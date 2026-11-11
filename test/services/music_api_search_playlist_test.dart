import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// `MusicApi.searchPlaylists` 的响应解析与过滤测试。
///
/// Rust 代理对 `/v1/search/special` 的响应做 data 提升（transport 层），
/// Dart 侧拿到的是 `{pagesize, page, total, lists: [...], status, ...}`。
class _FakeSearchApiClient implements ApiClientInterface {
  _FakeSearchApiClient(this.response);

  final dynamic response;
  Map<String, Object?>? lastQuery;

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
    if (path == '/search') {
      lastQuery = query;
      return response;
    }
    throw ArgumentError('Unexpected path: $path');
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('MusicApi.searchPlaylists', () {
    test('请求按 special 类型发出并解析 data 提升后的 lists', () async {
      final client = _FakeSearchApiClient({
        'pagesize': 30,
        'page': 1,
        'total': 480,
        'status': 1,
        'lists': [
          {
            'specialid': 6409645,
            'specialname': '周杰伦精选',
            'gid': 'collection_3_1_2_0',
            'song_count': 194,
            'nickname': '酷狗推荐',
            'total_play_count': '38044469',
            'img': 'http://imge.kugou.com/soft/collection/150/a.jpg',
          },
          // 无 gid：详情接口只认 global_collection_id，必须被过滤。
          {
            'specialid': 123,
            'specialname': '无全局 ID 的条目',
            'gid': '',
          },
        ],
      });
      final api = MusicApi(client);

      final results = await api.searchPlaylists('周杰伦');

      // 酷狗搜索侧的"歌单"类型名是 special，不是 playlist。
      expect(client.lastQuery, containsPair('type', 'special'));
      expect(client.lastQuery, containsPair('keywords', '周杰伦'));
      expect(results, hasLength(1));
      expect(results.first.gid, 'collection_3_1_2_0');
      expect(results.first.name, '周杰伦精选');
      expect(results.first.playCount, 38044469);
    });

    test('响应是裸数组（网关兼容形态）时同样解析', () async {
      final client = _FakeSearchApiClient([
        {'specialname': 'B', 'gid': 'collection_9', 'song_count': 5},
      ]);
      final api = MusicApi(client);

      final results = await api.searchPlaylists('k');

      expect(results, hasLength(1));
      expect(results.first.gid, 'collection_9');
    });

    test('空 lists 返回空列表而非抛错', () async {
      final client = _FakeSearchApiClient({'lists': <dynamic>[]});
      final api = MusicApi(client);

      expect(await api.searchPlaylists('不存在的词'), isEmpty);
    });
  });
}
