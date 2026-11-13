import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../widgets/app_feedback.dart' show friendlyServiceErrorMessage;
import '../widgets/app_section.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/app_version.dart';
import '../../models/music_models.dart';
import '../../services/app_update_service.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../form_factor.dart';
import '../widgets/app_update_widgets.dart';
import '../widgets/artwork.dart';
import '../widgets/cover_play_overlay.dart';
import '../widgets/home_collapsible_header.dart';
import '../widgets/home_song_row.dart';
import '../widgets/horizontal_wheel_scroll.dart';
import '../widgets/refresh_equalizer.dart';
import '../widgets/song_action_sheets.dart' show toggleLikeWithFeedback;
import '../widgets/swr_section_state.dart';
import '../widgets/toast.dart';
import '../player/song_tap_handler.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/local_music_controller.dart';
import 'playback_history_page.dart';
import 'rank_page.dart';
import 'recommended_playlists_page.dart';
import 'settings_page.dart';
import 'top_songs_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.theme,
    required this.downloads,
    required this.localMusic,
    this.sectionIndex = 0,
    this.onTabSwitch,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final ThemeController theme;
  final DownloadController downloads;
  final LocalMusicController localMusic;
  final int sectionIndex;
  final ValueChanged<int>? onTabSwitch;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends SwrSectionState<HomePage, HomeData>
    with TickerProviderStateMixin {
  static HomeData? _cachedData;
  static bool _hasAutoPlayed = false;

  final ScrollController _scrollController = ScrollController();
  // 非车机三 tab 内容列表各自的滚动控制器。顶栏（搜索栏 + 标签栏）是
  // 页面层固定组件（Stack 覆盖在 PageView 之上，见 build）：横向切页时
  // 顶栏纹丝不动，只有内容区随页面切换；顶栏收折进度由各 tab 的内容
  // 滚动 offset 派生（见 _updateHeaderShrink），不再需要 NestedScrollView
  // 外层 offset 镜像。
  final List<ScrollController> _tabControllers = List.generate(
    3,
    (_) => ScrollController(),
  );
  // 首页三 tab PageView 的跨形态搬运锚点：竖屏 ↔ 宽壳（平板侧栏/桌面）
  // 切换重构父链时，靠 GlobalKey 原样搬运整个滚动子树，避免
  // PageController/_tabControllers 在同一帧内附着新旧两套滚动视图
  // （'ScrollController attached to multiple scroll views'）。
  final GlobalKey<State<StatefulWidget>> _homeTabsPageViewHostKey =
      GlobalKey(debugLabel: 'home_tabs_page_view_host');
  // 顶栏收折进度（0 = 完全展开，_headerCollapseRange = 完全收折）：
  // 只驱动顶栏自身的重绘，切页/滚动都不触发整页 setState。
  final ValueNotifier<double> _headerShrink = ValueNotifier<double>(0.0);
  // 头部区间同步中的重入保护：把某个 tab 的头部进度镜像到其它 tab 时
  // 会触发它们的 listener 回调，用此标志避免递归同步。
  bool _syncingHeaderOffsets = false;
  // 各 tab 上一帧的内容 offset：静止态下顶栏跟手（floating）需要按
  // “本次 offset - 上次 offset”的增量驱动收折，而不是按绝对 offset，
  // 否则深滚时必须滑回顶部才能展开（见 _updateHeaderShrink）。
  final List<double> _prevTabOffsets = <double>[0.0, 0.0, 0.0];
  // 深滚时顶栏半收折的吸附动画（0<shrink<48 且 offset>48 时松手吸附到端点，
  // 只动顶栏不动内容）。滚动重新开始时取消，避免与跟手增量打架。
  AnimationController? _headerSnapController;
  // 移动端三 tab 自制下拉刷新的下拉距离（px）：顶部下拉时内容顶出空白并
  // 出现均衡器，松手达阈值触发对应页刷新。全程不用 Material 小圆圈，
  // 与桌面/车机/双击的均衡器反馈统一。下标 0/1/2 对应推荐/排行/电台。
  final List<ValueNotifier<double>> _pullExtents = <ValueNotifier<double>>[
    ValueNotifier<double>(0.0),
    ValueNotifier<double>(0.0),
    ValueNotifier<double>(0.0),
  ];
  // 下拉释放后的收合/吸附动画（同一时间只有一个 tab 在下拉，用单个控制器复用）。
  AnimationController? _pullAnimController;
  // 下拉触发的刷新在途保护：避免一次下拉重复触发、也避免下拉与双击刷新并发。
  final List<bool> _pullBusy = <bool>[false, false, false];

  /// 下拉触发阈值 / 最大下拉距离 / 刷新时指示器高度（均衡器 26px）。
  static const double _pullTriggerDistance = 60.0;
  static const double _pullMaxDistance = 90.0;
  static const double _pullRefreshHeight = 26.0;
  // 点按/外部切页的飞行目标：PageView 动画落定、onPageChanged 处理完之前，
  // 顶栏收折态冻结不变，落地页压到当前收折量防空白（见 _updateHeaderShrink）。
  // 手势滑动不需要它（落地时 page 与 _sectionIndex 不一致即可识别）。
  int? _switchTarget;

  /// 顶栏完全收折所需的滚动距离：等于 delegate 默认参数下
  /// maxExtent - minExtent = topMargin 8 + searchBarHeight 36 + spacing 8
  /// - pinnedTopOffset 4 = 48。
  /// 若调整 HomeCollapsibleHeaderDelegate 的默认尺寸需同步更新
  ///（home_collapsible_header_test.dart 也断言了该值）。
  static const double _headerCollapseRange = 48.0;
  // 排行榜 / 电台的刷新入口：双击首页按钮时调用（标题栏刷新按钮已移除）。
  final GlobalKey<RankPageState> _rankKey = GlobalKey<RankPageState>();
  final GlobalKey<_RadioSectionState> _radioKey =
      GlobalKey<_RadioSectionState>();

  late final AppUpdateService _updateService;
  AppVersionInfo? _availableUpdate;
  var _sectionIndex = 0;
  var _updateBannerDismissed = false;
  var _autoUpdateDialogShown = false;
  late PageController _pageController;
  // 车机/竖屏形态切换记忆：车机模式下 PageView 离树，PageController 会丢失
  // 当前页（重建时回退到 initialPage=0 即推荐页）。记录上帧形态，
  // 车机切回竖屏时用 _sectionIndex 重建控制器，保证回到对应 tab。
  bool? _lastIsCarMode;

  @override
  void initState() {
    super.initState();
    _sectionIndex = widget.sectionIndex;
    _pageController = PageController(initialPage: _sectionIndex);
    _pageController.addListener(_updateHeaderShrink);
    for (final controller in _tabControllers) {
      controller.addListener(_updateHeaderShrink);
    }
    _updateService = AppUpdateService();
    widget.auth.addListener(_handleAuthChanged);
    if (AppUpdateService.isSupportedPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdates());
    }
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sectionIndex != widget.sectionIndex) {
      // 外部切换 tab（如侧栏/底部导航）：移动端保持顶栏三 tab 统一行动主体，
      // 先对齐目标页头部；桌面端无吸顶头，跳过对齐避免引入偏移。
      if (!isDesktopFormFactor) {
        _alignTabToShrink(
          widget.sectionIndex,
          _headerShrink.value.clamp(0.0, _headerCollapseRange),
        );
      }
      _sectionIndex = widget.sectionIndex;
      if (_pageController.hasClients &&
          _pageController.page?.round() != widget.sectionIndex) {
        _switchTarget = widget.sectionIndex;
        _pageController.animateToPage(
          widget.sectionIndex,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _headerSnapController?.dispose();
    _pullAnimController?.dispose();
    for (final pull in _pullExtents) {
      pull.dispose();
    }
    _pageController.dispose();
    _scrollController.dispose();
    for (final controller in _tabControllers) {
      controller.dispose();
    }
    _headerShrink.dispose();
    widget.auth.removeListener(_handleAuthChanged);
    super.dispose();
  }

  /// 车机/竖屏形态切换时同步 PageView 到 [_sectionIndex]。
  ///
  /// 根因：竖屏三 tab 靠 PageView + PageController 承载，车机模式下
  /// PageView 离树（改用单 CustomScrollView + _PersistentTabPane），
  /// controller 失活；切回竖屏时新 PageView 会用创建时的 initialPage
  ///（多为 0=推荐）重建，而不是当前 [_sectionIndex]（如 1=排行榜），
  /// 于是从排行榜进车机再缩回会闪回推荐页。
  /// 此处在车机→竖屏的首帧同步重建控制器（无闪烁），已挂载的极端
  /// 情况降级为 post-frame jumpToPage。
  void _syncPageControllerForMode(bool isCarMode) {
    if (_lastIsCarMode == null) {
      _lastIsCarMode = isCarMode;
      return;
    }
    if (_lastIsCarMode == isCarMode) return;
    final wasCarMode = _lastIsCarMode!;
    _lastIsCarMode = isCarMode;
    // 仅处理车机→竖屏：竖屏→车机时 PageView 即将离树，无需动 controller。
    if (!wasCarMode || isCarMode) return;
    if (!_pageController.hasClients &&
        _pageController.initialPage != _sectionIndex) {
      // 首帧同步重建：新 PageView 直接落在对应 tab，无“推荐闪一下”；
      // 旧 controller 无挂载，dispose 安全。
      _pageController.dispose();
      _pageController = PageController(initialPage: _sectionIndex);
      _pageController.addListener(_updateHeaderShrink);
      // 旧 controller 上的切页飞行已随销毁终止，飞行目标一并作废，
      // 否则残留标记会在切回竖屏后一直把落地分支顶在地板高度。
      _switchTarget = null;
      return;
    }
    final target = _sectionIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients &&
          _pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  /// 由当前 tab 的内容滚动增量驱动顶栏收折进度（floating 跟手语义）。
  ///
  /// 顶栏是页面层固定组件，不再随 PageView 横向平移，是三个 tab 共用的
  /// 同一个行动主体：收折态全局统一，切页不重置——推荐页下滑收起搜索框
  /// 后切到排行榜/电台时搜索框保持收起，反之亦然。
  ///
  /// 规则（对齐 QQ 音乐 / 网易云等常用软件）：
  /// - 静止单页内：顶栏跟手增量驱动——下滑（offset 增大）等量收起，
  ///   上滑（offset 减小）等量展开。上滑 48px 即可完全展开，无需回到顶部；
  ///   下滑 48px 再次完全收起。深滚中途同样生效。
  /// - 为避免内容与顶栏之间出现空白，恒保持 shrink <= offset：
  ///   顶部 offset=0 时顶栏强制完全展开。
  /// - 切页途中（点按动画/手势滑动）与刚落地时：顶栏收折态冻结不变，
  ///   切 tab 与顶栏展示互不影响——展开就保持展开、收起就保持收起
  ///   （旧逻辑按相邻页 offset 插值联动，深滚页会把展开态顶栏拽关，
  ///   用户没滚动却看到搜索框消失）。内容侧只做防空白对齐：非中心页/
  ///   落地页被压到当前收折量（收起态下内容停在顶部会露出空白带），
  ///   深滚页不动（offset 已大于收折量，无空白）。
  /// 任一 tab 滚动或 PageView 翻页都会触发本函数（listener），只更新
  /// ValueNotifier，不 setState（镜像 jumpTo 期间用 [_syncingHeaderOffsets]
  /// 防重入；[_prevTabOffsets] 记录各 tab 上一帧 offset 用于求增量）。
  void _updateHeaderShrink() {
    if (!mounted || _syncingHeaderOffsets) return;
    // 桌面端无移动端吸顶头（搜索+胶囊 tab 已上移顶栏/侧栏）：收折进度恒为 0，
    // 且不再做跨 tab 的地板对齐，避免把内容推到 48px 偏移。
    if (isDesktopFormFactor) {
      if (_headerShrink.value != 0.0) _headerShrink.value = 0.0;
      return;
    }
    var page = _sectionIndex.toDouble();
    if (_pageController.hasClients &&
        _pageController.position.haveDimensions) {
      page = (_pageController.page ?? page).clamp(0.0, 2.0);
    }
    final i = page.floor().clamp(0, 2);
    final j = (i + 1).clamp(0, 2);

    void rememberOffsets() {
      for (var k = 0; k < _tabControllers.length; k++) {
        final controller = _tabControllers[k];
        if (controller.hasClients) {
          try {
            _prevTabOffsets[k] = controller.offset;
          } catch (_) {
            // 布局未就绪时保持旧值，下一帧继续对齐。
          }
        }
      }
    }

    final settled = (page - page.round()).abs() < 0.02;
    if (!settled) {
      // 切页飞行中：顶栏收折态冻结——切 tab 本身不改变顶栏展示。只把
      // 非中心页压到当前收折量，防止收起态下飞行途中露出空白带。
      final dominant = page.round().clamp(0, 2);
      final keep = _headerShrink.value;
      if (i != dominant) _alignTabToShrink(i, keep);
      if (j != dominant) _alignTabToShrink(j, keep);
      rememberOffsets();
      return;
    }
    final arrived = page.round().clamp(0, 2);
    if (_switchTarget != null &&
        arrived != _switchTarget &&
        arrived == _sectionIndex) {
      // 飞行被打断后停在了别的页：点按目标永远不会到达，作废飞行标记。
      // 否则残留标记让下方落地分支永久生效，落地页被一直 jumpTo 顶在
      // 地板高度，用户上滑展不开顶栏（正常落地由 _alignTargetPostFrame 清）。
      _switchTarget = null;
    }
    if (arrived != _sectionIndex || _switchTarget != null) {
      // 刚落地、状态还没对齐（手势 index 滞后 / 点按目标刚挂载还顶着 0）：
      // 只把落地页压到当前收折量（防收起态空白），顶栏保持不变。
      _alignTabToShrink(arrived, _headerShrink.value);
      rememberOffsets();
      return;
    }
    // 静止单页：跟手增量驱动顶栏（floating），深滚同样上滑即现。
    final controller = _tabControllers[arrived];
    if (!controller.hasClients) {
      rememberOffsets();
      return;
    }
    double currentOffset;
    try {
      currentOffset = controller.offset;
    } catch (_) {
      return;
    }
    final prevOffset = _prevTabOffsets[arrived];
    final delta = currentOffset - prevOffset;
    _prevTabOffsets[arrived] = currentOffset;
    // 其它 tab 的记忆同步刷新，避免切页后用陈旧值算出跳变增量。
    for (var k = 0; k < _tabControllers.length; k++) {
      if (k == arrived) continue;
      final other = _tabControllers[k];
      if (other.hasClients) {
        try {
          _prevTabOffsets[k] = other.offset;
        } catch (_) {}
      }
    }
    if (delta.abs() < 0.01) return;
    // 用户重新开始滚动：取消深滚吸附动画，避免打架。
    _cancelHeaderSnap();
    var next = (_headerShrink.value + delta).clamp(0.0, _headerCollapseRange);
    // 防空白钳制：顶栏高度不能超过内容已滚走的距离。
    final ceiling = currentOffset.clamp(0.0, _headerCollapseRange);
    if (next > ceiling) next = ceiling;
    if (currentOffset <= 0.5) next = 0.0;
    if ((_headerShrink.value - next).abs() > 0.1) {
      _headerShrink.value = next;
    }
    // 浅区其它页只许往上推到地板（防切页空白），不往下拉（保留各自进度）；
    // 深滚页不动。
    if (delta > 0) {
      _syncingHeaderOffsets = true;
      try {
        for (var k = 0; k < _tabControllers.length; k++) {
          if (k == arrived) continue;
          final other = _tabControllers[k];
          if (!other.hasClients) continue;
          double otherOffset;
          try {
            otherOffset = other.offset;
          } catch (_) {
            continue;
          }
          if (otherOffset > _headerCollapseRange + 0.5) continue;
          if (otherOffset >= next - 0.5) continue;
          double min;
          double max;
          try {
            min = other.position.minScrollExtent;
            max = other.position.maxScrollExtent;
          } catch (_) {
            continue;
          }
          final target = next.clamp(min, max);
          if ((otherOffset - target).abs() <= 0.5) continue;
          // 内容不够高顶不到地板：不硬推，等数据撑高后由切页对齐处理。
          if (target < next - 0.5) continue;
          try {
            other.jumpTo(target);
            _prevTabOffsets[k] = target;
          } catch (_) {
            // 滚动中或布局未就绪时忽略，下次滚动/切页会再次对齐。
          }
        }
      } finally {
        _syncingHeaderOffsets = false;
      }
    }
  }

  /// 取消深滚顶栏吸附动画（用户重新滚动 / dispose 前调用）。
  void _cancelHeaderSnap() {
    final snap = _headerSnapController;
    if (snap != null) {
      _headerSnapController = null;
      try {
        snap.stop();
      } catch (_) {}
      snap.dispose();
    }
  }

  /// 深滚松手后顶栏半收折时吸附到最近端点（只动顶栏不动内容）。
  void _snapHeaderDeep() {
    if (!mounted) return;
    final current = _headerShrink.value;
    if (current <= 0.5 || current >= _headerCollapseRange - 0.5) return;
    _cancelHeaderSnap();
    final target = current < _headerCollapseRange / 2
        ? 0.0
        : _headerCollapseRange;
    final snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _headerSnapController = snap;
    final tween = Tween<double>(begin: current, end: target);
    snap.addListener(() {
      if (!mounted || _headerSnapController != snap) return;
      _headerShrink.value = tween.evaluate(snap);
    });
    snap.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (_headerSnapController == snap) _headerSnapController = null;
        snap.dispose();
      }
    });
    unawaited(snap.forward());
  }

  /// 取消下拉收合动画（用户重新开始下拉时调用，避免与跟手打架）。
  /// 会同步完成等待中的 [_animatePullTo]，避免 await 悬挂导致刷新不触发。
  Completer<void>? _pullAnimCompleter;

  void _cancelPullAnim() {
    final completer = _pullAnimCompleter;
    _pullAnimCompleter = null;
    final anim = _pullAnimController;
    _pullAnimController = null;
    if (anim != null) {
      try {
        anim.stop();
      } catch (_) {}
      anim.dispose();
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// 把指定 tab 的下拉距离动画到 [target]，完成后返回（可 await）。
  Future<void> _animatePullTo(int tabIndex, double target) {
    if (!mounted) {
      _pullExtents[tabIndex].value = target;
      return Future<void>.value();
    }
    _cancelPullAnim();
    final notifier = _pullExtents[tabIndex];
    final start = notifier.value;
    if ((start - target).abs() < 0.5) {
      notifier.value = target;
      return Future<void>.value();
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _pullAnimController = controller;
    final tween = Tween<double>(begin: start, end: target);
    controller.addListener(() {
      if (_pullAnimController != controller) return;
      notifier.value = tween.evaluate(controller);
    });
    final completer = Completer<void>();
    _pullAnimCompleter = completer;
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (_pullAnimController == controller) _pullAnimController = null;
        if (_pullAnimCompleter == completer) _pullAnimCompleter = null;
        controller.dispose();
        if (!completer.isCompleted) completer.complete();
      }
    });
    unawaited(controller.forward());
    return completer.future;
  }

  /// 下拉松手后的统一出口：达阈值触发对应页刷新并保持指示器，
  /// 未达阈值收合取消。桌面/车机不走这里（无下拉手势）。
  void _releasePull(int tabIndex, Future<void> Function() onRefresh) {
    final pull = _pullExtents[tabIndex].value;
    if (pull <= 0.5) return;
    if (_pullBusy[tabIndex]) {
      // 刷新在途中的新下拉：不重复触发，只把预览收合，避免卡住。
      unawaited(_animatePullTo(tabIndex, 0.0));
      return;
    }
    if (pull < _pullTriggerDistance) {
      // 未达阈值：收合取消。
      unawaited(_animatePullTo(tabIndex, 0.0));
      return;
    }
    _pullBusy[tabIndex] = true;
    if (tabIndex == 0) {
      // 推荐页：下拉指示器与刷新均衡器是同一个 widget，先把下拉吸附到
      // 刷新高度再起刷新，高度 70→26 有动画，不会“直接出现”。
      unawaited(() async {
        try {
          await _animatePullTo(tabIndex, _pullRefreshHeight);
          if (!mounted) return;
          // 吸附到位后再发请求：高度已是 26，刷新均衡器接管无跳变。
          await onRefresh();
        } finally {
          if (mounted) await _animatePullTo(tabIndex, 0.0);
          _pullBusy[tabIndex] = false;
        }
      }());
    } else {
      // 排行/电台：下拉预览收合的同时子页内部均衡器展开（都是 250ms 级），
      // 总高度单调 70→26，不会出现双均衡器叠出 52px。
      unawaited(_animatePullTo(tabIndex, 0.0));
      unawaited(() async {
        try {
          await onRefresh();
        } finally {
          _pullBusy[tabIndex] = false;
        }
      }());
    }
  }

  /// 落页 post-frame 对齐：等目标页懒加载挂载、内容撑高后再推到地板高度。
  ///
  /// 根因有两层：
  /// 1. PageView 的 onPageChanged 按四舍五入触发，跨页跳转（如推荐 0 →
  ///    电台 2）时 page≈1.5 就报了 2，此时电台页往往还没挂载对齐不上；
  /// 2. 电台首访先渲染骨架屏（内容矮、maxScrollExtent 很小），对齐会被
  ///    钳到 0 附近，看起来“成功”了，但真数据把内容撑高后仍顶着 0。
  /// 因此没真正对上就下一帧重试（pending 的回调不生产新帧，不会空转；
  /// 有上限，超限后回落到内容真实高度），只在成功对齐后清 [_switchTarget]。
  void _alignTargetPostFrame(int index, int attemptsLeft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_tryAlignTabToShrink(
        index,
        _headerShrink.value.clamp(0.0, _headerCollapseRange),
      )) {
        if (_switchTarget == index) _switchTarget = null;
      } else if (attemptsLeft > 0) {
        _alignTargetPostFrame(index, attemptsLeft - 1);
      } else {
        // 一直没对上（内容本身就比头部区间矮，滚不上去）：清掉标记，
        // 并把顶栏收起量直接压到该页真实滚动偏移。不能只调
        // _updateHeaderShrink 重算——其静态分支对静止页有 delta==0
        // 早退，防空白钳制永远走不到，顶栏会卡在收起态留出空白带。
        if (_switchTarget == index) _switchTarget = null;
        _clampHeaderShrinkToTab(index);
      }
    });
  }

  /// 把顶栏收起量下压到 [index] 页当前滚动偏移（防空白钳制的直接版）。
  ///
  /// 收起量不得超过该页已滚走的距离：目标页内容比头部区间矮、永远滚
  /// 不到地板高度时（如空态/错误态的电台页），顶栏若停在收起态会和
  /// 未滚到位的内容之间留出一条空白带。
  void _clampHeaderShrinkToTab(int index) {
    if (index < 0 || index >= _tabControllers.length) return;
    final controller = _tabControllers[index];
    if (!controller.hasClients) return;
    double offset;
    try {
      offset = controller.offset;
    } catch (_) {
      return;
    }
    final ceiling = offset.clamp(0.0, _headerCollapseRange);
    if (_headerShrink.value > ceiling + 0.1) {
      _headerShrink.value = ceiling;
    }
  }

  /// 尝试把目标 tab 的头部进度推高到 [shrink]，返回是否已落定无需重试。
  ///
  /// - 未挂载、还没 layout（无 dimensions）、内容仍是骨架（max 顶不到
  ///   shrink）：返回 false，调用方下一帧重试。
  /// - 已在地板高度或深滚（保留内容进度）：返回 true。
  bool _tryAlignTabToShrink(int index, double shrink) {
    if (index < 0 || index >= _tabControllers.length) return true;
    final controller = _tabControllers[index];
    if (!controller.hasClients) {
      return false;
    }
    if (controller.offset > _headerCollapseRange + 0.5) return true;
    if (controller.offset >= shrink - 0.5) return true;
    double min;
    double max;
    try {
      min = controller.position.minScrollExtent;
      max = controller.position.maxScrollExtent;
    } catch (_) {
      // 还没 layout，读不到滚动范围，下一帧重试。
      return false;
    }
    final target = shrink.clamp(min, max);
    // 内容还不够高顶不到地板（如骨架屏）：不是“对上了”，继续等数据。
    // 注意判在前：骨架态 target 会被钳到 offset 附近，先判差值会误判落定。
    if (target < shrink - 0.5) return false;
    if ((controller.offset - target).abs() <= 0.5) return true;
    _syncingHeaderOffsets = true;
    try {
      controller.jumpTo(target);
      _prevTabOffsets[index] = target;
    } catch (_) {
      return false;
    } finally {
      _syncingHeaderOffsets = false;
    }
    return true;
  }
  /// 把目标 tab 的头部进度至少推高到 [shrink]（深滚不动）。
  ///
  /// 用于切页前/切页后对齐：目标还在头部区间顶部（如 offset 0）而顶栏
  /// 已收起时，把它推到与顶栏一致的位置，避免切页后搜索框突然冒出来。
  void _alignTabToShrink(int index, double shrink) {
    if (index < 0 || index >= _tabControllers.length) return;
    final controller = _tabControllers[index];
    if (!controller.hasClients) return;
    if (controller.offset > _headerCollapseRange + 0.5) return;
    if (controller.offset >= shrink - 0.5) return;
    double min;
    double max;
    try {
      min = controller.position.minScrollExtent;
      max = controller.position.maxScrollExtent;
    } catch (_) {
      // 还没 layout，读不到滚动范围：跳过，动画中的后续帧会继续对齐。
      return;
    }
    final target = shrink.clamp(min, max);
    if ((controller.offset - target).abs() <= 0.5) return;
    _syncingHeaderOffsets = true;
    try {
      controller.jumpTo(target);
      _prevTabOffsets[index] = target;
    } catch (_) {
      // 滚动中或布局未就绪时忽略，动画中的后续帧会继续对齐。
    } finally {
      _syncingHeaderOffsets = false;
    }
  }

  /// 当前子 tab 对应的刷新入口：双击首页与桌面头部刷新按钮共用同一语义。
  Future<void> _refreshCurrentSection() {
    return switch (_sectionIndex) {
      1 => _rankKey.currentState?.refresh() ?? Future<void>.value(),
      2 => _radioKey.currentState?.refresh() ?? Future<void>.value(),
      _ => refresh(),
    };
  }

  /// 判定滚动的阈值（px）：超过即认为用户已在本页下滑。
  static const double _tapRefreshScrollThreshold = 8.0;

  /// 顶部胶囊 tab 点击：点到其它 tab 只切换（各 tab 内容状态靠 KeepAlive
  /// 保留，不刷新）；点中当前 tab 则无条件回顶刷新（含顶部均衡器动画）。
  void _handleSectionTap(int value, {required bool animatePage}) {
    if (value == _sectionIndex) {
      unawaited(scrollToTopAndRefresh());
      return;
    }
    // 切页前先把目标页头部对齐到当前顶栏收折态（仅移动端）：顶栏是三 tab 共用的
    // 同一个行动主体，收起/展开切页不重置。深滚的目标页不动。
    // 桌面端无吸顶头，跳过对齐。未懒加载的目标页此处对齐不上（无挂载），
    // 靠 _switchTarget 在飞行途中/落定帧继续对齐（顶栏只收不展）。
    if (!isDesktopFormFactor) {
      _alignTabToShrink(
        value,
        _headerShrink.value.clamp(0.0, _headerCollapseRange),
      );
    }
    setState(() => _sectionIndex = value);
    widget.onTabSwitch?.call(value + 1);
    if (animatePage && _pageController.hasClients) {
      // 真正起飞才挂飞行标记（车机 animatePage=false 不走 PageView，
      // 挂了就没人清，会一直卡在落定分支）。
      _switchTarget = value;
      _pageController.animateToPage(
        value,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 双击底部首页按钮：回到当前 tab 顶部并且刷新对应内容。
  /// 推荐 tab 刷新推荐流，排行榜 / 电台 tab 刷新各自内容（标题栏刷新按钮已移除，
  /// 统一收敛到这里）。车机顶栏点中当前 tab 同样走这里（含均衡器动画）。
  /// 回顶并刷新对应内容。移动端（双击首页按钮/点中当前 tab）先回顶后刷新；
  /// 桌面侧栏双击传 [refreshInParallel]：立即起刷新让均衡器当帧出现，
  /// 回顶动画并行进行，不等滚动完成。
  Future<void> scrollToTopAndRefresh({bool refreshInParallel = false}) async {
    // 用户显式要求回顶：作废未完成的点按飞行对齐，避免落地帧把本页
    // 又推回顶栏地板高度（飞行中重按目标 tab / 对齐重试未完时双击）。
    _switchTarget = null;
    final size = MediaQuery.sizeOf(context);
    final isCarMode =
        size.width > size.height && ThemeController.instance.carModeEnabled;
    if (refreshInParallel) {
      unawaited(_refreshCurrentSection());
    }
    if (isCarMode) {
      // 车机单滚动容器：直接回顶。
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    } else {
      // 内容回顶；顶栏收折进度由内容 offset 派生，随动画自动展开。
      final controller = _tabControllers[_sectionIndex];
      if (controller.hasClients) {
        try {
          await controller.animateTo(
            0.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        } catch (_) {
          // 滚动中页面已销毁时忽略。
        }
      }
    }
    if (!mounted) return;
    if (!refreshInParallel) {
      await _refreshCurrentSection();
    }
  }

  /// 车机模式是否已滚动（单滚动容器偏离顶部即算）。
  /// 供车机顶栏点中当前 tab 时判断，未滚动则什么都不做。
  bool get isCarScrolled {
    if (!mounted) return false;
    return _scrollController.hasClients &&
        _scrollController.offset > _tapRefreshScrollThreshold;
  }

  void _handleAuthChanged() {
    if (widget.auth.isRestoring || !widget.auth.isLoggedIn) {
      return;
    }
    // 首次加载（无缓存）或 auth 恢复完成后触发加载（已有数据则基类忽略）。
    loadIfNeverLoaded();
  }

  void _checkAndAutoPlay(HomeData data) {
    if (!widget.player.autoPlayOnStartupEnabled || _hasAutoPlayed) return;

    final hasRestored = widget.player.hasRestoredPlaybackState;
    final songs = data.daily.songs;
    // 数据未就绪（无恢复状态且每日推荐为空，如上次会话接口失败留下的
    // 缓存）时不消费本次机会，等后续网络数据到达再触发。
    if (!hasRestored && songs.isEmpty) return;
    _hasAutoPlayed = true;

    // 必须推迟到首帧构建完成后执行：_checkAndAutoPlay 会在 initState
    // 阶段被同步调用，此时直接调用 playSong 会触发 notifyListeners()，
    // 违反 Flutter "build 阶段不能触发 setState/notifyListeners" 规则。
    // 叠加 Windows 平台 just_audio 的 WinRT MediaPlayer COM 线程在应用
    // 启动早期尚未完全就绪，立即 setUrl()/play() 会与 UI 渲染竞争，
    // 导致 "Lost connection to device" 进程崩溃。
    // Windows 上额外延迟 300ms 让 native 层完全稳定后再启动播放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final delay = defaultTargetPlatform == TargetPlatform.windows
          ? const Duration(milliseconds: 300)
          : Duration.zero;
      Future<void>.delayed(delay, () async {
        if (!mounted) return;
        // 先等两路启动恢复（settings/播放状态）收尾再消费：冷启动磁盘
        // 繁忙时 prefs 首次加载可能慢于首帧，若每日推荐先起播、
        // _restorePlaybackState 晚到，恢复会用上次队列整队覆盖在播会话，
        // 在途起播或曲末切歌被「已切歌」守卫放弃——表现为开机自启播完
        // 第一首就停在曲尾不再前进。
        await widget.player.startupRestored;
        if (!mounted) return;
        // 消费时刻才读 startupPlaySource：_restoreSettings 是构造函数
        // unawaited 发起的异步恢复，_checkAndAutoPlay 触发时可能尚未
        // 落地；await startupRestored 后 prefs 必然恢复完成。
        final preferDaily = widget.player.startupPlaySource == 'daily';
        if (songs.isNotEmpty && (preferDaily || !hasRestored)) {
          // 上次保存的队列与本次每日推荐逐位一致（同日内重启 APP/开机
          // 自启的常见场景）：继续播上次播到的歌，不回第一首重头播。
          // 一致性必须消费时刻读：queue/hasRestoredPlaybackState 由
          // await 过的启动恢复落定，守卫时刻捕获的可能是恢复前的空值。
          final continueDaily =
              preferDaily &&
              widget.player.hasRestoredPlaybackState &&
              _queueMatchesDaily(widget.player.queue, songs);
          if (continueDaily) {
            widget.player.resumePlayback();
          } else {
            // 每日推荐替换整个队列；preferDaily 但推荐为空（如未登录且
            // 缓存无数据）时回退继续播放。
            widget.player.playSong(songs.first, queue: songs);
          }
        } else {
          widget.player.resumePlayback();
        }
      });
    });
  }

  /// 上次保存的播放队列是否与本次每日推荐逐位一致（等长且同序同 hash）。
  ///
  /// 一致说明上次会话播的就是这份推荐列表（同日内重启 APP / 开机自启），
  /// 开机播放内容选「每日推荐」时应从上次的当前歌继续而不是回第一首；
  /// 跨天推荐已刷新、用户后来播了别的歌单都会导致不一致，仍整队重播。
  /// 注：播放状态最多持久化 200 首（_playbackStateMaxQueueSize），推荐
  /// 列表超长被截断时必然判不一致，回退重头播，可接受。
  bool _queueMatchesDaily(List<Song> restoredQueue, List<Song> dailySongs) {
    if (restoredQueue.length != dailySongs.length) return false;
    for (var i = 0; i < dailySongs.length; i++) {
      if (restoredQueue[i].hash != dailySongs[i].hash) return false;
    }
    return true;
  }

  /// 新歌速递失败时返回空列表，不阻塞首页其他板块。
  Future<List<Song>> _loadTopSongsSafe() async {
    try {
      return await widget.api.topSongs();
    } catch (_) {
      return const [];
    }
  }

  // ---------------- SWR 数据钩子（骨架见 SwrSectionState） ----------------

  @override
  CacheService get cache => widget.cache;

  @override
  HomeData? get cachedData => _cachedData;

  @override
  set cachedData(HomeData? value) => _cachedData = value;

  @override
  String get cacheKey => 'cache_home';

  @override
  Duration get cacheTtl => AppConfig.homeCacheTtl;

  @override
  HomeData decodeCache(Map<String, dynamic> json) {
    return HomeData(
      daily: DailyRecommend.fromCache(json['daily'] as Map<String, dynamic>),
      playlists: (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistSummary.fromCache)
          .toList(),
      topSongs: (json['topSongs'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }

  @override
  Map<String, dynamic> encodeCache(HomeData data) => {
        'daily': data.daily.toCache(),
        'playlists': data.playlists.map((p) => p.toCache()).toList(),
        'topSongs': data.topSongs.map((song) => song.toCache()).toList(),
      };

  /// 三个板块是否至少有一个非空：全空说明多半是接口异常的静默空数据，
  /// 不应写入/覆盖内存与磁盘缓存。
  @override
  bool hasContent(HomeData data) =>
      data.daily.songs.isNotEmpty ||
      data.playlists.isNotEmpty ||
      data.topSongs.isNotEmpty;

  @override
  Future<HomeData> fetchData() async {
    final results = await Future.wait([
      widget.api.dailyRecommend(),
      widget.api.recommendedPlaylists(),
      _loadTopSongsSafe(),
    ]);
    return HomeData(
      daily: results[0] as DailyRecommend,
      playlists: results[1] as List<PlaylistSummary>,
      topSongs: results[2] as List<Song>,
    );
  }

  @override
  void onDataArrived(HomeData data) => _checkAndAutoPlay(data);

  Future<void> _checkForUpdates() async {
    try {
      final version = await _updateService.checkForUpdate();
      if (!mounted || version == null) {
        return;
      }

      if (version.forceUpdate) {
        if (_autoUpdateDialogShown) {
          return;
        }
        _autoUpdateDialogShown = true;
        await showAppUpdateDialog(
          context: context,
          service: _updateService,
          version: version,
          force: true,
        );
        return;
      }

      if (!_updateBannerDismissed) {
        setState(() => _availableUpdate = version);
      }
    } catch (_) {
      // The automatic check should stay quiet; manual checks surface errors.
    }
  }

  Future<void> _showUpdateDetails() {
    final version = _availableUpdate;
    if (version == null) {
      return Future.value();
    }
    return showAppUpdateDialog(
      context: context,
      service: _updateService,
      version: version,
      force: false,
    );
  }

  void _openPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  Future<void> _playPlaylist(PlaylistSummary playlist) async {
    try {
      final fullCacheKey = 'playlist_full_${playlist.id}';
      final cached = await widget.cache.read<Map<String, dynamic>>(
        fullCacheKey,
        decode: (j) => j,
        ttl: AppConfig.playlistDetailTtl,
      );
      List<Song> songs = const [];
      if (cached != null && cached.data['songs'] is List) {
        songs = (cached.data['songs'] as List)
            .whereType<Map<String, dynamic>>()
            .map(Song.fromCache)
            .where((s) => s.hash.isNotEmpty)
            .toList();
      }
      if (songs.isEmpty) {
        Toast.info('正在获取歌单曲目…');
        songs = await widget.api.playlistSongs(
          playlist.id,
          page: 1,
          pageSize: 60,
        );
      }
      if (!mounted) return;
      if (songs.isNotEmpty) {
        widget.player.playSong(songs.first, queue: List<Song>.of(songs));
        Toast.show('正在播放歌单：${playlist.title}', type: ToastType.success);
      } else {
        Toast.error('歌单暂无可播放曲目');
      }
    } catch (_) {
      if (mounted) {
        Toast.error('播放失败，请稍后重试');
      }
    }
  }

  void _openDailyRecommend(DailyRecommend daily) {
    final playlist = PlaylistSummary(
      id: 'daily_recommend',
      title: '猜你喜欢',
      subtitle: daily.subtitle ?? '根据你的听歌偏好，每日精心推荐',
      coverUrl: daily.coverUrl ??
          (daily.songs.isNotEmpty ? daily.songs.first.coverUrl : null),
      songCount: daily.songs.length,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
          initialSongs: daily.songs,
        ),
      ),
    );
  }

  void _openRecommendedPlaylists(List<PlaylistSummary> playlists) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecommendedPlaylistsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          initialPlaylists: playlists,
        ),
      ),
    );
  }

  void _openTopSongs(List<Song> songs) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopSongsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          initialSongs: songs,
        ),
      ),
    );
  }

  void _playSong(Song song, List<Song> queue) {
    // 点到当前歌：打开播放页，绝不重头播放（主流移动端一致行为）。
    if (openPlayerIfSameSong(
      context,
      player: widget.player,
      auth: widget.auth,
      song: song,
    )) {
      return;
    }
    widget.player.playSong(song, queue: queue);
  }

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  // ignore: unused_element
  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          theme: widget.theme,
          downloads: widget.downloads,
          cache: widget.cache,
          localMusic: widget.localMusic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HomeData>(
      future: sectionFuture,
      builder: (context, snapshot) {
        final data = snapshot.data ?? _cachedData;
        // 桌面端：无下拉刷新手势（PC 无此惯例），滚动物理用桌面常规；
        // 数据重载入口改为页头刷新按钮（复用 refresh 同一逻辑）。
        // 移动端：三 tab 各自 RefreshIndicator + AlwaysScrollable（见 tabScrollView）。
        // 车机端：无 RefreshIndicator 小圆圈，刷新统一走顶栏点中当前 tab，
        // 反馈与移动端一致用顶部均衡器动画（RefreshEqualizer）。
        final isDesktop = isDesktopFormFactor;
        final size = MediaQuery.sizeOf(context);
        final topPadding = MediaQuery.paddingOf(context).top;
        final isLandscape = size.width > size.height;
        final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;
        // 平板形态：移动形态宽屏（触屏侧栏）下内容区走桌面式布局
        // （分区标题 + 无吸顶头——导航与搜索都提升到了左侧触屏侧栏）。
        // 与 AppShell 的侧栏阈值保持同源。
        final tabletShell = !isCarMode &&
            !isDesktop &&
            AdaptiveLayout.isTouchSidebarWidth(size.width);
        final wideShell = isDesktop || tabletShell;
        // 车机↔竖屏切换时把 PageView 对齐到当前子 tab，避免缩回时掉回推荐页。
        _syncPageControllerForMode(isCarMode);

        Widget content;
        if (data == null) {
          if (snapshot.hasError) {
            content = CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorView(
                    message: snapshot.error.toString(),
                    onRetry: refresh,
                  ),
                ),
              ],
            );
          } else {
            content = CustomScrollView(
              controller: _scrollController,
              slivers: const [SliverToBoxAdapter(child: _HomeSkeleton())],
            );
          }
        } else if (!isCarMode) {
          // 非车机：三 tab PageView 横向切换，只有下方内容区随页面切换。
          // 移动端顶栏（搜索栏 + 标签栏）是页面层固定组件：Stack 覆盖在 PageView
          // 之上，横向切页时顶栏纹丝不动，只有下方内容区随页面切换。
          // 桌面端无移动端吸顶头（搜索上移顶栏、切换走左侧栏），内容区顶部只放
          // slim 工具条（标题 + 刷新），见下方的 isDesktop 分支。
          // 各 tab 内容列表顶部留白 headerMaxExtent，滚动时内容从顶栏底下
          // 穿过；顶栏收折进度由当前 tab 的内容 offset 派生（切页动画中按
          // 页面位置在相邻 tab 间插值，见 _updateHeaderShrink）。
          // 移动端强制 Clamping：自制下拉刷新靠 OverscrollNotification 累计
          // 下拉量，iOS 默认的 BouncingScrollPhysics 从不产生该通知（下拉
          // 变纯回弹、刷新失效），且负 pixels 与占位 spacer 会双重计距。
          // 外层 AlwaysScrollableScrollPhysics 保证短内容页也能下拉刷新。
          final tabPhysics = isDesktop
              ? const ClampingScrollPhysics()
              : const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                );
          final headerDelegate = HomeCollapsibleHeaderDelegate(
            api: widget.api,
            auth: widget.auth,
            player: widget.player,
            sectionIndex: _sectionIndex,
            // 胶囊指示器直接监听 PageController：滑动过程中只重建头部内
            // 的小胶囊条，不再每像素 setState 整棵首页子树。
            pageTracker: _pageController,
            vsync: this,
            onSectionChanged: (value) {
              if (value == -1) {
                widget.onTabSwitch?.call(0);
              } else {
                _handleSectionTap(value, animatePage: true);
              }
            },
            onRefresh: isDesktop ? _refreshCurrentSection : null,
            topPadding: topPadding,
          );
          final headerMaxExtent = headerDelegate.maxExtent;

          Widget tabScrollView({
            required ScrollController controller,
            required PageStorageKey<String> bodyKey,
            required List<Widget> slivers,
            required Future<void> Function() onRefresh,
            required int tabIndex,
            bool combinedRefreshIndicator = false,
          }) {
            final pullNotifier = _pullExtents[tabIndex];
            // 下拉指示器：顶在内容最顶部（箭头所指的缝隙处）。下拉时高度跟手
            // 顶出空白并渐现均衡器，松手达阈值吸附到 26 再刷新，全程无小圆圈。
            // 推荐页下拉与刷新共用同一个（combinedRefreshIndicator），
            // 排行/电台下拉只是预览、刷新由子页内部均衡器接管。
            Widget pullSpacer() {
              if (isDesktop || isCarMode) return const SizedBox.shrink();
              return ValueListenableBuilder<double>(
                valueListenable: pullNotifier,
                builder: (context, pull, _) {
                  if (combinedRefreshIndicator) {
                    final refreshing = showRefreshEqualizer;
                    final height = refreshing
                        ? _pullRefreshHeight
                        : pull.clamp(0.0, _pullMaxDistance);
                    if (height <= 0.5) return const SizedBox.shrink();
                    final showBars = refreshing || pull > 12.0;
                    return SizedBox(
                      height: height,
                      child: Center(
                        child: showBars
                            ? const RefreshEqualizer(
                                visible: true,
                                height: 20,
                              )
                            : const SizedBox.shrink(),
                      ),
                    );
                  }
                  if (pull <= 0.5) return const SizedBox.shrink();
                  return SizedBox(
                    height: pull,
                    child: Center(
                      child: pull > 12.0
                          ? const RefreshEqualizer(
                              visible: true,
                              height: 20,
                            )
                          : const SizedBox.shrink(),
                    ),
                  );
                },
              );
            }

            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                // 内层横向滑轨（歌单/新歌横滚）的通知不上报，只处理最外层纵向。
                if (notification.depth != 0 ||
                    notification.metrics.axis != Axis.vertical) {
                  return false;
                }
                // 自制下拉跟手：仅移动端在顶部下拉时累计，离开顶部即取消。
                if (!isDesktop && !isCarMode) {
                  if (notification is ScrollStartNotification) {
                    if ((notification.metrics.extentBefore) <= 0.5) {
                      _cancelPullAnim();
                    }
                  } else if (notification is OverscrollNotification) {
                    if (notification.metrics.extentBefore <= 0.5 &&
                        notification.overscroll < 0) {
                      _cancelPullAnim();
                      final next = (pullNotifier.value - notification.overscroll)
                          .clamp(0.0, _pullMaxDistance);
                      pullNotifier.value = next;
                    }
                  } else if (notification is ScrollUpdateNotification) {
                    if (notification.metrics.extentBefore > 0.5 &&
                        pullNotifier.value > 0) {
                      pullNotifier.value = 0.0;
                    }
                  }
                }
                if (notification is ScrollEndNotification) {
                  // 收折吸附分两段，对齐 floating + snap 手感：
                  // - 浅区（0..48）：内容 offset 本身即顶栏进度，动画内容到端点；
                  // - 深滚（>48）：顶栏半收折时只吸附顶栏不动内容，上滑一点即现、
                  //   下滑继续隐藏的手感不受影响。
                  // 顶部下拉中（pull>0）不做顶栏吸附，避免跟下拉收合打架。
                  if (pullNotifier.value <= 0.5 && controller.hasClients) {
                    final offset = controller.offset;
                    if (offset > 0 && offset < _headerCollapseRange) {
                      _cancelHeaderSnap();
                      final target = offset < _headerCollapseRange / 2
                          ? 0.0
                          : _headerCollapseRange;
                      unawaited(
                        controller.animateTo(
                          target,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                        ),
                      );
                    } else if (offset >= _headerCollapseRange) {
                      _snapHeaderDeep();
                    }
                  }
                  // 下拉松手：达阈值触发刷新并保持指示器，未达收合。
                  if (!isDesktop && !isCarMode) {
                    _releasePull(tabIndex, onRefresh);
                  }
                }
                return false;
              },
              child: CustomScrollView(
                key: bodyKey,
                controller: controller,
                physics: tabPhysics,
                slivers: [
                  // 顶部留白 = 顶栏完全展开的高度：内容从顶栏底下穿过。
                  // 宽壳形态（桌面 / 平板侧栏）无移动端吸顶头（搜索+tab
                  // 已上移到侧栏/顶栏），不留白。
                  SliverPadding(
                    padding: EdgeInsets.only(top: wideShell ? 0 : headerMaxExtent),
                  ),
                  if (_availableUpdate != null && !_updateBannerDismissed)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: AppUpdateBanner(
                          version: _availableUpdate!,
                          onTap: _showUpdateDetails,
                          onClose: () => setState(
                            () => _updateBannerDismissed = true,
                          ),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(child: pullSpacer()),
                  ...slivers,
                ],
              ),
            );
          }

          // 跨形态整树搬运：竖屏(Stack+吸顶头) ↔ 宽壳(分区标题) 切换会
          // 重构 PageView 的父链，若子树随之销毁重建，PageController 与
          // 三个 _tabControllers 会在同一帧内短暂附着新旧两套滚动视图
          // （旧视图帧末才卸载），'ScrollController attached to multiple
          // scroll views' 断言必现（Windows 自由拉伸窗口跨 720 阈值即
          // 触发）。外层 GlobalKey 让 PageView 子树原样换父，滚动位置与
          // 附着关系全程保留。
          final pageView = KeyedSubtree(
            key: _homeTabsPageViewHostKey,
            child: PageView(
              key: const Key('home_tabs_page_view'),
              controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _sectionIndex = index;
                  });
                  widget.onTabSwitch?.call(index + 1);
                  // 飞行结束：等目标页懒加载挂载后对齐（带重试），成功后
                  // 才清点按标记回到静止镜像逻辑，见 _alignTargetPostFrame。
                  // 桌面端无吸顶头，对齐目标恒为 0，直接清标记即可。
                  if (isDesktopFormFactor) {
                    _switchTarget = null;
                  } else {
                    _alignTargetPostFrame(index, 60);
                  }
                },
                children: [
              // Tab 0: 推荐
              _HomeTabKeepAlive(
                child: tabScrollView(
                  controller: _tabControllers[0],
                  bodyKey:
                      const PageStorageKey<String>('home_tab_recommend'),
                  onRefresh: refresh,
                  tabIndex: 0,
                  // 下拉与刷新共用顶部的自制指示器（替代旧的独立均衡器 sliver，
                  // 下拉跟手顶出空白、松手吸附到 26 再刷新，无小圆圈）。
                  combinedRefreshIndicator: true,
                  slivers: [
                    // 桌面端推荐 pane 的均衡器：刷新在途时出现在内容最顶部，
                    // 与排行/电台 pane 内部自带的均衡器对齐（侧栏双击当前
                    // 分区刷新时可见）。移动端不挂——下拉指示器与刷新均衡器
                    // 共用 pullSpacer，再挂一份会出现双均衡器。
                    if (isDesktop)
                      SliverToBoxAdapter(
                        child: RefreshEqualizer(
                          visible: showRefreshEqualizer,
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(18, 12, 18, 16),
                        // 平板形态限宽：猜你喜欢是全宽单行卡，千像素宽的
                        // 内容区里会被拉成失衡长条，收到 620 内保持卡片
                        // 比例、靠左与后续网格对齐。
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: tabletShell ? 620 : double.infinity,
                          ),
                          child: _FeatureShelf(
                            daily: data.daily,
                            onDailyPlay: () {
                              final songs = data.daily.songs;
                              if (songs.isNotEmpty) {
                                widget.player.playSong(
                                  songs.first,
                                  queue: songs,
                                );
                              }
                            },
                            onDailyTap: () =>
                                _openDailyRecommend(data.daily),
                          ),
                        ),
                      ),
                    ),
                    // 桌面宽窗：本体直接输出懒构建 sliver 组（SliverGrid 只
                    // 构建滚动可见的行，见 _SongSection.asSlivers）；移动端
                    // 由本体自行包 SliverToBoxAdapter，观感不变。
                    _SongSection(
                      key: ValueKey('song_section_$railResetEpoch'),
                      asSlivers: true,
                      title: '大家都在听',
                      songs: data.daily.songs,
                      onPlay: _playSong,
                      isLiked: (song) => widget.auth.isLiked(song),
                      onLikeTap: (song) =>
                          toggleLikeWithFeedback(widget.auth, song),
                      auth: widget.auth,
                      player: widget.player,
                      onViewArtist: _openArtist,
                    ),
                    // 同上：推荐歌单网格桌面端转懒构建 SliverGrid。
                    _PlaylistRail(
                      key: ValueKey('playlist_rail_$railResetEpoch'),
                      asSlivers: true,
                      playlists: data.playlists,
                      onTap: _openPlaylist,
                      onPlay: _playPlaylist,
                      onTapTitle: () =>
                          _openRecommendedPlaylists(data.playlists),
                    ),
                    if (data.topSongs.isNotEmpty)
                      // 同上：新歌速递网格桌面端转懒构建 SliverGrid。
                      _TopSongRail(
                        key: ValueKey('topsong_rail_$railResetEpoch'),
                        asSlivers: true,
                        songs: data.topSongs,
                        onPlay: (song) => _playSong(song, data.topSongs),
                        onTapTitle: () => _openTopSongs(data.topSongs),
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: wideShell ? 24 : 166),
                    ),
                  ],
                ),
              ),
              // Tab 1: 排行榜
              _HomeTabKeepAlive(
                child: tabScrollView(
                  controller: _tabControllers[1],
                  bodyKey: const PageStorageKey<String>('home_tab_rank'),
                  onRefresh: () =>
                      _rankKey.currentState?.refresh() ??
                      Future<void>.value(),
                  tabIndex: 1,
                  slivers: [
                    SliverToBoxAdapter(
                      child: RankPage(
                        key: _rankKey,
                        api: widget.api,
                        auth: widget.auth,
                        player: widget.player,
                        cache: widget.cache,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: wideShell ? 24 : 166),
                    ),
                  ],
                ),
              ),
              // Tab 2: 电台
              _HomeTabKeepAlive(
                child: tabScrollView(
                  controller: _tabControllers[2],
                  bodyKey: const PageStorageKey<String>('home_tab_radio'),
                  onRefresh: () =>
                      _radioKey.currentState?.refresh() ??
                      Future<void>.value(),
                  tabIndex: 2,
                  slivers: [
                    SliverToBoxAdapter(
                      child: _RadioSection(
                        key: _radioKey,
                        api: widget.api,
                        player: widget.player,
                        cache: widget.cache,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: wideShell ? 24 : 166),
                    ),
                  ],
                ),
              ),
                ],
                ),
              );
              if (wideShell) {
                // 宽壳形态（桌面 / 平板侧栏，QQ 音乐 PC 式）：无移动端吸顶
                // 搜索+胶囊 tab（平板时导航与搜索都在左侧触屏侧栏），切换
                // 只走侧栏；内容区顶部只保留分区标题（刷新走双击推荐项/
                // 下拉，不再放刷新按钮）。平板无窗口标题栏，标题行上方补
                // 状态栏高度。
                const sectionTitles = ['推荐', '排行榜', '电台'];
                content = Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        18,
                        (isDesktop ? 12 : 12 + topPadding),
                        12,
                        4,
                      ),
                      child: Row(
                        children: [
                          Text(
                            sectionTitles[_sectionIndex.clamp(0, 2).toInt()],
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: pageView),
                  ],
                );
              } else {
                content = Stack(
                  children: [
                    pageView,
                    // 页面层固定顶栏：覆盖在 PageView 之上，横向切页时固定不动；
                    // 收折进度由 _headerShrink 驱动（当前 tab 内容滚动增量跟手，
                    // 上滑即现、下滑即隐，见 _updateHeaderShrink）。
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ValueListenableBuilder<double>(
                        valueListenable: _headerShrink,
                        builder: (context, shrink, _) =>
                            HomeCollapsibleHeaderView(
                          delegate: headerDelegate,
                          shrinkOffset: shrink,
                        ),
                      ),
                    ),
                  ],
                );
              }
        } else {
          // 车机模式：保留原有车机定制滚动与卡片布局
          content = CustomScrollView(
            controller: _scrollController,
            physics: isDesktop
                ? const ClampingScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _RecommendHeader(
                  auth: widget.auth,
                  daily: data.daily,
                  sectionIndex: _sectionIndex,
                  showRefreshEqualizer: showRefreshEqualizer,
                  onSectionChanged: (value) {
                    if (value == -1) {
                      widget.onTabSwitch?.call(0); // Switch to My tab
                    } else {
                      _handleSectionTap(value, animatePage: false);
                    }
                  },
                  onDailyPlay: () {
                    final songs = data.daily.songs;
                    if (songs.isNotEmpty) {
                      widget.player.playSong(songs.first, queue: songs);
                    }
                  },
                  onDailyTap: () => _openDailyRecommend(data.daily),
                  api: widget.api,
                  player: widget.player,
                  updateVersion:
                      _updateBannerDismissed ? null : _availableUpdate,
                  onUpdateTap: _showUpdateDetails,
                  onUpdateClose: () {
                    setState(() => _updateBannerDismissed = true);
                  },
                  onRefresh: isDesktop ? refresh : null,
                ),
              ),
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    _PersistentTabPane(
                      visible: _sectionIndex == 0,
                      child: Column(
                        children: [
                          _SongSection(
                            key: ValueKey('car_song_section_$railResetEpoch'),
                            title: '大家都在听',
                            songs: data.daily.songs,
                            onPlay: _playSong,
                            isLiked: (song) => widget.auth.isLiked(song),
                            onLikeTap: (song) =>
                                toggleLikeWithFeedback(widget.auth, song),
                            auth: widget.auth,
                            player: widget.player,
                            onViewArtist: _openArtist,
                          ),
                          _PlaylistRail(
                            key: ValueKey('car_playlist_rail_$railResetEpoch'),
                            playlists: data.playlists,
                            onTap: _openPlaylist,
                            onPlay: _playPlaylist,
                            onTapTitle: () =>
                                _openRecommendedPlaylists(data.playlists),
                          ),
                          if (data.topSongs.isNotEmpty)
                            _TopSongRail(
                              key: ValueKey('car_topsong_rail_$railResetEpoch'),
                              songs: data.topSongs,
                              onPlay: (song) =>
                                  _playSong(song, data.topSongs),
                              onTapTitle: () =>
                                  _openTopSongs(data.topSongs),
                            ),
                        ],
                      ),
                    ),
                    _PersistentTabPane(
                      visible: _sectionIndex == 1,
                      child: RankPage(
                        key: _rankKey,
                        api: widget.api,
                        auth: widget.auth,
                        player: widget.player,
                        cache: widget.cache,
                      ),
                    ),
                    _PersistentTabPane(
                      visible: _sectionIndex == 2,
                      child: _RadioSection(
                        key: _radioKey,
                        api: widget.api,
                        player: widget.player,
                        cache: widget.cache,
                      ),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(height: isDesktopFormFactor ? 24 : 166),
              ),
            ],
          );
        }

        final safeContent = ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: content,
        );

        // 移动端下拉刷新由各 tab 自制下拉头承载（见 tabScrollView 的 pullSpacer，
        // 推荐/排行/电台各刷各页）：顶部下拉时内容顶出空白并渐现均衡器，
        // 松手达阈值吸附到 26 再刷新，全程无 Material 小圆圈。
        // 外层不再包任何刷新 widget——外层 child 是横向 PageView，
        // 纵向下拉到不了它，且只能刷推荐一页，在排行/电台页会刷错页。
        // 桌面/车机无下拉手势：桌面走页头刷新按钮，车机走顶栏点中当前 tab，
        // 反馈都用顶部均衡器动画。
        return safeContent;
      },
    );
  }
}

