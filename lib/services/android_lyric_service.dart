import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 桌面歌词主题模式（移植自易格音乐）。
///
/// - [light]/[dark]：固定浅/深色配色。
/// - [system]：跟随系统深色模式（原生侧有配置广播 + 轮询双兜底）。
/// - [sensor]：光感传感器自适应（≤15 lux 判深色、≥30 lux 判浅色，迟滞防抖），
///   让歌词在应用被其他应用（如导航）覆盖到后台时仍能实时变色。
class AndroidLyricThemeMode {
  const AndroidLyricThemeMode._();

  static const String light = 'light';
  static const String dark = 'dark';
  static const String system = 'system';
  static const String sensor = 'sensor';

  /// 全部合法取值（设置页分段选项共用）。
  static const List<String> values = [light, dark, system, sensor];
}

/// Android 桌面歌词对齐方式：悬浮窗两行文字的横向锚点。
class AndroidLyricAlignment {
  const AndroidLyricAlignment._();

  static const String left = 'left';
  static const String center = 'center';
  static const String right = 'right';

  static const List<String> values = [left, center, right];
}

/// Android 桌面歌词设置（移植自易格音乐的字段集与默认值）。
///
/// 与 PC（Windows/Linux）的 [DesktopLyricsSettings] 是两套独立模型：
/// 易格方案是"浅/深两套 7 色 + 主题模式切换"而非自由取色，且多了
/// 描边/宽度百分比/对齐/悬浮窗时间偏移。持久化于
/// `settings.android_lyric_settings`（JSON + 版本号）。
class AndroidLyricSettings {
  /// 字号允许范围（易格同值：5-36sp）。
  static const double fontSizeMin = 5.0;
  static const double fontSizeMax = 36.0;

  /// 悬浮窗宽度占屏幕宽度百分比范围。易格 UI 标 1-100，但原生 applySettings
  /// 实际钳制 10-100，两处统一为 10-100。
  static const int widthPercentMin = 10;
  static const int widthPercentMax = 100;

  /// 悬浮窗歌词时间偏移范围与步进（仅作用于悬浮窗，不影响应用内歌词）。
  static const int lyricOffsetMsMin = 0;
  static const int lyricOffsetMsMax = 2000;
  static const int lyricOffsetStepMs = 50;

  /// 光感模式深色阈值（光感值）范围与步进（lux）：环境亮度 ≤ 该值切深色、
  /// ≥ 该值×2 切浅色（迟滞防抖，区间内保持原状态）。上限 1000 覆盖
  /// 白天隧道（几十~几百 lux）时手动调高的需求。
  static const int sensorDarkThresholdMin = 5;
  static const int sensorDarkThresholdMax = 1000;
  static const int sensorDarkThresholdStep = 5;

  // 出厂默认（易格同值）：色板索引 0、跟随系统、字号 18、双行、
  // 全宽、无描边、居中、无偏移。
  static const int defaultLightColorIndex = 0;
  static const int defaultDarkColorIndex = 0;
  static const String defaultThemeMode = AndroidLyricThemeMode.system;
  static const double defaultFontSize = 18.0;
  static const bool defaultDoubleLine = true;
  static const int defaultWidthPercent = 100;
  static const bool defaultStrokeEnabled = false;
  static const String defaultAlignment = AndroidLyricAlignment.center;
  static const int defaultLyricOffsetMs = 0;

  /// 光感值出厂默认（lux），与原生侧改造前的硬编码阈值 15 保持同行为。
  static const int defaultSensorDarkThreshold = 15;

  /// 浅色主题下的歌词色板（与原生 LyricsOverlayService.LIGHT_COLOR_HEX
  /// 逐项一致；仅设置页色块展示用，真正的取色在原生侧按索引完成）。
  static const List<int> lightPalette = [
    0xFF000000, // 纯黑
    0xFF333333, // 深灰
    0xFF1A237E, // 靛蓝
    0xFF880E4F, // 玫红
    0xFF1B5E20, // 墨绿
    0xFF263238, // 蓝灰
    0xFF4E342E, // 棕褐
  ];

  /// 深色主题下的歌词色板（与原生 DARK_COLOR_HEX 逐项一致）。
  static const List<int> darkPalette = [
    0xFFFFFFFF, // 纯白
    0xFFE0E0E0, // 浅灰
    0xFFFFCA28, // 琥珀
    0xFF00E5FF, // 青蓝
    0xFF69F0AE, // 薄荷
    0xFFFF4081, // 粉红
    0xFFB388FF, // 淡紫
  ];

  const AndroidLyricSettings({
    this.lightColorIndex = defaultLightColorIndex,
    this.darkColorIndex = defaultDarkColorIndex,
    this.themeMode = defaultThemeMode,
    this.fontSize = defaultFontSize,
    this.doubleLine = defaultDoubleLine,
    this.locked = false,
    this.widthPercent = defaultWidthPercent,
    this.strokeEnabled = defaultStrokeEnabled,
    this.alignment = defaultAlignment,
    this.lyricOffsetMs = defaultLyricOffsetMs,
    this.sensorDarkThreshold = defaultSensorDarkThreshold,
  });

