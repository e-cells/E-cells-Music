import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../services/android_lyric_service.dart';

/// Android 桌面歌词（易格方案）设置页。
///
/// 选项集与易格音乐一致：主题模式（含光感）、浅/深色板各 7 色、字号、
/// 双行、描边、对齐、宽度百分比、悬浮窗时间微调、锁定。悬浮窗开启期间
/// 所有调整实时生效——悬浮窗本身就是预览，无需预览卡片。
class AndroidLyricSettingsPage extends StatefulWidget {
  const AndroidLyricSettingsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<AndroidLyricSettingsPage> createState() =>
      _AndroidLyricSettingsPageState();
}

class _AndroidLyricSettingsPageState extends State<AndroidLyricSettingsPage> {
  late AndroidLyricSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.player.androidLyricSettings;
    widget.player.addListener(_syncFromPlayer);
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncFromPlayer);
    super.dispose();
  }

  void _syncFromPlayer() {
    final next = widget.player.androidLyricSettings;
    if (next == _settings) return;
    setState(() => _settings = next);
  }

  void _update(AndroidLyricSettings Function(AndroidLyricSettings s) fn) {
    setState(() => _settings = fn(_settings));
    widget.player.updateAndroidLyricSettings(_settings);
  }

  void _resetToDefaults() {
    // 只恢复外观；锁定是行为状态，正在显示的悬浮窗不应突然解锁。
    _update((s) => s.withDefaultAppearance());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('桌面歌词设置'),
        actions: [
          TextButton.icon(
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('恢复默认'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              _buildAppearanceSection(context, colorScheme),
              const SizedBox(height: 16),
              _buildBehaviorSection(context, colorScheme),
              const SizedBox(height: 16),
              _buildTipCard(context, colorScheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppearanceSection(BuildContext context, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '外观'),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _SegmentTile<String>(
              icon: Icons.brightness_6_rounded,
              iconColor: colorScheme.primary,
              title: '主题模式',
              selected: _settings.themeMode,
              segments: const [
                ButtonSegment(
                  value: AndroidLyricThemeMode.system,
                  label: Text('跟随系统'),
                ),
                ButtonSegment(
                  value: AndroidLyricThemeMode.light,
                  label: Text('浅色'),
                ),
                ButtonSegment(
                  value: AndroidLyricThemeMode.dark,
                  label: Text('深色'),
                ),
                ButtonSegment(
                  value: AndroidLyricThemeMode.sensor,
                  label: Text('光感'),
                ),
              ],
              onChanged: (v) => _update((s) => s.copyWith(themeMode: v)),
            ),
            // 光感值仅光感模式需要（隧道等场景手动调高切深色的灵敏度）
            if (_settings.themeMode == AndroidLyricThemeMode.sensor) ...[
              _SettingsDivider(),
              _SliderTile(
                key: const Key('slider_android_sensor_dark_threshold'),
                icon: Icons.brightness_4_rounded,
                iconColor: colorScheme.primary,
                title: '光感值',
                subtitle: '环境亮度低于该值（lux）时切换深色歌词；白天进隧道'
                    '歌词仍为浅色时调高它',
                value: _settings.sensorDarkThreshold.toDouble(),
                min: AndroidLyricSettings.sensorDarkThresholdMin.toDouble(),
                max: AndroidLyricSettings.sensorDarkThresholdMax.toDouble(),
                divisions: (AndroidLyricSettings.sensorDarkThresholdMax -
                        AndroidLyricSettings.sensorDarkThresholdMin) ~/
                    AndroidLyricSettings.sensorDarkThresholdStep,
                label: '${_settings.sensorDarkThreshold} lux',
                onChanged: (v) => _update(
                  (s) => s.copyWith(sensorDarkThreshold: v.round()),
                ),
              ),
            ],
            _SettingsDivider(),
            _ColorPaletteRow(
              icon: Icons.light_mode_rounded,
              iconColor: colorScheme.primary,
              title: '浅色主题颜色',
              palette: AndroidLyricSettings.lightPalette,
              selectedIndex: _settings.lightColorIndex,
              onSelected: (index) =>
                  _update((s) => s.copyWith(lightColorIndex: index)),
            ),
            _SettingsDivider(),
            _ColorPaletteRow(
              icon: Icons.dark_mode_rounded,
              iconColor: colorScheme.primary,
              title: '深色主题颜色',
              palette: AndroidLyricSettings.darkPalette,
              selectedIndex: _settings.darkColorIndex,
              onSelected: (index) =>
                  _update((s) => s.copyWith(darkColorIndex: index)),
            ),
            _SettingsDivider(),
            _SliderTile(
              icon: Icons.format_size_rounded,
              iconColor: colorScheme.primary,
              title: '字体大小',
              value: _settings.fontSize,
              min: AndroidLyricSettings.fontSizeMin,
              max: AndroidLyricSettings.fontSizeMax,
              label: '${_settings.fontSize.round()}sp',
              onChanged: (v) => _update((s) => s.copyWith(fontSize: v)),
            ),
            _SettingsDivider(),
            _SwitchTile(
              icon: Icons.table_rows_rounded,
              iconColor: colorScheme.primary,
              title: '双行歌词',
              subtitle: '关闭后单行显示，第二行显示翻译（无翻译时显示下一句）',
              value: _settings.doubleLine,
              onChanged: (v) => _update((s) => s.copyWith(doubleLine: v)),
            ),
            _SettingsDivider(),
            _SwitchTile(
              icon: Icons.border_style_rounded,
              iconColor: colorScheme.primary,
              title: '文字描边',
              subtitle: '为歌词文字加黑色描边，浅色背景下更清晰',
              value: _settings.strokeEnabled,
              onChanged: (v) => _update((s) => s.copyWith(strokeEnabled: v)),
            ),
            _SettingsDivider(),
            _SegmentTile<String>(
              icon: Icons.format_align_center_rounded,
              iconColor: colorScheme.primary,
              title: '对齐方式',
              selected: _settings.alignment,
              segments: const [
                ButtonSegment(
                  value: AndroidLyricAlignment.left,
                  label: Text('左对齐'),
                ),
                ButtonSegment(
                  value: AndroidLyricAlignment.center,
                  label: Text('居中'),
                ),
                ButtonSegment(
                  value: AndroidLyricAlignment.right,
                  label: Text('右对齐'),
                ),
              ],
              onChanged: (v) => _update((s) => s.copyWith(alignment: v)),
            ),
            _SettingsDivider(),
            _SliderTile(
              icon: Icons.width_full_rounded,
              iconColor: colorScheme.primary,
              title: '悬浮窗宽度',
              value: _settings.widthPercent.toDouble(),
              min: AndroidLyricSettings.widthPercentMin.toDouble(),
              max: AndroidLyricSettings.widthPercentMax.toDouble(),
              label: '${_settings.widthPercent}%',
              onChanged: (v) =>
                  _update((s) => s.copyWith(widthPercent: v.round())),
            ),
            _SettingsDivider(),
            _SliderTile(
              key: const Key('slider_android_lyric_offset'),
              icon: Icons.timer_outlined,
              iconColor: colorScheme.primary,
              title: '歌词时间微调',
              value: _settings.lyricOffsetMs.toDouble(),
              min: AndroidLyricSettings.lyricOffsetMsMin.toDouble(),
              max: AndroidLyricSettings.lyricOffsetMsMax.toDouble(),
              // 0-2000ms 步进 50（易格同值）。
              divisions: AndroidLyricSettings.lyricOffsetMsMax ~/
                  AndroidLyricSettings.lyricOffsetStepMs,
              label: _offsetLabel(_settings.lyricOffsetMs),
              onChanged: (v) =>
                  _update((s) => s.copyWith(lyricOffsetMs: v.round())),
            ),
          ],
        ),
      ],
    );
  }

  /// 偏移文案：0 显示"无"，否则显示毫秒（易格是 0-2000 正向微调；
  /// 需要歌词延后时用应用内逐曲偏移）。
  String _offsetLabel(int ms) => ms == 0 ? '无' : '$ms ms';

  Widget _buildBehaviorSection(BuildContext context, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '行为'),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.lock_rounded,
              iconColor: colorScheme.primary,
              title: '锁定歌词',
              subtitle: '锁定后完全穿透点击且背景透明，无法拖动，悬浮窗微调按钮也会隐藏；'
                  '可在悬浮窗上点锁定按钮，解锁或关闭请回本页操作',
              value: _settings.locked,
              onChanged: (v) => _update((s) => s.copyWith(locked: v)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTipCard(BuildContext context, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '歌词悬浮窗开启后一直显示（包括应用在前台时），可自由拖动位置。'
              '双行成对推进：唱完第二行才切换到下一对；单行模式第二行显示当前句翻译。'
              '"光感"主题会根据环境光自动切换深浅配色，'
              '白天进隧道切不过深色时可调高「光感值」。'
              '调乱了可点右上角「恢复默认」一键还原外观。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 与 desktop_lyrics_settings_page.dart 同风格的紧凑控件（该页私有，
// 此处最小复制一份） ---

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 48,
      color:
          Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.divisions,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;
  final int? divisions;

  /// 可选副标题：有值时标题/副标题占一行，滑条整行放下方（宽滑条更易细调）。
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
    final labelWidget = SizedBox(
      width: 48,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          label,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    if (subtitle == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Expanded(child: slider),
              const SizedBox(width: 8),
              labelWidget,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              labelWidget,
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: slider,
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SegmentTile<T> extends StatelessWidget {
  const _SegmentTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.selected,
    required this.segments,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final T selected;
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final titleRow = Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 12),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
    final segmentButton = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: segments,
      selected: {selected},
      onSelectionChanged: (newSet) {
        if (newSet.isNotEmpty) {
          onChanged(newSet.first);
        }
      },
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: WidgetStatePropertyAll(Size(0, 32)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10),
        ),
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏单行放不下四个分段（主题模式），回退为上下两行。
          if (constraints.maxWidth >= 460) {
            return Row(
              children: [
                titleRow,
                const Spacer(),
                segmentButton,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleRow,
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: segmentButton),
            ],
          );
        },
      ),
    );
  }
}

/// 色板行：图标 + 标题靠左，7 个色块靠右；当前索引白圈高亮。
class _ColorPaletteRow extends StatelessWidget {
  const _ColorPaletteRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.palette,
    required this.selectedIndex,
    required this.onSelected,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final List<int> palette;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < palette.length; i++) ...[
                _PaletteSwatch(
                  color: Color(palette[i]),
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
                if (i != palette.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('palette_${color.toARGB32()}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }
}
