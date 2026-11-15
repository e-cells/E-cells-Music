import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../config/app_config.dart';
import '../controllers/player_logic.dart';
import '../models/music_models.dart';

const _kgUserAgent = AppConfig.kugouUserAgent;

/// 代理转发上游响应头的最长等待：超时按网关故障处理（502），不让引擎
/// 在打开媒体源时无限悬挂（load 自身另有 15s 超时兜底，这里是源头）。
const Duration _upstreamHeaderTimeout = Duration(seconds: 15);

/// 代理转发上游数据流的「空闲」超时：相邻数据块间隔超过它视为上游断供。
///
/// 动机：CDN 尾部断供时这条响应会无限挂起——引擎等不到最后几百字节就
/// 到不了 EOF，completed 永远不触发，队列停在曲尾。Stream.timeout 判定
/// 的是事件间隔而非总时长：慢速但持续的传输（弱网听整首歌）不受影响；
/// 真断流超时后把错误注入响应，引擎收到的是截断错误而非无限等待，交给
/// 上层曲末/中途错误链路处置。
const Duration _upstreamIdleTimeout = Duration(seconds: 20);

/// 网易云域名（页 API/外链 CDN）统一在此判断：163 页面系（music.163.com）
/// 与音频 CDN 系（*.music.126.net）都要求 Referer，缺失时部分节点 403。
bool _isNeteaseHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == '163.com' ||
      host.endsWith('.163.com') ||
      host == '126.net' ||
      host.endsWith('.126.net');
}

/// 单次 load 的代理路由：远端 URL 或本地文件二选一。
///
/// 按 seq（`/play/<seq>`）路由而非共享单槽：两次 loadSong 重叠（快速切歌、
/// 后端对同一 URL 的延迟 Range 补请求）时，单槽在"请求到达时刻"取值会
/// 让旧 load 的请求吃到新歌字节（时长/元数据与实际音频不一致，甚至
/// 标题 A 播出 B 的声音）。按 seq 隔离后每个请求拿到的是它自己的目标。
class _ProxyRoute {
  _ProxyRoute({this.url, this.localPath})
      : assert((url != null) != (localPath != null), 'url 与 localPath 二选一');

  final String? url;
  final String? localPath;
}

/// 车机与手机通知渠道解析（车机使用专属静默渠道防弹窗，手机使用标准媒体渠道支持灵动岛与锁屏控制）。
///
/// 渠道 ID 与原生 MusicApplication.setupNotificationChannels 创建的渠道一一对应，
/// 改动需双端同步。渠道在启动时随 AudioServiceConfig 定向，运行时切换车机模式
/// 不会生效，需重启进程。
({String channelId, String channelName}) resolvePlaybackNotificationChannel({
  required bool isCarMode,
  required bool isAutomotiveDevice,
}) {
  final isCar = isCarMode || isAutomotiveDevice;
  return (
    channelId:
        isCar ? 'shiyin_music.playback_car' : 'shiyin_music.playback_phone',
    channelName: isCar ? '易格音乐 车机播放控制' : '易格音乐 播放控制',
  );
}

/// 通知卡片自定义按钮（收藏红心 / 桌面歌词开关）的状态查询与动作回调。
///
/// AudioHandler 在 main() 里创建时 AuthController/PlayerController 还不存在，
/// 与 [MusicAudioHandler.attachTransportControls] 同构：由 main.dart 在控制器
/// 就绪后注入闭包，晚绑定。Android 13+ 系统媒体卡片的标准槽位只有
/// 上一首/播放/下一首 3 个，自定义动作用剩余的 4、5 槽，因此最多两个
/// 自定义按钮，正是红心 + 桌面歌词。
class NotificationActionBridge {
  NotificationActionBridge({
    required this.canToggleLike,
    required this.isCurrentSongLiked,
    required this.onToggleLike,
    required this.desktopLyricsEnabled,
    required this.onToggleDesktopLyrics,
  });

  /// 当前是否可收藏（已登录且有在播歌曲）；false 时通知卡片隐藏红心。
  final bool Function() canToggleLike;

  /// 当前歌曲是否已收藏（决定红心实心/空心图标）。
  final bool Function() isCurrentSongLiked;

