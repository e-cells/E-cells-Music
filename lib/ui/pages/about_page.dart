import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../services/app_update_service.dart';
import '../../services/music_api.dart';
import '../widgets/app_update_widgets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.api});

  static final Uri _repositoryUri = Uri.parse(
    'https://github.com/e-cells/E-cells-Music',
  );

  final MusicApi api;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  Future<void> _openRepository(BuildContext context) async {
    final opened = await launchUrl(
      AboutPage._repositoryUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      Toast.error('无法打开 GitHub 仓库链接');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: AdaptiveContentPadding(
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('关于'),
            surfaceTintColor: Colors.transparent,
            backgroundColor: colorScheme.surface,
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 12),
                _AppLogo(),
                const SizedBox(height: 16),
                Text(
                  AppConfig.appName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '版本 ${AppConfig.appVersion} · ${AppConfig.rendererLabel}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '懂你的每一首热爱',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '一个专注播放体验的音乐应用。适配手机、车机、平板等多端。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppUpdateService.isSupportedPlatform
                            ? FilledButton.icon(
                                onPressed: () => checkAppUpdateManually(
                                  context: context,
                                ),
                                icon: const Icon(Icons.system_update_alt_rounded),
                                label: const Text('检查更新'),
                              )
                            : OutlinedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.system_update_alt_rounded),
                                label: const Text('暂不支持检查更新'),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
              child: _InfoSection(
                children: [
                  const _InfoRow(label: '应用名称', value: AppConfig.appName),
                  const _InfoRow(label: '当前版本', value: AppConfig.appVersion),
                  _InfoRow(label: '渲染引擎', value: AppConfig.rendererLabel),
                  _InfoLinkRow(
                    label: 'GitHub',
                    value: 'e-cells/E-cells-Music',
                    onTap: () => _openRepository(context),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
              child: _InfoSection(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.volunteer_activism_rounded,
                          size: 20,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '本软件完全开源免费，如果您是从淘宝、咸鱼等平台'
                            '购买的，请直接给店铺差评，谢谢！',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    ),
  );
  }
}

/// 应用 Logo，使用 lib/assets/logo.png。
class _AppLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: .22),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.asset(
          'lib/assets/logo.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: colorScheme.primaryContainer,
              child: Icon(
                Icons.music_note_rounded,
                size: 56,
                color: colorScheme.primary,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _InfoLinkRow extends StatelessWidget {
  const _InfoLinkRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.open_in_new_rounded,
              size: 18,
              color: colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(children: children),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

