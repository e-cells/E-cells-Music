import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/desktop_system_integration.dart';
import '../desktop/desktop_window.dart';
import '../widgets/toast.dart';
import 'download_location_settings.dart';
import 'settings_widgets.dart';

/// 设置页「桌面」分节（仅桌面形态：托盘关闭行为 + 下载位置 + 窗口重置）。
///
/// 「下载位置」组件本体（Android 亦复用）见 download_location_settings.dart。
class DesktopSettingsSection extends StatelessWidget {
  const DesktopSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '桌面'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            const CloseToTraySwitch(),
            SettingsDivider(),
            const AutoStartSwitch(),
            SettingsDivider(),
            const DownloadLocationSettings(),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.crop_square_rounded,
              iconColor: const Color(0xFF7CB342),
              title: '重置窗口',
              subtitle: '恢复默认窗口大小并居中',
              onTap: () => unawaited(DesktopWindow.resetToDefault()),
            ),
          ],
        ),
        // 与下一节（缓存）的间距：放在门控内，
        // 避免移动端桌面块被跳过时间距 20→40 翻倍。
        const SizedBox(height: 20),
      ],
    );
  }
}

/// "关闭时最小化到托盘"开关（桌面形态专属）。
///
/// settings_page 整页为 StatelessWidget，为避免整页改造，
/// 该开关独立成小组件，自行读写 prefs 键
/// [DesktopWindow.kCloseToTrayPrefKey]（默认 true）。
class CloseToTraySwitch extends StatefulWidget {
  const CloseToTraySwitch({super.key});

  @override
  State<CloseToTraySwitch> createState() => _CloseToTraySwitchState();
}

class _CloseToTraySwitchState extends State<CloseToTraySwitch> {
  /// 默认开启，与关闭行为默认值一致，prefs 读取完成后覆盖。
  bool _closeToTray = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _closeToTray = DesktopWindow.closeToTrayEnabled(prefs);
    });
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _closeToTray = value);
    final prefs = await SharedPreferences.getInstance();
    await DesktopWindow.setCloseToTray(prefs, value);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchTile(
      icon: Icons.window_rounded,
      iconColor: const Color(0xFF00B0FF),
      title: '关闭时最小化到托盘',
      subtitle: '点关闭按钮时隐藏到系统托盘，音乐不断',
      value: _closeToTray,
      onChanged: (value) => unawaited(_onChanged(value)),
    );
  }
}

/// "开机自启"开关（桌面形态专属）。
///
/// 与 [CloseToTraySwitch] 同模式：独立小组件避免整页改 Stateful。
/// 切换即 register/unregister（[autoStartManager]，可注入测试 fake）；
/// 失败或注册表实际状态与预期不符时回滚 UI 并提示，
/// 保证开关始终反映 OS 真实状态。
class AutoStartSwitch extends StatefulWidget {
  const AutoStartSwitch({super.key});

  @override
  State<AutoStartSwitch> createState() => _AutoStartSwitchState();
}

class _AutoStartSwitchState extends State<AutoStartSwitch> {
  /// 默认关；OS 实际状态读取完成后覆盖。
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await autoStartManager.isEnabled();
      if (!mounted) return;
      setState(() => _enabled = enabled);
    } on Exception {
      // 读取失败保持默认关（与开关初值一致），不影响页面其余功能。
    }
  }

  Future<void> _onChanged(bool value) async {
    // 乐观更新：立即反馈点击。
    setState(() => _enabled = value);
    try {
      await autoStartManager.setEnabled(value);
      // 以 OS 实际状态为准（如注册表写入被组策略拦截时 enable 静默失败）。
      final actual = await autoStartManager.isEnabled();
      if (!mounted) return;
      if (actual != value) {
        setState(() => _enabled = actual);
        Toast.error('设置开机自启失败');
      }
    } on Exception {
      if (!mounted) return;
      setState(() => _enabled = !value);
      Toast.error('设置开机自启失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchTile(
      icon: Icons.rocket_launch_rounded,
      iconColor: const Color(0xFF3949AB),
      title: '开机自启',
      subtitle: '登录系统时自动启动易格音乐',
      value: _enabled,
      onChanged: (value) => unawaited(_onChanged(value)),
    );
  }
}
