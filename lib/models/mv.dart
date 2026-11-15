import 'model_parsing.dart';

/// MV 清晰度档位。
///
/// 档位值对齐酷狗视频接口的 sd/hd/shd（超清）约定；「超清」泛指
/// 1080P 及以上（部分响应里表现为 uhd/2k/4k，统一归入 shd）。
enum MvQuality {
  standard('标清', 'sd'),
  high('高清', 'hd'),
  ultra('超清', 'shd');

  const MvQuality(this.label, this.apiValue);

  final String label;
  final String apiValue;

  /// 从接口返回的档位标记解析（宽容匹配 uhd/2k/4k/分辨率数字）。
  static MvQuality? fromApi(Object? value) {
    final text = value?.toString().toLowerCase();
    if (text == null || text.isEmpty) return null;
    if (text.contains('shd') ||
        text.contains('uhd') ||
        text.contains('2k') ||
        text.contains('4k')) {
      return MvQuality.ultra;
    }
    if (text.contains('hd')) return MvQuality.high;
    if (text.contains('sd')) return MvQuality.standard;
    // 分辨率数字形态：'720'/'1080'/'1080p'/'2160p' 等。
    final width = int.tryParse(
      RegExp(r'^(\d{3,4})').firstMatch(text)?.group(1) ?? '',
    );
    if (width != null) {
      if (width >= 1080) return MvQuality.ultra;
      if (width >= 720) return MvQuality.high;
      return MvQuality.standard;
    }
    return null;
  }

  /// 降级链：期望档位 → 依次回退到更低档位。
  List<MvQuality> get degradeChain {
    switch (this) {
      case MvQuality.ultra:
        return const [MvQuality.ultra, MvQuality.high, MvQuality.standard];
      case MvQuality.high:
        return const [MvQuality.high, MvQuality.standard];
      case MvQuality.standard:
        return const [MvQuality.standard, MvQuality.high];
    }
  }
}

/// 画质选择纯函数：从 [mv] 的可用 hash 集里按期望档位选出实际播放 hash。
///
/// 无分档信息时直接用默认 hash；期望档位缺失时沿降级链回退，全部
/// 缺失时用默认 hash 兜底，永不出空（调用方以空 hash 判「无 MV」）。
String resolvePlayHash(MvInfo mv, MvQuality prefer) {
  final hashes = mv.resolutionHashes;
  if (hashes.isEmpty) return mv.hash;
  for (final quality in prefer.degradeChain) {
    final hash = hashes[quality.apiValue];
    if (hash != null && hash.isNotEmpty) return hash;
  }
  return mv.hash;
}

/// MV 条目（跨来源统一模型）。
///
/// 来源与字段差异（搜索 type=mv / 歌手 MV 列表 / 视频详情 / 歌曲反查 /
/// 场景视频）在工厂方法里吸收；[id] 缺失时以 [hash] 作为去重主键。
class MvInfo {
  MvInfo({
    required this.id,
    required this.hash,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.duration,
    this.publishDate,
    this.albumAudioId,
    this.resolutionHashes = const {},
  });

  /// 视频 id（搜索结果 MvID / 详情 video_id），可能为空。
  final String id;

  /// 默认（标清）视频 hash —— 播放地址解析主键。
  final String hash;

  final String title;
  final String artist;
  final String? coverUrl;
  final Duration? duration;
  final String? publishDate;

  /// 歌曲反查（/kmr/audio/mv）来源时的 album_audio_id，用于关联回歌曲。
  final String? albumAudioId;

  /// 分档视频 hash：{'sd': ..., 'hd': ..., 'shd': ...}。
  final Map<String, String> resolutionHashes;

  /// 去重/比较主键：优先 video id，缺省退回 hash。
  String get key => id.isNotEmpty ? id : hash;

  bool get isPlayable => hash.isNotEmpty;

  MvInfo copyWith({
    String? id,
    String? hash,
    String? title,
    String? artist,
    String? coverUrl,
    Duration? duration,
    String? publishDate,
    Map<String, String>? resolutionHashes,
  }) {
    return MvInfo(
      id: id ?? this.id,
      hash: hash ?? this.hash,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      publishDate: publishDate ?? this.publishDate,
      albumAudioId: albumAudioId,
      resolutionHashes: resolutionHashes ?? this.resolutionHashes,
    );
  }

  /// 两个条目是否同一条 MV（队列高亮/点当前不重播）。
  static bool isSameMv(MvInfo? a, MvInfo? b) {
    if (a == null || b == null) return false;
    if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
    return a.hash.isNotEmpty && a.hash == b.hash;
  }

