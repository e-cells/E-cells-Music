import { Howl } from 'howler';
import { isGeckoView } from './nativeBridge';
import NativeAudio from './nativeAudio';
import { WebAudioEffectEngine } from './webAudioEffectEngine';
import logger from './logger';

export interface PlayerEngineEvents {
  timeUpdate?: (currentTime: number) => void;
  durationChange?: (duration: number) => void;
  ended?: () => void;
  play?: () => void;
  pause?: () => void;
  error?: (event: Event) => void;
  cacheProgress?: (data: { cacheKey: string; percent: number }) => void;
}

export interface MediaSessionMeta {
  title: string;
  artist: string;
  album?: string;
  artwork?: Array<{ src: string; sizes: string; type: string }>;
  durationMs?: number;
}

export interface MediaSessionState {
  isPlaying: boolean;
  duration: number;
  currentTime: number;
  playbackRate: number;
}

export interface TrackLoudness {
  lufs: number;
  gain: number;
  peak: number;
}

const clamp = (value: number, min: number, max: number): number =>
  Math.min(max, Math.max(min, value));

const DEFAULT_REFERENCE_LUFS = -14.0;

const useOnlineBackend = (): boolean => {
  return true;
};

const mpv = window.electron?.mpv;
const mediaControls = window.electron?.mediaControls;
const hasMpv = !!mpv && !useOnlineBackend();

const useNativeAudio = isGeckoView;
const useNativeNotification = isGeckoView;

export class PlayerEngine {
  private events: PlayerEngineEvents = {};
  private sourceUrl = '';
  private volumeValue = 1;
  private duckedVolume: number | null = null;
  private playbackRateValue = 1;
  private durationValue = 0;
  private lastTimeValue = -1;
  private normalizationEnabled = false;
  private normalizationGain = 1.0;
  private referenceLufs = DEFAULT_REFERENCE_LUFS;
  private lastTrackLoudness: TrackLoudness | null = null;
  private cleanupFns: Array<() => void> = [];
  private sourceHash = '';
  private sourceQuality = '';
  private lastMediaStateStatus = '';
  private lastTimelineSyncMs = 0;
  private lastTimeUpdateMs = 0;
  private readonly TIME_UPDATE_THROTTLE_MS = 250;

  // Howler fallback
  private howl: Howl | null = null;
  private howlTimer: ReturnType<typeof setInterval> | null = null;
  private loopFile = false;

  // Web Audio effect engine (Howler backend only)
  private webAudioEngine: WebAudioEffectEngine | null = null;
  private lastEqualizerGains: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  private lastEffect: string = 'none';

  // Native audio listener cleanup
  private nativeListeners: Array<{ remove: () => void }> = [];

  constructor() {
    if (hasMpv) {
      this.bindMpvEvents();
    } else if (useNativeAudio) {
      this.bindNativeAudioEvents();
      logger.info('PlayerEngine', 'Using native Android audio engine');
    } else {
      this.webAudioEngine = new WebAudioEffectEngine();
      logger.info('PlayerEngine', 'Using Howler.js browser audio engine (online backend mode)');
    }
  }

  // ── Native Audio (Android) ──

  private bindNativeAudioEvents(): void {
    const events = [
      NativeAudio.addListener('timeUpdate', (data) => {
        const time = data.currentTime;
        if (time !== this.lastTimeValue) {
          this.lastTimeValue = time;
          this.events.timeUpdate?.(time);
        }
      }),
      NativeAudio.addListener('durationChange', (data) => {
        if (data.duration !== this.durationValue) {
          this.durationValue = data.duration;
          this.events.durationChange?.(data.duration);
        }
      }),
      NativeAudio.addListener('play', () => {
        this.events.play?.();
      }),
      NativeAudio.addListener('pause', () => {
        this.events.pause?.();
      }),
      NativeAudio.addListener('ended', () => {
        this.events.ended?.();
      }),
      NativeAudio.addListener('error', (data) => {
        logger.error('PlayerEngine', 'Native audio error', data);
        const evt = new Event('error');
        (evt as any).fromEngine = true;
        this.events.error?.(evt);
      }),
      NativeAudio.addListener('cacheProgress', (data: any) => {
        if (data && typeof data.percent === 'number') {
          this.events.cacheProgress?.({
            cacheKey: data.cacheKey ?? '',
            percent: data.percent,
          });
        }
      }),
    ];
    Promise.all(events).then((listeners) => {
      this.nativeListeners = listeners as Array<{ remove: () => void }>;
    });
  }