class _HomeTabKeepAlive extends StatefulWidget {
  const _HomeTabKeepAlive({required this.child});
  final Widget child;

  @override
  State<_HomeTabKeepAlive> createState() => _HomeTabKeepAliveState();
}

class _HomeTabKeepAliveState extends State<_HomeTabKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _RecommendHeader extends StatelessWidget {
  const _RecommendHeader({
    required this.auth,
    required this.daily,
    required this.sectionIndex,
    required this.onSectionChanged,
    required this.onDailyPlay,
    required this.onDailyTap,
    required this.api,
    required this.player,
    required this.updateVersion,
    required this.onUpdateTap,
    required this.onUpdateClose,
    this.onRefresh,
    this.showRefreshEqualizer = false,
  });

  final AuthController auth;
  final DailyRecommend daily;
  final int sectionIndex;
  final ValueChanged<int> onSectionChanged;
  final VoidCallback onDailyPlay;
  final VoidCallback onDailyTap;
  final MusicApi api;
  final PlayerController player;
  final AppVersionInfo? updateVersion;
  final VoidCallback onUpdateTap;
  final VoidCallback onUpdateClose;

  /// 顶部刷新均衡器动画可见性（车机模式推荐页与电台/排行榜间距保持一致）。
  final bool showRefreshEqualizer;

