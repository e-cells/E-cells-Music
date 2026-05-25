import { watch, type WatchStopHandle } from 'vue';
import { storeToRefs } from 'pinia';
import { usePlayerStore } from '@/stores/player';
import { useLyricStore } from '@/stores/lyric';
import { useSettingStore } from '@/stores/setting';
import { useDesktopLyricStore } from './store';
import { NativeLyricBridge } from '../utils/nativeBridge';

const ANDROID_LYRIC_STORE_PREFIX = 'android_lyric_';

const getAndroidSetting = (key: string, fallback: string): string => {
  try {
    return localStorage.getItem(ANDROID_LYRIC_STORE_PREFIX + key) ?? fallback;
  } catch {
    return fallback;
  }
};

const readAndroidLyricSettings = () => {
  try {
    return {
      fontSize: Number(getAndroidSetting('fontSize', '18')),
      lightColorIndex: Number(getAndroidSetting('lightColorIndex', '0')),
      darkColorIndex: Number(getAndroidSetting('darkColorIndex', '0')),
      colorIndex: Number(getAndroidSetting('colorIndex', '3')),
      doubleLine: getAndroidSetting('doubleLine', 'true') === 'true',
      widthPercent: Number(getAndroidSetting('widthPercent', '100')),
      strokeEnabled: getAndroidSetting('strokeEnabled', 'false') === 'true',
      alignment: getAndroidSetting('alignment', 'center'),
      locked: getAndroidSetting('locked', 'false') === 'true',
    };
  } catch {
    return {
      fontSize: 18,
      lightColorIndex: 0,
      darkColorIndex: 0,
      colorIndex: 3,
      doubleLine: true,
      widthPercent: 100,
      strokeEnabled: false,
      alignment: 'center',
      locked: false,
    };
  }
};

