import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/desktop_lyrics_service.dart';
import 'package:shiyin_music/ui/desktop/lyrics_karaoke_line.dart';
import 'package:shiyin_music/ui/pages/desktop_lyrics_settings_page.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  @override
  bool desktopLyricsEnabled = true;

  final List<DesktopLyricsSettings> updatedSettingsList = [];

  @override
  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    updatedSettingsList.add(settings);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlayerController player;

  setUp(() {
    player = _FakePlayerController();
  });

  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    Size size = const Size(1200, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopLyricsSettingsPage(player: player),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('DesktopLyricsSettingsPage', () {

    testWidgets('renders line count selection and toggles single/dual line', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      expect(find.text('单行显示'), findsOneWidget);
      expect(find.text('双行显示'), findsOneWidget);
      // 桌面默认双行两端对齐。
      expect(player.desktopLyricsSettings.singleLine, isFalse);

      // Switch to single line
      await tester.tap(find.text('单行显示'));
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.singleLine, isTrue);
      expect(player.updatedSettingsList.last.singleLine, isTrue);

      // Switch back to dual line
      await tester.tap(find.text('双行显示'));
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.singleLine, isFalse);
      expect(player.updatedSettingsList.last.singleLine, isFalse);
    });

    testWidgets('alignment options follow line count (split is dual-only)', (
      tester,
    ) async {
      // 先切到单行：单行模式只有居中/左/右三种；「左右分离」只对双行显示有意义。
      await player.updateDesktopLyricsSettings(
        player.desktopLyricsSettings.copyWith(
          singleLine: true,
          alignment: DesktopLyricsAlignment.center,
        ),
      );
      await pumpSettingsPage(tester);

      // 单行模式只有居中/左/右三种；「左右分离」只对双行显示有意义。
      expect(find.text('居中'), findsOneWidget);
      expect(find.text('左对齐'), findsOneWidget);
      expect(find.text('右对齐'), findsOneWidget);
      expect(find.text('左右分离'), findsNothing);

      // 默认 split 在单行下与居中渲染完全一致 → 展示为居中，避免空选中。
      var alignmentSelector = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(alignmentSelector.selected, {DesktopLyricsAlignment.center});

      // Tap left align
      await tester.tap(find.text('左对齐'));
      await tester.pumpAndSettle();
      expect(player.desktopLyricsSettings.alignment, 'left');

      // 切到双行：出现「左右分离」并可选中。
      await tester.tap(find.text('双行显示'));
      await tester.pumpAndSettle();
      expect(find.text('左右分离'), findsOneWidget);

      await tester.tap(find.text('左右分离'));
      await tester.pumpAndSettle();
      expect(
        player.desktopLyricsSettings.alignment,
        DesktopLyricsAlignment.split,
      );

      // 切回单行：左右分离消失，且回落为渲染等价的居中。
      await tester.tap(find.text('单行显示'));
      await tester.pumpAndSettle();
      expect(find.text('左右分离'), findsNothing);
      expect(
        player.desktopLyricsSettings.alignment,
        DesktopLyricsAlignment.center,
      );

      alignmentSelector = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(alignmentSelector.selected, {DesktopLyricsAlignment.center});
    });

    testWidgets('renders text opacity slider and updates textOpacity', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      expect(find.text('文字透明度'), findsOneWidget);
      expect(find.text('100%'), findsWidgets);

      final slider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const Key('slider_text_opacity')),
          matching: find.byType(Slider),
        ),
      );
      expect(slider.min, 0.2);
      expect(slider.max, 1.0);

      // Change slider value
      slider.onChanged?.call(0.6);
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.textOpacity, closeTo(0.6, 0.01));
      expect(find.text('60%'), findsWidgets);
    });

    testWidgets('renders played and unplayed text color pickers and updates colors', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      expect(find.text('歌词颜色'), findsOneWidget);
      expect(find.text('高亮颜色'), findsOneWidget);

      // 打开「高亮颜色」取色弹窗，选黄色预设并确认
      await tester.tap(find.byKey(const Key('color_field_高亮颜色')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color_高亮颜色_ffffee58')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.playedTextColor, 0xFFFFEE58);

      // 打开「歌词颜色」取色弹窗，选白色预设并确认
      await tester.tap(find.byKey(const Key('color_field_歌词颜色')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color_歌词颜色_ffffffff')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.unplayedTextColor, 0xFFFFFFFF);
      expect(player.desktopLyricsSettings.textColor, 0xFFFFFFFF);
    });

    testWidgets('tapping a lyrics color scheme chip updates both colors', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      // 点击「鎏金」方案：歌词色与高亮色同步切换（白词 + 金黄高亮）。
      final gilded = DesktopLyricsColorScheme.presets[1];
      await tester.tap(find.byKey(ValueKey('scheme_${gilded.name}')));
      await tester.pumpAndSettle();

      expect(player.desktopLyricsSettings.unplayedTextColor, 0xFFFFFFFF);
      expect(player.desktopLyricsSettings.playedTextColor, 0xFFFFD700);
    });

    testWidgets('renders live preview section and updates on settings change', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      // Preview section header
      expect(find.text('效果预览'), findsOneWidget);

      // 桌面默认双行：预览同时显示两行。
      expect(find.text('易格音乐 懂你的每一首热爱'), findsWidgets);
      expect(find.text('让音乐更自由'), findsWidgets);
      expect(find.byType(LyricsKaraokeLine), findsNWidgets(2));

      // Switch to single line mode
      await tester.tap(find.text('单行显示'));
      await tester.pumpAndSettle();

      // Single line preview shows only current line
      expect(find.text('易格音乐 懂你的每一首热爱'), findsWidgets);
      expect(find.byType(LyricsKaraokeLine), findsOneWidget);
      expect(find.text('让音乐更自由'), findsNothing);
    });

    testWidgets('restore defaults resets appearance and keeps locked', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      // 先把外观调乱：单行、大字号、粉色歌词色。
      await tester.tap(find.text('单行显示'));
      await tester.pumpAndSettle();
      final fontSlider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const Key('slider_font_size')),
          matching: find.byType(Slider),
        ),
      );
      fontSlider.onChanged?.call(40.0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color_field_歌词颜色')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color_歌词颜色_ffff69b4')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(player.desktopLyricsSettings.fontSize, closeTo(40.0, 0.01));

      // 锁定是行为状态，恢复默认后应保持不变。
      await player.updateDesktopLyricsSettings(
        player.desktopLyricsSettings.copyWith(locked: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('恢复默认'));
      // 等 SnackBar 完整走完显示/定时/退出，避免测试结束时 Timer 未决。
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      final restored = player.updatedSettingsList.last;
      expect(restored.singleLine, isFalse);
      expect(restored.fontSize, DesktopLyricsSettings.defaultFontSize);
      expect(restored.alignment, DesktopLyricsAlignment.split);
      expect(restored.opacity, DesktopLyricsSettings.defaultOpacity);
      expect(
        restored.unplayedTextColor,
        DesktopLyricsSettings.defaultUnplayedTextColor,
      );
      expect(
        restored.playedTextColor,
        DesktopLyricsSettings.defaultPlayedTextColor,
      );
      expect(
        restored.backgroundColor,
        DesktopLyricsSettings.defaultBackgroundColor,
      );
      expect(restored.locked, isTrue);
    });

    testWidgets('updates UI when player desktopLyricsSettings changes externally', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      // 桌面默认双行两端对齐：对齐选择器直接展示 split。
      final alignmentSelector = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(alignmentSelector.selected, {DesktopLyricsAlignment.split});

      // Externally update player settings
      await player.updateDesktopLyricsSettings(
        player.desktopLyricsSettings.copyWith(
          alignment: 'right',
          singleLine: false,
        ),
      );
      await tester.pumpAndSettle();

      // Should reflect in preview with dual lines
      expect(find.byType(LyricsKaraokeLine), findsNWidgets(2));
      final updatedSelector = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(updatedSelector.selected, {'right'});
    });

    testWidgets(
      'wide layout renders 2-column split view with sticky preview on right',
      (tester) async {
        await pumpSettingsPage(tester, size: const Size(1000, 700));

        // Both appearance and preview sections exist
        final appearanceHeader = find.text('外观');
        final previewHeader = find.text('效果预览');
        expect(appearanceHeader, findsOneWidget);
        expect(previewHeader, findsOneWidget);

        // In wide layout, preview is on the right side of appearance settings
        final appearancePos = tester.getTopLeft(appearanceHeader);
        final previewPos = tester.getTopLeft(previewHeader);
        expect(previewPos.dx, greaterThan(appearancePos.dx));

        // Both are visible on screen
        expect(find.byType(LyricsKaraokeLine), findsNWidgets(2));

        // 1. Updating segments (行数)：默认双行，切单行验证切换生效。
        await tester.tap(find.text('单行显示'));
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.singleLine, isTrue);
        expect(find.byType(LyricsKaraokeLine), findsOneWidget);

        // 2. Updating slider (字体大小)
        final fontSlider = tester.widget<Slider>(
          find.descendant(
            of: find.byKey(const Key('slider_font_size')),
            matching: find.byType(Slider),
          ),
        );
        fontSlider.onChanged?.call(32.0);
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.fontSize, closeTo(32.0, 0.01));

        // 3. Updating color (open picker dialog, pick pink, confirm)
        await tester.tap(find.byKey(const Key('color_field_歌词颜色')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('color_歌词颜色_ffff69b4')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.unplayedTextColor, 0xFFFF69B4);
      },
    );

    testWidgets(
      'narrow layout renders preview card at top before appearance section',
      (tester) async {
        await pumpSettingsPage(tester, size: const Size(400, 800));

        final appearanceHeader = find.text('外观');
        final previewHeader = find.text('效果预览');
        expect(appearanceHeader, findsOneWidget);
        expect(previewHeader, findsOneWidget);

        // In narrow layout, preview is above appearance settings
        final appearancePos = tester.getTopLeft(appearanceHeader);
        final previewPos = tester.getTopLeft(previewHeader);
        expect(previewPos.dy, lessThan(appearancePos.dy));

        // 1. Updating segments (行数)
        await tester.tap(find.text('双行显示'));
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.singleLine, isFalse);
        expect(find.byType(LyricsKaraokeLine), findsNWidgets(2));

        // 2. Updating slider (字体大小)
        final fontSlider = tester.widget<Slider>(
          find.descendant(
            of: find.byKey(const Key('slider_font_size')),
            matching: find.byType(Slider),
          ),
        );
        fontSlider.onChanged?.call(30.0);
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.fontSize, closeTo(30.0, 0.01));

        // 3. Updating color (open picker dialog, pick pink, confirm)
        await tester.ensureVisible(
          find.byKey(const Key('color_field_歌词颜色')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('color_field_歌词颜色')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('color_歌词颜色_ffff69b4')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(player.desktopLyricsSettings.unplayedTextColor, 0xFFFF69B4);
      },
    );

    testWidgets(
      'dual line preview uses unified fontSize * 0.82 and bold weight for second line',
      (tester) async {
        await pumpSettingsPage(tester);

        await tester.tap(find.text('双行显示'));
        await tester.pumpAndSettle();

        final lines = tester
            .widgetList<LyricsKaraokeLine>(
              find.byType(LyricsKaraokeLine),
            )
            .toList();
        expect(lines.length, 2);

        final secondLine = lines[1];
        expect(secondLine.text, '让音乐更自由');
        expect(
          secondLine.fontSize,
          closeTo(player.desktopLyricsSettings.fontSize * 0.82, 0.01),
        );
        expect(secondLine.fontWeight, FontWeight.bold);
      },
    );

  });
}

