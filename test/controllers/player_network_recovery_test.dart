// 断网自动恢复 watchdog（车机过隧道场景）：
// - 链路在、数据不通（connectivity 全程 wifi/mobile）时，中途断流落
//   错误态后由周期探测兜底：外网恢复 → 从断点自动续播（isRetry）。
// - 链路真断（connectivity none）时不武装：恢复由 onConnectivityRestored
//   钩子的"断→通"跃迁负责。
// - 本地歌曲/确定性失败不武装，避免坏源被探测牵着无限重播。
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/services/network_monitor.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  Duration _position = Duration.zero;
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;

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
  ProcessingState get processingState => _processingState;

  @override
  int? get androidAudioSessionId => null;

  void setPosition(Duration pos) {
    _position = pos;
    _positionController.add(pos);
  }

  void emitPlayerState({required bool playing, ProcessingState? state}) {
    if (state != null) {
      _processingState = state;
    }
    _playing = playing;
    _playerStateController.add(PlayerState(playing, _processingState));
    _processingStateController.add(_processingState);
  }

  void emitError(PlayerException error) {
    _errorController.add(error);
  }

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
    _errorController.close();
  }
}

class _RecordingAudioHandler extends Fake implements MusicAudioHandler {
  _RecordingAudioHandler(this._audioPlayer);

  final _FakeAudioPlayer _audioPlayer;
  final List<String> loadedHashes = [];
  final List<Duration> seekPositions = [];
  int playCount = 0;
  int pauseCount = 0;

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
  Future<void> seek(Duration position, [dynamic options]) async {
    seekPositions.add(position);
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    loadedHashes.add(song.hash);
  }

  @override
  Future<void> play() async {
    playCount++;
    _audioPlayer.emitPlayerState(playing: true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _audioPlayer.emitPlayerState(playing: false);
  }

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index, {Duration? duration}) => Song(
  id: 'song_$index',
  title: '歌曲$index',
  artist: '歌手$index',
  hash: 'hash_$index',
  duration: duration ?? const Duration(seconds: 210),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 注意：controller 必须在 testWidgets 体内创建——setUp 运行在 fakeAsync
  // 之外，其中建立的 stream 订阅回调属于根 zone，回调里创建的 Timer 是
  // 真实时钟计时器，fake pump 永远等不到（watchdog 的周期探测就建在
  // errorStream 回调里）。体内创建让整条链留在 fake zone。
  late _FakeAudioPlayer fakeAudioPlayer;
  late _RecordingAudioHandler handler;
  late PlayerController controller;

  Future<void> makeController() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _RecordingAudioHandler(fakeAudioPlayer);
    controller = PlayerController(_MockMusicApi(), handler);
  }

  tearDown(() {
    NetworkMonitor.probeOverride = null;
    NetworkMonitor.instance.debugSetResults(const [ConnectivityResult.wifi]);
  });

  Future<void> pumpToastHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Toast.navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanUpToastAndSettle(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  /// 起播一首歌并模拟"播放到 50 秒"。
  Future<void> playToMiddle(WidgetTester tester) async {
    final song = _song(1);
    controller.queue = [song];
    await controller.playSong(song);
    await tester.pump();
    fakeAudioPlayer.setPosition(const Duration(seconds: 50));
    await tester.pump();
    expect(controller.isPlaying, isTrue);
  }

  testWidgets('隧道断流：中途错误落错误态，外网探测恢复后从断点续播', (tester) async {
    await makeController();
    await pumpToastHost(tester);
    // 隧道形态：链路始终在线（wifi），探测最初不通、随后恢复。
    NetworkMonitor.instance.debugSetResults(const [ConnectivityResult.wifi]);
    var reachable = false;
    NetworkMonitor.probeOverride = (_) async => reachable;

    await playToMiddle(tester);
    final song = controller.currentSong!;
    expect(handler.loadedHashes, [song.hash]);

    // 断流错误（远离曲尾，走"播放中断"路径）。
    fakeAudioPlayer.emitError(
      PlayerException(1, 'ffmpeg: tcp: Connection reset by peer', 0),
    );
    await tester.pump();

    expect(controller.isPlaying, isFalse);
    expect(controller.errorMessage, isNotNull);

    // 还在隧道里：两个探测周期都失败，不重播。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(handler.loadedHashes, hasLength(1));
    expect(controller.isPlaying, isFalse);

    // 出隧道：下一次探测成功 → 自动从断点（50s）续播。
    reachable = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(handler.loadedHashes, hasLength(2), reason: '应重新 loadSong 续播');
    expect(handler.loadedHashes.last, song.hash);
    expect(handler.seekPositions, contains(const Duration(seconds: 50)),
        reason: '续播应定位回断点，而不是从头播');
    expect(controller.isPlaying, isTrue);
    expect(controller.errorMessage, isNull);

    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    await cleanUpToastAndSettle(tester);
  });

  testWidgets('链路真断（connectivity none）时不武装 watchdog，交还 connectivity 钩子', (
    tester,
  ) async {
    await makeController();
    await pumpToastHost(tester);
    NetworkMonitor.instance.debugSetResults(const [ConnectivityResult.none]);
    NetworkMonitor.probeOverride = (_) async => true;

    await playToMiddle(tester);

    fakeAudioPlayer.emitError(PlayerException(1, 'stream stall', 0));
    await tester.pump();
    expect(controller.errorMessage, isNotNull);

    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(handler.loadedHashes, hasLength(1), reason: '链路断开时不做探测重播');

    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    await cleanUpToastAndSettle(tester);
  });

  testWidgets('本地歌曲断流不武装（无网络依赖，重播无意义）', (tester) async {
    await makeController();
    await pumpToastHost(tester);
    NetworkMonitor.instance.debugSetResults(const [ConnectivityResult.wifi]);
    NetworkMonitor.probeOverride = (_) async => true;

    final song = Song(
      id: 'file:///storage/song.flac',
      title: '本地歌曲',
      artist: '歌手',
      hash: 'local_hash',
      source: SongSource.local,
      duration: const Duration(seconds: 200),
    );
    controller.queue = [song];
    await controller.playSong(song);
    await tester.pump();
    fakeAudioPlayer.setPosition(const Duration(seconds: 30));
    await tester.pump();
    expect(controller.isPlaying, isTrue);

    fakeAudioPlayer.emitError(PlayerException(1, 'decoder error', 0));
    await tester.pump();

    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(handler.loadedHashes, hasLength(1), reason: '本地歌曲不应触发网络恢复重播');

    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    await cleanUpToastAndSettle(tester);
  });
}