  /// 搜索结果（/search type=mv）列表项。
  ///
  /// 契约字段（对齐 complexsearch.kugou.com/v1/search/mv 与 KuGouMusicApi）：
  /// MvID / MvName|FileName / SingerName / MvHash|FileHash / Duration(秒) /
  /// PublishDate；封面在真实接口中返回 `Pic`（如 `"20200620174316264397.jpg"`
  /// 纯文件名）或 `ErectPic` / `ThumbGif` / `Image` / `img`。
  factory MvInfo.fromSearch(Map<String, dynamic> json) {
    return MvInfo(
      id: asString(json['MvID']) ?? asString(json['VideoID']) ?? '',
      hash:
          asString(json['MvHash']) ??
          asString(json['FileHash']) ??
          asString(json['hash']) ??
          '',
      title:
          asString(json['MvName']) ??
          asString(json['FileName']) ??
          asString(json['title']) ??
          '未知MV',
      artist:
          asString(json['SingerName']) ??
          asString(json['singer']) ??
          asString(json['author_name']) ??
          '未知艺人',
      coverUrl: normalizeMvCoverUrl(
        asString(json['Pic']) ??
            asString(json['pic']) ??
            asString(json['Image']) ??
            asString(json['img']) ??
            asString(json['hdpic']) ??
            asString(json['ErectPic']) ??
            asString(json['ThumbGif']),
      ),
      duration: _parseMvDuration(json['Duration'] ?? json['duration']),
      publishDate:
          asString(json['PublishDate']) ?? asString(json['publish_date']),
      albumAudioId:
          asString(json['MixSongID']) ??
          asString(json['AudioID']) ??
          asString(json['AlbumAudioID']),
    );
  }

  /// 通用防御式解析：歌手 MV 列表 / 场景视频列表 / 视频详情等来源共用。
  ///
  /// 这些响应没有稳定公开契约，按字段别名链宽容解析；顺带吸收
  /// 分辨率信息（resolution/resolutions 数组或映射、h264/h265 清晰度对象、
  /// 以及顶层 fhd_hash/hd_hash/qhd_hash/sd_hash/ld_hash）。
  factory MvInfo.fromListJson(Map<String, dynamic> json) {
    final id =
        asString(json['MvID']) ??
        asString(json['video_id']) ??
        asString(json['videoid']) ??
        asString(json['VideoID']) ??
        asString(json['id']) ??
        '';
    final rawHash =
        asString(json['MvHash']) ??
        asString(json['FileHash']) ??
        asString(json['video_hash']) ??
        asString(json['VideoHash']) ??
        asString(json['hash']) ??
        '';

    // 分辨率档位：
    // 1) resolution/resolutions/mvhash 数组或映射；
    // 2) h264/h265 嵌套对象（歌手 MV /artist/videos 等）；
    // 3) 顶层 fhd_hash/hd_hash/qhd_hash/sd_hash/ld_hash（视频详情 /v1/video 等）。
    final resolutions = <String, String>{};
    for (final containerKey in const ['resolution', 'resolutions', 'mvhash']) {
      final container = json[containerKey];
      if (container is List) {
        for (final entry in container) {
          final map = asMap(entry);
          final entryHash =
              asString(map['hash']) ??
              asString(map['video_hash']) ??
              asString(map['mvhash']);
          final quality = MvQuality.fromApi(
            map['resolution'] ??
                map['definition'] ??
                map['quality'] ??
                map['type'],
          );
          if (entryHash != null && entryHash.isNotEmpty && quality != null) {
            resolutions.putIfAbsent(quality.apiValue, () => entryHash);
          }
        }
      } else if (container is Map) {
        for (final entry in asMap(container).entries) {
          final quality = MvQuality.fromApi(entry.key);
          final entryMap = asMap(entry.value);
          final entryHash =
              asString(entryMap['hash']) ?? asString(entry.value);
          if (quality != null && entryHash != null && entryHash.isNotEmpty) {
            resolutions.putIfAbsent(quality.apiValue, () => entryHash);
          }
        }
      }
    }

    const hashKeyToQuality = <String, String>{
      'fhd_hash': 'shd',
      'hd_hash': 'hd',
      'qhd_hash': 'hd',
      'mkv_qhd_hash': 'hd',
      'sd_hash': 'sd',
      'ld_hash': 'sd',
      'mkv_sd_hash': 'sd',
    };
    for (final field in const ['h264', 'h265']) {
      final slots = asMap(json[field]);
      for (final hashKey in hashKeyToQuality.entries) {
        final h = asString(slots[hashKey.key]);
        if (h != null && h.isNotEmpty) {
          resolutions.putIfAbsent(hashKey.value, () => h);
        }
      }
    }
    for (final hashKey in hashKeyToQuality.entries) {
      final h = asString(json[hashKey.key]);
      if (h != null && h.isNotEmpty) {
        resolutions.putIfAbsent(hashKey.value, () => h);
      }
    }

    final hash = rawHash.isNotEmpty
        ? rawHash
        : (resolutions['sd'] ?? resolutions['hd'] ?? resolutions['shd'] ?? '');

    return MvInfo(
      id: id,
      hash: hash,
      title:
          asString(json['MvName']) ??
          asString(json['FileName']) ??
          asString(json['title']) ??
          asString(json['name']) ??
          asString(json['video_name']) ??
          asString(json['mv_name']) ??
          '未知MV',
      artist:
          asString(json['SingerName']) ??
          asString(json['singer']) ??
          asString(json['singername']) ??
          asString(json['author_name']) ??
          '未知艺人',
      coverUrl: normalizeMvCoverUrl(
        asString(json['hdpic']) ??
            asString(json['hd_pic']) ??
            asString(json['Pic']) ??
            asString(json['pic']) ??
            asString(json['Image']) ??
            asString(json['img']) ??
            asString(json['cover']) ??
            asString(json['thumb']) ??
            asString(json['cover_url']) ??
            asString(json['imgUrl']) ??
            asString(json['horizontal_cover']) ??
            asString(json['erect_hdpic']),
      ),
      duration:
          durationFromMilliseconds(json['timelength']) ??
          _parseMvDuration(json['Duration'] ?? json['duration']),
      publishDate:
          asString(json['PublishDate']) ??
          asString(json['publish_date']) ??
          asString(json['publish_time']),
      albumAudioId:
          asString(json['album_audio_id']) ??
          asString(json['MixSongID']) ??
          asString(json['AudioID']),
      resolutionHashes: resolutions,
    );
  }

