<script setup lang="ts">
import { iconHome, iconPlayerPlay, iconUser } from '@/icons';

const activeTab = defineModel<number>({ required: true });

const tabs = [
  { key: 0, label: '首页', icon: iconHome },
  { key: 1, label: '播放', icon: iconPlayerPlay },
  { key: 2, label: '我的', icon: iconUser },
];
</script>

<template>
  <nav class="portrait-tab-bar">
    <button
      v-for="tab in tabs"
      :key="tab.key"
      type="button"
      :class="['tab-item', activeTab === tab.key ? 'is-active' : '']"
      @click="activeTab = tab.key"
    >
      <Icon :icon="tab.icon" width="22" height="22" />
      <span class="tab-label">{{ tab.label }}</span>
    </button>
  </nav>
</template>

<style scoped>
@reference "@/style.css";

.portrait-tab-bar {
  display: flex;
  align-items: stretch;
  justify-content: space-around;
  flex-shrink: 0;
  height: clamp(56px, 14vw, 64px);
  background: var(--color-bg-sidebar);
  border-top: 1px solid color-mix(in srgb, var(--color-border-light) 40%, transparent);
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

.tab-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
  flex: 1;
  min-width: 0;
  min-height: 44px;
  background: transparent;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  transition: color 0.2s ease;
  -webkit-tap-highlight-color: transparent;
}

.tab-item.is-active {
  color: var(--color-primary);
}

.tab-label {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.2px;
}
</style>
