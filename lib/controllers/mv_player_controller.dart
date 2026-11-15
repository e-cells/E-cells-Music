import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../config/app_config.dart';
import '../core/api_client.dart' show ApiException;
import '../models/music_models.dart';
import '../services/music_api.dart';
import 'player_controller.dart' show PlaybackMode;
import 'shuffle_queue.dart';

/// 单个 MV 加载失败后自动跳下一首前，允许的连续失败 MV 数上限。
const int _kMvMaxConsecutiveFailures = 5;

/// MV 播放控制器 —— 与歌曲播放器平行的独立播放系统。
///
/// 队列/播放模式（列表循环/随机/单曲循环）复用歌曲侧的 [PlaybackMode]
/// 与 [ShuffleQueue]；视频引擎用 video_player（Android ExoPlayer）。
/// 与 PlayerController 互斥：起播前经 [onPauseSongPlayer] 暂停歌曲播放。
class MvPlayerController extends ChangeNotifier {
  /// [api] 由 main.dart 装配时传入；测试/无装配环境经 [instance] 懒创建
  /// 的实例没有 api（仅支持读 UI 状态，播放链路会抛错）。
  MvPlayerController([MusicApi? api]) : _api = api {
    _instance = this;
    _restoreState();
    _restoreCollected();
  }

  static MvPlayerController? _instance;

  /// 全局实例（对齐 ThemeController.instance 先例）：入口页面无需逐层
  /// 透传构造参数即可触发 MV 播放。真实实例由 main.dart 唯一构造
  /// （带 api）；未装配环境懒创建无 api 实例供 UI 读状态。
  static MvPlayerController get instance => _instance ??= MvPlayerController();

  final MusicApi? _api;

  MusicApi get _requireApi => _api ?? (throw StateError('MV 播放器未初始化（缺少 API 客户端）'));

  // ==================== 播放状态 ====================

  /// MV 队列（与歌曲队列平行，不混用）。
  List<MvInfo> queue = const [];

  MvInfo? currentMv;

  /// 播放模式：列表循环（默认）/ 随机 / 单曲循环（复用歌曲侧枚举）。
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  bool isPlaying = false;
  bool isBuffering = false;

  /// 正在解析播放地址（首个画面出来前的准备态）。
  bool isPreparing = false;

  String? errorMessage;

  /// 期望画质（分档缺失时按降级链回退，见 [resolvePlayHash]）。
  MvQuality quality = MvQuality.high;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 高频进度单独走 ValueNotifier，避免整页每帧重建（对齐 PlayerController）。
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  /// 歌单/榜单/电台「以 MV 播放」时的后台匹配态（UI 显示「正在匹配MV…」）。
  bool isResolvingQueue = false;

  /// 视频引擎控制器（UI 层 VideoPlayer 挂 texture 渲染）。
  VideoPlayerController? videoController;

  /// MV 播放页是否在前台（全局迷你小窗据此隐藏，避免与页面重复）。
  bool isPlayerPageVisible = false;

  /// 本次运行是否已主动发起过 MV 播放会话。
  /// 冷启动仅从本地恢复历史队列（尚未点播）时为 false，不弹出全局 MV 小窗。
  bool _sessionActive = false;

  /// 是否因 APP 退到后台而自动暂停（回到前台时据此自动续播）。
  bool _pausedByLifecycle = false;

  /// 当前 APP 是否处于后台（防止退后台期间刚好初始化完的视频引擎在后台自动起播声音）。
  bool _isAppInBackground = false;

  /// 当前是否存在活跃的 MV 播放会话（供全局悬浮视频小窗与底栏入口判断）。
  bool get hasActiveSession =>
      currentMv != null &&
      (_sessionActive ||
          videoController != null ||
          isPreparing ||
          isResolvingQueue);

  /// 播放页进出前台时回写（触发迷你条显隐重建）。
  void setPlayerPageVisible(bool value) {
    if (isPlayerPageVisible == value) return;
    isPlayerPageVisible = value;
    notifyListeners();
  }

