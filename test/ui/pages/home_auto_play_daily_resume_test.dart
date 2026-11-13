// 开机播放内容为「每日推荐」且上次保存的队列与本次推荐逐位一致时：
//   不回第一首重头播，走 resumePlayback 从上次的当前歌继续。
//
// 本文件只放一个消费自动播放的测例：HomePage 的 _hasAutoPlayed 是
// static，同文件内跨测例不重置，多测例会拿到首例的残留状态。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/home_page.dart';

class _FakeMusicApi implements MusicApi {
  List<Song> dailySongs = const [];

  @override
  Future<DailyRecommend> dailyRecommend() async =>
      DailyRecommend(title: '每日推荐', songs: dailySongs);

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async => const [];

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      const [];

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AutoPlayFakePlayerController extends ChangeNotifier
    implements PlayerController {
  // 首页歌曲行等 UI 构建期会读的基础字段（与 home_auto_play_daily_test
  // 的 fake 同口径）。
  @override
  Song? currentSong;
  @override
  bool isPlaying = false;
  @override
  bool isPreparing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  @override
  String? errorMessage;
  @override
  List<Song> queue = [];

  // 开机自启播放开启 + 偏好每日推荐 + 有可恢复的上次播放状态。
  @override
  bool autoPlayOnStartupEnabled = true;
  @override
  String startupPlaySource = 'daily';
  @override
  bool hasRestoredPlaybackState = true;

  // 启动恢复完成信号：真实控制器由构造函数的两路恢复 whenComplete 放行。
  @override
  Future<void> get startupRestored => Future<void>.value();

  final List<Song> playedSongs = [];
  final List<List<Song>> playedQueues = [];
  bool resumed = false;

  // 命名参数必须带全（与 PlayerController.playSong 契约一致），
  // 否则 override 编译不过。
  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    playedSongs.add(song);
    playedQueues.add(queue ?? const []);
  }

  @override
  Future<bool> resumePlayback() async {
    resumed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => true;
  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
  @override
  int get likedCount => 0;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async =>
      null;

  @override
  Future<void> write(String key, Map<String, dynamic> payload) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloadController extends ChangeNotifier
    implements DownloadController {
  @override
  List<Song> get downloadedSongs => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalMusicController extends ChangeNotifier
    implements LocalMusicController {
  @override
  List<Song> get songs => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int i) => Song(
      id: 'id_$i',
      title: '歌曲_$i',
      artist: '歌手_$i',
      hash: 'hash_$i',
    );

void main() {
  ThemeController();

  testWidgets('上次队列与每日推荐逐位一致时从上次的歌继续播放', (tester) async {
    debugDesktopFormFactorOverride = false;
    // 避开 Windows 分支的 300ms 延迟：fake async 下 pumpAndSettle 可能
    // 在延迟定时器触发前提前返回。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(400, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 模拟「播到第 4 首后重启」：恢复出的队列就是这份推荐列表，
      // 当前歌停在第 4 首（索引 3）。
      final dailySongs = List.generate(8, (i) => _song(i));
      final api = _FakeMusicApi()..dailySongs = dailySongs;
      final player = _AutoPlayFakePlayerController()
        ..queue = List.of(dailySongs)
        ..currentSong = dailySongs[3];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              api: api,
              auth: _FakeAuthController(),
              player: player,
              cache: _FakeCache(),
              theme: ThemeController(),
              downloads: _FakeDownloadController(),
              localMusic: _FakeLocalMusicController(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 队列一致：走 resumePlayback（从上次的当前歌继续），
      // 不回第一首整队重播。
      expect(player.resumed, isTrue);
      expect(player.playedSongs, isEmpty);
      expect(player.playedQueues, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      debugDesktopFormFactorOverride = null;
    }
  });
}
