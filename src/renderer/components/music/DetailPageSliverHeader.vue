<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue';
import Cover from '@/components/ui/Cover.vue';

interface Props {
  typeLabel: string;
  title: string;
  coverUrl: string;
  hasDetails?: boolean;
  compact?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  hasDetails: false,
  compact: false,
});

const isScrolled = ref(false);
const currentHeight = ref(56); // 吸顶栏固定高度
defineExpose({ currentHeight });

const handleScroll = (e: Event) => {
  const target = e.target as HTMLElement;
  // 当向下滚动超过 80px 时，显示顶部的吸顶栏
  isScrolled.value = target.scrollTop > 80;
};

onMounted(() => {
  let scrollContainer = document.querySelector('.view-port') || document.querySelector('.scrollbar-wrap');
  if (scrollContainer) {
    scrollContainer.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll({ target: scrollContainer } as unknown as Event);
  }
});

onUnmounted(() => {
  let scrollContainer = document.querySelector('.view-port') || document.querySelector('.scrollbar-wrap');
  if (scrollContainer) {
    scrollContainer.removeEventListener('scroll', handleScroll);
  }
});
</script>

<template>
  <div class="sliver-header-root relative w-full">
    <div
      class="sticky top-0 z-[100] w-full h-[56px] flex items-center justify-between px-5 md:px-8 transition-all duration-300"
      :class="isScrolled ? 'bg-bg-main/90 backdrop-blur-xl border-b border-border-light/10 opacity-100 pointer-events-auto' : 'bg-transparent opacity-0 pointer-events-none'"
    >
      <div class="flex items-center gap-3 overflow-hidden flex-1 min-w-0 transition-transform duration-300" :class="isScrolled ? 'translate-y-0' : 'translate-y-4'">
        <div class="w-8 h-8 rounded-md overflow-hidden shrink-0 shadow-sm">
          <Cover :url="coverUrl" :size="80" :width="32" :height="32" />
        </div>
        <span class="font-bold text-[15px] text-text-main truncate">{{ title }}</span>
      </div>
      <div class="flex items-center gap-1 shrink-0 ml-4">
        <slot name="collapsed-actions" />
      </div>
    </div>

    <div class="relative z-10 flex flex-col md:flex-row items-center md:items-center px-5 md:px-8 pt-1 pb-6 md:pb-8 gap-5 md:gap-8 w-full box-border">
      
      <div class="shrink-0 relative group">
        <div class="w-40 h-40 md:w-48 md:h-48 rounded-2xl overflow-hidden shadow-2xl transition-transform duration-300 md:group-hover:-translate-y-1">
          <Cover :url="coverUrl" :size="400" :width="192" :height="192" />
        </div>
      </div>

      <div class="flex-1 min-w-0 flex flex-col items-center md:items-start text-center md:text-left w-full py-2">
        <div class="type-badge mb-2.5">{{ typeLabel }}</div>
        <h1 class="text-2xl md:text-3xl font-extrabold text-text-main leading-tight mb-3 line-clamp-2 w-full">
          {{ title }}
        </h1>
        <div class="w-full flex justify-center md:justify-start">
          <slot name="details" />
        </div>
        <div class="mt-5 w-full flex justify-center md:justify-start">
          <slot name="actions" />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.sliver-header-root {
  isolation: isolate;
}

.type-badge {
  @apply inline-block px-2.5 py-0.5 rounded-full text-[10px] font-bold tracking-[1.2px] uppercase;
  background-color: color-mix(in srgb, var(--color-primary) 12%, transparent);
  color: var(--color-primary);
  border: 0.5px solid color-mix(in srgb, var(--color-primary) 20%, transparent);
}
</style>