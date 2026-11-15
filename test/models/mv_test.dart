import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('MvInfo.fromSearch（搜索 type=mv 结果）', () {
    test('解析 MvID/MvName/SingerName/MvHash/Duration/PublishDate/Pic/MixSongID', () {
      final mv = MvInfo.fromSearch({
        'MvID': '11517822',
        'MvName': '晴天',
        'SingerName': '周杰伦',
        'MvHash': '3B5EE16299F703AEB0E5C28CB152EDF0',
        'Duration': 269,
        'PublishDate': '2003-07-31',
        'Pic': '20200620174316264397.jpg',
        'MixSongID': 32155307,
      });
      expect(mv.id, '11517822');
      expect(mv.hash, '3B5EE16299F703AEB0E5C28CB152EDF0');
      expect(mv.title, '晴天');
      expect(mv.artist, '周杰伦');
      expect(mv.duration, const Duration(seconds: 269));
      expect(mv.publishDate, '2003-07-31');
      expect(
        mv.coverUrl,
        'http://imge.kugou.com/mvhdpic/480/20200620/20200620174316264397.jpg',
      );
      expect(mv.albumAudioId, '32155307');
      expect(mv.isPlayable, isTrue);
      expect(mv.key, '11517822');
    });

    test('FileName/FileHash 备选字段链', () {
      final mv = MvInfo.fromSearch({
        'MvID': '1',
        'FileName': ' 林俊杰 - 修炼爱情 ',
        'FileHash': 'ABCDEF',
        'SingerName': '林俊杰',
      });
      expect(mv.title, '林俊杰 - 修炼爱情');
      expect(mv.hash, 'ABCDEF');
    });

    test('无 hash 的条目不可播放', () {
      final mv = MvInfo.fromSearch({'MvID': '9', 'MvName': 'x'});
      expect(mv.isPlayable, isFalse);
    });
  });

  group('MvInfo.fromKmrAudioMv（歌曲反查，实测契约）', () {
    // 抓包自 openapi /kmr/v1/audio/mv fields=h264,h265 的真实响应条目：
    // h264/h265 为按清晰度展开的 hash 对象，duration 毫秒，数字 id。
    test('清晰度 hash 对象归并三档：fhd→超清、hd/qhd→高清、sd/ld→标清', () {
      final mv = MvInfo.fromKmrAudioMv({
        'album_audio_id': 32148029,
        'video_id': 88465,
        'mv_name': '修炼爱情',
        'singer': '林俊杰',
        'duration': 353764,
        'thumb': 'http://imge.kugou.com/mvthumb/{size}/cb/99/x.jpg',
        'is_recommend': 1,
        'h264': {
          'sd_hash': 'SDH264',
          'hd_hash': 'HDH264',
          'fhd_hash': 'FHDH264',
          'qhd_hash': 'QHDH264',
          'ld_hash': 'LDH264',
        },
        'h265': {
          'sd_hash': 'SDH265',
          'hd_hash': 'HDH265',
        },
      });
      expect(mv, isNotNull);
      // 数字字段转字符串：来源映射靠 albumAudioId 关联回歌曲。
      expect(mv!.albumAudioId, '32148029');
      expect(mv.id, '88465');
      expect(mv.title, '修炼爱情');
      expect(mv.artist, '林俊杰');
      expect(mv.duration, const Duration(milliseconds: 353764));
      expect(mv.coverUrl, 'http://imge.kugou.com/mvthumb/480/cb/99/x.jpg');
      // 同档位 h264 优先，h265 只补缺失档。
      expect(mv.resolutionHashes['sd'], 'SDH264');
      expect(mv.resolutionHashes['hd'], 'HDH264');
      expect(mv.resolutionHashes['shd'], 'FHDH264');
      // 默认 hash 取标清（与搜索 MvHash 同档）。
      expect(mv.hash, 'SDH264');
    });

    test('h264 缺档时由 h265 补位', () {
      final mv = MvInfo.fromKmrAudioMv({
        'album_audio_id': 1,
        'h264': {'sd_hash': 'SDH264'},
        'h265': {'hd_hash': 'HDH265'},
      });
      expect(mv!.resolutionHashes['sd'], 'SDH264');
      expect(mv.resolutionHashes['hd'], 'HDH265');
    });

    test('无任何清晰度 hash 时返回 null（无 MV）', () {
      final mv = MvInfo.fromKmrAudioMv({'album_audio_id': 1});
      expect(mv, isNull);
    });
  });

  group('MvQuality.fromApi / resolvePlayHash', () {
    test('档位标记宽容匹配', () {
      expect(MvQuality.fromApi('shd'), MvQuality.ultra);
      expect(MvQuality.fromApi('UHD'), MvQuality.ultra);
      expect(MvQuality.fromApi('hd'), MvQuality.high);
      expect(MvQuality.fromApi('1080'), MvQuality.ultra);
      expect(MvQuality.fromApi('720'), MvQuality.high);
      expect(MvQuality.fromApi('480'), MvQuality.standard);
      expect(MvQuality.fromApi(null), isNull);
    });

    test('无分档时直接用默认 hash', () {
      final mv = MvInfo(
        id: '1',
        hash: 'DEFAULT',
        title: 't',
        artist: 'a',
      );
      expect(resolvePlayHash(mv, MvQuality.ultra), 'DEFAULT');
    });

    test('期望档位缺失时沿降级链回退', () {
      final mv = MvInfo(
        id: '1',
        hash: 'DEFAULT',
        title: 't',
        artist: 'a',
        resolutionHashes: {'sd': 'SDHASH', 'hd': 'HDHASH'},
      );
      // 超清缺失 → 高清。
      expect(resolvePlayHash(mv, MvQuality.ultra), 'HDHASH');
      // 高清命中。
      expect(resolvePlayHash(mv, MvQuality.high), 'HDHASH');
      // 标清缺失时向上回退到高清（宁高清不失败）。
      expect(resolvePlayHash(mv, MvQuality.standard), 'SDHASH');
    });

    test('全部档位缺失回退默认 hash，永不出空', () {
      final mv = MvInfo(
        id: '1',
        hash: 'DEFAULT',
        title: 't',
        artist: 'a',
        resolutionHashes: const {},
      );
      expect(resolvePlayHash(mv, MvQuality.high), 'DEFAULT');
    });
  });

  group('MvUrl.fromJson', () {
    test('主结构 data[小写hash].downurl + backupdownurl', () {
      final url = MvUrl.fromJson({
        'status': 1,
        'data': {
          'abc123': {
            'downurl': 'http://cdn.example.com/mv.mp4',
            'backupdownurl': ['http://bak1/mv.mp4', 'http://bak2/mv.mp4'],
            'filesize': 12345678,
          },
        },
      }, hash: 'ABC123');
      expect(url.urls, [
        'http://cdn.example.com/mv.mp4',
        'http://bak1/mv.mp4',
        'http://bak2/mv.mp4',
      ]);
      expect(url.fileSize, 12345678);
      expect(url.isPlayable, isTrue);
    });

    test('兼容 sd/hd/uhd 分档结构', () {
      final url = MvUrl.fromJson({
        'data': {
          'sd': {'url': 'http://sd.mp4', 'filesize': 1},
          'hd': {'url': 'http://hd.mp4', 'filesize': 2},
        },
      }, hash: 'XYZ');
      expect(url.urls.first, 'http://hd.mp4');
      expect(url.urls, contains('http://sd.mp4'));
    });

    test('空地址不可播放', () {
      final url = MvUrl.fromJson({'data': <String, dynamic>{}}, hash: 'H');
      expect(url.isPlayable, isFalse);
    });
  });

  group('MvInfo 持久化 round-trip', () {
    test('toJson/fromJson 保留关键字段', () {
      final mv = MvInfo(
        id: '42',
        hash: 'HASH',
        title: '晴天',
        artist: '周杰伦',
        coverUrl: 'http://img/cover.jpg',
        duration: const Duration(seconds: 269),
        publishDate: '2003-07-31',
        albumAudioId: '32155307',
        resolutionHashes: const {'sd': 'SD', 'hd': 'HD'},
      );
      final restored = MvInfo.fromJson(mv.toJson());
      expect(restored.id, '42');
      expect(restored.hash, 'HASH');
      expect(restored.title, '晴天');
      expect(restored.duration, const Duration(seconds: 269));
      expect(restored.resolutionHashes, {'sd': 'SD', 'hd': 'HD'});
      expect(MvInfo.isSameMv(mv, restored), isTrue);
    });
  });

  group('MvInfo.listFromAny', () {
    test('从 lists 数组容器解析并过滤无 hash 项', () {
      final result = MvInfo.listFromAny({
        'total': 10,
        'lists': [
          {'video_id': '1', 'hash': 'A', 'title': 'M1'},
          {'video_id': '2', 'title': '无hash'},
          {'video_id': '3', 'hash': 'C', 'title': 'M3'},
        ],
      });
      expect(result.length, 2);
      expect(result.first.title, 'M1');
    });

    test('resolution 数组归入分档 hash', () {
      final result = MvInfo.listFromAny({
        'lists': [
          {
            'video_id': '1',
            'hash': 'SDHASH',
            'title': 'M1',
            'resolution': [
              {'hash': 'HDHASH', 'resolution': 'hd'},
              {'hash': 'SHDHASH', 'definition': '1080p'},
            ],
          },
        ],
      });
      expect(result.single.resolutionHashes['hd'], 'HDHASH');
      expect(result.single.resolutionHashes['shd'], 'SHDHASH');
    });

    test('支持顶层 fhd_hash/hd_hash/sd_hash 与 hdpic 裸文件名及 timelength 毫秒', () {
      final mv = MvInfo.fromListJson({
        'id': 366845,
        'name': '晴天',
        'singer': '周杰伦',
        'hdpic': '20200620174316264397.jpg',
        'timelength': 269000,
        'sd_hash': 'SD_HASH_1',
        'hd_hash': 'HD_HASH_1',
        'fhd_hash': 'FHD_HASH_1',
      });
      expect(mv.id, '366845');
      expect(mv.hash, 'SD_HASH_1');
      expect(mv.resolutionHashes['sd'], 'SD_HASH_1');
      expect(mv.resolutionHashes['hd'], 'HD_HASH_1');
      expect(mv.resolutionHashes['shd'], 'FHD_HASH_1');
      expect(mv.duration, const Duration(seconds: 269));
      expect(
        mv.coverUrl,
        'http://imge.kugou.com/mvhdpic/480/20200620/20200620174316264397.jpg',
      );
    });
  });
}
