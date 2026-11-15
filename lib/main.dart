import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:local_notifier/local_notifier.dart';

import 'config/app_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/mv_player_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client_interface.dart';
import 'core/rust_api_client.dart';
import 'services/app_log_service.dart';
import 'services/cache_service.dart';
import 'services/desktop_system_integration.dart';
import 'services/desktop_system_media.dart';
import 'services/device_info_service.dart';
import 'services/download_service.dart';
import 'services/image_disk_cache.dart';
import 'services/legacy_migration.dart';
import 'services/music_audio_handler.dart';
import 'services/music_api.dart';
import 'services/network_monitor.dart';
import 'services/voice_search_service.dart';
import 'models/music_models.dart';
import 'ui/adaptive_layout.dart';
import 'ui/desktop/desktop_tray.dart';
import 'ui/desktop/desktop_window.dart';
import 'ui/desktop/lyrics_overlay_window.dart';
import 'ui/app_theme.dart';
import 'ui/form_factor.dart';
import 'ui/pages/app_shell.dart';
import 'ui/pages/login_page.dart';
import 'ui/widgets/mv_mini_bar.dart';
import 'ui/widgets/song_action_sheets.dart' show likeFailureMessage;
import 'ui/widgets/toast.dart';

Future<void> main(List<String> args) async {
  // 【Windows/桌面宿主移动端界面调试】：
  // 若想在 Windows 调试时查看手机移动端界面，取消下面这行注释（或命令行传入 --dart-define=FORCE_MOBILE=true）。
  // 注意：此开关优先级最高且对所有构建生效，严禁以启用状态提交——
  // 否则 Windows/macOS/Linux 的桌面骨架会被整体静默禁用。
  // debugDesktopFormFactorOverride = false;

  // desktop_multi_window 子窗口（桌面歌词悬浮窗）入口分流：
  // 子窗口引擎会以 args=['multi_window', id, arguments] 重新执行 main()，
  // 必须最先识别并 return，严禁执行音频服务/主窗窗口管理等重量级初始化。
  if (isLyricsOverlayWindowArgs(args)) {
    await runLyricsOverlayWindow(args);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  // 落盘日志尽早接管 debugPrint：现有诊断（[shiyin][next]/SYNOTIF/代理错误）
  // 零改动同步落文件，用户侧偶发问题（曲末不跳、通知按钮失灵）事后才有
  // 现场可取证。接管同步先行、路径解析异步不阻塞——之前的启动日志先进
  // 内存缓冲，落盘就绪后随下一轮 flush 一并写入。
  unawaited(AppLogService.install());
  // 全局未捕获异步异常兜底：此前无任何 onError，异常只进控制台且 release
  // 下不可见。这里仅记录并标记已处理（返回 true），不改变既有降级行为。
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[易格][fatal] 未捕获异步异常: $error\n$stack');
    return true;
  };
  // 图片缓存策略：
  // - 移动端/车机（2-4GB RAM，内存必须克制）：沿用 200 张 / 64MB。封面经
  //   Artwork 解码后最大 600×600×4B ≈ 1.4MB/张，64MB 约可容纳 44 张满尺寸
  //   封面或数百张列表小图，对 2-4GB 设备约占内存 2~3%，且一屏铺开的封面
  //   数远低于该上限，命中率本来够用。
  // - 桌面端：宽窗一屏能铺开几百张封面（推荐页在桌面端把当天全部歌曲/歌单
  //   转成网格），沿用移动端上限会长期处于 LRU 淘汰状态——条目被淘汰后再次
  //   解析只能重新走网络，表现为"进出播放页后整页封面变白再逐张回来"。
  //   桌面内存充裕，单独放宽（Android 不读这一支，车机 RAM 零回归）。
  final cache = PaintingBinding.instance.imageCache;
  if (isDesktopFormFactor) {
    cache.maximumSize = AppConfig.desktopImageMemoryCacheMaxCount;
    cache.maximumSizeBytes = AppConfig.desktopImageMemoryCacheMaxBytes;
  } else {
    cache.maximumSize = AppConfig.imageMemoryCacheMaxCount;
    cache.maximumSizeBytes = AppConfig.imageMemoryCacheMaxBytes;
  }
  // 封面磁盘缓存：只占存储不占 RAM，作为内存淘汰/冷启动时的第二道保险。
  // configure 只登记上限（不做 IO），目录按需惰性创建、裁剪放到首帧之后，
  // 不拖慢冷启动。
  ImageDiskCache.instance.configure(
    isDesktopFormFactor
        ? AppConfig.desktopImageDiskCacheMaxBytes
        : AppConfig.imageDiskCacheMaxBytes,
  );
  // 旧标识（ka_music_* 键与目录、Windows com.example / Linux 旧 app id
  // 数据目录）→ shiyin_* 命名的一次性迁移。必须先于 RustApiClient.getInstance()
  // 与首次 SharedPreferences 访问：支持目录路径取决于 CompanyName/app id，
  // 迁移晚跑会把登录会话（kg_session.json）与旧键留在旧目录。
  // 迁移内部各阶段独立 try/catch，失败不阻断启动。
  await LegacyMigration.run();
  try {
    final client = await RustApiClient.getInstance();
    final api = MusicApi(client);

    // 桌面形态（Windows 等）：初始化窗口尺寸/最小尺寸/几何记忆。
    // 必须在 runApp 之前完成，避免首帧以错误尺寸渲染。
    await DesktopWindow.ensureInitialized();
    final themeController = ThemeController();
    await themeController.detectAutomotive(const DeviceInfoService());
    await themeController.load();

    final channelConfig = resolvePlaybackNotificationChannel(
      isCarMode: themeController.carModeEnabled,
      isAutomotiveDevice: themeController.isAutomotiveDevice,
    );
    debugPrint('[SYNOTIF] 通知渠道定向：channelId=${channelConfig.channelId} '
        'carModeEnabled=${themeController.carModeEnabled} '
        'isAutomotiveDevice=${themeController.isAutomotiveDevice}');

    // Windows：libmpv 解复用（demux）缓存 32MB→8MB，省 24MB/播放器常驻。
    // 音频码率 128~320kbps、FLAC 约 1Mbps，8MB 足够缓冲 60s 以上音频，
    // 弱网抗抖动不受影响；Linux 保持默认 32MB 不变（作为对照）。bufferSize
    // 是 static 字段，在首个播放器创建（MediaKitPlayer 构造）前生效，故
    // 置于 ensureInitialized() 之前。kIsWeb 前置：web 上访问 Platform.*
    // 会直接 throw。
    if (!kIsWeb && Platform.isWindows) {
      JustAudioMediaKit.bufferSize = 8 * 1024 * 1024;
    }
    // Linux/Windows 桌面：统一注册社区 media_kit(libmpv) 后端（见
    // pubspec.yaml 依赖注释；Windows 自 2026-09 起由 just_audio_windows
    // 迁移而来，记录见 docs/superpowers/specs/
    // 2026-09-11-windows-media-kit-migration-design.md）。必须在创建首个
    // AudioPlayer（AudioService.init → MusicAudioHandler 字段初始化）之前
    // 调用。kIsWeb 前置：web 上访问 Platform.* 会直接 throw（当前 web 构建
    // 因 dart:io 无法编译，此为防御性收敛，保持与 form_factor 判定同构）。
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
      // Windows 音量合成器/任务管理器里的进程显示名（mpv 原生侧使用，
      // Linux 忽略）；不设则显示默认的 "JustAudioMediaKit"。
      if (Platform.isWindows) JustAudioMediaKit.title = '易格音乐';
      JustAudioMediaKit.ensureInitialized();
    }

    // 桌面系统媒体集成：Windows SMTC（音量浮层/媒体键/锁屏控件）与
    // Linux MPRIS（GNOME/KDE 媒体控件/媒体键）。audio_service 在桌面默认
    // 走 NoOp 平台实现，这里替换为对应平台实现；必须在 AudioService.init
    // 之前调用（audio_service 的 _platform 懒初始化发生在 init 内）。
    // 平台实现初始化失败（无 D-Bus 等）内部已降级，不会阻断启动。
    registerDesktopSystemMediaPlatform();

    final audioHandler = await AudioService.init(
      // 车机形态不注入通知卡片自定义按钮（红心/桌面歌词）：车机通知渠道
      // 为静默渠道，且车机系统对会话自定义操作的渲染不可控，与通知渠道
      // 一样仅在启动时定向，运行时切换需重启进程。
      builder: () => MusicAudioHandler(
        enableNotificationActions: !(themeController.carModeEnabled ||
            themeController.isAutomotiveDevice),
      ),
      config: AudioServiceConfig(
        androidNotificationChannelId: channelConfig.channelId,
        androidNotificationChannelName: channelConfig.channelName,
        androidStopForegroundOnPause: false,
      ),
    );

    runApp(
      ShiyinApp(
        client: client,
        api: api,
        audioHandler: audioHandler,
        themeController: themeController,
      ),
    );
  } catch (error, stack) {
    // 启动初始化失败（最常见：Rust 引擎 dll/so 加载失败——被杀软隔离、
    // cargo 产物缺失、架构不符；其次窗口/音频服务初始化异常）。此前直接
    // 白屏/白窗且无任何提示。这里以最小依赖（纯 Flutter，不碰引擎）跑一个
    // 错误说明页，至少让用户知道要重装或检查杀软。
    debugPrint('[易格][fatal] 启动初始化失败: $error\n$stack');
    // 若关闭拦截已开启而托盘不会创建（Tray.init 在 ShiyinApp.initState），
    // 错误页点 X 会被藏进不存在的托盘，进程永久隐形。先解除拦截。
    await DesktopWindow.disableCloseInterception();
    _runStartupFailureApp(error);
  }
}

