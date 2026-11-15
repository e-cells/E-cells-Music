import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/mv_card.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/album_grid.dart';
import '../widgets/app_song_row.dart';
import '../widgets/desktop_song_table_row.dart';
import '../adaptive_layout.dart';
import '../form_factor.dart';
import '../player/song_tap_handler.dart';
import 'mv_player_page.dart';
import 'playlist_detail_page.dart';

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.artist,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final ArtistRef artist;
  final PlayerController player;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

enum _ArtistTab { songs, albums, mvs }

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  static const _pageSize = 30;

  /// 头部展开高度（移动端）。
  static const _headerExpandedHeightMobile = 286.0;

  /// 头部展开高度（PC 桌面端）。
  static const _headerExpandedHeightDesktop = 210.0;

  final _scrollController = ScrollController();
  final _songs = <Song>[];
  final _albums = <ArtistAlbum>[];

  // ===== MV tab：按 tag 懒加载的分页列表 =====
  final _mvs = <MvInfo>[];
  var _mvTag = 'all';
  var _mvPage = 1;
  var _mvHasMore = true;
  var _mvLoading = false;
  var _mvLoadedForTag = '';

  _ArtistTab _selectedTab = _ArtistTab.songs;
  bool _isProgressiveLoading = false;
  int _progressiveEpoch = 0;

  ArtistDetail? _detail;
  String? _resolvedArtistId;
  String? _focusedSongKey;
  var _nextPage = 1;
  var _hasMore = true;
  var _isInitialLoading = true;
  var _isLoadingMore = false;
  var _isHeaderCollapsed = false;
  String? _errorMessage;
  String? _loadMoreError;

  /// 专辑卡片路由防重入时间戳（桌面双击会连触两次 onTap）。
  DateTime? _lastAlbumNavAt;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _progressiveEpoch++;
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _songs.clear();
    _detail = null;
    super.dispose();
  }

  Future<void> _loadInitial() async {
    _progressiveEpoch++;
    setState(() {
      _detail = null;
      _songs.clear();
      _albums.clear();
      _nextPage = 1;
      _hasMore = true;
      _isInitialLoading = true;
      _isLoadingMore = false;
      _isProgressiveLoading = false;
      _isHeaderCollapsed = false;
      _errorMessage = null;
      _loadMoreError = null;
    });

    try {
      var artistId = widget.artist.id;

      // If no ID (e.g. from search results), try to find it by name
      if (artistId.isEmpty && widget.artist.name.isNotEmpty) {
        final targetName = widget.artist.name.toLowerCase();

        // Try 1: search songs and match artist name
        final searchResults = await widget.api.searchSongs(
          widget.artist.name,
          pageSize: 10,
        );
        for (final song in searchResults) {
          for (final a in song.artists) {
            if (a.id.isNotEmpty && a.name.toLowerCase().contains(targetName)) {
              artistId = a.id;
              break;
            }
          }
          if (artistId.isNotEmpty) break;
        }
      }

      if (artistId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _errorMessage = '未找到该歌手';
          _isInitialLoading = false;
        });
        return;
      }

      _resolvedArtistId = artistId;

      final results = await Future.wait([
        widget.api.artistDetail(artistId),
        widget.api.artistAudios(
          artistId,
          page: 1,
          pageSize: _pageSize,
          sort: 'hot',
        ),
        _loadAlbumsSafe(artistId),
      ]);
      if (!mounted) return;

      final detail = results[0] as ArtistDetail;
      final songs = results[1] as List<Song>;
      final albums = results[2] as List<ArtistAlbum>;
      setState(() {
        _detail = detail;
        _songs.addAll(songs);
        _albums.addAll(albums);
        _nextPage = 2;
        _hasMore = songs.length == _pageSize;
        _isInitialLoading = false;
      });
      if (_hasMore) {
        _startProgressiveLoading();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _isInitialLoading = false;
      });
    }
  }

  Future<void> _startProgressiveLoading() async {
    if (_isProgressiveLoading || !_hasMore) return;
    _isProgressiveLoading = true;
    final epoch = _progressiveEpoch;

    try {
      while (_hasMore && mounted && epoch == _progressiveEpoch) {
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted || !_hasMore || epoch != _progressiveEpoch) break;

        final songs = await widget.api.artistAudios(
          _resolvedArtistId ?? widget.artist.id,
          page: _nextPage,
          pageSize: _pageSize,
          sort: 'hot',
        );
        if (!mounted || epoch != _progressiveEpoch) break;

        if (songs.isEmpty) {
          setState(() {
            _hasMore = false;
          });
          break;
        }

        setState(() {
          _songs.addAll(songs);
          _nextPage++;
          _hasMore = songs.length == _pageSize;
        });
      }
    } catch (_) {
      // 静默加载失败忽略，由用户触底手动重试
    } finally {
      if (epoch == _progressiveEpoch) {
        if (mounted) {
          setState(() {
            _isProgressiveLoading = false;
          });
        } else {
          _isProgressiveLoading = false;
        }
      }
    }
  }

  void _onScroll() {
    _maybeLoadMore();

    // 头部完全收起（滚动距离 >= 展开高度 - 工具栏高度）后，把顶栏从
    // 透明切为不透明底色 + 主题色图标：透明工具栏会让列表内容从返回键
    // 下方穿透，收起瞬间头部照片刚好完全离开视口，切换不会突兀。
    final expandedHeight = isDesktopFormFactor
        ? _headerExpandedHeightDesktop
        : _headerExpandedHeightMobile;
    final collapsed =
        _scrollController.hasClients &&
        _scrollController.offset >= expandedHeight - kToolbarHeight;
    if (collapsed != _isHeaderCollapsed) {
      setState(() => _isHeaderCollapsed = collapsed);
    }
  }

  void _maybeLoadMore() {
    // 初始骨架也可滚动：初始加载期间禁止加载更多，避免重复拉第 1 页。
    if (!_scrollController.hasClients ||
        !_hasMore ||
        _isInitialLoading ||
        _isLoadingMore ||
        _isProgressiveLoading) {
      return;
    }

    final position = _scrollController.position;
    if (position.extentAfter < 520) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isProgressiveLoading) return;

    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    try {
      final songs = await widget.api.artistAudios(
        _resolvedArtistId ?? widget.artist.id,
        page: _nextPage,
        pageSize: _pageSize,
        sort: 'hot',
      );
      if (!mounted) return;

      setState(() {
        _songs.addAll(songs);
        _nextPage++;
        _hasMore = songs.length == _pageSize;
        _isLoadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadMoreError = error.toString();
        _isLoadingMore = false;
      });
    }
  }

  /// 专辑列表失败时降级为空，不阻塞歌手详情与歌曲加载。
  Future<List<ArtistAlbum>> _loadAlbumsSafe(String artistId) async {
    try {
      return await widget.api.artistAlbums(artistId, pageSize: 20);
    } catch (_) {
      return const [];
    }
  }

  // ===== MV tab：懒加载（首次切到 MV tab 才请求） =====

  void _ensureMvsLoaded() {
    if (_mvLoadedForTag == _mvTag && _mvs.isNotEmpty) return;
    unawaited(_loadMvs(refresh: true));
  }

  void _switchMvTag(String tag) {
    if (_mvTag == tag) return;
    setState(() => _mvTag = tag);
    unawaited(_loadMvs(refresh: true));
  }

  Future<void> _loadMvs({bool refresh = false}) async {
    final artistId = _resolvedArtistId ?? widget.artist.id;
    if (artistId.isEmpty || _mvLoading) return;
    final page = refresh ? 1 : _mvPage;
    setState(() {
      _mvLoading = true;
      if (refresh) {
        _mvs.clear();
        _mvHasMore = true;
      }
    });
    try {
      final mvs = await widget.api.artistMvs(
        artistId,
        page: page,
        pageSize: _pageSize,
        tag: _mvTag,
      );
      if (!mounted) return;
      setState(() {
        if (page == 1) {
          _mvs
            ..clear()
            ..addAll(mvs);
        } else {
          _mvs.addAll(mvs);
        }
        _mvPage = page + 1;
        _mvHasMore = mvs.length >= _pageSize;
        _mvLoadedForTag = _mvTag;
      });
    } catch (_) {
      // MV 列表失败降级为空态，不阻塞歌曲/专辑。
      if (mounted) setState(() => _mvHasMore = false);
    } finally {
      if (mounted) setState(() => _mvLoading = false);
    }
  }

  /// 播放歌手 MV：当前列表作为队列（与歌曲点播同构）。
  void _playMv(MvInfo mv) {
    final mvPlayer = MvPlayerController.instance;
    if (MvInfo.isSameMv(mvPlayer.currentMv, mv) && mvPlayer.hasActiveSession) {
      if (!mvPlayer.isPlaying && !mvPlayer.isPreparing) {
        unawaited(mvPlayer.togglePlay());
      }
      unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
      return;
    }
    unawaited(mvPlayer.playMv(mv, queue: List<MvInfo>.of(_mvs)));
    unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
  }

  void _openAlbum(ArtistAlbum album) {
    // 路由防重入：桌面端双击会连续触发两次 onTap，600ms 内只 push 一次，
    // 避免叠两层相同专辑页。
    final now = DateTime.now();
    final last = _lastAlbumNavAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 600)) {
      return;
    }
    _lastAlbumNavAt = now;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: PlaylistSummary(
            id: album.id,
            title: album.name,
            subtitle: album.authorName ?? widget.artist.name,
            coverUrl: album.coverUrl,
            // 标记专辑侧 ID，使 isCollectedAlbum/albumId 走专辑分支（/album/songs）。
            sourceListId: album.id,
          ),
        ),
      ),
    );
  }

  String _songKey(Song song) =>
      song.hash.isNotEmpty ? song.hash : song.id;

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => ArtistRef(id: '', name: song.artist),
    );
    if (artist.name.isEmpty) return;
    if (artist.id.isNotEmpty &&
        (_resolvedArtistId == artist.id || widget.artist.id == artist.id)) {
      return;
    }
    if (artist.name == widget.artist.name || artist.name == _detail?.name) {
      return;
    }
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

  void _showSongMenu(Song song, {Offset? anchor}) {
    showSongActionSheet(
      context: context,
      song: song,
      anchor: anchor,
      actions: [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: widget.player,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: widget.auth,
            song: song,
          ),
        ),
        if (widget.player.downloadController != null)
          SongSheetAction(
            icon: widget.player.downloadController!.isDownloaded(song)
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            title: widget.player.downloadController!.isDownloaded(song)
                ? '已下载'
                : '下载',
            onTap: () => widget.player.downloadController!
                .download(song, widget.player.audioQuality),
          ),
      ],
    );
  }

  Widget _buildMobileAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final artistName = _detail?.name ?? widget.artist.name;
    return SliverAppBar(
      pinned: true,
      expandedHeight: _headerExpandedHeightMobile,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      // 展开态透明叠在头部照片上（白色返回键）；收起后换不透明
      // 底色 + 主题色，避免歌曲列表从工具栏下方穿透。
      backgroundColor: _isHeaderCollapsed
          ? theme.scaffoldBackgroundColor
          : Colors.transparent,
      foregroundColor: _isHeaderCollapsed
          ? theme.colorScheme.onSurface
          : Colors.white,
      title: AnimatedOpacity(
        opacity: _isHeaderCollapsed ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Text(
          artistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: _ArtistHeader(
          detail: _detail,
          fallback: widget.artist,
        ),
      ),
    );
  }

  Widget _buildDesktopAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final artistName = _detail?.name ?? widget.artist.name;
    return SliverAppBar(
      pinned: true,
      expandedHeight: _headerExpandedHeightDesktop,
      surfaceTintColor: Colors.transparent,
      backgroundColor: colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: .08),
      foregroundColor: colorScheme.onSurface,
      title: AnimatedBuilder(
        animation: _scrollController,
        builder: (context, _) {
          var collapsed = false;
          if (_scrollController.hasClients) {
            final delta = _headerExpandedHeightDesktop - kToolbarHeight;
            collapsed = delta <= 0 || _scrollController.offset > delta - 40;
          }
          return AnimatedOpacity(
            opacity: collapsed ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Text(
              artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        },
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: _DesktopArtistHeroHeader(
          detail: _detail,
          fallback: widget.artist,
          songsCount: _songs.length,
          albumsCount: _albums.length,
          hasMore: _hasMore,
          onPlayAll: _songs.isEmpty
              ? null
              : () => widget.player.playSong(
                  _songs.first,
                  queue: List<Song>.of(_songs),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // MiniPlayer 高度约 64，距底部 16，合计预留空间防止遮挡最后一首歌
    final miniPlayerSpace = bottomInset + 64 + 16;
    final theme = Theme.of(context);
    return Scaffold(
      body: AdaptiveContentPadding(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  if (isDesktopFormFactor)
                    _buildDesktopAppBar(context)
                  else
                    _buildMobileAppBar(context),
                  if (_isInitialLoading)
                    const _ArtistDetailSkeleton()
                  else if (_errorMessage case final message?)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _ArtistDetailError(
                        message: message,
                        onRetry: _loadInitial,
                      ),
                    )
                  else ...[
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _ArtistTabHeaderDelegate(
                        selectedTab: _selectedTab,
                        songsCount: _songs.length,
                        albumsCount: _albums.length,
                        mvsCount: _mvs.length,
                        onTabSelected: (tab) {
                          if (_selectedTab != tab) {
                            setState(() => _selectedTab = tab);
                            if (tab == _ArtistTab.mvs) _ensureMvsLoaded();
                          }
                        },
                      ),
                    ),
                    if (_selectedTab == _ArtistTab.songs) ...[
                      SliverToBoxAdapter(
                        child: _SongSectionHeader(
                          count: _songs.length,
                          onPlayAll: _songs.isEmpty
                              ? null
                              : () => widget.player.playSong(
                                  _songs.first,
                                  queue: List<Song>.of(_songs),
                                ),
                        ),
                      ),
                      if (_songs.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyArtistSongs(),
                        )
                      else ...[
                        if (isDesktopFormFactor) ...[
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _ArtistTableStickyHeaderDelegate(
                              child: Container(
                                color: theme.colorScheme.surface,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: const DesktopSongTableHeader(
                                  selecting: false,
                                  allSelected: false,
                                  onToggleSelectAll: null,
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            sliver: SliverFixedExtentList(
                              itemExtent: DesktopSongTableRow.rowHeight,
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final song = _songs[index];
                                  return DesktopSongTableRow(
                                    song: song,
                                    index: index + 1,
                                    player: widget.player,
                                    auth: widget.auth,
                                    canDelete: false,
                                    selecting: false,
                                    selected: false,
                                    isFocused: _focusedSongKey == _songKey(song),
                                    onTap: () {
                                      setState(() => _focusedSongKey = _songKey(song));
                                    },
                                    onDoubleTap: () {
                                      widget.player.playSong(
                                        song,
                                        queue: List<Song>.of(_songs),
                                      );
                                    },
                                    onPlay: () {
                                      widget.player.playSong(
                                        song,
                                        queue: List<Song>.of(_songs),
                                      );
                                    },
                                    onAddToPlaylist: () => showAddToPlaylistSheet(
                                      context: context,
                                      auth: widget.auth,
                                      song: song,
                                    ),
                                    onDelete: () {},
                                    onViewArtist: () => _openArtist(song),
                                    onMore: () => _showSongMenu(song),
                                    onSecondaryMore: (position) =>
                                        _showSongMenu(song, anchor: position),
                                  );
                                },
                                childCount: _songs.length,
                              ),
                            ),
                          ),
                        ] else ...[
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            sliver: SliverList.separated(
                              itemCount: _songs.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 2),
                              itemBuilder: (context, index) {
                                final song = _songs[index];
                                // 行视觉与歌单/搜索结果统一见 AppSongRow；
                                // 副标题带专辑名，更多菜单只留歌手页语境的两项。
                                return AppSongRow(
                                  song: song,
                                  player: widget.player,
                                  subtitle: [
                                    song.artist,
                                    if (song.albumName?.isNotEmpty == true)
                                      song.albumName!,
                                  ].join(' · '),
                                  onTap: () {
                                    if (openPlayerIfSameSong(
                                      context,
                                      player: widget.player,
                                      auth: widget.auth,
                                      song: song,
                                    )) {
                                      return;
                                    }
                                    widget.player.playSong(
                                      song,
                                      queue: List<Song>.of(_songs),
                                    );
                                  },
                                  trailing: [
                                    AppSongRowMenuButton(
                                      onPressed: () {
                                        showSongActionSheet(
                                          context: context,
                                          song: song,
                                          actions: [
                                            SongSheetAction(
                                              icon:
                                                  Icons.queue_music_rounded,
                                              title: '下一首播放',
                                              onTap: () =>
                                                  addSongToQueueWithFeedback(
                                                context: context,
                                                player: widget.player,
                                                song: song,
                                              ),
                                            ),
                                            SongSheetAction(
                                              icon: Icons
                                                  .playlist_add_rounded,
                                              title: '添加到歌单',
                                              onTap: () =>
                                                  showAddToPlaylistSheet(
                                                context: context,
                                                auth: widget.auth,
                                                song: song,
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                        SliverToBoxAdapter(
                          child: _ArtistLoadMoreFooter(
                            hasMore: _hasMore,
                            isLoading: _isLoadingMore || _isProgressiveLoading,
                            errorMessage: _loadMoreError,
                            onRetry: _loadMore,
                          ),
                        ),
                      ],
                    ] else if (_selectedTab == _ArtistTab.albums) ...[
                      if (_albums.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                '暂无专辑',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        AlbumSliverGridSection(
                          albums: _albums,
                          onTap: _openAlbum,
                          sectionSidePadding: isDesktopFormFactor ? 18 : 16,
                        ),
                    ] else if (_selectedTab == _ArtistTab.mvs) ...[
                      // tag 筛选 + 播放全部 + MV 卡片网格。
                      SliverToBoxAdapter(
                        child: _MvSectionHeader(
                          tag: _mvTag,
                          onTagChanged: _switchMvTag,
                          count: _mvs.length,
                          onPlayAll: _mvs.isEmpty
                              ? null
                              : () => _playMv(_mvs.first),
                          loading: _mvLoading,
                        ),
                      ),
                      if (_mvLoading && _mvs.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_mvs.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                '暂无 MV',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        )
                      else ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 280,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 12,
                              childAspectRatio: 16 / 11.6,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final mv = _mvs[index];
                                return MvCard(
                                  mv: mv,
                                  onTap: () => _playMv(mv),
                                );
                              },
                              childCount: _mvs.length,
                            ),
                          ),
                        ),
                        if (_mvHasMore)
                          SliverToBoxAdapter(
                            child: Center(
                              child: TextButton(
                                onPressed: _mvLoading
                                    ? null
                                    : () => _loadMvs(),
                                child: _mvLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('加载更多'),
                              ),
                            ),
                          ),
                      ],
                    ],
                    // 底部留白：移动端播放中时为 MiniPlayer 预留空间，
                    // 防止卡片遮挡导致用户点不到最底部的几首歌。
                    if (!isDesktopFormFactor)
                      SliverToBoxAdapter(
                        child: AnimatedBuilder(
                          animation: widget.player,
                          builder: (context, _) {
                            final hasSong = widget.player.currentSong != null;
                            return SizedBox(
                              height: hasSong ? miniPlayerSpace : 0,
                            );
                          },
                        ),
                      ),
                  ],
                ],
              ),
            ),
            // 桌面端内容区已有常驻 DesktopPlayerBar，MiniPlayerSlot 在桌面
            // 形态下不挂载，避免内容区底部叠两层播放条。
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomInset + 16,
              child: MiniPlayerSlot(player: widget.player, auth: widget.auth),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({required this.detail, required this.fallback});

  final ArtistDetail? detail;
  final ArtistRef fallback;

  @override
  Widget build(BuildContext context) {
    final avatar = detail?.avatarUrl ?? fallback.avatarUrl;

    // 作为 SliverAppBar 的 flexibleSpace 背景，尺寸由展开高度决定，
    // 底部直角平铺，与下方 Tab 栏无缝衔接，无圆角裁切。
    return Stack(
      fit: StackFit.expand,
      children: [
        if (avatar == null)
          const _ArtistPosterFallback()
        else
          RetryableNetworkImage(
            url: avatar,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            cacheWidth: 800,
            cacheHeight: 800,
            errorBuilder: (context, error, stackTrace) =>
                const _ArtistPosterFallback(),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: .20),
                Colors.black.withValues(alpha: .06),
                Colors.black.withValues(alpha: .58),
              ],
              stops: const [0, .48, 1],
            ),
          ),
        ),
        Positioned(
          left: 22,
          right: 22,
          bottom: 26,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                detail?.name ?? fallback.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  height: 1.08,
                ),
              ),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .22),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    detail?.birthday?.isNotEmpty == true
                        ? '生日 ${detail!.birthday}'
                        : '歌手 ID ${detail?.id ?? fallback.id}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: .88),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistPosterFallback extends StatelessWidget {
  const _ArtistPosterFallback();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .90),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .80),
          ],
        ),
      ),
      child: Icon(
        Icons.person_rounded,
        size: 88,
        color: Colors.white.withValues(alpha: .86),
      ),
    );
  }
}