  /// 歌曲反查（/kmr/audio/mv fields=h264,h265）结果项。
  ///
  /// 实测契约（真实接口抓包）：h264/h265 是按清晰度展开的 hash 对象
  /// （`ld_hash`/`sd_hash`/`qhd_hash`/`hd_hash`/`fhd_hash`），duration 为
  /// 毫秒，album_audio_id/video_id 为数字，标题/歌手在 mv_name/singer，
  /// 封面在 thumb/hdpic（含 {size} 占位符）。档位归并：fhd(1080P+)→超清，
  /// hd(720P)/qhd(960×540 quarter-HD，非 4K)→高清，sd/ld→标清；同档位
  /// h264 优先（部分车机/老设备无 h265 硬解）。
  /// 返回 null 表示该歌曲没有可用 MV。
  static MvInfo? fromKmrAudioMv(
    Map<String, dynamic> json, {
    String? fallbackTitle,
    String? fallbackArtist,
  }) {
    const hashKeyToQuality = <String, String>{
      'fhd_hash': 'shd',
      'hd_hash': 'hd',
      'qhd_hash': 'hd',
      'sd_hash': 'sd',
      'ld_hash': 'sd',
    };
    final hashes = <String, String>{};
    for (final field in const ['h264', 'h265']) {
      final slots = asMap(json[field]);
      for (final hashKey in hashKeyToQuality.entries) {
        final hash = asString(slots[hashKey.key]);
        if (hash != null && hash.isNotEmpty) {
          hashes.putIfAbsent(hashKey.value, () => hash);
        }
      }
    }

    // 默认 hash 取标清（与搜索 MvHash 同档，最稳妥）；实际播放档位由
    // resolvePlayHash 按期望画质从 resolutionHashes 里选。
    final fallback = hashes['sd'] ?? hashes['hd'] ?? hashes['shd'] ?? '';
    if (fallback.isEmpty) return null;
    return MvInfo(
      id: asString(json['video_id']) ?? asString(json['MvID']) ?? '',
      hash: fallback,
      title:
          asString(json['mv_name']) ??
          asString(json['title']) ??
          asString(json['MvName']) ??
          fallbackTitle ??
          '未知MV',
      artist:
          asString(json['singer']) ??
          asString(json['SingerName']) ??
          fallbackArtist ??
          '未知艺人',
      coverUrl: normalizeMvCoverUrl(
        asString(json['thumb']) ??
            asString(json['hdpic']) ??
            asString(json['hd_pic']) ??
            asString(json['pic']) ??
            asString(json['cover']),
      ),
      duration: durationFromMilliseconds(json['duration']),
      albumAudioId: asString(json['album_audio_id']),
      resolutionHashes: hashes,
    );
  }