/// 启动失败兜底界面。
void _runStartupFailureApp(Object error) {
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(
                  '${AppConfig.appName} 启动失败',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '音频引擎初始化失败。可能是杀毒软件隔离了程序组件，'
                  '或安装文件不完整。请尝试重新安装；若反复出现，'
                  '请在杀毒软件中恢复并信任本程序的文件。',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  error.toString(),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ShiyinApp extends StatefulWidget {
  const ShiyinApp({
    super.key,
    required this.client,
    required this.api,
    required this.audioHandler,
    required this.themeController,
  });

  final ApiClientInterface client;
  final MusicApi api;
  final MusicAudioHandler audioHandler;
  final ThemeController themeController;

  @override
  State<ShiyinApp> createState() => _ShiyinAppState();
}

class _ShiyinAppState extends State<ShiyinApp> with WidgetsBindingObserver {
  late final ApiClientInterface _client;
  late final MusicApi _api;
  late final CacheService _cacheService;
  late final DownloadService _downloadService;
  late final DownloadController _downloads;
  late final AuthController _auth;
  late final PlayerController _player;
  late final ThemeController _theme;
  late final LocalMusicController _localMusic;
  late final MvPlayerController _mvPlayer;

  /// 主窗标题随播放（仅桌面形态创建并绑定）。
  DesktopWindowTitleBinder? _windowTitleBinder;

  /// 桌面歌词开关上一次广播到通知卡片的值：PlayerController 的
  /// notifyListeners 频繁（播放态/时长等），重广播一次 playbackState 是
  /// 平台通道调用，只在开关真正翻转时才刷。
  bool _lastNotifiedDesktopLyricsEnabled = false;

  /// 切歌时上一次广播到通知卡片的歌曲标识：红心图标跟随当前歌曲的收藏态，
  /// 切歌当刻即刷新，不等下一个播放事件；桌面歌词开关是全局态不受切歌影响。
  String? _lastNotifiedSongHash;

  /// 收藏/登录态变化（含收藏失败回滚）→ 刷新通知卡片红心图标。
  /// AuthController 通知频率低，无需按值去重。
  void _refreshNotificationButtons() {
    final song = _player.currentSong;
    debugPrint('[SYNOTIF] 收到 AuthController 变化，重广播播放状态：'
        'isLoggedIn=${_auth.isLoggedIn} hasSong=${song != null} '
        'canLike=${_auth.isLoggedIn && song != null} '
        'isLiked=${song != null && _auth.isLiked(song)}');
    widget.audioHandler.refreshPlaybackControls();
  }

  /// 播放器状态变化 → 桌面歌词翻转或切歌时刷新通知卡片按钮图标。
  /// 红心跟随当前歌曲的收藏态：已红心的歌切出来当刻就是实心，不会一直空心。
  void _onPlayerChangedForNotificationButtons() {
    final enabled = _player.desktopLyricsEnabled;
    final songHash = _player.currentSong?.hash;
    final lyricsFlipped = enabled != _lastNotifiedDesktopLyricsEnabled;
    final songChanged = songHash != _lastNotifiedSongHash;
    if (!lyricsFlipped && !songChanged) return;
    _lastNotifiedDesktopLyricsEnabled = enabled;
    _lastNotifiedSongHash = songHash;
    final song = _player.currentSong;
    debugPrint('[SYNOTIF] 通知按钮刷新：lyricsFlipped=$lyricsFlipped '
        'songChanged=$songChanged song=${song?.title} '
        'isLiked=${song != null && _auth.isLiked(song)} lyricsOn=$enabled');
    widget.audioHandler.refreshPlaybackControls();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _api = widget.api;
    _cacheService = CacheService();
    _downloadService = DownloadService();
    _downloads = DownloadController(_downloadService, _api);
    _auth = AuthController(_api, _cacheService);
    _localMusic = LocalMusicController();
    _player = PlayerController(_api, widget.audioHandler)
      ..downloadController = _downloads
      ..cacheService = _cacheService
      ..localMusic = _localMusic
      ..vipClaim = _auth.vipClaim;
    // MV 播放系统（与歌曲播放器平行）。双向互斥：MV 起播暂停歌曲、
    // 歌曲起播暂停 MV——两侧各持一个回调钩子，晚绑定避免构造顺序依赖。
    _mvPlayer = MvPlayerController(_api);
    _mvPlayer.onPauseSongPlayer = () => unawaited(_player.pause());
    _player.onPauseMvPlayer = () => unawaited(_mvPlayer.pause());
    // 「切换为音频」：MV 侧不持有 PlayerController（两套系统解耦），
    // 经回调把 MV 对应的歌曲交回歌曲播放器续播。
    _mvPlayer.onPlaySong = (song, queue, initialPosition) =>
        _player.playSong(song, queue: queue, initialPosition: initialPosition);
    // 在播保护：清理/裁剪播放缓存时跳过当前歌曲本地文件（删了播一半 404）。
    // 闭包惰性求值，_player 已赋值后才会被调用，无 late 空窗。
    _downloads.playingPathProvider = () {
      final cur = _player.currentSong;
      if (cur == null) return null;
      return _downloads.localPathForAnyQuality(cur);
    };
    // 通知卡片自定义按钮（收藏红心/桌面歌词开关）接线：AudioHandler 创建
    // 于 runApp 之前，此处晚绑定闭包（与 attachTransportControls 同构）。
    // 切歌时按钮随播放事件自动刷新；收藏/登录态与歌词开关分别经两个
    // 监听触发重广播，见 [_refreshNotificationButtons]。
    widget.audioHandler.attachNotificationActions(
      NotificationActionBridge(
        // 门控与 UI 红心入口（player_controls 等）对齐：登录 + 有歌 + kugou
        // 源 + 喜欢歌单已就绪。冷启动 restore 窗口内（会话已恢复、歌单尚未
        // 加载）likedPlaylist 为 null，toggleLike 会静默返回——此时按钮先
        // 不出现，restore 完成后 AuthController 的通知会把它刷出来，避免
        // 「点通知红心无任何反馈」的假死观感（本地/网易云歌曲 UI 一律不
        // 给红心，通知侧同样不给）。
        canToggleLike: () {
          final song = _player.currentSong;
          return _auth.isLoggedIn &&
              song != null &&
              song.source == SongSource.kugou &&
              _auth.likedPlaylist != null;
        },
        isCurrentSongLiked: () {
          final song = _player.currentSong;
          return song != null && _auth.isLiked(song);
        },
        onToggleLike: () async {
          final song = _player.currentSong;
          debugPrint('[SYNOTIF] 通知红心被点：song=${song?.title} '
              'beforeLiked=${song != null && _auth.isLiked(song)}');
          if (song != null) {
            try {
              await _auth.toggleLike(song);
            } catch (e) {
              // 已回滚（红心弹回）：给可读提示而非只打日志——用户点了却
              // 无任何反馈，体感像「取消红心不生效」回归。
              debugPrint('[SYNOTIF] 通知红心失败（已回滚）: $e');
              Toast.error(likeFailureMessage(e));
            }
          }
          debugPrint('[SYNOTIF] 通知红心处理结束：'
              'afterLiked=${song != null && _auth.isLiked(song)}');
        },
        desktopLyricsEnabled: () => _player.desktopLyricsEnabled,
        onToggleDesktopLyrics: _player.toggleDesktopLyricsFromNotification,
      ),
    );
    _lastNotifiedDesktopLyricsEnabled = _player.desktopLyricsEnabled;
    _lastNotifiedSongHash = _player.currentSong?.hash;
    // 语音点歌（系统助手/车机语音）：Android 侧冷启动 query 由原生暂存，
    // 这里 init 挂好回调并触发冲刷（ready）。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      VoiceSearchService.instance.init(
        onQuery: (query) => unawaited(_player.voiceSearchPlay(query)),
      );
    }
    _auth.addListener(_refreshNotificationButtons);
    _player.addListener(_onPlayerChangedForNotificationButtons);
    debugPrint('[SYNOTIF] 通知按钮桥接已注入：auth.isLoggedIn='
        '${_auth.isLoggedIn} currentSong=${_player.currentSong?.title} '
        'desktopLyricsEnabled=${_player.desktopLyricsEnabled}');
    unawaited(NetworkMonitor.instance.start());
    _theme = widget.themeController;
    _auth.restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloads.initialize();
      // 封面磁盘缓存的裁剪放到首帧之后：全量扫目录要读大量 stat，放在启动前
      // 会拖慢冷启动（车机 eMMC 尤其明显），首帧后再跑用户无感。
      unawaited(ImageDiskCache.instance.prune());
    });
    // Windows 桌面：托盘常驻（左键恒恢复并置前，右键菜单、退出）。
    if (isDesktopFormFactor) {
      // 退出统一走 DesktopWindow.quitGracefully（落盘几何 → 刷写状态 →
      // 终止进程）：引擎 teardown 在 IME/UIA 环境下必崩，托盘图标与桌面
      // 歌词子窗由 Shell/内核随进程死亡一并清理，不在 Dart 侧逐个拆除
      // （详见 DesktopWindow.quitGracefully 注释）。播放队列/当前曲目是
      // 500ms 防抖落盘，硬终止前必须立即刷写，否则快速切歌后退出会回退
      // 到上一首。
      DesktopWindow.registerPreQuitFlusher(_player.flushPlaybackState);
      // 落盘日志同队列刷写：quitGracefully 末尾硬终止进程，500ms 防抖
      // 缓冲来不及落地——诊断日志（曲末 watchdog 等）恰恰要在退出前留住。
      DesktopWindow.registerPreQuitFlusher(AppLogService.instance.flush);
      unawaited(DesktopTray.init(player: _player));
      // 桌面系统集成：下载完成通知 + 主窗标题随播放。
      // local_notifier 初始化失败时降级为无通知，不影响其余功能。
      unawaited(_initDesktopNotifications());
      _windowTitleBinder = DesktopWindowTitleBinder(
        titleOf: () => _player.currentSong?.title,
        artistOf: () => _player.currentSong?.artist,
      )..attach(_player);
    }
  }

  /// 桌面下载完成通知：初始化 local_notifier（通知点击把主窗带到前台）
  /// 并注入下载控制器；移动端/车机不进入本路径。
  Future<void> _initDesktopNotifications() async {
    try {
      await localNotifier.setup(appName: AppConfig.appName);
      _downloads.desktopNotifier = const LocalNotifierDownloadNotifier();
    } catch (error) {
      debugPrint('ShiyinApp: local_notifier 初始化失败，下载通知降级: $error');
    }
  }

  @override
  void dispose() {
    // 先摘除托盘，避免销毁中的控制器再被托盘菜单回调触发。
    unawaited(DesktopTray.dispose());
    // 解除标题监听，避免悬空回调触发 windowManager.setTitle。
    _windowTitleBinder?.detach();
    // 摘除通知卡片自定义按钮的桥接与监听，避免悬空调用已销毁控制器。
    widget.audioHandler.detachNotificationActions();
    _auth.removeListener(_refreshNotificationButtons);
    _player.removeListener(_onPlayerChangedForNotificationButtons);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(NetworkMonitor.instance.stop());
    // 注意：NetworkMonitor 是进程单例，其广播流不得在这里 dispose，
    // 否则流永久关闭（事件失聪、二次 dispose 抛错、widget 测试 flake）。
    // stop() 已取消订阅，足以释放资源。
    _auth.dispose();
    _mvPlayer.dispose();
    _player.dispose();
    _downloads.dispose();
    _localMusic.dispose();
    _downloadService.dispose();
    _client.close();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // 主题跟随系统（ThemeMode.system）：系统深浅色切换时同步主窗原生擦除
    // 底色，避免窗口最大化/缩放过渡边缘闪出旧主题色（ MaterialApp 内部
    // 自行响应亮度重建，这里无需 setState）。
    _syncWindowEraseBackground();
  }

  /// 主窗原生擦除底色与当前主题页面底色保持一致。
  ///
  /// 取值与 AppTheme 的 scaffoldBackgroundColor（非透明背景分支）一致：
  /// 深色 0xFF06070A / 浅色纯白。
  void _syncWindowEraseBackground() {
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    unawaited(
      DesktopWindow.syncEraseBackground(
        dark ? const Color(0xFF06070A) : Colors.white,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _mvPlayer.handleAppLifecycleState(state);
    switch (state) {
      // 桌面歌词不再监听前后台：Android（易格方案）开启即常显，
      // PC 本就与前后台无关。旧版 setAppForeground 前后台同步已随
      // "前台隐藏 + 回桌面自愈"机制一并移除。
      case AppLifecycleState.resumed:
      // inactive/hidden 是瞬时失焦（下拉通知栏、权限弹窗、分屏失焦等，
      // 应用仍可见），不做事。
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.paused:
        // 图片缓存内存保护（后台驻留时不长期占用大量解码位图）：
        // - 缓存量较小时保留，切后台再回前台不重新下载，避免反复加载；
        // - 缓存量较大（>24MB）才整体释放，兼顾车机有限内存与加载体感。
        // 不再调用 clearLiveImages()：它会把当前正在显示的图流也强制释放，
        // 回到前台时整屏重新解码/下载，是"切页后图片反复重下"的根源之一。
        if (PaintingBinding.instance.imageCache.currentSizeBytes > 24 << 20) {
          PaintingBinding.instance.imageCache.clear();
        }
      case AppLifecycleState.detached:
        // 进程结束前尽力把诊断日志落盘（best-effort，时序不保证）。
        unawaited(AppLogService.instance.flush());
    }
  }

  @override
  Widget build(BuildContext context) {
    _theme.applyOrientations(AdaptiveLayout.isTablet(context));
    // 启动时（及主题相关重建时）同步主窗原生擦除底色；内部同值去重。
    _syncWindowEraseBackground();
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) {
        return MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: Toast.navigatorKey,
          themeMode: ThemeMode.system,
          theme: AppTheme.light(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          darkTheme: AppTheme.dark(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          builder: (context, child) {
            // 全局字体大小（保留系统无障碍缩放）。
            final baseScale = MediaQuery.textScalerOf(context).scale(1.0);
            final textScaler = TextScaler.linear(baseScale * _theme.fontScale);
            Widget result = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: _AppBackground(
                themeController: _theme,
                child: _SystemUiOverlay(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
            // Windows 桌面 AXTree 竞态导致原生崩溃 / 无障碍树永久冻结
            // （accessibility_bridge.cc），整 app 排除语义树彻底规避。
            // Android/iOS 不受影响。
            //
            // 上游跟踪（2026-09 复核：均未修复，故 workaround 必须保留）：
            // - flutter/flutter#190357：pushed route 内的 Slider 会序列化孤儿
            //   语义节点，ui::AXTree 更新被拒后无障碍树**永久冻结**（读屏失效）。
            //   stable 3.44.8（本项目版本）与 master 3.47.0-pre 均可复现，
            //   尚无关联 PR。注意本项目设置页正是 "Navigator.push + Slider"
            //   组合——移除本 workaround 会直接命中该 bug。
            // - flutter/flutter#192180：无障碍 hit-test 空指针崩溃
            //   （FlutterPlatformNodeDelegateWindows::HitTestSync，0xC0000005）。
            // 代价：桌面端读屏用户无法访问播放页/歌曲列表（已知 tradeoff）；
            // 上游修复后应移除并回归无障碍测试。
            if (Platform.isWindows) {
              result = ExcludeSemantics(child: result);
            }
            // 全局 MV 迷你条：MV 在播且播放页不在前台时悬浮于底部，
            // 点击返回 MV 画面（MV 像歌曲一样可后台续播）。
            result = MvPlayerOverlayHost(mvPlayer: _mvPlayer, child: result);
            return result;
          },
          home: AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              if (!_auth.isRestoring && !_auth.isLoggedIn) {
                return LoginPage(auth: _auth, api: _api);
              }

              return AppShell(
                api: _api,
                auth: _auth,
                player: _player,
                cache: _cacheService,
                downloads: _downloads,
                theme: _theme,
                localMusic: _localMusic,
              );
            },
          ),
        );
      },
    );
  }
}

