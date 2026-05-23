import { isGeckoView, NativeAudioBridge } from './nativeBridge';

export interface NativeAudioPlugin {
  loadAudio(options: { url: string; hash?: string; quality?: string }): Promise<{ loaded: boolean }>;
  play(): Promise<void>;
  pause(): Promise<void>;
  stop(): Promise<void>;
  seek(options: { time: number }): Promise<void>;
  setVolume(options: { volume: number }): Promise<void>;
  setRate(options: { rate: number }): Promise<void>;
  getDuration(): Promise<{ duration: number }>;
  getCurrentTime(): Promise<{ currentTime: number }>;
  setLoop(options: { loop: boolean }): Promise<void>;
  unload(): Promise<void>;

  updateMediaMetadata(options: {
    title: string;
    artist: string;
    coverUrl: string;
    durationMs: number;
  }): Promise<void>;

  updatePlaybackState(options: {
    isPlaying: boolean;
    positionMs: number;
    durationMs: number;
  }): Promise<void>;

  addListener(
    eventName: 'timeUpdate',
    listenerFunc: (data: { currentTime: number }) => void,
  ): Promise<any>;
  addListener(
    eventName: 'durationChange',
    listenerFunc: (data: { duration: number }) => void,
  ): Promise<any>;
  addListener(eventName: 'play', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'pause', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'ended', listenerFunc: () => void): Promise<any>;
  addListener(
    eventName: 'error',
    listenerFunc: (data: { what: number; extra: number }) => void,
  ): Promise<any>;
  addListener(eventName: 'mediaButtonPlay', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'mediaButtonPause', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'mediaButtonNext', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'mediaButtonPrev', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'mediaButtonSeek', listenerFunc: (data: any) => void): Promise<any>;
  addListener(eventName: 'mediaButtonStop', listenerFunc: () => void): Promise<any>;
  addListener(
    eventName: 'mediaButtonPlayFromSearch',
    listenerFunc: (data: any) => void,
  ): Promise<any>;
  addListener(eventName: 'mediaButtonDuck', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'mediaButtonUnduck', listenerFunc: () => void): Promise<any>;
  addListener(eventName: 'cacheProgress', listenerFunc: (data: { cacheKey: string; percent: number }) => void): Promise<any>;

  getCacheInfo(): Promise<{ sizeBytes: number; fileCount: number; maxSizeBytes: number }>;
  clearCache(): Promise<void>;
  setCacheSizeLimit(options: { mb: number }): Promise<void>;
}

const NativeAudio: NativeAudioPlugin = isGeckoView
  ? {
      loadAudio: (opts) => NativeAudioBridge.loadAudio(opts),
      play: () => NativeAudioBridge.play(),
      pause: () => NativeAudioBridge.pause(),
      stop: () => NativeAudioBridge.stop(),
      seek: (opts) => NativeAudioBridge.seek(opts),
      setVolume: (opts) => NativeAudioBridge.setVolume(opts),
      setRate: (opts) => NativeAudioBridge.setRate(opts),
      getDuration: () => NativeAudioBridge.getDuration(),
      getCurrentTime: () => NativeAudioBridge.getCurrentTime(),
      setLoop: (opts) => NativeAudioBridge.setLoop(opts),
      unload: () => NativeAudioBridge.unload(),
      updateMediaMetadata: (opts) => NativeAudioBridge.updateMediaMetadata(opts).then(() => {}),
      updatePlaybackState: (opts) => NativeAudioBridge.updatePlaybackState(opts).then(() => {}),
      addListener: (eventName: string, listenerFunc: Function) => {
        return Promise.resolve(NativeAudioBridge.addListener(eventName, listenerFunc as any));
      },
      getCacheInfo: () => NativeAudioBridge.getCacheInfo(),
      clearCache: () => NativeAudioBridge.clearCache().then(() => {}),
      setCacheSizeLimit: (opts) => NativeAudioBridge.setCacheSizeLimit(opts).then(() => {}),
    }
  : {
      // Fallback stubs when not in GeckoView (shouldn't be used)
      loadAudio: () => Promise.resolve({ loaded: false }),
      play: () => Promise.resolve(),
      pause: () => Promise.resolve(),
      stop: () => Promise.resolve(),
      seek: () => Promise.resolve(),
      setVolume: () => Promise.resolve(),
      setRate: () => Promise.resolve(),
      getDuration: () => Promise.resolve({ duration: 0 }),
      getCurrentTime: () => Promise.resolve({ currentTime: 0 }),
      setLoop: () => Promise.resolve(),
      unload: () => Promise.resolve(),
      updateMediaMetadata: () => Promise.resolve(),
      updatePlaybackState: () => Promise.resolve(),
      addListener: () => Promise.resolve({ remove: () => {} }),
      getCacheInfo: () => Promise.resolve({ sizeBytes: 0, fileCount: 0, maxSizeBytes: 0 }),
      clearCache: () => Promise.resolve(),
      setCacheSizeLimit: () => Promise.resolve(),
    };

export default NativeAudio;
