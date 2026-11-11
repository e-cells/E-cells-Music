import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
// 桌面（Windows/Linux）播放器是 just_audio_media_kit 的平台实现，音效
// 滤镜链经 MediaKitPlayer.setAudioEffectFilters 透传给 mpv（Task 5）。
// 注意：顶层 just_audio_media_kit.dart 不导出 MediaKitPlayer，须引
// mediakit_player.dart；just_audio 0.10.x 也不公开 AudioPlayer.platform，
// 桌面实例经 MediaKitPlayer.activeInstances 在册登记表触达。
import 'package:just_audio_media_kit/mediakit_player.dart'
    show MediaKitPlayer;
import 'package:shared_preferences/shared_preferences.dart';

// 音效预设/档案的类与数据表拆到 models 层（issue #2）：import 供本库与
// part 分片引用类型，export 维持既有消费方「经 player_controller.dart
// 引用 AudioEffectPreset/AudioEffectProfile」的写法零改动。
import '../models/audio_effect_presets.dart';
import '../models/music_models.dart';
import '../services/audio_effects_service.dart';
import '../services/cache_service.dart';
import '../services/bluetooth_lyrics_service.dart';
import '../services/desktop_audio_filters.dart';
import '../services/desktop_lyrics_service.dart';
import '../services/android_lyric_service.dart';
import '../services/loudness_service.dart';
import '../services/music_api.dart';
import '../services/music_audio_handler.dart';
import '../services/network_monitor.dart';
import '../services/playback_history_service.dart';
import '../services/playback_stats_service.dart';
import '../services/super_lyric_service.dart';
import '../services/vip_background_task.dart';
import '../ui/form_factor.dart';
import '../ui/widgets/toast.dart';
import 'download_controller.dart';
import 'local_music_controller.dart';
import 'player_logic.dart';
import 'shuffle_queue.dart';

export '../models/audio_effect_presets.dart'
    show AudioEffectPreset, AudioEffectProfile;

part 'player_controller.playback.dart';
part 'player_controller.queue.dart';
part 'player_controller.lyrics.dart';
part 'player_controller.effects.dart';
part 'player_controller.desktop.dart';
part 'player_controller.voice_search.dart';
part 'player_controller.settings.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

/// 连续播放失败达到该次数后自动跳到下一首（见 [_PlayerPlayback._registerPlaybackFailure]）。
/// 库级常量：静态成员不能经实例访问，而该逻辑在 part 文件的 mixin 内。
const int _kAutoSkipFailureThreshold = 3;

/// 单轮失败 streak 内自动跳过的次数上限（与队列长度取小）：连续多首失败
/// 基本是网络/服务端问题，早点停下报错，避免长队列下的跳歌风暴。
const int _kMaxAutoSkipsPerStreak = 5;

/// 单轮失败 streak 自动跳过的墙钟预算：每次跳过仍要完整走一遍地址解析
/// （弱网下单首可达 15-20s），仅按次数限制时长队列最坏要 2-3 分钟才停。
/// 超预算即停止跳转、落错误态，与次数上限双保险。
const Duration _kAutoSkipWallClockBudget = Duration(seconds: 60);

/// 中途解码/断流错误距曲尾小于该时长时，按「已播完」处理并自动切下一首。
///
/// 部分 CDN/FLAC 在最后一两帧损坏（invalid sync code），用户已完整听完，
/// 不应再对当前歌弹「暂无可播放音源」。阈值取 1.5s：覆盖坏尾帧即可；
/// 更大（如 3s）会把尾部真实断网也静默吞掉。最后 1.5s 即使是真断网，
/// 重试也只能补这 1.5s，直接进下一首是更好的 UX，故不按错误类型分流。
const Duration _kNearEndDecodeErrorThreshold = Duration(milliseconds: 1500);

/// 曲末停滞 watchdog：兜底 timer 到点后引擎位置仍冻结时的复检间隔与次数。
/// 首次检查在兜底 timer 回调内同步执行，不另耗时间；连续
/// [_kTailStallMaxChecks] 次仍停滞即强制按播完推进（总静默 ≈ 曲末
/// 兜底 delay（remaining≤750ms＋180ms）＋ 3×1.5s ≈ 4.7~5.4s——
/// 比它更短的重缓冲不会被误判）。
const int _kTailStallMaxChecks = 3;
const Duration _kTailStallRecheckInterval = Duration(milliseconds: 1500);

/// 断网自动恢复 watchdog（见 [_PlayerPlayback._scheduleNetworkRecovery]）：
/// 车机过隧道时链路常不报告离线，connectivity 跃迁不可依赖，改为
/// 周期探测外网可达性，恢复后从断点自动续播。
const Duration _kNetworkRecoveryProbeInterval = Duration(seconds: 5);
/// 单轮恢复预算：超时停手（最长隧道也就几分钟，10 分钟覆盖极端通勤）。
const Duration _kNetworkRecoveryBudget = Duration(minutes: 10);
/// 探测成功后的最大重播尝试次数：确定性失败（坏源/无版权）探测必然
/// 成功，靠它防止"探测→重播→再失败"无限循环。
const int _kNetworkRecoveryMaxAttempts = 4;

/// 「起播请求」平台确认的结果（见 [_PlayerControllerBase._requestPlayback]）。
enum PlayConfirm {
  /// 平台在限时内回执确认。
  confirmed,

  /// 超时但引擎侧已在播（Android `play(Result)` 拖到曲末的已知行为），
  /// 等同成功：清失败计数、记历史。
  timeoutPlaying,

  /// 超时且引擎侧静默（会话被抢/未 ready 又不抛错的未来路径），
  /// 调用方不得按成功记账：不清失败计数、不记历史不做缓存。
  timeoutSilent,
}

// PlayerController 的私有设置键/常量（原类内 static const，拆分后提升为库级常量，
// 仅同库可见，引用方式不变）。
const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
const _audioQualitySettingKey = 'settings.audio_quality';
const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
const _equalizerPresetSettingKey = 'settings.equalizer_preset';
const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
// 环绕开关/强度与低音增强同范式落盘（见 _applySurround 与 _restoreSettings）。
const _surroundEnabledSettingKey = 'settings.surround_enabled';
const _surroundStrengthSettingKey = 'settings.surround_strength';
const _audioInterruptionEnabledSettingKey =
    'settings.audio_interruption_enabled';
