import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart' show PlaybackMode;
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../adaptive_layout.dart';
import '../widgets/artwork.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mv_queue_sheet.dart';
import '../widgets/toast.dart';

/// 「切换为音频」统一入口：把当前 MV 换成对应的歌曲播放（歌曲 ⇄ MV 互切）。
///
/// 优先用「以 MV 播放」时记录的来源歌曲（恢复原歌曲队列并尽量续接
/// 进度）；来源缺失（搜索/歌手页直开的 MV）时按标题+歌手搜歌兜底。
/// 找不到对应歌曲时 toast 告知，MV 播放保持不动。
Future<void> switchMvToAudioWithFeedback(BuildContext context) async {
  final mvPlayer = MvPlayerController.instance;
  final cur = mvPlayer.currentMv;
  if (cur == null) return;
  final onPlaySong = mvPlayer.onPlaySong;
  if (onPlaySong == null) {
    Toast.error('歌曲播放器未就绪');
    return;
  }

  var song = mvPlayer.sourceSongFor(cur);
  var queue = song == null ? null : mvPlayer.sourceQueueFor(song);
  if (song == null) {
    final api = mvPlayer.api;
    if (api == null) {
      Toast.error('暂无法匹配对应歌曲');
      return;
    }
    Toast.info('正在匹配歌曲…');
    try {
      song = await api.searchSongForMv(cur);
    } on Exception {
      song = null;
    }
    if (song == null) {
      Toast.info('这首 MV 暂无对应歌曲');
      return;
    }
    queue = [song];
  }

  // MV 与歌曲通常同源同时长：播放超过 5 秒就把进度带过去，近似无缝切换。
  final resumeFrom =
      mvPlayer.position > const Duration(seconds: 5) ? mvPlayer.position : null;
  await onPlaySong(song, queue, resumeFrom);
  // 音频已接棒，结束 MV 会话（释放视频引擎、收起迷你条）并退出 MV 页。
  await mvPlayer.stop();
  if (context.mounted) {
    Navigator.of(context).maybePop();
  }
}

/// MV 全屏播放页。
///
/// - 竖屏手机：视频 16:9 置顶，下方常驻信息与控制区；
/// - 横屏/车机：视频满幅，控制层覆盖、4 秒自动隐藏；
/// - 单击视频切换控制层（横屏）/播放暂停（竖屏），双击播放暂停；
/// - 退出页面时若 MV 仍在播放，由全局悬浮视频小窗（MvMiniBar）承接画面与控制，
///   点击小窗即可无缝回到本页。
class MvPlayerPage extends StatefulWidget {
  const MvPlayerPage({super.key, required this.mvPlayer});

  final MvPlayerController mvPlayer;

  static bool _isRouteOpen = false;

  /// 打开 MV 播放页：优先使用全局 [Toast.navigatorKey] 根导航器，
  /// 彻底避免从 `MaterialApp.builder` 浮层或已关闭弹窗的 `context` 调用时
  /// 因找不到 `Navigator` 而无法进入 MV 播放页的问题。
  static Future<void> open(
    BuildContext? context, {
    required MvPlayerController mvPlayer,
  }) async {
    if (_isRouteOpen || mvPlayer.isPlayerPageVisible) return;
    final navigator =
        Toast.navigatorKey.currentState ??
        (context != null && context.mounted
            ? Navigator.maybeOf(context, rootNavigator: true)
            : null);
    if (navigator == null) return;
    _isRouteOpen = true;
    mvPlayer.setPlayerPageVisible(true);
    try {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MvPlayerPage(mvPlayer: mvPlayer),
        ),
      );
    } finally {
      _isRouteOpen = false;
      mvPlayer.setPlayerPageVisible(false);
    }
  }

  @override
  State<MvPlayerPage> createState() => _MvPlayerPageState();
}

class _MvPlayerPageState extends State<MvPlayerPage> {
  static const _screenChannel = MethodChannel('shiyin_music/screen');

  bool _controlsVisible = true;
  bool _dragging = false;
  double _dragValue = 0;
  bool _manualFullscreen = false;
  Timer? _hideTimer;