  /// 桌面端下拉刷新的替代入口（页头刷新按钮）；移动端 / 车机端不传。
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 车机模式专属样式仅在开启时生效，普通横屏不受影响。
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;
    // 车机宽屏：三个快捷入口在卡片右侧；车机非宽屏：入口在卡片下方。
    final isUltraWide =
        isCarMode &&
        size.width >= 1150 &&
        size.height >= 600 &&
        (size.width / size.height) > 2.0;

    // 清新淡雅：与我的页面一致，无大面积渐变，靠白卡与留白区分层次
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, isCarMode ? 4 : 10, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (updateVersion != null) ...[
                const SizedBox(height: 10),
                AppUpdateBanner(
                  version: updateVersion!,
                  onTap: onUpdateTap,
                  onClose: onUpdateClose,
                ),
              ],
              if (sectionIndex == 0) ...[
                const SizedBox(height: 12),
                RefreshEqualizer(visible: showRefreshEqualizer),
                if (isUltraWide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 6,
                        child: _FeatureShelf(
                          daily: daily,
                          onDailyPlay: onDailyPlay,
                          onDailyTap: onDailyTap,
                        ),
                      ),
                      // 猜你喜欢与统计 pills 之间留出明确呼吸间距，
                      // 避免五张卡挤成一排的局促感。
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 4,
                        child: _CarQuickStatsPills(
                          auth: auth,
                          player: player,
                          onSwitchToMyTab: () => onSectionChanged(-1),
                          api: api,
                          isSideBySide: true,
                        ),
                      ),
                    ],
                  )
                else ...[
                  _FeatureShelf(
                    daily: daily,
                    onDailyPlay: onDailyPlay,
                    onDailyTap: onDailyTap,
                  ),
                  if (isCarMode)
                    _CarQuickStatsPills(
                      auth: auth,
                      player: player,
                      onSwitchToMyTab: () => onSectionChanged(-1),
                      api: api,
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PersistentTabPane extends StatelessWidget {
  const _PersistentTabPane({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: visible,
      child: Offstage(offstage: !visible, child: child),
    );
  }
}


/// 推荐区特性卡：新碟上架下线后只剩「猜你喜欢」一张，全宽独占一行。
/// 手机/车机/宽窄屏统一为单卡，不再需要双卡并排与窄屏竖排逻辑。
class _FeatureShelf extends StatelessWidget {
  const _FeatureShelf({
    required this.daily,
    required this.onDailyPlay,
    required this.onDailyTap,
  });

  final DailyRecommend daily;
  final VoidCallback onDailyPlay;
  final VoidCallback onDailyTap;

  @override
  Widget build(BuildContext context) {
    return _FeatureCard(
      title: '猜你喜欢',
      subtitle: daily.songs.isEmpty
          ? '献给此刻迈步的你'
          : daily.songs.first.title,
      imageUrl: daily.songs.isEmpty
          ? daily.coverUrl
          : daily.songs.first.coverUrl,
      gradient: const [Color(0xFFFFD88E), Color(0xFFFF8DA2)],
      onTap: onDailyTap,
      onPlay: onDailyPlay,
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.gradient,
    required this.onTap,
    required this.onPlay,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final List<Color> gradient;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    final imageSize = isCarMode ? 82.0 : 64.0;
    final playSize = isCarMode ? 46.0 : 36.0;
    final playIconSize = isCarMode ? 26.0 : 20.0;
    final gap = isCarMode ? 14.0 : 10.0;
    final titleGap = isCarMode ? 7.0 : 6.0;
    final hintGap = isCarMode ? 4.0 : 3.0;
    final tagHPadding = isCarMode ? 9.0 : 7.0;
    final tagVPadding = isCarMode ? 4.5 : 3.0;
    final tagFontSize = isCarMode ? 13.5 : 11.0;
    final titleFontSize = isCarMode ? 17.5 : 13.0;
    final hintFontSize = isCarMode ? 13.0 : 11.0;
    final cardPadding = isCarMode ? const EdgeInsets.all(13) : const EdgeInsets.all(10);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: cardPadding,
            child: Row(
              children: [
                Container(
                  width: imageSize,
                  height: imageSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrl == null
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: gradient),
                            ),
                            child: Icon(
                              Icons.album_rounded,
                              color: Colors.white,
                              size: isCarMode ? 36 : 28,
                            ),
                          )
                        : RetryableNetworkImage(
                            url: imageUrl!,
                            fit: BoxFit.cover,
                            cacheWidth: 300,
                            cacheHeight: 300,
                            errorBuilder: (_, _, _) => DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: gradient),
                              ),
                              child: Icon(
                                Icons.music_note_rounded,
                                color: Colors.white,
                                size: isCarMode ? 32 : 26,
                              ),
                            ),
                          ),
                  ),
                ),
                SizedBox(width: gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: tagHPadding,
                          vertical: tagVPadding,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(
                            alpha: isDark ? .18 : .10,
                          ),
                          borderRadius: BorderRadius.circular(isCarMode ? 8 : 7),
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: tagFontSize,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      SizedBox(height: titleGap),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              fontSize: titleFontSize,
                              height: 1.2,
                            ),
                      ),
                      SizedBox(height: hintGap),
                      Text(
                        isCarMode ? '点击查看歌单 · 右侧播放' : '点击查看歌单',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant.withValues(alpha: .70),
                          fontWeight: FontWeight.w600,
                          fontSize: hintFontSize,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: gap),
                _CirclePlayButton(size: playSize, iconSize: playIconSize, onTap: onPlay),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SongSection extends StatefulWidget {
  const _SongSection({
    super.key,
    required this.title,
    required this.songs,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
    this.asSlivers = false,
  });

  /// 桌面宽窗下由 tab 级 CustomScrollView 直接承接：本体输出懒构建 sliver
  /// 组（见 _buildDesktopSlivers），非桌面形态则包 SliverToBoxAdapter 挂入。
  /// 默认 false 时返回普通盒子（车机 Column 宿主沿用）。
  final bool asSlivers;

  final String title;
  final List<Song> songs;
  final void Function(Song song, List<Song> queue) onPlay;
  final bool Function(Song song) isLiked;
  final void Function(Song song) onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final void Function(Song song) onViewArtist;

  @override
  State<_SongSection> createState() => _SongSectionState();
}

