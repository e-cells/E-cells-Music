import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/mv_player_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../form_factor.dart';
import '../widgets/app_feedback.dart' show friendlyServiceErrorMessage;
import '../widgets/artwork.dart';
import '../widgets/horizontal_wheel_scroll.dart';
import '../widgets/mini_player.dart';
import '../widgets/refresh_equalizer.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/swr_section_state.dart';
import '../widgets/toast.dart';
import '../player/song_tap_handler.dart';
import '../widgets/desktop_song_table_row.dart'
    show DesktopSongTableHeader, DesktopSongTableRow;
import 'artist_detail_page.dart';

/// 排行榜页面 —— 展示酷狗各类榜单，点击榜单查看歌曲列表。
class RankPage extends StatefulWidget {
  const RankPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;

  @override
  State<RankPage> createState() => RankPageState();
}

class RankPageState extends SwrSectionState<RankPage, List<RankCategory>>
    with AutomaticKeepAliveClientMixin {
  // 进程级单份缓存（基类契约：静态内存缓存进程内保活）：LRU 淘汰本页后
  // 重进靠它瞬间命中上屏 + 静默刷新，不走磁盘。两份静态均为定量单副本、
  // 整体替换不随会话增长，刻意不在 dispose 清理——Element/State 的释放
  // 已由 LazyIndexedStack LRU 完成，那才是内存大头。
  static List<RankCategory>? _cachedRanks;
  static List<Song>? _cachedNewSongs;

  /// 附加数据（新歌推荐）独立于主数据的 Future：独立缓存 key
  /// （cache_rank_new）、独立失败语义（失败降级缓存，不拖累榜单），
  /// 因此不走基类主数据生命周期，由 [loadSidecar] / [onSectionRestored] 驱动。
  Future<List<Song>>? _newSongsFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  CacheService get cache => widget.cache;

  @override
  List<RankCategory>? get cachedData => _cachedRanks;

  @override
  set cachedData(List<RankCategory>? value) => _cachedRanks = value;

  @override
  String get cacheKey => 'cache_rank';

  @override
  Duration get cacheTtl => AppConfig.rankCacheTtl;

  @override
  List<RankCategory> decodeCache(Map<String, dynamic> json) =>
      (json['ranks'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RankCategory.fromCache)
          // 与 API 层 rankList 的 rankId > 0 过滤对齐：异常/旧结构缓存
          // 混入 rankId=0 项时不再进入 UI（否则详情页会以 rankId=0 请求）。
          .where((c) => c.rankId > 0)
          .toList();

  @override
  Map<String, dynamic> encodeCache(List<RankCategory> ranks) =>
      {'ranks': ranks.map((r) => r.toCache()).toList()};

  @override
  bool hasContent(List<RankCategory> ranks) => ranks.isNotEmpty;

  @override
  Future<List<RankCategory>> fetchData() => widget.api.rankList(withSong: 1);

  @override
  Future<void> restoreSidecarFromDisk() async {
    try {
      final songsCache = await cache.read<Map<String, dynamic>>(
        'cache_rank_new',
        decode: (json) => json,
        ttl: AppConfig.rankCacheTtl,
      );
      if (!mounted) return;
      _cachedNewSongs =
          (songsCache?.data['songs'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(Song.fromCache)
              .where((s) => s.hash.isNotEmpty)
              .toList();
    } catch (_) {
      // 新歌缓存损坏则忽略，静默刷新会重建。
    }
  }

  @override
  void onSectionRestored() {
    _newSongsFuture ??= Future.value(_cachedNewSongs ?? const <Song>[]);
  }

  @override
  Future<void> loadSidecar(int epoch) {
    // 直接挂 in-flight Future：等待期 FutureBuilder 回落到 fallback
    // （旧缓存）展示，与原实现的最终表现一致。
    final future = _loadNewSongs(epoch: epoch);
    _newSongsFuture = future;
    return future;
  }

  void _persistNewSongs(List<Song> songs) {
    unawaited(() async {
      try {
        await widget.cache.write('cache_rank_new', {
          'songs': songs.map((s) => s.toCache()).toList(),
        });
      } catch (_) {
        // 缓存写入失败不影响已拿到的网络数据上屏。
      }
    }());
  }

  /// 新歌推荐失败不阻塞榜单：无缓存时返回空（隐藏该区域），有缓存时降级到缓存。
  Future<List<Song>> _loadNewSongs({int? epoch}) async {
    try {
      final songs = await widget.api.newSongs();
      // 空结果不覆盖缓存（同榜单主数据：异常静默空列表会毁掉离线兜底）。
      if (songs.isNotEmpty && (epoch == null || epoch == currentEpoch)) {
        _cachedNewSongs = songs;
        _persistNewSongs(songs);
      }
      return songs;
    } catch (_) {
      return _cachedNewSongs ?? const <Song>[];
    }
  }

  void _openRankDetail(RankCategory rank) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RankDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          rank: rank,
        ),
      ),
    );
  }

  int? _playingRankId;

  /// 榜单封面播钮：一键播放该榜。
  /// 列表预览（songinfo）无可播 hash：先拉第一页即播（转圈等待），再后台拉
  /// 全榜（TOP500 这类大榜）静默补进播放队列，播完 50 首不断档、直接续播。
  /// 失败静默忽略（保持当前播放不变）。
  Future<void> _playRank(RankCategory rank) async {
    if (_playingRankId != null) return;
    setState(() => _playingRankId = rank.rankId);
    try {
      final first = await widget.api.rankAudio(
        rankId: rank.rankId,
        page: 1,
        pageSize: 50,
      );
      if (!mounted) return;
      if (first.songs.isEmpty) return;
      await widget.player.playSong(first.songs.first, queue: first.songs);
      if (!mounted) return;
      setState(() => _playingRankId = null);
      // 首屏已在播：后台拉全榜补齐队列（用户切走则放弃，不抢队列）。
      unawaited(_expandRankQueue(rank, first.songs));
    } catch (_) {
      // 播放/拉取失败：保持原播放状态，不打断用户。
    } finally {
      if (mounted) setState(() => _playingRankId = null);
    }
  }

  /// 后台拉取整榜并在用户仍听本榜时扩展播放队列（与榜单详情页同款机制）。
  Future<void> _expandRankQueue(
    RankCategory rank,
    List<Song> startedWith,
  ) async {
    if (startedWith.isEmpty) return;
    String keyOf(Song s) => s.hash.isNotEmpty ? s.hash : s.id;
    // 拉全榜耗时数秒，期间用户可能"下一首播放"插入歌曲：记录起点队列
    // 长度，完成时长度有变即放弃整队替换——replaceQueue 会吞掉用户的
    // 插入，宁可这次不补全（下次播放会再试）。
    final queueLengthAtStart = widget.player.queue.length;
    try {
      final fetched = await widget.api.rankAudioAll(rankId: rank.rankId);
      // 上游对越界页可能重复返回最后一页（replaceQueue 不去重）：
      // 先按键去重再比较/入队，避免播放队列出现重复歌曲。
      final seen = <String>{};
      final all = <Song>[
        for (final song in fetched)
          if (seen.add(keyOf(song))) song,
      ];
      if (!mounted || all.length <= startedWith.length) return;
      if (widget.player.queue.length != queueLengthAtStart) return;
      final current = widget.player.currentSong;
      final startedKeys = startedWith.map(keyOf).toSet();
      final currentKey = current == null ? '' : keyOf(current);
      final queueStillOurs = widget.player.queue.any(
        (s) => startedKeys.contains(keyOf(s)),
      );
      // 用户已切到其它来源则不改队列。
      if ((currentKey.isEmpty || !startedKeys.contains(currentKey)) &&
          !queueStillOurs) {
        return;
      }
      if (all.length <= widget.player.queue.length) return;
      await widget.player.replaceQueue(all);
    } catch (_) {
      // 补全失败：保持首屏 50 首播放，不打断用户。
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final size = MediaQuery.sizeOf(context);
    final isCarLandscape =
        size.width > size.height && ThemeController.instance.carModeEnabled;

    // 磁盘恢复中（主数据 Future 尚未确定）：显示骨架，避免闪现空态。
    final initialFuture = sectionFuture;
    if (initialFuture == null) {
      return _RankSkeleton(isCarLandscape: isCarLandscape);
    }
    return FutureBuilder<List<RankCategory>>(
      future: initialFuture,
      builder: (context, snapshot) {
        // 与推荐页一致：优先显示内存/磁盘缓存，无缓存才走骨架/错误态；
        // 刷新失败时保持缓存显示，不闪回错误页。
        final ranks = snapshot.data ?? _cachedRanks ?? const <RankCategory>[];
        if (snapshot.connectionState == ConnectionState.waiting &&
            ranks.isEmpty) {
          return _RankSkeleton(isCarLandscape: isCarLandscape);
        }
        if (snapshot.hasError && ranks.isEmpty) {
          return _RankError(
            message: snapshot.error.toString(),
            onRetry: refresh,
          );
        }
        if (ranks.isEmpty) {
          return const _RankEmpty();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部均衡器刷新动画：刷新在途时出现，平时收起不占位。
            RefreshEqualizer(visible: showRefreshEqualizer),
            // 新歌推荐区域
            _NewSongsSection(
              key: ValueKey('rank_newsongs_$railResetEpoch'),
              future: _newSongsFuture,
              player: widget.player,
              auth: widget.auth,
              fallback: _cachedNewSongs ?? const <Song>[],
            ),
            // 榜单标题：与电台 _RadioSectionTitle 视觉与间距完全对齐
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(
                          alpha: Theme.of(context).brightness == Brightness.dark ? .18 : .12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.leaderboard_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '排行榜',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.3,
                          ),
                    ),
                  ),
                ],
              ),
            ),
            // 与电台标题下 SizedBox(height: 12) 完全对齐。
            const SizedBox(height: 12),
            // 榜单列表：QQ 式大卡（左封面 + 右榜名 + 前 3 首），点卡进详情，
            // 点封面右下播钮直接播放（精准命中才拦截，见 _RankCard）。
            // 行式多列：每行 N 张等宽卡，行高由最高的卡自然撑开，不设任何
            // 固定高度——屏宽/字体再怎么变都不可能 OVERFLOW。
            // 多列门槛：车机横屏 + 平板侧栏形态（移动形态宽内容区）；
            // 桌面保持 1 列不变。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final multiColumn = isCarLandscape ||
                      (!isDesktopFormFactor &&
                          AdaptiveLayout.isGridWidth(constraints.maxWidth));
                  final count = !multiColumn
                      ? 1
                      : (constraints.maxWidth > 1000
                          ? 3
                          : (constraints.maxWidth > 640 ? 2 : 1));
                  final gap = multiColumn ? 10.0 : 12.0;
                  if (count == 1) {
                    return ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: ranks.length,
                      separatorBuilder: (_, _) => SizedBox(height: gap),
                      itemBuilder: (context, index) {
                        final rank = ranks[index];
                        return _RankCard(
                          rank: rank,
                          onTap: () => _openRankDetail(rank),
                          onPlay: () => _playRank(rank),
                          playing: _playingRankId == rank.rankId,
                        );
                      },
                    );
                  }
                  final rowCount = (ranks.length + count - 1) ~/ count;
                  return ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: rowCount,
                    separatorBuilder: (_, _) => SizedBox(height: gap),
                    itemBuilder: (context, row) {
                      final items =
                          ranks.skip(row * count).take(count).toList();
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) SizedBox(width: gap),
                            Expanded(
                              child: _RankCard(
                                rank: items[i],
                                onTap: () => _openRankDetail(items[i]),
                                onPlay: () => _playRank(items[i]),
                                playing:
                                    _playingRankId == items[i].rankId,
                              ),
                            ),
                          ],
                          // 末行不满：空位占齐，保证卡片等宽对齐。
                          for (var i = items.length; i < count; i++) ...[
                            SizedBox(width: gap),
                            const Expanded(child: SizedBox.shrink()),
                          ],
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 166),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 新歌推荐
// ---------------------------------------------------------------------------