  MvPlayerController get mvPlayer => widget.mvPlayer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _setKeepScreenOn(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      mvPlayer.setPlayerPageVisible(true);
      // 冷启动恢复的队列（currentMv 有值但引擎未建且无错误）：进入页面续看。
      final cur = mvPlayer.currentMv;
      if (cur != null &&
          mvPlayer.videoController == null &&
          !mvPlayer.isPreparing &&
          mvPlayer.errorMessage == null) {
        unawaited(mvPlayer.playMv(cur, queue: mvPlayer.queue));
      }
    });
    _armHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _setKeepScreenOn(false);
    _restoreGlobalOrientations();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final player = mvPlayer;
    Future.microtask(() => player.setPlayerPageVisible(false));
    super.dispose();
  }

  void _setKeepScreenOn(bool enabled) {
    if (isDesktopPlatform) return;
    unawaited(
      _screenChannel
          .invokeMethod<void>('setKeepScreenOn', enabled)
          .catchError((_) {}),
    );
  }

  void _enterFullscreen() {
    _manualFullscreen = true;
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _exitFullscreen() {
    _manualFullscreen = false;
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  /// 退出 MV 页时恢复全局方向锁（与 ThemeController.applyOrientations
  /// 同一约定）。不能直接调 applyOrientations——同参数会被其去重缓存
  /// 跳过，本页的横屏覆盖就会残留。
  void _restoreGlobalOrientations() {
    final theme = ThemeController.instance;
    final allowAll =
        AdaptiveLayout.isTabletByPlatform() ||
        theme.landscapeEnabled ||
        theme.carModeEnabled;
    SystemChrome.setPreferredOrientations(
      allowAll
          ? const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _armHideTimer();
  }

  // ==================== 布局 ====================

  @override
  Widget build(BuildContext context) {
    // 桌面平台无 video_player 实现，降级提示（v2.0.0 起仅发布 Android）。
    if (isDesktopPlatform) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tv_off_rounded, color: Colors.white54, size: 56),
              SizedBox(height: 12),
              Text(
                'MV 播放仅支持 Android 设备',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final canExitFullscreenOnBack =
        _manualFullscreen && isLandscape && !_isCarLandscape(context);

    return PopScope(
      canPop: !canExitFullscreenOnBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (canExitFullscreenOnBack) {
          _exitFullscreen();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AnimatedBuilder(
          animation: mvPlayer,
          builder: (context, _) {
            final cur = mvPlayer.currentMv;
            if (cur == null) {
              return const _EmptyMvView();
            }
            return isLandscape
                ? _buildLandscape(context, cur)
                : _buildPortrait(context, cur);
          },
        ),
      ),
    );
  }

  /// 竖屏：顶栏返回区 + 视频 16:9 置顶 + 下方常驻控制区。
  Widget _buildPortrait(BuildContext context, MvInfo cur) {
    final width = MediaQuery.sizeOf(context).width;
    final videoHeight = width * 9 / 16;
    final topPadding = MediaQuery.paddingOf(context).top;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(4, topPadding + 4, 12, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.white,
                  size: 30,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: '收起小窗',
              ),
              Expanded(
                child: Text(
                  cur.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white70,
                  size: 22,
                ),
                tooltip: '退出并停止 MV',
                onPressed: () {
                  unawaited(mvPlayer.stop());
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          height: videoHeight,
          child: _buildVideoArea(
            context,
            cur,
            showTopBar: false,
            showCenterTransport: true,
            showBottomBar: false,
          ),
        ),
        Expanded(
          child: Padding(
            // 底部留出手势导航条高度，避免「播放列表 N/M」贴到屏幕边缘。
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              16 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(context, cur),
                const SizedBox(height: 18),
                _buildProgressBar(context, compact: false),
                const SizedBox(height: 6),
                _buildControlRow(context, landscape: false),
                const Spacer(),
                _buildQueueHint(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 横屏/车机：满幅视频 + 自动隐藏覆盖控制层。
  Widget _buildLandscape(BuildContext context, MvInfo cur) {
    final visible = _controlsVisible ||
        mvPlayer.isPreparing ||
        mvPlayer.isBuffering ||
        _dragging;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: _buildVideoArea(
        context,
        cur,
        showTopBar: visible,
        showCenterTransport: visible,
        showBottomBar: visible,
      ),
    );
  }

  /// 视频画面 + 覆盖层。三个区域的显隐由调用方决定（竖屏只覆盖中央键）。
  Widget _buildVideoArea(
    BuildContext context,
    MvInfo cur, {
    required bool showTopBar,
    required bool showCenterTransport,
    required bool showBottomBar,
  }) {
    final controller = mvPlayer.videoController;
    final hasVideo = controller != null && controller.value.isInitialized;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 竖屏：点画面直接播放/暂停；横屏：点画面切换控制层。
      onTap: () {
        final size = MediaQuery.sizeOf(context);
        if (size.width > size.height) {
          _controlsVisible ? _hideControlsNow() : _showControls();
          setState(() {});
        } else {
          unawaited(mvPlayer.togglePlay());
        }
      },
      onDoubleTap: () => unawaited(mvPlayer.togglePlay()),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 画面（未就绪时显示封面 + 准备动画）
          if (hasVideo)
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            )
          else
            _buildPoster(cur),

          // 顶部渐变 + 标题栏
          if (showTopBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopBar(context, cur),
            ),

          // 中央：准备/缓冲动画 或 传输控制
          Center(
            child: _buildCenterContent(context, showCenterTransport),
          ),

          // 底部渐变 + 进度条 + 控制行
          if (showBottomBar)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomOverlay(context),
            ),

          // 错误浮层
          if (mvPlayer.errorMessage case final message?)
            Positioned(
              left: 0,
              right: 0,
              bottom: 120,
              child: _buildErrorCard(context, message),
            ),
        ],
      ),
    );
  }

  // ==================== 组件 ====================

  Widget _buildPoster(MvInfo cur) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (cur.coverUrl != null)
            Opacity(
              opacity: .45,
              child: Artwork(
                url: cur.coverUrl,
                size: double.infinity,
                borderRadius: 0,
                highRes: true,
                icon: Icons.music_video_rounded,
              ),
            ),
          const SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, MvInfo cur) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        MediaQuery.paddingOf(context).top + 6,
        8,
        10,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () {
              final size = MediaQuery.sizeOf(context);
              if (_manualFullscreen &&
                  size.width > size.height &&
                  !_isCarLandscape(context)) {
                _exitFullscreen();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            tooltip: '返回',
          ),
          Expanded(
            child: MarqueeText.text(
              '${cur.title} · ${cur.artist}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          _buildAudioSwitchButton(context, light: true),
          _buildQualityPill(context),
          const SizedBox(width: 4),
          _buildCollectButton(context, cur, light: true),
        ],
      ),
    );
  }

  Widget _buildCenterContent(BuildContext context, bool showTransport) {
    if (mvPlayer.isPreparing || (mvPlayer.isBuffering && !mvPlayer.isPlaying)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 10),
          Text(
            mvPlayer.isPreparing ? '正在解析播放地址…' : '缓冲中…',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      );
    }
    if (!showTransport) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CircleButton(
          icon: Icons.skip_previous_rounded,
          size: 52,
          onPressed: () => unawaited(mvPlayer.previous()),
          tooltip: '上一个 MV',
        ),
        const SizedBox(width: 34),
        _CircleButton(
          icon: mvPlayer.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          size: 68,
          filled: true,
          onPressed: () => unawaited(mvPlayer.togglePlay()),
          tooltip: mvPlayer.isPlaying ? '暂停' : '播放',
        ),
        const SizedBox(width: 34),
        _CircleButton(
          icon: Icons.skip_next_rounded,
          size: 52,
          onPressed: () => unawaited(mvPlayer.next()),
          tooltip: '下一个 MV',
        ),
      ],
    );
  }

  Widget _buildBottomOverlay(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        MediaQuery.paddingOf(context).bottom + 12,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildProgressBar(context, compact: true),
          const SizedBox(height: 8),
          _buildControlRow(context, landscape: true),
        ],
      ),
    );
  }

  /// 标题/歌手/收藏（竖屏信息区，深色纯黑底常驻白字）。
  Widget _buildInfoRow(BuildContext context, MvInfo cur) {
    const textColor = Colors.white;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText.text(
                cur.title,
                style: const TextStyle(
                  color: textColor,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                cur.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor.withValues(alpha: .68),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _buildAudioSwitchButton(context, light: true),
        const SizedBox(width: 4),
        _buildQualityPill(context),
        const SizedBox(width: 4),
        _buildCollectButton(context, cur, light: true),
      ],
    );
  }

  /// 「切换为音频」按钮（歌曲 ⇄ MV 互切）：把当前 MV 换成对应歌曲播放。
  Widget _buildAudioSwitchButton(BuildContext context, {required bool light}) {
    return IconButton(
      tooltip: '切换为音频播放',
      onPressed: () => unawaited(switchMvToAudioWithFeedback(context)),
      icon: Icon(
        Icons.audiotrack_rounded,
        color: light ? Colors.white70 : Theme.of(context).colorScheme.primary,
        size: 24,
      ),
    );
  }

  /// 画质胶囊：多档可用时弹菜单切换，单档时仅展示。
  Widget _buildQualityPill(BuildContext context) {
    final options = mvPlayer.availableQualities();
    final current = mvPlayer.quality;
    return PopupMenuButton<MvQuality>(
      tooltip: '切换画质',
      enabled: options.length > 1,
      onSelected: (value) => unawaited(mvPlayer.setQuality(value)),
      itemBuilder: (_) => [
        for (final q in options)
          PopupMenuItem(
            value: q,
            child: Row(
              children: [
                if (q == current)
                  const Icon(Icons.check_rounded, size: 18)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 6),
                Text(q.label),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              options.length > 1 ? current.label : '标清',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (options.length > 1) ...[
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                color: Colors.white,
                size: 16,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCollectButton(
    BuildContext context,
    MvInfo cur, {
    required bool light,
  }) {
    final collected = mvPlayer.isCollected(cur);
    return IconButton(
      tooltip: collected ? '取消收藏' : '收藏 MV',
      onPressed: () async {
        await mvPlayer.toggleCollect(cur);
        if (!mounted) return;
        Toast.success(mvPlayer.isCollected(cur) ? '已收藏 MV' : '已取消收藏');
      },
      icon: Icon(
        collected ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: collected
            ? Theme.of(context).colorScheme.primary
            : (light ? Colors.white70 : null),
        size: 24,
      ),
    );
  }

  /// 进度条：拖拽期间不跟随播放位置（避免回弹），松手 seek。
  Widget _buildProgressBar(BuildContext context, {required bool compact}) {
    return ValueListenableBuilder<Duration>(
      valueListenable: mvPlayer.positionListenable,
      builder: (context, pos, _) {
        final liveTotalMs = mvPlayer.duration.inMilliseconds;
        final liveValue = _dragging
            ? _dragValue
            : (liveTotalMs <= 0
                  ? 0.0
                  : (pos.inMilliseconds / liveTotalMs).clamp(0.0, 1.0));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: compact ? 3 : 4,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: compact ? 6 : 7,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveTrackColor: Colors.white.withValues(alpha: .28),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: liveValue,
                onChanged: liveTotalMs <= 0
                    ? null
                    : (v) {
                        setState(() {
                          _dragging = true;
                          _dragValue = v;
                        });
                        _showControls();
                      },
                onChangeEnd: (v) {
                  setState(() => _dragging = false);
                  final target = Duration(
                    milliseconds: (v * liveTotalMs).round(),
                  );
                  unawaited(mvPlayer.seek(target));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _dragging
                        ? formatDuration(
                            Duration(
                              milliseconds: (_dragValue * liveTotalMs).round(),
                            ),
                          )
                        : formatDuration(pos),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    formatDuration(mvPlayer.duration),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 控制行：播放模式 / 上一首 / 播放暂停 / 下一首 / 队列 / 横竖屏。
  ///
  /// 车机横屏档加大图标与触控目标（对齐歌曲侧 Controls 的车机档尺寸）。
  Widget _buildControlRow(BuildContext context, {required bool landscape}) {
    final colorScheme = Theme.of(context).colorScheme;
    final car = _isCarLandscape(context);
    final edgeIcon = car ? 32.0 : 26.0;
    final skipIcon = car ? 44.0 : 36.0;
    final target = car ? 64.0 : 48.0;

    Widget rowIcon({
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
      double? iconSize,
    }) {
      return SizedBox.square(
        dimension: target,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          icon: Icon(icon, color: colorScheme.primary, size: iconSize ?? edgeIcon),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        rowIcon(
          tooltip: _playbackModeLabel(mvPlayer.playbackMode),
          icon: _playbackModeIcon(mvPlayer.playbackMode),
          onPressed: () {
            mvPlayer.cyclePlaybackMode();
            Toast.info(_playbackModeLabel(mvPlayer.playbackMode));
          },
        ),
        rowIcon(
          tooltip: '上一个 MV',
          icon: Icons.skip_previous_rounded,
          iconSize: skipIcon,
          onPressed: () => unawaited(mvPlayer.previous()),
        ),
        if (!landscape)
          _CircleButton(
            icon: mvPlayer.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            size: car ? 76 : 60,
            filled: true,
            onPressed: () => unawaited(mvPlayer.togglePlay()),
            tooltip: mvPlayer.isPlaying ? '暂停' : '播放',
          ),
        rowIcon(
          tooltip: '下一个 MV',
          icon: Icons.skip_next_rounded,
          iconSize: skipIcon,
          onPressed: () => unawaited(mvPlayer.next()),
        ),
        SizedBox.square(
          dimension: target,
          child: IconButton(
            tooltip: 'MV 播放队列',
            onPressed: () => showMvQueueSheet(context, mvPlayer),
            padding: EdgeInsets.zero,
            icon: Badge(
              isLabelVisible: mvPlayer.queue.length > 1,
              label: Text('${mvPlayer.queue.length}'),
              child: Icon(Icons.queue_music_rounded, size: edgeIcon),
            ),
            color: colorScheme.primary,
          ),
        ),
        if (!landscape && !_isCarLandscape(context))
          IconButton(
            tooltip: '全屏播放',
            onPressed: _enterFullscreen,
            icon: Icon(
              Icons.fullscreen_rounded,
              color: colorScheme.primary,
              size: 26,
            ),
          ),
        if (landscape && !_isCarLandscape(context))
          IconButton(
            tooltip: '退出全屏',
            onPressed: _exitFullscreen,
            icon: Icon(
              Icons.fullscreen_exit_rounded,
              color: colorScheme.primary,
              size: 26,
            ),
          ),
      ],
    );
  }

  /// 竖屏底部的队列摘要/匹配进度提示（点按开队列面板）。
  Widget _buildQueueHint(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final index = mvPlayer.queueIndex;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => showMvQueueSheet(context, mvPlayer),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            if (mvPlayer.isResolvingQueue) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text(
                '正在匹配 MV…',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ] else
              Text(
                index >= 0 ? '播放列表 ${index + 1}/${mvPlayer.queue.length}' : '查看播放列表',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, String message) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                final cur = mvPlayer.currentMv;
                if (cur != null) {
                  unawaited(mvPlayer.playMv(cur, queue: mvPlayer.queue));
                }
              },
              child: const Text('重试'),
            ),
            TextButton(
              onPressed: () => unawaited(mvPlayer.next()),
              child: const Text('跳过'),
            ),
          ],
        ),
      ),
    );
  }

  void _hideControlsNow() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
  }
}

/// 车机横屏形态：屏幕物理横置，横竖屏切换按钮会造成方向错乱，隐藏。
bool _isCarLandscape(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height && ThemeController.instance.carModeEnabled;
}

String _playbackModeLabel(PlaybackMode mode) {
  switch (mode) {
    case PlaybackMode.playlistLoop:
      return '列表循环';
    case PlaybackMode.shuffle:
      return '随机播放';
    case PlaybackMode.singleLoop:
      return '单曲循环';
  }
}

IconData _playbackModeIcon(PlaybackMode mode) {
  switch (mode) {
    case PlaybackMode.playlistLoop:
      return Icons.repeat_rounded;
    case PlaybackMode.shuffle:
      return Icons.shuffle_rounded;
    case PlaybackMode.singleLoop:
      return Icons.repeat_one_rounded;
  }
}

/// 圆形控制按钮（覆盖层用，白色系）。
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onPressed,
    this.size = 48,
    this.filled = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? Colors.white.withValues(alpha: .94) : null,
        border: filled
            ? null
            : Border.all(color: Colors.white.withValues(alpha: .55), width: 1.5),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(
          icon,
          size: size * .58,
          color: filled ? Colors.black87 : Colors.white,
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 无 MV 时的空态。
class _EmptyMvView extends StatelessWidget {
  const _EmptyMvView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_video_rounded,
            size: 64,
            color: Colors.white.withValues(alpha: .3),
          ),
          const SizedBox(height: 12),
          const Text(
            '还没有正在播放的 MV',
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
          const SizedBox(height: 18),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('去搜索 MV'),
          ),
        ],
      ),
    );
  }
}