  private cleanupNativeListeners(): void {
    for (const listener of this.nativeListeners) {
      try {
        listener.remove();
      } catch {
        /* ignore */
      }
    }
    this.nativeListeners = [];
  }

  // ── Howler 辅助 ──

  private startHowlTimer(): void {
    this.stopHowlTimer();
    this.howlTimer = setInterval(() => {
      if (this.howl) {
        const time = this.howl.seek() as number;
        if (time !== this.lastTimeValue) {
          this.lastTimeValue = time;
          this.events.timeUpdate?.(time);
        }
      }
    }, 250);
  }

  private stopHowlTimer(): void {
    if (this.howlTimer) {
      clearInterval(this.howlTimer);
      this.howlTimer = null;
    }
  }

  private unloadHowl(): void {
    this.stopHowlTimer();
    if (this.webAudioEngine) {
      this.webAudioEngine.disconnect();
    }
    if (this.howl) {
      this.howl.unload();
      this.howl = null;
    }
  }

  // ── mpv 事件监听 ──

  private bindMpvEvents(): void {
    const offTime = mpv!.onTimeUpdate((time: number) => {
      if (time === this.lastTimeValue) return;
      this.lastTimeValue = time;
      const now = Date.now();
      if (now - this.lastTimeUpdateMs < this.TIME_UPDATE_THROTTLE_MS) return;
      this.lastTimeUpdateMs = now;
      this.events.timeUpdate?.(time);
    });
    this.cleanupFns.push(offTime);

    const offDuration = mpv!.onDurationChange((duration: number) => {
      if (duration === this.durationValue) return;
      this.durationValue = duration;
      this.events.durationChange?.(duration);
    });
    this.cleanupFns.push(offDuration);

    const offState = mpv!.onStateChange((state: { playing?: boolean; paused?: boolean }) => {
      if (state.playing) {
        this.events.play?.();
      } else if (state.paused) {
        this.events.pause?.();
      }
    });
    this.cleanupFns.push(offState);

    const offEnd = mpv!.onPlaybackEnd((reason: string) => {
      if (reason === 'eof') {
        this.events.ended?.();
      } else if (reason === 'error') {
        this.events.error?.(new Event('error'));
      }
    });
    this.cleanupFns.push(offEnd);

    const offError = mpv!.onError((message: string) => {
      logger.error('PlayerEngine', 'mpv error', { message });
    });
    this.cleanupFns.push(offError);
  }

  // ── 公开 API ──

  setEvents(events: PlayerEngineEvents): void {
    this.events = events;
  }

