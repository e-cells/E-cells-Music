import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? get currentSong => null;
  @override
  bool get isPlaying => false;
  @override
  bool get isPreparing => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier(Duration.zero);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool get isLoggedIn => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('移动端搜索页 input 文字垂直居中且不被裁切底部', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    final theme = ThemeController();
    await theme.setCarModeEnabled(false);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SearchPage(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final textFieldFinder = find.byType(TextField);
    expect(textFieldFinder, findsOneWidget);

    // 1. 初始状态：text 为空，hintText 正常居中展示
    final iconFinder = find.byIcon(Icons.search_rounded);
    expect(iconFinder, findsOneWidget);
    final iconRect = tester.getRect(iconFinder);

    final hintFinder = find.text('搜索歌曲、歌手、专辑、歌单');
    expect(hintFinder, findsOneWidget);
    final hintRect = tester.getRect(hintFinder);

    final containerFinder = find.ancestor(
      of: iconFinder,
      matching: find.byType(Container),
    ).first;
    final containerRect = tester.getRect(containerFinder);

    final inputDecoratorFinder = find.byType(InputDecorator);
    expect(inputDecoratorFinder, findsOneWidget);

    // 空态装饰器高度（空态保留后缀 32px 槽位，与输入态等高，
    // 使 textAlignVertical.center 在空态同样把光标行垂直居中）
    final emptyDecoratorHeight = tester.getSize(inputDecoratorFinder).height;

    final editableFinder = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'EditableText');
    expect(editableFinder, findsOneWidget);
    final editableBox = tester.renderObject(editableFinder) as RenderBox;

    // 提示文案为叠放的普通 Text（不再走 InputDecorator.hintText）
    final hintRenderBox = tester.renderObject(hintFinder.first) as RenderBox;

    // 占位符与输入框基线完全对齐、高度一致
    final editableBaseline = editableBox.getDryBaseline(editableBox.constraints, TextBaseline.alphabetic);
    final hintBaseline = hintRenderBox.getDryBaseline(hintRenderBox.constraints, TextBaseline.alphabetic);
    expect((editableBaseline! - hintBaseline!).abs(), lessThan(0.5));
    expect(hintRenderBox.size.height, equals(editableBox.size.height));

    // hintText 与 icon 垂直中心必须与 36px 胶囊容器垂直中心居中对齐
    expect((hintRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));
    expect((iconRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));

    RenderEditable? renderEditable;
    void findRenderEditable(RenderObject ro) {
      if (ro is RenderEditable) {
        renderEditable = ro;
        return;
      }
      ro.visitChildren(findRenderEditable);
    }
    findRenderEditable(editableBox);

    expect(renderEditable, isNotNull);
    // RenderEditable 布局高度必须满足字体的 preferredLineHeight，不能被挤压裁切底部
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));

    // 2. 输入文字：检查 RenderEditable 完整展示，高度不被 contentPadding 挤压截断，且垂直居中
    await tester.enterText(textFieldFinder, '我的歌单gyjp');
    await tester.pumpAndSettle();

    final inputRect = tester.getRect(editableFinder);
    expect((inputRect.center.dy - containerRect.center.dy).abs(), lessThan(0.5));
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));

    // 输入态与空态装饰器近似等高（容差 2px：输入态多出聚焦描边）：
    // 高度接近才能让 textAlignVertical.center 在空态同样居中光标行
    final typedDecoratorHeight = tester.getSize(inputDecoratorFinder).height;
    expect(typedDecoratorHeight, closeTo(emptyDecoratorHeight, 2.0));

    // 3. 清除按钮测试
    final closeBtnFinder = find.byIcon(Icons.close_rounded);
    expect(closeBtnFinder, findsOneWidget);
    await tester.tap(closeBtnFinder);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text('搜索歌曲、歌手、专辑、歌单'), findsOneWidget);

    // 4. 输入长文字测试
    await tester.enterText(textFieldFinder, '这是一段非常长非常长的搜索测试文字用于验证字体底部不被截断gyjp');
    await tester.pumpAndSettle();
    expect(renderEditable!.size.height, greaterThanOrEqualTo(renderEditable!.preferredLineHeight));
  });
}
