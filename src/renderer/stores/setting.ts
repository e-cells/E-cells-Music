import { defineStore } from 'pinia';
import type { CloseBehavior, ThemeMode } from '../../shared/app';
import type {
  AudioQualityValue,
  OutputDeviceDisconnectBehavior,
  OutputDeviceOption,
  OutputDeviceStatus,
} from '../types';
import { buildFontFamily } from '../../shared/font';
import { isGeckoView } from '@/utils/nativeBridge';

export type ScreenOrientation = 'auto' | 'landscape' | 'portrait';
export type PortraitCoverStyle = 'square' | 'disc' | 'breathing';

export const DEFAULT_SHORTCUT_LABELS: Record<string, string> = {
  togglePlayback: '⌘Space',
  previousTrack: '⌘←',
  nextTrack: '⌘→',
  toggleMainLyric: '⌘K',
  toggleDesktopLyric: '⌘D',
  volumeUp: '⌘↑',
  volumeDown: '⌘↓',
  toggleMute: '⌘M',
  toggleFavorite: '⌘L',
  togglePlayMode: '⌘P',
  toggleWindow: '⌘W',
};

export const DEFAULT_GLOBAL_SHORTCUT_LABELS: Record<string, string> = {
  togglePlayback: '⌘⇧Space',
  previousTrack: '⌘⇧←',
  nextTrack: '⌘⇧→',
  toggleMainLyric: '⌘⇧K',
  toggleDesktopLyric: '⌘⇧D',
  volumeUp: '⌘⇧↑',
  volumeDown: '⌘⇧↓',
  toggleMute: '⌘⇧M',
  toggleFavorite: '⌘⇧L',
  togglePlayMode: '⌘⇧P',
  toggleWindow: '⌥⌘S',
};

