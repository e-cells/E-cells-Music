import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../core/api_client_interface.dart';
import '../core/rust_api_client.dart';
import '../models/music_models.dart';

part 'music_api_auth.dart';
part 'music_api_artist.dart';
part 'music_api_lyric.dart';
part 'music_api_lyric_parser.dart';
part 'music_api_mv.dart';
part 'music_api_playlist.dart';
part 'music_api_rank.dart';
part 'music_api_search.dart';
part 'music_api_song.dart';

/// 统一 API 门面。
///
/// 各领域方法（登录/歌单/排行/歌手/搜索/歌曲/歌词）以 [mixin] 形式拆分到
/// 同目录的 music_api_*.dart part 文件中，这里仅保留客户端状态。
/// 注意：域方法刻意保持为真实实例成员而非 extension——extension 走静态派发，
/// 会让测试替身（implements MusicApi 的 Fake）覆写的方法失效。
// 注意: _MusicApiSearch 声明 on _MusicApiBase, _MusicApiArtist, _MusicApiMv 声明 on
// _MusicApiBase, _MusicApiSearch,故 Artist 须在 Search 之前、Search 须在 Mv 之前,重排会编译失败。
class MusicApi extends _MusicApiBase
    with
        _MusicApiAuth,
        _MusicApiPlaylist,
        _MusicApiRank,
        _MusicApiArtist,
        _MusicApiSearch,
        _MusicApiSong,
        _MusicApiLyric,
        _MusicApiMv {
  MusicApi(super.client);

  String? get clientSessionId => _client.sessionId;
}

/// 各领域 mixin 共享的客户端状态（HTTP 通道）。
abstract class _MusicApiBase {
  _MusicApiBase(ApiClientInterface client) : _client = client;

  final ApiClientInterface _client;

  Object? _firstListValue(Map<String, dynamic> json) {
    for (final value in json.values) {
      if (value is List) {
        return value;
      }
      if (value is Map) {
        final nested = _firstListValue(asMap(value));
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }
}