const _autoResumeAfterInterruptionSettingKey =
    'settings.auto_resume_after_interruption';
const _playbackSpeedSettingKey = 'settings.playback_speed';
const _userVolumeSettingKey = 'settings.user_volume';
const _desktopLyricsEnabledSettingKey = 'settings.desktop_lyrics_enabled';
const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
// 桌面歌词设置版本号：v2 起默认透明悬浮（opacity 0.0/字号 24）。
// 老版本持久化的是旧默认值（0.8/16），不做迁移会盖掉代码新默认，
// 表现为“样式改了但重启无效”。版本对不上时丢弃旧值，用代码默认。
const _desktopLyricsSettingsVersionKey =
    'settings.desktop_lyrics_settings_version';
const _desktopLyricsSettingsVersion = 2;
// 对齐方式一次性迁移标记：新增 split（左右分离）取值时，历史版本里
// alignment 对双行**完全无效**（双行恒为左右分离），所以存量 'center'
// 不可能是用户为双行做的选择，而单行下 split 与 center 渲染一致 ——
// 把 center 改写成 split 是行为等价的重写，避免升级后双行观感从
// "对角交错"突变成"两行居中"。
const _desktopLyricsAlignmentMigratedKey =
    'settings.desktop_lyrics_alignment_migrated';
// Android 桌面歌词（易格方案）设置：独立于 PC 的 desktop_lyrics_settings。
// 版本号机制同上：版本不符丢弃旧 JSON 用代码默认，防止旧默认复活。
const _androidLyricSettingsKey = 'settings.android_lyric_settings';
const _androidLyricSettingsVersionKey = 'settings.android_lyric_settings_version';
const _androidLyricSettingsVersion = 1;
// 语音搜歌模式（易格同款）：all = 搜索结果全部入队播放 / first = 仅播首曲
// （插到当前曲目之后，不动原队列）。
const _voiceSearchModeSettingKey = 'settings.voice_search_mode';
const _smartQualitySettingKey = 'settings.smart_quality_enabled';
const _allowCellularPrecacheSettingKey = 'settings.allow_cellular_precache';
const _autoPlayOnStartupSettingKey = 'settings.auto_play_on_startup';
// 开机自启播放内容：'resume' = 继续播放上次队列（默认）/ 'daily' = 每日推荐。
const _startupPlaySourceSettingKey = 'settings.startup_play_source';
const _autoPlayOnDeviceConnectedSettingKey =
    'settings.auto_play_on_device_connected';
const _bluetoothLyricsEnabledSettingKey = 'settings.bluetooth_lyrics_enabled';
// 歌词进度偏移：按歌曲 hash 保存毫秒值（正 = 歌词提前），见 lyricOffset。
const _lyricOffsetsSettingKey = 'settings.lyric_offset_per_song';
const _keepScreenOnSettingKey = 'settings.keep_screen_on';
// 歌词页切歌键（issue #3）：默认关 = QQ 音乐原版底栏，用户可在 设置-播放 打开。
const _lyricPageSkipButtonsSettingKey = 'settings.lyric_page_skip_buttons';
const _playbackStateKey = 'playback_state';
const _playbackStateMaxQueueSize = 200;
const _listenTimeReportInterval = Duration(minutes: 30);
const _listenTimeCheckInterval = Duration(minutes: 1);
const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

/// 歌词进度调节步进（一次点按的调整量，主流播放器惯例 0.5 秒）。
const Duration kLyricOffsetStep = Duration(milliseconds: 500);

/// 歌词进度偏移上下限：±20 秒。再大就不只是"歌词有点偏差"，
/// 整段都会错位，钳住可避免用户长按连点后歌词飞出十万八千里。
const Duration kLyricOffsetLimit = Duration(seconds: 20);

/// 逐曲偏移的持久化条数上限：超出按插入序淘汰最旧（更新即置为最新）。
const int kLyricOffsetStoreLimit = 200;

/// 偏移落盘连调合并窗口（见 _PlayerLyrics._scheduleLyricOffsetPersist）。
const Duration _kLyricOffsetPersistWindow = Duration(milliseconds: 500);

