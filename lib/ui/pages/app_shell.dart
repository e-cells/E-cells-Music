import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/lazy_indexed_stack.dart';
import '../widgets/toast.dart';
import '../widgets/touch_sidebar.dart';
import '../widgets/car_left_player_panel.dart';
import '../adaptive_layout.dart';
import '../desktop/desktop_shell.dart';
import '../keyboard_focus_guard.dart';
import '../keyboard_shortcuts.dart';
import '../form_factor.dart';
import '../player/player_route.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'mv_player_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<AppShell> createState() => _AppShellState();
}

@visibleForTesting
DateTime Function() appShellNow = DateTime.now;

class _AppShellState extends State<AppShell> {
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  final GlobalKey<LibraryPageState> _libraryKey =
      GlobalKey<LibraryPageState>();
  var _index = 1; // Default to '推荐' tab (index 1) in landscape
  var _lastHomeTab =
      1; // Tracks the last active Home sub-tab (1=推荐, 2=排行榜, 3=电台)
  final _navigatorKey = GlobalKey<NavigatorState>();
  DateTime? _lastRailHomeTapTime;
  DateTime? _lastDoubleTapExecutedTime;

  /// 车机顶栏点中当前 tab：直接回到顶部并刷新（含均衡器动画，
  /// 与移动端点中当前 tab 语义一致）。不判断是否滚动过——在当前页
  /// 再点一次就刷新，逻辑简单明确；已在顶部时回顶动画自然无操作。
  /// 「我的」无刷新内容，只回顶；「推荐/排行榜/电台」回顶并刷新对应内容。
  void _handleCarTabReselect(int index) {
    if (index == 0) {
      unawaited(_libraryKey.currentState?.scrollToTop());
    } else {
      unawaited(_homeKey.currentState?.scrollToTopAndRefresh());
    }
  }

  int _getPortraitIndex() {
    return _index == 0 ? 1 : 0;
  }

  void _setPortraitIndex(int index) {
    _setShellIndex(index == 0 ? _lastHomeTab : 0);
  }

  /// 按 shellIndex 切换选中分区（语义与 [_index] 一致：
  /// 0=我的，1=推荐，2=排行榜，3=电台）。
  /// 切到首页子 tab 时同步记录 [_lastHomeTab]，单击「首页/推荐」
  /// 返回时恢复到最后浏览的子 tab。
  void _setShellIndex(int shellIndex) {
    setState(() {
      _index = shellIndex;
      if (shellIndex >= 1 && shellIndex <= 3) {
        _lastHomeTab = shellIndex;
      }
    });
  }

