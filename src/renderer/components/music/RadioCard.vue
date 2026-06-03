<script setup lang="ts">
import { useRouter } from 'vue-router';
import Cover from '@/components/ui/Cover.vue';
import { iconPlay } from '@/icons';
import { prefetchRadioSongs } from '@/api/radio';

interface Props {
  fmid: number;
  name: string;
  coverUrl: string;
  description?: string;
  layout?: 'grid' | 'list';
}

const props = withDefaults(defineProps<Props>(), {
  layout: 'grid',
});

const router = useRouter();

// 悬停/触摸时预加载该电台的歌曲
const handlePrefetch = () => {
  prefetchRadioSongs(props.fmid);
};

const handleClick = () => {
  router.push({
    name: 'radio-detail',
    params: { id: props.fmid },
    query: {
      name: props.name,
      cover: props.coverUrl,
      desc: props.description || '',
    },
  });
};

const handlePlay = (e: Event) => {
  e.stopPropagation();
  handleClick();
};
</script>

<template>
  <!-- Grid 布局 -->
  <div
    v-if="layout === 'grid'"
    class="radio-card-grid group cursor-pointer"
    @click="handleClick"
    @mouseenter="handlePrefetch"
    @touchstart="handlePrefetch"
  >
    <div class="card-container">
      <div class="cover-wrapper">
        <Cover
          :url="coverUrl"
          :size="400"
          :borderRadius="14"
          class="w-full h-full"
        />
        <button
          class="play-overlay"
          @click="handlePlay"
        >
          <Icon :icon="iconPlay" width="22" height="22" />
        </button>
      </div>
      <div class="info-wrapper">
        <h3 class="title">{{ name }}</h3>
        <p v-if="description" class="subtitle">{{ description }}</p>
      </div>
    </div>
  </div>

  <!-- List 布局 -->
  <div
    v-else
    class="radio-card-list group cursor-pointer"
    @click="handleClick"
    @mouseenter="handlePrefetch"
    @touchstart="handlePrefetch"
  >
    <div class="cover-wrapper-list relative overflow-hidden shrink-0">
      <Cover
        :url="coverUrl"
        :size="200"
        :width="56"
        :height="56"
        :borderRadius="10"
        class="w-full h-full"
      />
      <button
        class="play-overlay-mini"
        @click="handlePlay"
      >
        <Icon :icon="iconPlay" width="14" height="14" />
      </button>
    </div>
    <div class="info-wrapper ml-3 overflow-hidden flex flex-col justify-center">
      <h3 class="title">{{ name }}</h3>
      <p v-if="description" class="subtitle">{{ description }}</p>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* ===== Grid 布局 ===== */
.radio-card-grid {
  @apply transition-all duration-300 ease-out;
}

.radio-card-grid:hover {
  transform: scale(1.03);
}

.card-container {
  @apply p-[10px] rounded-[20px] bg-bg-card border border-border-light/50 transition-all duration-300;
  box-shadow: 0 8px 18px rgba(15, 23, 42, 0.08);
}

.dark .card-container {
  border-color: color-mix(in srgb, var(--color-border-light) 92%, transparent);
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.34);
}

.radio-card-grid:hover .card-container {
  box-shadow: 0 12px 28px rgba(15, 23, 42, 0.12), 0 0 24px var(--color-primary-light);
}

.dark .radio-card-grid:hover .card-container {
  box-shadow: 0 14px 34px rgba(0, 0, 0, 0.42), 0 0 24px color-mix(in srgb, var(--color-primary) 18%, transparent);
}

.cover-wrapper {
  @apply aspect-square overflow-hidden relative;
  border-radius: 14px;
}

/* 播放按钮覆盖层 - grid */
.play-overlay {
  @apply absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity duration-200;
}

.radio-card-grid:active .play-overlay {
  opacity: 1;
}

.play-overlay::before {
  content: '';
  @apply absolute inset-0;
  background: rgba(0, 0, 0, 0.35);
  border-radius: inherit;
}

.play-overlay {
  color: #fff;
  z-index: 1;
}

.play-overlay > :deep(*) {
  filter: drop-shadow(0 2px 4px rgba(0, 0, 0, 0.3));
}

.info-wrapper {
  @apply mt-2 px-0.5;
  min-height: 36px;
}

.title {
  @apply text-[13px] font-semibold text-text-main line-clamp-1;
  line-height: 1.1;
}

.subtitle {
  @apply text-[11px] font-semibold text-text-secondary line-clamp-1 opacity-80;
  margin-top: 2px;
}

/* ===== List 布局 ===== */
.radio-card-list {
  @apply flex items-center rounded-[14px] border border-transparent transition-all duration-200;
  padding: 4px 12px 4px 6px;
}

.radio-card-list:hover {
  background-color: color-mix(in srgb, var(--color-text-main) 5%, transparent);
  border-color: color-mix(in srgb, var(--color-border-light) 80%, transparent);
}

.cover-wrapper-list {
  width: 56px;
  height: 56px;
  border-radius: 10px;
}

/* 播放按钮覆盖层 - list */
.play-overlay-mini {
  @apply absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity duration-200;
  color: #fff;
}

.radio-card-list:active .play-overlay-mini {
  opacity: 1;
}

.play-overlay-mini::before {
  content: '';
  @apply absolute inset-0;
  background: rgba(0, 0, 0, 0.35);
  border-radius: inherit;
}

.play-overlay-mini > :deep(*) {
  filter: drop-shadow(0 2px 4px rgba(0, 0, 0, 0.3));
}

.radio-card-list .title {
  @apply text-[15px] font-semibold text-text-main line-clamp-1;
}

.radio-card-list .subtitle {
  @apply text-[12px] mt-1;
}
</style>