class _SongSectionState extends State<_SongSection> {
  late final PageController _pageController;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.92);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) {
      // 桌面懒构建形态本体是 sliver：空数据也返回空 sliver，避免盒子混进
      // tab 的 slivers 列表。
      if (widget.asSlivers) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) {
        // 桌面宽窗：宿主是 tab 的 CustomScrollView，标题 + 网格整体转为
        // 懒构建 sliver 组（只有滚动可见的行才实例化）。
        if (widget.asSlivers && isDesktopFormFactor) {
          return _buildDesktopSlivers();
        }
        final section = Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            children: [
              _SectionHeader(
                title: widget.title,
                action: _CirclePlayButton(
                  tooltip: '播放',
                  size: 38,
                  iconSize: 22,
                  onTap: () =>
                      widget.onPlay(widget.songs.first, widget.songs),
                ),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth;
                  // 盒子宿主统一走分页懒加载（PageView.builder 只构建可见
                  // 页）：桌面网格懒构建在 _buildDesktopSlivers（sliver
                  // 宿主），此处不保留桌面全量 eager 分支。
                  final int crossAxisCount;
                  final int itemsPerPage;
                  if (maxWidth >= 1050) {
                    crossAxisCount = 3;
                    itemsPerPage = 9;
                  } else if (maxWidth >= 650) {
                    crossAxisCount = 2;
                    itemsPerPage = 6;
                  } else {
                    crossAxisCount = 1;
                    itemsPerPage = 3;
                  }

                  final rowCount = (itemsPerPage / crossAxisCount).ceil();
                  final pageCount = (widget.songs.length / itemsPerPage).ceil();

                  // 刷新后歌曲变少（或换页容量变化）时当前页可能越界：
                  // 圆点先按钳制后的页码显示，布局完成后把 PageView 跳回最后一页。
                  final effectivePage = _page.clamp(0, pageCount - 1);
                  if (_pageController.hasClients &&
                      _pageController.position.haveDimensions &&
                      (_pageController.page ?? 0) > pageCount - 1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_pageController.hasClients) return;
                      _pageController.jumpToPage(pageCount - 1);
                    });
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: rowCount * 60.0,
                        child: HorizontalWheelPageScroll(
                          controller: _pageController,
                          child: PageView.builder(
                            controller: _pageController,
                            padEnds: false,
                            itemCount: pageCount,
                            onPageChanged: (i) => setState(() => _page = i),
                            itemBuilder: (context, pageIndex) {
                              final start = pageIndex * itemsPerPage;
                              final end = (start + itemsPerPage).clamp(
                                0,
                                widget.songs.length,
                              );
                              final pageSongs = widget.songs.sublist(start, end);

                              return Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (
                                      int col = 0;
                                      col < crossAxisCount;
                                      col++
                                    ) ...[
                                      if (col > 0) const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          children: [
                                            for (
                                              int i = col;
                                              i < pageSongs.length;
                                              i += crossAxisCount
                                            )
                                              HomeSongRow(
                                                song: pageSongs[i],
                                                queue: widget.songs,
                                                onPlay: widget.onPlay,
                                                isLiked: widget.isLiked(
                                                  pageSongs[i],
                                                ),
                                                onLikeTap: () =>
                                                    widget.onLikeTap(pageSongs[i]),
                                                auth: widget.auth,
                                                player: widget.player,
                                                onViewArtist: () => widget
                                                    .onViewArtist(pageSongs[i]),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      if (pageCount > 1) ...[
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(pageCount, (i) {
                            final active = i == effectivePage;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: active ? 16 : 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                color: active
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.outline
                                          .withValues(alpha: .3),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            );
                          }),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        );
        // 非桌面形态（asSlivers 挂进 tab slivers）：与改造前调用处的
        // SliverToBoxAdapter 包装等价，仅挪到本体内部；盒子宿主原样返回。
        if (widget.asSlivers) {
          return SliverToBoxAdapter(child: section);
        }
        return section;
      },
    );
  }

  /// 桌面宽窗懒构建形态（宿主为 tab 级 CustomScrollView）。
  ///
  /// 原桌面分支在 LayoutBuilder 里一次性全量实例化全部 HomeSongRow（Row +
  /// 按列 Expanded(Column)），歌曲多时首页峰值内存高；改为 SliverGrid +
  /// SliverChildBuilderDelegate 后只构建滚动可见的行。视觉口径不变：
  /// 列数断点 ≥1050=3 / ≥650=2、列距 16、行高 54——桌面旧行高为自然
  /// 54（44 封面 + 上下 2×5 padding，见 home_song_row.dart），mainAxisExtent
  /// 54 与旧视觉逐像素一致；60 是移动/车机分页分支的 rowCount * 60.0
  /// 口径，勿混淆。左右 18 边距、底部 24。旧实现按"列主序
  /// 填充 + 按列展示"，第 r 行第 c 格恰为 songs[r*列数+c]，SliverGrid
  /// 行主序 child i → songs[i] 视觉完全一致，无需任何置换。
  Widget _buildDesktopSlivers() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          // 8 = 原 header 与网格之间的 SizedBox(8)。
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: _SectionHeader(
              title: widget.title,
              action: _CirclePlayButton(
                tooltip: '播放',
                size: 38,
                iconSize: 22,
                onTap: () => widget.onPlay(widget.songs.first, widget.songs),
              ),
            ),
          ),
        ),
        SliverPadding(
          // 左右 18 与标题对齐，底部 24 = 原区块底部留白；列距 16 =
          // 原 Row 列间 SizedBox(16)。
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.crossAxisExtent;
              final int crossAxisCount;
              if (maxWidth >= 1050) {
                crossAxisCount = 3;
              } else if (maxWidth >= 650) {
                crossAxisCount = 2;
              } else {
                crossAxisCount = 1;
              }
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 16,
                  // 桌面旧行高为自然 54（44 封面 + 上下 2×5 padding），
                  // mainAxisExtent 54 与旧视觉逐像素一致；60 是移动/车机
                  // 分页分支口径，勿混淆。
                  mainAxisExtent: 54,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = widget.songs[index];
                    return HomeSongRow(
                      song: song,
                      queue: widget.songs,
                      onPlay: widget.onPlay,
                      isLiked: widget.isLiked(song),
                      onLikeTap: () => widget.onLikeTap(song),
                      auth: widget.auth,
                      player: widget.player,
                      onViewArtist: () => widget.onViewArtist(song),
                    );
                  },
                  childCount: widget.songs.length,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 新歌速递横向区块。
class _TopSongRail extends StatelessWidget {
  const _TopSongRail({
    super.key,
    required this.songs,
    required this.onPlay,
    this.onTapTitle,
    this.asSlivers = false,
  });

  final List<Song> songs;
  final ValueChanged<Song> onPlay;
  final VoidCallback? onTapTitle;

  /// 桌面宽窗下由 tab 级 CustomScrollView 直接承接：本体输出懒构建 sliver
  /// 组（网格改 SliverGrid，姿势同 recommended_playlists_page）。
  /// asSlivers=true 时桌面与非桌面均走本 sliver 懒构建路径（网格/横轨参数
  /// 与旧盒子路径逐字等价，移动端网格也因此懒构建）；盒子路径仅供车机
  /// Column 宿主（asSlivers=false，默认值）。
  final bool asSlivers;

  @override
  Widget build(BuildContext context) {
    // 车机首页只是二级页面的入口，只预览一行（6 首），与推荐歌单保持一致。
    final size = MediaQuery.sizeOf(context);
    final isCarMode =
        size.width > size.height && ThemeController.instance.carModeEnabled;
    if (isCarMode) {
      final preview = songs.length > 6 ? songs.sublist(0, 6) : songs;
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _SectionHeader(
                title: '新歌速递',
                action: const SizedBox.shrink(),
                onTap: onTapTitle,
              ),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: preview.length,
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                // 正方形封面 + 两行文字 ≈ 宽:高 = 0.72。
                childAspectRatio: 0.72,
              ),
              itemBuilder: (context, index) => _TopSongCard(
                song: preview[index],
                onTap: () => onPlay(preview[index]),
              ),
            ),
          ],
        ),
      );
    }
    // 桌面宽窗（宿主为 tab 级 CustomScrollView）：标题 + 网格整体转为懒构建
    // sliver 组，旧 GridView(shrinkWrap) 会一次性构建全部卡片；窄内容区
    // 仍回退横轨（与下方盒子分支同口径，只是宿主换成 sliver）。注意横轨
    // 自带分区标题（AppHorizontalRail 内部渲染），与旧结构一致只在网格
    // 分支额外挂 _SectionHeader。
    if (asSlivers) {
      return SliverLayoutBuilder(
        builder: (context, constraints) {
          if (AdaptiveLayout.isGridWidth(constraints.crossAxisExtent)) {
            return SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    // 20 = 原区块顶部留白，12 = 原 header 与网格之间的
                    // SizedBox(12)。
                    padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
                    child: _SectionHeader(
                      title: '新歌速递',
                      action: const SizedBox.shrink(),
                      onTap: onTapTitle,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 14,
                      // 正方形封面 + 两行文字 ≈ 宽:高 = 0.72。
                      childAspectRatio: 0.72,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: _TopSongCard(
                          song: songs[index],
                          onTap: () => onPlay(songs[index]),
                        ),
                      ),
                      childCount: songs.length,
                    ),
                  ),
                ),
              ],
            );
          }
          return SliverToBoxAdapter(
            child: AppHorizontalRail<Song>(
              title: '新歌速递',
              items: songs,
              height: 162,
              itemWidth: 110,
              topPadding: 20,
              onTapTitle: onTapTitle,
              itemBuilder: (context, song) =>
                  _TopSongCard(song: song, onTap: () => onPlay(song)),
            ),
          );
        },
      );
    }
    // 宽内容区（桌面宽窗 / 平板侧栏形态）：转网格并让封面撑满格宽
    // （此前复用横轨的固定 110 封面，格子比图大一圈，hover 时大片空白，
    // 见新歌速递截图箭头处）。
    return LayoutBuilder(
      builder: (context, constraints) {
        if (AdaptiveLayout.isGridWidth(constraints.maxWidth)) {
          return Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _SectionHeader(
                    title: '新歌速递',
                    action: const SizedBox.shrink(),
                    onTap: onTapTitle,
                  ),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: songs.length,
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 14,
                    // 正方形封面 + 两行文字 ≈ 宽:高 = 0.72。
                    childAspectRatio: 0.72,
                  ),
                  itemBuilder: (context, index) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: _TopSongCard(
                      song: songs[index],
                      onTap: () => onPlay(songs[index]),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return AppHorizontalRail<Song>(
          title: '新歌速递',
          items: songs,
          height: 162,
          itemWidth: 110,
          topPadding: 20,
          onTapTitle: onTapTitle,
          itemBuilder: (context, song) =>
              _TopSongCard(song: song, onTap: () => onPlay(song)),
        );
      },
    );
  }
}