/// 播放器控制器：状态拆分见 [_PlayerControllerBase]，职责分片见各 part 文件。
class PlayerController extends _PlayerControllerBase
    with
        _PlayerPlayback,
        _PlayerQueue,
        _PlayerLyrics,
        _PlayerEffects,
        _PlayerDesktop,
        _PlayerVoiceSearch,
        _PlayerSettings {
  /// EQ 预设表（16 项）与音效档案表（6 项）已拆到 models 层集中维护
  /// （曲线与调法注释见 audio_effect_presets.dart），此处保留原静态入口
  /// 签名，既有消费方零改动。
  static const equalizerPresets = kEqualizerPresets;
  static const audioEffectProfiles = kAudioEffectProfiles;

  PlayerController(super.api, super.audioHandler) {
    // whenComplete 兜底异常路径也放行等待方（恢复内部已自捕获，正常不抛）。
    unawaited(
      _restoreSettings().whenComplete(() {
        if (!_settingsRestored.isCompleted) _settingsRestored.complete();
      }),
    );
    unawaited(
      _restorePlaybackState().whenComplete(() {
        if (!_playbackStateRestored.isCompleted) {
          _playbackStateRestored.complete();
        }
      }),
    );
    // 车机切网（WiFi ↔ 蜂窝 ↔ 离线）后恢复网络时，若上一首因断网停在
    // 错误态，自动重播一次；isRetry 防止失败后再次触发形成循环。
    // 断点优先取 watchdog 保存的中断位置（隧道场景大多没有这条
    // connectivity 跃迁事件，靠 _scheduleNetworkRecovery 的周期探测兜底）。
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (isPreparing || errorMessage == null || _tailSkipExhausted) return;
        final song = currentSong;
        if (song == null) return;
        final resumeAt = _networkRecoverySongHash == song.hash
            ? _networkRecoveryPosition
            : null;
        _cancelNetworkRecovery();
        debugPrint('[易格][player] 网络已恢复，自动重播: ${song.title}');
        unawaited(
          playSong(
            song,
            isRetry: true,
            initialPosition:
                resumeAt != null && resumeAt > Duration.zero ? resumeAt : null,
          ),
        );
      },
    );
    _audioHandler.attachTransportControls(onNext: next, onPrevious: previous);
    // 语音点歌暖路径：MediaSession playFromSearch（系统助手/车机语音）经
    // audio_service 转发到 handler，再回到这里执行搜索播放。
    _audioHandler.attachVoiceSearch(onVoiceSearch: voiceSearchPlay);
    _setupDesktopLyricsListeners();
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (_pendingInitialPosition != null) {
        // 音频正在加载且指定了起播偏移量，忽略底层引擎加载音频源时的初始 0 秒回调，
        // 防止进度条与歌词闪回 0 秒
        return;
      }
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeStopClimaxPreview(value);
      _maybePrecacheNext(value);
      _maybeSyncDesktopLyricFromPosition();
      _syncSuperLyricFromPosition();
      _syncBluetoothLyricsFromPosition();
      // 进度只通知 positionListenable，避免整页 AnimatedBuilder(player) 每 tick 重建。
      _emitPosition();
    });
    // Send timing anchors; PC animates karaoke progress at display refresh.
    // Android（易格方案）整首歌词已交原生引擎自调度，无需逐帧推送。
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      // 控制器销毁后持久帧回调仍会被调度，直接跳过避免访问已释放状态。
      if (_disposed) return;
      if (isDesktopFormFactor &&
          _shouldShowDesktopLyrics &&
          isPlaying &&
          lyrics.isNotEmpty &&
          !_isScrubbing) {
        _syncDesktopKaraokeProgress();
      }
    });
    _durationSub = audioPlayer.durationStream.listen((value) {
      // 恢复占位保护：引擎无音频源时的 null 回调不清空歌曲元数据占位时长，
      // 真实音频加载后非 null 值会正常覆盖。
      if (value == null) return;
      duration = value;
      _emitPosition();
      notifyListeners();
    });
    _stateSub = audioPlayer.playerStateStream.listen((value) {
      // completed 视为未在播：PC 端适配层已在 EOF 把 playing 回写为 false，
      // 但移动端原生实现不会（just_audio 只在 play/pause/stop 里改它），
      // 若直接采信 playing，播完瞬间的迟到引擎错误会被
      // _handleMidPlaybackError 当成「播放中出错」，Toast 挂在刚播完的歌上。
      isPlaying =
          value.playing &&
          value.processingState != ProcessingState.completed;
      // 桌面滤镜链重放：系统停止（audio_service stop）/播放错误转 idle
      // 会让 just_audio 销毁并重建平台实例（setPlatform → 全新
      // MediaKitPlayer），新实例的 mpv af 从零开始，音效链静默丢失；Android
      // 有 sessionId 重挂钩子，桌面没有。趁每次真实起播（false→true 跃迁）
      // 幂等补写整链——_applyDesktopAudioFilters 内部按桌面门+在册实例自
      // 守卫，重复写同一条 af 无副作用。
      if (isPlaying && !_isPlayingForDesktopFilters) {
        unawaited(_applyDesktopAudioFilters());
      }
      _isPlayingForDesktopFilters = isPlaying;
      // 「重新出声作废完成去重」：系统播放键（通知栏/锁屏/耳机媒体键）曲末
      // 重播不经 togglePlay/_resetCompletionLatchForReplay（应用内入口会自
      // 己清），若不随这轮真实起播作废上一轮的完成标记，这首第二次播完的
      // completed 会被 [_willHandleCompletion] 去重吞掉，队列再次停在曲尾。
      // 完成标记只在「同一首歌的新一轮真出声」时命中：切歌后标记与新歌
      // hash 不等，天然不命中；完成流程在途由 _isHandlingCompletion 单独
      // 把关，不受影响。
      // 曲末耗尽态（[_tailSkipExhausted]）必须单独覆盖：预算耗尽路径
      // （曲末错误/watchdog 强推）在 _handleCompleted 之前就返回，
      // _completedSongHash 保持 null——上面的 hash 判定天然不命中，但残留
      // 的持久错误横幅与「抑制网络恢复自动重播」同样要随重新出声清掉。
      final invalidatesCompletionLatch =
          _completedSongHash != null &&
          _completedSongHash == currentSong?.hash;
      final clearsTailSkipExhaustion =
          _tailSkipExhausted && errorMessage != null && currentSong != null;
      if (value.playing &&
          value.processingState != ProcessingState.completed &&
          (invalidatesCompletionLatch || clearsTailSkipExhaustion)) {
        // 同应用内重播语义：新一轮真出声是全新尝试，连带清掉曲末跳过
        // 耗尽态与持久错误（否则残留横幅不消失、网络恢复自动重播被抑制），
        // 并取消上一轮的曲末兜底/watchdog timer（同曲同 hash 下旧 timer
        // 会在新一轮内开火）。
        _resetCompletionLatchForReplay();
        _nextLog('重新出声 → 作废上一轮完成去重/耗尽态: ${currentSong?.title}');
      }
      // 诊断：引擎上报的状态变化（实机排查"completed 到底有没有来"的第一手
      // 证据）。只在组合变化时记，避免每 tick 刷屏。
      final stateTrace = '${value.playing}/${value.processingState.name}';
      if (stateTrace != _lastStateTrace) {
        _lastStateTrace = stateTrace;
        _nextLog(
          '引擎状态 playing=${value.playing} '
          'processing=${value.processingState.name} → ctrlPlaying=$isPlaying',
        );
      }
      isBuffering =
          value.processingState == ProcessingState.loading ||
          value.processingState == ProcessingState.buffering;
      // 与 positionStream 同理：指定起播偏移量的加载过程中，引擎 position 归 0，
      // 此时不能用引擎位置重建平滑基线，否则歌词与进度条先闪回开头再跳回目标。
      if (!_isSeeking && _pendingInitialPosition == null) {
        _setPositionBase(audioPlayer.position, playing: isPlaying);
      }
      _syncListeningTimeTracker();
      _syncDesktopPlayState();
      _syncSuperLyricFromPosition();
      _syncBluetoothLyricsFromPosition();
      _emitPosition();
      notifyListeners();
    });
    _processingStateSub = audioPlayer.processingStateStream.distinct().listen((
      state,
    ) {
      if (state == ProcessingState.completed) {
        // 自然播完才重置曲末跳过预算，且必须是“会推进”的真完成：
        // - 承重的是 `!_isChangingSource`：兜底 timer 抢跑 → `_handleCompleted`
        //   → `playSong`（depth>0）后到达的迟到 completed 不推进任何东西，
        //   也不应白清预算（此时 `_completedSongHash` 已被 playSong 清空，
        //   `_willHandleCompletion` 为 true，拦不住）；
        // - `_willHandleCompletion` 覆盖 playSong 已返回后的同曲重复 completed。
        // 两个都留，但窄窗口下实际承重的是前者；误删前者会让系统性坏尾预算永不清零失效。
        final song = currentSong;
        final willHandle = song != null && _willHandleCompletion(song);
        if (song == null || _isChangingSource || !willHandle) {
          // 诊断：completed 到达却没推进 —— 必须能从日志直接看出是哪道守卫
          // 挡的（changingSource / 去重标记 / 完成流程仍在途）。
          _nextLog(
            'completed 到达但未推进 ← 守卫拦截: song=${song?.title ?? '-'} '
            'changingSource=$_isChangingSource(depth=$_changingSourceDepth) '
            'willHandleCompletion=$willHandle '
            'completedHash=$_completedSongHash '
            'handling=$_isHandlingCompletion handlingHash=$_handlingCompletedHash '
            '| ${_nextSnapshot()}',
          );
        } else {
          _nextLog('completed 到达 → 进入完成处理: song=${song.title} | ${_nextSnapshot()}');
        }
        if (song != null &&
            !_isChangingSource &&
            willHandle) {
          _consecutiveNearEndSkips = 0;
          _nearEndSkipStreakSince = null;
          _tailSkipExhausted = false;
          unawaited(_handleCompleted());
        }
      }
    });
    // 播放中的中途错误（断流/解码失败等）：此时 load 早已成功、playSong 已
    // 返回，错误不会经过其 catch——不接的话 isPlaying 恒为 true、进度继续
    // 外推，界面"假播放"到曲尾且无任何提示与自愈。加载期（isPreparing/
    // 换源深度>0）的错误仍由 playSong 的失败路径处理，这里只兜中途失败。
    _errorSub = audioPlayer.errorStream.listen(_handleMidPlaybackError);
    _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      _androidAudioSessionId = sessionId;
      unawaited(_refreshEqualizerConfig());
      unawaited(_applyEqualizer());
      unawaited(_applyBassBoost());
      unawaited(_applySurround());
      unawaited(_applyLoudnessGain());
    });
    unawaited(_setupAudioSessionListeners());
    unawaited(_loudness.init());
    unawaited(_superLyric.registerPublisher());
  }

  Duration? get climaxEndTime => _climaxEndTime;

  bool get isBluetoothLyricsSupported =>
      BluetoothLyricsService.isSupportedPlatform;

  bool get isScrubbing => _isScrubbing;

  @override
  void dispose() {
    _disposed = true;
    // 启动恢复的等待方（开机自启播放闭包）不能因控制器销毁而永久挂起。
    if (!_settingsRestored.isCompleted) _settingsRestored.complete();
    if (!_playbackStateRestored.isCompleted) _playbackStateRestored.complete();
    // 使在途的响度分析结果失效：cancelAnalysis 只能阻断后续进度，
    // 拦不住已在回调队列里的中途/最终值，不递增 serial 的话它们会在
    // dispose 完成后 notifyListeners 并对已释放的 AudioPlayer 应用增益。
    _loudnessSerial++;
    _pauseListeningTimeTracker();
    _flushPendingVolumePersist();
    _flushPendingLyricOffsetPersist();
    _networkRestoredSub?.cancel();
    _networkRecoveryTimer?.cancel();
    _autoResumeTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _stateSub.cancel();
    _processingStateSub.cancel();
    _errorSub.cancel();
    _androidAudioSessionSub.cancel();
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesSub?.cancel();
    _completionFallbackTimer?.cancel();
    _nearEndStallRecheck?.cancel();
    _saveStateTimer?.cancel();
    _desktopLyrics.setVisibilityChangedHandler(null);
    _desktopLyrics.setPlaybackActionHandler(null);
    _desktopLyrics.setLockChangedHandler(null);
    _desktopLyrics.setSettingsChangedHandler(null);
    _desktopLyrics.setOpenSettingsHandler(null);
    _androidLyric.setLockChangedHandler(null);
    _androidLyricHeartbeat?.cancel();
    _androidLyricHeartbeat = null;
    positionListenable.dispose();
    openLyricsSettingsRequest.dispose();
    openSongDetailRequest.dispose();
    unawaited(
      _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        levels: equalizerLevels,
      ),
    );
    unawaited(
      _audioEffects.configureBassBoost(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: bassBoostStrength,
      ),
    );
    // 环绕同理：dispose 必须显式释放，否则释放sessionId 后效果器仍挂着
    // 已销毁会话，下次创建会话时系统可能复用旧强度（与低音增强同范式）。
    unawaited(
      _audioEffects.configureVirtualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: surroundStrength,
      ),
    );
    // 桌面端清空 mpv 滤镜链（Android 走上面的通道 disable）。just_audio
    // 不公开平台实例，经在册登记表触达（见 mediakit_player.dart 补丁）。
    for (final player in MediaKitPlayer.activeInstances) {
      unawaited(player.setAudioEffectFilters(const []));
    }
    unawaited(_loudness.cancelAnalysis());
    unawaited(_loudness.releaseNative());
    unawaited(_superLyric.unregisterPublisher());
    _audioHandler.detachTransportControls();
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    unawaited(_androidLyric.hide());
    super.dispose();
  }
}

