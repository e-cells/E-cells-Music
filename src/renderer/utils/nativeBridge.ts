export const isGeckoView = typeof window !== 'undefined' && !!(window as any).__GECKOVIEW__;

const _listeners: Record<string, Array<(data: any) => void>> = {};

// Ensure the bridge object exists on the window (may already be injected by Java)
if (typeof window !== 'undefined') {
  const w = window as any;
  if (!w.NativeBridge) {
    w.NativeBridge = { _listeners: {} };
  }
  Object.assign(w.NativeBridge._listeners, _listeners);
}

function nativeCall(method: string, params: Record<string, any> = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      qs.set(k, String(v));
    }
    const uri = `native://${method}?${qs.toString()}`;

    try {
      const result = window.prompt('__native__', uri);
      if (result === null) {
        reject(new Error('Native call dismissed: ' + method));
        return;
      }
      try {
        const parsed = JSON.parse(result);
        if (parsed && parsed.__nativeError) {
          reject(new Error(parsed.__nativeError));
        } else {
          resolve(parsed);
        }
      } catch {
        resolve(result);
      }
    } catch (e) {
      reject(new Error('Native call failed: ' + method));
    }
  });
}

export function addListener(eventName: string, listener: (data: any) => void): { remove: () => void } {
  if (!_listeners[eventName]) {
    _listeners[eventName] = [];
  }
  _listeners[eventName].push(listener);

  const w = window as any;
  if (w.NativeBridge && !(w.NativeBridge._listeners as any)[eventName]) {
    (w.NativeBridge._listeners as any)[eventName] = _listeners[eventName];
  } else if (w.NativeBridge) {
    (w.NativeBridge._listeners as any)[eventName] = _listeners[eventName];
  }

  let removed = false;
  return {
    remove: () => {
      if (removed) return;
      removed = true;
      const arr = _listeners[eventName];
      if (arr) {
        const idx = arr.indexOf(listener);
        if (idx >= 0) arr.splice(idx, 1);
      }
    },
  };
}

export const NativeAudioBridge = {
  loadAudio: (options: { url: string; hash?: string; quality?: string }) => nativeCall('loadAudio', options),
  play: () => nativeCall('play'),
  pause: () => nativeCall('pause'),
  stop: () => nativeCall('stop'),
  seek: (options: { time: number }) => nativeCall('seek', options),
  setVolume: (options: { volume: number }) => nativeCall('setVolume', options),
  setRate: (options: { rate: number }) => nativeCall('setRate', options),
  getDuration: () => nativeCall('getDuration'),
  getCurrentTime: () => nativeCall('getCurrentTime'),
  setLoop: (options: { loop: boolean }) => nativeCall('setLoop', options),
  unload: () => nativeCall('unload'),
  updateMediaMetadata: (options: {
    title: string;
    artist: string;
    coverUrl: string;
    durationMs: number;
  }) => nativeCall('updateMediaMetadata', options),
  updatePlaybackState: (options: { isPlaying: boolean; positionMs: number; durationMs: number }) =>
    nativeCall('updateMediaPlaybackState', options),
  getCacheInfo: () => nativeCall('getCacheInfo'),
  clearCache: () => nativeCall('clearCache'),
  setCacheSizeLimit: (options: { mb: number }) => nativeCall('setCacheSizeLimit', options),
  preloadCache: (options: { url: string; hash: string; quality: string }) =>
    nativeCall('preloadCache', options),
  addListener,
};

// Lyric bridge piggybacks on updateMediaMetadata (a verified-working channel)
// by adding __lyricAction parameter to route to lyric handlers in Java
function lyricCall(action: string, params: Record<string, any> = {}): Promise<any> {
  return nativeCall('updateMediaMetadata', { __lyricAction: action, ...params });
}

export const NativeLyricBridge = {
  checkLyricPermission: () => lyricCall('checkPermission'),
  requestOverlayPermission: () => lyricCall('requestOverlayPermission'),
  showFloatingLyric: () => lyricCall('show'),
  hideFloatingLyric: () => lyricCall('hide'),
  updateLyric: (options: { line1: string; line2: string }) => lyricCall('updateLyric', options),
  updateLyricSettings: (options: {
    lightColorIndex?: number;
    darkColorIndex?: number;
    themeMode?: string;
    colorIndex?: number;
    fontSize?: number;
    doubleLine?: boolean;
    locked?: boolean;
    widthPercent?: number;
    strokeEnabled?: boolean;
    alignment?: string;
  }) => lyricCall('updateSettings', options),
  setLyricTheme: (options: { themeMode: string }) => lyricCall('setThemeMode', options),
  getLyricSettings: () => nativeCall('getLyricSettings'),
  openExternalUrl: (url: string) => nativeCall('openExternalUrl', { url }),
  checkBatteryOptimization: () => nativeCall('checkBatteryOptimization'),
  openAppSettings: () => nativeCall('openAppSettings'),
  // Native lyric engine methods (low-frequency, architecture inversion)
  loadLyrics: (options: { lyrics: string; currentTimeMs: number; isPlaying: boolean }) =>
    nativeCall('loadLyrics', options),
  setPlaybackState: (options: { isPlaying: boolean; currentTimeMs: number }) =>
    nativeCall('setPlaybackState', options),
  seekTo: (options: { currentTimeMs: number }) => nativeCall('lyricSeekTo', options),
  addListener,
};

export const NativeOrientationBridge = {
  setOrientation: (orientation: 'auto' | 'landscape' | 'portrait') =>
    nativeCall('setOrientation', { orientation }),
  setFullScreen: (fullscreen: boolean) =>
    nativeCall('setFullScreen', { fullscreen: String(fullscreen) }),
  setKeepScreenOn: (keepOn: boolean) =>
    nativeCall('setKeepScreenOn', { keepOn: String(keepOn) }),
};
