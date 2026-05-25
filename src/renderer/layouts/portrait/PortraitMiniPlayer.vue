<script setup lang="ts">
import { computed, ref } from 'vue';
import { usePlayerStore } from '@/stores/player';
import { usePlayerControls } from '@/utils/usePlayerControls';
import Cover from '@/components/ui/Cover.vue';
import PlayerQueueDrawer from '@/components/music/PlayerQueueDrawer.vue';
import { iconPlay, iconPause, iconSkipBack, iconSkipForward, iconList } from '@/icons';

const emit = defineEmits<{ click: [] }>();

const player = usePlayerStore();
const { currentTrack } = usePlayerControls();

const isPlaying = computed(() => player.isPlaying);
const progress = computed(() => {
  if (!player.duration || player.duration <= 0) return 0;
  return Math.min((player.currentTime / player.duration) * 100, 100);
});
const hasTrack = computed(() => !!currentTrack.value);

const artistText = computed(() => {
  const track = currentTrack.value;
  if (!track) return '';
  if (track.artists?.length) return track.artists.map((a) => a.name).join(' / ');
  return track.artist ?? '';
});

const isQueueDrawerOpen = ref(false);

const togglePlay = (e: Event) => {
  e.stopPropagation();
  void player.togglePlay();
};

const prevTrack = (e: Event) => {
  e.stopPropagation();
  player.prev();
};

const nextTrack = (e: Event) => {
  e.stopPropagation();
  player.next();
};

const openQueue = (e: Event) => {
  e.stopPropagation();
  isQueueDrawerOpen.value = true;
};
</script>

<template>
  <div v-if="hasTrack" class="mini-player" @click="emit('click')">
    <div class="mini-progress" :style="{ width: progress + '%' }"></div>
    <div class="mini-content">
      <Cover
        :url="currentTrack?.coverUrl ?? ''"
        :size="120"
        :width="36"
        :height="36"
        :borderRadius="8"
        class="shrink-0"
      />
      <div class="mini-info">
        <div class="mini-title">{{ currentTrack?.title ?? '未知' }}</div>
        <div class="mini-artist">{{ artistText }}</div>
      </div>
      <div class="mini-actions">
        <button type="button" class="mini-btn" @click="prevTrack">
          <Icon :icon="iconSkipBack" width="18" height="18" />
        </button>
        <button type="button" class="mini-btn" @click="togglePlay">
          <Icon :icon="isPlaying ? iconPause : iconPlay" width="20" height="20" />
        </button>
        <button type="button" class="mini-btn" @click="nextTrack">
          <Icon :icon="iconSkipForward" width="18" height="18" />
        </button>
        <button type="button" class="mini-btn" @click="openQueue">
          <Icon :icon="iconList" width="18" height="18" />
        </button>
      </div>
    </div>
    <PlayerQueueDrawer v-model:open="isQueueDrawerOpen" />
  </div>
</template>

<style scoped>
@reference "@/style.css";

.mini-player {
  position: relative;
  flex-shrink: 0;
  height: 52px;
  background: var(--color-bg-sidebar);
  border-top: 1px solid color-mix(in srgb, var(--color-border-light) 30%, transparent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  overflow: hidden;
}

.mini-progress {
  position: absolute;
  top: 0;
  left: 0;
  height: 2px;
  background: var(--color-primary);
  transition: width 0.3s linear;
}

.mini-content {
  display: flex;
  align-items: center;
  gap: 10px;
  height: 100%;
  padding: 0 12px;
}

.mini-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 1px;
  overflow: hidden;
}

.mini-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-main);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.mini-artist {
  font-size: 11px;
  color: color-mix(in srgb, var(--color-text-main) 55%, transparent);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.mini-actions {
  display: flex;
  align-items: center;
  gap: 2px;
  flex-shrink: 0;
}

.mini-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 40px;
  height: 40px;
  border-radius: 50%;
  background: transparent;
  color: var(--color-text-main);
  transition: background 0.15s ease;
  -webkit-tap-highlight-color: transparent;
}

.mini-btn:active {
  background: color-mix(in srgb, var(--color-text-main) 10%, transparent);
}
</style>
