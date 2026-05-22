<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useSettingStore } from '@/stores/setting';
import { usePlayerStore } from '@/stores/player';
import { isGeckoView } from '@/utils/nativeBridge';
import { useSwipeGesture } from '@/composables/useSwipeGesture';
import Scrollbar from '@/components/ui/Scrollbar.vue';
import PortraitTabBar from './PortraitTabBar.vue';
import PortraitMiniPlayer from './PortraitMiniPlayer.vue';
import PortraitHomeTab from './PortraitHomeTab.vue';
import PortraitPlayTab from './PortraitPlayTab.vue';
import PortraitMyTab from './PortraitMyTab.vue';

const route = useRoute();
const router = useRouter();
const settingStore = useSettingStore();
const playerStore = usePlayerStore();

const activeTab = ref(0);
const prevActiveTab = ref(0);

const keepAliveRouteNames = computed(() => {
  if (!settingStore.keepAliveEnabled) return ['personal-fm'];
  return [...new Set(['personal-fm', ...settingStore.keepAliveRoutes])];
});

const keepAliveMax = computed(() =>
  settingStore.keepAliveEnabled ? Math.max(1, Math.min(settingStore.keepAliveMax, 30)) : 1,
);

const routeViewKey = computed(() => String(route.query._t ?? route.fullPath));

const statusBarPaddingTop = computed(() => {
  if (!settingStore.showStatusBar) return '0px';
  const h = (window as any).__STATUS_BAR_HEIGHT__ || 0;
  return h ? `${h}px` : '0px';
});

const tabRootRouteNames = new Set(['home', 'explore']);

const isTabRoute = computed(() => tabRootRouteNames.has(String(route.name)));
const hasCurrentTrack = computed(() => !!playerStore.currentTrackId);

// Tab 切换时记住上一个 Tab（用于播放页退出后返回）
watch(activeTab, (val, old) => {
  if (old !== 1 && val === 1) {
    // 进入播放页
  } else if (old === 1 && val !== 1) {
    prevActiveTab.value = old;
  }
});

const handlePlayTabExit = () => {
  // 退出播放页时回到之前的 Tab
  activeTab.value = prevActiveTab.value || 0;
};

// 详情页左滑返回
const detailRef = ref<HTMLElement | null>(null);
const { bind: bindDetailSwipe, unbind: unbindDetailSwipe } = useSwipeGesture(detailRef, {
  onSwipeLeft: () => {
    if (!isTabRoute.value) router.back();
  },
  threshold: 80,
});

watch(isTabRoute, (isTab) => {
  if (!isTab) {
    // 进入详情页，绑定手势
    setTimeout(() => bindDetailSwipe(), 50);
  } else {
    unbindDetailSwipe();
  }
});

// 启动时应用方向设置
if (isGeckoView && settingStore.screenOrientation !== 'auto') {
  void import('@/utils/nativeBridge').then((m) =>
    m.NativeOrientationBridge.setOrientation(settingStore.screenOrientation),
  );
}

// ── 导航：从详情页返回 Tab 页 ──

const handleMiniPlayerClick = () => {
  if (!isTabRoute.value) {
    router.push({ name: 'home' }).then(() => {
      activeTab.value = 1;
    });
  } else {
    activeTab.value = 1;
  }
};

const handleTabClick = (tab: number) => {
  if (!isTabRoute.value) {
    router.push({ name: 'home' }).then(() => {
      activeTab.value = tab;
    });
  } else {
    activeTab.value = tab;
  }
};
</script>

<template>
  <div
    class="portrait-layout h-screen w-screen flex flex-col overflow-hidden bg-bg-main text-text-main"
  >
    <!-- 内容区域 -->
    <div class="flex-1 min-h-0 overflow-hidden" :style="{ paddingTop: statusBarPaddingTop }">
      <!-- Tab 根路由 -->
      <template v-if="isTabRoute">
        <div v-show="activeTab === 0" class="h-full">
          <PortraitHomeTab />
        </div>
        <div v-show="activeTab === 1" class="h-full">
          <PortraitPlayTab :active="activeTab === 1" @exit="handlePlayTabExit" />
        </div>
        <div v-show="activeTab === 2" class="h-full">
          <PortraitMyTab />
        </div>
      </template>

      <!-- 详情页子路由 -->
      <template v-else>
        <div ref="detailRef" class="h-full flex flex-col">
          <!-- 详情页导航栏 -->
          <div class="detail-nav-bar shrink-0 pt-[6px]">
            <button type="button" class="nav-back" @click="router.back()">
              <span class="nav-back-arrow">‹</span>
            </button>
            <span class="nav-title">{{ (route.meta.title as string) || '' }}</span>
            <span class="nav-placeholder"></span>
          </div>
          <Scrollbar class="flex-1 min-h-0" :content-props="{ class: 'view-port' }">
            <router-view v-slot="{ Component }">
              <KeepAlive :include="keepAliveRouteNames" :max="keepAliveMax">
                <component :is="Component" :key="routeViewKey" />
              </KeepAlive>
            </router-view>
          </Scrollbar>
        </div>
      </template>
    </div>

    <!-- 迷你播放条 -->
    <PortraitMiniPlayer v-if="activeTab !== 1 && hasCurrentTrack" @click="handleMiniPlayerClick" />

    <!-- 底部 Tab 栏 -->
    <PortraitTabBar :model-value="activeTab" @update:model-value="handleTabClick" />
  </div>
</template>

<style scoped>
@reference "@/style.css";

.portrait-layout {
  user-select: none;
  -webkit-user-select: none;
}

/* ── 详情页导航栏 ── */
.detail-nav-bar {
  display: flex;
  align-items: center;
  height: 44px;
  padding: 0 8px;
  background: var(--color-bg-main);
  border-bottom: 1px solid color-mix(in srgb, var(--color-border-light) 30%, transparent);
}

.nav-back {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 10px;
  background: transparent;
  color: var(--color-text-main);
  -webkit-tap-highlight-color: transparent;
}

.nav-back:active {
  background: color-mix(in srgb, var(--color-text-main) 8%, transparent);
}

.nav-back-arrow {
  font-size: 22px;
  font-weight: 300;
  line-height: 1;
}

.nav-title {
  flex: 1;
  text-align: center;
  font-size: 15px;
  font-weight: 600;
  color: var(--color-text-main);
}

.nav-placeholder {
  width: 36px;
}
</style>
