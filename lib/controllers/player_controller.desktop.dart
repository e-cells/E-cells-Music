// player_controller.desktop.dart —— PlayerController 的职责分片：桌面歌词与系统集成（悬浮窗歌词/卡拉OK进度/AudioSession 打断策略/设备接入自动播放）。成员声明与字段见 player_controller.dart。
//
// 桌面歌词双方案：
// - **PC（Windows/Linux）**：WindowsDesktopLyricsBridge 子窗方案，
//   逐句推送 + 逐字卡拉OK进度，行为与历史版本一致。
// - **Android**：易格音乐方案（android_lyric_service.dart）——整首歌词
//   一次下发原生引擎、开启即常显（无前后台隐藏）、30s 心跳校准。
part of 'player_controller.dart';

mixin _PlayerDesktop on _PlayerControllerBase {
  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // 打断开始：系统可能已自动暂停播放器。
          // 若开启了"阻止打断"，立即恢复播放以对抗暂停。
          if (!audioInterruptionEnabled && isPlaying && currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 300), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        } else {
          // 打断结束：若开启了"自动恢复"或"阻止打断"，恢复播放。
          if ((autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
              currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (!audioInterruptionEnabled) {
          // 阻止打断模式下忽略耳机拔出
          return;
        }
        if (autoResumeAfterInterruption && currentSong != null) {
          _autoResumeTimer?.cancel();
          _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
            if (!isPlaying && currentSong != null) {
              unawaited(_audioHandler.play());
            }
          });
        }
      });
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen((devices) {
        if (_previousDevices != null) {
          final addedDevices = devices.difference(_previousDevices!);
          if (addedDevices.isNotEmpty) {
            // ignore: experimental_member_use
            final hasNewAudioDevice = addedDevices.any(
              (d) =>
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothA2dp ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothLe ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.bluetoothSco ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadset ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.wiredHeadphones ||
                  // ignore: experimental_member_use
                  d.type == AudioDeviceType.carAudio,
            );

            if (hasNewAudioDevice &&
                autoPlayOnDeviceConnected &&
                currentSong != null &&
                !isPlaying) {
              _autoResumeTimer?.cancel();
              _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
                if (!isPlaying && currentSong != null) {
                  unawaited(_audioHandler.play());
                }
              });
            }
          }
        }
        _previousDevices = devices;
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 阻止打断时使用 [AndroidAudioFocusGainType.gain] 并禁用 androidWillPauseWhenDucked，
  /// 向系统声明不希望被其他 App 打断。同时配合 interruptionEventStream 中的
  /// 主动恢复播放作为双保险。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻断打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await checkDesktopLyricsPermission();
      if (!hasPermission) {
        debugPrint('[易格][桌面歌词] 开启失败：checkPermission=false');
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await requestDesktopLyricsPermission();
        return;
      }
      await _syncDesktopLyricsVisibility();
    } else {
      if (isDesktopFormFactor) {
        await _desktopLyrics.hide();
      } else {
        await _androidLyric.hide();
      }
    }
  }

  /// 通知卡片「桌面歌词」按钮的开关入口：与设置页开关同一状态源。区别在
  /// 无悬浮窗权限时的处理——不跳系统设置页（媒体卡片回调属于后台
  /// startActivity，会被后台启动限制拦截，用户也正盯着通知栏），改弹
  /// 原生 Toast 引导用户先在应用内开启一次；授权后此按钮即可长期使用。
  Future<void> toggleDesktopLyricsFromNotification() async {
    debugPrint('[SYNOTIF] 通知卡片词按钮触发：当前 desktopLyricsEnabled='
        '$desktopLyricsEnabled');
    if (desktopLyricsEnabled) {
      await setDesktopLyricsEnabled(false);
      return;
    }
    final granted = await checkDesktopLyricsPermission();
    debugPrint('[SYNOTIF] 悬浮窗权限检查结果: $granted');
    if (!granted) {
      if (isDesktopFormFactor) return;
      await _androidLyric.showToast('开启桌面歌词需要悬浮窗权限，请先在应用内开启一次桌面歌词');
      return;
    }
    await setDesktopLyricsEnabled(true);
  }

  /// 展示门控：
  /// - PC：开启且有歌即显示（桌面形态无前后台隐藏一说）。
  /// - Android（易格方案）：开启即常显——App 在前台也显示，直到用户关闭
  ///   开关。无歌时原生侧自然显示空行。
  bool get _shouldShowDesktopLyrics {
    if (!desktopLyricsEnabled) return false;
    if (isDesktopFormFactor) return currentSong != null;
    return true;
  }

  @override
  Future<void> _syncDesktopLyricsVisibility() async {
    // Android（易格方案）：显示由开关唯一决定，这里只负责"开启后把
    // 服务/窗口与全部状态补齐"。
    if (!isDesktopFormFactor) {
      if (!_shouldShowDesktopLyrics) {
        await _androidLyric.hide();
        return;
      }
      final shown = await _androidLyric.show();
      if (!shown) {
        debugPrint('[易格][桌面歌词] 悬浮窗启动失败（权限被撤或服务启动被拒）');
        return;
      }
      // 原生 onCreate 会从自己的 prefs 恢复设置，这里补推是首帧保险
      // （新安装尚无原生持久化/偏好被清时与 Dart 侧保持一致）。
      unawaited(_androidLyric.updateSettings(androidLyricSettings));
      _pushAndroidLyrics();
      _syncDesktopPlayState();
      return;
    }

    // ---- PC（Windows/Linux 子窗方案，行为与历史版本一致） ----
    if (!_shouldShowDesktopLyrics) {
      await _desktopLyrics.hide();
      return;
    }
    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (!shown) {
      debugPrint(
        '[易格][桌面歌词] 悬浮窗创建失败：检查 desktop_multi_window/window_manager 插件注册与窗口权限',
      );
    } else {
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  @override
  void _syncDesktopLyrics() {
    // Android（易格方案）：整首歌词交给原生引擎（带去重），不再逐句推送。
    if (!isDesktopFormFactor) {
      _pushAndroidLyrics();
      return;
    }

    // ---- PC：逐句推送（行为与历史版本一致） ----
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(
        current: '',
        next: '',
        activeOnBottom: false,
      );
      return;
    }
    final clamped = index.clamp(0, lyrics.length - 1);
    final current = lyrics[clamped].text;
    final nextIndex = clamped + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    // 双行交替（乒乓）高亮：偶数句落在上行、奇数句落在下行。子窗据此把
    // 逐字进度交给"正在唱的那一行"，另一行换成下一句 —— 正在唱的那句
    // 文字始终不移动（历史实现里它每句都要从下行跳到上行）。
    final activeOnBottom = clamped.isOdd;
    _desktopLyrics.updateLyrics(
      current: current,
      next: next,
      activeOnBottom: activeOnBottom,
    );
  }

  /// Android（易格方案）：整首歌词一次下发。
  ///
  /// 按 `songHash|行数|前3行文本` 去重——同一份歌词的重复同步（播放位置
  /// tick、显隐同步等都会经过这里）不重复推送；空歌词也下发（原生显示
  /// 空行，正确表达"这首歌没有歌词"）。
  void _pushAndroidLyrics() {
    if (!desktopLyricsEnabled) return;
    final key =
        '${currentSong?.hash}|${lyrics.length}|'
        '${lyrics.take(3).map((l) => l.text).join('|')}';
    if (key == _lastAndroidLyricKey) return;
    _lastAndroidLyricKey = key;
    unawaited(
      _androidLyric.loadLyrics(
        lines: [
          for (final l in lyrics)
            {
              'timeMs': l.time.inMilliseconds,
              'text': l.text,
              'translation': l.translation ?? '',
            },
        ],
        positionMs: lyricPosition.inMilliseconds,
        isPlaying: isPlaying,
      ),
    );
  }

  void _syncDesktopPlayState() {
    if (isDesktopFormFactor) {
      if (!_shouldShowDesktopLyrics) return;
      _desktopLyrics.updatePlayState(isPlaying: isPlaying);
      return;
    }
    // Android（易格方案）：重锚时间基准并启停原生调度；播放中额外挂
    // 30s 心跳校准（易格同款：防 Flutter 与原生两端时钟漂移）。
    if (!desktopLyricsEnabled) {
      _androidLyricHeartbeat?.cancel();
      _androidLyricHeartbeat = null;
      return;
    }
    _androidLyric.setPlaybackState(
      isPlaying: isPlaying,
      positionMs: lyricPosition.inMilliseconds,
    );
    if (isPlaying) {
      _androidLyricHeartbeat ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          if (!desktopLyricsEnabled || !isPlaying) return;
          _androidLyric.calibratePosition(
            positionMs: lyricPosition.inMilliseconds,
          );
        },
      );
    } else {
      _androidLyricHeartbeat?.cancel();
      _androidLyricHeartbeat = null;
    }
  }

  void _maybeSyncDesktopLyricFromPosition() {
    // Android（易格方案）：原生引擎自调度刷新，无需按位置同步。
    if (!isDesktopFormFactor) return;
    if (lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    if (_shouldShowDesktopLyrics) {
      _syncDesktopKaraokeProgress();
    }
  }

  @override
  void _syncDesktopKaraokeProgress() {
    // Android（易格方案）：无逐字卡拉OK填充（整行显示），无进度可推。
    if (!isDesktopFormFactor) return;
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    // 用带偏移的歌词位置：偏移只作用于歌词，不改变真实播放进度条。
    final position = lyricPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);
    // 有逐字时间时按字符占比分段映射（字间间隙停住不动），无逐字时间才
    // 退回整行线性推进。历史实现里 word 分支算的是与行级完全相同的线性
    // 进度（死分支），且行时长不可得时干脆不推送——高亮会停在半途。
    final progress = PlayerLyricProgressLogic.forLine(
      line: line,
      position: position,
      lineDuration: lineDuration,
    );
    _desktopLyrics.updateKaraokeProgress(
      progress: progress,
      lineDuration: lineDuration,
      isPlaying: isPlaying,
    );
  }

  /// PC 桌面歌词设置落盘与回推。
  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    await prefs.setInt(
      _desktopLyricsSettingsVersionKey,
      _desktopLyricsSettingsVersion,
    );
    debugPrint(
      '[易格][桌面歌词] 设置已保存 opacity=${settings.opacity} '
      'fontSize=${settings.fontSize}',
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  /// Android 桌面歌词（易格方案）设置落盘与回推：原生 applySettings
  /// 也会写一份自己的 prefs（服务重建时自恢复）。
  Future<void> updateAndroidLyricSettings(AndroidLyricSettings settings) async {
    androidLyricSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _androidLyricSettingsKey,
      jsonEncode(settings.toMap()),
    );
    await prefs.setInt(
      _androidLyricSettingsVersionKey,
      _androidLyricSettingsVersion,
    );
    debugPrint(
      '[易格][桌面歌词] Android 设置已保存 fontSize=${settings.fontSize} '
      'themeMode=${settings.themeMode}',
    );
    notifyListeners();
    await _androidLyric.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported =>
      isDesktopFormFactor || AndroidLyricService.isSupportedPlatform;

  /// PC 子窗用户点了关闭：开关翻转落盘（Android 无悬浮窗关闭按钮，
  /// 该回调只会来自 PC 桥接）。
  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed || !desktopLyricsEnabled) {
      return;
    }
    desktopLyricsEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
    notifyListeners();
    await _desktopLyrics.hide();
  }

  void _handleDesktopLyricsPlaybackAction(String action) {
    switch (action) {
      case 'previous':
        unawaited(previous());
      case 'togglePlay':
        unawaited(togglePlay());
      case 'next':
        unawaited(next());
      // 悬浮窗快捷菜单的歌词进度调整：主窗是偏移的唯一真相源，子窗只发指令，
      // 调整结果沿既有推送链路（换行文本 + 逐字进度）自动回流到悬浮窗。
      case 'lyricOffsetEarlier':
        unawaited(adjustLyricOffset(kLyricOffsetStep));
      case 'lyricOffsetLater':
        unawaited(adjustLyricOffset(-kLyricOffsetStep));
      case 'lyricOffsetReset':
        unawaited(resetLyricOffset());
      default:
        debugPrint('[易格][player] 未知桌面歌词播控指令: $action');
    }
  }

  bool get desktopLyricsLocked => isDesktopFormFactor
      ? desktopLyricsSettings.locked
      : androidLyricSettings.locked;

  /// PC 锁定（穿透语义）。
  Future<void> setDesktopLyricsLocked(bool locked) async {
    if (desktopLyricsSettings.locked == locked) return;
    await updateDesktopLyricsSettings(
      desktopLyricsSettings.copyWith(locked: locked),
    );
  }

  /// Android 锁定（易格语义：完全穿透 + 背景透明，悬浮窗上无按钮）。
  Future<void> setAndroidLyricLocked(bool locked) async {
    if (androidLyricSettings.locked == locked) return;
    await updateAndroidLyricSettings(
      androidLyricSettings.copyWith(locked: locked),
    );
  }

  Future<void> unlockDesktopLyrics() => isDesktopFormFactor
      ? setDesktopLyricsLocked(false)
      : setAndroidLyricLocked(false);

  /// 子窗工具栏请求切换锁定：统一走 updateDesktopLyricsSettings（落盘 +
  /// notifyListeners 通知设置页 + 回推子窗后子窗重建并重设穿透）。
  /// 锁定语义 = QQ 音乐式全穿透；解锁入口为托盘/设置页。
  void _handleDesktopLyricsLockChanged(bool locked) {
    if (desktopLyricsSettings.locked == locked) return;
    unawaited(setDesktopLyricsLocked(locked));
  }

  Future<bool> checkDesktopLyricsPermission() => isDesktopFormFactor
      ? _desktopLyrics.checkPermission()
      : _androidLyric.checkPermission();

  Future<void> requestDesktopLyricsPermission() async {
    // PC 悬浮窗无权限流程（DesktopLyricsService.requestPermission 本就是
    // no-op，直接短路）；Android 跳系统悬浮窗权限设置页。
    if (isDesktopFormFactor) return;
    await _androidLyric.requestPermission();
  }

  void _setupDesktopLyricsListeners() {
    // 以下回调均来自 PC（Windows/Linux）桥接；Android 通道是单向调用，
    // 不会触发它们。
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _desktopLyrics.setPlaybackActionHandler(_handleDesktopLyricsPlaybackAction);
    _desktopLyrics.setLockChangedHandler(_handleDesktopLyricsLockChanged);
    _desktopLyrics.setSettingsChangedHandler((settings) async {
      await updateDesktopLyricsSettings(settings);
    });
    _desktopLyrics.setOpenSettingsHandler(_handleDesktopLyricsOpenSettings);
    // Android 悬浮窗「锁定」按钮：原生已先应用锁定（穿透/透明/隐藏微调
    // 行），这里同步 Dart 状态与持久化，设置页开关随动；随后
    // updateSettings 回推原生时 applySettings 的变更守卫会跳过，不回环。
    _androidLyric.setLockChangedHandler(_handleAndroidLyricLockChanged);
  }

  /// Android 悬浮窗锁定按钮触发的锁定变更（原生 → Dart 单向通知）。
  void _handleAndroidLyricLockChanged(bool locked) {
    if (_disposed) return;
    if (androidLyricSettings.locked == locked) return;
    unawaited(setAndroidLyricLocked(locked));
  }

  void _handleDesktopLyricsOpenSettings() {
    openDesktopLyricsSettingsPage();
  }

  /// 请求打开桌面歌词设置页（悬浮窗工具栏调起或外部手动调起）。
  void openDesktopLyricsSettingsPage() {
    if (_disposed) return;
    openLyricsSettingsRequest.value = false;
    openLyricsSettingsRequest.value = true;
    onOpenDesktopLyricsSettings?.call();
  }
}