class _TopSongCard extends StatelessWidget {
  const _TopSongCard({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = isDesktopFormFactor;
    final cardRadius = isDesktop ? 8.0 : 14.0;

    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(cardRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 横轨下外层定宽 110；桌面网格下撑满格宽做正方形封面。
          final coverWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 110.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 桌面端：hover 封面浮现播放蒙层，点击 = 直接播放（与单击同义）；
              // 移动端 / 车机端 enabled=false，结构与接入前一致。
              CoverPlayOverlay(
                enabled: isDesktop,
                onPlay: onTap,
                borderRadius: cardRadius,
                buttonSize: 32,
                iconSize: 22,
                buttonColor: Colors.black54,
                iconColor: Colors.white,
                cover: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(cardRadius),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: .08)
                          : Colors.black.withValues(alpha: isDesktop ? .06 : .08),
                      width: 1,
                    ),
                    boxShadow: isDesktop
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: isDark ? .14 : .06,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(cardRadius),
                    child: Artwork(url: song.coverUrl, size: coverWidth),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlaylistRail extends StatelessWidget {
  const _PlaylistRail({
    super.key,
    required this.playlists,
    required this.onTap,
    this.onPlay,
    this.onTapTitle,
    this.asSlivers = false,
  });

  final List<PlaylistSummary> playlists;
  final ValueChanged<PlaylistSummary> onTap;
  final ValueChanged<PlaylistSummary>? onPlay;
  final VoidCallback? onTapTitle;

  /// 桌面宽窗下由 tab 级 CustomScrollView 直接承接：本体输出懒构建 sliver
  /// 组（网格改 SliverGrid，姿势同 recommended_playlists_page）。
  /// asSlivers=true 时桌面与非桌面均走本 sliver 懒构建路径（网格/横轨参数
  /// 与旧盒子路径逐字等价，移动端网格也因此懒构建）；盒子路径仅供车机
  /// Column 宿主（asSlivers=false，默认值）。
  final bool asSlivers;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      // 桌面懒构建形态本体是 sliver：空数据也返回空 sliver，避免盒子混进
      // tab 的 slivers 列表。
      if (asSlivers) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      return const SizedBox.shrink();
    }

    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 推荐歌单网格布局是车机专属，普通横屏用横向列表。
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    if (isCarMode) {
      // 车机首页只是二级页面的入口，只预览一行（6 张），避免一次铺满全量。
      final preview = playlists.length > 6 ? playlists.sublist(0, 6) : playlists;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _SectionHeader(
                title: '推荐歌单',
                action: const SizedBox.shrink(),
                onTap: onTapTitle,
              ),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: preview.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                childAspectRatio: 0.60,
              ),
              itemBuilder: (context, index) {
                final playlist = preview[index];
                return _PlaylistCard(
                  playlist: playlist,
                  onTap: () => onTap(playlist),
                  onPlay: onPlay == null ? null : () => onPlay!(playlist),
                );
              },
            ),
          ],
        ),
      );
    }

    // 桌面宽窗（宿主为 tab 级 CustomScrollView）：标题 + 网格整体转为懒构建
    // sliver 组，旧 GridView(shrinkWrap) 会一次性构建全部卡片；窄内容区
    // 仍回退横轨（与下方盒子分支同口径，只是宿主换成 sliver）。
    if (asSlivers) {
      return SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              // 12 = 原区块顶部留白 = 原 header 与网格之间的 SizedBox(12)。
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: _SectionHeader(
                title: '推荐歌单',
                action: const SizedBox.shrink(),
                onTap: onTapTitle,
              ),
            ),
          ),
          SliverLayoutBuilder(
            builder: (context, constraints) {
              if (AdaptiveLayout.isGridWidth(constraints.crossAxisExtent)) {
                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.60,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final playlist = playlists[index];
                        return _PlaylistCard(
                          playlist: playlist,
                          onTap: () => onTap(playlist),
                          onPlay:
                              onPlay == null ? null : () => onPlay!(playlist),
                        );
                      },
                      childCount: playlists.length,
                    ),
                  ),
                );
              }
              return SliverToBoxAdapter(
                child: SizedBox(
                  height: 204,
                  child: HorizontalWheelScroll(
                    builder: (context, controller) => ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      scrollDirection: Axis.horizontal,
                      itemCount: playlists.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        return _PlaylistCard(
                          playlist: playlist,
                          onTap: () => onTap(playlist),
                          onPlay:
                              onPlay == null ? null : () => onPlay!(playlist),
                          width: 128,
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _SectionHeader(
              title: '推荐歌单',
              action: const SizedBox.shrink(),
              onTap: onTapTitle,
            ),
          ),
          const SizedBox(height: 12),
          // 门控统一读内容宽度（constraints.maxWidth），与其他分区一致；
          // 纯宽度阈值：桌面宽窗与平板侧栏形态都转网格，窄内容区保持横轨。
          LayoutBuilder(
            builder: (context, constraints) {
              if (AdaptiveLayout.isGridWidth(constraints.maxWidth)) {
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: playlists.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.60,
                  ),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return _PlaylistCard(
                      playlist: playlist,
                      onTap: () => onTap(playlist),
                      onPlay: onPlay == null ? null : () => onPlay!(playlist),
                    );
                  },
                );
              }
              return SizedBox(
                height: 204,
                child: HorizontalWheelScroll(
                  builder: (context, controller) => ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    scrollDirection: Axis.horizontal,
                    itemCount: playlists.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return _PlaylistCard(
                        playlist: playlist,
                        onTap: () => onTap(playlist),
                        onPlay: onPlay == null ? null : () => onPlay!(playlist),
                        width: 128,
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.action = const SizedBox.shrink(),
    this.onTap,
  });

  final String title;
  final Widget action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget titleWidget = Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w900,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );

    Widget effectiveAction = action;
    if (onTap != null &&
        (action is SizedBox &&
            ((action as SizedBox).width == null ||
                (action as SizedBox).width == 0))) {
      effectiveAction = Icon(
        Icons.chevron_right_rounded,
        size: 22,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
      );
    }

    final content = Row(
      children: [
        Expanded(child: titleWidget),
        effectiveAction,
      ],
    );

    if (onTap != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}

/// 全局统一的淡雅圆形播放按钮：primary@.12 圆底 + primary 图标。
/// 用于推荐区头、猜你喜欢/新碟、自建歌单等所有列表播放入口。
class _CirclePlayButton extends StatelessWidget {
  const _CirclePlayButton({
    required this.onTap,
    this.size = 36,
    this.iconSize = 20,
    this.tooltip,
  });

  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final button = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: isDark ? .18 : .12),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        color: colorScheme.primary,
        size: iconSize,
      ),
    );
    final ink = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        child: button,
      ),
    );
    if (tooltip == null) return ink;
    return Tooltip(message: tooltip!, child: ink);
  }
}

