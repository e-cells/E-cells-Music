<script setup lang="ts">
import type { IconifyIcon } from '@iconify/types';
import { iconPlay, iconList } from '@/icons';
import Button from '@/components/ui/Button.vue';
interface Action {
  icon: IconifyIcon;
  label: string;
  onTap: () => void | Promise<void>;
  emphasized?: boolean;
  tone?: 'default' | 'favorite';
}

interface Props {
  playLabel?: string;
  playDisabled?: boolean;
  onPlay?: () => void;
  secondaryActions?: Action[];
}

const props = withDefaults(defineProps<Props>(), {
  playLabel: '播放',
  playDisabled: false,
  secondaryActions: () => [],
});

const emit = defineEmits<{
  (e: 'play'): void;
  (e: 'batch'): void;
}>();
</script>

<template>
  <div class="action-row-wrap flex flex-wrap items-center justify-start gap-2.5">
    <Button variant="unstyled" size="none" :disabled="props.playDisabled" @click="emit('play')" class="action-btn primary" :class="{ 'action-btn-disabled': props.playDisabled }">
      <Icon :icon="iconPlay" width="18" height="18" />
      <span>{{ playLabel }}</span>
    </Button>

    <Button
      variant="unstyled"
      size="none"
      v-for="action in secondaryActions"
      :key="action.label"
      @click="action.onTap"
      class="action-btn secondary"
      :class="[{ emphasized: action.emphasized }, action.tone === 'favorite' ? 'favorite' : '']"
    >
      <Icon :icon="action.icon" width="16" height="16" />
      <span>{{ action.label }}</span>
    </Button>

    <Button variant="unstyled" size="none" @click="emit('batch')" class="action-btn secondary">
      <Icon :icon="iconList" width="16" height="16" />
      <span>批量</span>
    </Button>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.action-btn {
  @apply flex items-center gap-1.5 px-4 h-10 rounded-full text-[13px] font-bold transition-all active:scale-95 select-none;
  background-color: var(--bg-info-card);
  color: var(--color-text-main);
}

.action-btn.primary {
  @apply bg-primary text-white hover:bg-primary-hover;
  box-shadow: 0 4px 12px color-mix(in srgb, var(--color-primary) 35%, transparent);
}

.action-btn.secondary.favorite {
  color: #f87171;
  background: color-mix(in srgb, #ef4444 8%, transparent);
}

.action-btn.secondary.favorite:hover {
  color: #ef4444;
  background: color-mix(in srgb, #ef4444 14%, transparent);
}

.action-btn.secondary.emphasized {
  color: #ef4444;
  background: color-mix(in srgb, #ef4444 12%, transparent);
}

.action-btn.secondary.emphasized:hover {
  color: #dc2626;
  background: color-mix(in srgb, #ef4444 18%, transparent);
}

.action-btn:hover {
  @apply brightness-95;
}

.dark .action-btn {
  background-color: rgba(255, 255, 255, 0.08);
}

.action-btn-disabled {
  opacity: 0.45;
  pointer-events: none;
}
</style>