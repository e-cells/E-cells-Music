import 'model_parsing.dart';

enum AudioQuality {
  standard('128', '标准音质', '128K'),
  high('320', '高品音质', '320K'),
  lossless('flac', '无损音质', 'FLAC');

  const AudioQuality(this.apiValue, this.label, this.badge);

  final String apiValue;
  final String label;
  final String badge;

  static AudioQuality fromApiValue(String? value) {
    for (final quality in AudioQuality.values) {
      if (quality.apiValue == value) {
        return quality;
      }
    }
    return AudioQuality.standard;
  }
}

/// 歌曲来源平台。
enum SongSource {
  /// 酷狗音乐（默认）
  kugou,

  /// 网易云音乐
  netease,

  /// 本地音乐
  local,
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.hash,
    this.rawTitle,
    this.albumId,
    this.albumAudioId,
    this.albumName,
    this.coverUrl,
    this.duration,
    this.artists = const [],
    this.isCloudDrive = false,
    this.source = SongSource.kugou,
  });

  final String id;
  final String title;
  final String? rawTitle;
  final String artist;
  final String hash;
  final String? albumId;
  final String? albumAudioId;
  final String? albumName;
  final String? coverUrl;
  final Duration? duration;
  final List<ArtistRef> artists;

  /// 纯净歌名（已去除冗余歌手名前缀）。
  String get cleanTitle => title;

  /// 标记是否为云盘歌曲。云盘歌曲的播放地址需通过 `/user/cloud/url` 获取。
  final bool isCloudDrive;

  /// 歌曲来源平台。
  final SongSource source;

  Song copyWith({
    String? id,
    String? title,
    String? rawTitle,
    String? artist,
    String? hash,
    String? albumId,
    String? albumAudioId,
    String? albumName,
    String? coverUrl,
    Duration? duration,
    List<ArtistRef>? artists,
    bool? isCloudDrive,
    SongSource? source,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      rawTitle: rawTitle ?? this.rawTitle,
      artist: artist ?? this.artist,
      hash: hash ?? this.hash,
      albumId: albumId ?? this.albumId,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      albumName: albumName ?? this.albumName,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      artists: artists ?? this.artists,
      isCloudDrive: isCloudDrive ?? this.isCloudDrive,
      source: source ?? this.source,
    );
  }

  factory Song.fromSearch(Map<String, dynamic> json) {
    final songId =
        asString(json['MixSongID']) ??
        asString(json['mixsongid']) ??
        asString(json['songid']) ??
        asString(json['audio_id']) ??
        asString(json['fileid']);

    final hash =
        asString(json['FileHash']) ??
        asString(json['hash']) ??
        asString(json['hash_320']) ??
        asString(json['hash_flac']) ??
        '';
    final imageUrl =
        asString(json['Image']) ??
        asString(json['sizable_cover']) ??
        asString(json['img']);
    final artists = parseArtists(
      json,
      fallbackName:
          asString(json['SingerName']) ??
          asString(json['author_name']) ??
          asString(json['singername']) ??
          asString(json['singer_name']),
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : asString(json['SingerName']) ??
              asString(json['author_name']) ??
              asString(json['singername']) ??
              asString(json['singer_name']) ??
              '未知艺人';

    // 首选酷狗原始歌名：OriSongName 本身不带歌手前缀，Suffix 为「(Live)」
    // 等版本后缀；后缀为空时直接用歌名，避免多余空格。此路径已是纯净歌名，
    // 不再走前缀剥离。字段缺失（非标内容/历史接口）时回退到备选字段链，
    // 再经 cleanSongTitle 剥离「歌手 - 」前缀兜底。
    final oriSongName = asString(json['OriSongName']);
    final suffix = asString(json['Suffix']) ?? '';
    final oriTitle = oriSongName == null || oriSongName.isEmpty
        ? null
        : (suffix.isNotEmpty ? '$oriSongName $suffix' : oriSongName);

    final fallbackRaw =
        asString(json['songname']) ??
        asString(json['SongName']) ??
        asString(json['FileName']) ??
        asString(json['name']) ??
        asString(json['audio_name']) ??
        '未知歌曲';

    final rawTitle = oriTitle ?? fallbackRaw;
    final cleanedTitle =
        oriTitle ??
        cleanSongTitle(
          fallbackRaw,
          artist: resolvedArtist,
          artists: artists,
        );

    return Song(
      id: songId ?? hash,
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash: hash,
      albumId: asString(json['AlbumID']) ?? asString(json['album_id']),
      albumAudioId: songId,
      albumName: asString(json['AlbumName']) ?? asString(json['album_name']),
      coverUrl: normalizeImageUrl(imageUrl),
      artists: artists,
      duration:
          durationFromSeconds(json['Duration']) ??
          durationFromMilliseconds(json['timelen']) ??
          durationFromSeconds(json['time_length']) ??
          durationFromSeconds(json['duration']),
    );
  }

  factory Song.fromTopSong(Map<String, dynamic> json) {
    final hash =
        asString(json['hash']) ??
        asString(json['hash_320']) ??
        asString(json['hash_flac']) ??
        '';
    final audioId =
        asString(json['audio_id']) ?? asString(json['album_audio_id']);
    final author = asString(json['author_name']) ?? '未知艺人';
    final artists = parseArtists(json, fallbackName: author);
    final rawTitle =
        asString(json['songname']) ?? asString(json['filename']) ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: author,
      artists: artists,
    );

    return Song(
      id: audioId ?? hash,
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: author,
      hash: hash,
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['album_audio_id']),
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(asString(json['album_sizable_cover'])),
      duration: durationFromMilliseconds(json['timelength']),
      artists: artists,
    );
  }

  factory Song.fromDaily(Map<String, dynamic> json) {
    final songId = asString(json['songid']) ?? asString(json['audio_id']);
    final artists = parseArtists(
      json,
      fallbackName: asString(json['author_name']),
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : asString(json['author_name']) ?? '未知艺人';
    final rawTitle =
        asString(json['songname']) ?? asString(json['audio_name']) ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );

    return Song(
      id: asString(json['mixsongid']) ?? songId ?? asString(json['hash']) ?? '',
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash:
          asString(json['hash']) ??
          asString(json['hash_320']) ??
          asString(json['hash_flac']) ??
          '',
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['mixsongid']) ?? songId,
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(asString(json['sizable_cover'])),
      artists: artists,
      duration: durationFromSeconds(json['time_length']),
    );
  }

  factory Song.fromPlaylist(Map<String, dynamic> json) {
    final artists = parseArtists(json);
    final artist = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artist.isNotEmpty ? artist : '未知艺人';
    final albumInfo = json['albuminfo'];
    final albumMap = albumInfo is Map<String, dynamic> ? albumInfo : null;
    final hash =
        asString(json['hash']) ??
        asString(json['hash_320']) ??
        asString(json['hash_flac']) ??
        asString(json['FileHash']) ??
        '';

    final rawTitle =
        asString(json['name']) ?? asString(json['audio_name']) ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );

    return Song(
      id: asString(json['fileid']) ?? asString(json['mixsongid']) ?? hash,
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash: hash,
      albumId:
          asString(json['album_id']) ??
          asString(albumMap?['album_id']) ??
          asString(albumMap?['id']),
      albumAudioId:
          asString(json['mixsongid']) ??
          asString(json['album_audio_id']) ??
          asString(json['audio_id']),
      albumName:
          asString(albumMap?['name']) ??
          asString(albumMap?['album_name']) ??
          asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(json['cover']) ??
            asString(albumMap?['sizable_cover']) ??
            asString(albumMap?['cover']),
      ),
      artists: artists,
      duration: durationFromMilliseconds(json['timelen']),
    );
  }

  factory Song.fromArtistAudio(Map<String, dynamic> json, {String? artistId}) {
    var artists = parseArtists(
      json,
      fallbackName: asString(json['author_name']),
    );
    final authorName = asString(json['author_name']);
    if (artistId != null &&
        artistId.isNotEmpty &&
        authorName != null &&
        artists.every((artist) => artist.id.isEmpty)) {
      artists = [ArtistRef(id: artistId, name: authorName)];
    }
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : authorName ?? '未知艺人';
    final rawTitle =
        asString(json['audio_name']) ?? asString(json['name']) ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );
    final transParam = asMap(json['trans_param']);

    return Song(
      id:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['hash']) ??
          '',
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash: asString(json['hash']) ?? '',
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['album_audio_id']),
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(transParam['union_cover']) ??
            asString(json['sizable_cover']) ??
            asString(json['cover']),
      ),
      artists: artists,
      duration:
          durationFromMilliseconds(json['timelength']) ??
          durationFromMilliseconds(json['timelen']),
    );
  }

  factory Song.fromFm(Map<String, dynamic> json) {
    final displayName =
        asString(json['audio_name']) ??
        asString(json['songname']) ??
        asString(json['name']);
    final splitName = _splitSongDisplayName(displayName);
    final artists = parseArtists(
      json,
      fallbackName:
          asString(json['author_name']) ??
          asString(json['SingerName']) ??
          splitName.artist,
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : splitName.artist ?? '未知艺人';
    final rawTitle = splitName.title ?? displayName ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );
    final transParam = asMap(json['trans_param']);

    return Song(
      id:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['sid']) ??
          asString(json['hash']) ??
          '',
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash:
          asString(json['hash']) ??
          asString(json['FileHash']) ??
          asString(json['320hash']) ??
          asString(json['hash_320']) ??
          asString(json['hash_flac']) ??
          '',
      albumId: asString(json['album_id']),
      albumAudioId:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(json['sid']),
      albumName: asString(json['album_name']),
      coverUrl: normalizeImageUrl(
        asString(transParam['union_cover']) ??
            asString(json['sizable_cover']) ??
            asString(json['cover']) ??
            asString(json['imgurl']),
      ),
      artists: artists,
      duration:
          durationFromMilliseconds(json['time']) ??
          durationFromMilliseconds(json['320time']) ??
          durationFromMilliseconds(json['timelen']) ??
          durationFromMilliseconds(json['timelength']),
    );
  }

  factory Song.fromAlbum(Map<String, dynamic> json) {
    final base = asMap(json['base']);
    final audioInfo = asMap(json['audio_info']);
    final albumInfo = asMap(json['album_info']);
    final authorsRaw = asList(
      json['authors'],
    ).whereType<Map<String, dynamic>>();
    final artists = authorsRaw
        .map(
          (item) => ArtistRef(
            id: asString(item['author_id']) ?? '',
            name: asString(item['author_name']) ?? '',
          ),
        )
        .where((artist) => artist.name.isNotEmpty)
        .toList();
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : asString(base['author_name']) ?? '未知艺人';
    final rawTitle = asString(base['audio_name']) ?? '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );

    return Song(
      id:
          asString(audioInfo['hash']) ??
          asString(base['album_id']) ??
          asString(json['id']) ??
          '',
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash: asString(audioInfo['hash']) ?? '',
      albumId: asString(base['album_id']),
      albumAudioId: asString(audioInfo['hash']) ?? asString(json['id']),
      albumName: asString(albumInfo['album_name']),
      coverUrl: normalizeImageUrl(asString(albumInfo['cover'])),
      artists: artists,
      duration: durationFromMilliseconds(audioInfo['duration']),
    );
  }

  factory Song.fromRank(Map<String, dynamic> json) {
    // 兼容两种格式：
    // 1. 扁平格式：hash/filename/singername 在顶层
    // 2. 嵌套格式：base/audio_info/album_info（与 fromAlbum 相同）
    final base = asMap(json['base']);
    final audioInfo = asMap(json['audio_info']);
    final albumInfo = asMap(json['album_info']);

    final artists = parseArtists(
      json,
      fallbackName:
          asString(json['singername']) ??
          asString(json['author_name']) ??
          asString(json['singer_name']) ??
          asString(base['author_name']),
    );
    final artistName = artists.map((a) => a.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : asString(json['singername']) ??
              asString(json['author_name']) ??
              asString(base['author_name']) ??
              '未知艺人';
    final rawTitle =
        asString(json['songname']) ??
        asString(json['filename']) ??
        asString(json['audio_name']) ??
        asString(json['name']) ??
        asString(base['audio_name']) ??
        '未知歌曲';
    final cleanedTitle = cleanSongTitle(
      rawTitle,
      artist: resolvedArtist,
      artists: artists,
    );

    final hash =
        asString(json['hash']) ??
        asString(json['hash_320']) ??
        asString(json['hash_flac']) ??
        asString(json['hash_128']) ??
        asString(audioInfo['hash']) ??
        asString(audioInfo['hash_320']) ??
        asString(audioInfo['hash_flac']) ??
        asString(audioInfo['hash_128']) ??
        asString(audioInfo['hash_high']) ??
        '';

    return Song(
      id:
          asString(json['album_audio_id']) ??
          asString(json['audio_id']) ??
          asString(audioInfo['hash_128']) ??
          asString(audioInfo['hash']) ??
          asString(json['hash']) ??
          '',
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: resolvedArtist,
      hash: hash,
      albumId: asString(json['album_id']) ?? asString(base['album_id']),
      albumAudioId:
          asString(json['album_audio_id']) ??
          asString(audioInfo['hash_128']) ??
          asString(audioInfo['hash']) ??
          asString(json['hash']),
      albumName:
          asString(json['album_name']) ?? asString(albumInfo['album_name']),
      coverUrl: normalizeImageUrl(
        asString(json['sizable_cover']) ??
            asString(json['img']) ??
            asString(json['cover']) ??
            asString(albumInfo['sizable_cover']) ??
            asString(albumInfo['cover']),
      ),
      artists: artists,
      duration:
          durationFromSeconds(json['time_length']) ??
          durationFromMilliseconds(json['timelen']) ??
          durationFromMilliseconds(json['timelength']) ??
          durationFromMilliseconds(audioInfo['duration']) ??
          durationFromMilliseconds(audioInfo['duration_128']) ??
          durationFromMilliseconds(audioInfo['duration_320']) ??
          durationFromMilliseconds(audioInfo['duration_flac']) ??
          durationFromMilliseconds(audioInfo['duration_high']),
    );
  }

  Map<String, dynamic> toCache() => {
    'id': id,
    'title': title,
    if (rawTitle != null) 'rawTitle': rawTitle,
    'artist': artist,
    'hash': hash,
    'albumId': albumId,
    'albumAudioId': albumAudioId,
    'albumName': albumName,
    'coverUrl': coverUrl,
    'durationMs': duration?.inMilliseconds,
    'artists': artists
        .map((a) => {'id': a.id, 'name': a.name, 'avatarUrl': a.avatarUrl})
        .toList(),
    if (isCloudDrive) 'isCloudDrive': true,
    if (source != SongSource.kugou) 'source': source.name,
  };

  factory Song.fromCache(Map<String, dynamic> json) {
    final title = asString(json['title']) ?? '未知歌曲';
    final rawTitle = asString(json['rawTitle']);
    final artist = asString(json['artist']) ?? '未知艺人';
    final artists = asList(json['artists'])
        .whereType<Map<String, dynamic>>()
        .map(
          (a) => ArtistRef(
            id: asString(a['id']) ?? '',
            name: asString(a['name']) ?? '',
            avatarUrl: asString(a['avatarUrl']),
          ),
        )
        .where((artist) => artist.name.isNotEmpty)
        .toList();
    // [toCache] 写入的 title 已是清洗结果，这里直接使用：
    // cleanSongTitle 非幂等，对「X - Y - Z」型标题二次清洗会继续切割丢前缀。
    // rawTitle 缺失就保持缺失，不回填清洗后标题（否则原始名永久丢失）。
    return Song(
      id: asString(json['id']) ?? '',
      title: title,
      rawTitle: rawTitle,
      artist: artist,
      hash: asString(json['hash']) ?? '',
      albumId: asString(json['albumId']),
      albumAudioId: asString(json['albumAudioId']),
      albumName: asString(json['albumName']),
      // 幂等补一次 normalize：隐式依赖「写入侧已 normalize」太脆，旧版本
      // 缓存或异常路径混入 {size} 占位符时会变成死链。
      coverUrl: normalizeImageUrl(asString(json['coverUrl'])),
      duration: durationFromMilliseconds(json['durationMs']),
      artists: artists,
      isCloudDrive: json['isCloudDrive'] == true,
      source: json['source'] is String
          ? SongSource.values.firstWhere(
              (s) => s.name == json['source'],
              orElse: () => SongSource.kugou,
            )
          : SongSource.kugou,
    );
  }
}