  final int lightColorIndex;
  final int darkColorIndex;
  final String themeMode;
  final double fontSize;
  final bool doubleLine;

  /// 锁定（易格语义）：完全触摸穿透 + 背景透明，锁定期间无法拖动，
  /// 解锁/关闭只能回设置页操作。
  final bool locked;
  final int widthPercent;
  final bool strokeEnabled;
  final String alignment;

  /// 悬浮窗歌词时间微调（毫秒）：原生歌词引擎把它叠加在 Flutter 推来的
  /// 播放位置上，只影响悬浮窗。
  final int lyricOffsetMs;

  /// 光感值（lux）：仅 themeMode 为光感时生效，环境亮度 ≤ 该值切深色
  /// 歌词、≥ 该值×2 切浅色；浅色阈值由原生侧派生，不单独存储。
  final int sensorDarkThreshold;

  /// 外观恢复出厂默认（设置页「恢复默认」）。锁定是行为状态，不在此
  /// 重置——正在显示的悬浮窗不应因恢复外观而突然解锁。
  AndroidLyricSettings withDefaultAppearance() => copyWith(
        lightColorIndex: defaultLightColorIndex,
        darkColorIndex: defaultDarkColorIndex,
        themeMode: defaultThemeMode,
        fontSize: defaultFontSize,
        doubleLine: defaultDoubleLine,
        widthPercent: defaultWidthPercent,
        strokeEnabled: defaultStrokeEnabled,
        alignment: defaultAlignment,
        lyricOffsetMs: defaultLyricOffsetMs,
        sensorDarkThreshold: defaultSensorDarkThreshold,
      );

  AndroidLyricSettings copyWith({
    int? lightColorIndex,
    int? darkColorIndex,
    String? themeMode,
    double? fontSize,
    bool? doubleLine,
    bool? locked,
    int? widthPercent,
    bool? strokeEnabled,
    String? alignment,
    int? lyricOffsetMs,
    int? sensorDarkThreshold,
  }) {
    return AndroidLyricSettings(
      lightColorIndex: lightColorIndex ?? this.lightColorIndex,
      darkColorIndex: darkColorIndex ?? this.darkColorIndex,
      themeMode: themeMode ?? this.themeMode,
      fontSize: fontSize ?? this.fontSize,
      doubleLine: doubleLine ?? this.doubleLine,
      locked: locked ?? this.locked,
      widthPercent: widthPercent ?? this.widthPercent,
      strokeEnabled: strokeEnabled ?? this.strokeEnabled,
      alignment: alignment ?? this.alignment,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
      sensorDarkThreshold: sensorDarkThreshold ?? this.sensorDarkThreshold,
    );
  }

  Map<String, dynamic> toMap() => {
        'lightColorIndex': lightColorIndex,
        'darkColorIndex': darkColorIndex,
        'themeMode': themeMode,
        'fontSize': fontSize,
        'doubleLine': doubleLine,
        'locked': locked,
        'widthPercent': widthPercent,
        'strokeEnabled': strokeEnabled,
        'alignment': alignment,
        'lyricOffsetMs': lyricOffsetMs,
        'sensorDarkThreshold': sensorDarkThreshold,
      };

  @override
  bool operator ==(Object other) =>
      other is AndroidLyricSettings &&
      other.lightColorIndex == lightColorIndex &&
      other.darkColorIndex == darkColorIndex &&
      other.themeMode == themeMode &&
      other.fontSize == fontSize &&
      other.doubleLine == doubleLine &&
      other.locked == locked &&
      other.widthPercent == widthPercent &&
      other.strokeEnabled == strokeEnabled &&
      other.alignment == alignment &&
      other.lyricOffsetMs == lyricOffsetMs &&
      other.sensorDarkThreshold == sensorDarkThreshold;

  @override
  int get hashCode => Object.hash(
        lightColorIndex,
        darkColorIndex,
        themeMode,
        fontSize,
        doubleLine,
        locked,
        widthPercent,
        strokeEnabled,
        alignment,
        lyricOffsetMs,
        sensorDarkThreshold,
      );