  /// 响应 APP 前后台生命周期变化（参考酷狗音乐 MV 播放逻辑）：
  /// - 退到后台（paused/detached）：自动暂停 MV，避免无画面以纯音频在后台继续播放；
  /// - 回到前台（resumed）：若退后台前正在播放，自动恢复视频播放。
  void handleAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _isAppInBackground = false;
        if (_pausedByLifecycle) {
          _pausedByLifecycle = false;
          final controller = videoController;
          if (controller != null &&
              controller.value.isInitialized &&
              !controller.value.isPlaying) {
            unawaited(controller.play());
          }
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _isAppInBackground = true;
        final controller = videoController;
        if (isPlaying || (controller != null && controller.value.isPlaying)) {
          _pausedByLifecycle = true;
          if (controller != null) {
            unawaited(controller.pause());
          }
          isPlaying = false;
          notifyListeners();
        }
    }
  }

  /// MV 起播前暂停歌曲播放器（main.dart 注入，双向互斥的 MV 侧）。
  VoidCallback? onPauseSongPlayer;

  /// 「切换为音频」时把 MV 对应的歌曲交回歌曲播放器（main.dart 注入）。
  ///
  /// MV 控制器不持有 PlayerController（保持两套播放系统解耦），经此
  /// 回调借 main.dart 装配的实例完成 playSong；未注入环境（测试）为 null。
  Future<void> Function(Song song, List<Song>? queue, Duration? initialPosition)?
  onPlaySong;

  /// API 客户端只读暴露：「切换为音频」兜底搜索（MV 反查歌曲）用。
  MusicApi? get api => _api;

  final ShuffleQueue _shuffleQueue = ShuffleQueue();

  /// 引擎加载串行门：只让最新一次 prepare 生效（对齐歌曲侧 _loadSeq）。
  int _loadSeq = 0;

  /// 曲末去重：video_player 的 completed 事件在一个曲末可能多次触发。
  String? _completedMvKey;

  /// 连续加载失败计数（自动跳歌预算，防跳歌风暴）。
  int _consecutiveFailures = 0;

  /// 歌曲批量转 MV 匹配任务序号（新一轮匹配作废旧任务）。
  int _resolveTaskSeq = 0;

  /// 「以 MV 播放」时的来源歌曲队列（原顺序、仅酷狗源），供切回音频用。
  List<Song> _sourceSongs = const [];

  /// 来源歌曲索引：album_audio_id → Song（MV.albumAudioId 反查来源歌）。
  final Map<String, Song> _sourceSongByAlbumAudioId = {};

  Timer? _saveDebounce;

  /// MV 详情（分档 hash）内存缓存：key 为 mv.key。
  final Map<String, MvInfo> _detailCache = {};

  int get queueIndex {
    final cur = currentMv;
    if (cur == null) return -1;
    return queue.indexWhere((mv) => MvInfo.isSameMv(mv, cur));
  }

  // ==================== 播放入口 ====================

  /// 播放指定 MV（queue 提供时替换整队，与 PlayerController.playSong 同构）。
  Future<void> playMv(MvInfo mv, {List<MvInfo>? queue}) {
    final newQueue = _mergeQueue(queue, keepCurrent: false);
    return _startMv(mv, newQueue);
  }

  /// 把一批歌曲按原顺序转成 MV 队列播放（歌单/榜单/电台/单曲「观看MV」共用）。
  ///
  /// 首批（30 个）解析返回即起播，其余批次后台补队列；无 MV 的歌曲剔除。
  /// [onFirstPlay] 在首个 MV 起播后回调（此时即可跳转 MV 页，不必等
  /// 全量匹配完成）。返回成功匹配的 MV 总数（调用方据此 Toast）。
  Future<int> playSongsAsMvQueue(
    List<Song> songs, {
    void Function()? onFirstPlay,
  }) async {
    final task = ++_resolveTaskSeq;
    final candidates = songs
        .where((song) => song.source == SongSource.kugou)
        .toList();
    // 记录来源歌曲（含未匹配上的）：切回音频时按 album_audio_id 找回
    // 对应歌曲并恢复原队列，不必再走网络。
    _sourceSongs = candidates;
    _sourceSongByAlbumAudioId
      ..clear()
      ..addEntries(
        candidates.map((song) => MapEntry(song.albumAudioId ?? song.id, song)),
      );
    isResolvingQueue = true;
    notifyListeners();

    final matched = <MvInfo>[];
    var started = false;
    try {
      // 按原顺序分批解析（songsMv 内部每批 30 个 id）。
      const batchSize = 30;
      for (var start = 0; start < candidates.length; start += batchSize) {
        if (task != _resolveTaskSeq) return matched.length; // 新任务接管
        final batch = candidates.skip(start).take(batchSize).toList();
        final idToMv = await _requireApi.songsMv(batch);
        for (final song in batch) {
          final id = song.albumAudioId ?? song.id;
          final mv = idToMv[id];
          if (mv != null) {
            // 反查结果不带标题，用歌曲元信息补全展示。
            matched.add(
              mv.title == '未知MV'
                  ? mv.copyWith(
                      title: song.title,
                      artist: mv.artist == '未知艺人' ? song.artist : mv.artist,
                    )
                  : mv,
            );
          }
        }
        if (matched.isNotEmpty && !started) {
          // 首批命中即起播（整队替换——「以 MV 播放」意图是播这一批，
          // 即便已有别的 MV 会话在播也切换过来），并立即触发 onFirstPlay
          // 跳转 MV 播放页（在页面内展示解析加载态），避免等待视频缓冲完
          // 才跳页导致 context 失效或后台只播声音。
          started = true;
          final firstPlayFuture = playMv(
            matched.first,
            queue: matched.toList(),
          );
          onFirstPlay?.call();
          await firstPlayFuture;
        } else if (matched.isNotEmpty) {
          _appendQueue(matched);
        }
      }
    } finally {
      if (task == _resolveTaskSeq) {
        isResolvingQueue = false;
        notifyListeners();
      }
    }
    return matched.length;
  }

  // ==================== 切回音频 ====================

  /// 当前 MV 对应的来源歌曲（经 [playSongsAsMvQueue] 建立的映射）。
  ///
  /// 搜索/歌手页等直开的 MV 没有来源映射，返回 null，由调用方兜底搜索。
  Song? sourceSongFor(MvInfo mv) {
    final albumAudioId = mv.albumAudioId;
    if (albumAudioId == null || albumAudioId.isEmpty) return null;
    return _sourceSongByAlbumAudioId[albumAudioId];
  }

  /// 切回音频时的歌曲队列：来源队列仍包含该歌曲时返回原队列，
  /// 否则（映射缺失/过期）返回 null，调用方退化为单曲播放。
  List<Song>? sourceQueueFor(Song song) {
    if (_sourceSongs.isEmpty) return null;
    final contains = _sourceSongs.any(
      (item) => item.hash == song.hash && item.hash.isNotEmpty,
    );
    return contains ? _sourceSongs : null;
  }

  // ==================== 传输控制 ====================

  Future<void> togglePlay() async {
    _pausedByLifecycle = false;
    final controller = videoController;
    if (controller == null || !controller.value.isInitialized) {
      final cur = currentMv;
      if (cur != null && !isPreparing) {
        await playMv(cur, queue: queue);
      }
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      onPauseSongPlayer?.call();
      // 曲末暂停后重新点播放：回到开头重播（对齐歌曲侧行为）。
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
  }

  Future<void> pause() async {
    _pausedByLifecycle = false;
    final controller = videoController;
    if (controller != null && controller.value.isPlaying) {
      await controller.pause();
    }
  }

  Future<void> seek(Duration target) async {
    final controller = videoController;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.seekTo(target);
    position = target;
    positionListenable.value = target;
  }

  /// 切换播放模式：列表循环 → 随机 → 单曲循环（与歌曲侧同序）。
  void cyclePlaybackMode() {
    switch (playbackMode) {
      case PlaybackMode.playlistLoop:
        playbackMode = PlaybackMode.shuffle;
        _shuffleQueue.reset(
          queue.length,
          currentIndex: queueIndex >= 0 ? queueIndex : null,
        );
      case PlaybackMode.shuffle:
        playbackMode = PlaybackMode.singleLoop;
      case PlaybackMode.singleLoop:
        playbackMode = PlaybackMode.playlistLoop;
    }
    _scheduleSaveState();
    notifyListeners();
  }

  /// 下一首（手动）。随机模式走洗牌队列，顺序模式 index+1（尾回绕）。
  Future<void> next() async {
    final target = _nextMv(manual: true);
    if (target != null) await _startMv(target, queue);
  }

  /// 上一首（手动）。随机模式精确回退；顺序模式 index-1，首曲回零重播。
  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (playbackMode == PlaybackMode.shuffle) {
      final index = _shuffleQueue.previous(queue.length);
      if (index >= 0 && index < queue.length) {
        await _startMv(queue[index], queue);
      }
      return;
    }
    final index = queueIndex;
    if (index <= 0) {
      await seek(Duration.zero);
      return;
    }
    await _startMv(queue[index - 1], queue);
  }

  // ==================== 队列管理 ====================

  /// 「下一个播放」：插到当前 MV 之后（对齐歌曲侧 addSongsToQueue）。
  void addToQueue(MvInfo mv) {
    _appendQueue([mv], afterCurrent: true);
  }

  void addMvsToQueue(List<MvInfo> mvs) {
    _appendQueue(mvs);
  }

  /// 移除队列项：删当前项时切到同位置下一首；删其他项不打断播放。
  Future<void> removeFromQueueAt(int index) async {
    if (index < 0 || index >= queue.length) return;
    final newQueue = List<MvInfo>.of(queue);
    final removed = newQueue.removeAt(index);
    if (MvInfo.isSameMv(currentMv, removed)) {
      if (newQueue.isEmpty) {
        queue = const [];
        await stop();
        return;
      }
      queue = newQueue;
      await _startMv(
        newQueue[index.clamp(0, newQueue.length - 1)],
        newQueue,
      );
      return;
    }
    queue = newQueue;
    _syncShuffleLength();
    _scheduleSaveState();
    notifyListeners();
  }

  /// 清空队列（保留当前播放中的 MV）。
  void clearQueue() {
    final cur = currentMv;
    if (cur == null) return;
    queue = [cur];
    _syncShuffleLength();
    _scheduleSaveState();
    notifyListeners();
  }

  /// 停止 MV 播放（迷你条关闭）：释放引擎、清空当前（保留队列可再续）。
  Future<void> stop() async {
    _loadSeq++;
    _completedMvKey = null;
    _sessionActive = false;
    _pausedByLifecycle = false;
    // MV 会话结束，来源歌曲映射一并作废（避免误用旧队列切回音频）。
    _sourceSongs = const [];
    _sourceSongByAlbumAudioId.clear();
    final controller = videoController;
    videoController = null;
    currentMv = null;
    isPlaying = false;
    isBuffering = false;
    isPreparing = false;
    position = Duration.zero;
    duration = Duration.zero;
    positionListenable.value = Duration.zero;
    errorMessage = null;
    notifyListeners();
    await controller?.dispose();
  }

  // ==================== 画质 ====================

  /// 切换画质：保留当前进度重载。
  Future<void> setQuality(MvQuality target) async {
    if (target == quality) return;
    quality = target;
    final cur = currentMv;
    if (cur == null) {
      notifyListeners();
      return;
    }
    await _startMv(cur, queue, initialPosition: position);
  }

  /// 当前 MV 实际可用的画质档位（供 UI 画质胶囊展示可选档）。
  List<MvQuality> availableQualities() {
    final cur = currentMv;
    if (cur == null || cur.resolutionHashes.isEmpty) {
      return const [MvQuality.standard];
    }
    return MvQuality.values
        .where((q) => cur.resolutionHashes[q.apiValue]?.isNotEmpty == true)
        .toList();
  }

  // ==================== 本地收藏 ====================

  List<MvInfo> collectedMvs = const [];

  bool isCollected(MvInfo mv) {
    return collectedMvs.any((item) => MvInfo.isSameMv(item, mv));
  }

  Future<void> toggleCollect(MvInfo mv) async {
    final next = List<MvInfo>.of(collectedMvs);
    if (isCollected(mv)) {
      next.removeWhere((item) => MvInfo.isSameMv(item, mv));
    } else {
      next.insert(0, mv);
    }
    collectedMvs = next;
    notifyListeners();
    await _saveCollected();
  }

  // ==================== 内部：加载链 ====================

  Future<void> _startMv(
    MvInfo mv,
    List<MvInfo> newQueue, {
    Duration? initialPosition,
  }) async {
    onPauseSongPlayer?.call();
    _sessionActive = true;
    _pausedByLifecycle = false;
    _completedMvKey = null;
    currentMv = mv;
    errorMessage = null;
    isPreparing = true;
    isPlaying = false;
    isBuffering = true;
    position = initialPosition ?? Duration.zero;
    duration = mv.duration ?? Duration.zero;
    positionListenable.value = position;
    queue = _mergeQueue(newQueue, keepCurrent: true, current: mv);
    if (playbackMode == PlaybackMode.shuffle) {
      final index = queueIndex;
      if (index >= 0) {
        _shuffleQueue.syncCurrentIndex(queue.length, index);
      } else {
        _shuffleQueue.reset(queue.length, currentIndex: null);
      }
    }
    notifyListeners();
    _scheduleSaveState();

    final seq = ++_loadSeq;
    try {
      // 1. 详情补全分档 hash（内存缓存，一次会话内不重复请求）。
      var resolved = mv;
      if (mv.resolutionHashes.isEmpty && mv.id.isNotEmpty) {
        final cached = _detailCache[mv.key];
        if (cached != null) {
          resolved = cached;
        } else {
          final detail = await _requireApi.mvDetail(mv);
          if (detail != null) {
            _detailCache[mv.key] = detail;
            resolved = detail;
          }
        }
      }
      if (seq != _loadSeq) return;
      if (!identical(resolved, mv)) {
        currentMv = resolved;
        if (resolved.duration != null && duration == Duration.zero) {
          duration = resolved.duration!;
        }
        queue = [
          for (final item in queue)
            if (MvInfo.isSameMv(item, resolved)) resolved else item,
        ];
        notifyListeners();
      }

      // 2. 按期望画质选 hash（降级链兜底到默认 hash）。
      final playHash = resolvePlayHash(resolved, quality);

      // 3. 解析播放地址（主链 + 备用链依次尝试）。
      final mvUrl = await _requireApi.mvUrl(playHash);
      if (seq != _loadSeq) return;
      if (!mvUrl.isPlayable) {
        throw ApiException('该 MV 暂无法播放（可能需要 VIP）');
      }

      // 4. 建引擎、初始化、起播。
      var loaded = false;
      Object? lastError;
      for (final url in mvUrl.urls) {
        try {
          final controller = VideoPlayerController.networkUrl(
            Uri.parse(url),
            httpHeaders: {'User-Agent': AppConfig.kugouUserAgent},
          );
          await controller.initialize();
          if (seq != _loadSeq) {
            await controller.dispose();
            return;
          }
          await _attachEngine(controller, initialPosition: initialPosition);
          loaded = true;
          break;
        } on Exception catch (error) {
          lastError = error;
          if (seq != _loadSeq) return;
        }
      }
      if (!loaded) {
        throw lastError ?? ApiException('MV 加载失败');
      }
      _consecutiveFailures = 0;
    } on Exception catch (error) {
      if (seq != _loadSeq) return;
      debugPrint('[MV] 加载失败: $error');
      _registerFailure(mv);
      return;
    }
  }

  Future<void> _attachEngine(
    VideoPlayerController controller, {
    Duration? initialPosition,
  }) async {
    await videoController?.dispose();
    videoController = controller;
    duration = controller.value.duration;
    if (initialPosition != null && initialPosition > Duration.zero) {
      await controller.seekTo(initialPosition);
      position = initialPosition;
      positionListenable.value = initialPosition;
    }
    controller.addListener(_onVideoUpdate);
    isPreparing = false;
    isBuffering = false;
    if (_isAppInBackground) {
      _pausedByLifecycle = true;
      isPlaying = false;
    } else {
      await controller.play();
      isPlaying = true;
    }
    notifyListeners();
  }

  void _onVideoUpdate() {
    final controller = videoController;
    if (controller == null) return;
    final value = controller.value;
    position = value.position;
    positionListenable.value = value.position;
    if (value.duration != duration) {
      duration = value.duration;
      notifyListeners();
    }
    final playing = value.isPlaying;
    final buffering = value.isBuffering;
    if (playing != isPlaying || buffering != isBuffering) {
      isPlaying = playing;
      isBuffering = buffering && !value.isCompleted;
      notifyListeners();
    }
    if (value.hasError) {
      _registerFailure(currentMv);
      return;
    }
    if (value.isCompleted) {
      final key = currentMv?.key;
      if (key == null || _completedMvKey == key) return;
      _completedMvKey = key;
      _handleCompleted();
    }
  }

  /// 曲末推进：单曲循环重播；否则取下一首（洗牌/顺序），与歌曲侧同构。
  Future<void> _handleCompleted() async {
    if (playbackMode == PlaybackMode.singleLoop) {
      final controller = videoController;
      if (controller == null) return;
      await controller.seekTo(Duration.zero);
      await controller.play();
      return;
    }
    final target = _nextMv(manual: false);
    if (target != null) {
      await _startMv(target, queue);
    }
  }

  /// 取下一首 MV。随机走洗牌队列；顺序 index+1，尾回绕到队首。
  MvInfo? _nextMv({required bool manual}) {
    if (queue.isEmpty) return null;
    if (queue.length == 1) return queue.first;
    if (playbackMode == PlaybackMode.shuffle) {
      final index = _shuffleQueue.next(queue.length);
      if (index >= 0 && index < queue.length) return queue[index];
      return queue.first;
    }
    final index = queueIndex;
    final nextIndex = index + 1;
    return nextIndex >= queue.length ? queue.first : queue[nextIndex];
  }

  /// 加载失败处理：计入预算后自动跳下一首，超预算停下报错。
  void _registerFailure(MvInfo? mv) {
    if (mv == null || !MvInfo.isSameMv(currentMv, mv)) return;
    _consecutiveFailures++;
    if (_consecutiveFailures >= _kMvMaxConsecutiveFailures) {
      errorMessage = '连续多个 MV 播放失败，已停止';
      isPreparing = false;
      isBuffering = false;
      isPlaying = false;
      notifyListeners();
      return;
    }
    final target = _nextMv(manual: false);
    if (target != null && !MvInfo.isSameMv(target, mv)) {
      unawaited(_startMv(target, queue));
    } else {
      errorMessage = 'MV 播放失败，请稍后重试';
      isPreparing = false;
      isBuffering = false;
      isPlaying = false;
      notifyListeners();
    }
  }

  // ==================== 内部：队列与持久化 ====================

  List<MvInfo> _mergeQueue(
    List<MvInfo>? newQueue, {
    required bool keepCurrent,
    MvInfo? current,
  }) {
    if (newQueue == null) return queue;
    final merged = List<MvInfo>.of(newQueue);
    if (!merged.any((mv) => MvInfo.isSameMv(mv, current ?? currentMv))) {
      final cur = current ?? currentMv;
      if (cur != null && keepCurrent) {
        merged.insert(0, cur);
      }
    }
    return merged;
  }

  void _appendQueue(List<MvInfo> mvs, {bool afterCurrent = false}) {
    if (mvs.isEmpty) return;
    final newQueue = List<MvInfo>.of(queue);
    final seen = newQueue.map((mv) => mv.key).toSet();
    final fresh = mvs.where((mv) => seen.add(mv.key)).toList();
    if (fresh.isEmpty) return;
    final index = afterCurrent ? queueIndex + 1 : newQueue.length;
    newQueue.insertAll(index.clamp(0, newQueue.length), fresh);
    queue = newQueue;
    _syncShuffleLength();
    _scheduleSaveState();
    notifyListeners();
  }

  /// 队列长度变化后同步洗牌队列（保持已播不重复语义）。
  void _syncShuffleLength() {
    if (playbackMode == PlaybackMode.shuffle) {
      final index = queueIndex;
      if (_shuffleQueue.length != queue.length) {
        _shuffleQueue.reset(
          queue.length,
          currentIndex: index >= 0 ? index : null,
        );
      }
    }
  }

  static const _statePrefsKey = 'mv_playback_state';
  static const _stateMaxQueueSize = 200;

  void _scheduleSaveState() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cur = currentMv;
        if (cur == null) {
          await prefs.remove(_statePrefsKey);
          return;
        }
        final trimmed = queue.length > _stateMaxQueueSize
            ? queue.sublist(0, _stateMaxQueueSize)
            : queue;
        await prefs.setString(
          _statePrefsKey,
          jsonEncode({
            'mode': playbackMode.name,
            'quality': quality.name,
            'index': queueIndex.clamp(0, trimmed.length - 1),
            'queue': trimmed.map((mv) => mv.toJson()).toList(),
          }),
        );
      } on Exception catch (error) {
        debugPrint('[MV] 保存播放状态失败: $error');
      }
    });
  }

  /// 冷启动恢复队列/模式/画质（不自动起播，进入 MV 页后手动续看）。
  Future<void> _restoreState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_statePrefsKey);
      if (raw == null || raw.isEmpty) return;
      final json = asMap(jsonDecode(raw));
      playbackMode = PlaybackMode.values.firstWhere(
        (mode) => mode.name == asString(json['mode']),
        orElse: () => PlaybackMode.playlistLoop,
      );
      quality = MvQuality.values.firstWhere(
        (q) => q.name == asString(json['quality']),
        orElse: () => MvQuality.high,
      );
      final restored = asList(json['queue'])
          .whereType<Map<String, dynamic>>()
          .map(MvInfo.fromJson)
          .where((mv) => mv.isPlayable)
          .toList();
      if (restored.isEmpty) return;
      queue = restored;
      final index = asInt(json['index']) ?? 0;
      currentMv = restored[index.clamp(0, restored.length - 1)];
      duration = currentMv?.duration ?? Duration.zero;
      notifyListeners();
    } on Exception catch (error) {
      debugPrint('[MV] 恢复播放状态失败: $error');
    }
  }

  static const _collectedPrefsKey = 'mv_collected';

  Future<void> _saveCollected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _collectedPrefsKey,
        jsonEncode(collectedMvs.map((mv) => mv.toJson()).toList()),
      );
    } on Exception catch (error) {
      debugPrint('[MV] 保存收藏失败: $error');
    }
  }

  Future<void> _restoreCollected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_collectedPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final list = asList(jsonDecode(raw))
          .whereType<Map<String, dynamic>>()
          .map(MvInfo.fromJson)
          .where((mv) => mv.isPlayable)
          .toList();
      if (list.isEmpty) return;
      collectedMvs = list;
      notifyListeners();
    } on Exception catch (error) {
      debugPrint('[MV] 恢复收藏失败: $error');
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    if (_instance == this) _instance = null;
    _saveDebounce?.cancel();
    positionListenable.dispose();
    videoController?.dispose();
    super.dispose();
  }
}
