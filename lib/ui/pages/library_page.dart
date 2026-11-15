import 'package:flutter/material.dart';
import '../widgets/liquid_glass_ui.dart';
import '../design_tokens.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/account_switcher_sheet.dart';
import '../widgets/app_dialog.dart';
import '../widgets/artwork.dart';
import '../widgets/toast.dart';
import 'cloud_drive_page.dart';
import 'downloaded_songs_page.dart';
import 'mv_collection_page.dart';
import 'playback_history_page.dart';
import 'playlist_detail_page.dart';
import 'settings_page.dart';
import 'local_songs_page.dart';
import '../../controllers/local_music_controller.dart';
import '../../core/pinyin_utils.dart';

/// 歌单排序模式。
enum _PlaylistSortMode { defaultOrder, byName, bySongCount, byCreatedTime }

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  final ScrollController _scrollController = ScrollController();

  /// 是否已滚动（供车机顶栏点中当前「我的」时判断）。
  bool get isScrolled =>
      _scrollController.hasClients && _scrollController.offset > 8.0;

  /// 车机顶栏点中当前「我的」时回到顶部（无刷新）。
  /// 未滚动时直接返回，避免无意义动画。
  Future<void> scrollToTop() async {
    if (!isScrolled) {
      return;
    }
    try {
      await _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      // 滚动中页面已销毁时忽略。
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
  // 折叠状态管理（改 tab 为折叠）
  bool _expandedCreated = true;
  bool _expandedCollected = true;
  bool _expandedAlbums = false;
  bool _expandedCloud = true;

  // 歌单排序模式
  _PlaylistSortMode _sortMode = _PlaylistSortMode.defaultOrder;

  // 多选管理状态（存歌单 ID 而非下标：列表会因 auth 通知重排/重建，
  // 下标会被后台重排静默映射到别的歌单，导致误删）。
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  String _selectedSection = 'created'; // 'created' | 'collected' | 'albums'

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

  bool _isLandscape(BuildContext ctx) {
    final size = MediaQuery.sizeOf(ctx);
    return size.width > size.height;
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          theme: widget.theme,
          downloads: widget.downloads,
          cache: widget.player.cacheService,
          localMusic: widget.localMusic,
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final name = await showDialog<String>(
      context: context,
      // 输入型弹窗不允许点遮罩关闭：误触会丢掉已输入的歌单名；
      // 纯确认型弹窗（playlist_detail 的 _confirm）保持可点遮罩取消。
      barrierDismissible: false,
      barrierColor: AppDialogStyle.barrierColor(),
      // Dialog 内部已按 viewInsets + insetPadding 避让键盘（与删除确认
      // 弹窗同写法），外层禁止再包 AnimatedPadding：双倍吃掉垂直空间后
      // 内容 Column 约束只剩几十 px，按钮溢出画到白卡外面（键盘弹起必现）。
      builder: (_) => const _CreatePlaylistDialog(),
    );
    if (name == null) return;

    await widget.auth.createPlaylist(name);
    if (!mounted) return;
    if (widget.auth.errorMessage != null) {
      Toast.error('创建失败：${widget.auth.errorMessage}');
    } else {
      Toast.success('歌单已创建');
    }
  }

  List<PlaylistSummary> _sortedPlaylists(List<PlaylistSummary> playlists) {
    switch (_sortMode) {
      case _PlaylistSortMode.byName:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        return sorted;
      case _PlaylistSortMode.bySongCount:
        final sorted = List<PlaylistSummary>.of(playlists);
        sorted.sort((a, b) => (b.songCount ?? 0).compareTo(a.songCount ?? 0));
        return sorted;
      case _PlaylistSortMode.byCreatedTime:
      case _PlaylistSortMode.defaultOrder:
        return playlists;
    }
  }

  String get _sortModeLabel {
    return switch (_sortMode) {
      _PlaylistSortMode.defaultOrder => '默认排序',
      _PlaylistSortMode.byName => '按名称',
      _PlaylistSortMode.bySongCount => '按歌曲数',
      _PlaylistSortMode.byCreatedTime => '按创建时间',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_PlaylistSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_PlaylistSortMode.defaultOrder, '默认排序'),
          (_PlaylistSortMode.byName, '按名称'),
          (_PlaylistSortMode.bySongCount, '按歌曲数'),
          (_PlaylistSortMode.byCreatedTime, '按创建时间'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '排序方式',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _SortOptionTile(
                          label: options[i].$2,
                          selected: _sortMode == options[i].$1,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(options[i].$1),
                        ),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 16,
                            color: colorScheme.outlineVariant
                                .withValues(alpha: .3),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (selected != null && selected != _sortMode) {
      setState(() => _sortMode = selected);
    }
  }

  void _enterMultiSelect(String section, PlaylistSummary playlist) {
    setState(() {
      _selectedSection = section;
      _multiSelectMode = true;
      _selectedIds
        ..clear()
        ..add(playlist.id);
    });
  }

  void _toggleSelected(PlaylistSummary playlist) {
    setState(() {
      if (_selectedIds.contains(playlist.id)) {
        _selectedIds.remove(playlist.id);
        if (_selectedIds.isEmpty) {
          _multiSelectMode = false;
        }
      } else {
        _selectedIds.add(playlist.id);
      }
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected(List<PlaylistSummary> currentList) async {
    // 按当前列表把 ID 解析回对象；列表已刷新导致条目消失时跳过。
    final targets = currentList
        .where((playlist) => _selectedIds.contains(playlist.id))
        .toList();
    if (targets.isEmpty) return;

    final confirmed = await showAppConfirmDialog(
      context,
      title: '删除歌单',
      message: '确定要删除选中的 ${targets.length} 个歌单吗？',
      confirmText: '删除',
    );
    if (confirmed != true) return;

    // 逐个删除并统计：批量操作部分失败必须可见，否则用户会误以为全部删掉了。
    var deleted = 0;
    var failed = 0;
    String? firstError;
    for (final playlist in targets) {
      try {
        await widget.auth.deleteOrUncollectPlaylist(playlist);
        // deleteOrUncollectPlaylist 内部经 _run 执行：API 失败只写
        // errorMessage 不抛出（_run 每次开头会清空它），因此它是唯一
        // 可靠的成败信号；同步守卫（系统歌单/缺 listid）才会走 catch。
        final error = widget.auth.errorMessage;
        if (error != null) {
          failed++;
          firstError ??= error;
          debugPrint('[library] 歌单删除失败: $error');
        } else {
          deleted++;
        }
      } catch (error) {
        failed++;
        firstError ??= error.toString();
        debugPrint('[library] 歌单删除失败: $error');
      }
    }
    if (!mounted) return;
    if (failed == 0) {
      Toast.success('已删除 ${targets.length} 个歌单');
    } else if (deleted == 0) {
      Toast.error('删除失败：${firstError ?? '未知错误'}');
    } else {
      Toast.info('已删除 $deleted 个歌单，$failed 个失败');
    }
    _exitMultiSelect();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              widget.auth,
              widget.downloads,
              widget.localMusic,
            ]),
            builder: (context, _) {
              final created = widget.auth.createdPlaylists;
              final collected = widget.auth.collectedPlaylists;
              final albums = widget.auth.collectedAlbums;
              final sortedCreated = _sortedPlaylists(created);
              final sortedCollected = _sortedPlaylists(collected);
              final sortedAlbums = _sortedPlaylists(albums);

              return CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // 1. 顶部 Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '我的',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                  ),
                            ),
                          ),
                          if (!(_isLandscape(context) && widget.theme.carModeEnabled))
                            IconButton(
                              tooltip: '设置',
                              mouseCursor: SystemMouseCursors.click,
                              onPressed: _openSettings,
                              icon: const Icon(Icons.settings_rounded),
                              iconSize: 22,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ),
                  ),

                  // 2. 用户资料头部（同款用户区域）：点击弹出账号切换面板
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => showAccountSwitcherSheet(
                            context,
                            auth: widget.auth,
                            api: widget.api,
                          ),
                          child: _UserProfileHeader(auth: widget.auth),
                        ),
                      ),
                    ),
                  ),

                  // 3. 同款 2x2 核心功能卡片网格（我喜欢、最近播放、本地音乐、已下载）
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                      child: _LibraryQuickGrid(
                        auth: widget.auth,
                        downloads: widget.downloads,
                        localMusic: widget.localMusic,
                        onOpenLiked: widget.auth.likedPlaylist == null
                            ? null
                            : () => _openPlaylist(widget.auth.likedPlaylist!),
                        onOpenRecent: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlaybackHistoryPage(
                              api: widget.api,
                              auth: widget.auth,
                              player: widget.player,
                            ),
                          ),
                        ),
                        onOpenLocal: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => LocalSongsPage(
                              player: widget.player,
                              auth: widget.auth,
                              localMusic: widget.localMusic,
                            ),
                          ),
                        ),
                        onOpenDownloads: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DownloadedSongsPage(
                              api: widget.api,
                              auth: widget.auth,
                              player: widget.player,
                              downloads: widget.downloads,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 3.5 收藏的 MV 入口（一行卡片，带收藏数角标）。
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                      child: Card(
                        margin: EdgeInsets.zero,
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: Icon(
                            Icons.music_video_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: const Text(
                            '收藏的 MV',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          trailing: AnimatedBuilder(
                            animation: MvPlayerController.instance,
                            builder: (context, _) {
                              final count =
                                  MvPlayerController.instance.collectedMvs.length;
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (count > 0)
                                    Text(
                                      '$count',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  const Icon(Icons.chevron_right_rounded),
                                ],
                              );
                            },
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const MvCollectionPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 20)),

                  // 4. 折叠分组 1：我创建的歌单
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我创建的歌单',
                        count: created.length,
                        isExpanded: _expandedCreated,
                        onToggle: () =>
                            setState(() => _expandedCreated = !_expandedCreated),
                        trailingActions: [
                          IconButton(
                            icon: const Icon(Icons.add_rounded, size: 20),
                            visualDensity: VisualDensity.compact,
                            tooltip: '新建歌单',
                            mouseCursor: SystemMouseCursors.click,
                            onPressed: _showCreatePlaylistDialog,
                          ),
                          if (created.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.sort_rounded, size: 19),
                              visualDensity: VisualDensity.compact,
                              tooltip: '排序方式: $_sortModeLabel',
                              mouseCursor: SystemMouseCursors.click,
                              onPressed: () => _showSortSheet(context),
                            ),
                        ],
                        child: _multiSelectMode && _selectedSection == 'created'
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _MultiSelectBar(
                                    selectedCount: _selectedIds.length,
                                    onCancel: _exitMultiSelect,
                                    onDelete: () => _deleteSelected(sortedCreated),
                                  ),
                                  _PlaylistGroup(
                                    playlists: sortedCreated,
                                    multiSelectMode: true,
                                    selectedIds: _selectedIds,
                                    onOpen: _openPlaylist,
                                    onTapInMultiSelect: _toggleSelected,
                                  ),
                                ],
                              )
                            : (sortedCreated.isEmpty
                                ? const _EmptyGroup()
                                : _PlaylistGroup(
                                    playlists: sortedCreated,
                                    onOpen: _openPlaylist,
                                    onLongPress: (playlist) =>
                                        _enterMultiSelect('created', playlist),
                                  )),
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // 5. 折叠分组 2：我收藏的歌单
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我收藏的歌单',
                        count: collected.length,
                        isExpanded: _expandedCollected,
                        onToggle: () => setState(
                            () => _expandedCollected = !_expandedCollected),
                        child: sortedCollected.isEmpty
                            ? const _EmptyGroup()
                            : _PlaylistGroup(
                                playlists: sortedCollected,
                                onOpen: _openPlaylist,
                              ),
                      ),
                    ),
                  ),

                  // 6. 折叠分组 3：收藏的专辑（若有或需要展示）
                  if (albums.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: _CollapsibleSection(
                          title: '收藏的专辑',
                          count: albums.length,
                          isExpanded: _expandedAlbums,
                          onToggle: () => setState(
                              () => _expandedAlbums = !_expandedAlbums),
                          child: sortedAlbums.isEmpty
                              ? const _EmptyGroup()
                              : _PlaylistGroup(
                                  playlists: sortedAlbums,
                                  onOpen: _openPlaylist,
                                ),
                        ),
                      ),
                    ),
                  ],

                  const SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // 7. 折叠分组 4：我的云盘（独立放到最下面）
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: _CollapsibleSection(
                        title: '我的云盘',
                        isExpanded: _expandedCloud,
                        onToggle: () =>
                            setState(() => _expandedCloud = !_expandedCloud),
                        child: _CloudDriveSectionItem(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CloudDrivePage(
                                api: widget.api,
                                auth: widget.auth,
                                player: widget.player,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 底部安全留白，避免内容被悬浮黑胶底栏遮挡
                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
// --- 1. 用户资料头部 (User Profile Header) ---

class _UserProfileHeader extends StatelessWidget {
  const _UserProfileHeader({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final profile = auth.profile;
    final vipInfo = auth.vipInfo;
    final hasVip = vipInfo?.hasVip ?? false;
    final vipLabel = vipInfo?.activeVip?.typeLabel ?? 'VIP';
    final expiry = vipInfo?.expiryDisplay;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 54,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? .35 : .08),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                ),
                ClipOval(
                  child: profile?.avatarUrl == null
                      ? Center(
                          child: Icon(
                            Icons.person_rounded,
                            color: colorScheme.primary,
                            size: 30,
                          ),
                        )
                      : RetryableNetworkImage(
                          url: profile!.avatarUrl!,
                          fit: BoxFit.cover,
                          // 54dp 圆形头像按档位解码（桌面 1.5x 档 /
                          // 移动 2x 档，见 decodeSizeFor），避免整图解码白占内存。
                          cacheWidth: decodeSizeFor(54),
                          cacheHeight: decodeSizeFor(54),
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              Icons.person_rounded,
                              color: colorScheme.primary,
                              size: 30,
                            ),
                          ),
                        ),
                ),
                // 边框环必须叠在头像之上：画在底层装饰上时头像作为 child
                // 会铺满整个圆，把边框内半圈盖住。
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: .24)
                            : Colors.white.withValues(alpha: .95),
                        width: 1.8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile?.nickname ?? '易格音乐 用户',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (hasVip) ...[
                      const SizedBox(width: 8),
                      _VipBadge(label: vipLabel, isDark: isDark),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Container(
                      width: 7.5,
                      height: 7.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: auth.isLoggedIn
                            ? const Color(0xFF4CAF50)
                            : colorScheme.onSurfaceVariant.withValues(alpha: .45),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        hasVip && expiry != null ? expiry : (auth.isLoggedIn ? '已登录' : '未登录'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 账号切换入口暗示（整个头部可点，弹账号切换面板）
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.surfaceContainerHigh,
            ),
            child: Icon(
              Icons.swap_horiz_rounded,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _VipBadge extends StatelessWidget {
  const _VipBadge({required this.label, required this.isDark});

  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // 清新淡雅的香槟金配色，避免土黄/亮金
    final bgGradient = isDark
        ? null
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFF9E8), Color(0xFFFFECB8)],
          );
    final bgColor = isDark ? const Color(0xFF3E3522) : null;
    final borderColor = isDark
        ? const Color(0xFFFFE2A6).withValues(alpha: .32)
        : const Color(0xFFEAD9AE);
    final textColor = isDark ? const Color(0xFFFFE2A6) : const Color(0xFF7A5D2E);
    final iconColor = isDark ? const Color(0xFFFFD68A) : const Color(0xFFC2984A);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        gradient: bgGradient,
        color: bgColor,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.diamond_rounded, size: 11, color: iconColor),
          const SizedBox(width: 3.5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
              color: textColor,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// --- 2. 同款 2x2 核心功能卡片网格 (2x2 Quick Grid) ---

class _LibraryQuickGrid extends StatelessWidget {
  const _LibraryQuickGrid({
    required this.auth,
    required this.downloads,
    required this.localMusic,
    required this.onOpenLiked,
    required this.onOpenRecent,
    required this.onOpenLocal,
    required this.onOpenDownloads,
  });

  final AuthController auth;
  final DownloadController downloads;
  final LocalMusicController localMusic;
  final VoidCallback? onOpenLiked;
  final VoidCallback onOpenRecent;
  final VoidCallback onOpenLocal;
  final VoidCallback onOpenDownloads;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _QuickHubTile(
                icon: Icons.favorite_rounded,
                title: '收藏',
                subtitle: '${auth.likedCount} 首',
                gradientColors: const [Color(0xFFFF85A1), Color(0xFFFF3366)],
                onTap: onOpenLiked,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickHubTile(
                icon: Icons.access_time_filled_rounded,
                title: '最近',
                subtitle: '播放历史',
                gradientColors: const [Color(0xFF70B9FE), Color(0xFF2C7BF6)],
                onTap: onOpenRecent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AnimatedBuilder(
                animation: localMusic,
                builder: (context, _) => _QuickHubTile(
                  icon: Icons.computer_rounded,
                  title: '本地',
                  subtitle: '${localMusic.songs.length} 首',
                  gradientColors: const [Color(0xFF67E3C8), Color(0xFF00BFA5)],
                  onTap: onOpenLocal,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedBuilder(
                animation: downloads,
                builder: (context, _) => _QuickHubTile(
                  icon: Icons.download_done_rounded,
                  title: '已下载',
                  subtitle: '${downloads.downloadedSongs.length} 首',
                  gradientColors: const [Color(0xFF81D4FA), Color(0xFF0288D1)],
                  onTap: onOpenDownloads,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickHubTile extends StatefulWidget {
  const _QuickHubTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradientColors,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> gradientColors;
  final VoidCallback? onTap;

  @override
  State<_QuickHubTile> createState() => _QuickHubTileState();
}

class _QuickHubTileState extends State<_QuickHubTile> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final primaryColor = widget.gradientColors.last;
    final cardBgColor = isDark
        ? (_isHovered
            ? Colors.white.withValues(alpha: .10)
            : Colors.white.withValues(alpha: .06))
        : (_isHovered
            ? Colors.white
            : Colors.white.withValues(alpha: .85));
    final cardBorderColor = isDark
        ? (_isHovered
            ? Colors.white.withValues(alpha: .24)
            : Colors.white.withValues(alpha: .12))
        : (_isHovered
            ? primaryColor.withValues(alpha: .35)
            : Colors.white.withValues(alpha: .92));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isPressed ? 0.95 : (_isHovered ? 1.015 : 1.0),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cardBgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cardBorderColor,
                width: _isHovered ? 1.3 : 1.1,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: _isHovered ? .35 : .20)
                      : (_isHovered
                          ? const Color(0x18000000)
                          : const Color(0x0C000000)),
                  blurRadius: _isHovered ? 14 : 10,
                  offset: Offset(0, _isHovered ? 4 : 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.gradientColors,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withValues(
                          alpha: _isHovered
                              ? (isDark ? .55 : .40)
                              : (isDark ? .40 : .30),
                        ),
                        blurRadius: _isHovered ? 10 : 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

// --- 3. 折叠分组组件 (Collapsible Section) ---

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    this.count,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailingActions,
  });

  final String title;
  final int? count;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final List<Widget>? trailingActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: Tooltip(
            message: isExpanded ? '点击收起 $title' : '点击展开 $title',
            waitDuration: AppDesktopTheme.tooltipWaitDuration,
            child: InkWell(
              onTap: onToggle,
              mouseCursor: SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: isExpanded ? 0.0 : -0.25,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 22,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const Spacer(),
                    ...?trailingActions,
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        AnimatedCrossFade(
          firstChild: child,
          secondChild: const SizedBox.shrink(),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 220),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

// --- 4. 云盘独立列表项组件 (Cloud Drive Section Item) ---

class _CloudDriveSectionItem extends StatelessWidget {
  const _CloudDriveSectionItem({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return LiquidGlassCard(
      borderRadius: AppRadius.lg,
      padding: EdgeInsets.zero,
      enableTouchFlex: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF68B0FB), Color(0xFF3378FF)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF3378FF).withValues(alpha: isDark ? .40 : .30),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '云盘音乐',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '随时随地，同步云端音乐资产',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 5. 排序选项条目 (Sort Option Tile) ---

class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: selected ? colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// --- 6. 多选模式操作栏 (Multi-Select Bar) ---

class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.selectedCount,
    required this.onCancel,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '取消',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: Text(
              '已选中 $selectedCount 项',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: selectedCount > 0 ? onDelete : null,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('删除'),
            style: FilledButton.styleFrom(
              foregroundColor: colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

// --- 7. 空态提示组件 (Empty Group) ---

class _EmptyGroup extends StatelessWidget {
  const _EmptyGroup();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 42,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              '这里还没有内容',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 8. 歌单卡片分组 (Playlist Group) ---

class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({
    required this.playlists,
    required this.onOpen,
    this.multiSelectMode = false,
    this.selectedIds = const {},
    this.onLongPress,
    this.onTapInMultiSelect,
  });

  final List<PlaylistSummary> playlists;
  final void Function(PlaylistSummary) onOpen;
  final bool multiSelectMode;
  final Set<String> selectedIds;
  final void Function(PlaylistSummary playlist)? onLongPress;
  final void Function(PlaylistSummary playlist)? onTapInMultiSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 720;
    final isUltraWide = size.width >= 1200;

    if (isWide) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: isUltraWide ? 280 : 340,
          mainAxisExtent: 72,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          return LiquidGlassCard(
            borderRadius: AppRadius.lg,
            padding: EdgeInsets.zero,
            child: _PlaylistRow(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              playlist: playlists[i],
              selected: multiSelectMode && selectedIds.contains(playlists[i].id),
              multiSelectMode: multiSelectMode,
              onTap: multiSelectMode
                  ? () => onTapInMultiSelect?.call(playlists[i])
                  : () => onOpen(playlists[i]),
              onLongPress: () => onLongPress?.call(playlists[i]),
            ),
          );
        },
      );
    }

    return LiquidGlassCard(
      borderRadius: AppRadius.lg,
      padding: EdgeInsets.zero,
      enableTouchFlex: false,
      child: Column(
        children: [
          for (var i = 0; i < playlists.length; i++) ...[
            _PlaylistRow(
              borderRadius: BorderRadius.circular(AppRadius.md),
              playlist: playlists[i],
              selected: multiSelectMode && selectedIds.contains(playlists[i].id),
              multiSelectMode: multiSelectMode,
              onTap: multiSelectMode
                  ? () => onTapInMultiSelect?.call(playlists[i])
                  : () => onOpen(playlists[i]),
              onLongPress: () => onLongPress?.call(playlists[i]),
            ),
            if (i < playlists.length - 1)
              Divider(
                height: 1,
                indent: 62,
                color: colorScheme.outlineVariant.withValues(alpha: .3),
              ),
          ],
        ],
      ),
    );
  }
}

// --- 9. 歌单列表单项 (Playlist Row) ---

class _PlaylistRow extends StatefulWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.multiSelectMode = false,
    this.borderRadius,
  });

  final PlaylistSummary playlist;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool multiSelectMode;
  final BorderRadius? borderRadius;

  @override
  State<_PlaylistRow> createState() => _PlaylistRowState();
}

class _PlaylistRowState extends State<_PlaylistRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.surfaceContainerHigh;
    final effectiveRadius =
        widget.borderRadius ?? BorderRadius.circular(AppRadius.md);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _isHovered ? hoverColor : Colors.transparent,
          borderRadius: effectiveRadius,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: effectiveRadius,
            mouseCursor: SystemMouseCursors.click,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  if (widget.multiSelectMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: widget.selected
                            ? Icon(
                                Icons.check_circle_rounded,
                                key: const ValueKey('checked'),
                                size: 26,
                                color: colorScheme.primary,
                              )
                            : Icon(
                                Icons.radio_button_unchecked_rounded,
                                key: const ValueKey('unchecked'),
                                size: 26,
                                color: colorScheme.outline,
                              ),
                      ),
                    )
                  else
                    Artwork(
                      url: widget.playlist.coverUrl,
                      size: 44,
                      borderRadius: 8,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.playlist.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.playlist.songCount == null
                              ? (widget.playlist.subtitle ?? '歌单')
                              : '${widget.playlist.songCount} 首歌',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.multiSelectMode)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: colorScheme.outline,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- 10. 创建歌单 Dialog（与删除确认弹窗同语言：18 圆角居中 + 双药丸按钮）---

class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog();

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  var _canSubmit = false;
  var _focused = false;

  /// 弹窗结局一次性消费标记：键盘 submit 与「创建/取消」按钮多入口，先到
  /// 的 pop 之后弹窗进入退出动画，迟到的第二次提交会把弹窗之下的路由顺带
  /// pop 掉（或触发两次创建回调），首点后短路。
  var _resolved = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTextChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    final focused = _focusNode.hasFocus;
    if (focused != _focused && mounted) {
      setState(() => _focused = focused);
    }
  }

  void _handleTextChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit && mounted) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  void _submit([String? value]) {
    final trimmed = (value ?? _controller.text).trim();
    if (trimmed.isEmpty) return;
    _close(trimmed);
  }

  void _close([String? value]) {
    if (_resolved) return;
    _resolved = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppDialogShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppDialogTitle('创建歌单'),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: isDark
                  ? colorScheme.surfaceContainerHighest
                  : const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(12),
              // 常态浅灰描边保证盒子结构可见；聚焦时染主题色，
              // 与搜索胶囊的聚焦细边框同语言。
              border: Border.all(
                color: _focused
                    ? colorScheme.primary.withValues(alpha: 0.6)
                    : (isDark
                        ? colorScheme.outlineVariant.withValues(alpha: 0.5)
                        : const Color(0xFFE2E5EA)),
                width: _focused ? 1.4 : 1,
              ),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              maxLength: 40,
              textInputAction: TextInputAction.done,
              textAlignVertical: TextAlignVertical.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
              decoration: InputDecoration(
                hintText: '请输入歌单名称',
                hintStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
                // 计数器直接隐藏（参考 QQ 样式：只留盒内 hint）；
                // maxLength 仍硬限制 40 字。
                counterText: '',
                // 全局 InputDecorationTheme 是 filled 白底，盖住外层灰底圆角盒
                // 还会露出白色直角（四个角花的元凶），必须显式关掉。
                filled: false,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
              ),
              onSubmitted: _submit,
            ),
          ),
          const SizedBox(height: 20),
          AppDialogPillActions(
            confirmText: '创建',
            confirmEnabled: _canSubmit,
            onCancel: () => _close(),
            onConfirm: _submit,
          ),
        ],
      ),
    );
  }
}