  setSource(url: string): void {
    if (!url || this.sourceUrl === url) return;
    this.sourceUrl = url;
    this.durationValue = 0;
    this.lastTimeValue = -1;
    this.events.durationChange?.(0);

    if (hasMpv) {
      if (url.startsWith('mpv-mkv://')) {
        const params = new URLSearchParams(url.slice('mpv-mkv://'.length));
        const trackId = parseInt(params.get('track') || '1', 10);
        const mkvUrl = params.get('url') || '';
        mpv!.loadMkvTrack(mkvUrl, trackId);
      } else {
        mpv!.load(url);
      }
    } else if (useNativeAudio) {
      NativeAudio.loadAudio({
        url,
        ...(this.sourceHash ? { hash: this.sourceHash } : {}),
        ...(this.sourceQuality ? { quality: this.sourceQuality } : {}),
      }).then(() => {
        if (this.lastEffect !== 'none') {
          NativeAudio.setAudioEffect({ effect: this.lastEffect }).catch(() => {});
        }
      }).catch((err) => {
        logger.error('PlayerEngine', 'Native loadAudio error', { err });
        const evt = new Event('error');
        (evt as any).fromEngine = true;
        this.events.error?.(evt);
      });
    } else {
      // Howler fallback
      this.unloadHowl();
      this.howl = new Howl({
        src: [url],
        html5: true,
        format: ['mp3'],
        volume: this.volumeValue,
        rate: this.playbackRateValue,
        loop: this.loopFile,
        onload: () => {
          this.durationValue = this.howl?.duration() ?? 0;
          this.events.durationChange?.(this.durationValue);
          // Attach Web Audio effect engine to Howl's <audio> element
          if (this.webAudioEngine && this.howl) {
            this.webAudioEngine.attachToHowl(this.howl);
            this.webAudioEngine.setEqualizer(this.lastEqualizerGains);
            if (this.lastEffect !== 'none') {
              this.webAudioEngine.setEffect(this.lastEffect);
            }
          }
        },
        onplay: () => {
          this.startHowlTimer();
          this.events.play?.();
        },
        onpause: () => {
          this.stopHowlTimer();
          this.events.pause?.();
        },
        onstop: () => {
          this.stopHowlTimer();
          this.lastTimeValue = 0;
          this.events.timeUpdate?.(0);
        },
        onend: () => {
          this.stopHowlTimer();
          this.events.ended?.();
        },
        onloaderror: (_id, err) => {
          logger.error('PlayerEngine', 'Howl load error', { err });
          const evt = new Event('error');
          (evt as any).fromEngine = true;
          this.events.error?.(evt);
        },
        onplayerror: (_id, err) => {
          logger.error('PlayerEngine', 'Howl play error', { err });
          // 重试一次，Android WebView 首次播放可能失败
          setTimeout(() => {
            if (this.howl) {
              this.howl.play();
            }
          }, 300);
        },
      });
    }
  }

  setMkvSource(url: string, audioTrackId: number): void {
    this.sourceUrl = url;
    this.durationValue = 0;
    this.lastTimeValue = -1;
    this.events.durationChange?.(0);
    if (hasMpv) {
      mpv!.loadMkvTrack(url, audioTrackId);
    }
  }

  async play(options?: {
    fadeIn?: boolean;
    fadeDurationMs?: number;
    timeoutMs?: number;
  }): Promise<void> {
    if (hasMpv) {
      const durationMs = options?.fadeIn ? (options.fadeDurationMs ?? 500) : 0;
      if (durationMs > 0) {
        await mpv!.playWithFade(this.volumeValue, durationMs);
      } else {
        await mpv!.play();
      }
    } else if (useNativeAudio) {
      await NativeAudio.play();
    } else if (this.howl) {
      if (this.webAudioEngine) await this.webAudioEngine.resume();
      this.howl.play();
    }
  }

  async pause(options?: { fadeOut?: boolean; fadeDurationMs?: number }): Promise<void> {
    if (hasMpv) {
      const durationMs = options?.fadeOut ? (options.fadeDurationMs ?? 500) : 0;
      if (durationMs > 0) {
        await mpv!.pauseWithFade(this.volumeValue, durationMs);
      } else {
        await mpv!.pause();
      }
    } else if (useNativeAudio) {
      await NativeAudio.pause();
    } else if (this.howl) {
      this.howl.pause();
      if (this.webAudioEngine) void this.webAudioEngine.suspend();
    }
  }

  seek(time: number): void {
    if (hasMpv) {
      mpv!.seek(time).catch((err: unknown) => {
        logger.warn('PlayerEngine', 'seek failed', { time, error: String(err) });
      });
    } else if (useNativeAudio) {
      NativeAudio.seek({ time }).catch((err: unknown) => {
        logger.warn('PlayerEngine', 'native seek failed', { time, error: String(err) });
      });
    } else if (this.howl) {
      this.howl.seek(time);
    }
    this.lastTimeValue = time;
    this.events.timeUpdate?.(time);
  }

