<script setup lang="ts">
import { onMounted, onUnmounted, watch } from 'vue';
import { RouterView } from 'vue-router';
import AuthExpiredDialog from '@/components/app/AuthExpiredDialog.vue';
import ToastViewport from '@/components/app/ToastViewport.vue';
import { usePlayerStore } from './stores/player';
import { useSettingStore } from './stores/setting';
import { useThemeStore } from './stores/theme';
import { getCoverUrl } from '@/utils/cover';
import { addListener, isGeckoView } from '@/utils/nativeBridge';
import { initDesktopLyricSync } from '@/desktopLyric/sync';
import LyricView from '@/views/Lyric.vue';


const player = usePlayerStore();
const settings = useSettingStore();
const themeStore = useThemeStore();
let colorSchemeMediaQuery: MediaQueryList | null = null;
let systemThemeListener: { remove: () => void } | null = null;
const updateTheme = () => {
  const isDark =
    settings.theme === 'dark' ||
    ((settings.theme === 'system' || settings.theme === 'sensor') &&
      window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', isDark);
  themeStore.onThemeChange();
};

const applyGlobalFont = () => {
  document.documentElement.style.fontFamily = settings.buildGlobalFontFamily();
};

onMounted(() => {
  // 一次性数据迁移：将 theme store 的 autoMode='sensor' 迁移到 setting store 的 theme='sensor'
  if (isGeckoView) {
    try {
      const themeStoreData = JSON.parse(localStorage.getItem('theme') || '{}');
      if (themeStoreData.autoMode === 'sensor') {
        const settingStoreData = JSON.parse(localStorage.getItem('setting') || '{}');
        if (settingStoreData.theme === 'system') {
          settingStoreData.theme = 'sensor';
          localStorage.setItem('setting', JSON.stringify(settingStoreData));
          settings.theme = 'sensor' as any;
        }
        delete themeStoreData.autoMode;
        localStorage.setItem('theme', JSON.stringify(themeStoreData));
      }
    } catch {}
  }

  player.init();
  void initDesktopLyricSync();
  updateTheme();
  applyGlobalFont();
  themeStore.applyCurrent();
  if (settings.autoCheckUpdate) {
    settings.checkForUpdates(true);
  }
  colorSchemeMediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
  colorSchemeMediaQuery.addEventListener('change', updateTheme);

  if (isGeckoView) {
    systemThemeListener = addListener('onSystemThemeChanged', (isDark: boolean) => {
      if (settings.theme !== 'system' && settings.theme !== 'sensor') return;
      document.documentElement.classList.toggle('dark', isDark);
      themeStore.onThemeChange();
    });
  }

  // 同步系统状态栏设置到 Android
  watch(
    () => settings.showStatusBar,
    (show) => {
      void import('@/utils/nativeBridge').then((m) => {
        if (m.isGeckoView) {
          m.NativeOrientationBridge.setFullScreen(!show).catch(() => {});
        }
      });
    },
    { immediate: true },
  );

  // Media button listeners are handled by PlayerEngine.setMediaSessionHandlers()
  // (state-aware handlers with proper play/pause guard)
});

onUnmounted(() => {
  colorSchemeMediaQuery?.removeEventListener('change', updateTheme);
  colorSchemeMediaQuery = null;
  systemThemeListener?.remove();
  systemThemeListener = null;
  document.removeEventListener('visibilitychange', handleVisibilityChange);
});

watch(() => settings.theme, updateTheme);
watch(() => settings.globalFont, applyGlobalFont);

// 切歌时，cover 模式下自动提取封面主色
watch(
  () => player.currentTrackSnapshot?.coverUrl,
  (coverUrl) => {
    if (!coverUrl) return;
    if (themeStore.accentMode !== 'cover') return;
    void themeStore.refreshFromCover(getCoverUrl(coverUrl, 300));
  },
  { immediate: true },
);

// 切换到 cover 模式时，立即用当前封面重新提取主色
watch(
  () => themeStore.accentMode,
  (mode) => {
    if (mode !== 'cover') return;
    const coverUrl = player.currentTrackSnapshot?.coverUrl;
    if (!coverUrl) return;
    void themeStore.refreshFromCover(getCoverUrl(coverUrl, 300));
  },
);

// 后台时暂停所有 CSS 动画，节省 GPU/CPU
const handleVisibilityChange = () => {
  document.documentElement.classList.toggle('document-hidden', document.hidden);
};
document.addEventListener('visibilitychange', handleVisibilityChange);
</script>

<template>
  <RouterView v-slot="{ Component }">
    <transition name="page" mode="out-in">
      <component :is="Component" />
    </transition>
  </RouterView>
  <Teleport to="body">
    <Transition name="lyric-overlay">
      <LyricView v-if="player.isLyricViewOpen" />
    </Transition>
  </Teleport>
  <AuthExpiredDialog />
  <ToastViewport />
</template>

<style>
.page-enter-active,
.page-leave-active {
  transition: all 0.3s ease-out;
}

.page-enter-from {
  opacity: 0;
  transform: translateY(8px);
}

.page-leave-to {
  opacity: 0;
  transform: translateY(-8px);
}

/* 歌词覆盖层动画 */
.lyric-overlay-enter-active {
  transition:
    transform 0.35s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.25s cubic-bezier(0.16, 1, 0.3, 1);
}

.lyric-overlay-leave-active {
  transition:
    transform 0.3s cubic-bezier(0.4, 0, 0.6, 1),
    opacity 0.2s cubic-bezier(0.4, 0, 1, 1);
}

.lyric-overlay-enter-from {
  opacity: 0;
  transform: translateY(100%);
}

.lyric-overlay-leave-to {
  opacity: 0;
  transform: translateY(100%);
}
</style>