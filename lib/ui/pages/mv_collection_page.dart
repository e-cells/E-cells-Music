import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../controllers/mv_player_controller.dart';
import '../../models/music_models.dart';
import '../widgets/mv_card.dart';
import '../widgets/toast.dart';
import 'mv_player_page.dart';

/// 收藏的 MV 页（本地收藏）。
///
/// 网格展示 + 播放全部 + 长按取消收藏；点卡片以整页收藏为队列播放。
class MvCollectionPage extends StatelessWidget {
  const MvCollectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final mvPlayer = MvPlayerController.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('收藏的 MV')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: mvPlayer,
          builder: (context, _) {
            final mvs = mvPlayer.collectedMvs;
            if (mvs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.music_video_rounded,
                      size: 56,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '还没有收藏的 MV',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '在 MV 播放页点红心即可收藏',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '共 ${mvs.length} 个 MV',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _playAll(context, mvPlayer),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('播放全部'),
                        style: TextButton.styleFrom(
                          foregroundColor:
                              Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 260,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 12,
                      childAspectRatio: 16 / 11.6,
                    ),
                    itemCount: mvs.length,
                    itemBuilder: (context, index) {
                      final mv = mvs[index];
                      return GestureDetector(
                        onLongPress: () async {
                          await mvPlayer.toggleCollect(mv);
                          Toast.success('已取消收藏');
                        },
                        child: MvCard(
                          mv: mv,
                          active: MvInfo.isSameMv(mvPlayer.currentMv, mv),
                          onTap: () => _playMv(context, mvPlayer, mv, mvs),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _playMv(
    BuildContext context,
    MvPlayerController mvPlayer,
    MvInfo mv,
    List<MvInfo> mvs,
  ) {
    if (MvInfo.isSameMv(mvPlayer.currentMv, mv) && mvPlayer.hasActiveSession) {
      if (!mvPlayer.isPlaying && !mvPlayer.isPreparing) {
        unawaited(mvPlayer.togglePlay());
      }
      unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
      return;
    }
    unawaited(mvPlayer.playMv(mv, queue: List<MvInfo>.of(mvs)));
    unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
  }

  void _playAll(BuildContext context, MvPlayerController mvPlayer) {
    final mvs = List<MvInfo>.of(mvPlayer.collectedMvs);
    if (mvs.isEmpty) return;
    unawaited(mvPlayer.playMv(mvs.first, queue: mvs));
    unawaited(MvPlayerPage.open(context, mvPlayer: mvPlayer));
  }
}
