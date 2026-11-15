import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/app_song_row.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/desktop_song_table_row.dart';
import '../widgets/song_action_sheets.dart';

/// 搜索结果（歌曲）列表。
///
/// 桌面端：复用 [DesktopSongTableRow] 表格（歌曲/歌手/专辑/时长），
/// 单击选中占位、双击播放、右键 anchored 操作菜单（对齐 PC 惯例）；
/// 移动端/车机端：保持原有卡片行（单击即播）逐字节不变。
class SearchSongResults extends StatelessWidget {
  const SearchSongResults({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
  });

  final List<Song> songs;
  final void Function(Song song) onPlay;
  final bool Function(Song song) isLiked;
  final void Function(Song song) onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final void Function(Song song) onViewArtist;

  @override
  Widget build(BuildContext context) {
    if (isDesktopFormFactor) {
      return _buildDesktopTable(context);
    }

    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 160),
          itemCount: songs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 2),
          itemBuilder: (context, index) {
            final song = songs[index];
            final liked = isLiked(song);
            // 其他平台歌曲（如网易云）仅支持播放，不支持收藏等操作
            final isExternal = song.source != SongSource.kugou;
            // 行视觉与歌单/歌手页统一见 AppSongRow；这里只组装
            // 红心、外部来源标与更多菜单（播中态/律动标由组件内管）。
            return AppSongRow(
              song: song,
              player: player,
              onTap: () => onPlay(song),
              trailing: [
                if (!isExternal) ...[
                  IconButton(
                    onPressed: () => onLikeTap(song),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked
                          ? Colors.redAccent
                          : colorScheme.outline,
                      size: 22,
                    ),
                  ),
                  Builder(
                    builder: (moreButtonContext) {
                      return AppSongRowMenuButton(
                        onPressed: () => _showSongMenu(
                          moreButtonContext,
                          song,
                          anchor: anchorBelow(moreButtonContext),
                        ),
                      );
                    },
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: .5,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        song.source == SongSource.netease ? '网易云' : '外部',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// 歌曲操作菜单：桌面端右键 / `...` 按钮共用；[anchor] 为空时由
  /// showSongActionSheet 自行定位。外部平台歌曲仅保留播放类操作。
  void _showSongMenu(BuildContext context, Song song, {Offset? anchor}) {
    final isExternal = song.source != SongSource.kugou;
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
            player: player,
            song: song,
          ),
        ),
        if (!isExternal)
          SongSheetAction(
            icon: Icons.music_video_rounded,
            title: '观看 MV',
            onTap: () => watchMvWithFeedback(
              context: context,
              song: song,
              songs: songs,
            ),
          ),
        if (!isExternal) ...[
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
            onTap: () => onViewArtist(song),
          ),
          if (player.downloadController != null)
            SongSheetAction(
              icon: player.downloadController!.isDownloaded(song)
                  ? Icons.download_done_rounded
                  : Icons.download_rounded,
              title: player.downloadController!.isDownloaded(song)
                  ? '已下载'
                  : '下载',
              onTap: () => player.downloadController!.download(
                song,
                player.audioQuality,
              ),
            ),
        ],
      ],
    );
  }

  /// 桌面端表格：粘性表头（36px）+ 固定行高 44px 数据行，
  /// 几何契约与排行/歌手页完全一致。
  Widget _buildDesktopTable(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: DesktopSongTableStickyHeaderDelegate(
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
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          sliver: SliverFixedExtentList(
            itemExtent: DesktopSongTableRow.rowHeight,
            delegate: SliverChildBuilderDelegate((context, index) {
              final song = songs[index];
              final isExternal = song.source != SongSource.kugou;
              return DesktopSongTableRow(
                song: song,
                index: index + 1,
                player: player,
                auth: auth,
                canDelete: false,
                selecting: false,
                selected: false,
                isFocused: false,
                showHoverActions: !isExternal,
                onTap: () {},
                onDoubleTap: () => onPlay(song),
                onPlay: () => onPlay(song),
                onAddToPlaylist: () => showAddToPlaylistSheet(
                  context: context,
                  auth: auth,
                  song: song,
                ),
                onDelete: () {},
                onViewArtist: () => onViewArtist(song),
                onMore: () => _showSongMenu(context, song),
                onSecondaryMore: (position) =>
                    _showSongMenu(context, song, anchor: position),
              );
            }, childCount: songs.length),
          ),
        ),
      ],
    );
  }
}
