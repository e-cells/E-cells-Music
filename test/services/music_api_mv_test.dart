import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

/// `MusicApi` MV 域方法的请求参数与响应解析测试。
class _FakeMvApiClient implements ApiClientInterface {
  _FakeMvApiClient(this.routes);

  /// path → (query, response) 的路由表；未命中路径抛错。
  final Map<String, dynamic Function(Map<String, Object?> query)> routes;

  Map<String, Object?>? lastQuery;
  String? lastPath;

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
    lastPath = path;
    lastQuery = query;
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

Song _song(String id, {String title = '歌名', String? albumAudioId}) {
  return Song(
    id: id,
    title: title,
    artist: '歌手',
    hash: 'SONGHASH$id',
    albumAudioId: albumAudioId,
  );
}

void main() {
  group('MusicApi.searchMvs', () {
    test('按 mv 类型发出请求并解析 lists', () async {
      final client = _FakeMvApiClient({
        '/search': (query) {
          expect(query['type'], 'mv');
          expect(query['keywords'], '周杰伦');
          return {
            'total': 20,
            'lists': [
              {
                'MvID': '11517822',
                'MvName': '晴天',
                'SingerName': '周杰伦',
                'MvHash': 'AAA',
                'Duration': 269,
              },
              // 无 hash 的脏数据被过滤。
              {'MvID': '2', 'MvName': '坏数据'},
            ],
          };
        },
      });
      final api = MusicApi(client);
      final mvs = await api.searchMvs('周杰伦');
      expect(client.lastPath, '/search');
      expect(mvs.length, 1);
      expect(mvs.single.title, '晴天');
      expect(mvs.single.hash, 'AAA');
    });
  });

  group('MusicApi.mvUrl', () {
    test('透传 hash 并解析直链', () async {
      final client = _FakeMvApiClient({
        '/video/url': (query) {
          expect(query['hash'], 'ABC123');
          return {
            'data': {
              'abc123': {
                'downurl': 'http://cdn/mv.mp4',
                'backupdownurl': [],
              },
            },
          };
        },
      });
      final api = MusicApi(client);
      final url = await api.mvUrl('ABC123');
      expect(url.urls.single, 'http://cdn/mv.mp4');
    });
  });

  group('MusicApi.songsMv', () {
    test('批量按 30 个一批分组请求并返回 id→MvInfo 映射', () async {
      final batches = <String>[];
      final client = _FakeMvApiClient({
        '/kmr/audio/mv': (query) {
          final ids = (query['album_audio_id'] as String).split(',');
          batches.add(query['album_audio_id'] as String);
          // 实测契约：data 按请求顺序逐 id 返回内层数组，
          // 无 MV 的 id 对应空对象。
          return {
            'status': 1,
            'error_code': 0,
            'data': [
              for (final id in ids)
                if (id != 'noMv')
                  [
                    {
                      'album_audio_id': id,
                      'video_id': 100,
                      'mv_name': 'MV$id',
                      'singer': '歌手',
                      'h264': {'sd_hash': 'MV$id'},
                    },
                  ]
                else
                  <String, dynamic>{},
            ],
          };
        },
      });
      final api = MusicApi(client);
      // 31 首：第一批 30 + 第二批 1；其中 'noMv' 无 MV。
      final songs = [
        for (var i = 0; i < 30; i++) _song('song$i'),
        _song('noMv'),
      ];
      final result = await api.songsMv(songs);
      expect(batches.length, 2);
      expect(result.length, 30);
      expect(result['song5']!.hash, 'MVsong5');
      expect(result.containsKey('noMv'), isFalse);
    });

    test('同曲多版本 MV 取 is_recommend 优先', () async {
      final client = _FakeMvApiClient({
        '/kmr/audio/mv': (query) {
          return {
            'data': [
              [
                {
                  'album_audio_id': 'a1',
                  'video_id': 2,
                  'mv_name': '现场版',
                  'h264': {'sd_hash': 'LIVE'},
                },
                {
                  'album_audio_id': 'a1',
                  'video_id': 1,
                  'mv_name': '官方版',
                  'is_recommend': 1,
                  'h264': {'sd_hash': 'OFFICIAL'},
                },
              ],
              // 无 MV 的 id：空对象。
              <String, dynamic>{},
            ],
          };
        },
      });
      final api = MusicApi(client);
      final result = await api.songsMv([_song('a1'), _song('zz')]);
      expect(result.length, 1);
      expect(result['a1']!.title, '官方版');
      expect(result['a1']!.hash, 'OFFICIAL');
    });

    test('单批失败不吞掉其他批次', () async {
      var callCount = 0;
      final client = _FakeMvApiClient({
        '/kmr/audio/mv': (query) {
          callCount++;
          if (callCount == 1) {
            throw Exception('network down');
          }
          return {
            'data': [
              [
                {
                  'album_audio_id': 'b2',
                  'h264': {'sd_hash': 'MVB2'},
                },
              ],
            ],
          };
        },
      });
      final api = MusicApi(client);
      final result = await api.songsMv([
        for (var i = 0; i < 30; i++) _song('a$i'), // 第一批（失败）
        _song('b2'), // 第二批（成功）
      ]);
      expect(result.length, 1);
      expect(result['b2']!.hash, 'MVB2');
    });
  });

  group('MusicApi.artistMvs / mvFeed', () {
    test('artistMvs 透传 tag 并走通用列表解析', () async {
      final client = _FakeMvApiClient({
        '/artist/videos': (query) {
          expect(query['id'], '6539');
          expect(query['tag'], 'official');
          return {
            'data': {
              'lists': [
                {'video_id': '1', 'hash': 'A', 'title': '官方MV'},
              ],
            },
          };
        },
      });
      final api = MusicApi(client);
      final mvs = await api.artistMvs('6539', tag: 'official');
      expect(mvs.single.title, '官方MV');
    });

    test('mvFeed 解析场景视频列表', () async {
      final client = _FakeMvApiClient({
        '/scene/video/list': (query) {
          expect(query['pagesize'], 12);
          return {
            'data': [
              {'video_id': '9', 'hash': 'S1', 'title': '场景MV'},
            ],
          };
        },
      });
      final api = MusicApi(client);
      final mvs = await api.mvFeed(pageSize: 12);
      expect(mvs.single.title, '场景MV');
    });
  });

  group('MusicApi.searchSongForMv（MV 反查歌曲兜底）', () {
    Map<String, dynamic> songJson(String hash, String title) => {
      'MixSongID': hash,
      'FileHash': hash,
      'OriSongName': title,
      'SingerName': '林俊杰',
    };

    test('按「标题 歌手」搜歌并取标题归一化最佳匹配', () async {
      final client = _FakeMvApiClient({
        '/search': (query) {
          expect(query['type'], 'song');
          expect(query['keywords'], '修炼爱情 林俊杰');
          return {
            'songs': [
              // 首位不是同一首歌：不应被误选。
              songJson('OTHER', '另一个自己'),
              songJson('RIGHT', '修炼爱情'),
            ],
          };
        },
      });
      final api = MusicApi(client);
      final song = await api.searchSongForMv(
        MvInfo(id: '1', hash: 'MV', title: '修炼爱情', artist: '林俊杰'),
      );
      expect(song, isNotNull);
      expect(song!.hash, 'RIGHT');
    });

    test('MV 标题的括号后缀与 MV 字样被归一化吸收', () async {
      final client = _FakeMvApiClient({
        '/search': (query) {
          expect(query['keywords'], '晴天MV 周杰伦');
          return {
            'songs': [songJson('QING', '晴天（Live）')],
          };
        },
      });
      final api = MusicApi(client);
      final song = await api.searchSongForMv(
        MvInfo(id: '1', hash: 'MV', title: '晴天MV', artist: '周杰伦'),
      );
      expect(song?.hash, 'QING');
    });

    test('未知艺人时仅以标题搜索；搜不到返回 null', () async {
      final client = _FakeMvApiClient({
        '/search': (query) {
          expect(query['keywords'], '冷门视频');
          return {'songs': <dynamic>[]};
        },
      });
      final api = MusicApi(client);
      final song = await api.searchSongForMv(
        MvInfo(id: '1', hash: 'MV', title: '冷门视频', artist: '未知艺人'),
      );
      expect(song, isNull);
    });
  });
}
