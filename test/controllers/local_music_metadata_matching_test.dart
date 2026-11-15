import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

class _FakeMusicApi extends Fake implements MusicApi {
  List<Song> searchResult = [];
  List<LyricLine> lyricResult = [];
  String? lastSearchKeyword;
  Song? lastLyricSong;

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    lastSearchKeyword = keywords;
    return searchResult;
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    lastLyricSong = song;
    return lyricResult;
  }
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  final Duration _position = Duration.zero;
  final bool _playing = false;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _processingStateController.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream =>
      _androidAudioSessionIdController.stream;

  @override
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => _position;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  int? get androidAudioSessionId => null;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
    _errorController.close();
  }
}

class _FakeMusicAudioHandler extends Fake implements MusicAudioHandler {
  _FakeMusicAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;
  Song? lastUpdatedSong;

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  void attachVoiceSearch({
    required Future<void> Function(String query) onVoiceSearch,
  }) {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> close() async {}

  @override
  void updateCurrentSong(Song song) {
    lastUpdatedSong = song;
  }
}

class _FakeLocalMusicController extends Fake implements LocalMusicController {
  String? mockEmbeddedLyrics;
  String? mockEmbeddedCover;
  String? lastUpdatedSongId;
  String? lastUpdatedCoverUrl;

  @override
  Future<String?> getEmbeddedLyrics(String filePath) async {
    return mockEmbeddedLyrics;
  }

  @override
  Future<String?> getOrExtractEmbeddedCover(Song song) async {
    return mockEmbeddedCover;
  }

  @override
  void updateSongCover(String songId, String coverUrl) {
    lastUpdatedSongId = songId;
    lastUpdatedCoverUrl = coverUrl;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeMusicApi api;
  late _FakeMusicAudioHandler audioHandler;
  late _FakeAudioPlayer audioPlayer;
  late PlayerController player;
  late _FakeLocalMusicController localMusic;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = _FakeMusicApi();
    audioPlayer = _FakeAudioPlayer();
    audioHandler = _FakeMusicAudioHandler(audioPlayer);
    player = PlayerController(api, audioHandler);
    localMusic = _FakeLocalMusicController();
    player.localMusic = localMusic;
  });

  tearDown(() async {
    player.dispose();
    audioPlayer.disposeStreams();
  });

  group('本地音乐播放时歌词与封面检查与匹配测试', () {
    test('1. 本地歌曲有内嵌歌词时，加载内嵌歌词且不触发网络搜索', () async {
      const localSong = Song(
        id: '/storage/emulated/0/Music/test.mp3',
        title: '七里香',
        artist: '周杰伦',
        hash: '/storage/emulated/0/Music/test.mp3',
        source: SongSource.local,
      );

      localMusic.mockEmbeddedLyrics = '[00:01.00]窗外的麻雀\n[00:03.00]在电线杆上多嘴';
      player.currentSong = localSong;

      await player.loadLyrics(localSong);

      expect(player.lyrics.length, 2);
      expect(player.lyrics.first.text, '窗外的麻雀');
      expect(api.lastSearchKeyword, isNull, reason: '有内嵌歌词时不应联网搜索');
    });

    test('2. 本地歌曲无内嵌歌词时，联网搜索匹配并加载网络歌词', () async {
      const localSong = Song(
        id: '/storage/emulated/0/Music/test2.mp3',
        title: '晴天',
        artist: '周杰伦',
        hash: '/storage/emulated/0/Music/test2.mp3',
        source: SongSource.local,
      );

      localMusic.mockEmbeddedLyrics = null;
      api.searchResult = [
        const Song(
          id: '123',
          title: '晴天',
          artist: '周杰伦',
          hash: 'matched_hash_123',
          coverUrl: 'http://imge.kugou.com/test_cover.jpg',
        ),
      ];
      api.lyricResult = [
        const LyricLine(time: Duration(seconds: 1), text: '故事的小黄花'),
      ];

      player.currentSong = localSong;
      await player.loadLyrics(localSong);

      expect(api.lastSearchKeyword, '晴天 周杰伦');
      expect(player.lyrics.length, 1);
      expect(player.lyrics.first.text, '故事的小黄花');
      // 若当前歌曲无封面，歌词匹配时还顺便补齐了封面
      expect(localMusic.lastUpdatedCoverUrl, 'http://imge.kugou.com/test_cover.jpg');
    });

    test('3. 本地歌曲有内嵌封面与内嵌歌词时，直接使用本地内嵌且不触发网络匹配', () async {
      const localSong = Song(
        id: '/storage/emulated/0/Music/test3.mp3',
        title: '稻香',
        artist: '周杰伦',
        hash: '/storage/emulated/0/Music/test3.mp3',
        source: SongSource.local,
      );

      localMusic.mockEmbeddedCover = '/data/user/0/cache/embedded_covers/test3.jpg';
      localMusic.mockEmbeddedLyrics = '[00:01.00]对这个世界如果你有太多的抱怨';

      player.currentSong = localSong;
      await player.playSong(localSong);

      // 等待异步封面检查完成
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(localMusic.lastUpdatedCoverUrl, '/data/user/0/cache/embedded_covers/test3.jpg');
      expect(player.currentSong?.coverUrl, '/data/user/0/cache/embedded_covers/test3.jpg');
      expect(audioHandler.lastUpdatedSong?.coverUrl, '/data/user/0/cache/embedded_covers/test3.jpg');
      expect(api.lastSearchKeyword, isNull, reason: '有内嵌封面时不应网络匹配封面');
    });

    test('4. 本地歌曲无内嵌封面时，联网匹配封面并更新系统通知栏与列表', () async {
      const localSong = Song(
        id: '/storage/emulated/0/Music/test4.mp3',
        title: '夜曲',
        artist: '周杰伦',
        hash: '/storage/emulated/0/Music/test4.mp3',
        source: SongSource.local,
      );

      localMusic.mockEmbeddedCover = null;
      api.searchResult = [
        const Song(
          id: '456',
          title: '夜曲',
          artist: '周杰伦',
          hash: 'matched_hash_456',
          coverUrl: 'http://imge.kugou.com/yequ_cover.jpg',
        ),
      ];

      player.currentSong = localSong;
      await player.playSong(localSong);

      // 等待异步封面匹配完成
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(api.lastSearchKeyword, '夜曲 周杰伦');
      expect(localMusic.lastUpdatedCoverUrl, 'http://imge.kugou.com/yequ_cover.jpg');
      expect(player.currentSong?.coverUrl, 'http://imge.kugou.com/yequ_cover.jpg');
      expect(audioHandler.lastUpdatedSong?.coverUrl, 'http://imge.kugou.com/yequ_cover.jpg');
    });

    test('5. Song.copyWith 能够正确更新属性', () {
      const song = Song(
        id: '1',
        title: 'Title',
        artist: 'Artist',
        hash: 'hash',
        source: SongSource.local,
      );
      final updated = song.copyWith(coverUrl: '/path/to/cover.jpg');
      expect(updated.coverUrl, '/path/to/cover.jpg');
      expect(updated.title, 'Title');
      expect(updated.source, SongSource.local);
    });
  });
}