  setEqualizer(gains: number[]): void {
    this.lastEqualizerGains = [...gains];
    if (hasMpv) {
      mpv!.setEqualizer(gains);
    } else if (useNativeAudio) {
      NativeAudio.setEqualizer({ gains: gains.join(',') }).catch((err) => {
        logger.warn('PlayerEngine', 'Native setEqualizer failed', { err });
      });
    } else if (this.webAudioEngine) {
      this.webAudioEngine.setEqualizer(gains);
    }
  }

  setEffect(effect: string): void {
    this.lastEffect = effect;
    if (useNativeAudio) {
      NativeAudio.setAudioEffect({ effect }).catch((err) => {
        logger.warn('PlayerEngine', 'Native setAudioEffect failed', { err });
      });
    } else if (this.webAudioEngine) {
      this.webAudioEngine.setEffect(effect);
    }
  }

  async getAudioFilter(): Promise<string> {
    if (hasMpv) {
      return (await mpv!.getAudioFilter()) || '';
    }
    return '';
  }

  setVolume(value: number): number {
    const next = clamp(value, 0, 1);
    this.volumeValue = next;
    if (hasMpv) {
      mpv!.setVolume(next);
    } else if (useNativeAudio) {
      NativeAudio.setVolume({ volume: next }).catch(() => {});
    } else if (this.webAudioEngine && this.webAudioEngine.isConnected()) {
      this.webAudioEngine.setVolume(next);
      if (this.howl) this.howl.volume(1.0);
    } else if (this.howl) {
      this.howl.volume(next);
    }
    return next;
  }

  getVolume(): number {
    return this.volumeValue;
  }

  fadeTo(value: number, durationMs = 0): Promise<void> {
    const to = clamp(value, 0, 1);
    const from = this.volumeValue;
    this.volumeValue = to;
    if (hasMpv) {
      if (durationMs <= 0) {
        mpv!.setVolume(to);
        return Promise.resolve();
      }
      return (mpv!.fade(from, to, durationMs) ?? Promise.resolve()).then(() => {
        mpv!.setVolume(this.volumeValue);
      });
    } else if (useNativeAudio) {
      NativeAudio.setVolume({ volume: to }).catch(() => {});
    } else if (this.howl) {
      this.howl.volume(to);
    }
    return Promise.resolve();
  }

  setPlaybackRate(rate: number): number {
    const next = clamp(rate, 0.1, 5);
    this.playbackRateValue = next;
    if (hasMpv) {
      mpv!.setSpeed(next);
    } else if (useNativeAudio) {
      NativeAudio.setRate({ rate: next }).catch(() => {});
    } else if (this.howl) {
      this.howl.rate(next);
    }
    return next;
  }

  async setOutputDevice(deviceId: string): Promise<boolean> {
    if (!hasMpv) return true;
    try {
      const mpvDevice = !deviceId || deviceId === 'default' ? 'auto' : deviceId;
      await mpv!.setAudioDevice(mpvDevice);
      return true;
    } catch {
      return false;
    }
  }

  setSourceMeta(hash: string, quality: string | null): void {
    this.sourceHash = hash;
    this.sourceQuality = quality ?? '';
  }

  reset(): void {
    if (hasMpv) {
      mpv!.stop();
    } else if (useNativeAudio) {
      NativeAudio.unload().catch(() => {});
    } else {
      this.unloadHowl();
    }
    this.sourceUrl = '';
    this.sourceHash = '';
    this.sourceQuality = '';
    this.durationValue = 0;
    this.lastTimeValue = -1;
    this.events.durationChange?.(0);
    this.events.timeUpdate?.(0);
  }

  setLoopFile(loop: boolean): void {
    this.loopFile = loop;
    if (hasMpv) {
      mpv!.setLoopFile(loop);
    } else if (useNativeAudio) {
      NativeAudio.setLoop({ loop }).catch(() => {});
    } else if (this.howl) {
      this.howl.loop(loop);
    }
  }