/// PlayerController 的可变状态基座：全部字段与状态派生的基础成员集中于此，
/// 供同库 part 文件中的职责 mixin（on 本类）与 PlayerController 自身直接访问
/// （同库私有，零可见性改动）。
/// 跨分片引用的方法在此声明为抽象契约，由各职责 mixin 提供实现。
abstract class _PlayerControllerBase extends ChangeNotifier {
  _PlayerControllerBase(this._api, this._audioHandler);

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  /// 本地音乐控制器（由 main.dart 在创建后注入，用于读取内嵌歌词等）。
  LocalMusicController? localMusic;

  /// VIP 领取任务（由 main.dart 在创建后注入，用于播放时按需领取 VIP）。
  VipBackgroundTask? vipClaim;

  final MusicApi _api;
  final MusicAudioHandler _audioHandler;
  final AudioEffectsService _audioEffects = AudioEffectsService();
  final DesktopLyricsService _desktopLyrics = DesktopLyricsService();
  // Android 桌面歌词（易格方案）通道客户端；PC 走上面的 Windows 桥接门面。
  final AndroidLyricService _androidLyric = AndroidLyricService();
  final PlaybackHistoryService _historyService = PlaybackHistoryService();
  final PlaybackStatsService _statsService = PlaybackStatsService();
  final LoudnessService _loudness = LoudnessService();
  final SuperLyricService _superLyric = SuperLyricService();
  final BluetoothLyricsService _bluetoothLyrics = BluetoothLyricsService();
  double? _pendingGainDb; // 当前歌曲分析得到的待应用增益(dB)
  // 切歌竞态守卫:每次发起分析递增,回调比对序号,不一致则丢弃旧结果。
  int _loudnessSerial = 0;
  // 当前歌曲实际播放 URL,供"开关开启时分析当前歌曲"复用,避免重新解析。
  String? _currentLoudnessUrl;
  // 渡口效应缓解:分析开始后前 3s(墙钟时间)的中途增益做 EMA 低通滤波。
  // 问题:渡口等歌前奏安静,初步 LUFS 偏低 → 增益被推到 +6dB 极限,
  // 随分析推进 LUFS 回升 → 增益砸回 +1.69dB,用户听到大幅跳变。
  // 方案:墙钟时间 3s 内的中途增益做 EMA(α=0.3),平滑掉前奏导致的剧烈跳变。
  // 用墙钟而非音频时长:解码 27x 快,3s 音频 ~110ms 就解码完,按音频时长滤波
  // 窗口在用户听到第一个进度时就已关闭。按墙钟则覆盖用户实际听到的前 3 秒。
  // 最终值(isFinal)不滤波,保证精度。
  // _emaGainDb 为 null 表示尚未初始化(首次中途值直接采用,不滤波)。
  double? _emaGainDb;
  // 分析开始的墙钟时间戳,用于判断是否在 EMA 滤波窗口内。
  DateTime? _emaStartWallTime;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _durationSub;
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<ProcessingState> _processingStateSub;
  late final StreamSubscription<PlayerException> _errorSub;
  late final StreamSubscription<int?> _androidAudioSessionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<void>? _networkRestoredSub;
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  Set<AudioDevice>? _previousDevices;
  final Stopwatch _positionClock = Stopwatch();
  // 平滑位置的上一次取值：用于过滤位置流的小幅倒退（音频缓冲/时钟抖动），
  // 避免歌词高亮和卡拉OK进度出现回跳。seek/换歌的大跨度回退会重建基线。
  Duration _lastSmoothPosition = Duration.zero;
  final _shuffleQueue = ShuffleQueue();

