import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/controllers/mv_player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/widgets/mv_mini_bar.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

/// `MvPlayerController` 来源歌曲映射（「切换为音频」的数据底座）与
/// 「以 MV 播放」队列语义测试。
///
/// 单测环境无 video_player 实现：fake `/video/url` 返回不可播数据，
/// 起播加载链走「ApiException 被内部吞掉」路径，聚焦队列/映射逻辑。
class _FakeMvApiClient implements ApiClientInterface {
  _FakeMvApiClient(this.routes);

  final Map<String, dynamic Function(Map<String, Object?> query)> routes;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async {
    final handler = routes[path];
    if (handler == null) {
      throw ArgumentError('Unexpected path: $path');
    }
    return handler(query);
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async => throw UnimplementedError();

  @override
  void close() {}
}

Song _song(String id, {String? albumAudioId, SongSource? source}) {
  return Song(
    id: id,
    title: '歌名$id',
    artist: '歌手',
    hash: 'SONGHASH$id',
    albumAudioId: albumAudioId,
    source: source ?? SongSource.kugou,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('playSongsAsMvQueue 来源歌曲映射', () {
    test('匹配后可按 albumAudioId 找回来源歌曲与原队列', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _FakeMvApiClient({
        '/kmr/audio/mv': (query) {
          // 实测契约：data 按请求顺序逐 id 返回内层数组，清晰度 hash
          // 在 h264 对象里按档展开（sd_hash 等）。
          return {
            'status': 1,
            'error_code': 0,
            'data': [
              [
                {
                  'album_audio_id': 'a1',
                  'video_id': 101,
                  'mv_name': '歌名s1',
                  'singer': '歌手',
                  'duration': 213000,
                  'h264': {'sd_hash': 'MV1', 'hd_hash': 'MV1HD'},
                },
              ],
              [
                {
                  'album_audio_id': 'a2',
                  'video_id': 102,
                  'mv_name': '歌名s2',
                  'h264': {'sd_hash': 'MV2'},
                },
              ],
            ],
          };
        },
        // 单测无 video_player：返回不可播数据让起播加载链静默失败
        // （ApiException 被内部吞掉），聚焦队列/映射逻辑。
        '/video/url': (query) => {'data': <String, dynamic>{}},
      });
      final controller = MvPlayerController(MusicApi(client));
      // 预置一个「旧会话」MV：新一批「以 MV 播放」应整队替换它，
      // 而不是追加在旧队列后面继续播旧的。
      controller.currentMv = MvInfo(
        id: 'seed',
        hash: 'SEED',
        title: '种子',
        artist: '歌手',
      );
      var firstPlayCalled = false;

      final count = await controller.playSongsAsMvQueue([
        _song('s1', albumAudioId: 'a1'),
        _song('s2', albumAudioId: 'a2'),
        _song('local', source: SongSource.local),
      ], onFirstPlay: () => firstPlayCalled = true);

      expect(count, 2, reason: '本地源歌曲被过滤，匹配到 2 个 MV');
      // 首批命中即整队替换旧会话（种子 MV 不在队列里）。
      expect(controller.queue.length, 2, reason: '旧种子 MV 被整队替换');
      expect(
        controller.queue.map((mv) => mv.hash),
        containsAll(['MV1', 'MV2']),
      );
      expect(firstPlayCalled, isTrue);

      final mv1 = controller.queue.firstWhere((mv) => mv.hash == 'MV1');
      expect(mv1.albumAudioId, 'a1');
      expect(controller.sourceSongFor(mv1)?.hash, 'SONGHASHs1');

      // 来源队列 = 原酷狗候选（不含本地源歌曲），且包含对应歌曲。
      final source = controller.sourceSongFor(mv1)!;
      expect(controller.sourceQueueFor(source)?.length, 2);
      // 非来源歌曲（如兜底搜索出的歌）拿不到原队列 → 调用方退化单曲播放。
      expect(controller.sourceQueueFor(_song('zz')), isNull);

      // 无 albumAudioId 的 MV（搜索直开等）没有来源映射。
      expect(
        controller.sourceSongFor(
          MvInfo(id: 'x', hash: 'X', title: 't', artist: 'a'),
        ),
        isNull,
      );

      // stop 结束 MV 会话：映射作废，避免误用旧队列切回音频。
      await controller.stop();
      expect(controller.sourceSongFor(mv1), isNull);
      controller.dispose();
    });

    test('onFirstPlay 在首个 MV 起播后回调一次', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _FakeMvApiClient({
        '/kmr/audio/mv': (query) {
          final ids = (query['album_audio_id'] as String).split(',');
          return {
            'status': 1,
            'error_code': 0,
            'data': [
              for (final id in ids)
                [
                  {
                    'album_audio_id': id,
                    'video_id': 100,
                    'h264': {'sd_hash': 'MV$id'},
                  },
                ],
            ],
          };
        },
        // 单测无 video_player：返回不可播数据让加载链走「失败被内部
        // 吞掉」路径（ApiException），验证 onFirstPlay 语义不受影响。
        '/video/url': (query) => {'data': <String, dynamic>{}},
      });
      final controller = MvPlayerController(MusicApi(client));
      // 不预置 currentMv：首批命中会走 playMv → _startMv。
      // 单测无 video_player，加载链在解析播放地址一步失败即被内部
      // 吞掉（连续失败预算兜底），不影响 onFirstPlay 回调语义。
      var calls = 0;
      await controller.playSongsAsMvQueue(
        [_song('a1', albumAudioId: 'a1')],
        onFirstPlay: () => calls++,
      );
      expect(calls, 1);
      expect(controller.currentMv?.hash, 'MVa1');
      expect(controller.hasActiveSession, isTrue);
      controller.dispose();
    });

    testWidgets(
      'MvPlayerOverlayHost 在 MaterialApp.builder 内点击迷你小窗可正常打开 MvPlayerPage',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final client = _FakeMvApiClient({
          '/video/detail': (query) => {'data': <String, dynamic>{}},
          '/video/url': (query) => {'data': <String, dynamic>{}},
          '/video/privilege': (query) => {'data': <dynamic>[]},
        });
        final controller = MvPlayerController(MusicApi(client));
        await controller.playMv(
          MvInfo(
            id: '11517822',
            hash: '3B5EE16299F703AEB0E5C28CB152EDF0',
            title: '晴天',
            artist: '周杰伦',
          ),
        );
        expect(controller.hasActiveSession, isTrue);
        expect(controller.isPlayerPageVisible, isFalse);

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: Toast.navigatorKey,
            builder: (context, child) => MvPlayerOverlayHost(
              mvPlayer: controller,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Center(child: Text('Home'))),
          ),
        );
        await tester.pump();

        // 悬浮小窗可见，显示 MV 标题
        expect(find.byType(MvMiniBar), findsOneWidget);
        expect(find.text('晴天'), findsOneWidget);

        // 点击悬浮小窗进入 MvPlayerPage（不抛 Navigator 异常）
        await tester.tap(find.text('晴天'));
        await tester.pumpAndSettle();

        expect(controller.isPlayerPageVisible, isTrue);
        controller.dispose();
      },
    );
  });
}