class _PlaylistCard extends StatefulWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.onTap,
    this.onPlay,
    this.width,
  });

  final PlaylistSummary playlist;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final double? width;

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = isDesktopFormFactor;
    final cardRadius = isDesktop ? 8.0 : 14.0;
    final hoverRadius = isDesktop ? 10.0 : cardRadius;
    const desktopInset = 6.0;

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final rawWidth = widget.width ?? constraints.maxWidth;
        final baseWidth = rawWidth.isInfinite ? 128.0 : rawWidth;
        final cardWidth = isDesktop
            ? (baseWidth - desktopInset * 2).clamp(0.0, double.infinity)
            : baseWidth;
        final size = cardWidth;

        final coverImage = Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(cardRadius),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: .08)
                  : Colors.black.withValues(alpha: isDesktop ? .06 : .08),
              width: 1,
            ),
            boxShadow: isDesktop
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? .14 : .06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(cardRadius),
            child: Artwork(
              url: widget.playlist.coverUrl,
              size: size,
              borderRadius: cardRadius,
            ),
          ),
        );

        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CoverPlayOverlay(
              enabled: isDesktop && widget.onPlay != null,
              alignment: Alignment.bottomRight,
              borderRadius: cardRadius,
              buttonSize: 36,
              iconSize: 22,
              margin: const EdgeInsets.all(8),
              buttonColor: Theme.of(context).colorScheme.primary,
              iconColor: Theme.of(context).colorScheme.onPrimary,
              onPlay: () => widget.onPlay?.call(),
              tooltip: '播放歌单',
              isHovered: _hovered,
              darkenOnHover: false,
              cover: coverImage,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: Text(
                widget.playlist.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: isDesktop ? 13.5 : 14,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.playlist.subtitle ?? _playCount(widget.playlist.playCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: isDesktop ? 12 : 12.5,
              ),
            ),
          ],
        );

        if (isDesktop) {
          return Padding(
            padding: const EdgeInsets.all(desktopInset),
            child: column,
          );
        }
        return column;
      },
    );

    final inkCard = InkWell(
      borderRadius: BorderRadius.circular(hoverRadius),
      onTap: widget.onTap,
      mouseCursor: SystemMouseCursors.click,
      child: content,
    );

    final mouseCard = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: isDesktop ? (_) => setState(() => _hovered = true) : null,
      onExit: isDesktop ? (_) => setState(() => _hovered = false) : null,
      child: inkCard,
    );

    if (widget.width != null) {
      return SizedBox(
        width: widget.width,
        child: mouseCard,
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: mouseCard,
    );
  }
}