  /// 高潮试听结束时间（播放到该时间自动暂停）。
  Duration? _climaxEndTime;

  /// 当前歌曲的高潮片段时间（用于进度条标记），可能为 null。
  SongClimax? climax;
  Timer? _completionFallbackTimer;

  /// 兜底 timer 建立时刻的引擎位置：曲末停滞 watchdog（playback 分片的
  /// [_PlayerPlayback._checkTailStall]）以它为基准判定「位置是否原地冻结」。
  Duration? _fallbackTimerBuiltAtPosition;

  /// 曲末停滞已复检次数与复检 timer（见 _checkTailStall）。
  int _nearEndStallChecks = 0;
  Timer? _nearEndStallRecheck;
  Timer? _listenTimeTimer;
  DateTime? _listenTimeStartedAt;
  Duration _pendingListenTime = Duration.zero;
  bool _isReportingListenTime = false;
  int _seekSerial = 0;
  bool _isSeeking = false;
  bool _isScrubbing = false;
  bool _isHandlingCompletion = false;
  String? _completedSongHash;
  // 完成处理锁绑定的歌曲 hash：不同歌的完成互不吞（旧歌处理中，新歌
  // 又播完时放行新歌，旧流程靠 playSong 的 hash 自弃收敛）
  String? _handlingCompletedHash;
  String? _precachedForSongHash;
  bool _isPrecaching = false;
  // Android 桌面歌词（易格方案）：常显模式没有前后台切换隐藏，也就不需要
  // _isAppForeground / 预览开关那套状态（已随旧方案一并移除）。
  Duration? _pendingIdlePosition;
  Duration? _pendingInitialPosition;
  bool _disposed = false;

  // 断网自动恢复 watchdog 状态（见 playback 分片 _scheduleNetworkRecovery）：
  // 播放因网络类失败停住后周期探测外网，恢复即从断点续播。
  Timer? _networkRecoveryTimer;
  DateTime? _networkRecoverySince;
  String? _networkRecoverySongHash;
  Duration? _networkRecoveryPosition;
  int _networkRecoveryAttempts = 0;

  /// 进行中的歌词拉取（按歌曲 hash 去重），防止进页兜底与并发触发重复请求。
  String? _lyricsFetchInFlightHash;

  /// 当前歌曲的歌词进度偏移（正 = 歌词提前，负 = 歌词延后）。
  ///
  /// 调节入口：移动端播放页「详情」弹层的「歌词进度」（另支持长按歌词行），
  /// PC 端封面开关列 `调` 按钮 / 歌词列表右键 / 桌面歌词悬浮窗快捷菜单。
  /// 实际生效位置是 [lyricPosition] —— 歌词定位与卡拉OK逐字进度必须同源，
  /// 否则会"换行已提前、扫字仍延后"。
  Duration lyricOffset = Duration.zero;

  /// 逐曲偏移的持久化镜像（song.hash → 毫秒）。
  ///
  /// 只在内存里维护，落盘见 [_persistLyricOffsets]，启动恢复见 [_restoreSettings]。
  final Map<String, int> _lyricOffsets = <String, int>{};

  Song? currentSong;
  List<Song> queue = const [];
  List<LyricLine> lyrics = const [];
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 播放进度专用通知（高频）。UI 进度条应监听此对象，勿依赖 [notifyListeners]。
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 请求主界面打开桌面歌词设置页（悬浮窗工具栏点击设置触发）。
  final ValueNotifier<bool> openLyricsSettingsRequest = ValueNotifier<bool>(
    false,
  );

