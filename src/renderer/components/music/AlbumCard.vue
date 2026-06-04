<script setup lang="ts">
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import { useMediaQuery } from '@vueuse/core';
import Cover from '@/components/ui/Cover.vue';

interface Props {
  id: string | number;
  name: string;
  coverUrl: string;
  artist?: string;
  publishTime?: string;
  subtitle?: string;
  layout?: 'grid' | 'list' | 'responsive'; // 新增 responsive 选项
}

const props = withDefaults(defineProps<Props>(), {
  layout: 'grid',
});

const router = useRouter();
const isMobile = useMediaQuery('(max-width: 768px)');

const effectiveLayout = computed(() => {
  if (props.layout === 'responsive') return isMobile.value ? 'list' : 'grid';
  return props.layout;
});

const handleClick = () => {
  router.push({ name: 'album-detail', params: { id: props.id } });
};
</script>

<template>
  <div v-if="effectiveLayout === 'grid'" class="album-card group cursor-pointer" @click="handleClick">
    <div class="card-container">
      <div class="cover-wrapper">
        <Cover :url="coverUrl" :size="400" class="w-full h-full" />
      </div>
      <div class="info-wrapper">
        <h3 class="title">{{ name }}</h3>
        <p class="subtitle">
          {{
            subtitle ||
            `${artist || ''}${artist && publishTime ? ' • ' : ''}${publishTime || ''}`.trim()
          }}
        </p>
      </div>
    </div>
  </div>

  <div v-else class="album-card-list group cursor-pointer" @click="handleClick">
    <Cover
      :url="coverUrl"
      :size="200"
      :width="56"
      :height="56"
      :borderRadius="10"
      class="shrink-0 shadow-sm"
    />
    <div class="info-wrapper ml-3 overflow-hidden flex flex-col justify-center">
      <h3 class="title">{{ name }}</h3>
      <p v-if="artist || publishTime || subtitle" class="subtitle">
        {{
          subtitle ||
          `${artist || ''}${artist && publishTime ? ' • ' : ''}${publishTime || ''}`.trim()
        }}
      </p>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.album-card {
  @apply transition-all duration-300 ease-out;
}

.album-card:hover {
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

.album-card:hover .card-container {
  box-shadow:
    0 12px 28px rgba(15, 23, 42, 0.12),
    0 0 24px var(--color-primary-light);
}

.dark .album-card:hover .card-container {
  box-shadow:
    0 14px 34px rgba(0, 0, 0, 0.42),
    0 0 24px color-mix(in srgb, var(--color-primary) 18%, transparent);
}

.cover-wrapper {
  @apply aspect-square rounded-[14px] overflow-hidden shadow-sm;
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

/* List Layout */
.album-card-list {
  @apply flex items-center rounded-[14px] border border-transparent transition-all duration-200;
  padding: 4px 12px 4px 6px;
}

.album-card-list:hover {
  background-color: color-mix(in srgb, var(--color-text-main) 5%, transparent);
  border-color: color-mix(in srgb, var(--color-border-light) 80%, transparent);
}

.album-card-list .title {
  @apply text-[15px] font-semibold text-text-main line-clamp-1;
}

.album-card-list .subtitle {
  @apply text-[12px] mt-1;
}
</style>