class _NewSongsSection extends StatelessWidget {
  const _NewSongsSection({
    super.key,
    required this.future,
    required this.player,
    required this.auth,
    this.fallback = const <Song>[],
  });

  final Future<List<Song>>? future;
  final PlayerController player;
  final AuthController auth;
  final List<Song> fallback;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Song>>(
      future: future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? fallback;
        // 为空时直接收起：刷新等待态由顶部均衡器动画统一表达，
        // 这里不再单独放转圈，避免一次刷新出现两个指示器。
        if (songs.isEmpty) return const SizedBox.shrink();

        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: isDark ? .18 : .12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.fiber_new_rounded, size: 18, color: colorScheme.primary),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '新歌推荐',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.3,
                        ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => player.playSong(songs.first, queue: songs),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final showCount = songs.length > 10 ? 10 : songs.length;
                  // 宽内容区（桌面宽窗 / 平板侧栏形态）：横轨转网格
                  // （项宽 ~120、行高 142），不再横向滚动。
                  if (AdaptiveLayout.isGridWidth(constraints.maxWidth)) {
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      itemCount: showCount,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 120,
                        mainAxisExtent: 142,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        // 正在播放徽标随播放状态实时变化：只重建单张卡片。
                        return AnimatedBuilder(
                          animation: player,
                          builder: (context, _) => _NewSongCard(
                            song: song,
                            onTap: () {
                              if (openPlayerIfSameSong(
                                context,
                                player: player,
                                auth: auth,
                                song: song,
                              )) {
                                return;
                              }
                              player.playSong(song, queue: songs);
                            },
                            isPlaying: player.currentSong?.hash == song.hash &&
                                song.hash.isNotEmpty,
                          ),
                        );
                      },
                    );
                  }
                  // 非桌面 / 窄窗：保持原横轨，仅接入滚轮横滚。
                  return SizedBox(
                    height: 142,
                    child: HorizontalWheelScroll(
                      builder: (context, controller) => ListView.separated(
                        controller: controller,
                        scrollDirection: Axis.horizontal,
                        itemCount: showCount,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return AnimatedBuilder(
                            animation: player,
                            builder: (context, _) => _NewSongCard(
                              song: song,
                              onTap: () {
                                if (openPlayerIfSameSong(
                                  context,
                                  player: player,
                                  auth: auth,
                                  song: song,
                                )) {
                                  return;
                                }
                                player.playSong(song, queue: songs);
                              },
                              isPlaying:
                                  player.currentSong?.hash == song.hash &&
                                      song.hash.isNotEmpty,
                            ),
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
      },
    );
  }
}