  /// 请求主界面打开歌曲详情页（全屏播放页内嵌底栏点歌名/评论触发，
  /// 内嵌处拿不到内容区 Navigator，走 shell 统一消费）。
  /// shell 消费后置回 null；commentsTab 为 true 时落「评论」tab。
  final ValueNotifier<({Song song, bool commentsTab})?>
  openSongDetailRequest = ValueNotifier(null);

  /// 外部界面可注册该回调或者监听 [openLyricsSettingsRequest]。
  VoidCallback? onOpenDesktopLyricsSettings;

  bool isPlaying = false;
  bool isBuffering = false;
  bool isPreparing = false;

  /// 上一事件周期的播放态副本，专供桌面滤镜链重放判跃迁（见 _stateSub
  /// 监听里的 false→true 钩子）：isPlaying 在监听入口已被本事件覆盖，
  /// 不能拿它当历史态。
  bool _isPlayingForDesktopFilters = false;

  /// 换源深度计数（并发 playSong 各自持有 +1/-1）。
  ///
  /// 曾经是共享 bool：快速连点切歌时，先启动的 playSong 在 await 中被
  /// 后启动者抢先，其 finally 会把后者仍需的"换源中"状态提前清除，
  /// completed 守卫失效。计数化后状态只在最后一个在途加载结束时归零。
  int _changingSourceDepth = 0;

  /// 连续播放失败次数（任一曲成功起播即归零）。
  int _consecutivePlayFailures = 0;

  /// 本轮失败 streak 内已自动跳过的曲数：上限为队列长度——整轮都失败就
  /// 停下报错，不做无限循环（坏源/断网时"跳一次失败一次"会瞬间扫光队列）。
  int _autoSkippedInStreak = 0;

  /// 连续「曲末停滞 watchdog 强制推进」次数（[_tryConsumeNearEndSkipBudget]）。
  ///
  /// 不随 playSong 成功清零（那会让系统性坏尾每首起播成功就重置预算、
  /// 无限静默跳歌），只在自然 completed、或「引擎已到真实 EOF 的曲末解码
  /// 错误」时重置——后者是正常播完，见 [_handleMidPlaybackError]。
  int _consecutiveNearEndSkips = 0;

  /// 曲末跳过这一路自己的墙钟起点，与 [_autoSkipStreakSince] 分开：[_autoSkipStreakSince]
  /// 会被 playSong 起播成功清空，而曲末跳过后必然跟一次成功的 playSong——共用
  /// 字段会让墙钟预算每次都被重置、永远判不出「超预算」。
  /// 本字段同样在起播成功时重新起算（playSong），只累计同一首歌内的重试风暴；
  /// 跨曲的坏尾爆发由 [_consecutiveNearEndSkips] 的次数上限兜住——两者若一起
  /// 只在自然 completed 清，就会在「曲末失败」这条路上永远清不掉而锁死预算。
  DateTime? _nearEndSkipStreakSince;

  /// 本轮 streak 第一次自动跳过的时刻：与 [_kAutoSkipWallClockBudget]
  /// 一起限制整轮跳过的墙钟时长（次数上限之外的另一道保险）。
  DateTime? _autoSkipStreakSince;
  bool addListeningTimeEnabled = true;

  /// 播放页是否保持屏幕常亮（仅 Android 生效，其余平台无原生实现）。
  ///
  /// 真实生效条件是 [keepScreenOnEnabled] **且** [isPlaying]：暂停/停播时
  /// 交回系统休眠。历史上是无条件常亮，导致暂停后停在播放页仍在烧屏。
  bool keepScreenOnEnabled = true;

  /// 歌词页底部是否显示上一首/下一首切歌键（issue #3）。
  ///
  /// 默认 false = QQ 音乐原版底栏观感；仅移动端歌词页消费（竖屏及非车机
  /// 横屏；桌面/车机分栏布局自带完整控制区），设置入口在 设置-播放
  /// （仅手机/平板形态展示，PC 与车机隐藏）。
  bool lyricPageSkipButtonsEnabled = false;
  AudioQuality audioQuality = AudioQuality.standard;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;

  /// 移动数据下是否允许后台缓存（下一首预缓存 + 播后缓存）。
  ///
  /// 默认 false = 仅 WiFi/有线/未知网络预缓存，蜂窝网络只预取歌词
  /// （歌词几 KB 不计），不下载音频（几十 MB），避免移动流量翻倍。
  bool allowCellularPrecache = false;

  /// 当前网络是否允许后台下载音频（预缓存 + 播后缓存）。
  ///
  /// 默认仅 WiFi/有线/未知网络允许；蜂窝网络需用户显式放行
  /// （[allowCellularPrecache]）。未知网络（单测/桌面无 NM 环境）
  /// 按放行处理，避免误杀。
  bool get isAudioPrecacheAllowed =>
      allowCellularPrecache || !NetworkMonitor.instance.isCellular;
  bool autoPlayOnStartupEnabled = false;
  bool hasRestoredPlaybackState = false;

  /// 开机自启播放内容：'resume' = 继续播放上次队列 / 'daily' = 每日推荐
  /// （无推荐数据时回退 'resume' 行为）。
  String startupPlaySource = 'resume';
  double playbackSpeed = 1.0;
  bool equalizerEnabled = false;
  List<int> equalizerLevels = List<int>.of(_defaultEqualizerLevels);
  String equalizerPresetName = '平直';
  EqualizerConfig equalizerConfig = EqualizerConfig.fallback(
    _defaultEqualizerLevels,
  );
  bool bassBoostEnabled = false;
  double bassBoostStrength = 0.45;
  bool surroundEnabled = false;
  double surroundStrength = 0.6;
  bool audioInterruptionEnabled = true;
  bool autoResumeAfterInterruption = false;
  bool autoPlayOnDeviceConnected = false;
  bool bluetoothLyricsEnabled = false;
  bool desktopLyricsEnabled = false;
  // PC（Windows/Linux）桌面歌词设置（现 PC 专用模型）。
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  // Android 桌面歌词（易格方案）设置与通道客户端。
  AndroidLyricSettings androidLyricSettings = const AndroidLyricSettings();

