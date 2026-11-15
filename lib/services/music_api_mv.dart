part of 'music_api.dart';

/// MV：搜索 / 详情（含清晰度）/ 播放地址 / 歌曲反查 / 歌手 MV / 场景视频。
mixin _MusicApiMv on _MusicApiBase, _MusicApiSearch {
  /// 搜索 MV（/search type=mv，需登录态，匿名返回 error_code=152）。
  Future<List<MvInfo>> searchMvs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'mv',
    });
    // 与 searchSongs 同款解包：data 提升后为 {total, lists}。
    final List items;
    if (raw is List) {
      items = raw;
    } else {
      final json = asMap(raw);
      items = asList(json['lists'] ?? json['list'] ?? json['info']);
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(MvInfo.fromSearch)
        .where((mv) => mv.isPlayable)
        .toList();
  }

  /// 视频详情（/video/detail）：补全标题/封面/时长与各清晰度 hash。
  ///
  /// 返回 null 表示接口未返回有效条目（ lite 身份被 kmr.service 拒答等）。
  Future<MvInfo?> mvDetail(MvInfo mv) async {
    if (mv.id.isEmpty) return mv;
    final raw = await _client.get('/video/detail', {'id': mv.id});
    final json = asMap(raw);
    final data = json['data'] ?? raw;
    Map<String, dynamic> entry;
    if (data is List) {
      final list = data.whereType<Map<String, dynamic>>().toList();
      entry = list.isNotEmpty ? list.first : const {};
    } else {
      entry = asMap(data);
    }
    if (entry.isEmpty) return mv;
    final detail = MvInfo.fromListJson(entry);
    if (!detail.isPlayable && detail.resolutionHashes.isEmpty) return mv;
    // 默认 hash 保持搜索结果原值（已验证可用）；详情只补档位与元信息。
    return mv.copyWith(
      title: detail.title == '未知MV' ? null : detail.title,
      artist: detail.artist == '未知艺人' ? null : detail.artist,
      coverUrl: detail.coverUrl,
      duration: detail.duration,
      resolutionHashes: detail.resolutionHashes.isNotEmpty
          ? detail.resolutionHashes
          : null,
    );
  }

  /// MV 播放地址（/video/url）。清晰度由 hash 决定（见 [resolvePlayHash]）。
  Future<MvUrl> mvUrl(String hash) async {
    final raw = await _client.get('/video/url', {'hash': hash});
    return MvUrl.fromJson(raw, hash: hash);
  }

  /// 按 MixSongID 批量反查歌曲 MV（/kmr/audio/mv fields=h264,h265）。
  ///
  /// 返回 album_audio_id → MvInfo 的映射（保留歌曲顺序由调用方保证），
  /// 无 MV 的歌曲不出现在结果里。
  Future<Map<String, MvInfo>> songsMv(List<Song> songs) async {
    final result = <String, MvInfo>{};
    // 按 id 去重后分批（每批 30 个，对齐接口批量上限的保守值）。
    final ids = <String>[];
    final seen = <String>{};
    for (final song in songs) {
      final id = song.albumAudioId ?? song.id;
      final numeric = id.isNotEmpty && id != '0' ? id : '';
      if (numeric.isNotEmpty && seen.add(numeric)) {
        ids.add(numeric);
      }
    }
    const batchSize = 30;
    for (var start = 0; start < ids.length; start += batchSize) {
      final batch = ids.skip(start).take(batchSize).toList();
      if (batch.isEmpty) continue;
      try {
        final raw = await _client.get('/kmr/audio/mv', {
          'album_audio_id': batch.join(','),
          'fields': 'h264,h265',
        });
        _collectKmrMvs(raw, batch, result);
      } on Exception {
        // 单批失败不影响其他批次；调用方以缺项表示「无 MV」。
        continue;
      }
    }
    return result;
  }

  void _collectKmrMvs(
    Object? raw,
    List<String> batch,
    Map<String, MvInfo> result,
  ) {
    final json = asMap(raw);
    // 实测契约：data 按请求 id 顺序返回内层数组——同一首歌可能有多个
    // 版本 MV（官方/现场/饭制），无 MV 的 id 对应空对象。
    final entries = <Map<String, dynamic>>[];
    for (final container in asList(json['data'] ?? raw)) {
      if (container is Map<String, dynamic>) {
        entries.add(container);
      } else if (container is List) {
        entries.addAll(container.whereType<Map<String, dynamic>>());
      }
    }
    final recommended = <String, bool>{};
    for (final entry in entries) {
      final albumAudioId =
          asString(entry['album_audio_id']) ??
          asString(entry['mixsong_id']) ??
          asString(entry['id']);
      if (albumAudioId == null || !batch.contains(albumAudioId)) continue;
      final mv = MvInfo.fromKmrAudioMv(entry);
      if (mv == null) continue;
      // 同曲多版本：默认取首个，但带 is_recommend 的官方版本优先。
      final isRecommend = asBool(entry['is_recommend']) == true;
      if (result.containsKey(albumAudioId)) {
        if (isRecommend && recommended[albumAudioId] != true) {
          result[albumAudioId] = mv;
          recommended[albumAudioId] = true;
        }
      } else {
        result[albumAudioId] = mv;
        recommended[albumAudioId] = isRecommend;
      }
    }
  }

  /// 歌手 MV 列表（/artist/videos）。tag: official/live/fan/artist/all。
  Future<List<MvInfo>> artistMvs(
    String artistId, {
    int page = 1,
    int pageSize = 30,
    String tag = 'all',
  }) async {
    final raw = await _client.get('/artist/videos', {
      'id': artistId,
      'page': page,
      'pagesize': pageSize,
      'tag': tag,
    });
    return MvInfo.listFromAny(raw);
  }

  /// 场景 MV 列表（/scene/video/list，首页「MV 精选」数据源）。
  Future<List<MvInfo>> mvFeed({
    String tagId = '',
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/scene/video/list', {
      'tag_id': tagId,
      'page': page,
      'pagesize': pageSize,
    });
    return MvInfo.listFromAny(raw);
  }

  /// MV 反查歌曲（「切换为音频」的兜底路径）。
  ///
  /// 来源映射缺失（搜索 MV/歌手 MV/场景 MV 直开）时，以「标题 歌手」
  /// 搜歌并取标题最接近的一条；搜不到返回 null（调用方 toast 提示）。
  Future<Song?> searchSongForMv(MvInfo mv) async {
    final keywords = mv.artist.isEmpty || mv.artist == '未知艺人'
        ? mv.title
        : '${mv.title} ${mv.artist}';
    final songs = await searchSongs(keywords, pageSize: 20);
    if (songs.isEmpty) return null;
    final target = _normalizeMvTitle(mv.title);
    if (target.isEmpty) return songs.first;
    Song? best;
    for (final song in songs) {
      final candidate = _normalizeMvTitle(song.title);
      if (candidate == target) return song;
      if (best == null &&
          candidate.isNotEmpty &&
          (candidate.contains(target) || target.contains(candidate))) {
        best = song;
      }
    }
    return best ?? songs.first;
  }

  /// 标题归一化：去掉括号内容（「（Live）」「(官方MV)」类后缀）与空白，
  /// 再摘掉结尾的 MV 字样，小写比较。
  static String _normalizeMvTitle(String title) {
    var result = title.replaceAll(RegExp(r'[（(\[【][^）)\]】]*[）)\]】]'), '');
    result = result.replaceAll(RegExp(r'\s+'), '');
    result = result.replaceAll(RegExp(r'(official)?mv$'), '');
    return result.toLowerCase();
  }
}