  /// 兼容秒与毫秒的时长解析：大于 10000（约 2.7 小时）视为毫秒。
  static Duration? _parseMvDuration(Object? value) {
    final raw = asInt(value);
    if (raw == null || raw <= 0) return null;
    if (raw > 10000) {
      return Duration(milliseconds: raw);
    }
    return Duration(seconds: raw);
  }

  /// 从任意响应容器（data/lists/list/info 数组等）挖出 MV 列表。
  static List<MvInfo> listFromAny(Object? raw) {
    if (raw == null) return const [];
    Iterable<Map<String, dynamic>> items;
    if (raw is List) {
      items = raw.whereType<Map<String, dynamic>>();
    } else {
      final json = asMap(raw);
      var container = json['lists'] ?? json['list'] ?? json['info'] ?? json['data'];
      if (container is Map) {
        // data 仍可能是 {lists: [...]} 或 {total, lists} 的包装。
        final nested = asMap(container);
        container = nested['lists'] ?? nested['list'] ?? nested['info'] ?? container;
      }
      items = (container is List ? container : const [])
          .whereType<Map<String, dynamic>>();
    }
    return items
        .map(MvInfo.fromListJson)
        .where((mv) => mv.isPlayable)
        .toList();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hash': hash,
      'title': title,
      'artist': artist,
      if (coverUrl != null) 'coverUrl': coverUrl,
      if (duration != null) 'durationSec': duration!.inSeconds,
      if (publishDate != null) 'publishDate': publishDate,
      if (albumAudioId != null) 'albumAudioId': albumAudioId,
      if (resolutionHashes.isNotEmpty) 'resolutionHashes': resolutionHashes,
    };
  }

  factory MvInfo.fromJson(Map<String, dynamic> json) {
    return MvInfo(
      id: asString(json['id']) ?? '',
      hash: asString(json['hash']) ?? '',
      title: asString(json['title']) ?? '未知MV',
      artist: asString(json['artist']) ?? '未知艺人',
      coverUrl: asString(json['coverUrl']),
      duration: durationFromSeconds(json['durationSec']),
      publishDate: asString(json['publishDate']),
      albumAudioId: asString(json['albumAudioId']),
      resolutionHashes: asMap(json['resolutionHashes']).map(
        (k, v) => MapEntry(k, v.toString()),
      ),
    );
  }
}

/// MV 播放地址（/video/url 结果）。
///
/// 主结构为 data[小写hash].{downurl, backupdownurl[], filesize}；
/// 兼容 data.sd/hd/uhd/shd 分档结构（每档 {url, filesize}）。
/// [urls] 为主链接 + 备用链，依序尝试。
class MvUrl {
  MvUrl({required this.urls, this.fileSize});

  final List<String> urls;
  final int? fileSize;

  bool get isPlayable => urls.any((url) => url.isNotEmpty);

  factory MvUrl.fromJson(Object? raw, {required String hash}) {
    final json = asMap(raw);
    final data = json['data'] ?? json;
    final dataMap = asMap(data);

    final byHash = asMap(dataMap[hash.toLowerCase()]);
    final downUrl = asString(byHash['downurl']) ?? asString(byHash['url']);
    final backups = asList(byHash['backupdownurl'])
        .map((url) => asString(url) ?? '')
        .where((url) => url.isNotEmpty)
        .toList();
    if (downUrl != null && downUrl.isNotEmpty) {
      return MvUrl(
        urls: [downUrl, ...backups],
        fileSize: asInt(byHash['filesize']),
      );
    }

    // 分档结构：sd/hd/uhd/shd 各档 {url, filesize}。
    final urls = <String>[];
    int? fileSize;
    for (final qualityKey in const ['shd', 'uhd', 'hd', 'sd']) {
      final entry = asMap(dataMap[qualityKey]);
      final url = asString(entry['url']);
      if (url != null && url.isNotEmpty) {
        urls.add(url);
        fileSize ??= asInt(entry['filesize']);
      }
    }
    return MvUrl(urls: urls, fileSize: fileSize);
  }
}
