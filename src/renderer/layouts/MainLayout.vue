<script setup lang="ts">
import { computed, ref, nextTick, watch, onMounted, onUnmounted } from 'vue';
import { useRoute } from 'vue-router';
import { useSettingStore } from '@/stores/setting';
import { isGeckoView } from '@/utils/nativeBridge';
import Sidebar from './Sidebar.vue';
import TitleBar from './TitleBar.vue';
import PlayerBar from './PlayerBar.vue';
import PortraitLayout from './portrait/PortraitLayout.vue';
import BackToTop from '@/components/ui/BackToTop.vue';
import Scrollbar from '@/components/ui/Scrollbar.vue';

const route = useRoute();
const settingStore = useSettingStore();
const scrollbarRef = ref<InstanceType<typeof Scrollbar> | null>(null);
const routeViewKey = computed(() => String(route.query._t ?? route.fullPath));

const windowWidth = ref(window.innerWidth);
const windowHeight = ref(window.innerHeight);

function onWindowResize() {
  windowWidth.value = window.innerWidth;
  windowHeight.value = window.innerHeight;
}

if (isGeckoView) {
  onMounted(() => window.addEventListener('resize', onWindowResize));
  onUnmounted(() => window.removeEventListener('resize', onWindowResize));
}

const isPortrait = computed(() => {
  if (!isGeckoView) return false;
  if (settingStore.screenOrientation === 'portrait') return true;
  if (settingStore.screenOrientation === 'landscape') return false;
  return windowWidth.value < windowHeight.value;
});

// 横屏布局顶部安全区域（状态栏高度）
const statusBarPaddingTop = computed(() => {
  const h = (window as any).__STATUS_BAR_HEIGHT__ || 0;
  return h ? `${h}px` : '0px';
});

// 始终 keepAlive 的路由
const alwaysKeepAlive = ['personal-fm'];

// 根据设置动态计算 keepAlive 列表
const keepAliveRouteNames = computed(() => {
  if (!settingStore.keepAliveEnabled) return alwaysKeepAlive;
  return [...new Set([...alwaysKeepAlive, ...settingStore.keepAliveRoutes])];
});

const keepAliveMax = computed(() =>
  settingStore.keepAliveEnabled
    ? Math.max(alwaysKeepAlive.length, Math.min(settingStore.keepAliveMax, 30))
    : alwaysKeepAlive.length,
);

// ── 滚动位置：每次路由变化归零 ──
watch(
  () => route.fullPath,
  () => {
    nextTick(() => {
      scrollbarRef.value?.setScrollTop(0);
    });
  },
);
</script>

<template>
  <PortraitLayout v-if="isPortrait" />

  <div
    v-else
    class="main-layout h-screen w-screen flex overflow-hidden bg-bg-main text-text-main transition-colors duration-300"
    :style="{ paddingTop: statusBarPaddingTop }"
  >
    <Sidebar 
      class="shrink-0 transition-all duration-300 ease-in-out" 
      style="width: calc(clamp(180px, 15vw, 210px) + env(safe-area-inset-left));"
    />

    <div 
      class="flex-1 flex flex-col min-w-0 min-h-0 relative"
      style="padding-right: env(safe-area-inset-right);"
    >
      <main class="main-content flex-1 flex flex-col min-w-0 min-h-0 overflow-hidden w-full box-border">
        <TitleBar />
        <Scrollbar
          ref="scrollbarRef"
          class="view-port-scroll flex-1 min-h-0 min-w-0 w-full"
          :content-props="{ class: 'view-port w-full min-w-0 box-border' }"
        >
          <div class="w-full min-w-0 overflow-x-hidden">
            <router-view v-slot="{ Component }">
              <KeepAlive :include="keepAliveRouteNames" :max="keepAliveMax">
                <component :is="Component" :key="routeViewKey" />
              </KeepAlive>
            </router-view>
          </div>
        </Scrollbar>
      </main>

      <PlayerBar />
      <BackToTop target-selector=".view-port" />
    </div>
  </div>
</template>

<style scoped>
.main-layout {
  user-select: none;
}
</style>