class _RadioSection extends StatefulWidget {
  const _RadioSection({
    super.key,
    required this.api,
    required this.player,
    required this.cache,
  });

  final MusicApi api;
  final PlayerController player;
  final CacheService cache;

  @override
  State<_RadioSection> createState() => _RadioSectionState();
}

class _RadioSectionState extends SwrSectionState<_RadioSection, _RadioData> {
  static _RadioData? _cachedData;

  String? _loadingStationId;

  @override
  CacheService get cache => widget.cache;

  @override
  _RadioData? get cachedData => _cachedData;

  @override
  set cachedData(_RadioData? value) => _cachedData = value;

  @override
  String get cacheKey => 'cache_radio';

  @override
  Duration get cacheTtl => AppConfig.radioCacheTtl;

  @override
  _RadioData decodeCache(Map<String, dynamic> json) => _RadioData.fromCache(json);

  @override
  Map<String, dynamic> encodeCache(_RadioData data) => data.toCache();

  @override
  bool hasContent(_RadioData data) =>
      data.recommended.isNotEmpty || data.groups.isNotEmpty;

  @override
  Future<_RadioData> fetchData() async {
    final results = await Future.wait([
      widget.api.fmRecommendedStations(),
      widget.api.fmClassGroups(),
    ]);
    final recommended = results[0] as List<FmStation>;
    final groups = results[1] as List<FmClassGroup>;
    final imageIds =
        [...recommended, ...groups.expand((group) => group.stations.take(4))]
            .where((station) => station.artworkUrl == null)
            .map((station) => station.id)
            .toList();
    final images = await widget.api.fmImages(imageIds);

    FmStation applyImage(FmStation station) {
      final image = images[station.id];
      return image == null ? station : station.mergeImage(image);
    }

    return _RadioData(
      recommended: recommended.map(applyImage).toList(),
      groups: groups
          .map(
            (group) => FmClassGroup(
              id: group.id,
              name: group.name,
              stations: group.stations.map(applyImage).toList(),
            ),
          )
          .toList(),
    );
  }

  Future<void> _playStation(FmStation station) async {
    if (_loadingStationId != null) {
      return;
    }

    setState(() => _loadingStationId = station.id);
    try {
      final songs = await widget.api.fmSongs(station);
      final queue = songs.isEmpty ? station.previewSongs : songs;
      if (!mounted) {
        return;
      }
      if (queue.isEmpty) {
        Toast.info('这个电台暂时没有可播放歌曲');
        return;
      }
      widget.player.playSong(queue.first, queue: queue);
    } catch (error) {
      if (!mounted) {
        return;
      }
      Toast.error('电台加载失败：${friendlyServiceErrorMessage(error)}');
    } finally {
      if (mounted) {
        setState(() => _loadingStationId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    // 电台双卡+网格布局是车机专属，普通横屏用原布局。
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    // 磁盘恢复中（主数据 Future 尚未确定）：显示骨架，避免闪现空态。
    final future = sectionFuture;
    if (future == null) {
      return const _RadioSkeleton();
    }
    return FutureBuilder<_RadioData>(
      future: future,
      builder: (context, snapshot) {
        // 与推荐页/排行榜一致：优先显示内存/磁盘缓存，无缓存才走骨架/错误态。
        final data = snapshot.data ?? _cachedData;
        if (snapshot.connectionState == ConnectionState.waiting &&
            data == null) {
          return const _RadioSkeleton();
        }
        if (data == null && snapshot.hasError) {
          return _ErrorView(
            message: snapshot.error.toString(),
            onRetry: refresh,
          );
        }
        final radio = data ?? _RadioData.empty;

        if (isCarMode) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部均衡器刷新动画：刷新在途时出现，平时收起不占位。
                RefreshEqualizer(visible: showRefreshEqualizer),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: _RadioSectionTitle(
                    title: '推荐电台',
                    icon: Icons.radio_rounded,
                  ),
                ),
                if (radio.recommended.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: radio.recommended.length >= 2
                        // 有两个及以上推荐时，并排展示两张横卡
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _RadioHeroCard(
                                  station: radio.recommended[0],
                                  loading:
                                      _loadingStationId ==
                                      radio.recommended[0].id,
                                  onTap: () =>
                                      _playStation(radio.recommended[0]),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _RadioHeroCard(
                                  station: radio.recommended[1],
                                  loading:
                                      _loadingStationId ==
                                      radio.recommended[1].id,
                                  onTap: () =>
                                      _playStation(radio.recommended[1]),
                                ),
                              ),
                            ],
                          )
                        : _RadioHeroCard(
                            station: radio.recommended.first,
                            loading:
                                _loadingStationId ==
                                radio.recommended.first.id,
                            onTap: () =>
                                _playStation(radio.recommended.first),
                          ),
                  ),
                if (radio.recommended.length > 2) ...[
                  const SizedBox(height: 14),
                  _RadioStationGrid(
                    stations: radio.recommended.skip(2).toList(),
                    loadingStationId: _loadingStationId,
                    onTap: _playStation,
                  ),
                ],
                for (final group in radio.groups) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: _RadioSectionTitle(
                      title: group.name,
                      icon: Icons.radio_rounded,
                      trailingText: '${group.stations.length} 个电台',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _RadioStationGrid(
                    stations: group.stations,
                    loadingStationId: _loadingStationId,
                    onTap: _playStation,
                  ),
                ],
                if (radio.recommended.isEmpty && radio.groups.isEmpty)
                  const _RadioEmpty(),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部均衡器刷新动画：刷新在途时出现，平时收起不占位。
              RefreshEqualizer(visible: showRefreshEqualizer),
              _RadioSectionTitle(
                title: '推荐电台',
                icon: Icons.radio_rounded,
              ),
              const SizedBox(height: 12),
              if (radio.recommended.isNotEmpty)
                _RadioHeroCard(
                  station: radio.recommended.first,
                  loading: _loadingStationId == radio.recommended.first.id,
                  onTap: () => _playStation(radio.recommended.first),
                ),
              if (radio.recommended.length > 1) ...[
                const SizedBox(height: 14),
                _RadioStationRail(
                  key: ValueKey('radio_rec_rail_$railResetEpoch'),
                  stations: radio.recommended.skip(1).toList(),
                  loadingStationId: _loadingStationId,
                  onTap: _playStation,
                ),
              ],
              for (final group in radio.groups) ...[
                const SizedBox(height: 24),
                _RadioSectionTitle(
                  title: group.name,
                  icon: Icons.radio_rounded,
                  trailingText: '${group.stations.length} 个电台',
                ),
                const SizedBox(height: 12),
                _RadioStationRail(
                  key: ValueKey('radio_group_${group.id}_$railResetEpoch'),
                  stations: group.stations,
                  loadingStationId: _loadingStationId,
                  onTap: _playStation,
                ),
              ],
              if (radio.recommended.isEmpty && radio.groups.isEmpty)
                const _RadioEmpty(),
            ],
          ),
        );
      },
    );
  }
}