  /// 通知卡片红心被点击（乐观收藏/取消收藏，与应用内同一入口）。
  final Future<void> Function() onToggleLike;

  /// 桌面歌词当前是否开启（决定歌词按钮图标）。
  final bool Function() desktopLyricsEnabled;

  /// 通知卡片桌面歌词按钮被点击。
  final Future<void> Function() onToggleDesktopLyrics;
}

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler({bool enableNotificationActions = true}) {
    // 注意：不能用 playbackEventStream.map(...).pipe(playbackState)。
    // audio_service 的 playbackState 是 rxdart Subject，addStream 开始后
    // （源流永不关闭）_isAddingStreamItems 恒为 true，此后任何手动
    // playbackState.add 都会抛 "You cannot add items while items are
    // being added from addStream"，导致收藏/歌词开关的手动重广播永远
    // 失败、通知图标永不换装（2026-09-17 线上问题根因，SYNOTIF 日志实锤）。
    // 改走显式 listen + 手动 add，播放事件与手动刷新统一经
    // [_safeBroadcastPlaybackEvent] 广播。
    _playbackEventsSubscription = audioPlayer.playbackEventStream.listen(
      _safeBroadcastPlaybackEvent,
      onError: (Object e) {
        debugPrint('[SYNOTIF][ERROR] 播放事件流异常: $e');
      },
    );
    // 车机（原生车机设备或用户开启车机模式）不注入自定义按钮：车机
    // 通知渠道为静默渠道，且车机系统对会话自定义操作的渲染不可控。
    // 与通知渠道一样只在启动时定向，运行时切换需重启进程。
    _notificationActionsEnabled = enableNotificationActions &&
        !kIsWeb &&
        Platform.isAndroid;
    debugPrint('[SYNOTIF] handler 创建：enableNotificationActions='
        '$enableNotificationActions kIsWeb=$kIsWeb '
        'Platform.android=${Platform.isAndroid} → '
        '_notificationActionsEnabled=$_notificationActionsEnabled');
  }

  /// 通知卡片自定义动作名（[customAction] 的 name 参数）。
  static const toggleLikeActionName = 'shiyin.toggle_like';
  static const toggleDesktopLyricsActionName = 'shiyin.toggle_desktop_lyrics';

  final AudioPlayer audioPlayer = AudioPlayer();

  bool _notificationActionsEnabled = false;
  NotificationActionBridge? _notificationActions;

  /// 本进程是否向系统媒体会话投递过媒体（loadSong/setSongQueue）。
  /// 昨日通知按钮改动新增的恢复/开关监听会在冷启动（_restoreSettings/
  /// _restorePlaybackState 的 notifyListeners）触发 refreshPlaybackControls，
  /// 此时 handler 还没有任何 mediaItem：放行广播会让 audio_service 凭空
  /// 贴出媒体通知。未投递过直接跳过，等首播自然建立通知。
  bool _hasLoadedMedia = false;

  /// 是否允许重广播播放状态（纯决策，可单测）：只有向系统会话投递过
  /// 媒体后刷新才有意义，否则广播只会让 audio_service 凭空贴通知。
  @visibleForTesting
  static bool shouldRefreshPlaybackControls({required bool hasLoadedMedia}) =>
      hasLoadedMedia;

  /// 播放事件流订阅（替代已删除的 .pipe，见构造函数注释）。
  StreamSubscription<PlaybackEvent>? _playbackEventsSubscription;

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  int _queueIndex = 0;

  HttpServer? _proxy;
  /// 进行中的代理端口绑定：并发首载共享同一次 bind，避免各自绑定一个
  /// HttpServer（多余的那个永远泄漏）。失败时置空以便下次重试。
  Future<HttpServer>? _binding;
  final Map<int, _ProxyRoute> _proxyRoutes = {};
  int _loadSeq = 0;

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
  }

  /// 语音点歌回调：系统助手/车机语音经 MediaSession onPlayFromSearch
  /// 触发（audio_service 转发到 [playFromSearch]），与冷启动的
  /// MEDIA_PLAY_FROM_SEARCH intent 路径汇聚到 PlayerController.voiceSearchPlay。
  Future<void> Function(String query)? _onVoiceSearch;

  void attachVoiceSearch({
    required Future<void> Function(String query) onVoiceSearch,
  }) {
    _onVoiceSearch = onVoiceSearch;
  }

  /// MediaSession 热路径：应用在运行、媒体会话活跃时，助手/车机语音的
  /// "播放xxx" 直达这里（audio_service 0.18 的 AudioHandler 契约）。
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    debugPrint('[SYNOTIF][VoiceSearch] playFromSearch: "$query"');
    await _onVoiceSearch?.call(query);
  }

  /// 注入通知卡片自定义按钮的回调（见 [NotificationActionBridge]）。
  void attachNotificationActions(NotificationActionBridge bridge) {
    _notificationActions = bridge;
    debugPrint('[SYNOTIF] 桥接已注入：enabled=$_notificationActionsEnabled');
  }

  void detachNotificationActions() {
    _notificationActions = null;
    debugPrint('[SYNOTIF] 桥接已摘除');
  }

  /// 收藏/登录态/桌面歌词开关等非播放事件变化后，重广播一次播放状态，
  /// 让通知卡片按钮图标立即换装（audio_service 只在 playbackState 重发时
  /// 重建通知按钮，见 audio_service#1002）。
  void refreshPlaybackControls() {
    // 冷启动恢复阶段（尚无 mediaItem）跳过：此时广播只会凭空贴通知，
    // 没有可刷新的按钮。
    if (!shouldRefreshPlaybackControls(hasLoadedMedia: _hasLoadedMedia)) {
      debugPrint('[SYNOTIF] refreshPlaybackControls 跳过：本进程尚未投递媒体');
      return;
    }
    debugPrint('[SYNOTIF] refreshPlaybackControls：enabled='
        '$_notificationActionsEnabled bridge=${_notificationActions != null} '
        'playing=${audioPlayer.playing}');
    _safeBroadcastPlaybackEvent(audioPlayer.playbackEvent);
  }

  /// 播放事件与手动刷新共用的安全广播：永不向外抛错。
  ///
  /// listen 回调里抛出的未捕获异常只会上报 Zone，不会杀死订阅（此前的
  /// .pipe 方案里 map 抛错才会中断管道）；这里再包一层，极端情况下
  /// （如平台通道已关闭）也只落日志、不连累调用方。
  void _safeBroadcastPlaybackEvent(PlaybackEvent event) {
    try {
      playbackState.add(_playbackStateForEvent(event));
    } catch (e) {
      debugPrint('[SYNOTIF][ERROR] playbackState 广播失败: $e');
    }
  }

  /// 调试快照：当前按钮状态源的实时值（闭包抛错时记 unknown，不中断主流程）。
  String _notificationSourceSnapshot() {
    final bridge = _notificationActions;
    if (bridge == null) return 'bridge=null';
    String canLike = 'unknown', liked = 'unknown', lyrics = 'unknown';
    try {
      canLike = '${bridge.canToggleLike()}';
    } catch (e) {
      canLike = 'error:$e';
    }
    try {
      liked = '${bridge.isCurrentSongLiked()}';
    } catch (e) {
      liked = 'error:$e';
    }
    try {
      lyrics = '${bridge.desktopLyricsEnabled()}';
    } catch (e) {
      lyrics = 'error:$e';
    }
    return 'canLike=$canLike liked=$liked lyricsOn=$lyrics';
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    debugPrint('[SYNOTIF] customAction 收到：name=$name '
        'bridge=${_notificationActions != null} before={${_notificationSourceSnapshot()}}');
    final bridge = _notificationActions;
    if (bridge == null) return null;
    switch (name) {
      case toggleLikeActionName:
        // 桥接回调抛错不得上浮到 audio_service：这里是系统媒体会话的调用，
        // 未捕获异常会污染会话状态。失败时记日志并继续走兜底重广播，
        // 把通知图标恢复到真实状态（回滚乐观换装）。
        try {
          await bridge.onToggleLike();
        } catch (e) {
          debugPrint('[SYNOTIF][ERROR] customAction 红心执行失败: $e');
        }
      case toggleDesktopLyricsActionName:
        try {
          await bridge.onToggleDesktopLyrics();
        } catch (e) {
          debugPrint('[SYNOTIF][ERROR] customAction 桌面歌词执行失败: $e');
        }
      default:
        debugPrint('[SYNOTIF] 未知 customAction：$name');
        return null;
    }
    debugPrint('[SYNOTIF] customAction 执行完毕：name=$name '
        'after={${_notificationSourceSnapshot()}}，兜底重广播');
    // 动作内部通常经 notifyListeners → refreshPlaybackControls 触发刷新，
    // 这里兜底再刷一次（如收藏请求失败回滚较慢时先按乐观状态换图标）。
    refreshPlaybackControls();
    return null;
  }

  /// 系统媒体会话队列上限（超长歌单只推送窗口，降低 MediaItem 堆积）。
  static const _maxSystemQueueSize = 80;

  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _hasLoadedMedia = true;
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    final currentItem = _mediaItemFor(song, includeArt: true);
    final items = _buildSystemQueue(queueSongs, _queueIndex);

    if (items.isNotEmpty) {
      queue.add(items);
    }
    mediaItem.add(currentItem);

    // 本地文件与远端 URL 统一经代理（Range/UA 处理一致），
    // 路由按 seq 注册见 [_loadViaProxy]。
    await _loadViaProxy(url);
  }

  Future<void> _ensureProxy() async {
    if (_proxy != null) return;
    // 绑定调用跨越 await，不能只靠 _proxy 判重：并发首载必须共享同一个
    // bind future，否则会绑出两个 HttpServer（其中一个泄漏）。
    final binding = _binding;
    if (binding != null) {
      await binding;
      return;
    }
    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _binding = future;
    try {
      final server = await future;
      server.listen(_onProxyRequest, onError: (Object e) {
        debugPrint('[AudioHandler] proxy error: $e');
      });
      _proxy = server;
    } catch (e) {
      // 绑定失败清空在途标记，下次 load 可重试。
      _binding = null;
      rethrow;
    }
  }

  void _onProxyRequest(HttpRequest req) async {
    // 按 URL 里的 seq 取本请求自己的路由；过期请求（旧 load 的迟到
    // Range 补发）直接 410，让后端重新走当前源。
    final seq = int.tryParse(req.uri.path.split('/').last);
    final route = seq == null ? null : _proxyRoutes[seq];
    if (route == null) {
      req.response.statusCode = HttpStatus.gone;
      await req.response.close();
      return;
    }
    final localFile = route.localPath;
    if (localFile != null) {
      await _serveLocalFile(req, localFile);
      return;
    }
    final target = route.url;
    if (target == null) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 10);
      final targetUri = Uri.parse(target);
      final upstream = await client.openUrl(req.method, targetUri);
      upstream.headers.set(HttpHeaders.userAgentHeader, _kgUserAgent);
      // 网易云外链（music.163.com / *.music.126.net）校验 Referer：
      // 只带 UA 不带 Referer 时部分 CDN 节点直接 403。酷狗 CDN 不吃
      // Referer，保持原样不动。
      if (_isNeteaseHost(targetUri)) {
        upstream.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/');
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }
      final resp = await upstream.close().timeout(
        _upstreamHeaderTimeout,
        onTimeout: () => throw Exception('上游响应头超 $_upstreamHeaderTimeout 未返回'),
      );

      req.response.statusCode = resp.statusCode;
      String? upstreamContentType;
      resp.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == HttpHeaders.contentTypeHeader ||
            lower == HttpHeaders.transferEncodingHeader) {
          // content-type 单独记录：上游有则透传（flac 等直链会带正确
          // 类型），没有再兜底 audio/mpeg——写死 mpeg 会把 flac 误标，
          // 遇到按 Content-Type 选解码器的路径会解码失败。
          if (lower == HttpHeaders.contentTypeHeader && values.isNotEmpty) {
            upstreamContentType = values.first;
          }
          return;
        }
        req.response.headers.set(name, values);
      });
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        upstreamContentType ?? 'audio/mpeg',
      );
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      // 空闲超时注入错误结束响应：此时响应头多半已发出（502 写不进去，
      // 外层 catch 里的写状态码会被吞掉），连接被关闭后引擎侧表现为流
      // 截断错误——正是我们想要的「响亮失败」。
      await resp
          .timeout(
            _upstreamIdleTimeout,
            onTimeout: (sink) {
              sink.addError(
                StateError('上游数据流停滞超 $_upstreamIdleTimeout'),
              );
              sink.close();
            },
          )
          .pipe(req.response);
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    } finally {
      // 每请求一个 client，无论成功还是 seek/切歌导致的中止都必须关闭，
      // 否则每次中止都泄漏一个 socket。
      client.close(force: true);
    }
  }

  /// 本地文件路径推断音频 Content-Type（默认 audio/mpeg）。
  @visibleForTesting
  static String contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    return 'audio/mpeg';
  }

  Future<void> _serveLocalFile(HttpRequest req, String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final fileSize = file.lengthSync();
      final range = req.headers.value(HttpHeaders.rangeHeader);
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        contentTypeForPath(path),
      );

      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        int? start;
        int? end;
        // 合法形态仅三种：`start-end` / `start-` / `-suffix`；其余（含
        // `bytes=-`、段数不对、非数字）视为畸形，直接 416。
        if (parts.length == 2 && parts[0].isNotEmpty) {
          start = int.tryParse(parts[0]);
          if (parts[1].isNotEmpty) end = int.tryParse(parts[1]);
        } else if (parts.length == 2 && parts[1].isNotEmpty) {
          // 后缀范围 bytes=-N：取文件末尾 N 字节（此前误实现为开头 N 字节）。
          final suffix = int.tryParse(parts[1]);
          if (suffix != null && suffix > 0) {
            start = math.max(0, fileSize - suffix);
            end = fileSize - 1;
          }
        }
        // 不满足/畸形必须 416：
        // - 解析不出起点（畸形或 N<=0 的后缀）；
        // - 起点越界（文件比后端以为的短，如缓存被清理，end<start 会让
        //   contentLength 为负，直接抛异常挂在请求上）；
        // - 显式 end < start。
        if (start == null ||
            start >= fileSize ||
            (end != null && end < start)) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$fileSize',
          );
          await req.response.close();
          return;
        }
        // 显式 end 超出 EOF 必须 clamp 到 fileSize-1：否则 contentLength
        // 超过实际可发字节，客户端会一直等剩余数据直至挂起。
        final actualEnd = math.min(end ?? fileSize - 1, fileSize - 1);
        final length = actualEnd - start + 1;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$actualEnd/$fileSize');
        req.response.headers.contentLength = length;
        final stream = file.openRead(start, actualEnd + 1);
        await stream.pipe(req.response);
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentLength = fileSize;
        final stream = file.openRead();
        await stream.pipe(req.response);
      }
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _loadViaProxy(String url) async {
    await _ensureProxy();
    final seq = ++_loadSeq;
    _proxyRoutes[seq] = url.startsWith('http://') || url.startsWith('https://')
        ? _ProxyRoute(url: url)
        : _ProxyRoute(localPath: url);
    // 只保留最近几个路由：后端换源后的旧请求应尽快失效，
    // 同时给在途的延迟 Range 补发留足窗口。
    while (_proxyRoutes.length > 3) {
      _proxyRoutes.remove(_proxyRoutes.keys.first);
    }
    final proxyUrl = 'http://127.0.0.1:${_proxy!.port}/play/$seq';
    try {
      await _enqueueEngineLoad(seq, proxyUrl);
    } on PlayerException catch (e) {
      throw Exception('播放失败: ${e.message}');
    }
  }

  // ---- 引擎加载串行门 ----------------------------------------------------
  //
  // 桌面统一走 media_kit(libmpv) 后端后，WinRT MediaPlayer 高频 setUrl 的
  // COM 线程竞态崩溃根源已消除，最小加载间隔 workaround 已随迁移删除；
  // 但串行门本身保留——它承载的语义与后端无关：
  // 1. 串行：同一时刻至多一个 setUrl 在 native 侧执行（异步链排队）；
  // 2. 只加载最新：排队期间出现更新的 load 注册时，旧 load 直接跳过
  //    （不碰引擎），上层 playSong 的 hash 守卫会把对应的旧流程收尾。
  // 连点 N 次的净效果：队列里的旧任务瞬间跳过，只有最后一次真正进引擎。

  /// 引擎加载串行链的尾端（Promise 链式排队）。
  Future<void> _engineLoadChain = Future<void>.value();

  Future<void> _enqueueEngineLoad(int seq, String proxyUrl) {
    final task = _engineLoadChain
        .then((_) => _performEngineLoad(seq, proxyUrl));
    // 推进链尾但不吞掉调用方的异常：失败的任务本身仍会把错误抛给
    // 等待它的 _loadViaProxy，链上后续任务不受影响。
    _engineLoadChain = task.then(
      (_) {},
      onError: (_) {},
    );
    return task;
  }

  Future<void> _performEngineLoad(int seq, String proxyUrl) async {
    if (seq != _loadSeq) return; // 已被更新的加载取代，跳过
    await audioPlayer.setUrl(proxyUrl).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        throw Exception('音频加载超时，请检查网络后重试');
      },
    );
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    _hasLoadedMedia = true;
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    queue.add(_buildSystemQueue(queueSongs, _queueIndex));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong, includeArt: true));
    }
  }

  /// 当歌曲元数据（例如补全封面）更新时，刷新系统媒体项（通知栏/锁屏）。
  void updateCurrentSong(Song song) {
    mediaItem.add(_mediaItemFor(song, includeArt: true));
  }

  @override
  Future<void> play() async {
    // 曲末恢复：completed 且位置停在尾部时，移动端原生 just_audio 的
    // playing 是陈旧 true（EOF 不回写），直接 play() 会被其首行
    // `if (playing) return` 短路——通知栏/锁屏/耳机媒体键的播放键在曲末
    // 按了毫无反应。与应用内 togglePlay 的 completed 分支同构：pause 归位
    // 后 seek(0) 重播本曲（去重标记由控制器「重新出声作废」不变式清掉）。
    // 只在「停在尾部」时回零：seekToAndPlay/_ensurePlaying 已把位置定位到
    // 曲中的 completed 状态必须原地续播，不能被回零冲掉（判定见
    // PlayerPlaybackLogic.shouldRestartTrackOnPlay）。复位失败不阻断起播。
    final restart = PlayerPlaybackLogic.shouldRestartTrackOnPlay(
      completed: audioPlayer.processingState == ProcessingState.completed,
      duration: audioPlayer.duration,
      position: audioPlayer.position,
    );
    if (restart) {
      debugPrint('[AudioHandler] 曲末收到播放指令 → pause+seek(0) 后重播本曲');
      try {
        if (audioPlayer.playing) {
          await audioPlayer.pause();
        }
        await audioPlayer.seek(Duration.zero);
      } catch (e) {
        debugPrint('[AudioHandler][ERROR] 曲末重播复位失败: $e');
      }
    }
    await audioPlayer.play();
  }

  @override
  Future<void> pause() async {
    await audioPlayer.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await audioPlayer.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> stop() async {
    await audioPlayer.stop();
  }

  Future<void> close() async {
    await _playbackEventsSubscription?.cancel();
    _playbackEventsSubscription = null;
    await _proxy?.close(force: true);
    _proxy = null;
    // 在途绑定标记必须同步清理，否则 close 后重建（热重启/重载）时
    // _ensureProxy 会命中旧 _binding 直接返回，_proxy 仍为 null 而空崩。
    _binding = null;
    await audioPlayer.dispose();
  }

  /// 构建推给系统媒体会话的队列：当前曲含封面，其余精简；超长队列只保留窗口。
  List<MediaItem> _buildSystemQueue(List<Song> songs, int focusIndex) {
    if (songs.isEmpty) {
      return const [];
    }
    final safeFocus = focusIndex.clamp(0, songs.length - 1);
    if (songs.length <= _maxSystemQueueSize) {
      return [
        for (var i = 0; i < songs.length; i++)
          _mediaItemFor(songs[i], includeArt: i == safeFocus),
      ];
    }

    final half = _maxSystemQueueSize ~/ 2;
    var start = safeFocus - half;
    var end = start + _maxSystemQueueSize;
    if (start < 0) {
      start = 0;
      end = _maxSystemQueueSize;
    } else if (end > songs.length) {
      end = songs.length;
      start = end - _maxSystemQueueSize;
    }
    _queueIndex = safeFocus - start;
    return [
      for (var i = start; i < end; i++)
        _mediaItemFor(songs[i], includeArt: i == safeFocus),
    ];
  }

  MediaItem _mediaItemFor(Song song, {bool includeArt = false}) {
    return MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: includeArt && song.coverUrl != null
          ? (song.coverUrl!.startsWith('/') ||
                  (song.coverUrl!.length > 2 && song.coverUrl![1] == ':')
              ? Uri.file(song.coverUrl!)
              : Uri.tryParse(song.coverUrl!))
          : null,
      extras: {'hash': song.hash, 'songId': song.id},
    );
  }

  /// 构建通知卡片/系统媒体卡片的按钮序列。
  ///
  /// Android 13+：系统卡片从 PlaybackState 渲染，自定义动作用 4、5 槽，
  /// 红心与词按钮在标准三键之外正常显示。
  /// Android 8–12：audio_service 原生侧会把自定义按钮从通知的 action
  /// 列表里过滤掉（只写入 PlaybackState，不进通知），因此这两个按钮在
  /// 旧系统的通知里不显示，通知本身不受影响（要在旧系统显示需原生侧
  /// 自定义通知构建，暂不做）。
  @visibleForTesting
  static List<MediaControl> buildNotificationControls({
    required bool playing,
    required bool customButtonsEnabled,
    NotificationActionBridge? actions,
  }) {
    final controls = <MediaControl>[];
    if (customButtonsEnabled && actions != null && actions.canToggleLike()) {
      final liked = actions.isCurrentSongLiked();
      controls.add(MediaControl.custom(
        androidIcon: liked
            ? 'drawable/ic_notification_heart_filled'
            : 'drawable/ic_notification_heart_outline',
        label: liked ? '取消收藏' : '收藏',
        name: toggleLikeActionName,
      ));
    }
    controls
      ..add(MediaControl.skipToPrevious)
      ..add(playing ? MediaControl.pause : MediaControl.play)
      ..add(MediaControl.skipToNext);
    if (customButtonsEnabled && actions != null) {
      final lyricsOn = actions.desktopLyricsEnabled();
      controls.add(MediaControl.custom(
        androidIcon: lyricsOn
            ? 'drawable/ic_notification_lyrics_on'
            : 'drawable/ic_notification_lyrics_off',
        label: lyricsOn ? '关闭桌面歌词' : '桌面歌词',
        name: toggleDesktopLyricsActionName,
      ));
    }
    return controls;
  }

  /// 上一次落日志的按钮组合签名：播放事件流高频，仅在组合变化时打一行。
  String? _lastLoggedControlsSignature;

  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    List<MediaControl> controls;
    try {
      controls = buildNotificationControls(
        playing: audioPlayer.playing,
        customButtonsEnabled: _notificationActionsEnabled,
        actions: _notificationActions,
      );
    } catch (e, st) {
      // 按钮构建抛错时回退标准三键，保证广播不断流（外层
      // [_safeBroadcastPlaybackEvent] 另有兜底），同时留下现场。
      debugPrint('[SYNOTIF][ERROR] 构建通知按钮异常，回退标准三键: $e\n$st');
      controls = [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ];
    }
    final signature = controls
        .map((c) =>
            '${c.action.name}:${c.customAction?.name ?? ''}:${c.androidIcon}')
        .join(' | ');
    if (signature != _lastLoggedControlsSignature) {
      _lastLoggedControlsSignature = signature;
      debugPrint('[SYNOTIF] 通知按钮组合(${controls.length}键, '
          'playing=${audioPlayer.playing}, src={${_notificationSourceSnapshot()}}): '
          '$signature');
    }
    return PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      // 紧凑视图（Android 8–12 收起的通知）索引指向通知内的 action，
      // 而 audio_service 会把自定义按钮过滤出通知（通知里永远只有
      // 上一首/播放/下一首 = 0/1/2），必须恒定取 [0,1,2]；Android 13+
      // 忽略该参数。
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
