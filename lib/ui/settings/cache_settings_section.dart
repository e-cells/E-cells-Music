import 'dart:io';

import 'package:flutter/material.dart';

import 'download_location_settings.dart';
import 'settings_widgets.dart';

/// 设置页「缓存」分节。
///
/// [onOpenManager] 由页面注入（缓存管理弹窗逻辑保留在 settings_page）。
/// Android 追加「下载位置」（自定义下载路径，选公共目录/SD/USB 盘）；
/// 桌面形态的下载位置在「桌面」分节，不在此重复。
class CacheSettingsSection extends StatelessWidget {
  const CacheSettingsSection({super.key, required this.onOpenManager});

  final VoidCallback onOpenManager;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '缓存'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.storage_rounded,
              iconColor: const Color(0xFF009688),
              title: '缓存管理',
              subtitle: '查看和清理缓存',
              onTap: onOpenManager,
            ),
            if (Platform.isAndroid) ...[
              const SettingsDivider(),
              const DownloadLocationSettings(),
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