/// 电台统一小节标题：32 主色图标底 + 17 粗标题，与排行榜/首页白卡语言一致。
class _RadioSectionTitle extends StatelessWidget {
  const _RadioSectionTitle({
    required this.title,
    required this.icon,
    this.trailingText,
  });

  final String title;
  final IconData icon;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: isDark ? .18 : .12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
          ),
        ),
        if (trailingText != null)
          Text(
            trailingText!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
          ),
      ],
    );
  }
}

class _RadioHeroCard extends StatelessWidget {
  const _RadioHeroCard({
    required this.station,
    required this.loading,
    required this.onTap,
  });

  final FmStation station;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    final artworkSize = isCarMode ? 84.0 : 72.0;
    final cardPadding = isCarMode ? const EdgeInsets.all(14) : const EdgeInsets.all(12);
    final gap = isCarMode ? 14.0 : 12.0;
    final titleGap = isCarMode ? 7.0 : 6.0;
    final subtitleGap = isCarMode ? 4.0 : 3.0;
    final tagHPadding = isCarMode ? 9.0 : 7.0;
    final tagVPadding = isCarMode ? 4.5 : 3.0;
    final tagFontSize = isCarMode ? 13.5 : 11.0;
    final titleFontSize = isCarMode ? 18.0 : 15.0;
    final subtitleFontSize = isCarMode ? 14.0 : 12.0;

    // 与首页白卡统一：白底 16 圆角 + 描边 + 轻阴影，左侧封面 + 右侧信息 + 主色圆播钮。
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: loading ? null : onTap,
          mouseCursor: loading
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: cardPadding,
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Artwork(
                      url: station.artworkUrl ?? station.bannerUrl,
                      size: artworkSize,
                      borderRadius: 12,
                      icon: Icons.radio_rounded,
                    ),
                  ),
                ),
                SizedBox(width: gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: tagHPadding,
                          vertical: tagVPadding,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: isDark ? .18 : .10),
                          borderRadius: BorderRadius.circular(isCarMode ? 8 : 7),
                        ),
                        child: Text(
                          '推荐电台',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: tagFontSize,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      SizedBox(height: titleGap),
                      Text(
                        station.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              fontSize: titleFontSize,
                              height: 1.2,
                            ),
                      ),
                      SizedBox(height: subtitleGap),
                      Text(
                        station.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                              fontSize: subtitleFontSize,
                            ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: gap),
                _RadioPlayBadge(loading: loading),
              ],
            ),
          ),
        ),
      ),
    );
}
}

class _RadioStationRail extends StatelessWidget {
  const _RadioStationRail({
    super.key,
    required this.stations,
    required this.loadingStationId,
    required this.onTap,
  });

  final List<FmStation> stations;
  final String? loadingStationId;
  final ValueChanged<FmStation> onTap;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽内容区（桌面宽窗 / 平板侧栏形态）直接复用车机网格组件
        // （同参数、同卡片），保持视觉一致。
        if (AdaptiveLayout.isGridWidth(constraints.maxWidth)) {
          return _RadioStationGrid(
            stations: stations,
            loadingStationId: loadingStationId,
            onTap: onTap,
          );
        }
        // 卡片内容高度充足（封面116 + 标题 + 副标题），轨道188彻底杜绝底部溢出且呼吸感匀称。
        return SizedBox(
          height: 188,
          child: HorizontalWheelScroll(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemCount: stations.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final station = stations[index];
                return _RadioStationCard(
                  station: station,
                  loading: loadingStationId == station.id,
                  onTap: () => onTap(station),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _RadioStationGrid extends StatelessWidget {
  const _RadioStationGrid({
    required this.stations,
    required this.loadingStationId,
    required this.onTap,
  });

  final List<FmStation> stations;
  final String? loadingStationId;
  final ValueChanged<FmStation> onTap;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return const SizedBox.shrink();
    }
    // 格子纵横比给足文字与留白空间，避免在大屏网格下溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final count = (maxWidth / 170).floor().clamp(2, 7);
        const spacing = 12.0;
        final cellWidth = (maxWidth - spacing * (count - 1)) / count;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          itemCount: stations.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: cellWidth / (cellWidth + 56),
          ),
          itemBuilder: (context, index) {
            final station = stations[index];
            return _RadioStationCard(
              station: station,
              loading: loadingStationId == station.id,
              onTap: () => onTap(station),
              width: null,
            );
          },
        );
      },
    );
  }
}

class _RadioStationCard extends StatelessWidget {
  const _RadioStationCard({
    required this.station,
    required this.loading,
    required this.onTap,
    this.width = 132,
  });

  final FmStation station;
  final bool loading;
  final VoidCallback onTap;
  /// 横滑轨道传固定宽；网格传 null 让卡片撑满格子，封面随格宽自适应。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 与排行榜新歌卡统一的白卡：圆角 16 + 描边 + 轻阴影，封面圆角 + 右下淡蓝播钮。
    final card = Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .18 : .06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: loading ? null : onTap,
            mouseCursor: loading
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final side = constraints.maxWidth.isFinite
                          ? constraints.maxWidth
                          : 116.0;
                      return Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: .08),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox.square(
                                dimension: side,
                                child: Artwork(
                                  url: station.artworkUrl,
                                  size: side,
                                  borderRadius: 12,
                                  icon: Icons.radio_rounded,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: _RadioPlayBadge(loading: loading, compact: true),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      station.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            height: 1.2,
                          ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      station.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11.5,
                            height: 1.2,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    final width = this.width;
    if (width == null) return card;
    return SizedBox(width: width, child: card);
  }
}

class _RadioPlayBadge extends StatelessWidget {
  const _RadioPlayBadge({required this.loading, this.compact = false});

  final bool loading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    // 与全局/推荐页圆形播钮统一：清爽淡蓝底 + 主色图标。大卡小卡统一实底淡蓝，杜绝泛灰。
    final size = compact ? 30.0 : (isCarMode ? 46.0 : 38.0);
    final iconSize = compact ? 18.0 : (isCarMode ? 26.0 : 22.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.primary.withValues(alpha: .28)
            : const Color(0xFFE8F2FF),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: isDark ? .20 : .12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: loading
            ? SizedBox.square(
                dimension: compact ? 14 : 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.0,
                  color: colorScheme.primary,
                ),
              )
            : Icon(
                Icons.play_arrow_rounded,
                color: colorScheme.primary,
                size: iconSize,
              ),
      ),
    );
  }
}

class _RadioSkeleton extends StatelessWidget {
  const _RadioSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SkeletonBox(width: 140, height: 32, radius: 10),
          const SizedBox(height: 12),
          const _SkeletonBox(width: double.infinity, height: 100, radius: 16),
          const SizedBox(height: 22),
          const _SkeletonBox(width: 120, height: 32, radius: 10),
          const SizedBox(height: 12),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 3,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                return _SkeletonBox(
                  width: 132,
                  height: 190,
                  radius: 16,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioEmpty extends StatelessWidget {
  const _RadioEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 46, 10, 70),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.radio_rounded,
              size: 42,
              color: colorScheme.primary.withValues(alpha: .72),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无电台内容',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _RadioUnsupported extends StatelessWidget {
  const _RadioUnsupported();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 54, 28, 166),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.radio_rounded,
            size: 42,
            color: colorScheme.primary.withValues(alpha: .72),
          ),
          const SizedBox(height: 14),
          Text(
            '电台暂不支持',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            '等接口准备好后再接入这个频道。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 166),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _SkeletonBox(width: 54, height: 26, radius: 8),
                const SizedBox(width: 26),
                const _SkeletonBox(width: 42, height: 26, radius: 8),
                const Spacer(),
                _SkeletonBox.circle(size: 38),
                const SizedBox(width: 12),
                _SkeletonBox.circle(size: 34),
              ],
            ),
            const SizedBox(height: 28),
            const _SkeletonBox(width: double.infinity, height: 44, radius: 9),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final cardSize = (constraints.maxWidth - 10) / 2;
                return Row(
                  children: [
                    _SkeletonBox(width: cardSize, height: cardSize, radius: 12),
                    const SizedBox(width: 10),
                    _SkeletonBox(width: cardSize, height: cardSize, radius: 12),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),
            const _SkeletonBox(width: 128, height: 24, radius: 8),
            const SizedBox(height: 18),
            for (var index = 0; index < 6; index++) ...[
              Row(
                children: [
                  const _SkeletonBox(width: 58, height: 58, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _SkeletonBox(
                          width: double.infinity,
                          height: 16,
                          radius: 6,
                        ),
                        SizedBox(height: 8),
                        _SkeletonBox(width: 140, height: 14, radius: 6),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
          ],
        ),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

  const _SkeletonBox.circle({required double size})
    : width = size,
      height = size,
      radius = size / 2;

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 绝不把 ApiException / URL 等原始异常透出到页面：统一转成可行动的友好文案。
    final friendly = friendlyServiceErrorMessage(message);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text('暂时连接不上音乐服务', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            friendly,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 首页推荐 tab 的组合数据模型（每日推荐 + 推荐歌单 + 新歌速递）。
/// 公开可见是 [HomePageState] 作为 `SwrSectionState<HomePage, HomeData>`
/// 的泛型参数所需；仅在首页内部使用。
class HomeData {
  const HomeData({
    required this.daily,
    required this.playlists,
    this.topSongs = const [],
  });

  final DailyRecommend daily;
  final List<PlaylistSummary> playlists;
  final List<Song> topSongs;
}

class _RadioData {
  const _RadioData({required this.recommended, required this.groups});

  static const empty = _RadioData(recommended: [], groups: []);

  final List<FmStation> recommended;
  final List<FmClassGroup> groups;

  Map<String, dynamic> toCache() {
    return {
      'recommended': recommended.map((s) => s.toCache()).toList(),
      'groups': groups.map((g) => g.toCache()).toList(),
    };
  }

  factory _RadioData.fromCache(Map<String, dynamic> json) {
    return _RadioData(
      recommended: (json['recommended'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FmStation.fromCache)
          .where((s) => s.id.isNotEmpty)
          .toList(),
      groups: (json['groups'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FmClassGroup.fromCache)
          .toList(),
    );
  }
}

String _playCount(int? value) {
  if (value == null) {
    return '精选歌单';
  }
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(1)} 万次播放';
  }
  return '$value 次播放';
}

class _CarQuickStatsPills extends StatefulWidget {
  const _CarQuickStatsPills({
    required this.auth,
    required this.player,
    required this.onSwitchToMyTab,
    required this.api,
    this.isSideBySide = false,
  });

  final AuthController auth;
  final PlayerController player;
  final VoidCallback onSwitchToMyTab;
  final MusicApi api;
  final bool isSideBySide;

  @override
  State<_CarQuickStatsPills> createState() => _CarQuickStatsPillsState();
}

class _CarQuickStatsPillsState extends State<_CarQuickStatsPills> {
  int _historyCount = 0;

  @override
  void initState() {
    super.initState();
    _loadHistoryCount();
  }

  Future<void> _loadHistoryCount() async {
    try {
      final count = await widget.player.getPlaybackHistoryCount();
      if (mounted) {
        setState(() {
          _historyCount = count;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // 外层已有左右 18 留白，这里只留顶部间距，保证与上方特征卡左右对齐。
    const padding = EdgeInsets.only(top: 20);
    return Padding(
      padding: widget.isSideBySide ? EdgeInsets.zero : padding,
      child: Row(
        children: [
          Expanded(
            child: _PillCard(
              title: '已播歌曲',
              value: '$_historyCount',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaybackHistoryPage(
                    api: widget.api,
                    auth: widget.auth,
                    player: widget.player,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _PillCard(
              title: '收藏歌曲',
              value: '${widget.auth.likedCount}',
              onTap: () {
                if (widget.auth.likedPlaylist != null) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlaylistDetailPage(
                        api: widget.api,
                        auth: widget.auth,
                        player: widget.player,
                        playlist: widget.auth.likedPlaylist!,
                      ),
                    ),
                  );
                } else {
                  Toast.info('暂无收藏歌单');
                }
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _PillCard(
              title: '自建歌单',
              value: '${widget.auth.createdPlaylists.length}',
              onTap: widget.onSwitchToMyTab,
            ),
          ),
        ],
      ),
    );
  }
}

class _PillCard extends StatelessWidget {
  const _PillCard({
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _CirclePlayButton(size: 36, iconSize: 20, onTap: onTap),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: colorScheme.onSurface,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}