  /// 语音搜歌模式（易格同款）：'all' = 全部结果 / 'first' = 仅播首曲。
  String voiceSearchMode = 'all';

  /// 用户音量（0..1）：UI 滑杆/快捷键的唯一真相源。
  /// 引擎实际音量 = 用户音量 × 响度系数（见 _applyLoudnessGain），
  /// 两通道分开后互不覆盖，滑块不再自己跳。
  double userVolume = 1.0;

  /// 音量落盘防抖（见 _PlayerPlayback.setUserVolume）与最近落盘值。
  Timer? _volumePersistDebounce;
  double _persistedUserVolume = 1.0;

  /// 歌词偏移落盘防抖（见 _PlayerLyrics.setLyricOffset）：`− / +`
  /// 长按连调 130ms 一步，直接落盘的话 20 秒长按≈150 次磁盘写。
  /// 首调立即写（单击语义不变），窗口内后调合并为一次尾写。
  Timer? _lyricOffsetPersistDebounce;
  bool _lyricOffsetPersistDirty = false;

  // SuperLyric/蓝牙歌词同步状态
  int _lastSuperLyricIndex = -1;
  bool _lastSuperLyricPlaying = false;
  int _lastBluetoothLyricIndex = -1;
  bool _lastBluetoothPlaying = false;
  int _lastDesktopLyricIndex = -1;

  // Android 桌面歌词（易格方案）：整首歌词下发的去重键
  // （songHash|行数|前3行文本），换歌/歌词重载时清空；播放中每 30s 心跳
  // 校准一次原生时钟锚点（防两端时钟漂移）。
  String _lastAndroidLyricKey = '';
  Timer? _androidLyricHeartbeat;

  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  Timer? _saveStateTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;

  /// 曲末跳过预算耗尽标记：与 [errorMessage] 同设不同命。
  ///
  /// 耗尽态沿用 errorMessage 做移动端持久提示，但它不是“可重试的网络错误”——
  /// 网络恢复钩子（[_networkRestoredSub]）必须跳过它，否则任何一次切网都会把
  /// 停在曲尾的歌从头重播（playSong 不带定位 → 回 0）。只在新起播/自然播完清。
  bool _tailSkipExhausted = false;
  int? _androidAudioSessionId;

  /// 诊断日志去重：上一次已记录的「引擎 playing/processingState」组合。
  String? _lastStateTrace;

  /// 诊断日志去重：已记录过曲尾判定的歌曲 hash（每首歌只记一次）。
  String? _endOfSongLoggedForHash;

  bool get _isChangingSource => _changingSourceDepth > 0;

  /// 构造函数两路 unawaited 启动恢复（settings / 播放状态）的完成信号。
  ///
  /// 启动消费方（开机自启播放等）在触发播放前必须 await 它：冷启动磁盘
  /// 繁忙时 SharedPreferences 首次加载可能慢于首页首帧，若每日推荐先起播、
  /// [_restorePlaybackState] 晚到，恢复会用上次队列整队覆盖在播会话
  /// （queue/currentSong/洗牌状态），在途起播或曲末切歌被「已切歌」守卫
  /// 放弃 —— 表现为开机自启播完第一首就停在曲尾不再前进。
  final Completer<void> _settingsRestored = Completer<void>();
  final Completer<void> _playbackStateRestored = Completer<void>();

  /// 两路启动恢复是否均已收尾（含「无持久化状态」的空恢复）。
  Future<void> get startupRestored => Future.wait([
        _settingsRestored.future,
        _playbackStateRestored.future,
      ]);

  /// 曲末自动切歌诊断日志。实机排查「播完不跳下一首」时唯一需要过滤的通道：
  ///
  ///   adb logcat -s flutter | findstr shiyin
  ///
  /// 覆盖链路：引擎状态上报 → 接近曲尾/兜底 timer 是否建立 → completed 是否
  /// 到达、被哪道守卫拦截 → 完成处理选了哪个分支 → playSong 是否真的起播。
  /// 日志量按每首歌个位数行控制（状态变化才记、每首歌只记一次曲尾判定）。
  void _nextLog(String message) {
    debugPrint('[shiyin][next] $message');
  }

  /// 诊断快照：一次打印推进判定所需的关键字段。
  String _nextSnapshot() {
    return 'song=${currentSong?.title ?? '-'} '
        'enginePos=${audioPlayer.position.inMilliseconds}ms '
        'uiPos=${position.inMilliseconds}ms dur=${duration.inMilliseconds}ms '
        'ctrlPlaying=$isPlaying enginePlaying=${audioPlayer.playing} '
        'state=${audioPlayer.processingState.name} '
        'preparing=$isPreparing chgDepth=$_changingSourceDepth';
  }

  /// 「起播请求」等待平台确认的上限。
  ///
  /// Android 原生 just_audio 的 `play(Result)` 只在两种情况下回执：playWhenReady
  /// 本已为真，或曲目走到 STATE_ENDED（见 just_audio AudioPlayer.java:971-986，
  /// playResult 只在 STATE_ENDED/dispose 处 complete）。而本工程起播前刚
  /// pause 过（playSong 切新歌会先暂停旧歌），于是 `AudioPlayer.play()` 的
  /// Future 会一直挂到曲末——实机日志已经证实：`playSong 起播成功` 与
  /// `completed` 落在同一毫秒。
  ///
  /// 挂起本身不影响出声（Java 侧已 setPlayWhenReady(true)），但 await 它会把
  /// 调用方的收尾拖到曲末（playSong 的 finally → [_changingSourceDepth] 保持 1）：
  /// 1. completed 分支被 `!_isChangingSource` 整条挡掉，自动下一首只能靠曲末
  ///    兜底推进（3.0.3 兜底被 isPlaying 判活关掉 → 手机"播完不跳下一首"）；
  /// 2. [_handleMidPlaybackError] 同样被挡，播放中断流/解码失败被静默吞掉
  ///    （界面假播放、无提示、不自动跳过）；
  /// 3. 单曲循环重播、切音质重载的收尾同样被拖到曲末。
  ///
  /// 故统一给「平台确认」设上限：超时按"已起播"处理（引擎侧确实已在播，
  /// 当失败处理会误伤正常播放）。超时后额外复核一次引擎侧 `playing`：
  /// 若引擎静默（会话被抢/未 ready 又不抛错的未来路径），返回
  /// [PlayConfirm.timeoutSilent]，调用方不清失败计数、不记历史。
  static const Duration _kPlayConfirmTimeout = Duration(seconds: 2);