class _NewSongCard extends StatelessWidget {
  const _NewSongCard({
    required this.song,
    required this.onTap,
    required this.isPlaying,
  });

  final Song song;
  final VoidCallback onTap;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 108,
        decoration: BoxDecoration(
          color: isPlaying
              ? colorScheme.primary.withValues(alpha: isDark ? .14 : .07)
              : (isDark ? Colors.white.withValues(alpha: .06) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPlaying
                ? colorScheme.primary.withValues(alpha: .30)
                : (isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92)),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: Artwork(url: song.coverUrl, size: 108, borderRadius: 0),
                ),
                if (isPlaying)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: colorScheme.primary.withValues(alpha: .40),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.equalizer_rounded,
                        size: 14,
                        color: colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      color: isPlaying ? colorScheme.primary : colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isPlaying
                          ? colorScheme.primary.withValues(alpha: .75)
                          : colorScheme.onSurfaceVariant,
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

class _RankCard extends StatelessWidget {
  const _RankCard({
    required this.rank,
    required this.onTap,
    required this.onPlay,
    this.playing = false,
  });

  final RankCategory rank;
  final VoidCallback onTap;

  /// 封面右下播钮回调：精准命中才播放，不进详情。
  final VoidCallback onPlay;

  /// 正在为该榜拉歌/起播时，播钮转圈。
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final isCarMode =
        size.width > size.height && ThemeController.instance.carModeEnabled;