  // ── 音量均衡 ──

  setVolumeNormalization(enabled: boolean): void {
    this.normalizationEnabled = enabled;
    if (!hasMpv) return;
    if (!enabled) {
      mpv!.setNormalizationGain(0);
      this.normalizationGain = 1.0;
    } else if (this.lastTrackLoudness) {
      this.applyTrackLoudness(this.lastTrackLoudness);
    }
    logger.info('PlayerEngine', 'Volume normalization toggled', { enabled });
  }

  applyTrackLoudness(loudness: TrackLoudness | null): void {
    this.lastTrackLoudness = loudness;
    if (!hasMpv) return;
    if (!loudness || !this.normalizationEnabled) {
      this.normalizationGain = 1.0;
      mpv!.setNormalizationGain(0);
      return;
    }
    const { lufs } = loudness;
    if (!Number.isFinite(lufs)) {
      this.normalizationGain = 1.0;
      mpv!.setNormalizationGain(0);
      return;
    }
    const gainLinear = this.computeNormalizationGain(loudness);
    const gainDb = 20 * Math.log10(gainLinear);
    this.normalizationGain = gainLinear;
    mpv!.setNormalizationGain(gainDb);
    logger.info('PlayerEngine', 'Track loudness applied', {
      lufs,
      gainDb: gainDb.toFixed(2) + ' dB',
    });
  }

  setReferenceLufs(lufs: number): void {
    this.referenceLufs = clamp(lufs, -20, -8);
    if (this.normalizationEnabled && this.lastTrackLoudness) {
      this.applyTrackLoudness(this.lastTrackLoudness);
    }
  }

  private computeNormalizationGain(loudness: TrackLoudness): number {
    const { lufs, gain: suggestedGain, peak } = loudness;
    let gain = Math.pow(10, (this.referenceLufs - lufs) / 20);
    if (suggestedGain !== 0) {
      gain *= Math.pow(10, suggestedGain / 20);
    }
    if (peak > 0 && peak * gain > 0.95) {
      gain = 0.95 / peak;
    }
    return clamp(gain, 0.1, 3.0);
  }

  // ── 系统媒体控制 ──

