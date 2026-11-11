// player_controller.playback.dart —— PlayerController 的职责分片：播放主流程（加载/播放/seek/完成回调/高潮试听/音量与倍速）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerPlayback on _PlayerControllerBase {
  /// 当前用户音量（0.0–1.0）。桌面播放栏音量滑杆使用。
  /// 注意：返回用户值而非引擎值——引擎值含响度系数，直接读它滑块会跳。
  double get volume => userVolume;

  /// 设置用户音量（0.0–1.0），越界值自动夹取。
  /// 经响度系数合成后 instant 应用（打断在途 ramp 跟手），不破坏响度比。
  /// 音量会被快捷键等非 UI 入口修改，通知监听者以同步播放栏滑块。
  /// 拖动滑杆/滚轮调节会高频调用：引擎音量即时应用保持跟手，SharedPreferences
  /// 落盘防抖合并（此前每 tick 一次磁盘写，且写完才应用音量，拖动发涩）。
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    userVolume = clamped;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = Timer(const Duration(milliseconds: 500), () {
      _volumePersistDebounce = null;
      unawaited(_persistUserVolume(clamped));
    });
    await _applyLoudnessGain(instant: true);
    notifyListeners();
  }

  Future<void> _persistUserVolume(double clamped) async {
    _persistedUserVolume = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_userVolumeSettingKey, clamped);
  }

  /// 尽快落盘未写入的用户音量（dispose 时防抖窗口内还有最后一次调节）。
  void _flushPendingVolumePersist() {
    final pending = _volumePersistDebounce?.isActive ?? false;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
    if (pending && userVolume != _persistedUserVolume) {
      unawaited(_persistUserVolume(userVolume));
    }
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    final isSameSong = currentSong?.hash == song.hash;
    if (!preserveClimax) {
      _climaxEndTime = null;
      climax = null;
    }
    _completionFallbackTimer?.cancel();
    _nearEndStallRecheck?.cancel();
    _fallbackTimerBuiltAtPosition = null;
    _nearEndStallChecks = 0;
    _completedSongHash = null;
    // 新一轮播放：曲尾诊断日志重新允许记录（同曲重播也要能看到）。
    _endOfSongLoggedForHash = null;
    _precachedForSongHash = null;
    _pendingIdlePosition = null;

    if (initialPosition != null && initialPosition > Duration.zero) {
      _pendingInitialPosition = initialPosition;
      _setPositionBase(initialPosition, playing: false);
      _lastSmoothPosition = initialPosition;
      _emitPosition();
    } else {
      _pendingInitialPosition = null;
      _setPositionBase(Duration.zero, playing: false);
      _lastSmoothPosition = Duration.zero;
      _emitPosition();
    }

    // 检查是否有本地音频缓存（已下载/播放缓存）或本地音频文件
    var local = downloadController?.localPathFor(song, audioQuality);
    // 离线/跨音质降级检索：若当前音质无缓存，查找是否有任意可用本地音质文件
    local ??= downloadController?.localPathForAnyQuality(
      song,
      preferredQuality: audioQuality,
    );
    final hasLocalAudio = local != null || song.source == SongSource.local;

    // 切新歌必须清空歌词并重置歌词行；同一首歌重播/从冷启动恢复播放时保留已有歌词防闪烁
    if (!isSameSong) {
      // 切换新歌立即暂停旧歌，避免新歌加载/解析期间旧音频继续播放导致音画脱节
      unawaited(_audioHandler.pause());
      duration = song.duration ?? Duration.zero;
      lyrics = const [];
      _lastDesktopLyricIndex = -1;
      // 换歌即清空桌面歌词：PC 子窗发空句；Android（易格方案）清掉去重键
      // 后 _syncDesktopLyrics 会把空歌词表下发原生——从此刻到新歌词加载
      // 完成之间，悬浮窗不再显示上一首的句子。
      _lastAndroidLyricKey = '';
      _syncDesktopLyrics();
    }

    // 切新歌或无本地缓存需走网络解析时标记 isPreparing；
    // 同一首歌且有本地缓存时毫秒级即播，无需展示加载态，实现无感体验。
    isPreparing = !isSameSong || !hasLocalAudio;
    _changingSourceDepth++;
    errorMessage = null;
    _tailSkipExhausted = false;
    currentSong = song;
    // 装载这首歌自己的歌词进度偏移（歌词列表/桌面歌词都按它定位）。
    _loadLyricOffsetForSong(song);
    final queueChanged = queue != null && !listEquals(this.queue, queue);
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
    } else if (this.queue.isEmpty) {
      this.queue = [song];
    }
    if (playbackMode == PlaybackMode.shuffle) {
      final songIndex = this.queue.indexWhere((item) => item.hash == song.hash);
      if (queueChanged || _shuffleQueue.length != this.queue.length) {
        _shuffleQueue.reset(
          this.queue.length,
          currentIndex: songIndex >= 0 ? songIndex : 0,
        );
      } else if (songIndex >= 0) {
        _shuffleQueue.syncCurrentIndex(this.queue.length, songIndex);
      }
    }
    notifyListeners();
    // 诊断：放在 currentSong/queue 落定之后，快照里的 song= 才是本次请求的歌。
    _nextLog(
      'playSong 请求: ${song.title} isSameSong=$isSameSong isRetry=$isRetry '
      'initialPosition=${initialPosition?.inMilliseconds}ms | ${_nextSnapshot()}',
    );
    // 预缓存封面图，避免打开播放页时出现纯色背景闪烁
    _precacheCover(song);
    unawaited(_syncDesktopLyricsVisibility());
    // 切歌:取消上一首可能在途的响度分析,避免旧分析空跑占 CPU。
    // 序号守卫也会丢弃旧结果,但取消能立即停掉原生解码线程。
    unawaited(_loudness.cancelAnalysis());
    // 异步预取高潮片段时间，用于进度条标记（失败静默）。
    unawaited(_loadClimax(song));

    try {
      String url;
      String? networkUrl;
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        // URL 解析可挂起数秒（弱网/智能音质降级重试链），期间用户可能
        // 已切到另一首（currentSong 已被后者覆盖）：旧歌不得再把引擎与
        // mediaItem 抢回去，歌词/高潮等已有 hash 序号守卫，唯独主播放
        // 路径此前没有。
        if (currentSong?.hash != song.hash) {
          debugPrint('[易格][player] 地址解析期间已切歌，丢弃旧结果: ${song.title}');
          _nextLog('playSong 放弃(解析期间已切歌): ${song.title}');
          return;
        }
        if (playUrl.url.isEmpty) {
          throw Exception(
            song.isCloudDrive
                ? '云盘歌曲暂时没有可播放地址'
                : song.source == SongSource.netease
                ? '网易云歌曲暂时没有可播放地址'
                : '这首歌暂时没有可播放地址',
          );
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      // 响度均衡:先查缓存,命中则首播前即应用正确增益(instant,无跳变);
      // 未命中则播放中分析,完成后渐变(ramp)应用。
      _currentLoudnessUrl = url;
      final pre = _loudness.gainFromCache(song.hash);
      if (pre.fromCache) {
        _pendingGainDb = pre.gainDb;
        unawaited(_applyLoudnessGain(instant: true));
      } else {
        // 未命中:新歌增益未知,上一首的增益先中性化(渐变回用户音量),
        // 杜绝新歌开头带着旧增益播放(分析完成后会再渐变到真实值)。
        _resetStaleLoudnessGain();
      }
      unawaited(_analyzeAndApplyLoudness(song: song, url: url));
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: this.queue,
        queueIndex: currentIndex,
      );
      // loadSong（setUrl 等待后端就绪）期间同样可能被更新的切歌抢先：
      // 旧歌的 seek/play/缓存后置动作全部作废，避免新歌被旧歌的
      // 播放指令打回。
      if (currentSong?.hash != song.hash) {
        debugPrint('[易格][player] 加载期间已切歌，中止旧歌后续动作: ${song.title}');
        _nextLog('playSong 放弃(加载期间已切歌): ${song.title}');
        return;
      }
      if (initialPosition != null && initialPosition > Duration.zero) {
        await seek(initialPosition);
      }
      _pendingInitialPosition = null;
      isPreparing = false;
      notifyListeners();
      unawaited(loadLyrics(song));
      // 起播请求不能无界 await：Android 端平台确认会拖到曲末，把本方法的
      // finally（→ _changingSourceDepth）钉在 1 一整首歌，completed 分支与
      // 中途错误处理都会被整条挡掉。理由详见 [_kPlayConfirmTimeout]。
      final confirm = await _requestPlayback();
      if (confirm == PlayConfirm.timeoutSilent) {
        // 超时且引擎静默：load 成功但引擎没接住（会话被抢/未 ready 又不抛错）。
        // 不清失败计数（否则自动跳过失效）、不记历史不做缓存；不抛异常，
        // 后续真实错误由中途错误处理/下一次失败计数接管。finally 照常收尾。
        _nextLog('playSong 起播未确认(引擎静默): ${song.title} | ${_nextSnapshot()}');
        return;
      }
      // 起播成功（含超时但引擎已在播）：连续失败 streak 整体归零（含已自动跳过的计数）。
      _consecutivePlayFailures = 0;
      _autoSkippedInStreak = 0;
      _autoSkipStreakSince = null;
      // 恢复 watchdog 同步收手并归零重播计数：这轮播放已经成功了，
      // 后续若再失败属于新一轮 streak，预算从零起算。
      _cancelNetworkRecovery();
      _networkRecoveryAttempts = 0;
      // 曲末跳过的墙钟预算同步重新起算。它此前只在「自然播完」时清零，而
      // 曲末失败那条路（本预算存在的理由）恰恰不会再走自然播完：一首几分钟
      // 的歌播完后，下一次曲末失败必然被 60s 预算判成「超预算」，于是曲末
      // 自动切歌在本次会话里永久失效（停在曲尾不再前进）。防「整目录坏尾」
      // 的正解是次数上限 min(队列长度, _kMaxAutoSkipsPerStreak)，墙钟只该
      // 约束同一首歌内的重试风暴，故这里重新起算而保留计数。
      _nearEndSkipStreakSince = null;
      _nextLog('playSong 起播成功: ${song.title} | ${_nextSnapshot()}');
      // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
      unawaited(_historyService.record(song));
      unawaited(_statsService.recordPlay(song));
      // 首播后后台缓存（仅当本次用的是网络 URL，且当前网络允许）。
      // 蜂窝网络默认跳过音频下载（只播不存），避免移动流量翻倍；
      // 用户在设置中放行后才缓存。
      if (networkUrl != null && isAudioPrecacheAllowed) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      } else if (networkUrl != null) {
        debugPrint('[易格][player] 蜂窝网络跳过播后缓存: ${song.title}');
      }
    } catch (error) {
      if (_disposed) return;
      // VIP 过期：自动领取后重试一次（转发定位/队列上下文，避免冷启动
      // 定位与高潮试听从 0 秒重播）。isRetry 内不再领取：重试后仍报 VIP
      // 说明领取无效/服务端持续拒绝，不设限会形成"领取→重试→再领取"无限循环。
      if (!isRetry && error is VipRequiredException && vipClaim != null) {
        final claimed = await _tryClaimVipAndRetry(
          song,
          queue: queue,
          initialPosition: initialPosition,
          preserveClimax: preserveClimax,
        );
        if (claimed) return;
      }
      // 网络类失败（非 VIP、非首次重试）：短暂等待后自动重试一次。
      // 车机弱网/网络切换瞬间首次请求常失败，重试后即可恢复；
      // 确定性错误（如"没有可播放地址"）重试成本低，统一兜底一次。
      //
      // 例外：已进入"连续失败自动跳过"状态（_autoSkippedInStreak > 0）时
      // 不再逐首重试——此时基本是网络/服务端级故障，每首再等 2 秒会把
      // 跳过扫描拖成数分钟的跳歌风暴，直接计入失败并继续跳。
      if (!isRetry &&
          error is! VipRequiredException &&
          _autoSkippedInStreak == 0) {
        // 等待期间用户可能已切歌：旧歌的自动重试不得抢回播放权。
        if (currentSong?.hash != song.hash) {
          debugPrint('[易格][player] 重试前歌曲已切换，放弃重试: ${song.title}');
          return;
        }
        errorMessage = '播放失败，正在重试...';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_disposed) return;
        if (currentSong?.hash != song.hash) {
          debugPrint('[易格][player] 重试等待期间歌曲已切换，放弃重试: ${song.title}');
          return;
        }
        debugPrint('[易格][player] 播放失败，自动重试: ${song.title} ($error)');
        await playSong(
          song,
          queue: queue,
          isRetry: true,
          initialPosition: initialPosition,
          preserveClimax: preserveClimax,
        );
        return;
      }
      // 确定性失败落错误态前同样确认仍是当前歌：切歌后的旧错误不得
      // 覆盖新歌的加载/播放状态。
      if (currentSong?.hash != song.hash) {
        debugPrint('[易格][player] 失败落错误态前歌曲已切换，跳过: ${song.title}');
        return;
      }
      unawaited(_audioHandler.pause());
      duration = song.duration ?? Duration.zero;
      _pendingInitialPosition = null;
      _setPositionBase(Duration.zero, playing: false);
      _lastSmoothPosition = Duration.zero;
      _emitPosition();
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
      _nextLog('playSong 落错误态: ${song.title} → $error');
      // 网络/坏源失败都可能走到这里：交给恢复 watchdog 周期探测，
      // 外网恢复即从断点（或 initialPosition 恢复语境）自动重播一次。
      _scheduleNetworkRecovery(song, initialPosition ?? Duration.zero);
      // 已走完 VIP 领取与自动重试仍失败：计一次最终失败，达阈值自动前进。
      _registerPlaybackFailure(song);
    } finally {
      var depth = _changingSourceDepth;
      if (depth > 0) {
        depth = --_changingSourceDepth;
      }
      if (!_disposed) {
        // 守卫归属：_pendingInitialPosition / isPreparing 属于"最新的在途
        // 加载流程"。本流程被更新流程抢先而中止时（hash 检查 return），
        // finally 不得清掉新流程刚设置的守卫——否则加载期间引擎的 0 秒
        // 位置事件会把进度/歌词闪回开头、加载态提前消失。仅在深度归零
        // （没有任何在途流程）时才允许清。
        if (depth == 0) {
          _pendingInitialPosition = null;
          if (isPreparing) {
            isPreparing = false;
            notifyListeners();
          }
        }
        _nextLog(
          'playSong 收尾: ${song.title} chgDepth=$_changingSourceDepth '
          'preparing=$isPreparing',
        );
        _scheduleSavePlaybackState();
      }
    }
  }

  /// 播放中的中途错误处理（接入点见构造器 `_errorSub`）。
  ///
  /// 断流/解码失败发生时 load 早已成功、[playSong] 已返回，错误不经其
  /// catch 分支；底层 `playing` 不变（mpv 只是停止出数据），没有这里的
  /// 话 isPlaying 恒为 true、smoothPosition 持续外推，界面"假播放"到
  /// 曲尾。与 playSong 失败路径做相同收尾（暂停引擎、复位位置展示），
  /// 并计入连续失败 streak 复用 3 次阈值自动跳过；同时写入 errorMessage
  /// ——网络恢复钩子（onConnectivityRestored）会据此自动重播一次。
  void _handleMidPlaybackError(PlayerException error) {
    if (_disposed) return;
    final song = currentSong;
    if (song == null) return;
    // 加载/换源期的错误由 playSong 的失败路径统一处理，避免双重计数。
    if (isPreparing || _isChangingSource) {
      _nextLog(
        '引擎错误忽略(加载/换源在途): $error | preparing=$isPreparing '
        'chgDepth=$_changingSourceDepth',
      );
      return;
    }
    // 用户已暂停时迟到的错误不处理（无"假播放"问题，保留现场等用户操作）。
    if (!isPlaying) {
      _nextLog('引擎错误忽略(已不在播): $error | ${_nextSnapshot()}');
      return;
    }
    // 曲目刚播完（completed）时的迟到错误不算「播放中出错」：此时应走
    // 自动下一首，而不是对已播完的歌弹"没有音源"。PC media_kit 在 EOF 后
    // 可能先吐错误日志再进入 completed，两个流到上层的顺序不保证。
    if (audioPlayer.processingState == ProcessingState.completed) {
      _nextLog('引擎错误忽略(已 completed，属迟到错误): $error | ${_nextSnapshot()}');
      return;
    }

    // 曲末解码失败：先采样进度再复位。remaining <= 阈值（含引擎时长
    // 略短于元数据导致的负 remaining）一律按播完处理，走自动下一首。
    final errorPosition = audioPlayer.position > position
        ? audioPlayer.position
        : position;
    final songDuration = duration > Duration.zero
        ? duration
        : (song.duration ?? Duration.zero);
    if (songDuration > Duration.zero &&
        songDuration - errorPosition <= _kNearEndDecodeErrorThreshold) {
      unawaited(_audioHandler.pause());
      isPlaying = false;
      notifyListeners();
      // 本次「完成」若会被 _handleCompleted 去重掉（同曲已完成过/正在处理），
      // 它不会推进任何东西：先判掉，别做无意义的推进尝试，也别让下面的
      // 预算清零被一次不会推进的事件消费掉。
      if (!_willHandleCompletion(song)) {
        _nextLog(
          '曲末错误按播完处理，但完成会被去重吞掉 → 不推进: ${song.title} '
          'completedHash=$_completedSongHash handling=$_isHandlingCompletion '
          'handlingHash=$_handlingCompletedHash',
        );
        return;
      }
      // 引擎已到真实 EOF：libmpv（Windows/Linux 的 media_kit 后端）与部分
      // CDN 会在最后一帧之后报 `(1) Error decoding audio.`，而用户其实已
      // 完整听完——这是正常播完，不是「坏尾」，因此**不扣**曲末跳过预算，
      // 反而要把计数清零。否则每首都会命中本分支、每首扣一次额度，5 首之后
      // 自动切歌在本次会话内永久失效（3.0.8 实机日志：1/5 → 5/5 → 停住，
      // 进度停在曲尾，手动续播也救不回，只能重启 App——因为计数器只在自然
      // completed 归零，而本路径永远不会走到那里）。
      // 不计入 _consecutivePlayFailures，避免误弹「暂无可播放音源」。
      // 真正的「坏尾」（CDN 尾部断供、引擎位置冻结、completed 永不到达）
      // 不经本分支，走 [_checkTailStall]，预算在那条路上继续承重。
      _consecutiveNearEndSkips = 0;
      _nearEndSkipStreakSince = null;
      debugPrint(
        '[易格][player] 曲末解码失败，按播完自动切歌: ${song.title} '
        '(${errorPosition.inMilliseconds}/${songDuration.inMilliseconds}ms, $error)',
      );
      _nextLog(
        '曲末错误 → 按播完自动切歌: ${song.title} '
        'errorPos=${errorPosition.inMilliseconds}ms '
        'songDur=${songDuration.inMilliseconds}ms err=$error',
      );
      unawaited(_handleCompleted());
      return;
    }

    debugPrint('[易格][player] 播放中出错: ${song.title} ($error)');
    _nextLog(
      '引擎错误 → 非曲末，落"播放中断"失败路径: ${song.title} '
      'errorPos=${errorPosition.inMilliseconds}ms '
      'songDur=${songDuration.inMilliseconds}ms err=$error',
    );
    unawaited(_audioHandler.pause());
    // 同步收敛播放态：pause 是引擎异步确认，不先置 false 的话 UI 会
    // 在错误提示出现后仍短暂显示「播放中」。
    isPlaying = false;
    duration = song.duration ?? duration;
    // 复位展示进度前先保存中断位置：恢复 watchdog 出隧道后从这里续播，
    // 而不是把整首歌从头再来。
    _networkRecoveryPosition = errorPosition;
    _setPositionBase(Duration.zero, playing: false);
    _lastSmoothPosition = Duration.zero;
    _emitPosition();
    errorMessage = '播放中断，请稍后重试';
    notifyListeners();
    _scheduleNetworkRecovery(song, errorPosition);
    _registerPlaybackFailure(song);
  }

  /// 断网自动恢复 watchdog（车机过隧道场景）。
  ///
  /// 症状：进隧道断流 → 引擎错误 → 暂停落错误态；出隧道后音乐不会自动
  /// 恢复。原因：热点/蜂窝链路在隧道里往往并未断开（connectivity 全程
  /// mobile/wifi），[NetworkMonitor.onConnectivityRestored] 的"断→通"
  /// 跃迁不发生；即便发生，也只是从 0 秒重播。这里改为：失败停住后
  /// 每 [_kNetworkRecoveryProbeInterval] 探测一次外网可达性
  /// （[NetworkMonitor.probeInternet]，不依赖 connectivity 事件），
  /// 可达即从断点续播（isRetry，失败会重新武装，次数由
  /// [_kNetworkRecoveryMaxAttempts] 与墙钟预算双保险限流）。
  ///
  /// 自动停手条件（tick 内判定）：用户已接管播放/切歌/错误被清、
  /// 曲末预算耗尽态（与 connectivity 钩子同等排除）、预算/次数用尽。
  void _scheduleNetworkRecovery(Song song, Duration position) {
    if (_disposed || song.source == SongSource.local) return;
    // 分工：链路真断（connectivity 报 none）时，恢复由
    // onConnectivityRestored 钩子的"断→通"跃迁负责；watchdog 只兜
    // "链路在、数据不通"的隧道形态——那时的探测才有信息量，也避免
    // 确定性坏源在正常网络下被探测成功牵着多播几轮。
    if (!NetworkMonitor.instance.hasNetwork) return;
    _networkRecoverySongHash = song.hash;
    _networkRecoveryPosition = position;
    _networkRecoverySince ??= DateTime.now();
    _networkRecoveryTimer?.cancel();
    _networkRecoveryTimer = Timer.periodic(
      _kNetworkRecoveryProbeInterval,
      (_) => unawaited(_probeNetworkRecovery()),
    );
    _nextLog(
      '断网恢复 watchdog 武装: ${song.title} '
      'pos=${position.inMilliseconds}ms attempts=$_networkRecoveryAttempts',
    );
  }

  Future<void> _probeNetworkRecovery() async {
    if (_disposed) {
      _cancelNetworkRecovery();
      return;
    }
    // 用户已接管（手动播放/新加载在途/切歌/错误被清）或曲末耗尽态：
    // 与 connectivity 钩子的排除条件保持一致，立即收手。
    if (isPlaying ||
        isPreparing ||
        _isChangingSource ||
        _tailSkipExhausted ||
        errorMessage == null) {
      _cancelNetworkRecovery();
      return;
    }
    final song = currentSong;
    if (song == null || song.hash != _networkRecoverySongHash) {
      _cancelNetworkRecovery();
      return;
    }
    final since = _networkRecoverySince;
    final overBudget = since != null &&
        DateTime.now().difference(since) >= _kNetworkRecoveryBudget;
    if (overBudget || _networkRecoveryAttempts >= _kNetworkRecoveryMaxAttempts) {
      _nextLog(
        '断网恢复 watchdog 收手: 预算/次数用尽 '
        'attempts=$_networkRecoveryAttempts overBudget=$overBudget',
      );
      _cancelNetworkRecovery();
      return;
    }

    final reachable = await NetworkMonitor.instance.probeInternet();
    if (_disposed || !reachable) return; // 仍在隧道：下个周期再探
    // 探测成功后重检状态：探测期间用户可能已操作。
    if (isPlaying ||
        isPreparing ||
        _isChangingSource ||
        errorMessage == null ||
        currentSong?.hash != _networkRecoverySongHash) {
      _cancelNetworkRecovery();
      return;
    }
    final resumeAt = _networkRecoveryPosition;
    _networkRecoveryAttempts++;
    _cancelNetworkRecovery();
    debugPrint(
      '[易格][player] 外网探测恢复，从断点自动续播: ${song.title} '
      '@${resumeAt?.inMilliseconds ?? 0}ms '
      '(attempt $_networkRecoveryAttempts/$_kNetworkRecoveryMaxAttempts)',
    );
    _nextLog(
      '断网恢复 watchdog → 续播: ${song.title} '
      'pos=${resumeAt?.inMilliseconds ?? 0}ms attempt=$_networkRecoveryAttempts',
    );
    unawaited(
      playSong(
        song,
        isRetry: true,
        initialPosition:
            resumeAt != null && resumeAt > Duration.zero ? resumeAt : null,
      ),
    );
  }

  /// 停掉恢复 watchdog（保留 song/position 快照与计数，供钩子取断点）。
  void _cancelNetworkRecovery() {
    _networkRecoveryTimer?.cancel();
    _networkRecoveryTimer = null;
    _networkRecoverySince = null;
  }

  /// 曲末自动切歌预算：用独立计数 [_consecutiveNearEndSkips]，避免
  /// 系统性坏尾（CDN 尾部断供/整目录坏帧）在长队列里无限静默跳歌。
  ///
  /// 唯一调用点是曲末停滞 watchdog（[_checkTailStall]）——那才是真的没播完
  /// （位置冻结、completed 永不到达）。曲末解码错误那条路是引擎已到真实 EOF
  /// 的正常播完，不扣额度并清零本计数（见 [_handleMidPlaybackError]）；
  /// 把它也算进预算，就是 3.0.8 实机「播到曲末不再跳转」的成因。
  ///
  /// 不计入 [_consecutivePlayFailures]（避免误弹「没有音源」）；
  /// 也不随 playSong 成功清零——那会让每首起播成功就重置预算。
  /// 计数在自然 completed（player_controller.dart 的 processingState 监听）
  /// 与真实 EOF 的曲末解码错误处清零；墙钟起点则在每次起播成功时重新起算
  /// （见 playSong：停滞这条路不会走自然播完，若只在 completed 清，
  /// 预算必然跨曲累积、一首歌之后就永久判超预算）。返回 false 表示应停住并提示。
  bool _tryConsumeNearEndSkipBudget(Song song) {
    if (_disposed) return false;
    // 单曲队列也会走到 completed 的 seek(0)：单曲循环下会无限重播坏尾，
    // 因此同样用跳过预算限流（limit 至少 1，允许一次自动重播）。
    final queueLength = queue.length;
    final skipLimit = queueLength < _kMaxAutoSkipsPerStreak
        ? queueLength
        : _kMaxAutoSkipsPerStreak;
    final effectiveLimit = skipLimit < 1 ? 1 : skipLimit;
    // 墙钟起点用本路自己的字段：_autoSkipStreakSince 会被 playSong 起播成功
    // 清空，而曲末跳过后必然跟一次成功的 playSong，共用字段会让这里永远是
    // 「刚起算」，墙钟预算形同虚设。本字段同样在每次起播成功时重新起算
    // （否则几百秒后的一次曲末失败必然「超预算」，曲末切歌永久失效）。
    final since = _nearEndSkipStreakSince ??= DateTime.now();
    final overBudget =
        DateTime.now().difference(since) >= _kAutoSkipWallClockBudget;
    if (_consecutiveNearEndSkips >= effectiveLimit || overBudget) {
      debugPrint(
        '[易格][player] 曲末跳过已达上限 '
        '($_consecutiveNearEndSkips/$effectiveLimit'
        '${overBudget ? '，已超墙钟预算' : ''})，停止自动切歌: ${song.title}',
      );
      _nextLog(
        '曲末跳过预算耗尽 → 停住不切歌: ${song.title} '
        'skips=$_consecutiveNearEndSkips/$effectiveLimit overBudget=$overBudget '
        'since=$_nearEndSkipStreakSince',
      );
      Toast.error('连续多次在曲末播放失败，已停止自动切歌');
      return false;
    }
    _consecutiveNearEndSkips++;
    _nextLog(
      '曲末跳过计入预算 ($_consecutiveNearEndSkips/$effectiveLimit): ${song.title}',
    );
    debugPrint(
      '[易格][player] 曲末失败计入跳过预算 '
      '($_consecutiveNearEndSkips/$effectiveLimit): ${song.title}',
    );
    return true;
  }

  /// 记录一次最终播放失败（已走完 VIP 领取与自动重试）。
  ///
  /// 连续失败达 [_kAutoSkipFailureThreshold] 次后自动跳到下一首：坏源
  /// （无版权/地址失效）与断网场景下，播放器此前会永久卡在同一首的错误态，
  /// 用户只能手动一首首点。跳过策略：
  /// - 单曲队列不跳（无处可去，保持错误态提示）；
  /// - 本轮 streak 内跳过次数上限 = min(队列长度, [_kMaxAutoSkipsPerStreak])：
  ///   连续多首失败说明是网络/服务端问题而非单曲问题，早点停下报错——
  ///   每首都要走一遍自动重试（2s 等待），长队列会变成数分钟的跳歌风暴；
  /// - 墙钟预算 [_kAutoSkipWallClockBudget]：弱网下每首跳过仍要 15-20s
  ///   的地址解析，只按次数限制最坏要 2-3 分钟才停，超时即停；
  /// - 任一首成功起播即整体归零（见 playSong 起播后的清零）。
  void _registerPlaybackFailure(Song song) {
    if (_disposed) return;
    _consecutivePlayFailures++;
    if (_consecutivePlayFailures < _kAutoSkipFailureThreshold) {
      Toast.error('《${song.title}》暂无可播放音源');
      return;
    }

    final queueLength = queue.length;
    if (queueLength <= 1) {
      Toast.error('《${song.title}》暂无可播放音源');
      return;
    }
    final skipLimit = queueLength < _kMaxAutoSkipsPerStreak
        ? queueLength
        : _kMaxAutoSkipsPerStreak;
    final since = _autoSkipStreakSince ??= DateTime.now();
    final overBudget =
        DateTime.now().difference(since) >= _kAutoSkipWallClockBudget;
    if (_autoSkippedInStreak >= skipLimit || overBudget) {
      debugPrint(
        '[易格][player] 连续失败 $_consecutivePlayFailures 次，本轮已自动跳过 '
        '$_autoSkippedInStreak 首（上限 $skipLimit'
        '${overBudget ? '，已超墙钟预算 $_kAutoSkipWallClockBudget' : ''}），停止跳转',
      );
      Toast.error('连续多首歌曲播放失败，已停止播放');
      return;
    }
    _autoSkippedInStreak++;
    debugPrint(
      '[易格][player] 连续失败 $_consecutivePlayFailures 次，自动跳过: ${song.title}',
    );
    Toast.show('《${song.title}》播放失败，已跳过');
    // 脱离当前调用栈：本流程的 finally 尚未执行，直接 await next() 会形成
    // 逐曲嵌套的 await 链；延后一拍让本次收尾先完成（finally 的深度计数
    // 随后归零，不会误清新流程的守卫）。
    Future<void>.delayed(Duration.zero, () {
      if (_disposed) return;
      unawaited(next());
    });
  }

  /// 预缓存歌曲封面到 Flutter ImageCache，打开播放页时可立即显示。
  void _precacheCover(Song song) {
    final coverUrl = song.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    if (coverUrl.startsWith('content://')) return;
    final provider = ResizeImage(
      NetworkImage(coverUrl),
      width: 150,
      height: 150,
    );
    // listener 必须在拿到图/出错后自摘（与 precacheImage 内部同款）：
    // 常驻监听会让 ImageStreamCompleter 永远判定为 live，解码后的封面
    // 脱离 ImageCache 的 LRU 淘汰，长会话播放数百首后内存持续累积。
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) => stream.removeListener(listener),
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  /// 解析播放地址。
  ///
  /// - 云盘歌曲走 [MusicApi.cloudSongUrl]
  /// - 网易云歌曲使用外链地址
  /// - 其它歌曲走 [MusicApi.songUrl]，开启智能音质时在网络请求失败
  ///   或返回空地址时自动降级重试（lossless -> high -> standard）。
  @override
  Future<PlayUrl> _resolvePlayUrl(Song song) async {
    if (song.source == SongSource.local) {
      return PlayUrl(url: song.id, hash: song.hash);
    }
    if (song.isCloudDrive) {
      return _api.cloudSongUrl(song);
    }
    if (song.source == SongSource.netease) {
      // 网易云歌曲使用外链播放地址
      return PlayUrl(
        url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
        hash: song.hash,
      );
    }

    try {
      final playUrl = await _api.songUrl(song, quality: audioQuality);
      if (playUrl.url.isNotEmpty || !smartQualityEnabled) {
        return playUrl;
      }
      // 返回空地址：按智能音质策略降级重试
      final fallback = PlayerQualityLogic.nextLowerQuality(audioQuality);
      if (fallback == null) return playUrl;
      return _api.songUrl(song, quality: fallback);
    } catch (error) {
      if (!smartQualityEnabled) rethrow;
      // 网络请求失败：尝试降级重试
      final fallback = PlayerQualityLogic.nextLowerQuality(audioQuality);
      if (fallback == null) rethrow;
      try {
        final retryUrl = await _api.songUrl(song, quality: fallback);
        if (retryUrl.url.isNotEmpty) {
          debugPrint(
            '[易格][smart-quality] ${audioQuality.badge} 失败，'
            '已降级为 ${fallback.badge}',
          );
          return retryUrl;
        }
      } catch (_) {
        // 降级也失败，抛出原始错误
      }
      rethrow;
    }
  }

  /// VIP 过期时自动领取并重试播放，成功返回 true。
  /// 转发调用方的队列/定位/高潮上下文，避免重试丢定位。
  @override
  Future<bool> _tryClaimVipAndRetry(
    Song song, {
    List<Song>? queue,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    try {
      final result = await vipClaim!.claimNow(null);
      if (result.status == VipClaimStatus.success ||
          result.status == VipClaimStatus.alreadyClaimed) {
        debugPrint('[易格][player] VIP 已领取，重试播放: ${song.title}');
        final playUrl = await _api.songUrl(song, quality: audioQuality);
        if (playUrl.url.isNotEmpty) {
          errorMessage = null;
          // 重新走完整播放流程（保留定位与高潮武装）；
          // isRetry 防止服务端反复在"下发 URL"与 VIP 异常之间抖动时形成无限领取/重试递归。
          unawaited(
            playSong(
              song,
              queue: queue,
              initialPosition: initialPosition,
              preserveClimax: preserveClimax,
              isRetry: true,
            ),
          );
          return true;
        }
      }
    } catch (e) {
      debugPrint('[易格][player] VIP 领取/重试失败: $e');
    }
    return false;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 3.0);
    if ((playbackSpeed - clamped).abs() < 0.001) {
      return;
    }
    playbackSpeed = clamped;
    await audioPlayer.setSpeed(clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_playbackSpeedSettingKey, clamped);
    notifyListeners();
  }

  @override
  Future<void> togglePlay() async {
    // 以 controller 的 isPlaying 为 UI 真相源：completed 后它已收敛为
    // false（见 playerStateStream 监听），而 just_audio.playing 在这种状态下
    // 可能仍是 true（PC 端适配层已在 EOF 回写真话，移动端原生实现仍会陈旧）。
    // 若继续读 audioPlayer.playing，曲终点「播放」会走进 pause 分支
    // （图标与行为相反）。
    if (isPlaying) {
      await _audioHandler.pause();
      return;
    }
    // 冷启动恢复播放状态后，音频引擎只恢复了队列/当前歌曲状态，
    // 尚未加载任何音频源（idle）。此时直接 play() 只是空转
    // （UI 显示播放中但不出声），必须走完整播放流程加载当前歌曲。
    if (audioPlayer.processingState == ProcessingState.idle) {
      final song = currentSong;
      if (song != null) {
        final initPos =
            _pendingIdlePosition ?? (position > Duration.zero ? position : null);
        _pendingIdlePosition = null;
        await playSong(song, queue: queue, initialPosition: initPos);
        return;
      }
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      // just_audio.play() 首行 `if (playing) return`，而 completed 不会把
      // just_audio.playing 置回 false。必须先 pause 再 seek+play，否则
      // 进度回零了却永远不出声。
      // 这一轮是同一首歌的全新一遍：先清完成去重/曲末耗尽残留，否则本遍
      // 播完时 completed 会被上一轮的标记去重吞掉，队列不再前进。
      _resetCompletionLatchForReplay();
      await _audioHandler.pause();
      await _audioHandler.seek(Duration.zero);
      await _requestPlayback();
      return;
    }
    await _requestPlayback();
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    _setPositionBase(position, playing: false);
    _emitPosition();
  }

  @override
  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    _lastSmoothPosition = Duration.zero;
    // 用户手动 seek 后取消高潮武装，避免拖动进度条到高潮结束点后意外自动暂停。
    _climaxEndTime = null;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    _emitPosition();

    // 当底层音频引擎处于 idle 状态（如冷启动恢复歌曲但尚未起播）时，
    // 底层尚未加载音频源。此时暂存目标位置，等后续起播时作为 initialPosition 传入，杜绝弹回 0 秒。
    if (audioPlayer.processingState == ProcessingState.idle) {
      _pendingIdlePosition = target;
    }

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      _emitPosition();
      // Android（易格方案）：原生引擎重锚到新位置并立即刷新当前句。
      // 用 lyricPosition（已含单曲歌词偏移并夹取）与 loadLyrics 锚点同源。
      if (!isDesktopFormFactor && desktopLyricsEnabled) {
        unawaited(
          _androidLyric.seekTo(positionMs: lyricPosition.inMilliseconds),
        );
      }
    } catch (_) {
      // 仅 idle 吞错：无音频源时靠 _pendingIdlePosition 兜底。
      // 非 idle 下的引擎错误（蓝牙断开/后端抖动）必须抛给调用方，
      // 否则 UI 已显示目标进度、引擎仍在旧位，声画脱节且无错误。
      if (audioPlayer.processingState != ProcessingState.idle) {
        rethrow;
      }
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  /// 跳转到指定位置并起播（常用于歌词点击、准星跳转等场景）。
  /// 兼容冷启动/未播放 (idle) 状态，确保直接从指定位置加载并播放，绝不弹回 0 秒。
  Future<void> seekToAndPlay(Duration position) async {
    final song = currentSong;
    if (song == null) return;
    final target = _clampPosition(position);

    if (audioPlayer.processingState == ProcessingState.idle) {
      _pendingIdlePosition = null;
      await playSong(song, queue: queue, initialPosition: target);
    } else {
      try {
        await seek(target);
      } catch (error) {
        // UI 调用方（歌词行点击等）丢弃本 Future：seek 在非 idle 引擎错误
        // （蓝牙断开/后端抖动）下会故意 rethrow（见 seek 注释），这里不接住
        // 就成了未捕获异步异常。与 queue.dart 的 _seekToStartSafe 同理。
        debugPrint('[易格][player] seekToAndPlay 失败: $error');
        return;
      }
      // 调用方（歌词点击等）常丢弃本 Future，起播失败必须就地接住，
      // 否则成为未取消认领的异步异常（与上方 seek 的处理同理）。
      try {
        await _ensurePlaying();
      } catch (error) {
        debugPrint('[易格][player] seekToAndPlay 起播失败: $error');
      }
    }
  }

  /// 在当前（已被 seek 到的）位置确保真的起播。
  ///
  /// 不能读 `audioPlayer.playing` 判「还在不在播」：曲目播完（completed）后
  /// just_audio 的 playing 不会被置回 false（只有 play()/pause()/stop() 会改它），
  /// 直接 `play()` 会被其首行的 `if (playing) return;` 短路——PC media_kit
  /// 适配层已在 EOF 时回写这段真话，移动端仍可能是陈旧的 true。
  /// 也不能复用 [togglePlay]：它会把 completed 理解成「从头再来」而 seek 回零，
  /// 覆盖调用方刚定位到的目标位置。这里只收敛播放标志，不动位置。
  Future<void> _ensurePlaying() async {
    if (isPlaying) return;
    if (audioPlayer.processingState == ProcessingState.completed) {
      _resetCompletionLatchForReplay();
    }
    await _audioHandler.pause();
    await _requestPlayback();
  }

  /// 当前歌曲「原地重新起播」（曲末点播放 / 曲末点歌词定位）时清掉上一轮的
  /// 完成去重与失败残留。
  ///
  /// [_completedSongHash] 只在 [playSong] 里清；而 3.0.3 起 [togglePlay] 在
  /// completed 下会走 pause→seek(0)→play、[seekToAndPlay] 走 [_ensurePlaying]，
  /// 两条都不经 `playSong`。于是「同一首歌重播」会把去重标记留到下一轮：
  /// 这首歌唱完第二次时 completed 被 [_willHandleCompletion] 去重吞掉，
  /// 队列不再前进，而曲末兜底也会因同一条去重而拒绝接管——表现为
  /// 「停在当前这首不动、进度停在曲尾」（移动端回归）。用户手动起播是一次
  /// 全新尝试，同时清掉曲末跳过耗尽态与持久错误，否则会被上一轮预算拒绝。
  void _resetCompletionLatchForReplay() {
    _completedSongHash = null;
    _completionFallbackTimer?.cancel();
    _nearEndStallRecheck?.cancel();
    _tailSkipExhausted = false;
    errorMessage = null;
  }

  /// 本次「本曲完成」是否会真的被 [_handleCompleted] 处理（去重判定的唯一出处）。
  ///
  /// - 同曲已处理过（[_completedSongHash]）：重复事件，丢弃；
  /// - 同曲的完成流程仍在途（弱网解析下一首可能挂起数秒）：丢弃。
  ///
  /// 曲末跳过预算要先问这里再扣额度，否则可能在「不会推进」的事件上白扣一次。
  bool _willHandleCompletion(Song song) {
    if (_completedSongHash == song.hash) return false;
    if (_isHandlingCompletion && _handlingCompletedHash == song.hash) {
      return false;
    }
    return true;
  }

  Future<void> _handleCompleted() async {
    final song = currentSong;
    if (song == null) {
      _nextLog('完成处理放弃: currentSong=null');
      return;
    }
    if (!_willHandleCompletion(song)) {
      _nextLog(
        '完成处理放弃(去重): ${song.title} completedHash=$_completedSongHash '
        'handling=$_isHandlingCompletion handlingHash=$_handlingCompletedHash',
      );
      return;
    }
    if (_isHandlingCompletion) {
      // 不同歌说明用户已切走且新歌又播完，放行新歌，旧流程自弃
      debugPrint('[易格][player] 上一首完成处理中，新歌又完成，直接处理新歌');
    }
    _isHandlingCompletion = true;
    _handlingCompletedHash = song.hash;
    _completionFallbackTimer?.cancel();
    _nearEndStallRecheck?.cancel();
    _completedSongHash = song.hash;
    _nextLog(
      '完成处理开始: ${song.title} mode=${playbackMode.name} '
      'index=$currentIndex queueLen=${queue.length} '
      'sleepFinish=$_sleepFinishCurrentSong | ${_nextSnapshot()}',
    );

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        _nextLog('完成处理分支: 睡眠定时"播完这首再停" → 暂停，不切歌');
        return;
      }

      if (playbackMode == PlaybackMode.singleLoop) {
        // 重启完成后再清去重 hash：重启在途中重复 completed 事件仍去重，
        // 避免 self-loop 打转；下一轮正常播完可再次触发。
        // completed 后 just_audio.playing 仍为 true，play() 会被
        // `if (playing) return` 短路——必须先 pause 归零再起播。
        _nextLog('完成处理分支: 单曲循环 → 重播本曲');
        await _audioHandler.pause();
        await seek(Duration.zero);
        if (currentSong?.hash != song.hash) return;
        // 同样有界等待：无界 await 会让完成锁一直留到曲末，下一轮重播的
        // completed 被 _willHandleCompletion 去重吞掉（单曲循环只循环一次）。
        await _requestPlayback();
        _completedSongHash = null;
        return;
      }

      final nextSong = _nextSong();
      if (nextSong == null) {
        _nextLog('完成处理分支: 无下一首 → 回零停住');
        await seek(Duration.zero);
        return;
      }
      _nextLog(
        '完成处理分支: 自动切下一首 → ${nextSong.title} '
        '(hash=${nextSong.hash} isSameSong=${nextSong.hash == song.hash})',
      );
      await playSong(nextSong, queue: queue);
    } catch (error) {
      // playSong 内部不抛；这里只可能是 seek/play 引擎异常，记日志
      // 落错误态，避免 unawaited 调用方的未处理异常
      debugPrint('[易格][player] 完成处理失败: $error');
      _nextLog('完成处理异常: ${song.title} → $error');
      if (currentSong?.hash == song.hash) {
        errorMessage = error.toString();
        notifyListeners();
      }
    } finally {
      // 只复位自己绑定的锁：并发的新歌流程不受旧 finally 影响
      if (_handlingCompletedHash == song.hash) {
        _isHandlingCompletion = false;
        _handlingCompletedHash = null;
      }
      _nextLog(
        '完成处理结束: ${song.title} → now=${currentSong?.title ?? '-'} '
        'errorMessage=${errorMessage ?? '-'}',
      );
    }
  }

  void _maybeCompleteFromPosition(Duration value) {
    // 诊断：每首歌只记一次「接近曲尾」判定，含被哪道守卫挡住 —— 实机排查
    // "播完不跳"时，这一行直接说明兜底 timer 到底有没有机会建立。
    // remaining 只取"合理范围"：切歌瞬间上一首的迟到位置事件（远大于新歌
    // duration）会算出 -45s 这类值，记下来只是噪声；而引擎时长略短于元数据
    // 的合法小负值（几十~几百 ms）仍要保留。
    if (duration > Duration.zero) {
      final remaining = duration - value;
      final songHash = currentSong?.hash;
      if (remaining.inMilliseconds <= 750 &&
          remaining.inMilliseconds >= -3000 &&
          songHash != null &&
          _endOfSongLoggedForHash != songHash) {
        _endOfSongLoggedForHash = songHash;
        final blocker = _isSeeking
            ? 'seeking'
            : _isScrubbing
            ? 'scrubbing'
            : !isPlaying
            ? 'ctrlPlaying=false'
            : audioPlayer.processingState == ProcessingState.completed
            ? 'alreadyCompleted'
            : (_completionFallbackTimer?.isActive == true
                  ? 'timerActive'
                  : 'none(将建立兜底 timer)');
        _nextLog(
          '接近曲尾: remaining=${remaining.inMilliseconds}ms '
          'blockedBy=$blocker | ${_nextSnapshot()}',
        );
      }
    }
    if (_isSeeking || _isScrubbing || !isPlaying || duration <= Duration.zero) {
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      return;
    }

    final remaining = duration - value;
    if (remaining.inMilliseconds <= 750 &&
        (_completionFallbackTimer?.isActive != true)) {
      final delay =
          (remaining > Duration.zero ? remaining : Duration.zero) +
          const Duration(milliseconds: 180);
      // 建 timer 时绑定歌曲：触发时已切歌则丢弃，避免旧 timer 推新歌连跳
      final songHash = currentSong?.hash;
      // watchdog 基准：以此判定引擎位置是否自此刻起原地冻结（见 _checkTailStall）。
      _fallbackTimerBuiltAtPosition = value;
      _nearEndStallChecks = 0;
      _nextLog(
        '建立曲末兜底 timer: delay=${delay.inMilliseconds}ms '
        'remaining=${remaining.inMilliseconds}ms song=${currentSong?.title}',
      );
      _completionFallbackTimer = Timer(delay, () {
        if (_disposed || _isSeeking || _isScrubbing) {
          _nextLog(
            '曲末兜底 timer 放弃: disposed=$_disposed seeking=$_isSeeking '
            'scrubbing=$_isScrubbing',
          );
          return;
        }
        if (currentSong?.hash != songHash) {
          _nextLog(
            '曲末兜底 timer 放弃(已切歌): timerSong=$songHash '
            'now=${currentSong?.hash}',
          );
          return;
        }
        // 存活判据不能只看 isPlaying：3.0.3 起曲末 isPlaying 已在 completed
        // 收敛为 false（见 playerStateStream 监听），而本兜底恰恰是为
        // 「引擎已到曲尾、主推进却被守卫吞掉」准备的——例如同曲音质重载
        // 在途（_reloadCurrentSongForQuality 不取消本 timer）会把 completed
        // 分支的 `!_isChangingSource` 整条挡掉。此时若要求 isPlaying 为真，
        // 兜底会在需要它的那一刻失效，队列永久停在曲尾（移动端 3.0.3 回归）。
        // 因此：引擎已宣告 completed 时无条件补推；其余情况仍要求确实在播，
        // 避免用户停在曲尾（暂停）被误判为播完而自动切歌。
        final engineCompleted =
            audioPlayer.processingState == ProcessingState.completed;
        if (!engineCompleted && !isPlaying) {
          _nextLog(
            '曲末兜底 timer 放弃(未在播且引擎未宣告 completed): '
            'ctrlPlaying=$isPlaying | ${_nextSnapshot()}',
          );
          return;
        }
        final currentPosition = audioPlayer.position;
        final nearEnd =
            duration > Duration.zero &&
            duration - currentPosition <= const Duration(milliseconds: 220);
        if (engineCompleted || nearEnd) {
          _nextLog(
            '曲末兜底 timer → 补推完成处理: engineCompleted=$engineCompleted '
            'nearEnd=$nearEnd | ${_nextSnapshot()}',
          );
          unawaited(_handleCompleted());
        } else {
          _nextLog(
            '曲末兜底 timer 未到曲尾: engineCompleted=false '
            'enginePos=${currentPosition.inMilliseconds}ms '
            'dur=${duration.inMilliseconds}ms',
          );
          _checkTailStall(songHash);
        }
      });
    }
  }

  /// 曲末兜底 timer 到点、引擎既未 completed 也不在 220ms 判距内时的
  /// 停滞复检（watchdog）。
  ///
  /// 覆盖的实机形态：CDN 尾部断供（代理上游卡死）时引擎位置冻结在曲尾前
  /// 1~2 秒、playerState 停在 ready/buffering——completed 永远不来，位置
  /// 不再前进也不会再触发新的兜底窗口（remaining > 750ms），队列永久停在
  /// 曲尾、重启才能恢复。这里在「控制器仍在播、位置自兜底 timer 建立起
  /// 纹丝不动」时按 [_kTailStallRecheckInterval] 复检，连续
  /// [_kTailStallMaxChecks] 次仍停滞即强制按播完推进；位置恢复前进或用户
  /// 暂停则立即放弃判定（与主 timer 相同的「暂停不误判为播完」约束）。
  void _checkTailStall(String? songHash) {
    final builtAt = _fallbackTimerBuiltAtPosition;
    final stalled =
        builtAt != null &&
        PlayerPlaybackLogic.isTailStalled(
          ctrlPlaying: isPlaying,
          builtAt: builtAt,
          now: audioPlayer.position,
        );
    if (!stalled) {
      _nearEndStallChecks = 0;
      _nextLog(
        '曲末停滞 watchdog 放弃(位置已前进或已暂停): ctrlPlaying=$isPlaying '
        'builtAt=${builtAt?.inMilliseconds}ms '
        'now=${audioPlayer.position.inMilliseconds}ms | ${_nextSnapshot()}',
      );
      return;
    }
    if (_nearEndStallChecks >= _kTailStallMaxChecks) {
      _nearEndStallChecks = 0;
      final song = currentSong;
      if (song == null || song.hash != songHash) return;
      // 本次强制推进若会被 _handleCompleted 去重掉（同曲已完成过/正在处理），
      // 它不会推进任何东西：先判掉，别白扣预算（与曲末错误路径同理）。
      if (!_willHandleCompletion(song)) {
        _nextLog(
          '曲末停滞 watchdog 强制推进，但完成会被去重吞掉 → 不推进: ${song.title} '
          'completedHash=$_completedSongHash handling=$_isHandlingCompletion '
          'handlingHash=$_handlingCompletedHash',
        );
        return;
      }
      // 计入曲末跳过预算：系统性坏尾（CDN 尾部断供）下每首都会停滞，
      // 不扣预算的话长队列会被无提示地静默抽干、单曲循环会无限重播
      // （与曲末解码错误路径共用同一预算，见 _tryConsumeNearEndSkipBudget）。
      if (!_tryConsumeNearEndSkipBudget(song)) {
        // 预算耗尽：停住并给持久提示（Toast 瞬态，errorMessage 持久）。
        // 不 seek(0)：留在冻结处可 fail-fast，用户点播只需验证尾部，
        // 不必重听整首；若用户手动播完触发自然 completed，预算会正常重置。
        unawaited(_audioHandler.pause());
        isPlaying = false;
        errorMessage = '连续多次在曲末播放失败，已停止自动切歌';
        _tailSkipExhausted = true;
        _setPositionBase(audioPlayer.position, playing: false);
        _lastSmoothPosition = audioPlayer.position;
        _emitPosition();
        notifyListeners();
        return;
      }
      _nextLog(
        '曲末停滞 watchdog → 强制按播完推进: '
        'pos=${audioPlayer.position.inMilliseconds}ms '
        'dur=${duration.inMilliseconds}ms | ${_nextSnapshot()}',
      );
      unawaited(_handleCompleted());
      return;
    }
    _nearEndStallChecks++;
    _nextLog(
      '曲末停滞 watchdog 复检($_nearEndStallChecks/$_kTailStallMaxChecks): '
      'pos=${audioPlayer.position.inMilliseconds}ms | ${_nextSnapshot()}',
    );
    _nearEndStallRecheck?.cancel();
    _nearEndStallRecheck = Timer(_kTailStallRecheckInterval, () {
      if (_disposed || _isSeeking || _isScrubbing) return;
      if (currentSong?.hash != songHash) return;
      // 复检窗口里引擎自行走到 completed（或兜底已推进）：一切交给既有
      // 完成链，watchdog 不再介入。
      if (audioPlayer.processingState == ProcessingState.completed) return;
      _checkTailStall(songHash);
    });
  }

  /// 试听当前歌曲的高潮片段：定位到高潮开始并播放，到高潮结束自动暂停。
  /// 返回是否成功（无高潮片段或失败时返回 false）。
  Future<bool> playClimaxPreview() async {
    final song = currentSong;
    if (song == null) return false;
    try {
      final climax = await _api.songClimax(song.hash);
      if (climax == null) return false;
      // 等待网络期间可能已切歌，避免把旧歌的高潮定位到新歌上。
      if (currentSong?.hash != song.hash) return false;
      this.climax = climax;
      if (audioPlayer.processingState == ProcessingState.idle) {
        await playSong(
          song,
          queue: queue,
          initialPosition: climax.startTime,
          preserveClimax: true,
        );
      } else {
        await seek(climax.startTime);
        // 与 seekToAndPlay 同理：不能读 audioPlayer.playing 判在不在播，
        // 也不能走 togglePlay（completed 下它会 seek 回零，冲掉高潮起点）。
        await _ensurePlaying();
      }
      if (currentSong?.hash != song.hash) return false;
      _climaxEndTime = climax.endTime;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 高潮试听播放到结束时间时自动暂停。
  void _maybeStopClimaxPreview(Duration value) {
    final end = _climaxEndTime;
    if (end == null || value < end) return;
    _climaxEndTime = null;
    // 以 isPlaying 为准：读 audioPlayer.playing 时，completed/暂停 后的陈旧
    // true 会让 togglePlay 走进起播分支，把已经停下的播放又拉起来。
    if (isPlaying) {
      unawaited(togglePlay());
    }
  }

  /// 异步获取当前歌曲高潮时间，用于进度条标记（失败静默）。
  @override
  Future<void> _loadClimax(Song song) async {
    try {
      final result = await _api.songClimax(song.hash);
      if (currentSong?.hash != song.hash) return;
      climax = result;
      notifyListeners();
    } catch (_) {
      if (currentSong?.hash == song.hash) {
        climax = null;
      }
    }
  }

  /// 尝试播放已恢复的当前歌曲。
  ///
  /// 播放失败时按播放模式处理：
  /// - [PlaybackMode.singleLoop]：不切歌，保留错误信息
  /// - [PlaybackMode.playlistLoop] / [PlaybackMode.shuffle]：自动切下一首重试
  ///
  /// 返回 true 表示成功开始播放（或用户在恢复期间手动接管了播放）。
  Future<bool> resumePlayback() async {
    if (currentSong == null || queue.isEmpty) return false;

    final maxAttempts = queue.length;
    var songToPlay = currentSong!;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      errorMessage = null;
      await playSong(songToPlay, queue: queue);
      // 恢复链可能耗时数秒（地址解析+重试），期间用户可能已手动点了别的歌：
      // currentSong 已换人时立即收手，绝不再用 _nextSong() 抢占用户的选择。
      if (currentSong?.hash != songToPlay.hash) return true;
      if (errorMessage == null) return true;

      if (playbackMode == PlaybackMode.singleLoop) {
        return false;
      }

      final nextSong = _nextSong();
      if (nextSong == null) return false;
      songToPlay = nextSong;
    }

    return false;
  }
}