    // QQ 式通栏大卡：大封面 + 右侧榜名 + 前 3 首（序号 + 两行歌名/歌手）。
    // 封面取正方形、尺寸与右侧内容等高（榜名 + 3 行 ≈ 133），视觉上左右齐平。
    final cardPadding = isCarMode ? 14.0 : 12.0;
    final hasRows = rank.songs.isNotEmpty || rank.topPreviews.isNotEmpty;
    final artworkSize = hasRows ? (isCarMode ? 136.0 : 132.0) : 84.0;
    final nameFontSize = isCarMode ? 18.0 : 17.0;
    final songTitleFontSize = isCarMode ? 14.0 : 13.5;
    final songArtistFontSize = isCarMode ? 12.5 : 12.0;
    final spacing = isCarMode ? 16.0 : 12.0;
    const maxSongs = 3;

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
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.all(cardPadding),
            child: Row(
              children: [
                // 封面：TOP1 预览歌曲封面（无则回落官方榜单图）+ 右下淡蓝播钮。
                // 播钮是独立 InkWell：精准命中只播不跳页；点卡片其他区域进详情。
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? .20 : .08),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox.square(
                      dimension: artworkSize,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Artwork(
                            url: rank.cardCoverUrl,
                            size: artworkSize,
                            borderRadius: 12,
                            icon: Icons.leaderboard_rounded,
                          ),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: _RankCoverPlayButton(
                              playing: playing,
                              onPlay: onPlay,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(width: spacing),
                // 榜单信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              rank.rankName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: nameFontSize,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 右列：优先可播 songs，其次 songinfo 纯展示预览，最后兜底。
                      ...(() {
                        final rows = rank.songs.isNotEmpty
                            ? rank.songs
                                .take(maxSongs)
                                .map((s) => (title: s.title, artist: s.artist))
                                .toList()
                            : rank.topPreviews
                                .take(maxSongs)
                                .map((s) => (title: s.title, artist: s.artist))
                                .toList();
                        if (rows.isEmpty) {
                          return <Widget>[
                            const SizedBox(height: 6),
                            Text(
                              '查看完整榜单歌曲',
                              style: TextStyle(
                                fontSize: songTitleFontSize,
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: .75),
                              ),
                            ),
                          ];
                        }
                        return <Widget>[
                          const SizedBox(height: 6),
                          ...rows.asMap().entries.map(
                            (entry) {
                              final i = entry.key;
                              final s = entry.value;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        child: Text(
                                          '${i + 1}',
                                          style: TextStyle(
                                            fontSize: songTitleFontSize + 1,
                                            fontWeight: FontWeight.w800,
                                            height: 1.2,
                                            color: colorScheme.onSurface,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              s.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: songTitleFontSize,
                                                height: 1.2,
                                                fontWeight: FontWeight.w700,
                                                color: colorScheme.onSurface,
                                              ),
                                            ),
                                            const SizedBox(height: 1),
                                            Text(
                                              s.artist.isEmpty
                                                  ? '未知艺人'
                                                  : s.artist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: songArtistFontSize,
                                                height: 1.2,
                                                fontWeight: FontWeight.w400,
                                                color: colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: .8),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ];
                      })(),
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

/// 榜单封面右下播钮：与电台卡 `_RadioPlayBadge` 同款语言。
/// 浅色淡蓝实底 + 主色图标，深色主色淡底；常显（移动端无 hover）。
class _RankCoverPlayButton extends StatelessWidget {
  const _RankCoverPlayButton({required this.playing, required this.onPlay});

  final bool playing;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark
          ? colorScheme.primary.withValues(alpha: .30)
          : const Color(0xFFE8F2FF),
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: colorScheme.primary.withValues(alpha: isDark ? .25 : .15),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPlay,
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox.square(
          dimension: 32,
          child: Center(
            child: playing
                ? SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      color: colorScheme.primary,
                    ),
                  )
                : Icon(
                    Icons.play_arrow_rounded,
                    color: isDark ? Colors.white : colorScheme.primary,
                    size: 20,
                  ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 榜单详情（歌曲列表）
// ---------------------------------------------------------------------------

class RankDetailPage extends StatefulWidget {
  const RankDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.rank,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final RankCategory rank;

  @override
  State<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<RankDetailPage> {
  final _scrollController = ScrollController();
  final _songs = <Song>[];
  var _page = 1;
  var _hasMore = true;
  var _isLoadingMore = false;
  var _isLoading = true;
  var _isLoadingAllSongs = false;
  var _allSongsLoaded = false;

  /// 服务端声明的榜单总曲数（total <= 0 视为未知存 null）。
  /// hasMore 判定优先对齐 total：song 列表已按空 hash 过滤，按过滤后
  /// 条数比较会在页内被过滤时提前误判末页。
  int? _serverTotal;
  String? _error;
  String? _focusedSongKey;

  /// 移动端头部展开高度（与 [_buildMobileAppBar] 的 expandedHeight 保持一致）。
  static const _headerExpandedHeightMobile = 220.0;
  var _isHeaderCollapsed = false;

  @override
  void initState() {
    super.initState();
    // 如果榜单自带歌曲预览，先显示
    if (widget.rank.songs.isNotEmpty) {
      _songs.addAll(widget.rank.songs);
    }
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  void _onScroll() {
    _maybeLoadMore();

    // 移动端图片头顶部是深色封面（比如国潮音乐榜的黑底封面）：
    // 展开态顶栏透明 + 白色返回键，收起后切回不透明底色 + 主题色，
    // 与歌手详情页同款机制，避免黑色图标压在黑底上看不见，
    // 也避免列表内容从透明工具栏下方穿透。
    final collapsed = _scrollController.hasClients &&
        _scrollController.offset >=
            _headerExpandedHeightMobile - kToolbarHeight;
    if (collapsed != _isHeaderCollapsed) {
      setState(() => _isHeaderCollapsed = collapsed);
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await widget.api.rankAudio(
        rankId: widget.rank.rankId,
        page: 1,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(result.songs);
        _page = 2;
        _serverTotal = result.total > 0 ? result.total : null;
        _hasMore = _songs.isNotEmpty &&
            (_serverTotal != null
                ? _songs.length < _serverTotal!
                : result.songs.length >= 50);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _maybeLoadMore() {
    // 首屏加载中不触发加载更多，避免并发请求第 1 页导致重复数据
    if (_isLoading) return;
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) return;
    if (_scrollController.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    // 首屏加载中不触发加载更多，避免并发请求第 1 页导致重复数据
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final result = await widget.api.rankAudio(
        rankId: widget.rank.rankId,
        page: _page,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        // 去重：上游对越界页可能重复返回最后一页，避免列表出现重复歌曲。
        final existingKeys = _songs.map(_songKey).toSet();
        var added = 0;
        for (final song in result.songs) {
          final key = _songKey(song);
          if (existingKeys.contains(key)) continue;
          _songs.add(song);
          existingKeys.add(key);
          added++;
        }
        _page++;
        if (result.songs.isEmpty || added == 0) {
          // 空页 / 整页都是重复：认定已到底。
          _hasMore = false;
        } else if (_serverTotal != null) {
          _hasMore = _songs.length < _serverTotal!;
        } else {
          _hasMore = result.songs.length >= 50;
        }
        _isLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _playSong(Song song) {
    if (openPlayerIfSameSong(
      context,
      player: widget.player,
      auth: widget.auth,
      song: song,
    )) {
      return;
    }
    widget.player.playSong(song, queue: List.of(_songs));
    _expandQueueInBackgroundIfNeeded(startedWith: song);
  }

  void _playAll() {
    if (_songs.isNotEmpty) {
      final first = _songs.first;
      widget.player.playSong(first, queue: List.of(_songs));
      _expandQueueInBackgroundIfNeeded(startedWith: first);
    }
  }

  /// 以 MV 播放整个榜单：批量匹配 MV 队列，无 MV 的歌剔除。
  /// 首个 MV 起播即跳转 MV 页，余下匹配后台补队列。
  Future<void> _playAllMv() async {
    if (_songs.isEmpty) return;
    if (MvPlayerController.instance.isResolvingQueue) return;
    Toast.info('正在匹配榜单 MV…');
    await watchMvWithFeedback(
      context: context,
      song: _songs.first,
      songs: List.of(_songs),
      noMvMessage: '榜单里的歌曲暂无 MV',
    );
  }

  /// 后台拉取榜单全部分页，并在仍播放本榜单时扩展播放队列（与歌单详情页同款机制）。
  /// 播放立即以已加载列表开始，不阻塞等待；补全完成后静默替换队列，
  /// 避免"播放全部只含首屏 50 首、播完回到第一首"。
  void _expandQueueInBackgroundIfNeeded({required Song startedWith}) {
    if (_allSongsLoaded || !_hasMore) return;
    final startedKey = startedWith.hash.isNotEmpty ? startedWith.hash : startedWith.id;
    if (startedKey.isEmpty) return;
    // 加载期间用户可能"下一首播放"插入歌曲：记录起点队列长度，完成后
    // 长度有变即放弃替换，避免吞掉用户插入。
    final queueLengthAtStart = widget.player.queue.length;
    unawaited(() async {
      await _loadAllSongs();
      if (!mounted) return;
      if (widget.player.queue.length != queueLengthAtStart) return;
      final current = widget.player.currentSong;
      if (current == null) return;
      final currentKey = current.hash.isNotEmpty ? current.hash : current.id;
      final queueStillOurs = widget.player.queue.any((s) {
        final k = s.hash.isNotEmpty ? s.hash : s.id;
        return k == startedKey;
      });
      // 用户已切到其它来源则不改队列
      if (currentKey != startedKey && !queueStillOurs) return;
      final expanded = List<Song>.of(_songs);
      if (expanded.length <= widget.player.queue.length) return;
      await widget.player.replaceQueue(expanded);
    }());
  }

  Future<void> _loadAllSongs() async {
    if (_isLoadingAllSongs || _allSongsLoaded) return;
    setState(() => _isLoadingAllSongs = true);
    try {
      final allSongs = await widget.api.rankAudioAll(
        rankId: widget.rank.rankId,
      );
      if (!mounted) return;
      setState(() {
        // 增量追加：保留已加载歌曲，仅追加尚未加载的，避免列表滚动位置被重置
        final existingKeys = _songs.map(_songKey).toSet();
        for (final song in allSongs) {
          final key = _songKey(song);
          if (existingKeys.contains(key)) continue;
          _songs.add(song);
          existingKeys.add(key);
        }
        _hasMore = false;
        _allSongsLoaded = true;
        _isLoadingAllSongs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingAllSongs = false);
    }
  }

  String _songKey(Song song) =>
      song.hash.isNotEmpty ? song.hash : song.id;

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => ArtistRef(id: '', name: song.artist),
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
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: widget.auth,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: () => _openArtist(song),
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

  Widget _buildDesktopAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 200,
      surfaceTintColor: Colors.transparent,
      backgroundColor: colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: .08),
      title: AnimatedBuilder(
        animation: _scrollController,
        builder: (context, _) {
          var collapsed = false;
          if (_scrollController.hasClients) {
            final delta = 200.0 - kToolbarHeight;
            collapsed = delta <= 0 || _scrollController.offset > delta - 40;
          }
          return AnimatedOpacity(
            opacity: collapsed ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Text(
              widget.rank.rankName,
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
        background: _buildDesktopHeroHeader(context),
      ),
    );
  }

  Widget _buildDesktopHeroHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final updateFreq = widget.rank.updateFrequency.isNotEmpty
        ? widget.rank.updateFrequency
        : '实时更新';

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
          padding: const EdgeInsets.fromLTRB(24, kToolbarHeight + 4, 24, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? .35 : .18),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Artwork(
                  url: widget.rank.imageUrl,
                  size: 120,
                  borderRadius: 16,
                ),
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.rank.rankName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
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
                        '${_songs.length} 首歌曲 · $updateFreq',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _playAll,
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('播放全部'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: '以 MV 播放全部',
                          onPressed: _playAllMv,
                          icon: const Icon(Icons.music_video_rounded, size: 20),
                        ),
                        if (_isLoading)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
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

  Widget _buildMobileAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = theme.colorScheme.surface;
    return SliverAppBar(
      pinned: true,
      expandedHeight: _headerExpandedHeightMobile,
      surfaceTintColor: Colors.transparent,
      // 展开态透明叠在封面图上（白色返回键）；收起后换不透明底色，
      // 避免歌曲列表从工具栏下方穿透。与歌手详情页移动端同款。
      backgroundColor: _isHeaderCollapsed ? surface : Colors.transparent,
      foregroundColor:
          _isHeaderCollapsed ? theme.colorScheme.onSurface : Colors.white,
      systemOverlayStyle: _isHeaderCollapsed
          ? (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          : SystemUiOverlayStyle.light,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.black.withValues(alpha: .08),
      title: AnimatedOpacity(
        opacity: _isHeaderCollapsed ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Text(
          widget.rank.rankName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.rank.imageUrl != null)
              RetryableNetworkImage(
                url: widget.rank.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            // 顶部深色罩：保证白色返回键在任何封面（黑底/白底）上都有对比度。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [
                    Color.fromRGBO(0, 0, 0, 0.45),
                    Color.fromRGBO(0, 0, 0, 0.0),
                  ],
                  stops: [0, 0.45],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .05),
                    isDark
                        ? const Color(0xFF06070A)
                        : Colors.white,
                  ],
                  stops: const [0.45, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme) {
    final friendly = friendlyServiceErrorMessage(_error ?? '加载失败');
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_off_rounded,
                size: 44,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                '暂时连接不上音乐服务',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
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
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              if (isDesktopFormFactor)
                _buildDesktopAppBar(context)
              else
                _buildMobileAppBar(context),
              if (isDesktopFormFactor) ...[
                if (_error != null && _songs.isEmpty)
                  _buildErrorState(colorScheme)
                else ...[
                  if (_songs.isNotEmpty)
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _RankTableStickyHeaderDelegate(
                        child: Container(
                          color: colorScheme.surface,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: const DesktopSongTableHeader(
                            selecting: false,
                            allSelected: false,
                            onToggleSelectAll: null,
                          ),
                        ),
                      ),
                    ),
                  if (_songs.isEmpty && _isLoading)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
                              onTap: () => setState(
                                () => _focusedSongKey = _songKey(song),
                              ),
                              onDoubleTap: () => _playSong(song),
                              onPlay: () => _playSong(song),
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
                    if (_isLoadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ],
              ] else ...[
                // 播放全部按钮
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: .06)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: .10)
                              : Colors.white.withValues(alpha: .92),
                          width: 1.1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? .18 : .06,
                            ),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(
                                alpha: isDark ? .18 : .12,
                              ),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(
                              Icons.music_note_rounded,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '${_songs.length} 首歌曲',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                          ),
                          const Spacer(),
                          IconButton.filledTonal(
                            tooltip: '以 MV 播放全部',
                            onPressed: _playAllMv,
                            icon: const Icon(Icons.music_video_rounded),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _playAll,
                            icon:
                                const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('播放全部'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                              elevation: 0,
                            ),
                          ),
                          if (_isLoading)
                            const Padding(
                              padding: EdgeInsets.only(left: 12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 歌曲列表
                if (_error != null && _songs.isEmpty)
                  _buildErrorState(colorScheme)
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index >= _songs.length) {
                          return _isLoadingMore
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink();
                        }
                        final song = _songs[index];
                        return _RankSongRow(
                          index: index + 1,
                          song: song,
                          onTap: () => _playSong(song),
                          api: widget.api,
                          auth: widget.auth,
                          player: widget.player,
                          queue: _songs,
                        );
                      },
                      childCount: _songs.length + (_hasMore ? 1 : 0),
                    ),
                  ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 166)),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: MiniPlayerSlot(player: widget.player, auth: widget.auth),
          ),
        ],
      ),
    );
  }
}

/// PC 桌面端表格吸顶代理。
class _RankTableStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  _RankTableStickyHeaderDelegate({required this.child});

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
  bool shouldRebuild(covariant _RankTableStickyHeaderDelegate oldDelegate) =>
      child != oldDelegate.child;
}

// ---------------------------------------------------------------------------
// 排行榜歌曲行
// ---------------------------------------------------------------------------

class _RankSongRow extends StatelessWidget {
  const _RankSongRow({
    required this.index,
    required this.song,
    required this.onTap,
    required this.api,
    required this.auth,
    required this.player,
    required this.queue,
  });

  final int index;
  final Song song;
  final VoidCallback onTap;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final List<Song> queue;

  void _showActions(BuildContext context) {
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
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: auth,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: () {
            final artist = song.artists.firstWhere(
              (a) => a.name.isNotEmpty,
              orElse: () => const ArtistRef(id: '', name: ''),
            );
            if (artist.name.isEmpty) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  api: api,
                  auth: auth,
                  artist: artist,
                  player: player,
                ),
              ),
            );
          },
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isTop3 = index <= 3;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final isPlaying =
            song.hash.isNotEmpty && player.currentSong?.hash == song.hash;
        final isActive = isPlaying;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            decoration: BoxDecoration(
              color: isActive
                  ? colorScheme.primary.withValues(alpha: .08)
                  : (isDark ? Colors.white.withValues(alpha: .06) : Colors.white),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isActive
                    ? colorScheme.primary.withValues(alpha: .18)
                    : (isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92)),
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
                onTap: onTap,
                mouseCursor: SystemMouseCursors.click,
                onLongPress: () => _showActions(context),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(
                    children: [
                      // 排名
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: isTop3
                              ? colorScheme.primary.withValues(alpha: isDark ? .18 : .12)
                              : (isDark ? Colors.white.withValues(alpha: .06) : colorScheme.surfaceContainerHighest.withValues(alpha: .9)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '$index',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: isTop3 ? 14 : 13,
                              fontWeight: isTop3 ? FontWeight.w900 : FontWeight.w700,
                              color: isTop3 ? colorScheme.primary : colorScheme.onSurfaceVariant,
                              fontStyle: isTop3 ? FontStyle.italic : FontStyle.normal,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 封面
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .06),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Artwork(url: song.coverUrl, size: 48, borderRadius: 10),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 歌曲信息
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: isPlaying
                                    ? colorScheme.primary
                                    : colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 3),
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
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 播放中指示 / 更多操作按钮
                      if (isPlaying)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            Icons.equalizer_rounded,
                            size: 20,
                            color: colorScheme.primary,
                          ),
                        )
                      else
                        IconButton(
                          tooltip: '更多',
                          onPressed: () => _showActions(context),
                          icon: Icon(
                            Icons.more_vert_rounded,
                            size: 20,
                            color: colorScheme.onSurfaceVariant.withValues(alpha: .6),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 骨架屏 / 错误 / 空状态
// ---------------------------------------------------------------------------

class _RankSkeleton extends StatelessWidget {
  const _RankSkeleton({this.isCarLandscape = false});

  final bool isCarLandscape;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = BoxDecoration(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(10),
    );

    Widget buildItem() => Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(width: 72, height: 72, decoration: placeholder),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 120, height: 14, decoration: placeholder),
                    const SizedBox(height: 8),
                    Container(
                        width: double.infinity,
                        height: 10,
                        decoration: placeholder),
                    const SizedBox(height: 6),
                    Container(width: 160, height: 10, decoration: placeholder),
                  ],
                ),
              ),
            ],
          ),
        );

