import 'model_parsing.dart';
import 'playlist.dart';
import 'song.dart';

class SearchHotKeyword {
  const SearchHotKeyword({required this.keyword, this.reason});

  final String keyword;
  final String? reason;

  factory SearchHotKeyword.fromJson(Map<String, dynamic> json) {
    return SearchHotKeyword(
      keyword: asString(json['keyword']) ?? '',
      reason: asString(json['reason']),
    );
  }
}

class SearchHotCategory {
  const SearchHotCategory({required this.name, required this.keywords});

  final String name;
  final List<SearchHotKeyword> keywords;

  factory SearchHotCategory.fromJson(Map<String, dynamic> json) {
    return SearchHotCategory(
      name: asString(json['name']) ?? '',
      keywords: asList(json['keywords'])
          .whereType<Map<String, dynamic>>()
          .map(SearchHotKeyword.fromJson)
          .toList(),
    );
  }
}

class SearchArtistResult {
  const SearchArtistResult({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.songCount = 0,
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final int songCount;

  factory SearchArtistResult.fromJson(Map<String, dynamic> json) {
    return SearchArtistResult(
      id:
          asString(json['singerid']) ??
          asString(json['singer_id']) ??
          asString(json['author_id']) ??
          asString(json['id']) ??
          '',
      name:
          asString(json['singername']) ??
          asString(json['singer_name']) ??
          asString(json['author_name']) ??
          asString(json['name']) ??
          '未知歌手',
      avatarUrl: normalizeImageUrl(
        asString(json['sizable_avatar']) ??
            asString(json['avatar']) ??
            asString(json['img']),
      ),
      songCount: asInt(json['songcount'] ?? json['song_count']) ?? 0,
    );
  }
}

class SearchAlbumResult {
  const SearchAlbumResult({
    required this.albumId,
    required this.albumName,
    this.artistName = '',
    this.coverUrl,
    this.songCount = 0,
  });

  final String albumId;
  final String albumName;
  final String artistName;
  final String? coverUrl;
  final int songCount;

  factory SearchAlbumResult.fromJson(Map<String, dynamic> json) {
    return SearchAlbumResult(
      albumId:
          asString(json['albumid']) ??
          asString(json['album_id']) ??
          asString(json['id']) ??
          '',
      albumName:
          asString(json['albumname']) ??
          asString(json['album_name']) ??
          asString(json['name']) ??
          '未知专辑',
      // `/search` type=album 的字段名是 `singer`（见 api.json 的
      // SearchAlbumItem），不是歌手接口那套 singername/author_name。
      // 只认后者会让专辑 tab 的歌手名恒为空（上层是
      // `if (artistName.isNotEmpty)`，所以表现为静默不显示）。
      artistName:
          asString(json['singer']) ??
          asString(json['singername']) ??
          asString(json['author_name']) ??
          asString(json['singer_name']) ??
          '',
      coverUrl: normalizeImageUrl(
        asString(json['sizable_cover']) ??
            asString(json['cover']) ??
            asString(json['img']),
      ),
      songCount: asInt(json['songcount'] ?? json['song_count']) ?? 0,
    );
  }
}

/// 歌单搜索结果（`/search?type=special` 的 `SearchPlaylistItem`）。
///
/// 契约来源 api.json 与 complexsearch.kugou.com `/v1/search/special` 实测：
/// `gid`（歌单全局 ID，详情/曲目加载的唯一可用 ID）、`specialid`（本地 ID）、
/// `specialname`、`song_count`、`nickname`（创建者）、`play_count` /
/// `total_play_count`（字符串数字）、`img`（完整 URL，可带 {size} 占位）。
class SearchPlaylistResult {
  const SearchPlaylistResult({
    required this.gid,
    required this.name,
    this.specialId = '',
    this.coverUrl,
    this.songCount = 0,
    this.creatorName = '',
    this.playCount = 0,
    this.publishTime,
  });

  /// 歌单全局 ID（`collection_...` 形态）：[PlaylistSummary.id] 与
  /// 歌单详情/曲目接口（global_collection_id）都只认它。为空的条目
  /// 打不开详情，调用方直接过滤。
  final String gid;

  final String name;
  final String specialId;
  final String? coverUrl;
  final int songCount;
  final String creatorName;
  final int playCount;
  final String? publishTime;

  factory SearchPlaylistResult.fromJson(Map<String, dynamic> json) {
    return SearchPlaylistResult(
      gid: asString(json['gid']) ?? '',
      name:
          asString(json['specialname']) ?? asString(json['name']) ?? '未知歌单',
      specialId: asString(json['specialid']) ?? '',
      coverUrl: normalizeImageUrl(
        asString(json['img']) ??
            asString(json['flexible_cover']) ??
            asString(json['cover']),
      ),
      songCount: asInt(json['song_count'] ?? json['count']) ?? 0,
      creatorName:
          asString(json['nickname']) ?? asString(json['user_name']) ?? '',
      // 实测 total_play_count/play_count 都是字符串数字；asInt 都能接。
      playCount:
          asInt(json['total_play_count'] ?? json['play_count'] ?? json['heat']) ??
          0,
      publishTime: asString(json['publish_time']),
    );
  }

  /// 转为可打开 [PlaylistDetailPage] 的歌单摘要。
  ///
  /// 与 `PlaylistSummary.fromRecommend` 同构：`sourceGlobalId` 必须带上 gid，
  /// 否则 [PlaylistSummary.isCollectedAlbum] 会把它误判成收藏专辑，
  /// 详情页走专辑加载分支导致曲目恒为空。
  PlaylistSummary toPlaylistSummary() {
    return PlaylistSummary(
      id: gid,
      title: name,
      subtitle: creatorName.isNotEmpty ? creatorName : null,
      coverUrl: coverUrl,
      songCount: songCount,
      playCount: playCount,
      sourceGlobalId: gid,
    );
  }
}

// ---------------------------------------------------------------------------
// 排行榜 (Rank)
// ---------------------------------------------------------------------------

/// 榜单前三预览（仅展示用，不可播放）。
///
/// `/rank/list?withsong=1` 随榜下发的 `songinfo` 只有 `name/author/songname`，
/// 没有可播 `hash`，因此不进 [Song]（全链路按 `hash.isNotEmpty` 过滤），
/// 单独用轻量结构承载 QQ 式右列。
class RankPreviewSong {
  const RankPreviewSong({required this.title, this.artist = '', this.coverUrl});

  final String title;
  final String artist;

  /// TOP1 歌曲封面（`trans_param.union_cover`），榜单卡片用它代替官方模板图。
  final String? coverUrl;

  factory RankPreviewSong.fromJson(Map<String, dynamic> json) {
    var title = asString(json['name']) ?? '';
    var artist = asString(json['author']) ?? '';
    if (title.isEmpty || artist.isEmpty) {
      // 退化解析 `songname`（形如 "歌手 - 歌名"）。
      final full = asString(json['songname']) ?? '';
      final sep = full.indexOf(' - ');
      if (sep >= 0) {
        artist = artist.isEmpty ? full.substring(0, sep).trim() : artist;
        title = title.isEmpty ? full.substring(sep + 3).trim() : title;
      } else if (title.isEmpty) {
        title = full;
      }
    }
    final transParam = asMap(json['trans_param']);
    return RankPreviewSong(
      title: title,
      artist: artist,
      coverUrl: normalizeImageUrl(asString(transParam['union_cover'])),
    );
  }

  Map<String, dynamic> toCache() => {'t': title, 'a': artist, 'c': coverUrl};

  factory RankPreviewSong.fromCache(Map<String, dynamic> json) {
    return RankPreviewSong(
      title: asString(json['t']) ?? '未知歌曲',
      artist: asString(json['a']) ?? '',
      coverUrl: normalizeImageUrl(asString(json['c'])),
    );
  }
}

class RankCategory {
  const RankCategory({
    required this.rankId,
    required this.rankName,
    this.rankType = 0,
    this.imageUrl,
    this.children = const [],
    this.songs = const [],
    this.topPreviews = const [],
    this.updateFrequency = '',
  });

  final int rankId;
  final String rankName;
  final int rankType;
  final String? imageUrl;
  final List<RankCategory> children;
  final List<Song> songs;

  /// 榜单前三预览（展示用，不可播；可播歌曲走 [songs] / 详情页）。
  final List<RankPreviewSong> topPreviews;
  final String updateFrequency;

  /// 卡片封面：TOP1 预览歌曲封面（无则回落官方榜单图）。
  String? get cardCoverUrl =>
      topPreviews.isNotEmpty && topPreviews.first.coverUrl != null
          ? topPreviews.first.coverUrl
          : imageUrl;

  factory RankCategory.fromJson(Map<String, dynamic> json) {
    final children = asList(
      json['children'],
    ).whereType<Map<String, dynamic>>().map(RankCategory.fromJson).toList();
    final songs = asList(
      json['songlist'] ?? json['songs'] ?? json['song_list'],
    )
        .whereType<Map<String, dynamic>>()
        .map(Song.fromRank)
        .where((s) => s.hash.isNotEmpty)
        .toList();
    final topPreviews = asList(json['songinfo'])
        .whereType<Map<String, dynamic>>()
        .map(RankPreviewSong.fromJson)
        .where((s) => s.title.isNotEmpty)
        .take(3)
        .toList();
    return RankCategory(
      rankId: asInt(json['rankid']) ?? 0,
      rankName: asString(json['rankname']) ?? '未知榜单',
      rankType: asInt(json['ranktype']) ?? 0,
      imageUrl: normalizeImageUrl(asString(json['imgurl'])),
      children: children,
      songs: songs,
      topPreviews: topPreviews,
      updateFrequency:
          asString(json['update_frequency']) ??
          asString(json['frequency']) ??
          asString(json['period']) ??
          '',
    );
  }

  Map<String, dynamic> toCache() {
    return {
      'rankId': rankId,
      'rankName': rankName,
      'rankType': rankType,
      'imageUrl': imageUrl,
      'updateFrequency': updateFrequency,
      'songs': songs.map((s) => s.toCache()).toList(),
      'previews': topPreviews.map((s) => s.toCache()).toList(),
      'children': children.map((c) => c.toCache()).toList(),
    };
  }

  factory RankCategory.fromCache(Map<String, dynamic> json) {
    return RankCategory(
      rankId: asInt(json['rankId']) ?? 0,
      rankName: asString(json['rankName']) ?? '未知榜单',
      rankType: asInt(json['rankType']) ?? 0,
      // 幂等补一次 normalize：防止旧版本缓存混入 {size} 占位符死链。
      imageUrl: normalizeImageUrl(asString(json['imageUrl'])),
      updateFrequency: asString(json['updateFrequency']) ?? '',
      songs: (json['songs'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((s) => s.hash.isNotEmpty)
          .toList(),
      topPreviews: (json['previews'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RankPreviewSong.fromCache)
          .where((s) => s.title.isNotEmpty)
          .take(3)
          .toList(),
      children: (json['children'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RankCategory.fromCache)
          .toList(),
    );
  }
}

class RankSongPage {
  const RankSongPage({required this.songs, this.total = 0});

  final List<Song> songs;
  final int total;
}