  updateMediaMetadata(meta: MediaSessionMeta): void {
    if (hasMpv && mediaControls) {
      mediaControls.updateMetadata({
        title: meta.title,
        artist: meta.artist,
        album: meta.album ?? '',
        coverUrl: meta.artwork?.[meta.artwork.length - 1]?.src,
        durationMs: meta.durationMs || 0,
      });
    } else if (useNativeNotification) {
      NativeAudio.updateMediaMetadata({
        title: meta.title,
        artist: meta.artist,
        coverUrl: meta.artwork?.[meta.artwork.length - 1]?.src ?? '',
        durationMs: meta.durationMs || 0,
      }).catch(() => {});
    } else if ('mediaSession' in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: meta.title,
        artist: meta.artist,
        album: meta.album ?? '',
        artwork: meta.artwork ?? [],
      });
    }
  }

  updateMediaPlaybackState(state: MediaSessionState): void {
    if (hasMpv && mediaControls) {
      const newStatus = state.isPlaying ? 'Playing' : 'Paused';
      if (newStatus !== this.lastMediaStateStatus) {
        this.lastMediaStateStatus = newStatus;
        mediaControls.updateState({ status: newStatus });
      }
      if (state.duration > 0) {
        const now = Date.now();
        if (now - this.lastTimelineSyncMs >= 2000) {
          this.lastTimelineSyncMs = now;
          mediaControls.updateTimeline({
            currentTimeMs: (state.currentTime || 0) * 1000,
            totalTimeMs: (state.duration || 0) * 1000,
          });
        }
      }
    } else if (useNativeNotification) {
      NativeAudio.updatePlaybackState({
        isPlaying: state.isPlaying,
        positionMs: Math.round((state.currentTime || 0) * 1000),
        durationMs: Math.round((state.duration || 0) * 1000),
      }).catch(() => {});
    } else if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = state.isPlaying ? 'playing' : 'paused';
    }
  }

  setMediaSessionHandlers(handlers: {
    play?: () => void;
    pause?: () => void;
    previoustrack?: () => void;
    nexttrack?: () => void;
    seekto?: (time: number) => void;
    seekbackward?: (offset: number) => void;
    seekforward?: (offset: number) => void;
    playfromsearch?: (query: string) => void;
    stop?: () => void;
  }): void {
    if (hasMpv && mediaControls) {
      const offEvent = mediaControls.onEvent?.((event: { type: string; positionMs?: number }) => {
        switch (event.type) {
          case 'Play':
            handlers.play?.();
            break;
          case 'Pause':
            handlers.pause?.();
            break;
          case 'NextSong':
            handlers.nexttrack?.();
            break;
          case 'PreviousSong':
            handlers.previoustrack?.();
            break;
          case 'Seek':
            if (event.positionMs !== undefined) {
              handlers.seekto?.(event.positionMs / 1000);
            }
            break;
        }
      });
      if (offEvent) this.cleanupFns.push(offEvent);
    } else if (useNativeNotification) {
      const mediaListeners = [
        NativeAudio.addListener('mediaButtonPlay', () => handlers.play?.()),
        NativeAudio.addListener('mediaButtonPause', () => handlers.pause?.()),
        NativeAudio.addListener('mediaButtonNext', () => handlers.nexttrack?.()),
        NativeAudio.addListener('mediaButtonPrev', () => handlers.previoustrack?.()),
        NativeAudio.addListener('mediaButtonSeek', (data: any) => {
          const time = typeof data === 'number' ? data : data?.time;
          if (time != null) handlers.seekto?.(time);
        }),
        NativeAudio.addListener('mediaButtonStop', () => handlers.stop?.()),
        NativeAudio.addListener('mediaButtonPlayFromSearch', (data: any) => {
          const query = typeof data === 'string' ? data : data?.query;
          if (query) handlers.playfromsearch?.(query);
        }),
        NativeAudio.addListener('mediaButtonDuck', () => {
          // 降低音量 - 车机导航播报时
          const current = this.getVolume();
          this.duckedVolume = current;
          this.setVolume(Math.max(0.1, current * 0.3));
        }),
        NativeAudio.addListener('mediaButtonUnduck', () => {
          // 恢复音量
          if (this.duckedVolume != null) {
            this.setVolume(this.duckedVolume);
            this.duckedVolume = null;
          }
        }),
      ];
      Promise.all(mediaListeners).then((listeners) => {
        for (const l of listeners) {
          this.nativeListeners.push(l as { remove: () => void });
        }
      });
    } else if ('mediaSession' in navigator) {
      if (handlers.play) navigator.mediaSession.setActionHandler('play', handlers.play);
      if (handlers.pause) navigator.mediaSession.setActionHandler('pause', handlers.pause);
      if (handlers.previoustrack)
        navigator.mediaSession.setActionHandler('previoustrack', handlers.previoustrack);
      if (handlers.nexttrack)
        navigator.mediaSession.setActionHandler('nexttrack', handlers.nexttrack);
      if (handlers.seekto)
        navigator.mediaSession.setActionHandler('seekto', (details) => {
          if (details.seekTime !== undefined) handlers.seekto?.(details.seekTime);
        });
    }
  }

  // ── getter ──

  get volumeNormalizationEnabled(): boolean {
    return this.normalizationEnabled;
  }
  get source(): string {
    return this.sourceUrl;
  }
  get currentTime(): number {
    return this.lastTimeValue >= 0 ? this.lastTimeValue : 0;
  }
  get duration(): number {
    return this.durationValue;
  }
  get volume(): number {
    return this.volumeValue;
  }
  get playbackRate(): number {
    return this.playbackRateValue;
  }
}
