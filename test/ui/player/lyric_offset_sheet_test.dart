// 「调整歌词进度」UI：移动端详情弹层入口与底部弹层、PC 锚定弹层、
// PC 两个入口（封面开关列 `调` / 歌词列表右键）。
//
// 面板形态对齐酷狗「调整歌词进度」极简三键：一行三枚圆角方钮
// （`− 0.5 秒` / `重置` / `+ 0.5 秒`，标签在钮下），仅已调偏移时亮一行短状态；
// 状态与重置可用态自监听 PlayerController。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/player_logic.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/desktop_lyric_list.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';
import 'package:shiyin_music/ui/player/lyric_display_mode.dart';
import 'package:shiyin_music/ui/player/lyric_offset_sheet.dart';
import 'package:shiyin_music/ui/player/player_top_bar.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Duration lyricOffset = Duration.zero;

  int adjustCalls = 0;
  int resetCalls = 0;
  final ValueNotifier<Duration> _positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  @override
  bool isPlaying = false;

  @override
  bool get isScrubbing => false;

  @override
  bool get isPreparing => false;

  @override
  Duration get smoothPosition => _positionListenable.value;

  @override
  Duration get lyricPosition => smoothPosition + lyricOffset;

  @override
  ValueNotifier<Duration> get positionListenable => _positionListenable;

  @override
  List<LyricLine> lyrics = const [
    LyricLine(time: Duration.zero, text: '第一句'),
    LyricLine(time: Duration(seconds: 5), text: '第二句'),
  ];

  @override
  int get activeLyricIndex => 0;

  @override
  Song? currentSong = const Song(
    id: 's1',
    hash: 'h1',
    title: '单身情歌',
    artist: '林志炫',
  );

  @override
  bool get hasLyricOffset => lyricOffset != Duration.zero;

  @override
  String get lyricOffsetLabel => PlayerLyricOffsetLogic.describe(lyricOffset);

  @override
  Future<void> adjustLyricOffset(Duration delta) async {
    adjustCalls++;
    lyricOffset += delta;
    notifyListeners();
  }

  @override
  Future<void> resetLyricOffset() async {
    resetCalls++;
    lyricOffset = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> seekToAndPlay(Duration position) async {}

  // 详情弹层（showPlayerMoreSheet）构建时要读的档位标签。
  @override
  String get playbackSpeedLabel => '1x';

  @override
  AudioQuality get audioQuality => AudioQuality.standard;

  @override
  bool get isAudioEffectsSupported => false;

  @override
  bool get isDesktopLyricsSupported => false;

  @override
  bool get desktopLyricsEnabled => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 详情弹层只把 auth 透传给「添加到歌单」的点击回调，构建期不读它。
class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 真机形态：音效（均衡器）与桌面歌词都可用 → 宫格候选 7 个（超过 6 宫封顶）。
class _FakePlayerFull extends _FakePlayerController {
  @override
  bool get isAudioEffectsSupported => true;

  @override
  bool get isDesktopLyricsSupported => true;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 弹层里三键的图标 → 稳定命中（标签 `0.5 秒` 有两处，靠图标区分）。
const _addIcon = Icons.add_rounded;
const _minusIcon = Icons.remove_rounded;
const _resetIcon = Icons.restart_alt_rounded;

/// 状态行：仅在已调偏移时出现，短读数 + 记忆提示。
String _status(Duration offset) =>
    '${PlayerLyricOffsetLogic.formatSigned(offset)} · 已为本首歌记忆';

void main() {
  group('LyricOffsetControl', () {
    testWidgets('三键与状态行：点按即改偏移并即时刷新状态', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(_host(LyricOffsetControl(player: player)));

      // 默认态极简：状态行占位但不可见（面板高度恒定，PC 锚定弹层
      // 打开瞬间量的尺寸在首次点 ± 后依然成立，底部标签不被挤出）。
      Visibility statusRow() =>
          tester.widget<Visibility>(find.byType(Visibility));
      expect(find.textContaining('已为本首歌记忆'), findsOneWidget);
      expect(statusRow().visible, isFalse);
      expect(find.text('0.5 秒'), findsNWidgets(2));
      expect(find.text('重置'), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pump();
      expect(player.lyricOffset, kLyricOffsetStep);
      expect(player.adjustCalls, 1);
      expect(find.text(_status(kLyricOffsetStep)), findsOneWidget);
      expect(statusRow().visible, isTrue);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pump();
      expect(player.lyricOffset, const Duration(seconds: 1));
      expect(
        find.text(_status(const Duration(seconds: 1))),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(_minusIcon));
      await tester.pump();
      expect(player.lyricOffset, kLyricOffsetStep);

      await tester.tap(find.byIcon(_resetIcon));
      await tester.pump();
      expect(player.resetCalls, 1);
      expect(player.lyricOffset, Duration.zero);
      expect(statusRow().visible, isFalse);
    });

    testWidgets('无偏移时重置不可用（点了也不触发 reset）', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(_host(LyricOffsetControl(player: player)));

      await tester.tap(find.byIcon(_resetIcon));
      await tester.pump();
      expect(player.resetCalls, 0);
      expect(player.lyricOffset, Duration.zero);
    });
  });

  group('移动端详情弹层入口', () {
    testWidgets('详情里有「歌词进度」入口，点开即打开调整弹层并带出当前偏移', (tester) async {
      // 形态判定跟着宿主 OS 走（测试跑在 Windows 上恒为桌面），这里显式
      // 覆盖成移动形态，走的才是手机上的底部弹层分支。
      debugDesktopFormFactorOverride = false;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      final player = _FakePlayerController()
        // 已经调过的歌：详情项副标题直接显示当前偏移（"已调整"可见）。
        ..lyricOffset = kLyricOffsetStep;
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayerMoreSheet(
                context: context,
                player: player,
                auth: auth,
                song: player.currentSong!,
              ),
              child: const Text('more'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('more'));
      await tester.pumpAndSettle();

      // 列表里的「歌词进度」行，副标题是短读数（与「1x」/「320K」同量级）。
      // 行在小视口下可能首屏外：先滚出来再点（真机上用户也是上滑后点）。
      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.text('+0.5 秒'), findsOneWidget);
      await tester.ensureVisible(find.text('歌词进度'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('歌词进度'));
      await tester.pumpAndSettle();

      // 详情弹层关闭（详情独有的「倍速」入口消失）、调整弹层打开，且是同一份状态。
      // 注意：底层页面仍在（「more」还在树里），只断言详情内容已走、弹层已来。
      expect(find.text('倍速'), findsNothing, reason: '详情弹层应已关闭');
      expect(find.text('调整歌词进度'), findsOneWidget);
      expect(find.text(_status(kLyricOffsetStep)), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, const Duration(seconds: 1));
      expect(
        find.text(_status(const Duration(seconds: 1))),
        findsOneWidget,
      );
    });

    testWidgets('顶部只留 4 宫：其余入口全部平铺为菜单行', (tester) async {
      debugDesktopFormFactorOverride = false;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      // 10 个入口（4 宫格 + 6 平铺）：宫格固定为添加到歌单/倍速/音质/
      // 歌曲信息；其余 6 个（观看MV/高潮/音效/定时/歌词进度/桌面歌词）
      // 平铺成 ListTile。
      final player = _FakePlayerFull();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayerMoreSheet(
                context: context,
                player: player,
                auth: auth,
                song: player.currentSong!,
              ),
              child: const Text('more'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('more'));
      await tester.pumpAndSettle();

      // 10 个入口全部可见：宫格 4 个（添加到歌单/倍速/音质/歌曲信息）+
      // 平铺 6 行（观看MV/高潮/音效/定时/歌词进度/桌面歌词）。
      expect(find.text('添加到歌单'), findsOneWidget);
      expect(find.text('歌曲信息'), findsOneWidget);
      expect(find.text('观看 MV'), findsOneWidget);
      expect(find.text('高潮'), findsOneWidget);
      expect(find.text('音效'), findsOneWidget);
      expect(find.text('定时'), findsOneWidget);
      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.text('桌面歌词'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(6));
    });

    testWidgets('无音效时宫格仍为固定 4 位，高潮/定时下沉到列表', (tester) async {
      debugDesktopFormFactorOverride = false;
      addTearDown(() => debugDesktopFormFactorOverride = null);

      // 无音效无桌面歌词：宫格仍是添加到歌单/倍速/音质/歌曲信息，
      // 观看MV/高潮/定时/歌词进度平铺 4 行。
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayerMoreSheet(
                context: context,
                player: player,
                auth: auth,
                song: player.currentSong!,
              ),
              child: const Text('more'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('more'));
      await tester.pumpAndSettle();

      expect(find.text('添加到歌单'), findsOneWidget);
      expect(find.text('观看 MV'), findsOneWidget);
      expect(find.text('高潮'), findsOneWidget);
      expect(find.text('定时'), findsOneWidget);
      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.text('歌曲信息'), findsOneWidget);
      // 添加到歌单与歌曲信息进了宫格而非列表：
      // 列表只剩观看MV/高潮/定时/歌词进度 4 行。
      expect(find.byType(ListTile), findsNWidgets(4));
    });
  });

  group('showLyricOffsetSheet（移动端弹层）', () {
    testWidgets('标题、歌曲信息与步进键齐备，调整后状态同步', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyricOffsetSheet(
                context,
                player: player,
                song: player.currentSong,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('调整歌词进度'), findsOneWidget);
      expect(find.text('林志炫 · 单身情歌'), findsOneWidget);
      expect(find.byIcon(_minusIcon), findsOneWidget);
      expect(find.byIcon(_resetIcon), findsOneWidget);
      expect(find.byIcon(_addIcon), findsOneWidget);
      expect(find.text('重置'), findsOneWidget);

      await tester.tap(find.byIcon(_addIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, kLyricOffsetStep);
      expect(find.text(_status(kLyricOffsetStep)), findsOneWidget);
    });
  });

  group('showLyricOffsetMenu（PC 锚定弹层）', () {
    testWidgets('锚定面板标题「歌词进度」+ 步进键，调整即时生效', (tester) async {
      final player = _FakePlayerController();
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyricOffsetMenu(
                context,
                player: player,
                anchor: const Offset(240, 180),
              ),
              child: const Text('menu'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();

      expect(find.text('歌词进度'), findsOneWidget);
      expect(find.byIcon(_addIcon), findsOneWidget);

      await tester.tap(find.byIcon(_minusIcon));
      await tester.pumpAndSettle();
      expect(player.lyricOffset, -kLyricOffsetStep);
      expect(
        find.text(_status(-kLyricOffsetStep)),
        findsOneWidget,
      );
    });
  });

  group('PC 入口', () {
    testWidgets('封面开关列的 [调] 始终可见，点击回调带上按钮锚点', (tester) async {
      Offset? anchor;
      await tester.pumpWidget(
        _host(
          Center(
            child: LandscapeLyricToggleColumn(
              showTranslation: false,
              showRomanization: false,
              hasTranslation: false,
              hasRomanization: false,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onOpenLyricOffset: (position) => anchor = position,
            ),
          ),
        ),
      );

      // 这首歌既没翻译也没音译，[调] 仍然必须渲染（它是功能入口不是状态开关）。
      expect(find.text('调'), findsOneWidget);
      expect(find.text('译'), findsNothing);

      await tester.tap(find.text('调'));
      await tester.pump();
      expect(anchor, isNotNull);
      expect(anchor!.dx.isFinite && anchor!.dy.isFinite, isTrue);
    });

    testWidgets('歌词列表右键在指针处打开进度面板', (tester) async {
      final player = _FakePlayerController();
      Offset? tappedAt;

      await tester.pumpWidget(
        _host(
          DesktopLyricList(
            player: player,
            songHash: 'h1',
            lyrics: player.lyrics,
            activeIndex: 0,
            displayMode: LyricDisplayMode.lyricsOnly,
            lyricScale: 1.0,
            onSecondaryTapLine: (position) => tappedAt = position,
          ),
        ),
      );
      await tester.pump();

      final target = tester.getCenter(find.text('第二句'));
      await tester.tap(find.text('第二句'), buttons: kSecondaryMouseButton);
      await tester.pump();

      expect(tappedAt, isNotNull);
      expect((tappedAt! - target).distance, lessThan(24));
    });
  });
}