class _SongSectionHeader extends StatelessWidget {
  const _SongSectionHeader({required this.count, required this.onPlayAll});

  final int count;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktopFormFactor ? 18 : 18,
        isDesktopFormFactor ? 8 : 4,
        isDesktopFormFactor ? 18 : 18,
        isDesktopFormFactor ? 8 : 12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 0 ? '歌曲' : '热门歌曲 $count',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(
                fontWeight: isDesktopFormFactor
                    ? FontWeight.w700
                    : FontWeight.w900,
              ),
            ),
          ),
          if (!isDesktopFormFactor)
            TextButton.icon(
              onPressed: onPlayAll,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放'),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

/// MV tab 头部：tag 筛选 chips + 播放全部。
class _MvSectionHeader extends StatelessWidget {
  const _MvSectionHeader({
    required this.tag,
    required this.onTagChanged,
    required this.count,
    required this.onPlayAll,
    required this.loading,
  });

  final String tag;
  final ValueChanged<String> onTagChanged;
  final int count;
  final VoidCallback? onPlayAll;
  final bool loading;

  static const _tags = {
    'all': '全部',
    'official': '官方',
    'live': '现场',
    'fan': '饭制',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  count == 0 ? 'MV' : 'MV $count',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: isDesktopFormFactor
                        ? FontWeight.w700
                        : FontWeight.w900,
                  ),
                ),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              TextButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in _tags.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: tag == entry.key,
                  onSelected: (_) => onTagChanged(entry.key),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArtistDetailSkeleton extends StatelessWidget {
  const _ArtistDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      sliver: SliverList.list(
        children: [
          const _SkeletonBox(width: 110, height: 22, radius: 8),
          const SizedBox(height: 18),
          for (var index = 0; index < 8; index++) ...[
            const _SkeletonSongRow(),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _SkeletonSongRow extends StatelessWidget {
  const _SkeletonSongRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _SkeletonBox(width: 50, height: 50, radius: 9),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SkeletonBox(width: double.infinity, height: 16, radius: 6),
              SizedBox(height: 8),
              _SkeletonBox(width: 150, height: 14, radius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        _SkeletonBox(width: 42, height: 14, radius: 6),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

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

class _EmptyArtistSongs extends StatelessWidget {
  const _EmptyArtistSongs();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        '暂无歌曲',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ArtistLoadMoreFooter extends StatelessWidget {
  const _ArtistLoadMoreFooter({
    required this.hasMore,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  final bool hasMore;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        child: Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(18, 14, 18, 30),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
      child: Center(
        child: Text(
          hasMore ? '继续下滑加载更多' : '已加载全部',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ArtistDetailError extends StatelessWidget {
  const _ArtistDetailError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, size: 42),
          const SizedBox(height: 12),
          Text('歌手页面加载失败', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
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

/// PC 桌面端横排紧凑 Hero 头部。
class _DesktopArtistHeroHeader extends StatelessWidget {
  const _DesktopArtistHeroHeader({
    required this.detail,
    required this.fallback,
    required this.songsCount,
    required this.albumsCount,
    required this.onPlayAll,
    this.hasMore = false,
  });

  final ArtistDetail? detail;
  final ArtistRef fallback;
  final int songsCount;
  final int albumsCount;
  final VoidCallback? onPlayAll;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final avatar = detail?.avatarUrl ?? fallback.avatarUrl;
    final artistName = detail?.name ?? fallback.name;

    final statText = hasMore
        ? '已加载 $songsCount 首热门单曲${albumsCount > 0 ? ' · $albumsCount 张专辑' : ''}'
        : '共 $songsCount 首热门单曲${albumsCount > 0 ? ' · $albumsCount 张专辑' : ''}';

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [Color(0xFF1B2E49), Color(0xFF0D121E), Color(0xFF06070A)]
              : const [Color(0xFFD3E8FF), Color(0xFFEDF4FF), Color(0xFFFFFFFF)],
          stops: isDark ? const [0, 0.55, 1] : const [0, 0.62, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, kToolbarHeight, 28, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(60),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? .35 : .16),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Artwork(
                  url: avatar,
                  size: 120,
                  borderRadius: 60,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(
                          alpha: isDark ? .20 : .10,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        statText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: Text(
                        '播放热门单曲',
                        style: TextStyle(
                          fontWeight: isDesktopFormFactor
                              ? FontWeight.w700
                              : FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        enabledMouseCursor: isDesktopFormFactor
                            ? SystemMouseCursors.click
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 9,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PC 桌面端表格吸顶代理。
class _ArtistTableStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ArtistTableStickyHeaderDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 36.0;

  @override
  double get maxExtent => 36.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) =>
      child;

  @override
  bool shouldRebuild(covariant _ArtistTableStickyHeaderDelegate oldDelegate) =>
      child != oldDelegate.child;
}

/// 歌手页 Tab 吸顶代理。
class _ArtistTabHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _ArtistTabHeaderDelegate({
    required this.selectedTab,
    required this.songsCount,
    required this.albumsCount,
    required this.mvsCount,
    required this.onTabSelected,
  });

  final _ArtistTab selectedTab;
  final int songsCount;
  final int albumsCount;
  final int mvsCount;
  final ValueChanged<_ArtistTab> onTabSelected;

  @override
  double get minExtent => 48.0;

  @override
  double get maxExtent => 48.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: 48.0,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: isDark ? .20 : .40),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _ArtistTabItem(
            label: '精选单曲',
            count: songsCount,
            isSelected: selectedTab == _ArtistTab.songs,
            onTap: () => onTabSelected(_ArtistTab.songs),
          ),
          const SizedBox(width: 8),
          _ArtistTabItem(
            label: '所有专辑',
            count: albumsCount,
            isSelected: selectedTab == _ArtistTab.albums,
            onTap: () => onTabSelected(_ArtistTab.albums),
          ),
          const SizedBox(width: 8),
          _ArtistTabItem(
            label: 'MV',
            count: mvsCount,
            isSelected: selectedTab == _ArtistTab.mvs,
            onTap: () => onTabSelected(_ArtistTab.mvs),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _ArtistTabHeaderDelegate oldDelegate) {
    return oldDelegate.selectedTab != selectedTab ||
        oldDelegate.songsCount != songsCount ||
        oldDelegate.albumsCount != albumsCount ||
        oldDelegate.mvsCount != mvsCount;
  }
}

class _ArtistTabItem extends StatefulWidget {
  const _ArtistTabItem({
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_ArtistTabItem> createState() => _ArtistTabItemState();
}

class _ArtistTabItemState extends State<_ArtistTabItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Color textColor;
    FontWeight fontWeight;
    if (widget.isSelected) {
      textColor = colorScheme.primary;
      fontWeight = FontWeight.w800;
    } else if (_isHovered) {
      textColor = colorScheme.onSurface;
      fontWeight = FontWeight.w600;
    } else {
      textColor = colorScheme.onSurfaceVariant;
      fontWeight = FontWeight.w600;
    }

    final badgeBgColor = widget.isSelected
        ? colorScheme.primary.withValues(alpha: isDark ? .24 : .12)
        : (_isHovered
            ? colorScheme.onSurfaceVariant.withValues(alpha: isDark ? .18 : .08)
            : colorScheme.onSurfaceVariant.withValues(alpha: isDark ? .12 : .06));

    final badgeTextColor = widget.isSelected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: colorScheme.primary.withValues(alpha: .06),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: widget.isSelected
                ? colorScheme.primary.withValues(alpha: isDark ? .16 : .08)
                : (_isHovered
                    ? colorScheme.onSurface.withValues(alpha: .04)
                    : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: textColor,
                  fontWeight: fontWeight,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeBgColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${widget.count}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: badgeTextColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

