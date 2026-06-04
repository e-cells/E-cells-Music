import { defineStore } from 'pinia';
import { reactive, toRefs } from 'vue';
import { PERSONAL_FM_QUEUE_ID, usePlaylistStore } from './playlist';
import { useLyricStore } from './lyric';
import { useSettingStore } from './setting';
import { useUserStore } from './user';
import logger from '@/utils/logger';
import { PlayerEngine, type PlayerEngineEvents } from '@/utils/player';
import type { Song } from '@/models/song';
import { search as apiSearch } from '@/api/search';
import { mapSearchSong } from '@/utils/mappers/song';

import { createPlayerState } from './player/state';
import { createPlaybackManager } from './player/playback';
import { createAudioManager } from './player/audio';
import { createResolver } from './player/resolver';
import { createHistoryManager } from './player/history';
import { createDeviceManager } from './player/device';
import { buildMediaState, findTrackById, resolvePlaybackNotice } from './player/utils';
import { isPlayableSong } from '@/utils/song';

const engine = new PlayerEngine();

export const usePlayerStore = defineStore(
  'player',
  () => {
    const state = reactive(createPlayerState());
    const playlistStore = usePlaylistStore();
    const settingStore = useSettingStore();
    const lyricStore = useLyricStore();

    const resolver = createResolver(state, playlistStore, settingStore);
    const historyManager = createHistoryManager(state);

    const refreshCurrentTrack = async () => {
      if (!state.currentTrackId) return;
      if (state.isLoading) {
        state.pendingSettingRefresh = true;
        return;
      }
      const requestSeq = ++state.playbackRequestSeq;
      const track = findTrackById(state.currentTrackId, state.currentPlaylist, playlistStore);
      if (!track) return;

      state.pendingSettingRefresh = false;
      const wasPlaying = state.isPlaying;
      const previousTime = state.currentTime;
      state.isLoading = true;

      const resolved = await resolver.resolveAudioUrl(track, { forceReload: true });
      if (requestSeq !== state.playbackRequestSeq) return;
      if (!resolved.url) {
        state.isLoading = false;
        state.lastError = 'audio-url-unavailable';
        showPlaybackNotice('audio-url-unavailable', track);
        return;
      }

      clearPlaybackNotice();

      engine.setVolume(state.volume);
      if (requestSeq !== state.playbackRequestSeq) return;

      state.currentAudioUrl = resolved.url;
      state.currentResolvedAudioQuality = resolved.quality;
      state.currentResolvedAudioEffect = resolved.effect;
      track.audioUrl = resolved.url;
      const savedDuration = state.duration;
      engine.setSource(resolved.url);
      if (!state.duration && !engine.duration && savedDuration) state.duration = savedDuration;
      engine.applyTrackLoudness(resolved.loudness);
      engine.setPlaybackRate(state.playbackRate);
      void resolver.fetchClimaxMarks(track);

      if (previousTime > 0) {
        state.recentSeekIgnoreEnd = true;
        window.setTimeout(() => {
          state.recentSeekIgnoreEnd = false;
        }, 1500);
        let actualDuration = engine.duration;
        if (actualDuration <= 0) {
          for (let i = 0; i < 10; i++) {
            await new Promise((r) => window.setTimeout(r, 50));
            actualDuration = engine.duration;
            if (actualDuration > 0) break;
          }
        }
        let safeTime = previousTime;
        if (actualDuration > 0 && previousTime >= actualDuration - 0.5) safeTime = 0;
        engine.seek(safeTime);
        state.currentTime = safeTime;
      }

      if (wasPlaying) {
        try {
          await engine.play();
          if (requestSeq !== state.playbackRequestSeq) return;
        } catch (error) {
          logger.error('PlayerStore', 'Reload track failed:', error);
        }
      }
      if (!state.duration && !engine.duration && track.duration) state.duration = track.duration;
      if (wasPlaying) engine.setVolume(state.volume);
      state.isLoading = false;
      if (state.pendingSettingRefresh) {
        state.pendingSettingRefresh = false;
        void refreshCurrentTrack();
      }
    };

    const audioManager = createAudioManager(state, engine, refreshCurrentTrack);
    const deviceManager = createDeviceManager(state, engine, settingStore);
    const showPlaybackNotice = (code: string, track?: Song | null) => {
      state.playbackNotice = resolvePlaybackNotice({
        code,
        track,
        autoNextEnabled: true,
        autoNextDelaySeconds: settingStore.autoNextDelaySeconds,
      });
    };

    const clearPlaybackNotice = (trackId?: string | number | null) => {
      if (!state.playbackNotice) return;
      if (
        trackId !== undefined &&
        trackId !== null &&
        state.playbackNotice.trackId !== String(trackId)
      )
        return;
      state.playbackNotice = null;
    };

    const playbackManager = createPlaybackManager(
      state,
      engine,
      playlistStore,
      settingStore,
      lyricStore,
      resolver,
      historyManager,
      showPlaybackNotice,
      clearPlaybackNotice,
    );

    const toggleLyricView = (open?: boolean) => {
      state.isLyricViewOpen = open ?? !state.isLyricViewOpen;
    };

    const handlePlaybackEnded = async () => {
      if (playlistStore.activeQueue?.id === PERSONAL_FM_QUEUE_ID) {
        const nextFmSong = await playlistStore.consumeNextPersonalFmTrack({
          track: state.currentTrackSnapshot,
          playtime: state.duration,
          isOverplay: true,
        });

        if (nextFmSong) {
          await playbackManager.playTrack(String(nextFmSong.id), playlistStore.activeQueue.songs, {
            sourceQueueId: PERSONAL_FM_QUEUE_ID,
          });
        } else {
          playbackManager.stop();
        }
        return;
      }
      if (state.playMode === 'single') {
        if (state.currentAudioUrl) {
          engine.reset();
          engine.setSourceMeta(
            state.currentTrackSnapshot?.hash ?? '',
            state.currentResolvedAudioQuality ?? '',
          );
          engine.setSource(state.currentAudioUrl);
          void engine.play();
        }
        return;
      }
      playbackManager.next();
    };

    const registerSettingWatchers = () => {
      if (state.settingsWatcherRegistered) return;
      state.settingsWatcherRegistered = true;
      let snapshot = {
        defaultAudioQuality: settingStore.defaultAudioQuality,
        compatibilityMode: settingStore.compatibilityMode,
        volumeFade: settingStore.volumeFade,
        volumeFadeTime: settingStore.volumeFadeTime,
        outputDevice: settingStore.outputDevice,
        exclusiveAudioDevice: settingStore.exclusiveAudioDevice,
      };
      settingStore.$subscribe(() => {
        const shouldRefresh =
          (state.currentAudioQualityOverride === null &&
            settingStore.defaultAudioQuality !== snapshot.defaultAudioQuality) ||
          settingStore.compatibilityMode !== snapshot.compatibilityMode;
        const shouldUpdateFade =
          settingStore.volumeFade !== snapshot.volumeFade ||
          settingStore.volumeFadeTime !== snapshot.volumeFadeTime;
        const shouldUpdateOutputDevice =
          settingStore.outputDevice !== snapshot.outputDevice ||
          settingStore.exclusiveAudioDevice !== snapshot.exclusiveAudioDevice;
        snapshot = {
          defaultAudioQuality: settingStore.defaultAudioQuality,
          compatibilityMode: settingStore.compatibilityMode,
          volumeFade: settingStore.volumeFade,
          volumeFadeTime: settingStore.volumeFadeTime,
          outputDevice: settingStore.outputDevice,
          exclusiveAudioDevice: settingStore.exclusiveAudioDevice,
        };
        if (shouldRefresh) {
          if (state.isLoading || state.pendingSettingRefresh) state.pendingSettingRefresh = true;
          else void refreshCurrentTrack();
        }
        if (shouldUpdateFade && state.isPlaying) {
          void audioManager.fadeVolume(state.volume, { durationMs: 120, respectUserVolume: false });
        }
        if (shouldUpdateOutputDevice)
          void deviceManager.applyOutputDevice(settingStore.outputDevice);
      });
    };

    const init = () => {
      engine.setVolume(state.volume);
      engine.setPlaybackRate(state.playbackRate);
      engine.setVolumeNormalization(settingStore.volumeNormalization);
      engine.setReferenceLufs(settingStore.volumeNormalizationLufs);
      engine.setLoopFile(state.playMode === 'single');
      registerSettingWatchers();
      deviceManager.registerOutputDeviceWatcher();
      void deviceManager.refreshOutputDevices();

      let lastMediaSessionSync = 0;
      const MEDIA_SESSION_SYNC_MS = 5000;
      let lastSyncedPosition = -1;
      let lastHistoryCheck = 0;
      const HISTORY_CHECK_MS = 10000;

      // ── Stall detection ──
      let lastTimeUpdateAt = 0;
      let stallCheckTimer: number | null = null;
      const STALL_TIMEOUT_MS = 5000;
      const STALL_CHECK_INTERVAL_MS = 3000;
      const startStallCheck = () => {
        stopStallCheck();
        stallCheckTimer = window.setInterval(() => {
          if (state.isPlaying && !state.isLoading && state.currentTrackId && lastTimeUpdateAt > 0) {
            const elapsed = Date.now() - lastTimeUpdateAt;
            if (elapsed > STALL_TIMEOUT_MS) {
              logger.warn('PlayerStore', 'Stall detected, triggering recovery', {
                elapsed,
                currentTime: state.currentTime,
                trackId: state.currentTrackId,
              });
              playbackManager.triggerAutoRecovery();
              stopStallCheck();
            }
          }
        }, STALL_CHECK_INTERVAL_MS);
      };
      const stopStallCheck = () => {
        if (stallCheckTimer !== null) {
          window.clearInterval(stallCheckTimer);
          stallCheckTimer = null;
        }
      };

      const events: PlayerEngineEvents = {
        timeUpdate: (currentTime) => {
          if (state.isDraggingProgress) return;
          if (
            state.seekTargetTime !== null &&
            Date.now() - state.seekTimestamp < 500 &&
            currentTime < state.seekTargetTime - 0.5
          )
            return;
          state.seekTargetTime = null;
          state.currentTime = currentTime;
          lastTimeUpdateAt = Date.now();
          const now = Date.now();

          // MediaSession 同步 — 始终执行（后台也需要，保持方向盘按键响应）
          if (now - lastMediaSessionSync >= MEDIA_SESSION_SYNC_MS) {
            const posDelta = Math.abs(state.currentTime - lastSyncedPosition);
            if (posDelta >= 1.0 || lastSyncedPosition < 0) {
              lastMediaSessionSync = now;
              lastSyncedPosition = state.currentTime;
              engine.updateMediaPlaybackState(buildMediaState(state));
            }
          }

          // 以下操作在后台时跳过（避免不必要的网络请求）
          if (document.hidden) return;
          if (now - lastHistoryCheck >= HISTORY_CHECK_MS) {
            state.lastPlayTime = currentTime;
            lastHistoryCheck = now;
            void historyManager.commitListeningHistory();
          }
        },
        durationChange: (duration) => {
          state.duration = duration;
          engine.updateMediaPlaybackState(buildMediaState(state));
          const trackDuration = state.currentTrackSnapshot?.duration ?? 0;
          if (duration > 0 && trackDuration > 0) {
            const diff = Math.abs(duration - trackDuration);
            lyricStore.lyricSyncWarning = diff > 10 && diff / trackDuration > 0.1;
          } else {
            lyricStore.lyricSyncWarning = false;
          }
        },
        ended: () => {
          stopStallCheck();
          if (!state.recentSeekIgnoreEnd) handlePlaybackEnded();
          else state.recentSeekIgnoreEnd = false;
        },
        play: () => {
          state.isPlaying = true;
          state.isLoading = false;
          lastTimeUpdateAt = Date.now();
          startStallCheck();
          clearPlaybackNotice(state.currentTrackId);
          settingStore.syncPreventSleep(true);
          engine.updateMediaPlaybackState(buildMediaState(state));
        },
        pause: () => {
          state.isPlaying = false;
          stopStallCheck();
          settingStore.syncPreventSleep(false);
          engine.updateMediaPlaybackState(buildMediaState(state));
        },
        error: (event) => {
          if (event && !event.isTrusted && !(event as any)?.detail && !(event as any)?.fromEngine)
            return;
          stopStallCheck();
          state.lastError = (event as any)?.type ?? 'playback-error';
          showPlaybackNotice('playback-failed', state.currentTrackSnapshot);
          playbackManager.applyFailedPlaybackState({ keepResolvedSource: true });
          settingStore.syncPreventSleep(false);
          if (state.currentTrackId) {
            playbackManager.triggerAutoRecovery();
          }
          if (state.currentPlaylist?.length)
            playbackManager.scheduleAutoNext();
          else playbackManager.clearAutoNextTimer();
        },
        cacheProgress: (data) => {
          if (data.cacheKey === state.cacheProgressKey) {
            state.cacheProgress = data.percent;
          }
        },
      };
      engine.setEvents(events);
      engine.setMediaSessionHandlers({
        // 确保只有在非播放状态下才触发播放
        play: () => {
          if (!state.isPlaying) playbackManager.togglePlay();
        },
        // 确保只有在播放状态下才触发暂停
        pause: () => {
          if (state.isPlaying) playbackManager.togglePlay();
        },
        previoustrack: () => playbackManager.prev(),
        nexttrack: () => playbackManager.next(),
        seekto: (time) => playbackManager.seek(time),
        seekbackward: (offset) => playbackManager.seek(Math.max(0, state.currentTime - offset)),
        seekforward: (offset) =>
          playbackManager.seek(Math.min(state.duration, state.currentTime + offset)),
        playfromsearch: (query: string) => {
          const store = usePlayerStore();
          store.voiceSearchPlay(query);
        },
      });
      window.electron?.mpv?.getState?.().then((mpvState) => {
        if (!mpvState) return;
        if (mpvState.playing && !state.isPlaying) {
          state.isPlaying = true;
          state.isLoading = false;
          settingStore.syncPreventSleep(true);
        }
        if (mpvState.duration > 0) state.duration = mpvState.duration;
        if (mpvState.timePos > 0) state.currentTime = mpvState.timePos;
      });

      // Auto-play on startup: restore last played track with saved progress
      if (settingStore.autoPlayOnStart && state.currentTrackId) {
        const userStore = useUserStore();
        if (userStore.isLoggedIn) {
          let list =
            state.currentPlaylist ?? playlistStore.activeQueue?.songs ?? playlistStore.defaultList;
          let track = findTrackById(state.currentTrackId, list, playlistStore);
          // Fallback to persisted snapshot when playlist is empty on restart
          if (!track && state.currentTrackSnapshot) {
            track = state.currentTrackSnapshot;
            // 仅当列表确实为空时才设为单曲，否则保留原列表供 next()/prev() 使用
            if (!list || list.length === 0) {
              list = [track];
            }
          }
          if (track && isPlayableSong(track)) {
            const savedTime = state.lastPlayTime > 0 ? state.lastPlayTime : undefined;
            void playbackManager.playTrack(String(track.id), list, {
              seekToTime: savedTime,
            });
          }
        }
      }
    };

    const notifySeekStart = () => {
      state.isDraggingProgress = true;
    };
    const notifySeekEnd = () => {
      state.isDraggingProgress = false;
    };
    const setVolumeSmooth = async (value: number, durationMs?: number) => {
      await engine.fadeTo(value, durationMs ?? 1000);
      state.volume = engine.volume;
    };

    // Explicitly return state and actions to help TypeScript
    return {
      ...toRefs(state),
      // State-like (actually actions but Pinia treats them as actions)
      getEffectiveAudioQuality: resolver.getEffectiveAudioQuality,
      getResolvedAudioQuality: resolver.getResolvedAudioQuality,
      ensureTrackRelateGoods: resolver.ensureTrackRelateGoods,
      resolveAudioUrl: resolver.resolveAudioUrl,
      fetchClimaxMarks: resolver.fetchClimaxMarks,

      getTrackedPlayCount: historyManager.getTrackedPlayCount,
      syncTrackedPlayCount: historyManager.syncTrackedPlayCount,
      hydrateHistoryPlayCounts: historyManager.hydrateHistoryPlayCounts,
      resetHistoryUploadState: historyManager.resetHistoryUploadState,
      commitListeningHistory: historyManager.commitListeningHistory,

      setVolume: audioManager.setVolume,
      setPlaybackRate: audioManager.setPlaybackRate,
      setPlayMode: audioManager.setPlayMode,
      setVolumeNormalization: audioManager.setVolumeNormalization,
      setReferenceLufs: audioManager.setReferenceLufs,
      setEq: audioManager.setEq,
      setAudioEffect: audioManager.setAudioEffect,
      fadeVolume: audioManager.fadeVolume,
      setCurrentAudioQualityOverride: audioManager.setCurrentAudioQualityOverride,

      refreshOutputDevices: deviceManager.refreshOutputDevices,
      applyOutputDevice: deviceManager.applyOutputDevice,

      playTrack: playbackManager.playTrack,
      togglePlay: playbackManager.togglePlay,
      seek: playbackManager.seek,
      next: playbackManager.next,
      prev: playbackManager.prev,
      stop: playbackManager.stop,
      voiceSearchPlay: async (query: string) => {
        try {
          if (!query) return;
          const text = query.trim().toLowerCase();

          // 1. 拦截常见的语音控制指令（子串匹配，优先匹配具体指令避免泛化词干扰）
          const nextKeywords = ['下一首歌曲', '下一首歌', '换下一首', '切下一首', '再来一首', '再来一曲', '换一首歌', '跳一首', '跳一曲', '切一首', '下一首', '下一曲', '下一支', '换一首', '换歌', '切歌', '跳过', '下首', '下首歌', '后一首', '下一集', '往后切', 'next track', 'next song', 'skip', 'next'];
          const prevKeywords = ['上一首歌曲', '回上一首', '回上一曲', '切上一首', '回退一首', '上一首歌', '上一首', '上一曲', '上一支', '上一曲目', '前一首歌', '上一集', '退一首', '退一曲', '倒一首', '往前切', '上首', '上首歌', '前一首', 'previous track', 'prev track', 'previous', 'prev'];
          const pauseKeywords = ['暂停播放', '暂停', '停', '别放了', '停止播放', 'pause', 'stop'];
          const playKeywords = ['继续播放', '开始播放', '继续', '播放', '开始', 'play', 'resume'];

          if (nextKeywords.some(kw => text.includes(kw))) {
            playbackManager.next();
            return;
          }
          if (prevKeywords.some(kw => text.includes(kw))) {
            playbackManager.prev();
            return;
          }
          if (pauseKeywords.some(kw => text.includes(kw))) {
            if (state.isPlaying) playbackManager.togglePlay();
            return;
          }
          if (playKeywords.some(kw => text.includes(kw))) {
            if (!state.isPlaying) playbackManager.togglePlay();
            return;
          }

          // 2. 如果不是控制指令，则执行正常的搜索播放逻辑
          const res = await apiSearch(query, 'song', 1, 100);
          const data = (res as any)?.data;
          const lists = data?.lists ?? data?.list ?? [];
          if (Array.isArray(lists) && lists.length > 0) {
            const songList: Song[] = lists.map((s: unknown) => mapSearchSong(s));

            const playlistStore = usePlaylistStore();

            if (settingStore.voiceSearchMode === 'first') {
              // 仅播首曲：只播放第一首歌，不替换当前队列，播完后继续原来的播放列表
              const currentQueueSongs = playlistStore.activeQueue?.songs ?? playlistStore.defaultList;
              await playbackManager.playTrack(String(songList[0].id), currentQueueSongs, {
                autoPlay: true,
                sourceQueueId: playlistStore.activeQueueId,
              });
            } else {
              // 全部结果：将搜索结果全部加载到播放队列
              playlistStore.setPlaybackQueueWithOptions(songList, 0, {
                queueId: `search-${Date.now()}`,
                title: `语音搜索: ${query}`,
                type: 'search',
                activate: true,
              });

              await playbackManager.playTrack(String(songList[0].id), songList, {
                autoPlay: true,
                sourceQueueId: playlistStore.activeQueueId,
              });
            }
          }
        } catch (e) {
          logger.error('Voice search play failed', e);
        }
      },

      toggleLyricView,
      showPlaybackNotice,
      clearPlaybackNotice,
      refreshCurrentTrack,
      init,
      notifySeekStart,
      notifySeekEnd,
      setVolumeSmooth,
    };
  },
  {
    persist: {
      pick: [
        'volume',
        'playMode',
        'currentTrackId',
        'playbackRate',
        'audioEffect',
        'equalizerGains',
        'historyPlayCountMap',
        'lastPlayTime',
        'currentTrackSnapshot',
        'currentPlaylist', // 👈 完美的补丁：让本地缓存记住整个播放列表数组
      ],
    },
  },
);