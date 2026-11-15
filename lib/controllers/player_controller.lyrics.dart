// player_controller.lyrics.dart —— PlayerController 的职责分片：歌词与逐行广播（歌词加载/SuperLyric/车载蓝牙歌词）。成员声明与字段见 player_controller.dart。
part of 'player_controller.dart';

mixin _PlayerLyrics on _PlayerControllerBase {
  /// 开关车载蓝牙歌词广播（默认关闭，避免无车机时多余广播）。
  Future<void> setBluetoothLyricsEnabled(bool enabled) async {
    if (bluetoothLyricsEnabled == enabled) return;
    bluetoothLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bluetoothLyricsEnabledSettingKey, enabled);
    if (!enabled && currentSong != null) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: currentSong!.title,
          artist: currentSong!.artist,
          album: currentSong!.albumName,
          lyric: '',
          position: position,
          duration: currentSong!.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
    } else if (enabled) {
      _pushBluetoothLyricForCurrentLine(force: true);
    }
    notifyListeners();
  }

  @override
  Future<void> loadLyrics(Song song) async {
    final cache = cacheService;
    final cacheKey = 'cache_lyric_${song.hash}';

    if (song.source == SongSource.local) {
      // 1. 优先尝试同名 .lrc 文件
      try {
        final songFile = File(song.id);
        final dotIndex = songFile.path.lastIndexOf('.');
        final lrcPath =
            '${dotIndex != -1 ? songFile.path.substring(0, dotIndex) : songFile.path}.lrc';
        final file = File(lrcPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          String content;
          try {
            content = utf8.decode(bytes);
          } catch (_) {
            content = utf8.decode(bytes, allowMalformed: true);
          }
          final lines = parseLyrics(content);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load local .lrc lyrics: $e');
      }

      // 2. 尝试从音频文件内嵌元数据读取歌词
      try {
        final embedded = await localMusic?.getEmbeddedLyrics(song.id);
        if (embedded != null && embedded.isNotEmpty) {
          final lines = parseLyrics(embedded);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load embedded lyrics: $e');
      }

      // 3. 本地 .lrc 与内嵌歌词均不存在时：联网匹配歌词！
      // 3.1 先查本地歌词缓存
      final localLyricCacheKey = 'cache_lyric_local_${song.hash}';
      if (cache != null) {
        try {
          final cached = await cache.read<List<LyricLine>>(
            localLyricCacheKey,
            decode: (json) => (json['lines'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(LyricLine.fromCache)
                .toList(),
            ttl: const Duration(days: 30),
          );
          if (cached != null &&
              cached.data.isNotEmpty &&
              currentSong?.hash == song.hash) {
            lyrics = cached.data;
            notifyListeners();
            _syncDesktopLyrics();
            return;
          }
        } catch (_) {}
      }

      // 3.2 联网匹配歌词
      try {
        final candidates = await _searchLocalSongCandidates(song);
        final matched = _findBestLocalMatch(candidates, song);
        if (matched != null) {
          // 若此时当前歌曲还没有封面，顺便把网络匹配到的封面同步补齐
          if (currentSong?.hash == song.hash &&
              (currentSong?.coverUrl == null || currentSong!.coverUrl!.isEmpty)) {
            if (matched.coverUrl != null && matched.coverUrl!.isNotEmpty) {
              _applyResolvedLocalCover(song, matched.coverUrl!);
            }
          }

          final fresh = await _api.lyrics(matched);
          if (fresh.isNotEmpty) {
            if (currentSong?.hash == song.hash) {
              lyrics = fresh;
              notifyListeners();
              _syncDesktopLyrics();
            }
            if (cache != null) {
              unawaited(
                cache
                    .write(localLyricCacheKey, {
                      'lines': fresh.map((l) => l.toCache()).toList(),
                    })
                    .catchError((Object _) {}),
              );
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('Failed to match online lyrics for local song: $e');
      }

      if (currentSong?.hash == song.hash) {
        lyrics = const [];
        notifyListeners();
        _syncDesktopLyrics();
      }
      return;
    }

    // 1. 先读缓存，命中则立即显示（无感）
    if (cache != null) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          cacheKey,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: const Duration(days: 30),
        );
        if (cached != null &&
            !listEquals(lyrics, cached.data) &&
            currentSong?.hash == song.hash) {
          lyrics = cached.data;
          notifyListeners();
          _syncDesktopLyrics();
        }
      } catch (_) {}
    }

    // 2. 后台静默刷新
    try {
      final fresh = await _api.lyrics(song);
      if (currentSong?.hash == song.hash && !listEquals(lyrics, fresh)) {
        lyrics = fresh;
        notifyListeners();
      }
      // 写缓存（空歌词也缓存，避免重复请求）。写失败要吞掉异常：
      // write 在平台层 setString 返回 false 时会 throw，unawaited 的
      // async 错误会逃逸成未处理异常（外层同步 try/catch 接不住）。
      if (cache != null) {
        unawaited(
          cache
              .write(cacheKey, {
                'lines': fresh.map((l) => l.toCache()).toList(),
              })
              .catchError((Object _) {}),
        );
      }
    } catch (_) {
      // 拉取失败保持静默：此时 lyrics 若非空必为本歌缓存数据（切歌时
      // playSong 已先清空），清掉只会丢好数据；若为空则任何通知都会与
      // 进页兜底（ensureLyricsLoaded）互相触发，形成无限重拉循环。
    }
    if (currentSong?.hash == song.hash) {
      _syncDesktopLyrics();
    }
  }

  /// 进入播放页时的兜底：[loadLyrics] 只在 [playSong] 成功加载音频后触发，
  /// 恢复播放/请求失败等路径下歌词可能为空，进页必须补拉一次。
  /// 已有歌词时直接返回，不产生额外请求。
  Future<void> ensureLyricsLoaded() async {
    final song = currentSong;
    if (song == null || lyrics.isNotEmpty) return;
    // 同一首歌的拉取已在进行中则跳过，防止页面 didUpdateWidget 反复触发并发重拉。
    if (_lyricsFetchInFlightHash == song.hash) return;
    _lyricsFetchInFlightHash = song.hash;
    try {
      await loadLyrics(song);
    } finally {
      // 无论成功失败都释放，切歌后新歌的兜底拉取不被卡住。
      if (_lyricsFetchInFlightHash == song.hash) {
        _lyricsFetchInFlightHash = null;
      }
    }
  }

  // ---- 歌词进度偏移 ----
  // 设计见 docs/superpowers/specs/2026-09-21-lyric-progress-offset-design.md。

  /// 步进调节当前歌曲的歌词进度（[delta] 为正 = 歌词提前，例如
  /// [kLyricOffsetStep] 表示提前 0.5 秒）。
  @override
  Future<void> adjustLyricOffset(Duration delta) =>
      setLyricOffset(lyricOffset + delta);

  /// 直接把当前歌曲的偏移设为 [value]（超过 ±[kLyricOffsetLimit] 会被夹取）。
  ///
  /// 偏移落定后按歌曲持久化：0 即删除记录，非 0 记录毫秒值（酷狗/QQ 音乐
  /// 同款"这首歌字幕偏了"的一次性修正，换歌不受影响、下次播放仍生效）。
  @override
  Future<void> setLyricOffset(Duration value) async {
    final next = PlayerLyricOffsetLogic.clamp(value, kLyricOffsetLimit);
    if (next == lyricOffset) return;
    lyricOffset = next;
    final song = currentSong;
    if (song != null) {
      // 先删再插：Map 保持插入序，重新插入即把该歌顶到 LRU 最新端。
      _lyricOffsets.remove(song.hash);
      if (next != Duration.zero) {
        _lyricOffsets[song.hash] = next.inMilliseconds;
      }
      while (_lyricOffsets.length > kLyricOffsetStoreLimit) {
        _lyricOffsets.remove(_lyricOffsets.keys.first);
      }
    }
    _notifyLyricOffsetChanged();
    await _scheduleLyricOffsetPersist();
  }

  /// 偏移落盘调度：空闲态首调立即写（单击语义与旧版一致，可确定性断言），
  /// 随后开 [_kLyricOffsetPersistWindow] 窗口；窗口内的后调只记脏。
  /// 窗口结束时若脏则尾写一次并按需续窗——`− / +` 长按连调 130ms 一步，
  /// 不合并的话 20 秒长按≈150 次 SharedPreferences 写，合并后首写＋尾写
  /// 共 2 次。并发重入（理论上只有连点才碰得到）：后调记脏合并，
  /// 最坏多一次幂等的全量覆盖，无正确性问题。
  Future<void> _scheduleLyricOffsetPersist() async {
    if (_lyricOffsetPersistDebounce != null) {
      _lyricOffsetPersistDirty = true;
      return;
    }
    await _persistLyricOffsets();
    if (_disposed) return;
    _lyricOffsetPersistDebounce = Timer(
      _kLyricOffsetPersistWindow,
      _onLyricOffsetPersistWindow,
    );
  }

  void _onLyricOffsetPersistWindow() {
    _lyricOffsetPersistDebounce = null;
    if (_lyricOffsetPersistDirty) {
      _lyricOffsetPersistDirty = false;
      unawaited(_persistLyricOffsets());
      if (!_disposed) {
        _lyricOffsetPersistDebounce = Timer(
          _kLyricOffsetPersistWindow,
          _onLyricOffsetPersistWindow,
        );
      }
    }
  }

  /// 尽快落盘窗口内未写入的偏移（dispose 时防抖窗口还有脏值）。
  void _flushPendingLyricOffsetPersist() {
    final pending = _lyricOffsetPersistDebounce?.isActive ?? false;
    _lyricOffsetPersistDebounce?.cancel();
    _lyricOffsetPersistDebounce = null;
    if (pending && _lyricOffsetPersistDirty) {
      _lyricOffsetPersistDirty = false;
      unawaited(_persistLyricOffsets());
    }
  }

  /// 重置当前歌曲的歌词进度（回到"以歌词自带时间为准"）。
  ///
  /// 重置是 deliberate 的单次动作（按钮不可长按连调）：先取消防抖窗口
  /// 再走正常落盘，保证语义确定、可断言；否则紧跟 ± 后的重置会被记脏、
  /// 延迟到窗口结束才生效。
  @override
  Future<void> resetLyricOffset() async {
    _lyricOffsetPersistDebounce?.cancel();
    _lyricOffsetPersistDebounce = null;
    _lyricOffsetPersistDirty = false;
    await setLyricOffset(Duration.zero);
  }

  /// 装载某首歌自己的偏移（切歌、启动恢复时调用）；无记录即归零。
  @override
  void _loadLyricOffsetForSong(Song? song) {
    final next = Duration(
      milliseconds: song == null ? 0 : (_lyricOffsets[song.hash] ?? 0),
    );
    if (next == lyricOffset) return;
    lyricOffset = next;
    _notifyLyricOffsetChanged();
  }

  /// 偏移变更后的统一广播。
  ///
  /// 三路"上一句"缓存必须一起失效：否则悬浮窗/超级歌词/蓝牙要等到下一句
  /// 才换文本；再主动补推一次，让当前句与逐字进度立刻按新偏移重排。
  void _notifyLyricOffsetChanged() {
    if (_disposed) return;
    _lastDesktopLyricIndex = -1;
    _lastSuperLyricIndex = -1;
    _lastBluetoothLyricIndex = -1;
    notifyListeners();
    _syncDesktopLyrics();
    _syncDesktopKaraokeProgress();
    // Android（易格方案）：歌词文本没变（去重不会重发），但锚点位置必须
    // 按新偏移重算——原生引擎的 lyricPosition 语义 = Flutter 推来的
    // 锚点 + 悬浮窗自己的 lyricOffsetMs，重锚后当前句立即按新偏移对齐。
    if (!isDesktopFormFactor && desktopLyricsEnabled) {
      unawaited(
        _androidLyric.calibratePosition(positionMs: lyricPosition.inMilliseconds),
      );
    }
    _syncSuperLyricFromPosition();
    _syncBluetoothLyricsFromPosition();
  }

  Future<void> _persistLyricOffsets() async {
    final prefs = await SharedPreferences.getInstance();
    if (_lyricOffsets.isEmpty) {
      // 全部归零就把键删掉，不给下次启动留一份空 JSON。
      await prefs.remove(_lyricOffsetsSettingKey);
      return;
    }
    await prefs.setString(_lyricOffsetsSettingKey, jsonEncode(_lyricOffsets));
  }

  /// 启动恢复逐曲偏移映射。恢复后由调用方再对齐当前歌（构造函数里
  /// [_restoreSettings] 与 [_restorePlaybackState] 都是 unawaited 发起，
  /// 恢复映射时可能已经有歌在播了）。
  ///
  /// **不清空内存镜像**：读取落盘值之前，用户可能已经在播放页调过偏移，
  /// 那是更新的真值（磁盘上要么还没有这个键、要么还是旧值），所以按
  /// "内存优先"合并——否则启动瞬间的调整会被恢复流程抹回 0。
  @override
  void _restoreLyricOffsets(SharedPreferences prefs) {
    final raw = prefs.getString(_lyricOffsetsSettingKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is String && value is num) {
            _lyricOffsets.putIfAbsent(key, () => value.round());
          }
        }
      }
    } catch (error) {
      debugPrint('[易格][歌词] 歌词进度偏移恢复失败（跳过）: $error');
    }
  }

  void _syncSuperLyricFromPosition() {
    if (currentSong == null) return;
    if (lyrics.isEmpty) {
      if (!isPlaying && _lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = false;
        _lastSuperLyricIndex = -1;
        unawaited(_superLyric.sendStop());
      } else if (isPlaying && !_lastSuperLyricPlaying) {
        _lastSuperLyricPlaying = true;
      }
      return;
    }
    final index = activeLyricIndex;
    final lineChanged = isPlaying && (index != _lastSuperLyricIndex);
    final resumed = isPlaying && !_lastSuperLyricPlaying;
    if (lineChanged || resumed) {
      _lastSuperLyricIndex = index;
      _lastSuperLyricPlaying = true;
      final clampedIndex = index.clamp(0, lyrics.length - 1);
      final line = lyrics[clampedIndex];
      final lineEndTime =
          line.time +
          (line.duration ??
              _estimatedLineDuration(clampedIndex) ??
              Duration.zero);
      unawaited(
        _superLyric.sendLyric(
          song: currentSong!,
          line: line,
          lineEndTime: lineEndTime,
        ),
      );
    } else if (!isPlaying && _lastSuperLyricPlaying) {
      _lastSuperLyricPlaying = false;
      unawaited(_superLyric.sendStop());
    }
  }

  void _syncBluetoothLyricsFromPosition() {
    if (!bluetoothLyricsEnabled) return;
    if (currentSong == null) return;
    final index = lyrics.isEmpty ? -1 : activeLyricIndex;
    final lineChanged = index != _lastBluetoothLyricIndex;
    final playingChanged = isPlaying != _lastBluetoothPlaying;
    if (lineChanged || playingChanged) {
      _pushBluetoothLyricForCurrentLine(
        index: index,
        forcePlayState: playingChanged,
      );
    }
  }

  void _pushBluetoothLyricForCurrentLine({
    bool force = false,
    int? index,
    bool forcePlayState = false,
  }) {
    if (!bluetoothLyricsEnabled || currentSong == null) return;
    final song = currentSong!;
    final resolvedIndex = index ?? (lyrics.isEmpty ? -1 : activeLyricIndex);
    final prevIndex = _lastBluetoothLyricIndex;

    final String lyricText;
    if (lyrics.isEmpty || resolvedIndex < 0) {
      lyricText = '';
      _lastBluetoothLyricIndex = -1;
    } else {
      final clampedIndex = resolvedIndex.clamp(0, lyrics.length - 1);
      lyricText = lyrics[clampedIndex].text;
      _lastBluetoothLyricIndex = clampedIndex;
    }

    _lastBluetoothPlaying = isPlaying;

    final lineChanged = force || prevIndex != _lastBluetoothLyricIndex;
    if (lineChanged) {
      unawaited(
        _bluetoothLyrics.broadcastMetaChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          lyric: lyricText,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
          trackIndex: currentIndex,
          listSize: queue.length,
        ),
      );
    }
    if (forcePlayState) {
      unawaited(
        _bluetoothLyrics.broadcastPlayStateChanged(
          title: song.title,
          artist: song.artist,
          album: song.albumName,
          position: position,
          duration: song.duration ?? Duration.zero,
          playing: isPlaying,
        ),
      );
    }
  }
}