export const useSettingStore = defineStore('setting', {
  state: () => ({
    theme: 'system' as ThemeMode,
    language: 'zh-CN',
    shortcutEnabled: true,
    rememberWindowSize: true,
    showPlaylistCount: true,
    closeBehavior: 'tray' as CloseBehavior,
    replacePlaylist: false,
    volumeFade: true,
    volumeFadeTime: 1000,
    lyricArtistBackdrop: true,
    lyricBackdropOpacity: 50,
    lyricCarouselEnabled: true,
    lyricCarouselInterval: 15,
    lyricAutoCollapseDelay: 5,
    lyricAutoCollapseEnabled: true,
    lyricAdaptiveColor: true,
    autoNextDelaySeconds: 3,
    autoNextMaxAttempts: 10,
    preventSleep: true,
    defaultAudioQuality: 'high' as AudioQualityValue,
    compatibilityMode: true,
    globalShortcutsEnabled: false,
    shortcutBindings: {} as Record<string, string>,
    globalShortcutBindings: {} as Record<string, string>,
    defaultShortcutLabels: { ...DEFAULT_SHORTCUT_LABELS } as Record<string, string>,
    defaultGlobalShortcutLabels: { ...DEFAULT_GLOBAL_SHORTCUT_LABELS } as Record<string, string>,
    outputDevice: 'default',
    outputDevices: [{ label: '系统默认', value: 'default' }] as OutputDeviceOption[],
    outputDeviceType: 'default' as 'default' | 'wasapi',
    exclusiveAudioDevice: false,
    outputDeviceStatus: 'idle' as OutputDeviceStatus,
    outputDeviceStatusMessage: '',
    outputDeviceDisconnectBehavior: 'pause' as OutputDeviceDisconnectBehavior,
    autoReceiveVip: false,
    showAudioQualityBadge: true,
    volumeNormalization: true,
    volumeNormalizationLufs: -14,
    keepAliveEnabled: true,
    keepAliveMax: 20,
    keepAliveRoutes: ['playlist-detail', 'artist-detail', 'album-detail', 'favorites'] as string[],
    playResumeTimeout: 5,
    autoPlayOnStart: false,
    silentUpdate: true,
    autoCheckUpdate: true,
    checkPrerelease: false,
    appVersion: '',
    isPrerelease: false,
    searchHistory: [] as string[],
    userAgreementAccepted: false,
    disableGpuAcceleration: false,
    // 字体设置
    globalFont: 'system-ui',
    lyricFont: 'follow',
    // 远端服务
    apiBaseUrl: '',
    // 屏幕方向（仅 Android）
    screenOrientation: 'auto' as ScreenOrientation,
    // 显示系统状态栏
    showStatusBar: true,
    // 竖屏播放封面样式
    portraitCoverStyle: 'disc' as PortraitCoverStyle,
    // 缓存设置（Android）
    cacheSizeLimitMb: 500,
  }),
  actions: {
    setTheme(theme: ThemeMode) {
      this.theme = theme;
      this.syncTheme();
      if (isGeckoView && window.prompt && (theme === 'system' || theme === 'sensor')) {
        try {
          const nativeMode = theme === 'sensor' ? 'sensor' : 'system';
          window.prompt('__native__', `native://setThemeAutoMode?mode=${nativeMode}`);
        } catch(e) {
          console.warn('通知安卓端切换主题模式失败', e);
        }
      }
    },
    setScreenOrientation(orientation: ScreenOrientation) {
      this.screenOrientation = orientation;
      if (isGeckoView) {
        void import('@/utils/nativeBridge').then((m) =>
          m.NativeOrientationBridge.setOrientation(orientation),
        );
      }
    },
    setShowStatusBar(show: boolean) {
      this.showStatusBar = show;
      if (isGeckoView) {
        void import('@/utils/nativeBridge').then((m) =>
          m.NativeOrientationBridge.setFullScreen(!show),
        );
      }
    },
    setPortraitCoverStyle(style: PortraitCoverStyle) {
      this.portraitCoverStyle = style;
    },
    toggleShortcuts(enabled: boolean) {
      this.shortcutEnabled = enabled;
    },
    resetShortcutDefaults() {
      this.defaultShortcutLabels = { ...DEFAULT_SHORTCUT_LABELS };
      this.defaultGlobalShortcutLabels = { ...DEFAULT_GLOBAL_SHORTCUT_LABELS };
    },
    openLogDirectory() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('open-log-directory', null);
      }
    },
    clearAppData() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('clear-app-data', null);
      }
      localStorage.clear();
      sessionStorage.clear();
      this.$reset();
      window.setTimeout(() => {
        window.location.reload();
      }, 80);
    },
    checkForUpdates(silent = false) {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('check-for-updates', {
          prerelease: this.checkPrerelease,
          silent,
        });
      }
    },
    async hydrateAppInfo() {
      if (!window.electron?.appInfo) return;
      try {
        const appInfo = await window.electron.appInfo.get();
        this.appVersion = String(appInfo.version || '').trim();
        this.isPrerelease = Boolean(appInfo.isPrerelease);
      } catch {
        // ignore hydration failure and keep current value
      }
    },
    openRepo() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('open-external', 'https://github.com/hoowhoami/EchoMusic');
      }
    },
    openDisclaimer() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('open-disclaimer', null);
      }
    },
    syncCloseBehavior() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('update-close-behavior', this.closeBehavior);
      }
    },
    syncTheme() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('update-theme', this.theme);
      }
    },
    syncRememberWindowSize() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('update-remember-window-size', this.rememberWindowSize);
      }
    },
    syncPreventSleep(isPlaying = false) {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send('update-power-save-blocker', {
          enabled: this.preventSleep,
          isPlaying,
        });
      }
    },
    syncDisableGpuAcceleration() {
      if (window.electron?.ipcRenderer) {
        window.electron.ipcRenderer.send(
          'update-disable-gpu-acceleration',
          this.disableGpuAcceleration,
        );
      }
    },
    setOutputDeviceStatus(status: OutputDeviceStatus, message = '') {
      this.outputDeviceStatus = status;
      this.outputDeviceStatusMessage = message;
    },
    addToSearchHistory(keyword: string) {
      const normalized = keyword.trim();
      if (!normalized) return;
      this.searchHistory = [
        normalized,
        ...this.searchHistory.filter((item) => item !== normalized),
      ].slice(0, 20);
    },
    removeFromSearchHistory(keyword: string) {
      this.searchHistory = this.searchHistory.filter((item) => item !== keyword);
    },
    clearSearchHistory() {
      this.searchHistory = [];
    },
    acceptUserAgreement() {
      this.userAgreementAccepted = true;
    },
    // 获取系统字体列表
    async fetchSystemFonts(): Promise<string[]> {
      if (!window.electron?.fonts) return [];
      try {
        const fonts = await window.electron.fonts.getAll();
        return (fonts ?? []).map((f: string) => f.replace(/^['"]+|['"]+$/g, ''));
      } catch {
        return [];
      }
    },
    // 构建全局 font-family 字符串
    buildGlobalFontFamily(): string {
      return buildFontFamily(this.globalFont);
    },
    // 构建歌词区域 font-family 字符串
    buildLyricFontFamily(): string {
      if (!this.lyricFont || this.lyricFont === 'follow') return this.buildGlobalFontFamily();
      return buildFontFamily(this.lyricFont);
    },
  },
  persist: true,
});
