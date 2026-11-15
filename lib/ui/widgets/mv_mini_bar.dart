import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../controllers/mv_player_controller.dart';
import '../pages/mv_player_page.dart';
import 'artwork.dart';

/// 全局 MV 悬浮视频小窗宿主：包住 MaterialApp 的 navigator。
///
/// 参考酷狗音乐的 MV 小窗播放逻辑：
/// 当用户从 [MvPlayerPage] 返回浏览其它页面且 MV 会话仍在活跃状态时，
/// 在屏幕右下角（底栏上方）悬浮展示 16:9 实时视频小窗，支持拖拽移动、
/// 播放/暂停、关闭，点击小窗即可无缝回到全屏 MV 播放页面。
class MvPlayerOverlayHost extends StatefulWidget {
  const MvPlayerOverlayHost({
    super.key,
    required this.mvPlayer,
    required this.child,
  });

  final MvPlayerController mvPlayer;

  /// MaterialApp builder 传入的 navigator。
  final Widget child;

  @override
  State<MvPlayerOverlayHost> createState() => _MvPlayerOverlayHostState();
}

class _MvPlayerOverlayHostState extends State<MvPlayerOverlayHost> {
  static const double _windowWidth = 204;
  static const double _windowHeight = 115;

  /// 相对右下角默认位置的拖拽偏移量。
  Offset _dragOffset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = MediaQuery.paddingOf(context);
        final defaultRight = 16.0;
        // 默认停靠在底部导航栏/MiniPlayer 上方，避免遮挡底栏操作。
        final defaultBottom = (padding.bottom > 0 ? padding.bottom : 12.0) + 84.0;
        final maxLeft =
            (constraints.maxWidth - _windowWidth - 8).clamp(8.0, double.infinity);
        final maxTop = (constraints.maxHeight - _windowHeight - 8).clamp(
          padding.top + 8.0,
          double.infinity,
        );
        final baseLeft = constraints.maxWidth - defaultRight - _windowWidth;
        final baseTop = constraints.maxHeight - defaultBottom - _windowHeight;
        final left = (baseLeft + _dragOffset.dx).clamp(8.0, maxLeft);
        final top = (baseTop + _dragOffset.dy).clamp(padding.top + 8.0, maxTop);

        return Stack(
          textDirection: TextDirection.ltr,
          children: [
            Positioned.fill(child: widget.child),
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    final nextLeft =
                        (baseLeft + _dragOffset.dx + details.delta.dx)
                            .clamp(8.0, maxLeft);
                    final nextTop =
                        (baseTop + _dragOffset.dy + details.delta.dy)
                            .clamp(padding.top + 8.0, maxTop);
                    _dragOffset = Offset(
                      nextLeft - baseLeft,
                      nextTop - baseTop,
                    );
                  });
                },
                child: MvMiniBar(mvPlayer: widget.mvPlayer),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// MV 16:9 悬浮视频小窗（MV 未处于活跃会话或播放页在前台时占位为零）。
class MvMiniBar extends StatelessWidget {
  const MvMiniBar({super.key, required this.mvPlayer});

  final MvPlayerController mvPlayer;

  static const double _width = 204;
  static const double _height = 115;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: mvPlayer,
      builder: (context, _) {
        final mv = mvPlayer.currentMv;
        // 仅在本次运行已发起过 MV 播放会话且播放页不在前台时显示小窗。
        if (mv == null ||
            !mvPlayer.hasActiveSession ||
            mvPlayer.isPlayerPageVisible) {
          return const SizedBox.shrink();
        }
        final colorScheme = Theme.of(context).colorScheme;
        final controller = mvPlayer.videoController;
        final hasVideo =
            controller != null && controller.value.isInitialized;

        return Material(
          color: Colors.transparent,
          elevation: 10,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: _width,
            height: _height,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: .22),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(
                  MvPlayerPage.open(context, mvPlayer: mvPlayer),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 1. 实时视频画面（未就绪时显示 MV 封面兜底）
                    if (hasVideo)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.size.width,
                          height: controller.value.size.height,
                          child: VideoPlayer(controller),
                        ),
                      )
                    else
                      Artwork(
                        url: mv.coverUrl,
                        size: _width,
                        borderRadius: 0,
                        icon: Icons.music_video_rounded,
                      ),

                    // 2. 上下轻渐变暗角，保证标题与按钮清晰可读
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x99000000),
                            Color(0x11000000),
                            Color(0xAA000000),
                          ],
                          stops: [0.0, 0.48, 1.0],
                        ),
                      ),
                    ),

                    // 3. 顶部：左侧「MV · 标题」+ 右上角关闭按钮
                    Positioned(
                      top: 4,
                      left: 8,
                      right: 4,
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'MV',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              mv.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => unawaited(mvPlayer.stop()),
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .45),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 4. 底部：点击返回全屏提示 + 右下角播放/暂停按钮
                    Positioned(
                      left: 8,
                      right: 6,
                      bottom: 7,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.open_in_full_rounded,
                            color: Colors.white70,
                            size: 13,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              mv.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: mvPlayer.isPreparing
                                ? null
                                : () => unawaited(mvPlayer.togglePlay()),
                            child: Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .52),
                                shape: BoxShape.circle,
                              ),
                              child: mvPlayer.isPreparing
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      mvPlayer.isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 5. 贴底实时进度条
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ValueListenableBuilder<Duration>(
                        valueListenable: mvPlayer.positionListenable,
                        builder: (context, pos, _) {
                          final totalMs = mvPlayer.duration.inMilliseconds;
                          final progress = totalMs <= 0
                              ? 0.0
                              : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
                          return LinearProgressIndicator(
                            value: progress,
                            minHeight: 2.5,
                            color: colorScheme.primary,
                            backgroundColor: Colors.white24,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
