import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/artwork.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/marquee_text.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'lyric_views.dart';
import 'player_comment_button.dart';
import 'player_controls.dart';

class PosterPlayerPage extends StatefulWidget {
  const PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
    required this.auth,
    required this.onArtistTap,
    this.isPageVisible = true,
    this.onLyricTap,
    this.onCoverTap,
    this.onVerticalDragDown,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;
  final AuthController auth;
  final ValueChanged<Song> onArtistTap;

  /// 本页是否可见（播放页 PageView 的当前页）。划到歌词页后本页被
  /// `AutomaticKeepAliveClientMixin` 留在树上，不门控的话海报歌词预览
  /// 仍会以 ~30Hz setState 空转。
  final bool isPageVisible;
  final VoidCallback? onLyricTap;
  final VoidCallback? onCoverTap;
  final GestureDragDownCallback? onVerticalDragDown;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  final GestureDragCancelCallback? onVerticalDragCancel;

  @override
  State<PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<PosterPlayerPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragDown: widget.onVerticalDragDown,
      onVerticalDragStart: widget.onVerticalDragStart,
      onVerticalDragUpdate: widget.onVerticalDragUpdate,
      onVerticalDragEnd: widget.onVerticalDragEnd,
      onVerticalDragCancel: widget.onVerticalDragCancel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 650;
          // 矮横屏（手机开横屏模式、矮高平板）：固定块（歌名/歌词预览/
          // 操作栏/进度/控制按钮）合计约 340dp，Spacer 已无弹性可收，
          // 控制按钮会被整段挤出屏幕（对齐上游 PR#111 的问题）。
          // short 档封面改 Expanded+FittedBox 弹性缩放吸收高度缺口；
          // tiny 档再隐藏歌词预览与操作栏，优先保证歌名与控制按钮完整。
          final short = constraints.maxHeight < 560;
          final tiny = constraints.maxHeight < 400;
          final horizontalPadding = compact ? 20.0 : 28.0;

          final maxArtworkHeight =
              (constraints.maxHeight * (compact ? 0.34 : 0.42)).clamp(
                130.0,
                330.0,
              );
          final artworkMaxWidth = math.min(
            constraints.maxWidth - horizontalPadding * 2,
            maxArtworkHeight,
          );

