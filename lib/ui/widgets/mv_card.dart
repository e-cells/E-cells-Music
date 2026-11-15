import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import 'artwork.dart';

/// MV 封面卡（16:9 封面 + 时长角标 + 标题/歌手）。
///
/// 搜索 MV 结果、首页「MV 精选」、收藏 MV 网格共用。
class MvCard extends StatelessWidget {
  const MvCard({
    super.key,
    required this.mv,
    required this.onTap,
    this.width,
    this.active = false,
  });

  final MvInfo mv;

  /// 卡片宽度；null 时自适应父容器（网格场景）。
  final double? width;

  final VoidCallback onTap;

  /// 是否为正在播放的 MV（高亮边框 + 播放中角标）。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themeData = Theme.of(context);

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: active
                          ? Border.all(color: colorScheme.primary, width: 2)
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Artwork(
                        url: mv.coverUrl,
                        // size 无穷 → 内部 SizedBox.expand 撑满 16:9 容器。
                        size: double.infinity,
                        borderRadius: 0,
                        icon: Icons.music_video_rounded,
                      ),
                    ),
                  ),
                  // 时长角标
                  if (mv.duration != null && mv.duration!.inSeconds > 0)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          formatDuration(mv.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  // 播放中角标
                  if (active)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 12,
                            ),
                            Text(
                              '播放中',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              mv.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: themeData.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: active ? colorScheme.primary : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              mv.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: themeData.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
