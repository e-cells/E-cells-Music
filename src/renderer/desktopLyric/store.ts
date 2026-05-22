import { defineStore } from 'pinia';
import { useToastStore } from '../stores/toast';
import { isGeckoView, NativeLyricBridge } from '../utils/nativeBridge';
import {
  DEFAULT_DESKTOP_LYRIC_SETTINGS,
  type DesktopLyricSettings,
} from '../../shared/desktop-lyric';

const mergeSettings = (settings?: Partial<DesktopLyricSettings>): DesktopLyricSettings => ({
  ...DEFAULT_DESKTOP_LYRIC_SETTINGS,
  ...(settings ?? {}),
});

export const useDesktopLyricStore = defineStore('desktopLyric', {
  state: () => ({
    settings: { ...DEFAULT_DESKTOP_LYRIC_SETTINGS } as DesktopLyricSettings,
  }),
  actions: {
    async hydrate() {
      if (isGeckoView) return;
      if (!window.electron?.desktopLyric) return;
      const toastStore = useToastStore();
      try {
        const snapshot = await window.electron.desktopLyric.getSnapshot();
        this.settings = mergeSettings(snapshot.settings);
      } catch {
        toastStore.actionFailed('同步桌面歌词状态');
      }
    },
    async syncSettings(partial?: Partial<DesktopLyricSettings>) {
      if (isGeckoView && partial) {
        try {
          await NativeLyricBridge.updateLyricSettings({
            locked: partial.locked,
            doubleLine: partial.doubleLine,
          });
        } catch {}
        return;
      }
      if (!window.electron?.desktopLyric) return;
      const toastStore = useToastStore();
      try {
        const snapshot = await window.electron.desktopLyric.updateSettings(partial ?? {});
        this.settings = mergeSettings(snapshot.settings);
      } catch {
        toastStore.actionFailed('同步桌面歌词设置');
      }
    },
    async setEnabled(enabled: boolean) {
      this.settings = {
        ...this.settings,
        enabled,
      };
      if (isGeckoView) return;
      if (!window.electron?.desktopLyric) return;
      const toastStore = useToastStore();
      try {
        const snapshot = enabled
          ? await window.electron.desktopLyric.show()
          : await window.electron.desktopLyric.hide();
        this.settings = mergeSettings(snapshot.settings);
      } catch {
        toastStore.actionFailed(enabled ? '开启桌面歌词' : '关闭桌面歌词');
      }
    },
    setLocal(partial: Partial<DesktopLyricSettings>) {
      this.settings = {
        ...this.settings,
        ...partial,
      };
    },
  },
});