          final cover = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onCoverTap?.call();
            },
            child: Hero(
              tag: 'player_cover',
              child: Artwork(
                url: widget.song.coverUrl,
                size: double.infinity,
                borderRadius: 8,
                // 播放页海报大图：任何形态都保持 2x/600 解码档。
                highRes: true,
              ),
            ),
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              compact ? 4 : 8,
              horizontalPadding,
              compact ? 10 : 16,
            ),
            child: Column(
              children: [
                if (!short) const Spacer(),
                if (short)
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: SizedBox.square(
                          dimension: artworkMaxWidth,
                          child: cover,
                        ),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: artworkMaxWidth),
                    child: AspectRatio(aspectRatio: 1, child: cover),
                  ),
                SizedBox(height: compact ? 12 : 20),
                PosterSongInfoRow(
                  song: widget.song,
                  player: widget.player,
                  auth: widget.auth,
                  onArtistTap: widget.onArtistTap,
                ),
                if (!tiny) ...[
                  SizedBox(height: compact ? 8 : 14),
                  PosterLyricPreview(
                    player: widget.player,
                    onLyricTap: widget.onLyricTap,
                    compact: compact,
                    isPageVisible: widget.isPageVisible,
                  ),
                  SizedBox(height: compact ? 8 : 12),
                  PosterActionRail(
                    player: widget.player,
                    song: widget.song,
                    auth: widget.auth,
                  ),
                ],
                if (!short) const Spacer(),
                Progress(player: widget.player, bright: true),
                SizedBox(height: compact ? 6 : 10),
                Controls(
                  player: widget.player,
                  bright: true,
                  onQueue: widget.onQueue,
                  compactOverride: short,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PosterSongInfoRow extends StatelessWidget {
  const PosterSongInfoRow({
    super.key,
    required this.song,
    required this.player,
    required this.auth,
    required this.onArtistTap,
  });

  final Song song;
  final PlayerController player;
  final AuthController auth;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MarqueeText.text(
                song.title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onArtistTap(song),
                      child: Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PlayerAudioQualityPill(player: player, compact: true),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ListenableBuilder(
          listenable: auth,
          builder: (context, _) {
            final liked = auth.isLiked(song);
            // 与顶栏/车机面板统一：仅酷狗源可喜欢，非酷狗禁用
            // （喜欢走歌单 fileId 体系，非酷狗无稳定映射）
            final likeEnabled = song.source == SongSource.kugou;
            return SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 26,
                tooltip: liked ? '取消喜欢' : '喜欢',
                onPressed: likeEnabled
                    ? () => toggleLikeWithFeedback(auth, song)
                    : null,
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: liked
                      ? Colors.redAccent
                      : Colors.white.withValues(alpha: likeEnabled ? .7 : .3),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class PosterActionRail extends StatelessWidget {
  const PosterActionRail({
    super.key,
    required this.player,
    required this.song,
    required this.auth,
  });

  final PlayerController player;
  final Song song;
  final AuthController auth;

  Widget _buildDownloadButton(BuildContext context) {
    DownloadController? downloadCtrl;
    try {
      downloadCtrl = player.downloadController;
    } catch (_) {
      downloadCtrl = null;
    }

    if (downloadCtrl != null) {
      final ctrl = downloadCtrl;
      return ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final downloaded = ctrl.isDownloaded(song);
          return IconButton(
            iconSize: 24,
            tooltip: downloaded ? '已下载' : '下载',
            icon: Icon(
              downloaded ? Icons.download_done_rounded : Icons.download_rounded,
            ),
            color: downloaded
                ? Theme.of(context).colorScheme.primary
                : Colors.white.withValues(alpha: .85),
            onPressed: () {
              if (downloaded) {
                Toast.info('歌曲已下载');
              } else {
                ctrl.download(song, player.audioQuality);
                Toast.success('已加入下载队列');
              }
            },
          );
        },
      );
    }

    return IconButton(
      iconSize: 24,
      tooltip: '下载',
      icon: const Icon(Icons.download_rounded),
      color: Colors.white.withValues(alpha: .85),
      onPressed: () {
        Toast.info('下载功能未就绪');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        // 1. 收藏到歌单
        IconButton(
          iconSize: 24,
          tooltip: '添加到歌单',
          icon: const Icon(Icons.playlist_add_rounded),
          color: Colors.white.withValues(alpha: .85),
          onPressed: () =>
              showAddToPlaylistSheet(context: context, auth: auth, song: song),
        ),

        // 2. 音效 / 定时
        AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            final hasAudioEffects = player.isAudioEffectsSupported;
            return IconButton(
              iconSize: 24,
              tooltip: hasAudioEffects ? '音效' : '定时播放',
              icon: Icon(
                hasAudioEffects
                    ? Icons.graphic_eq_rounded
                    : Icons.bedtime_rounded,
              ),
              color: Colors.white.withValues(alpha: .85),
              onPressed: () {
                if (hasAudioEffects) {
                  showAudioEffectsSheet(context: context, player: player);
                } else {
                  showSleepTimerSheet(context: context, player: player);
                }
              },
            );
          },
        ),

        // 3. 下载
        _buildDownloadButton(context),

        // 4. 观看 MV（歌曲 ⇄ MV 互切；反查走酷狗 id 体系，非酷狗源禁用）
        _MvSwitchButton(player: player, song: song),

        // 5. 评论
        PlayerCommentButton(
          player: player,
          song: song,
          iconSize: 22,
          iconColor: Colors.white.withValues(alpha: .85),
        ),
      ],
    );
  }
}

/// 「观看 MV」按钮：把当前歌曲（连同播放队列）切成 MV 播放。
///
/// 匹配期间按钮转菊花，防止重复触发「正在匹配 MV」任务。
class _MvSwitchButton extends StatefulWidget {
  const _MvSwitchButton({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  State<_MvSwitchButton> createState() => _MvSwitchButtonState();
}

class _MvSwitchButtonState extends State<_MvSwitchButton> {
  bool _switching = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.song.source == SongSource.kugou;
    return IconButton(
      iconSize: 24,
      tooltip: '观看 MV',
      icon: _switching
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.music_video_rounded),
      color: enabled
          ? Colors.white.withValues(alpha: .85)
          : Colors.white.withValues(alpha: .3),
      onPressed: enabled && !_switching
          ? () async {
              setState(() => _switching = true);
              try {
                await watchMvWithFeedback(
                  context: context,
                  song: widget.song,
                  songs: widget.player.queue,
                );
              } finally {
                if (mounted) setState(() => _switching = false);
              }
            }
          : null,
    );
  }
}

int activeLyricIndexFor(List<LyricLine> lyrics, Duration position) {
  if (lyrics.isEmpty) return -1;
  var index = 0;
  for (var i = 0; i < lyrics.length; i++) {
    if (position >= lyrics[i].time) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

class PosterLyricPreview extends StatefulWidget {
  const PosterLyricPreview({
    super.key,
    required this.player,
    this.onLyricTap,
    this.compact = false,
    this.isPageVisible = true,
  });

  final PlayerController player;
  final VoidCallback? onLyricTap;
  final bool compact;

  /// 本页是否可见。不可见时停掉 ticker：本组件由海报页持有，而海报页
  /// 在划到歌词页后仍被 keep-alive 缓存，否则会持续 ~30Hz setState。
  /// （移动端歌词列表对同一问题已有门控，见 MobileLyricList._syncTicker。）
  final bool isPageVisible;

  @override
  State<PosterLyricPreview> createState() => _PosterLyricPreviewState();
}

class _PosterLyricPreviewState extends State<PosterLyricPreview> {
  late final Ticker _ticker;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _position = widget.player.lyricPosition;
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant PosterLyricPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.player.isScrubbing) {
      _position = widget.player.lyricPosition;
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _syncTicker() {
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isPlaying &&
        widget.player.lyrics.isNotEmpty &&
        !widget.player.isScrubbing;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // 歌词高亮按字推进，~30Hz 刷新视觉足够；无阈值逐帧 setState 会把
    // 预览子树在高刷屏上推到 165Hz 重建（对齐 mobile_lyric_list 的做法）。
    final next = widget.player.lyricPosition;
    if ((next - _position).abs() < const Duration(milliseconds: 20)) {
      return;
    }
    setState(() => _position = next);
  }

  @override
  Widget build(BuildContext context) {
    final previewHeight = widget.compact ? 56.0 : 72.0;
    final lyrics = widget.player.lyrics;

    if (lyrics.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onLyricTap,
        child: SizedBox(
          height: previewHeight,
          child: Center(
            child: Text(
              widget.player.isPreparing ? '歌词加载中...' : '暂无歌词',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white.withValues(alpha: .78),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    final index = activeLyricIndexFor(lyrics, _position);
    final current = lyrics[index];
    final next = index + 1 < lyrics.length ? lyrics[index + 1] : null;
    final currentStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: Colors.white,
      fontSize: widget.compact ? 18 : 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white.withValues(alpha: .46),
      fontSize: widget.compact ? 13 : 15,
      height: 1.18,
      fontWeight: FontWeight.w700,
    );

    // 歌词预览每帧更新位置，仅桌面 Windows 排除语义树（AXTree 竞态）
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onLyricTap,
      child: ExcludeSemantics(
        excluding: isDesktopPlatform,
        child: SizedBox(
          height: previewHeight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: Column(
              key: ValueKey(current.time.inMilliseconds),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: widget.compact ? 28 : 34,
                  child: MarqueeSingleLine(
                    textKey: current.time.inMilliseconds,
                    child: LyricText(
                      line: current,
                      active: true,
                      position: _position,
                      styleOverride: currentStyle,
                      textAlign: TextAlign.center,
                      singleLine: true,
                    ),
                  ),
                ),
                SizedBox(height: widget.compact ? 4 : 6),
                SizedBox(
                  height: widget.compact ? 20 : 24,
                  child: MarqueeSingleLine(
                    textKey:
                        current.translation != null &&
                            current.translation!.isNotEmpty
                        ? current.time.inMilliseconds
                        : (next?.time.inMilliseconds ?? -1),
                    child: Text(
                      current.translation != null &&
                              current.translation!.isNotEmpty
                          ? current.translation!
                          : (next?.text ?? ''),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: nextStyle,
                    ),
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

class MarqueeSingleLine extends StatefulWidget {
  const MarqueeSingleLine({
    super.key,
    required this.child,
    required this.textKey,
  });

  final Widget child;
  final Object textKey;

  @override
  State<MarqueeSingleLine> createState() => _MarqueeSingleLineState();
}

class _MarqueeSingleLineState extends State<MarqueeSingleLine>
    with SingleTickerProviderStateMixin {
  final _viewportKey = GlobalKey();
  final _contentKey = GlobalKey();
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant MarqueeSingleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textKey != widget.textKey) {
      _controller
        ..stop()
        ..reset();
      _overflow = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) {
      return;
    }
    final viewport = _viewportKey.currentContext?.size?.width ?? 0;
    final content = _contentKey.currentContext?.size?.width ?? 0;
    final overflow = math.max(0.0, content - viewport);
    if ((overflow - _overflow).abs() < 1) {
      return;
    }
    setState(() => _overflow = overflow);
    if (overflow > 0) {
      _controller
        ..duration = Duration(milliseconds: (overflow * 42).round() + 2600)
        ..repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          key: _viewportKey,
          child: SizedBox(
            width: constraints.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final offset = _overflow <= 0
                    ? 0.0
                    : -_overflow * _controller.value;
                return Align(
                  alignment: _overflow <= 0
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                );
              },
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(key: _contentKey, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}