  factory AndroidLyricSettings.fromMap(Map<String, dynamic> map) {
    int clampIndex(Object? v) =>
        ((v as num?)?.toInt() ?? 0).clamp(0, lightPalette.length - 1);
    return AndroidLyricSettings(
      lightColorIndex: clampIndex(map['lightColorIndex']),
      darkColorIndex: clampIndex(map['darkColorIndex']),
      themeMode: AndroidLyricThemeMode.values.contains(map['themeMode'])
          ? map['themeMode'] as String
          : defaultThemeMode,
      fontSize:
          ((map['fontSize'] as num?)?.toDouble() ?? defaultFontSize)
              .clamp(fontSizeMin, fontSizeMax),
      doubleLine: map['doubleLine'] as bool? ?? defaultDoubleLine,
      locked: map['locked'] as bool? ?? false,
      widthPercent:
          ((map['widthPercent'] as num?)?.toInt() ?? defaultWidthPercent)
              .clamp(widthPercentMin, widthPercentMax),
      strokeEnabled: map['strokeEnabled'] as bool? ?? defaultStrokeEnabled,
      alignment: AndroidLyricAlignment.values.contains(map['alignment'])
          ? map['alignment'] as String
          : defaultAlignment,
      lyricOffsetMs:
          ((map['lyricOffsetMs'] as num?)?.toInt() ?? defaultLyricOffsetMs)
              .clamp(lyricOffsetMsMin, lyricOffsetMsMax),
      // 旧版本 JSON 无此键：缺省回落默认值，行为与升级前一致
      sensorDarkThreshold: ((map['sensorDarkThreshold'] as num?)?.toInt() ??
              defaultSensorDarkThreshold)
          .clamp(sensorDarkThresholdMin, sensorDarkThresholdMax),
    );
  }
}

/// Android 桌面歌词通道客户端（通道 `shiyin_music/desktop_lyrics`）。
///
/// 契约与原生 LyricsOverlayService/MainActivity 对应：
/// - [show]/[hide]：开启/关闭（起停前台服务 + 建移悬浮窗）。
/// - [loadLyrics]：整首歌词一次下发，原生引擎自算当前句。
/// - [setPlaybackState]/[seekTo]/[calibratePosition]：播放锚点控制。
/// - [updateSettings]：易格字段集。
class AndroidLyricService {
  static const MethodChannel _channel = MethodChannel('shiyin_music/desktop_lyrics');

  /// 仅 Android：PC 走 [DesktopLyricsService] 的 Windows 桥接。
  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> checkPermission() async {
    if (!isSupportedPlatform) return false;
    try {
      final result = await _channel.invokeMethod<bool>('checkPermission');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> requestPermission() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // ignore
    }
  }

  /// 原生 Toast：通知卡片按钮在应用后台触发时，应用内 Toast 被通知栏
  /// 遮挡不可见，只能走原生提示。
  Future<void> showToast(String message) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('showToast', {'message': message});
    } on MissingPluginException {
      // ignore
    }
  }

  /// 开启悬浮窗：起前台服务 + 300ms 延迟建窗（原生侧完成）。
  /// 无悬浮窗权限时返回 false（PlatformException no_permission）。
  Future<bool> show() async {
    if (!isSupportedPlatform) return false;
    try {
      await _channel.invokeMethod<void>('show');
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 关闭悬浮窗并停服。
  Future<void> hide() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // ignore
    }
  }

  Future<bool> isVisible() async {
    if (!isSupportedPlatform) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isVisible');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 整首歌词一次下发。原生引擎接管当前句计算与刷新调度；
  /// [positionMs] 是当前播放位置（含单曲歌词偏移），作为锚点起点。
  Future<void> loadLyrics({
    required List<Map<String, Object>> lines,
    required int positionMs,
    required bool isPlaying,
  }) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('loadLyrics', {
        'lyrics': jsonEncode(lines),
        'currentTimeMs': positionMs,
        'isPlaying': isPlaying,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  /// 播放/暂停切换：重锚时间基准并启停原生调度。
  Future<void> setPlaybackState({
    required bool isPlaying,
    required int positionMs,
  }) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('setPlaybackState', {
        'isPlaying': isPlaying,
        'currentTimeMs': positionMs,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  /// 用户拖动进度条后的跳转：重锚 + 立即刷新。
  Future<void> seekTo({required int positionMs}) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('seekTo', {'currentTimeMs': positionMs});
    } on MissingPluginException {
      // ignore
    }
  }

  /// 心跳校准（30s 一次，播放中）：用精确位置重锚，防两端时钟漂移。
  Future<void> calibratePosition({required int positionMs}) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('calibratePosition', {
        'currentTimeMs': positionMs,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> updateSettings(AndroidLyricSettings settings) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('updateSettings', settings.toMap());
    } on MissingPluginException {
      // ignore
    }
  }

  /// 注册原生侧事件回调（原生 → Dart）。
  ///
  /// 目前唯一事件是 `onLockChanged`：用户点了悬浮窗微调行的「锁定」按钮，
  /// 原生已先应用锁定（穿透/透明/隐藏按钮），这里回推 Dart 同步设置状态。
  /// 传 null 注销回调。
  void setLockChangedHandler(void Function(bool locked)? handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLockChanged') {
        final args = call.arguments;
        handler?.call(args is Map && args['locked'] == true);
      }
    });
  }
}
