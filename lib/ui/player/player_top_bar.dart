import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/player_logic.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../pages/android_lyric_settings_page.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'lyric_offset_sheet.dart';
import 'player_controls.dart';
import 'song_info_sheet.dart';

class PlayerPageIndicator extends StatelessWidget {
  const PlayerPageIndicator({
    super.key,
    required this.currentPage,
    this.onPageSelected,
  });

  final int currentPage;
  final ValueChanged<int>? onPageSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [_buildDot(0), const SizedBox(width: 4), _buildDot(1)],
    );
  }

  Widget _buildDot(int pageIndex) {
    final active = currentPage == pageIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onPageSelected?.call(pageIndex),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: active ? 14.0 : 4.0,
          height: 3.5,
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2.0),
          ),
        ),
      ),
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onArtistTap,
    this.currentPage,
    this.onPageSelected,
    this.onVerticalDragDown,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final ValueChanged<Song> onArtistTap;
  final int? currentPage;
  final ValueChanged<int>? onPageSelected;
  final GestureDragDownCallback? onVerticalDragDown;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  final GestureDragCancelCallback? onVerticalDragCancel;

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (currentPage != null) {
      content = Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              color: Colors.white,
              onPressed: onClose,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            Expanded(
              child: Center(
                child: PlayerPageIndicator(
                  currentPage: currentPage!,
                  onPageSelected: onPageSelected,
                ),
              ),
            ),
            Builder(
              builder: (moreButtonContext) => IconButton(
                tooltip: '更多',
                color: Colors.white,
                onPressed: () => _showMoreSheet(moreButtonContext),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ),
          ],
        ),
      );
    } else {
      content = AnimatedBuilder(
        animation: auth,
        builder: (context, _) {
          final liked = auth.isLiked(song);
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  color: Colors.white,
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MarqueeText.text(
                        song.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: .82),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: liked ? '取消喜欢' : '喜欢',
                  color: Colors.white,
                  onPressed: song.source == SongSource.kugou
                      ? () => toggleLikeWithFeedback(auth, song)
                      : null,
                  icon: Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                PlayerAudioQualityPill(player: player),
                const SizedBox(width: 8),
                Builder(
                  builder: (moreButtonContext) => IconButton(
                    tooltip: '更多',
                    color: Colors.white,
                    onPressed: () => _showMoreSheet(moreButtonContext),
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragDown: onVerticalDragDown,
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      onVerticalDragCancel: onVerticalDragCancel,
      child: content,
    );
  }

  void _showMoreSheet(BuildContext context) {
    showPlayerMoreSheet(
      context: context,
      player: player,
      auth: auth,
      song: song,
      anchor: anchorBelow(context),
    );
  }
}

void showPlayerMoreSheet({
  required BuildContext context,
  required PlayerController player,
  required AuthController auth,
  required Song song,
  Offset? anchor,
}) {
  showSongActionSheet(
    context: context,
    song: song,
    anchor: anchor,
    actions: [
      // 宫格固定 4 位（按顺序取前 4 个 isGrid）：添加到歌单常驻第一位，
      // 后面跟倍速/音质/歌曲信息；其余一律平铺，不标 isGrid。
      // 高潮/音效不在顶部占位：高潮低频、音效播放页就能调。
      if (song.source == SongSource.kugou)
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          isGrid: true,
          onTap: () =>
              showAddToPlaylistSheet(context: context, auth: auth, song: song),
        ),
      SongSheetAction(
        icon: Icons.speed_rounded,
        title: '倍速',
        subtitle: player.playbackSpeedLabel,
        isGrid: true,
        onTap: () => showPlaybackSpeedSheet(context: context, player: player),
      ),
      SongSheetAction(
        icon: Icons.high_quality_rounded,
        title: '音质',
        subtitle: player.audioQuality.badge,
        isGrid: true,
        onTap: () => showAudioQualityPicker(context, player),
      ),
      SongSheetAction(
        icon: Icons.info_outline_rounded,
        title: '歌曲信息',
        isGrid: true,
        onTap: () => showSongInfoSheet(
          context: context,
          player: player,
          auth: auth,
          song: song,
        ),
      ),
      // List actions
      // 观看 MV：把当前歌曲（连同播放队列）切成 MV 播放（歌曲 ⇄ MV 互切）。
      if (song.source == SongSource.kugou)
        SongSheetAction(
          icon: Icons.music_video_rounded,
          title: '观看 MV',
          subtitle: '切换为视频播放',
          onTap: () => watchMvWithFeedback(
            context: context,
            song: song,
            songs: player.queue,
          ),
        ),
      SongSheetAction(
        icon: Icons.auto_awesome_rounded,
        title: '高潮',
        onTap: () async {
          final ok = await player.playClimaxPreview();
          if (!ok) Toast.error('暂无高潮片段');
        },
      ),
      if (player.isAudioEffectsSupported)
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          onTap: () => showAudioEffectsSheet(context: context, player: player),
        ),
      // 定时是低频操作：下沉到平铺列表，不占宫格位。
      SongSheetAction(
        icon: Icons.bedtime_rounded,
        title: '定时',
        onTap: () => showSleepTimerSheet(context: context, player: player),
      ),
      // 歌词进度：第三方曲库的歌词偶有整体偏差，属"低频修正"操作，
      // 放详情弹层的平铺列表里。
      // 图标用秒表（时间校准的具象 pictogram，替代原来抽象的循环箭头）；
      // 副标题用短读数（`0 秒` / `+0.5 秒`，与倍速「1x」、音质「320K」
      // 同一量级）；调过的歌点亮入口（active）。
      SongSheetAction(
        icon: Icons.timer_rounded,
        title: '歌词进度',
        subtitle: PlayerLyricOffsetLogic.formatSigned(player.lyricOffset),
        active: player.hasLyricOffset,
        onTap: () {
          // 注意：不要在这里 pop —— 详情弹层的关闭由 _GridItem /
          // _SongActionTile / 桌面级联菜单统一负责，这里再 pop 会把
          // 底下的播放页也一起退出（移动端开歌词进度就闪退即此因）。
          if (!context.mounted) return;
          if (isDesktopFormFactor) {
            // PC：在同一个锚点弹出锚定面板，与封面 `调` 按钮/歌词右键一致。
            unawaited(
              showLyricOffsetMenu(
                context,
                player: player,
                anchor: anchor ?? anchorBelow(context),
              ),
            );
          } else {
            unawaited(
              showLyricOffsetSheet(context, player: player, song: song),
            );
          }
        },
      ),

      if (player.isDesktopLyricsSupported) ...[
        SongSheetAction(
          icon: player.desktopLyricsEnabled
              ? Icons.lyrics_rounded
              : Icons.lyrics_outlined,
          title: '桌面歌词',
          onTap: () async {
            // 同上：菜单壳已负责关闭，这里不再手动 pop，避免连带退出播放页。
            await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
          },
        ),
        if (player.desktopLyricsEnabled)
          SongSheetAction(
            icon: Icons.tune_rounded,
            title: '歌词设置',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                // PC 用原设置页；Android（易格方案）用移动端设置页。
                builder: (_) => isDesktopFormFactor
                    ? DesktopLyricsSettingsPage(player: player)
                    : AndroidLyricSettingsPage(player: player),
              ),
            ),
          ),
      ],
    ],
  );
}
