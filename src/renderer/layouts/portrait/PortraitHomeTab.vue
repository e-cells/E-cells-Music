<script setup lang="ts">
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import CustomTabBar from '@/components/ui/CustomTabBar.vue';
import HomeView from '@/views/Home.vue';
import ExploreView from '@/views/Explore.vue';
import { iconSearch } from '@/icons';

const router = useRouter();
const subTab = ref(0);

const subTabs = ['推荐', '歌单', '排行榜', '新碟上架', '新歌速递', '歌手'];

const goToSearch = () => router.push('/main/search');
</script>

<template>
  <div class="portrait-home h-full flex flex-col bg-bg-main relative">
    
    <div class="top-nav-area shrink-0 z-20 sticky top-0 w-full">
      <div class="px-4 md:px-6 pt-3 pb-2 w-full">
        <button type="button" class="search-bar" @click="goToSearch">
          <Icon :icon="iconSearch" width="18" height="18" class="search-icon" />
          <span class="search-placeholder">搜索音乐、歌手、歌单...</span>
        </button>
      </div>
      <div class="px-4 md:px-6 pb-2">
        <CustomTabBar v-model="subTab" :tabs="subTabs" />
      </div>
    </div>

    <div class="flex-1 min-h-0 overflow-hidden relative z-10 -mt-[1px]">
      <div v-show="subTab === 0" class="h-full overflow-y-auto pb-safe scrollbar-hide">
        <HomeView :show-header="true" />
      </div>
      <div v-show="subTab !== 0" class="h-full overflow-y-auto pb-safe scrollbar-hide">
        <ExploreView :initial-tab="subTab - 1" :show-header="false" />
      </div>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.portrait-home {
  background: var(--color-bg-main);
}

/* 底部安全区适配 (全面屏手势小横条留白) 依然保留 */
.pb-safe {
  padding-bottom: max(16px, calc(env(safe-area-inset-bottom, 0px) + 16px));
}

/* 顶部导航区毛玻璃效果 */
.top-nav-area {
  background: color-mix(in srgb, var(--color-bg-main) 85%, transparent);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  /* 仅在底部保留极细的分割线，更高级 */
  border-bottom: 1px solid color-mix(in srgb, var(--color-border-light) 30%, transparent);
}
.dark .top-nav-area {
  background: color-mix(in srgb, var(--color-bg-main) 75%, transparent);
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
}

/* 搜索框样式升级：更宽厚、更柔和 */
.search-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  height: 42px;
  padding: 0 16px;
  border-radius: 21px; /* 完美半圆 */
  background: color-mix(in srgb, var(--color-text-main) 5%, transparent);
  border: 1px solid transparent;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: all 0.2s ease;
}

.dark .search-bar {
  background: rgba(255, 255, 255, 0.08);
}

.search-bar:active {
  transform: scale(0.98);
  background: color-mix(in srgb, var(--color-text-main) 8%, transparent);
}
.dark .search-bar:active {
  background: rgba(255, 255, 255, 0.12);
}

.search-icon {
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  flex-shrink: 0;
}

.search-placeholder {
  font-size: 14px;
  color: color-mix(in srgb, var(--color-text-main) 45%, transparent);
  font-weight: 500;
  letter-spacing: 0.3px;
}

/* 隐藏手机端原生滚动条 */
.scrollbar-hide::-webkit-scrollbar {
  display: none;
}
.scrollbar-hide {
  -ms-overflow-style: none;
  scrollbar-width: none;
}
</style>