/// 全局背景图层。
///
/// 当用户启用了自定义背景图时，在所有页面内容下方显示背景图，
/// 并叠加半透明遮罩（由 [ThemeController.backgroundOpacity] 控制）。
class _AppBackground extends StatefulWidget {
  const _AppBackground({required this.themeController, required this.child});

  final ThemeController themeController;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  ImageProvider? _imageProvider;
  String? _cachedPath;

  @override
  void initState() {
    super.initState();
    widget.themeController.addListener(_onThemeChanged);
    _updateProvider();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheBackground();
    });
  }

  @override
  void didUpdateWidget(covariant _AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeController != widget.themeController) {
      oldWidget.themeController.removeListener(_onThemeChanged);
      widget.themeController.addListener(_onThemeChanged);
      _updateProvider();
      _precacheBackground();
    }
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    _updateProvider();
    _precacheBackground();
    setState(() {});
  }

  void _updateProvider() {
    final path = widget.themeController.backgroundImagePath;
    if (path != null && path != _cachedPath) {
      _cachedPath = path;
      _imageProvider = ResizeImage(
        FileImage(File(path)),
        width: 800,
        height: 800,
      );
    }
  }

  void _precacheBackground() {
    if (_imageProvider != null) {
      precacheImage(_imageProvider!, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.themeController.backgroundEnabled;
    final path = widget.themeController.backgroundImagePath;

    if (!enabled || path == null || _imageProvider == null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayColor = isDark ? const Color(0xFF06070A) : Colors.white;
    final opacity = widget.themeController.backgroundOpacity;

    return Stack(
      children: [
        // 背景图层（复用同一个 FileImage provider，避免重复解码）
        Positioned.fill(
          child: Image(
            image: _imageProvider!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩（opacity 越大遮罩越透明，背景图越明显）
        Positioned.fill(
          child: ColoredBox(
            color: overlayColor.withValues(alpha: 1.0 - opacity),
          ),
        ),
        // 页面内容
        widget.child,
      ],
    );
  }
}

class _SystemUiOverlay extends StatelessWidget {
  const _SystemUiOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: child,
    );
  }
}
