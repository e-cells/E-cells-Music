import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// `SearchPlaylistResult` 的字段契约测试。
///
/// 契约来源是仓库根目录的 `api.json`（SearchPlaylistItem）与
/// complexsearch.kugou.com `/v1/search/special` 实测响应：
/// `gid`（歌单全局 ID）、`specialid`、`specialname`、`song_count`、
/// `nickname`、`play_count` / `total_play_count`（字符串数字）、`img`。
void main() {
  group('SearchPlaylistResult.fromJson 字段契约', () {
    test('按 /v1/search/special 实测形状解析出全部展示字段', () {
      // 实测样本（2026-11 complexsearch）：total_play_count/play_count
      // 为字符串数字，specialid 为整数，img 是完整 URL。
      final playlist = SearchPlaylistResult.fromJson({
        'specialid': 6409645,
        'song_count': 194,
        'specialname': '周杰伦出道26周年｜播放属于我们的青春记忆',
        'img': 'http://imge.kugou.com/soft/collection/150/20261105/abc.jpg',
        'publish_time': '2023-01-10 19:31:00',
        'suid': '2132029040',
        'nickname': '酷狗推荐',
        'play_count': '423790',
        'total_play_count': '38044469',
        'gid': 'collection_3_2132029040_287_0',
      });

      expect(playlist.gid, 'collection_3_2132029040_287_0');
      expect(playlist.specialId, '6409645');
      expect(playlist.name, '周杰伦出道26周年｜播放属于我们的青春记忆');
      expect(playlist.songCount, 194);
      expect(playlist.creatorName, '酷狗推荐');
      // 回归点：播放量取 total_play_count（总量）而非 play_count（日量）。
      expect(playlist.playCount, 38044469);
      expect(
        playlist.coverUrl,
        'http://imge.kugou.com/soft/collection/150/20261105/abc.jpg',
      );
      expect(playlist.publishTime, '2023-01-10 19:31:00');
    });

    test('img 带 {size} 占位符时归一化为具体尺寸，否则是死链', () {
      final playlist = SearchPlaylistResult.fromJson({
        'gid': 'collection_1',
        'specialname': 'A',
        'img': 'https://imge.kugou.com/collection/{size}/a.jpg',
      });
      expect(playlist.coverUrl, contains('/480/'));
      expect(playlist.coverUrl, isNot(contains('{size}')));
    });

    test('字段缺失时不抛异常，给出稳定默认值', () {
      final playlist = SearchPlaylistResult.fromJson(const {});
      expect(playlist.gid, '');
      expect(playlist.name, '未知歌单');
      expect(playlist.songCount, 0);
      expect(playlist.playCount, 0);
      expect(playlist.creatorName, '');
      expect(playlist.coverUrl, isNull);
    });

    test('toPlaylistSummary 携带 sourceGlobalId，不被误判为收藏专辑', () {
      // 回归点：不填 sourceGlobalId 时 isCollectedAlbum 会把搜索歌单
      // 误判成专辑条目，详情页走专辑加载分支导致曲目恒为空。
      final summary = SearchPlaylistResult.fromJson({
        'gid': 'collection_3_1_2_0',
        'specialname': '开车必备',
        'nickname': '某人',
        'song_count': 30,
      }).toPlaylistSummary();

      expect(summary.id, 'collection_3_1_2_0');
      expect(summary.title, '开车必备');
      expect(summary.subtitle, '某人');
      expect(summary.songCount, 30);
      expect(summary.sourceGlobalId, 'collection_3_1_2_0');
      expect(summary.isCollectedAlbum, isFalse);
      expect(summary.hasCollectionSource, isTrue);
    });
  });
}