export const initAndroidLyricSync = async () => {
  const desktopLyricStore = useDesktopLyricStore();
  const playerStore = usePlayerStore();
  const lyricStore = useLyricStore();
  const settingStore = useSettingStore();

  const stops: WatchStopHandle[] = [];
  const { currentTime, isPlaying, currentTrackId, seekTimestamp } = storeToRefs(playerStore);
  const { lines, currentIndex } = storeToRefs(lyricStore);

  let waitingForOverlayPermission = false;
  let lastSyncedTrackId = '';
  let lastSyncedLinesHash = '';

  const sendLyricsToNative = () => {
    if (!desktopLyricStore.settings.enabled) return;
    if (lines.value.length === 0) return;

    const lyricData = lines.value.map((l) => ({
      timeMs: Math.round(l.time * 1000),
      text: l.text,
      translation: l.translated || '',
    }));

    NativeLyricBridge.loadLyrics({
      lyrics: JSON.stringify(lyricData),
      currentTimeMs: Math.round(currentTime.value * 1000),
      isPlaying: isPlaying.value,
    }).catch(() => {});
  };

  const syncSettings = () => {
    const androidSettings = readAndroidLyricSettings();
    NativeLyricBridge.updateLyricSettings({
      doubleLine: androidSettings.doubleLine,
      fontSize: androidSettings.fontSize,
      lightColorIndex: androidSettings.lightColorIndex,
      darkColorIndex: androidSettings.darkColorIndex,
      colorIndex: androidSettings.colorIndex,
      widthPercent: androidSettings.widthPercent,
      strokeEnabled: androidSettings.strokeEnabled,
      alignment: androidSettings.alignment,
      locked: androidSettings.locked,
    }).catch(() => {});
  };

  const showLyricIfReady = async () => {
    try {
      const permResult = await NativeLyricBridge.checkLyricPermission();
      if (permResult.overlayGranted) {
        await NativeLyricBridge.showFloatingLyric();
        syncSettings();
        sendLyricsToNative();
      } else {
        desktopLyricStore.settings.enabled = false;
      }
    } catch {
      desktopLyricStore.settings.enabled = false;
    }
  };

  // Handle enable/disable
  const handleToggle = async () => {
    if (!desktopLyricStore.settings.enabled) {
      await NativeLyricBridge.hideFloatingLyric().catch(() => {});
      return;
    }

    try {
      const permResult = await NativeLyricBridge.checkLyricPermission();
      if (!permResult.overlayGranted) {
        waitingForOverlayPermission = true;
        await NativeLyricBridge.requestOverlayPermission();
        return;
      }
      await showLyricIfReady();
    } catch {
      desktopLyricStore.settings.enabled = false;
    }
  };

  // Listen for activity resume events from native side
  const resumeListener = NativeLyricBridge.addListener('onActivityResume', () => {
    if (waitingForOverlayPermission && desktopLyricStore.settings.enabled) {
      waitingForOverlayPermission = false;
      void showLyricIfReady();
    }
  });

  // Poll native lock state every 2s (overlay lock icon changes aren't reliably pushed via events)
  const lockPollTimer = window.setInterval(async () => {
    if (!desktopLyricStore.settings.enabled) return;
    try {
      const ns = (await NativeLyricBridge.getLyricSettings()) as any;
      if (ns && typeof ns.locked === 'boolean') {
        if (desktopLyricStore.settings.locked !== ns.locked) {
          desktopLyricStore.settings.locked = ns.locked;
        }
      }
    } catch {}
  }, 2000);

  // Toggle on/off
  stops.push(
    watch(
      [() => desktopLyricStore.settings.enabled],
      () => {
        void handleToggle();
      },
      { immediate: true },
    ),
  );

  // Song change → immediately clear old lyrics on native side
  stops.push(
    watch([currentTrackId], ([newTrackId], [oldTrackId]) => {
      if (!desktopLyricStore.settings.enabled) return;
      if (newTrackId === oldTrackId) return;
      lastSyncedTrackId = '';
      lastSyncedLinesHash = '';
      NativeLyricBridge.loadLyrics({
        lyrics: '[]',
        currentTimeMs: 0,
        isPlaying: false,
      }).catch(() => {});
    }),
  );

  // Lyrics loaded → send full lyrics to native
  stops.push(
    watch(
      [lines],
      () => {
        if (!desktopLyricStore.settings.enabled) return;
        if (lines.value.length === 0) return;
        const linesHash = lines.value
          .slice(0, 3)
          .map((l) => l.text)
          .join('|');
        const trackKey = currentTrackId.value + '|' + lines.value.length + '|' + linesHash;
        if (trackKey === lastSyncedTrackId) return;
        lastSyncedTrackId = trackKey;
        lastSyncedLinesHash = linesHash;
        sendLyricsToNative();
      },
      { deep: true, immediate: true },
    ),
  );

  // Play/pause → sync state
  stops.push(
    watch([isPlaying], () => {
      if (!desktopLyricStore.settings.enabled) return;
      NativeLyricBridge.setPlaybackState({
        isPlaying: isPlaying.value,
        currentTimeMs: Math.round(currentTime.value * 1000),
      }).catch(() => {});
    }),
  );

  // Seek → sync native lyric engine position
  stops.push(
    watch([seekTimestamp], () => {
      if (!desktopLyricStore.settings.enabled) return;
      NativeLyricBridge.seekTo({
        currentTimeMs: Math.round(currentTime.value * 1000),
      }).catch(() => {});
    }),
  );

  const enableListener = watch([() => desktopLyricStore.settings.enabled], (newVal) => {
    if (newVal[0] && lines.value.length > 0) {
      const linesHash = lines.value
        .slice(0, 3)
        .map((l) => l.text)
        .join('|');
      const trackKey = currentTrackId.value + '|' + lines.value.length + '|' + linesHash;
      if (trackKey !== lastSyncedTrackId) {
        lastSyncedTrackId = trackKey;
        lastSyncedLinesHash = linesHash;
        sendLyricsToNative();
      }
    }
  });
  stops.push(enableListener);

  // Auto-restore desktop lyric if it was enabled before app closed
  const savedEnabled = getAndroidSetting('enabled', 'false');
  if (savedEnabled === 'true') {
    desktopLyricStore.setEnabled(true);
  }

  // 监听主题切换，自动同步歌词颜色主题
  const syncLyricTheme = () => {
    if (!desktopLyricStore.settings.enabled) return;
    if (settingStore.theme === 'system') {
      NativeLyricBridge.setLyricTheme({ themeMode: 'system' }).catch(() => {});
    } else {
      const isDark = document.documentElement.classList.contains('dark');
      NativeLyricBridge.setLyricTheme({ themeMode: isDark ? 'dark' : 'light' }).catch(() => {});
    }
  };
  const darkObserver = new MutationObserver(syncLyricTheme);
  darkObserver.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['class'],
  });

  // 初始同步一次主题
  syncLyricTheme();

  return () => {
    resumeListener.remove();
    clearInterval(lockPollTimer);
    darkObserver.disconnect();
    stops.forEach((stop) => stop());
  };
};