class _SongDisplayName {
  const _SongDisplayName({this.artist, this.title});

  final String? artist;
  final String? title;
}

_SongDisplayName _splitSongDisplayName(String? value) {
  if (value == null) {
    return const _SongDisplayName();
  }

  final separator = RegExp(r'\s[-–—]\s');
  final match = separator.firstMatch(value);
  if (match == null) {
    return _SongDisplayName(title: value);
  }

  final artist = value.substring(0, match.start).trim();
  final title = value.substring(match.end).trim();
  return _SongDisplayName(
    artist: artist.isEmpty ? null : artist,
    title: title.isEmpty ? value : title,
  );
}

/// 清洗歌曲名称，剥离多余的「歌手名 - 」前缀，保留纯正歌名。
///
/// 当 [rawTitle] 包含 `歌手名 - 歌名` 格式，且前半部与 [artist] / [artists] 匹配时，
/// 自动剔除前半部与分隔符。若前半部与歌手无关（例如《Part 1 - The Beginning》），
/// 则安全保留原名不误切。
String cleanSongTitle(
  String? rawTitle, {
  String? artist,
  List<ArtistRef>? artists,
}) {
  if (rawTitle == null) {
    return '未知歌曲';
  }
  final trimmed = rawTitle.trim();
  if (trimmed.isEmpty) {
    return '未知歌曲';
  }

  final separator = RegExp(r'\s+[-–—]\s+');
  final match = separator.firstMatch(trimmed);
  if (match == null) {
    return trimmed;
  }

  final prefix = trimmed.substring(0, match.start).trim();
  final suffix = trimmed.substring(match.end).trim();
  if (suffix.isEmpty || prefix.isEmpty) {
    return trimmed;
  }

  final cleanArtist = artist?.trim();
  final isUnknownArtist =
      cleanArtist == null ||
      cleanArtist.isEmpty ||
      cleanArtist == '未知艺人' ||
      cleanArtist == '群星';

  if (isUnknownArtist) {
    return suffix;
  }

  final prefixNorm = prefix.toLowerCase();
  final artistNorm = cleanArtist.toLowerCase();

  // 1. 完全相同
  if (prefixNorm == artistNorm) {
    return suffix;
  }

  // 2. 归一化多歌手分隔符（支持 /、\、顿号、逗号、& 等）
  String normArtists(String s) => s
      .toLowerCase()
      .split(RegExp(r'[/、\\,，&+]|\s+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(' ');

  if (normArtists(prefix) == normArtists(cleanArtist)) {
    return suffix;
  }

  // 3. 检查 artists 引用列表
  if (artists != null &&
      artists.any((a) => a.name.trim().toLowerCase() == prefixNorm)) {
    return suffix;
  }

  // 4. 检查 prefix 是否为 cleanArtist 中的任一子歌手
  final subArtists = cleanArtist
      .split(RegExp(r'[/、\\,，&+]'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (subArtists.contains(prefixNorm)) {
    return suffix;
  }

  // 5. 若 prefix 包含多个歌手，且每一个都在 cleanArtist 里
  final prefixSubArtists = prefix
      .split(RegExp(r'[/、\\,，&+]'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (prefixSubArtists.isNotEmpty &&
      prefixSubArtists.every((pa) => artistNorm.contains(pa))) {
    return suffix;
  }

  // 不匹配歌手前缀，安全保留原标题
  return trimmed;
}

class ArtistRef {
  const ArtistRef({required this.id, required this.name, this.avatarUrl});

  final String id;
  final String name;
  final String? avatarUrl;
}

List<ArtistRef> parseArtists(
  Map<String, dynamic> json, {
  String? fallbackName,
}) {
  final artists = <ArtistRef>[];
  void addFromMap(Map<String, dynamic> item) {
    final id =
        asString(item['id']) ??
        asString(item['author_id']) ??
        asString(item['AuthorID']) ??
        asString(item['AuthorId']) ??
        asString(item['singerid']) ??
        asString(item['singer_id']) ??
        asString(item['SingerId']) ??
        asString(item['SingerID']) ??
        asString(item['singer_id_new']) ??
        asString(item['encode_singer_id']) ??
        asString(item['singerId']) ??
        asString(item['authorId']);
    final name =
        asString(item['name']) ??
        asString(item['author_name']) ??
        asString(item['SingerName']) ??
        asString(item['singername']) ??
        asString(item['singer_name']) ??
        asString(item['singerName']) ??
        asString(item['authorName']);
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return;
    }
    if (artists.any((artist) => artist.id == id)) {
      return;
    }
    artists.add(
      ArtistRef(
        id: id,
        name: name,
        avatarUrl: normalizeImageUrl(
          asString(item['sizable_avatar']) ?? asString(item['avatar']),
        ),
      ),
    );
  }

  for (final key in const [
    'singerinfo',
    'authors',
    'author',
    'singers',
    'Singers',
  ]) {
    final value = json[key];
    if (value is List) {
      for (final item in value.whereType<Map<String, dynamic>>()) {
        addFromMap(item);
      }
    } else if (value is Map<String, dynamic>) {
      addFromMap(value);
    }
  }

  addFromMap(json);

  if (artists.isEmpty && fallbackName != null && fallbackName.isNotEmpty) {
    final names = fallbackName
        .split(RegExp(r'\s*[/、,，&]\s*'))
        .where((name) => name.trim().isNotEmpty);
    for (final name in names) {
      artists.add(ArtistRef(id: '', name: name.trim()));
    }
  }
  return artists;
}

class PlayUrl {
  const PlayUrl({required this.url, required this.hash, this.privStatus = 0});

  final String url;
  final String hash;

  /// 权限状态：1 = 需要 VIP，10 = 需要购买专辑。
  /// 上游可能返回 integer 或 string，统一用 asInt 解析。
  final int privStatus;

  bool get requiresVip => privStatus == 1;

  factory PlayUrl.fromJson(Map<String, dynamic> json) {
    final urls = asList(json['url']).whereType<String>().toList();
    return PlayUrl(
      url: urls.isNotEmpty ? urls.first : '',
      hash: asString(json['hash']) ?? '',
      privStatus: asInt(json['priv_status']) ?? 0,
    );
  }
}

/// 播放地址需要 VIP 权限时抛出，供播放器捕获后自动领取并重试。
class VipRequiredException implements Exception {
  const VipRequiredException([this.message = '该歌曲需要 VIP 才能播放']);

  final String message;

  @override
  String toString() => message;
}

class LyricLine {
  const LyricLine({
    required this.time,
    required this.text,
    this.duration,
    this.translation,
    this.romanization,
    this.words = const [],
  });

  final Duration time;
  final String text;
  final Duration? duration;
  final String? translation;
  final String? romanization;
  final List<LyricWord> words;

  LyricLine copyWith({String? translation, String? romanization}) {
    return LyricLine(
      time: time,
      text: text,
      duration: duration,
      translation: translation ?? this.translation,
      romanization: romanization ?? this.romanization,
      words: words,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricLine &&
        other.time == time &&
        other.text == text &&
        other.duration == duration &&
        other.translation == translation &&
        other.romanization == romanization &&
        _lyricWordsEqual(other.words, words);
  }

  @override
  int get hashCode => Object.hash(
    time,
    text,
    duration,
    translation,
    romanization,
    Object.hashAll(words),
  );

  int activeWordIndex(Duration position) {
    if (words.isEmpty) {
      return -1;
    }
    var active = -1;
    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      if (position >= word.time) {
        active = index;
      } else {
        break;
      }
    }
    return active;
  }

  Map<String, dynamic> toCache() => {
    'timeMs': time.inMilliseconds,
    'text': text,
    'durationMs': duration?.inMilliseconds,
    'translation': translation,
    'romanization': romanization,
    'words': words.map((w) => w.toCache()).toList(),
  };

  factory LyricLine.fromCache(Map<String, dynamic> json) {
    return LyricLine(
      time: Duration(milliseconds: asInt(json['timeMs']) ?? 0),
      text: asString(json['text']) ?? '',
      duration: durationFromMilliseconds(json['durationMs']),
      translation: asString(json['translation']),
      romanization: asString(json['romanization']),
      words: (json['words'] as List? ?? const [])
          .whereType<Map>()
          .map((w) => LyricWord.fromCache(asMap(w)))
          .toList(),
    );
  }
}

/// 词曲作者（从歌词正文提取的弱数据：有就展示，无则隐藏对应行）。
class LyricCredits {
  const LyricCredits({this.lyricist, this.composer});

  /// 作词。
  final String? lyricist;

  /// 作曲。
  final String? composer;

  bool get isEmpty => lyricist == null && composer == null;
}

/// 从歌词正文提取词曲作者：大量 LRC/KRC 头部即 `作词：xxx` / `作曲：xxx`。
///
/// 只扫前 [maxLines] 行（署名行都在头部）；冒号兼容半角/全角；
/// 命中多条时取第一条。无命中返回空 [LyricCredits]，调用方隐藏对应行。
LyricCredits extractLyricCredits(List<LyricLine> lines, {int maxLines = 12}) {
  String? lyricist;
  String? composer;
  // 行首允许残留时间标签（如 `[00:00.00]`，未解析的原始行也能处理）。
  final pattern = RegExp(r'^(?:\[[^\]]*\]\s*)*(作词|作曲)\s*[:：]\s*(.+?)\s*$');
  for (final line in lines.take(maxLines)) {
    final match = pattern.firstMatch(line.text.trim());
    if (match == null) continue;
    final name = match.group(2)!.trim();
    if (name.isEmpty) continue;
    if (match.group(1) == '作词') {
      lyricist ??= name;
    } else {
      composer ??= name;
    }
    if (lyricist != null && composer != null) break;
  }
  return LyricCredits(lyricist: lyricist, composer: composer);
}

class LyricWord {
  const LyricWord({
    required this.time,
    required this.duration,
    required this.text,
  });

  final Duration time;
  final Duration duration;
  final String text;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricWord &&
        other.time == time &&
        other.duration == duration &&
        other.text == text;
  }

  @override
  int get hashCode => Object.hash(time, duration, text);

  Map<String, dynamic> toCache() => {
    'timeMs': time.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'text': text,
  };

  factory LyricWord.fromCache(Map<String, dynamic> json) {
    return LyricWord(
      time: Duration(milliseconds: asInt(json['timeMs']) ?? 0),
      duration: Duration(milliseconds: asInt(json['durationMs']) ?? 0),
      text: asString(json['text']) ?? '',
    );
  }
}

/// 逐字歌词列表的值比较（LyricLine == 的辅助，避免 List == 走同一性）。
bool _lyricWordsEqual(List<LyricWord> a, List<LyricWord> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 歌曲高潮片段信息（/song/climax）。
class SongClimax {
  const SongClimax({
    required this.startTime,
    required this.endTime,
    required this.hash,
  });

  final Duration startTime;
  final Duration endTime;
  final String hash;

  bool get isValid => endTime > startTime && endTime > Duration.zero;

  factory SongClimax.fromJson(Map<String, dynamic> json) {
    return SongClimax(
      startTime: Duration(milliseconds: asInt(json['start_time']) ?? 0),
      endTime: Duration(milliseconds: asInt(json['end_time']) ?? 0),
      hash: asString(json['hash']) ?? '',
    );
  }
}