  /// 发起播放，只在有界时间内等待平台确认（理由见 [_kPlayConfirmTimeout]）。
  ///
  /// 返回值区分三种结局：平台确认成功、超时但引擎已在播（等同成功）、
  /// 超时且引擎静默（调用方不应按成功记账）。只读 `audioPlayer.playing`
  /// 做复核：just_audio 的 playing 含 buffering 为 true，慢网不会误判；
  /// 本方法调用前刚 `loadSong` 成功，processingState 不可能是 completed，
  /// 不用担心 EOF 陈旧 true。
  Future<PlayConfirm> _requestPlayback() async {
    try {
      await _audioHandler.play().timeout(_kPlayConfirmTimeout);
      return PlayConfirm.confirmed;
    } on TimeoutException {
      // 读引擎侧真相，不读 controller 的 isPlaying（后者是 UI 真相源，
      // 见 togglePlay 注释；这里要判断的是引擎有没有接受播放）。
      final enginePlaying = audioPlayer.playing;
      _nextLog(
        '起播确认 ${_kPlayConfirmTimeout.inSeconds}s 内未回执 → '
        'enginePlaying=$enginePlaying '
        '${enginePlaying ? '按已起播继续' : '引擎静默，不按成功记账'}'
        '（Android play(Result) 拖到曲末才回执，属已知平台行为，非错误）',
      );
      return enginePlaying
          ? PlayConfirm.timeoutPlaying
          : PlayConfirm.timeoutSilent;
    }
  }

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    return queue.indexWhere((item) => item.hash == song.hash);
  }

  int get activeLyricIndex =>
      PlayerLyricLogic.activeIndex(lyrics, lyricPosition);

  /// 歌词定位/卡拉OK专用位置：真实平滑进度叠加 [lyricOffset]。
  ///
  /// 偏移为正即"歌词提前"——真实进度 10.0s 处显示 10.5s 那一句（与 QQ 音乐
  /// PC 的「歌词提前 0.5 秒」语义一致）。夹取到 `[0, duration]`：负偏移不能
  /// 让开头几句永远点不亮，正偏移也不该把进度推到曲尾之后。
  Duration get lyricPosition {
    var value = smoothPosition + lyricOffset;
    if (value < Duration.zero) {
      value = Duration.zero;
    } else if (duration > Duration.zero && value > duration) {
      value = duration;
    }
    return value;
  }

  /// 当前歌曲是否带有非零歌词偏移（入口据此显示"已调整"）。
  bool get hasLyricOffset => lyricOffset != Duration.zero;

  /// 偏移的中文描述：`歌词提前 0.5 秒` / `歌词延后 1 秒` / `无偏移`。
  String get lyricOffsetLabel => PlayerLyricOffsetLogic.describe(lyricOffset);

  Duration? _estimatedLineDuration(int index) =>
      PlayerLyricLogic.estimatedLineDuration(lyrics, duration, index);

  Duration get smoothPosition {
    final raw = _isScrubbing
        ? position
        : (!isPlaying ? position : position + _positionClock.elapsed);
    var value = raw;
    if (value < Duration.zero) {
      value = Duration.zero;
    } else if (duration > Duration.zero && value > duration) {
      value = duration;
    }
    if (_isScrubbing) {
      // 拖动进度条时位置必须严格跟随手指。
      _lastSmoothPosition = value;
      return value;
    }
    if (value < _lastSmoothPosition) {
      if (_lastSmoothPosition - value > const Duration(milliseconds: 250)) {
        // 明显回退：视为 seek 或切歌，直接重建基线。
        _lastSmoothPosition = value;
      }
    } else {
      _lastSmoothPosition = value;
    }
    return _lastSmoothPosition;
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    position = _clampPosition(value);
    _positionClock
      ..stop()
      ..reset();
    if (playing) {
      _positionClock.start();
    }
  }

  void _emitPosition() {
    final next = smoothPosition;
    if (positionListenable.value != next) {
      positionListenable.value = next;
    }
  }

  Duration _clampPosition(Duration value) =>
      PlayerPositionLogic.clamp(value, duration);

  // ---- 跨职责分片的成员契约（由各 part 文件的职责 mixin 实现）----

  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  });

  Future<void> togglePlay();

  Future<void> seek(Duration position);

  Future<void> next();

  Future<void> previous();

  Song? _nextSong({bool peek = false}) {
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) return queue.first;
      final nextIndex = peek
          ? _shuffleQueue.peekNext(queue.length)
          : _shuffleQueue.next(queue.length);
      if (nextIndex >= 0 && nextIndex < queue.length) {
        return queue[nextIndex];
      }
      return queue.first;
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    return queue.first;
  }

  Future<void> loadLyrics(Song song);

  // 歌词进度偏移（lyrics 分片实现；playback/settings/desktop 分片都要访问）。
  Future<void> adjustLyricOffset(Duration delta);

  Future<void> setLyricOffset(Duration value);

  Future<void> resetLyricOffset();

  void _loadLyricOffsetForSong(Song? song);

  void _restoreLyricOffsets(SharedPreferences prefs);

  void _syncDesktopLyrics();

  void _syncDesktopKaraokeProgress();

  Future<void> _syncDesktopLyricsVisibility();

  void _scheduleSavePlaybackState();

  Future<PlayUrl> _resolvePlayUrl(Song song);

  Future<void> _loadClimax(Song song);

  /// VIP 过期领取后重试（playback 分片实现，settings 的切音质路径复用）。
  Future<bool> _tryClaimVipAndRetry(
    Song song, {
    List<Song>? queue,
    Duration? initialPosition,
    bool preserveClimax,
  });

  Future<void> _refreshEqualizerConfig();

  Future<void> _applyEqualizer();

  Future<void> _applyBassBoost();

  Future<void> _applySurround();

  Future<void> _analyzeAndApplyLoudness({
    required Song song,
    required String url,
  });

  Future<void> _applyLoudnessGain({bool instant = false});

  /// 切歌缓存未命中时中性化残留的旧响度增益（effects 分片实现）。
  void _resetStaleLoudnessGain();
}
