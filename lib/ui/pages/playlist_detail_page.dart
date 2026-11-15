import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart';
import '../../core/pinyin_utils.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_search_field.dart';
import '../widgets/app_song_row.dart';
import '../widgets/app_section.dart';
import '../widgets/artwork.dart';
import '../widgets/desktop_song_table_row.dart';
import '../widgets/import_playlist_sheet.dart';
import '../widgets/locate_current_song_button.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import '../design_tokens.dart';
import '../form_factor.dart';
import '../player/song_tap_handler.dart';
import 'artist_detail_page.dart';

/// 缓存中完整歌单歌曲列表的 key 后缀。
const _fullSongsCacheSuffix = '_full';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.playlist,
    this.initialSongs,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final PlaylistSummary playlist;
  final List<Song>? initialSongs;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  static const _pageSize = 50;

  /// 参考主流音乐 App 的歌单头：进入时居中大封面（图2），上滑时列表
  /// 圆角面板上移覆盖（图3），置顶后仅留标题+粘性歌曲操作条（图4）。
  /// 桌面端用紧凑横排头（仿 QQ 音乐 PC：封面左、信息右），高度减半。
  static const _heroExpandedHeightMobile = 412.0;
  static const _heroExpandedHeightDesktop = 236.0;
  static const _stickyHeaderHeight = 68.0;

  /// MiniPlayer 悬浮条总高（64 内容 + 2 进度条），定位按钮悬浮其上方。
  static const _miniPlayerExtent = 66.0;

  double get _heroExpandedHeight =>
      isDesktopFormFactor ? _heroExpandedHeightDesktop : _heroExpandedHeightMobile;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _songs = <Song>[];
  final _cache = CacheService();

  PlaylistSummary? _info;
  var _nextPage = 1;
  var _hasMore = true;
  var _isInitialLoading = true;
  var _isLoadingMore = false;
  String? _errorMessage;
  String? _loadMoreError;
  bool _isMutating = false;
  bool _isSearching = false;
  bool _isLoadingAllSongs = false;
  // 后台静默补全进行中（点歌后扩展队列用，不驱动全屏 loading UI，
  // 避免列表被替换导致滚动位置丢失）。
  bool _isExpandingQueue = false;
  bool _allSongsLoaded = false;
  // 全量加载代际：页面退出/重新加载时 +1，使在途的 _loadAllSongs
  // 在下一个 await 后自行放弃（逻辑 CancelToken，MusicApi 的 Rust
  // 通道不支持 dio CancelToken，只能靠代际丢弃结果，避免退出后
  // 仍写缓存/ setState 浪费流量与内存）。
  // Flag 归属规则：guard 标记（_isLoadingAllSongs/_isExpandingQueue）属于
  // 创建时的代际；新代际在 +1 时同步接管并复位（见 _loadInitial），旧代际
  // 的取消路径一律不得再碰 flag，否则会把新一轮的标记清掉或把旧标记泄漏
  // 到新一轮（旧任务取消后新任务被 guard 永久挡住）。
  int _loadGeneration = 0;
  bool _disposed = false;
  // 大歌单分片粒度：toCache/fromCache 的同步循环每 500 条让出一帧，
  // 避免千首大单一次性阻塞 UI（5000 条约 10 片，每片 <8ms）。
  static const int _cacheChunkSize = 500;
  bool _isSelecting = false;
  bool _selectAllMode = false;
  final Set<String> _selectedKeys = {};
  final Set<String> _excludedKeys = {};
  String _searchQuery = '';
  _SongSortMode _sortMode = _SongSortMode.defaultOrder;
  String? _focusedSongKey;

  // _filteredSongs 记忆化缓存：行构建器/吸顶代理/滚动监听每帧会多次调用
  // 该 getter，全量拷贝 + 拼音排序开销大。影响结果的输入（_songs、
  // _searchQuery、_sortMode）只在 setState 中变更，因此重写 setState
  // 统一递增版本号使缓存失效（宽失效：宁可多算一次也不返回旧结果）。
  int _filteredVersion = 0;
  List<Song>? _filteredCache;
  int? _filteredCacheVersion;
  String? _filteredCacheQuery;
  _SongSortMode? _filteredCacheSort;

  bool get _showDesktopTableHeader =>
      isDesktopFormFactor && _filteredSongs.isNotEmpty;

  double get _stickyHeaderDelegateHeight =>
      _showDesktopTableHeader
          ? _stickyHeaderHeight + 36.0
          : _stickyHeaderHeight;

  /// 相似歌单（增强展示，加载失败静默忽略）。
  List<PlaylistSummary> _similarPlaylists = const [];

  /// 多选批量下载进行中。
  bool _isBatchDownloading = false;

  /// 手动定位当前播放歌曲（右下角定位按钮）相关状态。
  bool _isLocating = false;
  int? _locateTargetIndex;
  final GlobalKey _locateRowKey = GlobalKey();

  String get _sortModeLabel {
    return switch (_sortMode) {
      _SongSortMode.defaultOrder => '默认排序',
      _SongSortMode.byTitle => '按歌名',
      _SongSortMode.byArtist => '按歌手',
      _SongSortMode.byAlbum => '按专辑',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_SongSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_SongSortMode.defaultOrder, '默认排序'),
          (_SongSortMode.byTitle, '按歌名'),
          (_SongSortMode.byArtist, '按歌手'),
          (_SongSortMode.byAlbum, '按专辑'),
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
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
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
                            color: colorScheme.outlineVariant.withValues(
                              alpha: .3,
                            ),
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

  bool get _isAlbum => widget.playlist.isCollectedAlbum;
  bool get _isDailyRecommend => widget.playlist.id == 'daily_recommend';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    if (widget.playlist.isLikedPlaylist) {
      widget.auth.addListener(_onLikedChanged);
    }
    _loadInitial();
  }

  /// 见 _filteredSongs 的记忆化说明：任何 setState 都可能改了过滤/排序
  /// 输入，统一递增版本号让缓存失效。
  @override
  void setState(VoidCallback fn) {
    _filteredVersion++;
    super.setState(fn);
  }

  @override
  void dispose() {
    _disposed = true;
    // 代际 +1：在途全量加载在下一个 await 后自行放弃，不再 setState/写缓存
    _loadGeneration++;
    if (widget.playlist.isLikedPlaylist) {
      widget.auth.removeListener(_onLikedChanged);
    }
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _searchController.dispose();
    _songs.clear();
    _info = null;
    super.dispose();
  }

  void _onLikedChanged() {
    if (!mounted) return;
    final before = _songs.length;
    _songs.removeWhere((song) => !widget.auth.isLiked(song));
    if (_songs.length != before) {
      setState(() {});
    }
  }

  List<Song> get _filteredSongs {
    final cached = _filteredCache;
    if (cached != null &&
        _filteredCacheVersion == _filteredVersion &&
        _filteredCacheQuery == _searchQuery &&
        _filteredCacheSort == _sortMode) {
      return cached;
    }
    List<Song> list;
    if (_searchQuery.isEmpty) {
      list = List<Song>.of(_songs);
    } else {
      final q = _searchQuery.toLowerCase();
      list = _songs.where((song) {
        return song.title.toLowerCase().contains(q) ||
            song.artist.toLowerCase().contains(q) ||
            (song.albumName?.toLowerCase().contains(q) ?? false);
      }).toList();
    }

    switch (_sortMode) {
      case _SongSortMode.byTitle:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        break;
      case _SongSortMode.byArtist:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.artist, b.artist));
        break;
      case _SongSortMode.byAlbum:
        list.sort(
          (a, b) =>
              PinyinUtils.comparePinyin(a.albumName ?? '', b.albumName ?? ''),
        );
        break;
      case _SongSortMode.defaultOrder:
        break;
    }
    _filteredCache = list;
    _filteredCacheVersion = _filteredVersion;
    _filteredCacheQuery = _searchQuery;
    _filteredCacheSort = _sortMode;
    return list;
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
    if (_isSearching && !_allSongsLoaded) {
      _loadAllSongs();
    }
  }

  /// 释放全量加载的 guard 标记（仅拥有者可调）。
  ///
  /// 调用方传入创建任务时捕获的代际 [gen]：与当前 [_loadGeneration]
  /// 一致时才复位，否则说明新一轮已接管 flag，旧任务不得触碰。
  void _releaseAllSongsFlags(int gen, {bool silent = false}) {
    if (gen != _loadGeneration) return;
    _isExpandingQueue = false;
    _isLoadingAllSongs = false;
    if (!silent && mounted) setState(() {});
  }

  /// [silent] 为 true 时为点歌后的后台静默补全：不置位
  /// [_isLoadingAllSongs]，不把列表替换成全屏 loading，
  /// 从而保留滚动位置；仅在结束时增量追加。
  ///
  /// 取消语义：调用时捕获 [_loadGeneration]，每个 await 后检查代际；
  /// 页面退出/重新加载导致代际变化时直接放弃，不 setState、不写缓存、
  /// 不碰 guard flag（flag 已由新代际接管，见 [_releaseAllSongsFlags]）。
  /// 不改变触发时机与队列扩展逻辑（上滑仍分页，计数口径不变）。
  Future<void> _loadAllSongs({bool silent = false}) async {
    if (_isLoadingAllSongs || _isExpandingQueue || _allSongsLoaded) return;
    if (_disposed) return;
    final gen = _loadGeneration;
    if (silent) {
      _isExpandingQueue = true;
    } else {
      setState(() => _isLoadingAllSongs = true);
    }
    try {
      final id = _isAlbum
          ? (widget.playlist.albumId ?? widget.playlist.id)
          : widget.playlist.id;

      // 优先尝试从完整歌单缓存读取（命中则跳过网络请求）
      final fullCacheKey = _isAlbum
          ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}$_fullSongsCacheSuffix'
          : 'cache_playlist_${widget.playlist.id}$_fullSongsCacheSuffix';

      CacheResult<Map<String, dynamic>>? fullCached;
      try {
        fullCached = await _cache.read<Map<String, dynamic>>(
          fullCacheKey,
          decode: (json) => json,
          ttl: AppConfig.playlistDetailTtl,
        );
      } catch (_) {}
      if (_disposed || gen != _loadGeneration) return;

      List<Song> allSongs;
      // 过期视为未命中，走网络重新拉全量，避免全量缓存永不失效。
      if (fullCached != null && !fullCached.isStale) {
        // 分片解析：大单 fromCache 同步循环每片让出一帧，避免卡顿；
        // 中途代际变化直接放弃。
        final raw =
            (fullCached.data['songs'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList();
        allSongs = [];
        for (var i = 0; i < raw.length; i += _cacheChunkSize) {
          if (_disposed || gen != _loadGeneration) return;
          final end = (i + _cacheChunkSize).clamp(0, raw.length);
          for (var j = i; j < end; j++) {
            final song = Song.fromCache(raw[j]);
            if (song.hash.isNotEmpty) allSongs.add(song);
          }
          // 非末片让出一帧，保持列表可滚动
          if (end < raw.length) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      } else {
        allSongs = _isAlbum
            ? await widget.api.albumSongs(id, page: 1, pageSize: 5000)
            : await widget.api.playlistSongs(id, fetchAll: true);
        if (_disposed || gen != _loadGeneration) return;
        // 分片写缓存：toCache 同步映射同样分片让帧；取消后不写，
        // 避免退出后仍做大 JSON 编码浪费电量。
        final cacheList = <Map<String, dynamic>>[];
        for (var i = 0; i < allSongs.length; i += _cacheChunkSize) {
          if (_disposed || gen != _loadGeneration) return;
          final end = (i + _cacheChunkSize).clamp(0, allSongs.length);
          for (var j = i; j < end; j++) {
            cacheList.add(allSongs[j].toCache());
          }
          if (end < allSongs.length) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        // 写入完整歌单缓存，后续播放可直接复用
        await _cache.write(fullCacheKey, {'songs': cacheList});
        if (_disposed || gen != _loadGeneration) return;
      }

      if (!mounted || _disposed || gen != _loadGeneration) {
        // 拥有者才复位：代际过期说明新一轮已接管 flag，旧任务直接放弃，
        // 不得清掉新任务的标记（亦不得把 _isLoadingAllSongs 漏掉，之前
        // 这里只复位了 _isExpandingQueue）。
        _releaseAllSongsFlags(gen, silent: silent);
        return;
      }
      setState(() {
        // 增量追加：保留已有歌曲，仅追加尚未加载的歌曲，
        // 避免先清空再重建列表导致滚动位置被强制重置。
        final existingKeys = _songs
            .map(_songKey)
            .where((k) => k.isNotEmpty)
            .toSet();
        for (final song in allSongs) {
          final key = _songKey(song);
          if (key.isEmpty || existingKeys.contains(key)) continue;
          _songs.add(song);
          existingKeys.add(key);
        }
        _allSongsLoaded = true;
        _hasMore = false;
        _isLoadingAllSongs = false;
        _isExpandingQueue = false;
      });
    } catch (_) {
      // 异常复位同样只允许拥有者：新代际在途时旧任务的异常不得清新标记。
      _releaseAllSongsFlags(gen, silent: silent);
    }
  }

  /// 当前可播放队列：已加载列表（搜索时为过滤结果）。
  /// 不阻塞等待未分页内容，避免因 count 含无版权曲而误提示「加载完整歌单」。
  List<Song> _playbackQueueNow() {
    // 缓存列表只读复用：出队列前拷贝，避免调用方原地修改污染缓存。
    if (_searchQuery.isNotEmpty) return List<Song>.of(_filteredSongs);
    return _songs.where((s) => s.hash.isNotEmpty).toList();
  }

  /// 后台静默补全剩余分页，并在仍播放本列表时扩展队列（无 Toast）。
  void _expandQueueInBackgroundIfNeeded({required Song startedWith}) {
    if (_searchQuery.isNotEmpty) return;
    if (_allSongsLoaded || !_hasMore) return;
    final startedKey = startedWith.hash.isNotEmpty
        ? startedWith.hash
        : startedWith.id;
    unawaited(() async {
      // 静默补全：不弹全屏 loading、不重置滚动位置。
      await _loadAllSongs(silent: true);
      if (!mounted || _disposed || startedKey.isEmpty) return;
      final current = widget.player.currentSong;
      if (current == null) return;
      final currentKey = current.hash.isNotEmpty ? current.hash : current.id;
      final queueStillOurs = widget.player.queue.any((s) {
        final k = s.hash.isNotEmpty ? s.hash : s.id;
        return k == startedKey;
      });
      // 用户已切到其它来源则不改队列
      if (currentKey != startedKey && !queueStillOurs) return;
      final expanded = _playbackQueueNow();
      if (expanded.length <= widget.player.queue.length) return;
      await widget.player.replaceQueue(expanded);
    }());
  }

  Future<void> _loadInitial() async {
    // 新一轮初始加载使在途全量补全失效（代际取消），避免旧单结果
    // 追加到新单列表里。新代际同步接管 guard flag 并复位：在途旧任务
    // 按代际丢弃且不再碰 flag（见 _releaseAllSongsFlags），复位后新一轮
    // 的 _loadAllSongs 才不会被旧标记挡在 guard 外。
    _loadGeneration++;
    _isLoadingAllSongs = false;
    _isExpandingQueue = false;
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _errorMessage = null;
      _loadMoreError = null;
      _nextPage = 1;
      _hasMore = true;
      _info = null;
      _songs.clear();
    });

    if (_isDailyRecommend) {
      if (widget.initialSongs != null && widget.initialSongs!.isNotEmpty && _songs.isEmpty) {
        final songs = List<Song>.of(widget.initialSongs!);
        setState(() {
          _info = widget.playlist;
          _songs
            ..clear()
            ..addAll(songs);
          _isInitialLoading = false;
          _allSongsLoaded = true;
          _hasMore = false;
        });
        return;
      }
      try {
        final daily = await widget.api.dailyRecommend();
        if (!mounted) return;
        setState(() {
          _info = widget.playlist.copyWith(
            songCount: daily.songs.length,
            coverUrl: daily.coverUrl ??
                (daily.songs.isNotEmpty ? daily.songs.first.coverUrl : null),
          );
          _songs
            ..clear()
            ..addAll(daily.songs);
          _isInitialLoading = false;
          _allSongsLoaded = true;
          _hasMore = false;
        });
      } catch (e) {
        if (!mounted) return;
        if (widget.initialSongs != null && widget.initialSongs!.isNotEmpty) {
          setState(() {
            _info = widget.playlist;
            _songs
              ..clear()
              ..addAll(widget.initialSongs!);
            _isInitialLoading = false;
            _allSongsLoaded = true;
            _hasMore = false;
          });
        } else {
          setState(() {
            _errorMessage = '加载失败: $e';
            _isInitialLoading = false;
          });
        }
      }
      return;
    }

    final cacheKey = _isAlbum
        ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}'
        : 'cache_playlist_${widget.playlist.id}';

    // 先读缓存，命中则立即显示
    CacheResult<Map<String, dynamic>>? cached;
    try {
      cached = await _cache.read<Map<String, dynamic>>(
        cacheKey,
        decode: (json) => json,
        ttl: AppConfig.playlistDetailTtl,
      );
    } catch (_) {}
    if (cached != null && mounted) {
      final cacheData = cached.data;
      final infoJson = cacheData['info'];
      setState(() {
        if (infoJson is Map<String, dynamic>) {
          final library =
              widget.auth.findUserPlaylist(widget.playlist) ?? widget.playlist;
          _info = library.mergeWithDetail(PlaylistSummary.fromCache(infoJson));
        }
        _songs.clear();
        _songs.addAll(
          (cacheData['songs'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(Song.fromCache)
              .toList(),
        );
        _isInitialLoading = false;
        // 基础缓存只存第 1 页（pageSize 50）：网络降级失败时，滚动
        // 加载才能从第 2 页续传，否则会重复拉第 1 页造成列表重复。
        _nextPage = 2;
      });
    }

    try {
      if (_isAlbum) {
        final songPage = await widget.api.albumSongPage(
          widget.playlist.albumId ?? widget.playlist.id,
          page: 1,
          pageSize: _pageSize,
        );
        if (!mounted) return;

        setState(() {
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed =
              _songs.length != songs.length || !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (widget.playlist.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          if (!_hasMore) {
            _allSongsLoaded = true;
          }
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'songs': songPage.songs.map((s) => s.toCache()).toList(),
        });
      } else {
        final results = await Future.wait([
          widget.api.playlistInfo(widget.playlist.id),
          widget.api.playlistSongPage(
            widget.playlist.id,
            page: 1,
            pageSize: _pageSize,
          ),
        ]);
        if (!mounted) return;

        final info = results[0] as PlaylistSummary;
        final songPage = results[1] as SongPage;
        final songs = songPage.songs;
        setState(() {
          // 详情接口可能缺 type/listId；与入口/库内元数据合并，保证 canEdit 正确
          final library =
              widget.auth.findUserPlaylist(widget.playlist) ?? widget.playlist;
          _info = library.mergeWithDetail(info);
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed =
              _songs.length != songs.length || !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (info.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          if (!_hasMore) {
            _allSongsLoaded = true;
          }
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'info': info.toCache(),
          'songs': songs.map((s) => s.toCache()).toList(),
        });
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _hasMore && !_allSongsLoaded) {
          _loadAllSongs(silent: true);
        }
      });
    } catch (error) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _errorMessage = error.toString();
          _isInitialLoading = false;
        });
        return;
      }
      // 有缓存数据，保持不报错（降级），继续走相似歌单加载。
    }
    unawaited(_loadSimilarPlaylists());
  }

  /// 加载相似歌单（增强展示，失败静默忽略）。
  Future<void> _loadSimilarPlaylists() async {
    try {
      final similar = await widget.api.similarPlaylists(widget.playlist.id);
      if (!mounted || similar.isEmpty) return;
      setState(() => _similarPlaylists = similar);
    } catch (_) {}
  }

  /// 路由防重入：桌面端双击会连续触发两次 onTap，600ms 内同一目标只
  /// push 一次，避免叠两层相同页面。
  final _navThrottleTimes = <String, DateTime>{};

  bool _isNavThrottled(String key) {
    final now = DateTime.now();
    final last = _navThrottleTimes[key];
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 600)) {
      return true;
    }
    _navThrottleTimes[key] = now;
    return false;
  }

  /// 打开相似歌单详情。
  void _openSimilarPlaylist(PlaylistSummary playlist) {
    if (_isNavThrottled('similar_${playlist.id}')) return;
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

  void _maybeLoadMore() {
    // 初始加载/后台全量补全期间禁止加载更多，避免并发拉页导致列表重复。
    if (!_scrollController.hasClients ||
        !_hasMore ||
        _isLoadingMore ||
        _isInitialLoading ||
        _isLoadingAllSongs ||
        _isExpandingQueue) {
      return;
    }

    final position = _scrollController.position;
    if (position.extentAfter < 520) {
      _loadMore();
    }
  }

  /// 比较两份歌曲列表是否内容一致（按 hash 逐项比较）。
  bool _listEquals(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].hash != b[i].hash) return false;
    }
    return true;
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    try {
      final songPage = _isAlbum
          ? await widget.api.albumSongPage(
              widget.playlist.albumId ?? widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            )
          : await widget.api.playlistSongPage(
              widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            );
      if (!mounted) return;

      setState(() {
        final songs = songPage.songs;
        _songs.addAll(songs);
        _nextPage++;
        _hasMore =
            songPage.rawItemCount == _pageSize &&
            _songs.length < (_currentPlaylist.songCount ?? 1 << 31);
        if (!_hasMore) {
          _allSongsLoaded = true;
        }
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

  /// 手动定位到当前播放的歌曲（右下角定位按钮触发，滚动到其所在行）。
  ///
  /// 当前歌曲尚未加载（分页懒加载）时：若当前歌可能属于本歌单/专辑
  /// （见 [_shouldSearchForCurrentSong]），逐页加载直到找到；否则不再
  /// 额外请求，避免点一次按钮就触发全量加载。
  Future<void> _locateCurrentSong() async {
    if (_isLocating) return;
    final current = widget.player.currentSong;
    if (current == null) return;
    _isLocating = true;
    try {
      var index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
      if (index < 0 && _shouldSearchForCurrentSong(current)) {
        // 逐页加载直到找到（上限 24 页，异常情况不再继续）
        var pages = 0;
        while (index < 0 &&
            pages++ < 24 &&
            _hasMore &&
            _loadMoreError == null) {
          await _loadMore();
          if (!mounted) return;
          index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
        }
      }
      if (index >= 0 && mounted) {
        await _scrollToSong(index);
      }
    } finally {
      _isLocating = false;
    }
  }

  /// 判断当前播放歌曲是否属于本歌单/专辑，值得向下翻页查找。
  ///
  /// 宽松匹配：专辑页比对专辑 ID/专辑名；歌单页只要队列包含当前歌且
  /// 与已加载歌单有交集、或歌单总数与队列长度接近即可。不能用「已加载
  /// 歌曲全部属于队列」的强条件——队列被追加过歌、或从别处播起同一首
  /// 歌时会误判，导致定位按钮消失、深翻页查找被拒绝。
  bool _shouldSearchForCurrentSong(Song current) {
    if (_songs.isEmpty) return false;
    // 专辑详情页：比对专辑 ID 或专辑名
    if (_isAlbum) {
      final targetAlbumId = widget.playlist.albumId ?? widget.playlist.id;
      if (current.albumId != null && current.albumId == targetAlbumId) {
        return true;
      }
      if (current.albumName != null &&
          current.albumName!.isNotEmpty &&
          current.albumName == widget.playlist.title) {
        return true;
      }
    }
    // 歌单详情页：队列含当前歌，且与已加载歌单有交集，或总数接近
    final queueHashes = widget.player.queue.map((s) => s.hash).toSet();
    if (queueHashes.contains(current.hash)) {
      if (_songs.any((s) => queueHashes.contains(s.hash))) {
        return true;
      }
      final total = _currentPlaylist.songCount;
      if (total != null && (total - widget.player.queue.length).abs() <= 10) {
        return true;
      }
    }
    return false;
  }

  /// 定位按钮可见性：当前有播放歌曲，且该歌曲已在已加载歌曲列表中；
  /// 尚未加载到时用「当前歌可能属于本歌单」做代理（深页场景，点击后
  /// 限量加载再定位）。搜索过滤把当前歌滤掉时列表滚不到它，直接隐藏。
  bool get _canShowLocateButton {
    final current = widget.player.currentSong;
    if (current == null) return false;
    if (_filteredSongs.any((s) => s.hash == current.hash)) return true;
    if (_searchQuery.isNotEmpty) return false;
    return _shouldSearchForCurrentSong(current);
  }

  /// 滚动到展示列表中 [displayIndex] 所在行：先按固定行高估算偏移跳转，
  /// 再用目标行 key 精确校正（兼容字体缩放等导致的估算误差）。
  Future<void> _scrollToSong(int displayIndex) async {
    if (displayIndex < 0 || displayIndex >= _filteredSongs.length) return;
    if (!_scrollController.hasClients) {
      // 等待首帧布局完成（内容刚加载完时 ScrollView 可能尚未 attach）
      for (var i = 0; i < 20 && !_scrollController.hasClients && mounted; i++) {
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !_scrollController.hasClients) return;
    }

    final topInset = MediaQuery.paddingOf(context).top;
    // 折叠后 SliverAppBar 工具栏高度 + 粘性歌曲条（含 padding）+
    // 列表顶部 padding；移动端行高 72（50 封面 + 上下 10 padding + 2 边框）
    // + 分隔 8 = 80，桌面端行高 48（DesktopSongTableRow.rowHeight）。
    final actionsHeight = _showDesktopTableHeader ? 104.0 : 68.0;
    const listTopPadding = 4.0;
    final rowExtent = isDesktopFormFactor
        ? _DesktopSongTableRow.rowHeight
        : 80.0;
    final targetOffset =
        kToolbarHeight +
        topInset +
        actionsHeight +
        listTopPadding +
        displayIndex * rowExtent;

    setState(() => _locateTargetIndex = displayIndex);

    final position = _scrollController.position;
    _scrollController.jumpTo(targetOffset.clamp(0.0, position.maxScrollExtent));

    // 精确校正：定位行 key 一旦构建，用 ensureVisible 对齐到视口上 1/4 处。
    // 估算偏移与真实偏移存在误差（字体缩放等）时，向后/向前各探测一屏。
    var probe = 0; // 0=未探测 1=已向后探测 2=已双向探测
    for (var attempt = 0; attempt < 10; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final rowContext = _locateRowKey.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: 0.25,
          duration: const Duration(milliseconds: 220),
        );
        if (mounted) setState(() => _locateTargetIndex = null);
        return;
      }
      final currentPosition = _scrollController.position;
      final remaining = targetOffset - currentPosition.pixels;
      if (remaining.abs() > 4) {
        // 尚未到达估算位置：直接跳到估算偏移
        _scrollController.jumpTo(
          (currentPosition.pixels + remaining).clamp(
            0.0,
            currentPosition.maxScrollExtent,
          ),
        );
        continue;
      }
      if (probe == 0) {
        probe = 1;
        _scrollController.jumpTo(
          (currentPosition.pixels - currentPosition.viewportDimension * 0.9)
              .clamp(0.0, currentPosition.maxScrollExtent),
        );
      } else if (probe == 1) {
        probe = 2;
        _scrollController.jumpTo(
          (currentPosition.pixels + currentPosition.viewportDimension * 0.9)
              .clamp(0.0, currentPosition.maxScrollExtent),
        );
      } else {
        break;
      }
    }
    if (mounted) setState(() => _locateTargetIndex = null);
  }

  PlaylistSummary get _currentPlaylist => _info ?? widget.playlist;

  PlaylistSummary get _libraryPlaylist {
    return widget.auth.findUserPlaylist(_currentPlaylist) ?? _currentPlaylist;
  }

  bool get _isInLibrary => widget.auth.isPlaylistInLibrary(_currentPlaylist);

  /// 优先用库列表里的歌单元数据判断，避免详情接口字段不全导致无法删歌。
  bool get _canEdit => widget.auth.canEditPlaylist(_libraryPlaylist);

  String _songKey(Song song) => song.hash.isNotEmpty ? song.hash : song.id;

  bool _isSongSelected(Song song) {
    final key = _songKey(song);
    if (key.isEmpty) return false;
    if (_selectAllMode) {
      return !_excludedKeys.contains(key);
    }
    return _selectedKeys.contains(key);
  }

  int get _selectedCount {
    if (!_isSelecting) return 0;
    if (_selectAllMode) {
      // 未全部加载时用歌单总数估算，避免全选后显示偏小
      if (_searchQuery.isEmpty &&
          !_allSongsLoaded &&
          _currentPlaylist.songCount != null) {
        return (_currentPlaylist.songCount! - _excludedKeys.length).clamp(
          0,
          _currentPlaylist.songCount!,
        );
      }
      final pool = _selectPool;
      return pool.where((s) => !_excludedKeys.contains(_songKey(s))).length;
    }
    return _selectedKeys.length;
  }

  /// 当前可选池：搜索时为过滤结果，否则为已加载列表。
  List<Song> get _selectPool => _filteredSongs;

  bool get _isAllSelected {
    final pool = _selectPool;
    if (pool.isEmpty) return false;
    if (_selectAllMode) {
      return pool.every((s) => !_excludedKeys.contains(_songKey(s)));
    }
    return pool.every((s) => _selectedKeys.contains(_songKey(s)));
  }

  void _enterSelectMode() {
    setState(() {
      _focusedSongKey = null;
      _isSelecting = true;
      _selectAllMode = false;
      _selectedKeys.clear();
      _excludedKeys.clear();
      if (_isSearching) {
        _isSearching = false;
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _focusedSongKey = null;
      _isSelecting = false;
      _selectAllMode = false;
      _selectedKeys.clear();
      _excludedKeys.clear();
    });
  }

  void _toggleSongSelection(Song song) {
    final key = _songKey(song);
    if (key.isEmpty) return;
    setState(() {
      if (_selectAllMode) {
        if (_excludedKeys.contains(key)) {
          _excludedKeys.remove(key);
        } else {
          _excludedKeys.add(key);
        }
      } else {
        if (_selectedKeys.contains(key)) {
          _selectedKeys.remove(key);
        } else {
          _selectedKeys.add(key);
        }
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_isAllSelected) {
        _selectAllMode = false;
        _selectedKeys.clear();
        _excludedKeys.clear();
      } else {
        // 逻辑全选：只标记模式，不把所有 id 塞进 Set
        _selectAllMode = true;
        _selectedKeys.clear();
        _excludedKeys.clear();
      }
    });
  }

  Future<List<Song>> _resolveSelectedSongs() async {
    // 仅当真有未加载分页时才补全；count 含无版权曲时不再误触发
    if (_selectAllMode &&
        _searchQuery.isEmpty &&
        !_allSongsLoaded &&
        _hasMore) {
      Toast.info('正在加载完整列表…');
      await _loadAllSongs();
      if (!_allSongsLoaded) {
        Toast.error('完整歌单加载失败，仅对已加载的歌曲生效');
      }
    }
    final pool = _selectPool;
    if (_selectAllMode) {
      return pool.where((s) => !_excludedKeys.contains(_songKey(s))).toList();
    }
    return pool.where((s) => _selectedKeys.contains(_songKey(s))).toList();
  }

  Future<void> _batchPlayNext() async {
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    try {
      final n = await widget.player.addSongsToQueue(songs);
      Toast.success(n > 0 ? '已添加 $n 首到下一首播放' : '所选歌曲已在播放中');
      _exitSelectMode();
    } catch (e) {
      Toast.error('添加失败：$e');
    }
  }

  Future<void> _batchAddToPlaylist() async {
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    final ok = await showAddSongsToPlaylistSheet(
      context: context,
      auth: widget.auth,
      songs: songs,
    );
    if (ok && mounted) _exitSelectMode();
  }

  Future<void> _batchDelete() async {
    if (!_canEdit) return;
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    final isLiked = _libraryPlaylist.isLikedPlaylist;
    final confirmed = await _confirm(
      title: '删除歌曲',
      message: isLiked
          ? '确定将选中的 ${songs.length} 首歌曲从“我喜欢”中移除？'
          : '确定从当前歌单中移除选中的 ${songs.length} 首歌曲？',
      confirmText: '删除',
    );
    if (confirmed != true) return;
    await _runMutation(() async {
      await widget.auth.removeSongsFromPlaylist(_libraryPlaylist, songs);
      // AuthController 失败只写 errorMessage 不抛出：此时不做本地乐观删除。
      if (widget.auth.errorMessage != null) return;
      if (!mounted) return;
      final keys = songs.map(_songKey).toSet();
      setState(() {
        _songs.removeWhere((s) => keys.contains(_songKey(s)));
      });
      _exitSelectMode();
    });
  }

  /// 把选中的歌曲批量加入下载队列。
  Future<void> _batchDownload() async {
    final downloads = widget.player.downloadController;
    if (downloads == null) {
      Toast.error('下载功能不可用');
      return;
    }
    if (_isBatchDownloading) return;
    // 先置位再解析歌曲，避免加载完整列表期间重复点击并发入队。
    setState(() => _isBatchDownloading = true);
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) {
      if (mounted) setState(() => _isBatchDownloading = false);
      return;
    }

    try {
      final result = await downloads.enqueueBatch(
        songs,
        widget.player.audioQuality,
      );
      final parts = <String>['已加入下载队列 ${result.enqueued} 首'];
      if (result.skipped > 0) {
        parts.add('已跳过 ${result.skipped} 首（已下载/下载中）');
      }
      if (result.failed > 0) {
        parts.add('失败 ${result.failed} 首');
      }
      Toast.success(parts.join('，'));
    } catch (_) {
      Toast.error('加入下载队列失败');
    } finally {
      if (mounted) {
        setState(() => _isBatchDownloading = false);
        _exitSelectMode();
      }
    }
  }

  Future<void> _collectPlaylist() async {
    if (_isAlbum) return;
    await _runMutation(() => widget.auth.collectPlaylist(_currentPlaylist));
  }

  Future<void> _deleteOrUncollectPlaylist() async {
    final target = _libraryPlaylist;
    final title = target.isCollectedAlbum
        ? '取消收藏专辑'
        : target.isCreatedPlaylist
        ? '删除歌单'
        : '取消收藏';
    final message = target.isCollectedAlbum
        ? '确定取消收藏这个专辑吗？'
        : target.isCreatedPlaylist
        ? '确定删除「${target.title}」吗？'
        : '确定取消收藏「${target.title}」吗？';
    final confirmText = target.isCollectedAlbum || !target.isCreatedPlaylist
        ? '取消收藏'
        : '删除歌单';
    final confirmed = await _confirm(
      title: title,
      message: message,
      confirmText: confirmText,
    );
    if (confirmed != true) return;

    // 仅在删除/取消收藏成功后才退出页面，失败留在本页并提示。
    final ok = await _runMutation(
      () => widget.auth.deleteOrUncollectPlaylist(target),
    );
    if (ok && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _removeSong(Song song) async {
    final isLiked = _libraryPlaylist.isLikedPlaylist;
    final confirmed = await _confirm(
      title: '删除歌曲',
      message: isLiked ? '确定将该歌曲从“我喜欢”中移除？' : '确定从当前歌单中移除该歌曲？',
      confirmText: '删除',
    );
    if (confirmed != true) return;
    await _runMutation(() async {
      await widget.auth.removeSongFromPlaylist(_libraryPlaylist, song);
      // AuthController 失败只写 errorMessage 不抛出：此时不做本地乐观删除。
      if (widget.auth.errorMessage != null) return;
      if (mounted) {
        setState(() => _songs.removeWhere((item) => item.id == song.id));
      }
    });
  }

  Future<void> _addSongToPlaylist(Song song) async {
    await showAddToPlaylistSheet(
      context: context,
      auth: widget.auth,
      song: song,
    );
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
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.music_video_rounded,
            title: '观看 MV',
            onTap: () => watchMvWithFeedback(
              context: context,
              song: song,
              songs: _playbackQueueNow(),
            ),
          ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => _addSongToPlaylist(song),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: () => _openArtist(song),
        ),
        if (_canEdit)
          SongSheetAction(
            icon: Icons.delete_outline_rounded,
            title: '从歌单删除',
            danger: true,
            onTap: () => _removeSong(song),
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

  /// 分享歌单：将歌单信息与歌曲列表复制到剪贴板。
  void _sharePlaylist() {
    final info = _currentPlaylist;
    final songs = _songs;
    final buffer = StringBuffer();
    buffer.writeln('🎵 ${info.title}');
    if (info.subtitle != null && info.subtitle!.trim().isNotEmpty) {
      buffer.writeln('by ${info.subtitle}');
    }
    buffer.writeln('共 ${songs.length} 首');
    buffer.writeln('---');
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      buffer.writeln('${i + 1}. ${song.title} - ${song.artist}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    Toast.success('歌单信息已复制到剪贴板');
  }

  /// 播放全部/播放结果：与粘性歌曲条共用，避免两处逻辑分叉。
  void _playAll() {
    final queue = _playbackQueueNow();
    if (queue.isEmpty) return;
    final first = queue.first;
    widget.player.playSong(first, queue: List<Song>.of(queue));
    _expandQueueInBackgroundIfNeeded(startedWith: first);
  }

  /// 以 MV 播放整个歌单（收藏歌单同理）：批量把歌曲匹配为 MV 队列，
  /// 无 MV 的歌剔除；首个 MV 起播即跳转、后台继续补队列。
  Future<void> _playAllMv() async {
    final songs = _playbackQueueNow();
    if (songs.isEmpty) return;
    if (MvPlayerController.instance.isResolvingQueue) return;
    Toast.info('正在匹配歌单 MV…');
    await watchMvWithFeedback(
      context: context,
      song: songs.first,
      songs: songs,
      noMvMessage: '歌单里的歌曲暂无 MV',
    );
  }

  /// Hero 区「下载」：补全全量后整单入队，复用批量下载的并发 guard。
  Future<void> _downloadAll() async {
    final downloads = widget.player.downloadController;
    if (downloads == null) {
      Toast.error('下载功能不可用');
      return;
    }
    if (_isBatchDownloading) return;
    setState(() => _isBatchDownloading = true);
    try {
      if (!_allSongsLoaded && _hasMore) {
        Toast.info('正在加载完整列表…');
        await _loadAllSongs();
      }
      if (!mounted) return;
      final songs = _playbackQueueNow();
      if (songs.isEmpty) {
        Toast.error('暂无可下载歌曲');
        return;
      }
      final result = await downloads.enqueueBatch(
        songs,
        widget.player.audioQuality,
      );
      final parts = <String>['已加入下载队列 ${result.enqueued} 首'];
      if (result.skipped > 0) {
        parts.add('已跳过 ${result.skipped} 首（已下载/下载中）');
      }
      if (result.failed > 0) {
        parts.add('失败 ${result.failed} 首');
      }
      Toast.success(parts.join('，'));
    } catch (_) {
      Toast.error('加入下载队列失败');
    } finally {
      if (mounted) setState(() => _isBatchDownloading = false);
    }
  }

  /// 显示歌单操作 BottomSheet（收藏/删除/取消收藏/导入）。
  /// 顶栏瘦身后仅保留这一个溢出入口，原顶栏的导入/收藏统一收敛到这里。
  void _showPlaylistActionSheet() {
    final options = <_ActionOption>[];
    options.add(
      _ActionOption(
        icon: Icons.playlist_add_rounded,
        title: '通过 ID 导入歌单',
        onTap: () => showImportPlaylistSheet(
          context: context,
          api: widget.api,
          auth: widget.auth,
        ),
      ),
    );
    if (!_isAlbum && !_isInLibrary) {
      options.add(
        _ActionOption(
          icon: Icons.bookmark_add_outlined,
          title: '收藏歌单',
          onTap: _collectPlaylist,
        ),
      );
    }
    if (_isInLibrary &&
        !_libraryPlaylist.isLikedPlaylist &&
        !_libraryPlaylist.isSystemDefaultCollect) {
      final isAlbum = _libraryPlaylist.isCollectedAlbum;
      final isCreated = _libraryPlaylist.isCreatedPlaylist;
      options.add(
        _ActionOption(
          icon: isCreated
              ? Icons.delete_outline_rounded
              : Icons.bookmark_remove_outlined,
          title: isAlbum
              ? '取消收藏专辑'
              : isCreated
              ? '删除歌单'
              : '取消收藏',
          danger: isCreated,
          onTap: _deleteOrUncollectPlaylist,
        ),
      );
    }
    if (options.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '歌单操作',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _ActionOptionTile(option: options[i]),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 58,
                            color: colorScheme.outlineVariant.withValues(
                              alpha: .3,
                            ),
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
  }

  /// 通过歌单 ID 导入并打开歌单详情。
  /// 公开静态 API，供外部调用。
  // ignore: unused_element
  static Future<void> importPlaylistById({
    required BuildContext context,
    required MusicApi api,
    required AuthController auth,
    required PlayerController player,
    required String playlistId,
  }) async {
    Toast.info('正在导入歌单...');
    try {
      final info = await api.playlistInfo(playlistId);
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: info,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) Toast.error('导入失败：$e');
    }
  }

  /// 执行写操作：返回 true 表示成功（AuthController 失败只写 errorMessage
  /// 不抛出，这里统一转成布尔，调用方据此决定是否继续本地收尾动作）。
  Future<bool> _runMutation(Future<void> Function() action) async {
    if (_isMutating) return false;
    setState(() => _isMutating = true);
    try {
      await action();
      if (widget.auth.errorMessage != null) {
        throw Exception(widget.auth.errorMessage);
      }
      Toast.success('操作完成');
      return true;
    } catch (error) {
      Toast.error('操作失败：$error');
      return false;
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    String confirmText = '删除',
  }) {
    // 统一确认弹窗（AppDialogShell + 双药丸，内置连点守卫）。
    return showAppConfirmDialog(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
      barrierDismissible: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // 粘性歌曲条的两行文案：标题放总数、副标题放加载/排序状态，
    // 窄屏下各自省略，不再像之前单行那样把「已加载 xx」挤没。
    final totalCount = (!_hasMore || _allSongsLoaded)
        ? _songs.length
        : (_info?.songCount ?? _songs.length);
    final stickyTitle = _searchQuery.isNotEmpty
        ? '搜索结果 · ${_filteredSongs.length} 首'
        : _allSongsLoaded || !_hasMore
            ? '${_songs.length} 首歌曲'
            : '共 $totalCount 首 · 已加载 ${_songs.length} 首';
    final stickySubtitle = _isLoadingAllSongs
        ? '正在加载全部歌曲…'
        : _searchQuery.isNotEmpty
            ? _sortModeLabel
            : _allSongsLoaded || !_hasMore
                ? _sortModeLabel
                : '$_sortModeLabel · 继续下滑加载更多';

    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) {
          _exitSelectMode();
        }
      },
      child: Scaffold(
        extendBody: true,
        body: AdaptiveContentPadding(
          child: Stack(
            children: [
              // Windows 平台滚动时 sliver item 回收重建会产生大量语义节点更新，
              // 触发 Flutter Windows 引擎 AXTree 更新 bug（console 提示
              // "Failed to update ui::AXTree"）。仅桌面平台排除语义树，
              // 移动端保留无障碍功能。
              // 上游 flutter/flutter#190357 / #192180 未修复，详见 main.dart。
              ExcludeSemantics(
                excluding: isDesktopPlatform,
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      stretch: !_isSearching,
                      centerTitle: true,
                      expandedHeight: _isSearching ? 0 : _heroExpandedHeight,
                      surfaceTintColor: Colors.transparent,
                      elevation: 0,
                      scrolledUnderElevation: 1,
                      shadowColor: Colors.black.withValues(alpha: .08),
                      // 修复穿透：收起时用不透明 surface 遮挡滚动内容，展开时被 _HeroHeader 覆盖
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      // 选择模式也保留默认返回箭头（参考主流 App）：
                      // PopScope 会把返回拦截为退出选择，不需要 X。
                      title: _isSearching
                          // 与首页/搜索页同款胶囊：同高 36、同圆角、同底色、
                          // 同搜索图标与同提示样式，顶栏搜索不再是裸 TextField。
                          ? AppSearchField(
                              controller: _searchController,
                              autofocus: true,
                              hintText: _isLoadingAllSongs
                                  ? '正在加载全部歌曲…'
                                  : '搜索歌曲名或歌手名',
                              onChanged: (value) =>
                                  setState(() => _searchQuery = value),
                              onSubmitted: (_) =>
                                  FocusScope.of(context).unfocus(),
                            )
                          // 参考图4：标题仅在收起后淡入，展开时由 Hero 居中展示，
                          // 顶栏不再与一排按钮抢宽度，窄屏也能完整显示。
                          : AnimatedBuilder(
                              animation: _scrollController,
                              builder: (context, _) {
                                var collapsed = false;
                                if (_scrollController.hasClients) {
                                  final delta =
                                      _heroExpandedHeight - kToolbarHeight;
                                  collapsed = delta <= 0 ||
                                      _scrollController.offset > delta - 48;
                                }
                                return AnimatedOpacity(
                                  opacity: collapsed ? 1 : 0,
                                  duration:
                                      const Duration(milliseconds: 180),
                                  child: Text(
                                    (_info ?? widget.playlist).title,
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
                      // 顶栏瘦身：选择/搜索/分享/导入下沉到 Hero 与粘性条，
                      // 选择模式下顶栏只剩返回+标题（参考图2），全选/完成在粘性条。
                      // 这里最多只剩一个溢出入口，标题不再被挤成几个字。
                      actions: [
                        if (_isSelecting)
                          const SizedBox.shrink()
                        else if (!_isSearching) ...[
                          if (_isMutating)
                            const Padding(
                              padding: EdgeInsets.only(right: 16),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                ),
                              ),
                            )
                          else
                            IconButton(
                              tooltip: '更多',
                              onPressed: _showPlaylistActionSheet,
                              icon: const Icon(Icons.more_vert_rounded),
                            ),
                        ] else
                          IconButton(
                            tooltip: '关闭搜索',
                            onPressed: _toggleSearch,
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                      flexibleSpace: _isSearching
                          ? null
                          : FlexibleSpaceBar(
                              stretchModes: const [StretchMode.zoomBackground],
                              background: _HeroHeader(
                                info: _info ?? widget.playlist,
                                isInLibrary: _isInLibrary,
                                showCollect:
                                    !_isAlbum && !_isDailyRecommend,
                                mutating: _isMutating,
                                downloading: _isBatchDownloading,
                                downloadAvailable: widget
                                        .player.downloadController !=
                                    null,
                                onShare: _sharePlaylist,
                                onCollect: _collectPlaylist,
                                onMore: _showPlaylistActionSheet,
                                onDownloadAll: _downloadAll,
                              ),
                            ),
                    ),
                    if (_isInitialLoading)
                      const _PlaylistDetailSkeleton()
                    else if (_errorMessage case final message?)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _DetailError(
                          title: _isAlbum ? '专辑加载失败' : '歌单加载失败',
                          message: message,
                          onRetry: _loadInitial,
                        ),
                      )
                    else ...[
                      // 参考图4：圆角列表面板的粘性头，置顶后依然可播/可搜/可排。
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _StickyHeaderDelegate(
                          height: _stickyHeaderDelegateHeight,
                          scrollController: _scrollController,
                          heroExpandedHeight:
                              _isSearching ? 0.0 : _heroExpandedHeight,
                          builder: (context, _) {
                            if (isDesktopFormFactor) {
                              return Container(
                                color: Theme.of(context).colorScheme.surface,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      height: _stickyHeaderHeight,
                                      child: ListStickyBar(
                                        flatTop: true,
                                        topRadiusOverride: 0.0,
                                        selecting: _isSelecting,
                                        selectedCount: _selectedCount,
                                        allSelected: _isAllSelected,
                                        onToggleSelectAll: _selectPool.isEmpty
                                            ? null
                                            : _toggleSelectAll,
                                        onDone: _exitSelectMode,
                                        title: stickyTitle,
                                        subtitle: stickySubtitle,
                                        canPlay:
                                            _playbackQueueNow().isNotEmpty,
                                        onPlay: _playAll,
                                        onPlayMv: _playAllMv,
                                        onSearch: _toggleSearch,
                                        onSort: () => _showSortSheet(context),
                                        selectEnabled:
                                            _songs.isNotEmpty || _hasMore,
                                        onSelect: _enterSelectMode,
                                      ),
                                    ),
                                    if (_showDesktopTableHeader)
                                      SizedBox(
                                        height: 36.0,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: _DesktopSongTableHeader(
                                            selecting: _isSelecting,
                                            allSelected: _isAllSelected,
                                            onToggleSelectAll:
                                                _selectPool.isEmpty
                                                    ? null
                                                    : _toggleSelectAll,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            }
                            return ListStickyBar(
                              flatTop: true,
                              topRadiusOverride: 0.0,
                              selecting: _isSelecting,
                              selectedCount: _selectedCount,
                              allSelected: _isAllSelected,
                              onToggleSelectAll: _selectPool.isEmpty
                                  ? null
                                  : _toggleSelectAll,
                              onDone: _exitSelectMode,
                              title: stickyTitle,
                              subtitle: stickySubtitle,
                              canPlay: _playbackQueueNow().isNotEmpty,
                              onPlay: _playAll,
                              onPlayMv: _playAllMv,
                              onSearch: _toggleSearch,
                              onSort: () => _showSortSheet(context),
                              selectEnabled: _songs.isNotEmpty || _hasMore,
                              onSelect: _enterSelectMode,
                            );
                          },
                        ),
                      ),
                      // 只有空列表时才用全屏 loading 占位；已有歌曲时保留列表、
                      // 仅在列表上方叠加一条小提示，避免 CustomScrollView 内容
                      // 高度塌陷导致滚动位置被钳制回顶部。
                      if (_isLoadingAllSongs && _songs.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: Column(
                                children: [
                                  CircularProgressIndicator(strokeWidth: 2.4),
                                  SizedBox(height: 12),
                                  Text('正在加载全部歌曲…'),
                                ],
                              ),
                            ),
                          ),
                        )
                      else if (_searchQuery.isNotEmpty &&
                          _filteredSongs.isEmpty &&
                          !_isLoadingAllSongs)
                        const SliverToBoxAdapter(child: _SearchEmpty())
                      else ...[
                        if (_isLoadingAllSongs)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Text('正在加载全部歌曲…'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (isDesktopFormFactor)
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              4,
                              16,
                              _isSelecting ? 110 : 16,
                            ),
                            sliver: SliverFixedExtentList(
                              itemExtent: _DesktopSongTableRow.rowHeight,
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final song = _filteredSongs[index];
                                  return _DesktopSongTableRow(
                                    key: _locateTargetIndex == index
                                        ? _locateRowKey
                                        : null,
                                    song: song,
                                    index: index + 1,
                                    player: widget.player,
                                    auth: widget.auth,
                                    canDelete: _canEdit,
                                    selecting: _isSelecting,
                                    selected: _isSongSelected(song),
                                    isFocused:
                                        _focusedSongKey == _songKey(song),
                                    onTap: () {
                                      if (_isSelecting) {
                                        _toggleSongSelection(song);
                                        return;
                                      }
                                      setState(
                                        () => _focusedSongKey = _songKey(song),
                                      );
                                    },
                                    onDoubleTap: () {
                                      if (_isSelecting) return;
                                      final queue = _playbackQueueNow();
                                      if (queue.isEmpty) return;
                                      widget.player.playSong(
                                        song,
                                        queue: List<Song>.of(queue),
                                      );
                                      _expandQueueInBackgroundIfNeeded(
                                        startedWith: song,
                                      );
                                    },
                                    onPlay: () {
                                      final queue = _playbackQueueNow();
                                      if (queue.isEmpty) return;
                                      widget.player.playSong(
                                        song,
                                        queue: List<Song>.of(queue),
                                      );
                                      _expandQueueInBackgroundIfNeeded(
                                        startedWith: song,
                                      );
                                    },
                                    onAddToPlaylist: () =>
                                        _addSongToPlaylist(song),
                                    onDelete: () => _removeSong(song),
                                    onViewArtist: () => _openArtist(song),
                                    onMore: () => _showSongMenu(song),
                                    onSecondaryMore: (position) =>
                                        _showSongMenu(song, anchor: position),
                                  );
                                },
                                childCount: _filteredSongs.length,
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              4,
                              16,
                              _isSelecting ? 110 : 16,
                            ),
                            sliver: SliverList.separated(
                              itemCount: _filteredSongs.length,
                              // 扁平行只靠呼吸间距分隔，不再用卡片式大间隙。
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 2),
                              itemBuilder: (context, index) {
                                final song = _filteredSongs[index];
                                return _SongRow(
                                  key: _locateTargetIndex == index
                                      ? _locateRowKey
                                      : null,
                                  song: song,
                                  player: widget.player,
                                  canDelete: _canEdit,
                                  selecting: _isSelecting,
                                  selected: _isSongSelected(song),
                                  onTap: () {
                                    if (_isSelecting) {
                                      _toggleSongSelection(song);
                                      return;
                                    }
                                    // 点到当前歌：打开播放页，绝不重头播放。
                                    if (openPlayerIfSameSong(
                                      context,
                                      player: widget.player,
                                      auth: widget.auth,
                                      song: song,
                                    )) {
                                      return;
                                    }
                                    final queue = _playbackQueueNow();
                                    if (queue.isEmpty) return;
                                    widget.player.playSong(
                                      song,
                                      queue: List<Song>.of(queue),
                                    );
                                    _expandQueueInBackgroundIfNeeded(
                                      startedWith: song,
                                    );
                                  },
                                  onAddToPlaylist: () =>
                                      _addSongToPlaylist(song),
                                  onDelete: () => _removeSong(song),
                                  onViewArtist: () => _openArtist(song),
                                );
                              },
                            ),
                          ),
                        if (_searchQuery.isEmpty)
                          SliverToBoxAdapter(
                            child: _LoadMoreFooter(
                              hasMore: _hasMore,
                              isLoading: _isLoadingMore,
                              errorMessage: _loadMoreError,
                              onRetry: _loadMore,
                            ),
                          ),
                        if (_searchQuery.isEmpty &&
                            _similarPlaylists.isNotEmpty)
                          SliverToBoxAdapter(
                            child: _SimilarPlaylistsSection(
                              playlists: _similarPlaylists,
                              onTap: _openSimilarPlaylist,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
              if (_isSelecting)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: bottomInset > 0 ? bottomInset + 10 : 16,
                  child: _SelectionBottomBar(
                    canDelete: _canEdit,
                    downloading: _isBatchDownloading,
                    onPlayNext: _selectedCount > 0 ? _batchPlayNext : null,
                    onAddToPlaylist: _selectedCount > 0
                        ? _batchAddToPlaylist
                        : null,
                    onDownload: _selectedCount > 0 && !_isBatchDownloading
                        ? _batchDownload
                        : null,
                    onDelete: _canEdit && _selectedCount > 0
                        ? _batchDelete
                        : null,
                  ),
                )
              else
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottomInset + 10,
                  child: MiniPlayerSlot(player: widget.player, auth: widget.auth),
                ),
              // 右下角手动定位按钮：进入页面不再自动滚动，由用户点击定位。
              // 多选模式下隐藏（给多选底栏让位）；显隐用 AnimatedBuilder 只
              // 重建按钮子树，响应切歌，不 setState 整页。
              // bottom 在 MiniPlayer 顶边之上再留 8px 间隙，避免按钮阴影
              // 贴住迷你播放条；桌面形态没有迷你播放条（内容区底部已有
              // DesktopPlayerBar），贴底留常规边距即可。
              if (!_isSelecting)
                Positioned(
                  right: isDesktopFormFactor ? 24.0 : 16.0,
                  bottom: isDesktopFormFactor
                      ? bottomInset + 16
                      : bottomInset + _miniPlayerExtent + 10 + 8,
                  child: AnimatedBuilder(
                    animation: widget.player,
                    builder: (context, _) {
                      if (!_canShowLocateButton) {
                        return const SizedBox.shrink();
                      }
                      return LocateCurrentSongButton(
                        onPressed: _locateCurrentSong,
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
}

/// 相似歌单横向区块。
class _SimilarPlaylistsSection extends StatelessWidget {
  const _SimilarPlaylistsSection({
    required this.playlists,
    required this.onTap,
  });

  final List<PlaylistSummary> playlists;
  final ValueChanged<PlaylistSummary> onTap;

  @override
  Widget build(BuildContext context) {
    return AppHorizontalRail<PlaylistSummary>(
      title: '相似歌单',
      items: playlists,
      height: 170,
      itemWidth: 120,
      topPadding: 20,
      itemBuilder: (context, playlist) => _SimilarPlaylistCard(
        playlist: playlist,
        onTap: () => onTap(playlist),
      ),
    );
  }
}

class _SimilarPlaylistCard extends StatelessWidget {
  const _SimilarPlaylistCard({required this.playlist, required this.onTap});

  final PlaylistSummary playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = isDesktopFormFactor;
    final cardRadius = isDesktop ? 8.0 : 14.0;
    final hoverRadius = isDesktop ? 10.0 : cardRadius;
    const desktopInset = 6.0;
    final imageSize = isDesktop ? (120.0 - desktopInset * 2) : 120.0;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
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
            child: Artwork(url: playlist.coverUrl, size: imageSize, borderRadius: cardRadius),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          playlist.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        Text(
          playlist.creatorName ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    final padded = isDesktop
        ? Padding(
            padding: const EdgeInsets.all(desktopInset),
            child: column,
          )
        : column;

    final inkCard = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hoverRadius),
      child: SizedBox(
        width: 120,
        child: padded,
      ),
    );

    if (isDesktop) {
      return Align(
        alignment: Alignment.topCenter,
        child: inkCard,
      );
    }
    return inkCard;
  }
}

class _SelectionBottomBar extends StatelessWidget {
  const _SelectionBottomBar({
    required this.canDelete,
    required this.downloading,
    required this.onPlayNext,
    required this.onAddToPlaylist,
    required this.onDownload,
    required this.onDelete,
  });

  final bool canDelete;
  final bool downloading;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
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
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.queue_music_rounded,
                  label: '下一首',
                  onTap: onPlayNext,
                ),
              ),
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.playlist_add_rounded,
                  label: '加歌单',
                  onTap: onAddToPlaylist,
                ),
              ),
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.download_rounded,
                  label: downloading ? '加入中…' : '下载',
                  busy: downloading,
                  onTap: onDownload,
                ),
              ),
              if (canDelete)
                Expanded(
                  child: _SelectionActionButton(
                    icon: Icons.delete_outline_rounded,
                    label: '删除',
                    danger: true,
                    onTap: onDelete,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionActionButton extends StatelessWidget {
  const _SelectionActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isEnabled = onTap != null && !busy;

    final color = !isEnabled
        ? colorScheme.onSurface.withValues(alpha: isDark ? .28 : .32)
        : danger
            ? colorScheme.error
            : colorScheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: isEnabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(14),
        splashColor: (danger ? colorScheme.error : colorScheme.primary)
            .withValues(alpha: .12),
        highlightColor: (danger ? colorScheme.error : colorScheme.primary)
            .withValues(alpha: .06),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: color,
                  ),
                )
              else
                Icon(icon, color: color, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: isEnabled ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 12,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌单操作选项数据。
class _ActionOption {
  const _ActionOption({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;
}

/// 歌单操作选项条目。
class _ActionOptionTile extends StatelessWidget {
  const _ActionOptionTile({required this.option});

  final _ActionOption option;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = option.danger ? colorScheme.error : colorScheme.onSurface;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        option.onTap();
      },
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(option.icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                option.title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 参考图2的居中大封面头：封面 + 居中标题/副标题/meta + 圆形操作行。
/// 原来的左右白卡在窄屏下挤压标题，这里标题独占整行居中，最多两行。
class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.info,
    required this.isInLibrary,
    required this.showCollect,
    required this.mutating,
    required this.downloading,
    required this.downloadAvailable,
    required this.onShare,
    required this.onCollect,
    required this.onMore,
    required this.onDownloadAll,
  });

  final PlaylistSummary info;
  final bool isInLibrary;
  final bool showCollect;
  final bool mutating;
  final bool downloading;
  final bool downloadAvailable;
  final VoidCallback onShare;
  final VoidCallback onCollect;
  final VoidCallback onMore;
  final VoidCallback onDownloadAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 桌面端紧凑横排头（仿 QQ 音乐 PC）：封面 120 左置，
    // 标题/副标题/meta/操作右置，高度收敛在 236 内。
    // 移动端居中大封面 412 在 PC 上过于空旷（分享/下载占满首屏）。
    if (isDesktopFormFactor) {
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
            padding: const EdgeInsets.fromLTRB(24, kToolbarHeight + 8, 24, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: isDark ? .35 : .18),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Artwork(
                    url: info.coverUrl,
                    size: 120,
                    borderRadius: 18,
                  ),
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              height: 1.2,
                              letterSpacing: -0.3,
                            ),
                      ),
                      if (info.subtitle?.trim().isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            info.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(
                            alpha: isDark ? .20 : .10,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _detailMeta(info),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 11.5,
                              ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _HeroPillAction(
                            icon: Icons.share_rounded,
                            label: '分享',
                            onTap: onShare,
                          ),
                          if (showCollect) ...[
                            const SizedBox(width: 10),
                            _HeroPillAction(
                              icon: isInLibrary
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              label: mutating
                                  ? '请稍候'
                                  : (isInLibrary ? '已收藏' : '收藏'),
                              onTap: isInLibrary ? onMore : onCollect,
                            ),
                          ],
                          const SizedBox(width: 10),
                          _HeroPillAction(
                            icon: downloading
                                ? Icons.downloading_rounded
                                : Icons.download_rounded,
                            label: downloading ? '下载中' : '下载',
                            onTap: downloadAvailable && !downloading
                                ? onDownloadAll
                                : null,
                          ),
                        ],
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
          // 顶部避开 pinned AppBar 的 toolbar（状态栏已由 SafeArea 处理）；
          // 内容总高需收敛在 expandedHeight 内，避免小屏溢出裁剪操作行。
          padding: const EdgeInsets.fromLTRB(24, kToolbarHeight + 2, 24, 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? .35 : .18),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Artwork(
                  url: info.coverUrl,
                  size: 132,
                  borderRadius: 26,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                info.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      height: 1.2,
                      letterSpacing: -0.3,
                    ),
              ),
              const SizedBox(height: 4),
              if (info.subtitle?.trim().isNotEmpty == true)
                Text(
                  info.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? .20 : .10,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _detailMeta(info),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _HeroCircleAction(
                    icon: Icons.share_rounded,
                    label: '分享',
                    onTap: onShare,
                  ),
                  if (showCollect) ...[
                    const SizedBox(width: 24),
                    _HeroCircleAction(
                      icon: isInLibrary
                          ? Icons.bookmark_added_rounded
                          : Icons.bookmark_add_outlined,
                      label: mutating
                          ? '请稍候'
                          : (isInLibrary ? '已收藏' : '收藏'),
                      onTap: isInLibrary ? onMore : onCollect,
                    ),
                  ],
                  const SizedBox(width: 24),
                  _HeroCircleAction(
                    icon: downloading
                        ? Icons.downloading_rounded
                        : Icons.download_rounded,
                    label: downloading ? '下载中' : '下载',
                    onTap: downloadAvailable && !downloading
                        ? onDownloadAll
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero 区圆形幽灵按钮：图标圆底 + 下方文字，与参考图的分享/下载一致，
/// 不再用顶栏小图标挤占标题空间。
class _HeroCircleAction extends StatelessWidget {
  const _HeroCircleAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    final fg = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: .38);

    return Opacity(
      opacity: enabled ? 1 : .55,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: isDark
                ? Colors.white.withValues(alpha: .10)
                : Colors.white.withValues(alpha: .78),
            shape: const CircleBorder(),
            elevation: 0,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: Icon(icon, size: 22, color: fg),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: enabled
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.onSurfaceVariant.withValues(alpha: .5),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
          ),
        ],
      ),
    );
  }
}

/// Hero 区胶囊操作按钮（桌面紧凑头专用）：图标 + 文字横排一颗胶囊，
/// 比圆形双行按钮更省纵向空间。
class _HeroPillAction extends StatelessWidget {
  const _HeroPillAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    final fg = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: .38);

    return Opacity(
      opacity: enabled ? 1 : .55,
      child: Material(
        color: isDark
            ? Colors.white.withValues(alpha: .10)
            : Colors.white.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(20),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
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

class _PlaylistDetailSkeleton extends StatelessWidget {
  const _PlaylistDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 118),
      sliver: SliverList.list(
        children: [
          Row(
            children: [
              const _SkeletonBox(width: 108, height: 18, radius: 7),
              const Spacer(),
              _SkeletonBox(width: 104, height: 40, radius: 20),
            ],
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < 10; index++) ...[
            const _PlaylistSkeletonSongRow(),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

class _PlaylistSkeletonSongRow extends StatelessWidget {
  const _PlaylistSkeletonSongRow();

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
              _SkeletonBox(width: 142, height: 14, radius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        _SkeletonBox(width: 38, height: 14, radius: 6),
        SizedBox(width: 18),
        _SkeletonBox(width: 24, height: 24, radius: 12),
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

/// 粘性头的 sliver 代理：固定高度，置顶后依然可播/可搜/可排（参考图4）。
@visibleForTesting
class StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  StickyHeaderDelegate({
    required this.height,
    this.child,
    this.builder,
    this.scrollController,
    this.heroExpandedHeight,
  }) : assert(
          child != null || builder != null,
          'Either child or builder must be provided',
        );

  final double height;
  final Widget? child;
  final Widget Function(BuildContext context, double topRadius)? builder;
  final ScrollController? scrollController;
  final double? heroExpandedHeight;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  double _computeTopRadius() {
    // 圆角已取消（移动端默认展开态的顶部左右圆弧不好看）：粘性条恒为直角无阴影，
    // 与桌面端扁平表头一致，不再随滚动插值。
    return 0.0;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    if (builder != null) {
      if (scrollController != null) {
        return AnimatedBuilder(
          animation: scrollController!,
          builder: (context, _) {
            final radius = _computeTopRadius();
            return SizedBox.expand(child: builder!(context, radius));
          },
        );
      }
      final radius = _computeTopRadius();
      return SizedBox.expand(child: builder!(context, radius));
    }
    return SizedBox.expand(child: child!);
  }

  @override
  bool shouldRebuild(covariant StickyHeaderDelegate oldDelegate) {
    return oldDelegate.height != height ||
        oldDelegate.child != child ||
        oldDelegate.builder != builder ||
        oldDelegate.scrollController != scrollController ||
        oldDelegate.heroExpandedHeight != heroExpandedHeight;
  }
}

typedef _StickyHeaderDelegate = StickyHeaderDelegate;

/// 「以 MV 播放」小圆钮：与播放键同形制，music_video 图标区分。
class _MvPlayButton extends StatelessWidget {
  const _MvPlayButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.primary.withValues(alpha: .14),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        mouseCursor: SystemMouseCursors.click,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child: Icon(
              Icons.music_video_rounded,
              size: 22,
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 参考图4的粘性歌曲条：左侧蓝色播放 pill，
/// 中间两行计数（标题+副标题各自省略，窄屏不再挤没「已加载」），
/// 右侧搜索/排序/多选三个幽灵图标。多选模式下切换为已选计数+全选。
///
/// 圆角契约：粘性条恒为顶部直角、无上浮阴影（移动端默认展开态的左右圆弧
/// 已取消，与桌面端 QQ 音乐 PC 式扁平表头一致，置顶时与 AppBar 无缝）。
/// [flatTop]/[topRadiusOverride] 参数保留兼容（widget 仍支持圆角），
/// 页面层统一传入直角。
@visibleForTesting
class ListStickyBar extends StatelessWidget {
  const ListStickyBar({
    super.key,
    required this.selecting,
    required this.selectedCount,
    required this.allSelected,
    required this.onToggleSelectAll,
    required this.onDone,
    required this.title,
    required this.subtitle,
    required this.canPlay,
    required this.onPlay,
    required this.onSearch,
    required this.onSort,
    required this.selectEnabled,
    required this.onSelect,
    this.flatTop = false,
    this.topRadiusOverride,
    this.onPlayMv,
  });

  final bool selecting;
  final int selectedCount;
  final bool allSelected;
  final VoidCallback? onToggleSelectAll;
  final VoidCallback onDone;
  final String title;
  final String subtitle;
  final bool canPlay;
  final VoidCallback onPlay;
  final VoidCallback onSearch;
  final VoidCallback onSort;
  final bool selectEnabled;
  final VoidCallback onSelect;
  final bool flatTop;
  final double? topRadiusOverride;

  /// 「以 MV 播放全部」：非 null 时播放键旁显示 MV 图标按钮。
  final VoidCallback? onPlayMv;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final effectiveRadius =
        (topRadiusOverride ?? (flatTop ? 0.0 : AppRadius.lg))
            .clamp(0.0, AppRadius.lg);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: effectiveRadius <= 0
            ? BorderRadius.zero
            : BorderRadius.vertical(
                top: Radius.circular(effectiveRadius),
              ),
        boxShadow: effectiveRadius <= 0
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? .25 : .07),
                  blurRadius: 12,
                  offset: const Offset(0, -4),
                ),
              ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      // 选择模式（参考图2）：复选框+全选+已选计数+右侧蓝色完成，
      // 顶栏不再重复放全选，返回箭头即退出选择。
      child: selecting
          ? Row(
              children: [
                MusicCircleCheckbox(
                  value: allSelected,
                  onChanged: onToggleSelectAll == null
                      ? null
                      : (_) => onToggleSelectAll!(),
                ),
                const SizedBox(width: 8),
                Text(
                  '全选',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '已选 $selectedCount 首',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Material(
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? .22 : .12,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onDone,
                    mouseCursor: SystemMouseCursors.click,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      child: Text(
                        '完成',
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Material(
                  color: canPlay
                      ? colorScheme.primary
                      : colorScheme.primary.withValues(alpha: .38),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: canPlay ? onPlay : null,
                    mouseCursor: canPlay
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    customBorder: const CircleBorder(),
                    child: const SizedBox.square(
                      dimension: 40,
                      child: Center(
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 24,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (onPlayMv != null) ...[
                  _MvPlayButton(onPressed: onPlayMv!),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  height: 1.15,
                                ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                              fontSize: 11.5,
                              height: 1.15,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StickyHeaderIconButton(
                  icon: Icons.search_rounded,
                  tooltip: '搜索',
                  onTap: onSearch,
                ),
                const SizedBox(width: 8),
                _StickyHeaderIconButton(
                  icon: Icons.sort_rounded,
                  tooltip: '排序',
                  onTap: onSort,
                ),
                const SizedBox(width: 8),
                _StickyHeaderIconButton(
                  icon: Icons.checklist_rounded,
                  tooltip: '多选',
                  onTap: selectEnabled ? onSelect : null,
                ),
              ],
            ),
    );
  }
}

class _StickyHeaderIconButton extends StatelessWidget {
  const _StickyHeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? Colors.white.withValues(alpha: .08)
        : Colors.black.withValues(alpha: .04);
    final iconColor = onTap == null
        ? colorScheme.onSurface.withValues(alpha: .38)
        : colorScheme.onSurface;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bgColor,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          mouseCursor: onTap != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 36,
            child: Center(
              child: Icon(
                icon,
                size: 20,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 40, 18, 160),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          const SizedBox(height: 12),
          Text(
            '没有找到匹配的歌曲',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({
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
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 118),
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
        padding: EdgeInsets.fromLTRB(18, 14, 18, 118),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 118),
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

/// 移动端歌单行：视觉委托给公共 [AppSongRow]，这里只组装
/// 多选复选框与更多菜单（下一首/加歌单/看歌手/删除/下载）。
class _SongRow extends StatelessWidget {
  const _SongRow({
    super.key,
    required this.song,
    required this.player,
    required this.canDelete,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onDelete,
    required this.onViewArtist,
  });

  final Song song;
  final PlayerController player;
  final bool canDelete;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    return AppSongRow(
      song: song,
      player: player,
      onTap: onTap,
      excludeSemantics: isDesktopPlatform,
      highlighted: selecting && selected,
      leading: selecting
          ? MusicCircleCheckbox(
              value: selected,
              onChanged: (_) => onTap(),
            )
          : null,
      trailing: selecting
          ? const []
          : [AppSongRowMenuButton(onPressed: () => _showMenu(context))],
    );
  }

  void _showMenu(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      actions: [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: player,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: onAddToPlaylist,
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: onViewArtist,
        ),
        if (canDelete)
          SongSheetAction(
            icon: Icons.delete_outline_rounded,
            title: '从歌单删除',
            danger: true,
            onTap: onDelete,
          ),
        if (player.downloadController != null)
          SongSheetAction(
            icon: player.downloadController!.isDownloaded(song)
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            title: player.downloadController!.isDownloaded(song)
                ? '已下载'
                : '下载',
            onTap: () => player.downloadController!
                .download(song, player.audioQuality),
          ),
      ],
    );
  }
}

typedef _DesktopSongTableHeader = DesktopSongTableHeader;
typedef _DesktopSongTableRow = DesktopSongTableRow;

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
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
          Text(title, style: Theme.of(context).textTheme.titleLarge),
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

enum _SongSortMode { defaultOrder, byTitle, byArtist, byAlbum }

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
              Icon(Icons.check_rounded, size: 20, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

String _detailMeta(PlaylistSummary info) {
  if (info.isCollectedAlbum) {
    if (info.songCount != null) {
      return '${info.songCount} 首歌';
    }
    return '新专辑';
  }
  final parts = <String>[];
  if (info.songCount != null) {
    parts.add('${info.songCount} 首歌');
  }
  if (info.playCount != null) {
    parts.add(_playCount(info.playCount));
  }
  return parts.isEmpty ? '来自 ${AppConfig.appName}' : parts.join(' · ');
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
