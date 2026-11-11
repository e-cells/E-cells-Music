part of 'music_api.dart';

/// 搜索（酷狗站内与网易云）。
mixin _MusicApiSearch on _MusicApiBase, _MusicApiArtist {
  Future<List<SearchHotCategory>> searchHotKeywords() async {
    final json = asMap(await _client.get('/search/hot'));
    return asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(SearchHotCategory.fromJson)
        .toList();
  }

  Future<List<String>> searchSuggest(String keywords) async {
    final json = asMap(
      await _client.get('/search/suggest', {'keywords': keywords}),
    );
    final items = asList(json['music']);
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => asString(item['keyword']) ?? '')
        .where((k) => k.isNotEmpty)
        .toList();
  }

  static bool _isPlayableSearchSong(Map<String, dynamic> json) {
    final transParam = asMap(json['trans_param']);
    if (transParam.isNotEmpty) {
      final cid = asInt(transParam['cid']);
      final failProcess = asInt(json['FailProcess']);
      if (cid != null && cid <= 0 && failProcess != null && failProcess == 0) {
        return false;
      }
    }
    return true;
  }

  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'song',
    });
    // API returns either a plain array or { songs: [...] }
    final List songs;
    if (raw is List) {
      songs = raw;
    } else {
      final json = asMap(raw);
      songs = asList(json['songs'] ?? json['song'] ?? json['lists']);
    }
    return songs
        .whereType<Map<String, dynamic>>()
        .where(_isPlayableSearchSong)
        .map(Song.fromSearch)
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  Future<List<SearchArtistResult>> searchArtists(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    // 酷狗 complexsearch 不支持 singer 类型搜索，
    // 改为搜索歌曲后从结果中提取去重歌手。
    final songs = await searchSongs(keywords, page: page, pageSize: pageSize);
    final seen = <String>{};
    final artists = <SearchArtistResult>[];
    for (final song in songs) {
      for (final artist in song.artists) {
        if (artist.id.isNotEmpty && seen.add(artist.id)) {
          artists.add(
            SearchArtistResult(
              id: artist.id,
              name: artist.name,
              avatarUrl: artist.avatarUrl,
            ),
          );
        } else if (artist.id.isEmpty &&
            artist.name.isNotEmpty &&
            seen.add('name:${artist.name}')) {
          artists.add(SearchArtistResult(id: '', name: artist.name));
        }
      }
    }
    // 搜索接口不返回头像，通过 artistDetail 并行补全
    final needAvatar = artists
        .where(
          (a) =>
              a.id.isNotEmpty && (a.avatarUrl == null || a.avatarUrl!.isEmpty),
        )
        .toList();
    if (needAvatar.isNotEmpty) {
      final details = await Future.wait(
        needAvatar.map((a) async {
          try {
            return await artistDetail(a.id);
          } catch (_) {
            return null;
          }
        }),
      );
      for (var i = 0; i < needAvatar.length; i++) {
        final detail = details[i];
        if (detail != null &&
            detail.avatarUrl != null &&
            detail.avatarUrl!.isNotEmpty) {
          final idx = artists.indexOf(needAvatar[i]);
          if (idx >= 0) {
            artists[idx] = SearchArtistResult(
              id: needAvatar[i].id,
              name: needAvatar[i].name,
              avatarUrl: detail.avatarUrl,
              songCount: needAvatar[i].songCount,
            );
          }
        }
      }
    }
    return artists;
  }

  Future<List<SearchAlbumResult>> searchAlbums(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'album',
    });
    final List items;
    if (raw is List) {
      items = raw;
    } else {
      final json = asMap(raw);
      // 兼容多种可能的字段名和嵌套结构
      items = asList(
        json['info'] ??
            json['album'] ??
            json['albums'] ??
            json['list'] ??
            json['lists'] ??
            json['items'] ??
            asMap(json['album'])['info'] ??
            asMap(json['data'])['info'],
      );
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(SearchAlbumResult.fromJson)
        .where((a) => a.albumId.isNotEmpty)
        .toList();
  }

  /// 搜索酷狗歌单（`/search?type=special`）。
  ///
  /// 酷狗的"歌单"在搜索侧叫 special；Rust 层按参考实现补
  /// albumhide/nocollect 参数。响应经 transport 提升 data 后是
  /// `{lists: [...]}`，条目形状见 [SearchPlaylistResult]。
  Future<List<SearchPlaylistResult>> searchPlaylists(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'special',
    });
    final List items;
    if (raw is List) {
      items = raw;
    } else {
      final json = asMap(raw);
      items = asList(
        json['lists'] ??
            json['special_list'] ??
            json['list'] ??
            asMap(json['data'])['lists'],
      );
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(SearchPlaylistResult.fromJson)
        // 无 gid 的条目（系统/下架歌单）没有可用的详情 ID，直接过滤。
        .where((p) => p.gid.isNotEmpty)
        .toList();
  }

  /// 搜索网易云歌曲。
  ///
  /// 使用独立的网易云 API（`wyy.music.api.hoilai.cn`）：
  /// 1. 调用 `/search?keywords=xxx` 获取歌曲 ID 列表
  /// 2. 调用 `/song/detail?ids=id1,id2,...` 获取歌曲详情（名称、歌手、专辑、封面）
  Future<List<Song>> searchNetEaseSongs(
    String keywords, {
    int limit = 30,
    int offset = 0,
  }) async {
    final baseUri = Uri.parse('https://wyy.music.api.hoilai.cn');

    // 1. 搜索获取歌曲 ID
    final searchUri = baseUri.replace(
      path: '/search',
      queryParameters: {
        'keywords': keywords,
        'limit': '$limit',
        'offset': '$offset',
        'type': '1',
      },
    );
    final searchResponse = await _client.getRaw(searchUri);
    final searchJson = asMap(searchResponse);
    final rawSongs = asList(
      searchJson['result'] is Map
          ? asMap(searchJson['result'])['songs']
          : searchJson['songs'],
    );
    final ids = rawSongs
        .whereType<Map>()
        .map((item) => asInt(asMap(item)['id']))
        .whereType<int>()
        .where((id) => id > 0)
        .toList();
    if (ids.isEmpty) return const [];

    // 2. 批量获取歌曲详情
    final detailUri = baseUri.replace(
      path: '/song/detail',
      queryParameters: {'ids': ids.join(',')},
    );
    final detailResponse = await _client.getRaw(detailUri);
    final detailJson = asMap(detailResponse);
    final songsList = asList(detailJson['songs']);

    return songsList
        .whereType<Map<String, dynamic>>()
        .map((item) => NetEaseSong.fromJson(item).toSong())
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }
}