  void _handleHomeDoubleTap() {
    final now = appShellNow();
    if (_lastDoubleTapExecutedTime != null &&
        now.difference(_lastDoubleTapExecutedTime!) <
            const Duration(milliseconds: 350)) {
      return;
    }
    _lastDoubleTapExecutedTime = now;

    final needSwitch = _getPortraitIndex() != 0;
    if (needSwitch) {
      _setPortraitIndex(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_homeKey.currentState?.scrollToTopAndRefresh());
      });
    } else {
      unawaited(_homeKey.currentState?.scrollToTopAndRefresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShortcutScope(player: widget.player, child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    // 桌面形态（Windows 等）：独立的桌面骨架（侧栏 + 底部播放栏）。
    // 判定只看平台（form_factor.dart），Android 车机/平板/手机不受影响；
    // 车机模式在桌面形态下不生效（本分支先行返回）。
    if (isDesktopFormFactor) {
      return DesktopShell(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        cache: widget.cache,
        downloads: widget.downloads,
        theme: widget.theme,
        localMusic: widget.localMusic,
      );
    }

    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    // 车机布局：仅在横屏且开启车机模式时启用（左侧播放面板 + 顶栏）。
    // 关闭时回到普通布局（宽屏用 NavigationRail），与原项目行为一致；
    // 平板横屏适配留给上游后续开发。
    if (isLandscape && widget.theme.carModeEnabled) {
      // 车机模式下文字相对放大（保留系统无障碍设置）。
      final baseTextScaler = MediaQuery.textScalerOf(context);
      final scaledTextScaler = _RelativeTextScaler(
        base: baseTextScaler,
        multiplier: ThemeController.carModeFontScaleFactor,
      );
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaledTextScaler),
        child: PopScope(
          // 拦截 Android 返回键：先尝试 pop 内层 Navigator（搜索/设置/歌单等
          // push 到内层 Navigator 的页面），内层无法 pop 时才退出应用。
          // 不加 PopScope 会导致返回键只 pop root Navigator（只有一个 AppShell
          // route），从歌单页面返回直接退出应用。
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final nav = _navigatorKey.currentState;
            if (nav != null && nav.canPop()) {
              nav.pop();
            } else {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            body: Row(
              children: [
                // ExcludeSemantics 规避频繁响应 player 更新导致的
                // Windows AXTree 竞态崩溃（Flutter Windows 引擎 bug，
                // 上游 flutter/flutter#190357 / #192180 仍未修复；
                // 详见 main.dart 全局 workaround 处说明）。
                // 仅桌面平台排除；车机分支跑在 Android 上，必须保留语义。
                ExcludeSemantics(
                  excluding: isDesktopPlatform,
                  child: CarLeftPlayerPanel(
                    player: widget.player,
                    auth: widget.auth,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: Navigator(
                    key: _navigatorKey,
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute(
                        builder: (navContext) {
                          final homePage = HomePage(
                            key: _homeKey,
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            cache: widget.cache,
                            theme: widget.theme,
                            downloads: widget.downloads,
                            localMusic: widget.localMusic,
                            // 切到「我的」时保持最后一个首页子 tab，而非塌缩为 0：
                            // 否则 HomePage.didUpdateWidget 会 animateToPage(0)，
                            // 动画途中 onPageChanged 回调 onTabSwitch(1) 把用户弹回首页。
                            sectionIndex: _index > 0 ? _index - 1 : _lastHomeTab - 1,
                            onTabSwitch: (index) {
                              setState(() {
                                _index = index;
                                if (index >= 1 && index <= 3) {
                                  _lastHomeTab = index;
                                }
                              });
                            },
                          );

                          final libraryPage = LibraryPage(
                            key: _libraryKey,
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            downloads: widget.downloads,
                            theme: widget.theme,
                            localMusic: widget.localMusic,
                          );

                          final pages = [homePage, libraryPage];
                          final activePageIndex = _index == 0 ? 1 : 0;

                          return Scaffold(
                            body: Column(
                              children: [
                                _buildCarTopNavBar(navContext),
                                const Divider(height: 1),
                                Expanded(
                                  child: LazyIndexedStack(
                                    index: activePageIndex,
                                    children: pages,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Original Portrait Layout
    final useTouchSidebar = AdaptiveLayout.isTouchSidebarWidth(size.width);
    final portraitIndex = _getPortraitIndex();

    final homePage = HomePage(
      key: _homeKey,
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      cache: widget.cache,
      theme: widget.theme,
      downloads: widget.downloads,
      localMusic: widget.localMusic,
      // 同车机分支：在「我的」页保持最后的首页子 tab，防止 HomePage 收到
      // sectionIndex 变化后动画回首页、经 onPageChanged 把用户弹回。
      sectionIndex: _index > 0 ? _index - 1 : _lastHomeTab - 1,
      onTabSwitch: (index) {
        setState(() {
          _index = index;
          if (index >= 1 && index <= 3) {
            _lastHomeTab = index;
          }
        });
      },
    );

    final libraryPage = LibraryPage(
      key: _libraryKey,
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      downloads: widget.downloads,
      theme: widget.theme,
      localMusic: widget.localMusic,
    );

    final pages = [homePage, libraryPage];

    // 宽屏（平板）形态：迷你播放器停靠侧栏底部，主内容区不再叠全宽迷你条。
    Widget mainContent = LazyIndexedStack(
      index: portraitIndex,
      children: pages,
    );

    if (useTouchSidebar) {
      // 平板触屏侧栏：把首页三个子 tab（推荐/排行榜/电台）与「我的」
      // 全部提升为一级导航，顶部搜索胶囊直达搜索页（替代被顶栏收起的
      // 移动端搜索栏），底部停靠迷你播放器。
      mainContent = Row(
        children: [
          TouchSidebar(
            items: const [
              TouchSidebarItem(
                icon: Icons.explore_outlined,
                activeIcon: Icons.explore_rounded,
                label: '推荐',
              ),
              TouchSidebarItem(
                icon: Icons.leaderboard_outlined,
                activeIcon: Icons.leaderboard_rounded,
                label: '排行榜',
              ),
              TouchSidebarItem(
                icon: Icons.radio_outlined,
                activeIcon: Icons.radio_rounded,
                label: '电台',
              ),
              TouchSidebarItem(
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: '我的',
              ),
            ],
            // 条目序号 → shellIndex（0=我的，1/2/3=首页子 tab）。
            selectedIndex: _index == 0 ? 3 : _index - 1,
            onSelect: (itemIndex) {
              final shellIndex = itemIndex == 3 ? 0 : itemIndex + 1;
              // 双击「推荐」：回顶 + 刷新（与底栏/旧 NavigationRail 行为一致）。
              if (shellIndex == 1) {
                final now = appShellNow();
                if (_lastRailHomeTapTime != null &&
                    now.difference(_lastRailHomeTapTime!) <
                        const Duration(milliseconds: 350)) {
                  _lastRailHomeTapTime = null;
                  _handleHomeDoubleTap();
                  return;
                }
                _lastRailHomeTapTime = now;
              } else {
                _lastRailHomeTapTime = null;
              }
              _setShellIndex(shellIndex);
            },
            onSearchTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            player: widget.player,
            auth: widget.auth,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: mainContent),
        ],
      );
    }

    return Scaffold(
      extendBody: true,
      body: AdaptiveContentPadding(child: mainContent),
      bottomNavigationBar: useTouchSidebar
          ? null
          : _FloatingBottomBar(
              currentIndex: portraitIndex,
              onTap: _setPortraitIndex,
              onHomeDoubleTap: _handleHomeDoubleTap,
              player: widget.player,
              auth: widget.auth,
            ),
    );
  }

  Widget _buildCarTopNavBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tabs = ['我的', '推荐', '排行榜', '电台'];
    final topInset = MediaQuery.paddingOf(context).top;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      // 顶部加上状态栏高度，避免导航栏内容被状态栏遮挡
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      height: 72 + topInset, // Increased from 64
      child: Row(
        children: [
          // Search Pill Button — 纯搜索入口，点击直达搜索页，杜绝首页误触
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: isDark
                    ? colorScheme.surfaceContainerHighest
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: .54,
                      ),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: isDark
                      ? colorScheme.outlineVariant.withValues(alpha: .85)
                      : colorScheme.outlineVariant.withValues(alpha: .45),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_rounded,
                    color: isDark
                        ? colorScheme.onSurface.withValues(alpha: .92)
                        : colorScheme.onSurfaceVariant,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: isDark
                          ? colorScheme.onSurface.withValues(alpha: .92)
                          : colorScheme.onSurfaceVariant,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          // Choice Chip Tabs
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in tabs.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ), // Increased from 6
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: Text(
                          entry.$2,
                          style: TextStyle(
                            fontSize: 17, // Increased from default
                            fontWeight: _index == entry.$1
                                ? FontWeight.w900
                                : FontWeight.w600,
                          ),
                        ),
                        selected: _index == entry.$1,
                        onSelected: (selected) {
                          if (selected) {
                            // 切到其它页面：只切换、保持各页滚动位置，不刷新。
                            setState(() {
                              _index = entry.$1;
                              if (entry.$1 >= 1 && entry.$1 <= 3) {
                                _lastHomeTab = entry.$1;
                              }
                            });
                          } else {
                            // 点中当前页面：回顶并刷新，不切换页面。
                            _handleCarTabReselect(entry.$1);
                          }
                        },
                        selectedColor: colorScheme.primary.withValues(
                          alpha: 0.18,
                        ),
                        labelStyle: TextStyle(
                          color: _index == entry.$1
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        backgroundColor: Colors.transparent,
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ), // Added explicit padding
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            12,
                          ), // Added explicit shape for larger tap area
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Settings Icon
          IconButton(
            tooltip: '设置',
            iconSize: 28, // Increased iconSize from default (24)
            icon: const Icon(Icons.settings_rounded),
            onPressed: () {
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
            },
          ),
        ],
      ),
    );
  }
}

/// 悬浮胶囊底栏（实色，无 BackdropFilter）— 参考上游 ` _LiquidGlassBottomBar` 的居中唱片交互，
/// 但以实色 + 轻阴影实现，避免 `ImageFilter.blur` 在车机/低端机上的离屏缓冲与掉帧。
class _FloatingBottomBar extends StatefulWidget {
  const _FloatingBottomBar({
    required this.currentIndex,
    required this.onTap,
    this.onHomeDoubleTap,
    required this.player,
    required this.auth,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onHomeDoubleTap;
  final PlayerController player;
  final AuthController auth;

  @override
  State<_FloatingBottomBar> createState() => _FloatingBottomBarState();
}

class _FloatingBottomBarState extends State<_FloatingBottomBar> {
  DateTime? _lastHomeTapTime;

  void _handleHomeTap() {
    // 双击检测只用这里的计时窗口：不注册 InkWell.onDoubleTap，
    // 否则 Flutter 会为消歧而把每次单击推迟 ~300ms 才派发。
    final now = appShellNow();
    if (_lastHomeTapTime != null &&
        now.difference(_lastHomeTapTime!) < const Duration(milliseconds: 350)) {
      _lastHomeTapTime = null;
      widget.onHomeDoubleTap?.call();
      return;
    }
    _lastHomeTapTime = now;
    widget.onTap(0);
  }

  void _handleLibraryTap() {
    _lastHomeTapTime = null;
    widget.onTap(1);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset > 0 ? bottomInset : 12),
        child: Container(
          height: 62,
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2433) : Colors.white,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: .12)
                  : colorScheme.outlineVariant.withValues(alpha: .5),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? .28 : .12),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _BottomNavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: '首页',
                selected: widget.currentIndex == 0,
                onTap: _handleHomeTap,
              ),
              _CenterDisc(player: widget.player, auth: widget.auth),
              _BottomNavItem(
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: '我的',
                selected: widget.currentIndex == 1,
                onTap: _handleLibraryTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        splashColor: colorScheme.primary.withValues(alpha: .10),
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? activeIcon : icon,
              size: 24,
              color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
class CenterDisc extends StatelessWidget {
  const CenterDisc({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  void _openPlayer(BuildContext context) {
    final mvPlayer = MvPlayerController.instance;
    if (mvPlayer.hasActiveSession && !player.isPlaying) {
      unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
      return;
    }
    // 无歌曲时不进播放页：首次安装尚未播放，直接给轻提示，避免白屏。
    if (player.currentSong == null) {
      Toast.info('先去挑选一首喜欢的歌曲吧');
      return;
    }
    PlayerPageRoute.open(context, player: player, auth: auth);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _openPlayer(context),
      onLongPress: () {
        if (player.currentSong != null) {
          HapticFeedback.lightImpact();
          player.togglePlay();
        }
      },
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          final hasSong = song != null;
          // 进度环单独听 positionListenable：position 字段只在大 notify 才变，
          // 直接读它圆环播放中会 frozen，这里用 tick 值驱动
          final progressRing = ValueListenableBuilder<Duration>(
            valueListenable: player.positionListenable,
            builder: (context, pos, _) {
              final durationMs = player.duration.inMilliseconds;
              final progress = (durationMs > 0 && hasSong
                      ? pos.inMilliseconds / durationMs
                      : 0.0)
                  .clamp(0.0, 1.0);
              return SizedBox(
                width: 52,
                height: 52,
                child: CircularProgressIndicator(
                  value: hasSong ? progress : 0,
                  strokeWidth: 2.5,
                  backgroundColor:
                      colorScheme.outlineVariant.withValues(alpha: .35),
                  valueColor:
                      AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
              );
            },
          );
          return SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 进度环
                progressRing,
                // 封面
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: .9), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: hasSong
                        ? Artwork(url: song.coverUrl, size: 42, borderRadius: 21)
                        : Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(Icons.music_note_rounded,
                                size: 22, color: colorScheme.onSurfaceVariant),
                          ),
                  ),
                ),
                // 播放/暂停小图标叠加（无歌时隐藏）
                if (hasSong)
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .45),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

typedef _CenterDisc = CenterDisc;

/// 在已有 [TextScaler] 基础上再乘固定倍数（Flutter 内置 TextScaler 无 `*` 运算符）。
class _RelativeTextScaler extends TextScaler {
  const _RelativeTextScaler({required this.base, required this.multiplier});

  final TextScaler base;
  final double multiplier;

  @override
  double scale(double fontSize) => base.scale(fontSize) * multiplier;

  @override
  double get textScaleFactor {
    // ignore: deprecated_member_use
    final baseFactor = base.textScaleFactor;
    return baseFactor * multiplier;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _RelativeTextScaler &&
          base == other.base &&
          multiplier == other.multiplier;

  @override
  int get hashCode => Object.hash(base, multiplier);

  @override
  String toString() => '$base × $multiplier';
}

/// 全局快捷键作用域（双端共用，按 [isDesktopFormFactor] 选表）：
///
/// - 移动/车机端（历史行为保持）：空格播放/暂停，←/→ 切歌，↑/↓ 音量。
/// - 桌面端：空格播放/暂停（焦点在可滚动区域时退让给滚动翻页），
///   ←/→ 快退/快进 ±5 秒，Ctrl+←/→ 切歌，↑/↓ 音量。
///   按键表映射见 keyboard_shortcuts.dart。
class AppShortcutScope extends StatelessWidget {
  const AppShortcutScope({
    super.key,
    required this.player,
    required this.child,
  });

  final PlayerController player;
  final Widget child;

  Map<ShortcutActivator, Intent> _buildShortcutTable({required bool desktop}) {
    Intent bindingsFor(AppShortcutAction action) => switch (action) {
          AppShortcutAction.playPause => const _PlayPauseIntent(),
          AppShortcutAction.previousTrack => const _PreviousIntent(),
          AppShortcutAction.nextTrack => const _NextIntent(),
          AppShortcutAction.seekBackward => const _SeekIntent(backward: true),
          AppShortcutAction.seekForward => const _SeekIntent(backward: false),
          AppShortcutAction.volumeUp => const _VolumeUpIntent(),
          AppShortcutAction.volumeDown => const _VolumeDownIntent(),
        };
    return {
      for (final action in AppShortcutAction.values)
        for (final activator in appShortcutActivators(action, desktop: desktop))
          activator: bindingsFor(action),
    };
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopFormFactor;
    return Shortcuts(
      shortcuts: _buildShortcutTable(desktop: desktop),
      child: Actions(
        actions: {
          _PlayPauseIntent: GuardedCallbackAction<_PlayPauseIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              if (desktop && isFocusInsideScrollableRegion()) {
                // 空格退让：焦点在普通可滚动区域内 → 向下翻一页。
                scrollFocusedRegionByPage(forward: true);
              } else {
                player.togglePlay();
              }
              return null;
            },
          ),
          _NextIntent: GuardedCallbackAction<_NextIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              unawaited(player.next());
              return null;
            },
          ),
          _PreviousIntent: GuardedCallbackAction<_PreviousIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              unawaited(player.previous());
              return null;
            },
          ),
          _SeekIntent: GuardedCallbackAction<_SeekIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (intent) {
              final target = computeSeekTarget(
                position: player.position,
                duration: player.duration,
                forward: !intent.backward,
              );
              if (target != null) {
                // seek 非 idle 下引擎异常会抛错，快捷键无 context 可提示，
                // 仅日志吞掉，避免未处理异步异常上报
                unawaited(
                  player.seek(target).catchError((Object error) {
                    debugPrint('[易格][shortcut] seek 失败已忽略: $error');
                  }),
                );
              }
              return null;
            },
          ),
          _VolumeUpIntent: GuardedCallbackAction<_VolumeUpIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              player.setVolume((player.volume + 0.05).clamp(0.0, 1.0));
              return null;
            },
          ),
          _VolumeDownIntent: GuardedCallbackAction<_VolumeDownIntent>(
            desktop: desktop,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              player.setVolume((player.volume - 0.05).clamp(0.0, 1.0));
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

/// ←/→ 快退/快进（桌面端），[backward] 为 true 表示快退。
class _SeekIntent extends Intent {
  const _SeekIntent({required this.backward});
  final bool backward;
}

class _VolumeUpIntent extends Intent {
  const _VolumeUpIntent();
}

class _VolumeDownIntent extends Intent {
  const _VolumeDownIntent();
}
