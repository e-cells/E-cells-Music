import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/music_api.dart';
import '../form_factor.dart';
import '../pages/android_lyric_settings_page.dart';
import '../pages/audio_interruption_settings_page.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../pages/playback_history_page.dart';
import '../pages/playback_stats_page.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 设置页「播放」分节。
///
/// [onSelectDefaultAudioQuality] 由页面注入（默认音质选择弹窗保留在
/// settings_page）。
class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.onSelectDefaultAudioQuality,
    required this.showLyricPageSkipButtons,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final VoidCallback onSelectDefaultAudioQuality;

  /// 是否展示「歌词页切歌键」开关：仅手机/平板形态需要（移动端歌词页
  /// 底栏才有切歌键）；PC 与车机隐藏，避免「看得到但无效」。
  final bool showLyricPageSkipButtons;

  String _audioInterruptionSummary(PlayerController player) {
    final parts = <String>[];
    if (!player.audioInterruptionEnabled) parts.add('已阻止打断');
    if (player.autoResumeAfterInterruption) parts.add('自动恢复');
    return parts.isEmpty ? '未开启' : parts.join(' · ');
  }

  /// 语音搜歌模式选择弹窗（易格同款两项）。
  Future<void> _showVoiceSearchModeDialog(BuildContext context) async {
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('语音搜歌'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('all'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('全部结果'),
              subtitle: Text('搜索结果全部加入播放队列并从第一首播放'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('first'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('仅播首曲'),
              subtitle: Text('只播放第一首，插到当前曲目之后，播完继续原列表'),
            ),
          ),
        ],
      ),
    );
    if (mode != null) {
      await player.setVoiceSearchMode(mode);
    }
  }

  /// 开机播放内容选择弹窗（开机自启播放开启时可见）。
  Future<void> _showStartupPlaySourceDialog(BuildContext context) async {
    final source = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('开机播放内容'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('resume'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('继续播放'),
              // 只存队列/当前歌，不存进度：恢复从歌曲开头播，不承诺"续播进度"。
              subtitle: Text('恢复上次的播放队列，从上次的歌曲开始播放'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('daily'),
            // 缓存的推荐歌单可能过期（首页缓存 adopt 不判 isStale），
            // 不承诺"今日"。
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('每日推荐'),
              subtitle: Text(
                '播放每日推荐歌单并替换播放队列；上次播的就是这份推荐时从上次的歌继续，无推荐数据时恢复上次队列',
              ),
            ),
          ),
        ],
      ),
    );
    if (source != null) {
      await player.setStartupPlaySource(source);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '播放'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.high_quality_rounded,
              iconColor: const Color(0xFF7E57C2),
              title: '默认音质',
              subtitle: player.audioQuality.label,
              onTap: onSelectDefaultAudioQuality,
            ),
            SettingsDivider(),
            SettingsSwitchTile(
              icon: Icons.auto_awesome_rounded,
              iconColor: const Color(0xFF3F51B5),
              title: '智能音质',
              subtitle: '播放失败时自动降级音质重试',
              value: player.smartQualityEnabled,
              onChanged: player.setSmartQualityEnabled,
            ),
            SettingsDivider(),
            // 移动端/车机专属：桌面无蜂窝网络，显示纯属摆设（含前导分隔线）。
            if (!isDesktopFormFactor) ...[
              SettingsSwitchTile(
                icon: Icons.wifi_rounded,
                iconColor: const Color(0xFF0288D1),
                title: '移动数据下后台缓存',
                subtitle: player.allowCellularPrecache
                    ? '蜂窝网络也会预缓存下一首'
                    : '默认仅 WiFi 下预缓存，省流量',
                value: player.allowCellularPrecache,
                onChanged: player.setAllowCellularPrecache,
              ),
              SettingsDivider(),
            ],
            SettingsSwitchTile(
              icon: Icons.power_settings_new_rounded,
              iconColor: const Color(0xFF00897B),
              title: '开机自启播放',
              subtitle: '打开应用时自动播放上次的歌曲',
              value: player.autoPlayOnStartupEnabled,
              onChanged: player.setAutoPlayOnStartupEnabled,
            ),
            SettingsDivider(),
            // 开机自启播放的内容偏好：仅在开关开启时展示（与父开关同色
            // 表从属；无平台/形态依赖，全形态可见）。
            if (player.autoPlayOnStartupEnabled) ...[
              SettingsTile(
                icon: Icons.queue_music_rounded,
                iconColor: const Color(0xFF00897B),
                title: '开机播放内容',
                subtitle: player.startupPlaySource == 'daily'
                    ? '每日推荐（同一份推荐从上次的歌继续播）'
                    : '继续播放（恢复上次队列）',
                onTap: () => _showStartupPlaySourceDialog(context),
              ),
              SettingsDivider(),
            ],
            // 移动端/车机专属：桌面隐藏（含其前导分隔线，避免双线）。
            if (!isDesktopFormFactor) ...[
              SettingsSwitchTile(
                icon: Icons.bluetooth_audio_rounded,
                iconColor: const Color(0xFF00ACC1),
                title: '连接新音频设备自动播放',
                subtitle: '连接蓝牙或耳机时自动恢复播放',
                value: player.autoPlayOnDeviceConnected,
                onChanged: player.setAutoPlayOnDeviceConnected,
              ),
              SettingsDivider(),
            ],
            SettingsSwitchTile(
              icon: Icons.volume_up_rounded,
              iconColor: const Color(0xFF43A047),
              title: '响度均衡',
              // 平台差异如实标注：macOS 无分析通道（Rust 引擎未接入，
              // 见 form_factor.dart 清单）。Windows 迁移 mpv 后端后放大/
              // 衰减能力与 Linux 一致，不再需要差异化文案。
              // 移动端无需显示桌面平台专属限制提示。
              subtitle: !isDesktopFormFactor
                  ? '基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异'
                  : switch (defaultTargetPlatform) {
                      TargetPlatform.macOS => 'macOS 暂不支持响度分析',
                      _ => '基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异',
                    },
              value: player.loudnessEnabled,
              onChanged: player.setLoudnessEnabled,
            ),
            if (player.isAudioEffectsSupported) ...[
              SettingsDivider(),
              SettingsTile(
                icon: Icons.graphic_eq_rounded,
                iconColor: const Color(0xFF8E24AA),
                title: '音效',
                subtitle: player.audioEffectsLabel,
                onTap: () =>
                    showAudioEffectsSheet(context: context, player: player),
              ),
            ],
            // 尾部分隔线在守卫外：桌面隐藏音效瓦片时，
            // 响度均衡与播放统计之间仍保留分隔线。
            SettingsDivider(),
            SettingsTile(
              icon: Icons.bar_chart_rounded,
              iconColor: const Color(0xFFD81B60),
              title: '播放统计',
              subtitle: '听歌时长、最常听歌手等',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaybackStatsPage(player: player),
                ),
              ),
            ),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.history_rounded,
              iconColor: const Color(0xFF0288D1),
              title: '播放历史',
              subtitle: '最近播放的歌曲',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      PlaybackHistoryPage(api: api, auth: auth, player: player),
                ),
              ),
            ),
            SettingsDivider(),
            // 移动端/车机专属：桌面隐藏（含前导分隔线）。
            if (!isDesktopFormFactor) ...[
              SettingsTile(
                icon: Icons.block_rounded,
                iconColor: const Color(0xFFFF7043),
                title: '后台打断机制',
                subtitle: _audioInterruptionSummary(player),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        AudioInterruptionSettingsPage(player: player),
                  ),
                ),
              ),
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.timelapse_rounded,
                iconColor: const Color(0xFF7CB342),
                title: '增加听歌时长',
                subtitle: '每播放 30 分钟自动同步一次',
                value: player.addListeningTimeEnabled,
                onChanged: player.setAddListeningTimeEnabled,
              ),
              // 可见性只跟形态走（与上面的「后台打断机制」同口径），不叠
              // defaultTargetPlatform 判断：Windows 上用
              // `--dart-define=FORCE_MOBILE=true` 预览移动端布局时，
              // isDesktopFormFactor 被强制为 false 而宿主平台仍是 windows，
              // 叠加平台判断会让这个开关在移动端预览里凭空消失。
              // 原生通道目前只有 Android 实现（MainActivity.kt 的
              // shiyin_music/screen），iOS/桌面下拨动是无副作用的空操作；
              // 要让 iOS 真正生效需补 UIApplication.idleTimerDisabled。
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.stay_current_portrait_rounded,
                iconColor: const Color(0xFF00ACC1),
                title: '播放页保持屏幕常亮',
                subtitle: '仅在播放中常亮；暂停或停止后交回系统自动休眠',
                value: player.keepScreenOnEnabled,
                onChanged: player.setKeepScreenOnEnabled,
              ),
              // 歌词页切歌键：仅手机/平板形态提供；PC 与车机没有移动端
              // 歌词页底栏（车机横屏走分栏布局），隐藏以免无效开关。
              if (showLyricPageSkipButtons) ...[
                SettingsDivider(),
                SettingsSwitchTile(
                  icon: Icons.skip_next_rounded,
                  iconColor: const Color(0xFF5C6BC0),
                  title: '歌词页切歌键',
                  subtitle: '在歌词页底部显示上一首/下一首按钮，无需滑回封面页',
                  value: player.lyricPageSkipButtonsEnabled,
                  onChanged: player.setLyricPageSkipButtonsEnabled,
                ),
              ],
            ],
            if (player.isDesktopLyricsSupported) ...[
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.lyrics_rounded,
                iconColor: const Color(0xFF00B0FF),
                title: '桌面歌词',
                subtitle: '在其他应用上方显示歌词悬浮窗',
                value: player.desktopLyricsEnabled,
                onChanged: (value) async {
                  await player.setDesktopLyricsEnabled(value);
                  if (!player.desktopLyricsEnabled && value) {
                    Toast.error('需要悬浮窗权限才能使用桌面歌词');
                  }
                },
              ),
              if (player.desktopLyricsEnabled) ...[
                SettingsDivider(),
                SettingsTile(
                  icon: Icons.tune_rounded,
                  iconColor: const Color(0xFF651FFF),
                  title: '歌词设置',
                  // PC 用原设置页（透明度/卡拉OK配色/对齐等）；Android 用
                  // 易格方案设置页（主题模式/色板/描边/宽度等）。
                  subtitle: isDesktopFormFactor
                      ? '透明度、颜色、锁定位置等'
                      : '主题颜色、字号、宽度、锁定等',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => isDesktopFormFactor
                          ? DesktopLyricsSettingsPage(player: player)
                          : AndroidLyricSettingsPage(player: player),
                    ),
                  ),
                ),
              ],
              // 语音点歌（系统助手/车机语音）模式：仅 Android 提供该入口
              //（MEDIA_PLAY_FROM_SEARCH + MediaSession 接线）。
              if (!isDesktopFormFactor &&
                  !kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.android) ...[
                SettingsDivider(),
                SettingsTile(
                  icon: Icons.mic_rounded,
                  iconColor: const Color(0xFF26A69A),
                  title: '语音搜歌',
                  subtitle: player.voiceSearchMode == 'first'
                      ? '仅播首曲（插入当前队列，不动原列表）'
                      : '全部结果（替换为搜索结果队列）',
                  onTap: () => _showVoiceSearchModeDialog(context),
                ),
              ],
              if (player.isBluetoothLyricsSupported) ...[
                SettingsDivider(),
                SettingsSwitchTile(
                  icon: Icons.bluetooth_rounded,
                  iconColor: const Color(0xFF2979FF),
                  title: '车载蓝牙歌词',
                  subtitle: '通过系统广播将歌词同步到车机/第三方歌词 App',
                  value: player.bluetoothLyricsEnabled,
                  onChanged: player.setBluetoothLyricsEnabled,
                ),
              ],
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
