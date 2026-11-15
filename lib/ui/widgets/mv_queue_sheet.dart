import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../controllers/mv_player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'marquee_text.dart';
import 'toast.dart';

/// 弹出 MV 播放队列面板（底部弹层）。
///
/// 与歌曲侧 showQueueSheet（queue_sheet.dart）同构：队列数/清空/点行切歌/
/// 单行删除/当前行高亮律动。
Future<void> showMvQueueSheet(
  BuildContext context,
  MvPlayerController mvPlayer,
) {
  return showModalBottomSheet<void>(
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
              AnimatedBuilder(
                animation: mvPlayer,
                builder: (context, _) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Text(
                          'MV 播放队列',
                          style: Theme.of(sheetContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${mvPlayer.queue.length} 个',
                          style:
                              Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                        ),
                        if (mvPlayer.isResolvingQueue) ...[
                          const SizedBox(width: 8),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '正在匹配MV…',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colorScheme.primary),
                          ),
                        ],
                        const Spacer(),
                        TextButton(
                          onPressed: mvPlayer.queue.length > 1
                              ? () => _clearMvQueue(sheetContext, mvPlayer)
                              : null,
                          child: Text(
                            '清空',
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              Flexible(
                child: AnimatedBuilder(
                  animation: mvPlayer,
                  builder: (context, _) {
                    if (mvPlayer.queue.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            'MV 播放队列为空',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: mvPlayer.queue.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final mv = mvPlayer.queue[index];
                        final active = MvInfo.isSameMv(mvPlayer.currentMv, mv);
                        return MvQueueTile(
                          mv: mv,
                          index: index + 1,
                          active: active,
                          isPlaying: active && mvPlayer.isPlaying,
                          onTap: () {
                            // 点当前 MV 只关面板不重播（对齐歌曲侧口径）。
                            if (active) {
                              Navigator.of(sheetContext).pop();
                              return;
                            }
                            Navigator.of(sheetContext).pop();
                            unawaited(mvPlayer.playMv(mv, queue: mvPlayer.queue));
                          },
                          onDelete: mvPlayer.queue.length > 1
                              ? () => _removeFromMvQueue(sheetContext, mvPlayer, index)
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void _removeFromMvQueue(
  BuildContext sheetContext,
  MvPlayerController mvPlayer,
  int index,
) {
  final removed = mvPlayer.queue[index];
  final removingCurrent = MvInfo.isSameMv(mvPlayer.currentMv, removed);
  if (removingCurrent) {
    Navigator.of(sheetContext).pop();
  }
  unawaited(mvPlayer.removeFromQueueAt(index));
}

void _clearMvQueue(BuildContext sheetContext, MvPlayerController mvPlayer) {
  Navigator.of(sheetContext).pop();
  mvPlayer.clearQueue();
  Toast.success('已清空 MV 队列');
}

class MvQueueTile extends StatelessWidget {
  const MvQueueTile({
    super.key,
    required this.mv,
    required this.index,
    required this.active,
    required this.isPlaying,
    required this.onTap,
    this.onDelete,
  });

  final MvInfo mv;
  final int index;
  final bool active;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? colorScheme.primary.withValues(alpha: .09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: active
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 64,
              height: 36,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Artwork(
                  url: mv.coverUrl,
                  size: double.infinity,
                  borderRadius: 0,
                  icon: Icons.music_video_rounded,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText.text(
                    mv.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: active ? colorScheme.primary : null,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mv.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: active
                              ? colorScheme.primary.withValues(alpha: .72)
                              : colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (mv.duration != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  formatDuration(mv.duration),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            if (active)
              Icon(
                isPlaying ? Icons.equalizer_rounded : Icons.pause_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                tooltip: '从队列移除',
                color: colorScheme.onSurfaceVariant,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