    Widget buildGridItem() => Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 88,
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: placeholder,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 90, height: 13, decoration: placeholder),
                    const SizedBox(height: 7),
                    Container(
                        width: double.infinity,
                        height: 10,
                        decoration: placeholder),
                  ],
                ),
              ),
            ],
          ),
        );

    if (isCarLandscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth > 600 ? 2 : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 3.6,
              ),
              itemCount: 8,
              itemBuilder: (context, index) => buildItem(),
            );
          },
        ),
      );
    }

    // 手机版骨架与双列小卡同构。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = constraints.maxWidth > 600 ? 3 : 2;
          const spacing = 12.0;
          const cardHeight = 148.0;
          final cellWidth =
              (constraints.maxWidth - spacing * (count - 1)) / count;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: cellWidth / cardHeight,
            ),
            itemCount: 6,
            itemBuilder: (context, index) => buildGridItem(),
          );
        },
      ),
    );
  }
}

class _RankError extends StatelessWidget {
  const _RankError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 与电台 _ErrorView 统一视觉：不再忽略 message，而是转成友好文案，
    // 避免无网络时只显示干巴巴的“加载失败”或透出原始异常。
    final friendly = friendlyServiceErrorMessage(message);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 44,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '暂时连接不上音乐服务',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
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
      ),
    );
  }
}

class _RankEmpty extends StatelessWidget {
  const _RankEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.leaderboard_rounded,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无榜单数据',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
