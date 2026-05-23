<script setup lang="ts">
defineOptions({ name: 'personal-fm' });
import { computed, onActivated, onMounted, ref } from 'vue';
import {
  PERSONAL_FM_QUEUE_ID,
  getPersonalFmModePresentation,
  getPersonalFmSongPoolPresentation,
  usePlaylistStore,
} from '@/stores/playlist';
import { usePlayerStore } from '@/stores/player';
import { useUserStore } from '@/stores/user';
import { iconHeartFilled, iconHeartOff, iconPause, iconPlay } from '@/icons';
import Button from '@/components/ui/Button.vue';
import Cover from '@/components/ui/Cover.vue';
import { replaceQueueAndPlay } from '@/utils/playback';
import { getSongQualityTags } from '@/utils/song';
import type { PersonalFmMode, PersonalFmSongPoolId } from '@/stores/playlist';
import type { Song } from '@/models/song';

const playlistStore = usePlaylistStore();
const playerStore = usePlayerStore();
const userStore = useUserStore();
const personalFmLoading = ref(false);

const personalFmModeOptions: Array<{ value: PersonalFmMode; label: string }> = [
  { value: 'normal', label: '红心' },
  { value: 'small', label: '小众' },
  { value: 'peak', label: '速览' },
];

const personalFmSongPoolOptions: Array<{ value: PersonalFmSongPoolId; label: string }> = [
  { value: 0, label: '根据口味' },
  { value: 1, label: '根据风格' },
  { value: 2, label: '探索' },
];

const personalFmQueue = computed(
  () => playlistStore.playbackQueues.find((queue) => queue.id === PERSONAL_FM_QUEUE_ID) ?? null,
);
const isLoggedIn = computed(() => userStore.isLoggedIn);
const personalFmCurrentTrack = computed(() => playlistStore.getPersonalFmPreviewTrack());
const isPersonalFmActive = computed(() => playlistStore.activeQueueId === PERSONAL_FM_QUEUE_ID);
const personalFmQueueCurrentTrackId = computed(() =>
  String(personalFmQueue.value?.currentTrackId ?? ''),
);
const isPersonalFmCurrentTrackActive = computed(() => {
  const queueTrackId = personalFmQueueCurrentTrackId.value;
  if (!queueTrackId) return false;
  return (
    playerStore.currentSourceQueueId === PERSONAL_FM_QUEUE_ID &&
    String(playerStore.currentTrackId ?? '') === queueTrackId
  );
});
const isPersonalFmPlaying = computed(
  () => isPersonalFmCurrentTrackActive.value && playerStore.isPlaying,
);
const personalFmDisplayTracks = computed(() => playlistStore.getPersonalFmDisplayTracks(6));
const personalFmNowPlayingTrack = computed(() => {
  const queue = personalFmQueue.value;
  const queueCurrentTrackId = String(queue?.currentTrackId ?? '');
  if (queue && queueCurrentTrackId) {
    return (
      queue.songs.find((song) => String(song.id) === queueCurrentTrackId) ??
      personalFmCurrentTrack.value
    );
  }
  return personalFmCurrentTrack.value;
});
const personalFmCurrentDisc = computed(
  () => personalFmNowPlayingTrack.value ?? personalFmCurrentTrack.value,
);
const personalFmSideTracks = computed(() => {
  const currentId = String(personalFmCurrentDisc.value?.id ?? '');
  return personalFmDisplayTracks.value
    .filter((track) => String(track.id) !== currentId)
    .slice(0, 4); // 固定展示后续最多 4 首
});

const selectedPersonalFmMode = computed(() => playlistStore.personalFmMode);
const selectedPersonalFmSongPoolId = computed(() => playlistStore.personalFmSongPoolId);
const personalFmPresentation = computed(() =>
  getPersonalFmModePresentation(selectedPersonalFmMode.value),
);
const personalFmSongPoolPresentation = computed(() =>
  getPersonalFmSongPoolPresentation(selectedPersonalFmSongPoolId.value),
);
const personalFmCurrentTrackReason = computed(() => {
  const track = personalFmCurrentDisc.value;
  if (!track) return '';
  return track.recDesc || `${personalFmPresentation.value.title} 实时推荐`;
});
const personalFmCurrentTrackAlbum = computed(() => {
  const track = personalFmCurrentDisc.value;
  return String(track?.albumName ?? track?.album ?? '').trim();
});
const personalFmCurrentTrackInfoChips = computed(() => {
  const track = personalFmCurrentDisc.value;
  if (!track) return [];

  const chips: string[] = [];
  const duration =
    track.duration > 0
      ? `${Math.floor(track.duration / 60)}:${String(Math.floor(track.duration % 60)).padStart(2, '0')}`
      : '';
  const quality = getSongQualityTags(track.relateGoods).at(-1) ?? '';

  if (duration) chips.push(duration);
  if (quality) chips.push(quality);
  if (track.language) chips.push(track.language);
  if (track.similarDesc) chips.push(`相似度${track.similarDesc}`);

  return chips.slice(0, 4);
});

const playCurrentPersonalFm = async () => {
  const queue = playlistStore.playbackQueues.find((item) => item.id === PERSONAL_FM_QUEUE_ID);
  if (!queue) return;
  const targetSong = await playlistStore.consumeNextPersonalFmTrack({
    playtime: 0,
    isOverplay: false,
  });
  if (!targetSong) return;
  await replaceQueueAndPlay(playlistStore, playerStore, queue.songs, 0, targetSong, {
    queueId: PERSONAL_FM_QUEUE_ID,
    title: queue.title,
    subtitle: queue.subtitle,
    type: 'fm',
    dynamic: true,
    meta: {
      mode: selectedPersonalFmMode.value,
      song_pool_id: selectedPersonalFmSongPoolId.value,
    },
  });
  void playlistStore.ensurePersonalFmQueue({ track: targetSong, playtime: 0, isOverplay: false });
};

const resumeCurrentPersonalFm = async () => {
  const targetTrack = personalFmCurrentDisc.value ?? personalFmCurrentTrack.value;
  if (!targetTrack) return false;

  const queueSongs = playlistStore.activatePersonalFmTrack(targetTrack);
  await playerStore.playTrack(String(targetTrack.id), queueSongs, {
    sourceQueueId: PERSONAL_FM_QUEUE_ID,
  });
  void playlistStore.ensurePersonalFmQueue({
    track: targetTrack,
    playtime: 0,
    isOverplay: false,
  });
  return true;
};

const handlePlayPersonalFm = async () => {
  const resetPending = playlistStore.isPersonalFmSessionResetPending();
  if (
    isPersonalFmCurrentTrackActive.value &&
    personalFmQueue.value?.songs.length &&
    !resetPending
  ) {
    await playerStore.togglePlay();
    return;
  }
  if (personalFmLoading.value) return;
  personalFmLoading.value = true;
  try {
    if (!resetPending) {
      const resumed = await resumeCurrentPersonalFm();
      if (resumed) return;
    }

    const ready = await playlistStore.startPersonalFm({
      fresh: true,
      mode: selectedPersonalFmMode.value,
      recreate: resetPending,
      retainBuffer: resetPending,
    });
    if (!ready) return;
    await playCurrentPersonalFm();
  } finally {
    personalFmLoading.value = false;
  }
};

const handleSelectPersonalFmTrack = async (track: Song) => {
  if (personalFmLoading.value) return;

  const targetId = String(track.id ?? '');
  if (!targetId) return;

  if (isPersonalFmActive.value && String(playerStore.currentTrackId ?? '') === targetId) {
    if (!playerStore.isPlaying) {
      await playerStore.togglePlay();
    }
    return;
  }

  personalFmLoading.value = true;
  try {
    if (playlistStore.isPersonalFmSessionResetPending()) {
      const ready = await playlistStore.startPersonalFm({
        fresh: true,
        mode: selectedPersonalFmMode.value,
        recreate: true,
      });
      if (!ready) return;
      await playCurrentPersonalFm();
      return;
    }
    const queueSongs = playlistStore.activatePersonalFmTrack(track);
    await playerStore.playTrack(targetId, queueSongs, {
      sourceQueueId: PERSONAL_FM_QUEUE_ID,
    });
    void playlistStore.ensurePersonalFmQueue({ track, playtime: 0, isOverplay: false });
  } finally {
    personalFmLoading.value = false;
  }
};

const handleChangePersonalFmMode = async (mode: PersonalFmMode) => {
  if (personalFmLoading.value || mode === selectedPersonalFmMode.value) return;
  personalFmLoading.value = true;
  try {
    await playlistStore.resetPersonalFmPreview({
      mode,
      songPoolId: selectedPersonalFmSongPoolId.value,
    });
    if (isPersonalFmActive.value) {
      await playCurrentPersonalFm();
    }
  } finally {
    personalFmLoading.value = false;
  }
};

const handleChangePersonalFmSongPool = async (songPoolId: PersonalFmSongPoolId) => {
  if (personalFmLoading.value || songPoolId === selectedPersonalFmSongPoolId.value) return;
  personalFmLoading.value = true;
  try {
    await playlistStore.resetPersonalFmPreview({
      mode: selectedPersonalFmMode.value,
      songPoolId,
    });
    if (isPersonalFmActive.value) {
      await playCurrentPersonalFm();
    }
  } finally {
    personalFmLoading.value = false;
  }
};

const handleDislikePersonalFm = async () => {
  const currentTrack = personalFmNowPlayingTrack.value ?? personalFmCurrentTrack.value;
  if (personalFmLoading.value || !currentTrack) return;

  personalFmLoading.value = true;
  try {
    if (!isPersonalFmActive.value || !playerStore.currentTrackId) {
      await playlistStore.resetPersonalFmPreview({
        mode: selectedPersonalFmMode.value,
        songPoolId: selectedPersonalFmSongPoolId.value,
      });
      return;
    }

    await playlistStore.ensurePersonalFmQueue({
      track: currentTrack,
      playtime: Math.max(0, Math.floor(playerStore.currentTime || 0)),
      action: 'garbage',
      isOverplay: false,
    });

    playlistStore.removeFromQueue(currentTrack.id);
    await playCurrentPersonalFm();
  } finally {
    personalFmLoading.value = false;
  }
};

onMounted(() => {
  if (!isLoggedIn.value) return;

  const shouldFetchPreview =
    playlistStore.isPersonalFmSessionResetPending() || !personalFmCurrentTrack.value;

  if (shouldFetchPreview && !personalFmLoading.value) {
    personalFmLoading.value = true;
    void playlistStore
      .resetPersonalFmPreview({
        mode: selectedPersonalFmMode.value,
        songPoolId: selectedPersonalFmSongPoolId.value,
        preserveQueue: true,
      })
      .finally(() => {
        personalFmLoading.value = false;
      });
  }
});

onActivated(() => {
  const scrollContainer = document.querySelector('.view-port');
  if (scrollContainer) {
    scrollContainer.scrollTop = 0;
  }
});
</script>

<template>
  <div class="personal-fm-view w-full h-full relative overflow-hidden flex flex-col">
    <div class="absolute inset-0 z-0 overflow-hidden pointer-events-none transition-opacity duration-1000" :class="{ 'opacity-0': !personalFmCurrentDisc, 'opacity-40': personalFmCurrentDisc }">
      <img v-if="personalFmCurrentDisc?.coverUrl" :src="personalFmCurrentDisc.coverUrl" alt="bg" class="w-full h-full object-cover blur-[80px] scale-125 opacity-30 dark:opacity-20" />
      <div class="absolute inset-0 bg-gradient-to-b from-transparent to-bg-main dark:to-bg-main"></div>
    </div>

    <div class="relative z-10 w-full h-full overflow-y-auto pt-6 pb-24 px-6 md:px-12 scrollbar-hide">
      <div class="fm-header mb-8 md:mb-12">
        <div class="text-3xl font-extrabold tracking-tight text-text-main">私人 FM</div>
        <div class="text-sm font-medium text-text-main/60 mt-2">
          {{ personalFmPresentation.title }} · {{ personalFmSongPoolPresentation.label }}
        </div>
      </div>

      <section v-if="!isLoggedIn" class="flex flex-col items-center justify-center min-h-[50vh] text-center">
        <div class="w-20 h-20 rounded-full bg-primary/10 text-primary flex items-center justify-center mb-6">
          <Icon :icon="iconHeartFilled" width="36" height="36" />
        </div>
        <div class="text-2xl font-bold text-text-main">登录后畅听私人 FM</div>
        <div class="text-sm text-text-main/60 mt-3">懂你的音乐，随时为你准备</div>
      </section>

      <section v-else class="flex flex-col md:flex-row gap-10 md:gap-16 lg:gap-24 max-w-7xl mx-auto items-center md:items-start justify-center">
        
        <div class="flex-shrink-0 w-full max-w-[200px] md:max-w-[300px] flex flex-col items-center gap-5">
          <div
            class="cover-wrapper relative w-full aspect-square rounded-[24px] overflow-hidden shadow-2xl transition-transform duration-300"
            :class="{ 'scale-[1.02] shadow-primary/20': isPersonalFmPlaying }"
            @click="handlePlayPersonalFm"
          >
            <Cover
              v-if="personalFmCurrentDisc"
              :url="personalFmCurrentDisc.coverUrl"
              :size="800"
              class="w-full h-full object-cover cursor-pointer"
            />
            <div v-else class="w-full h-full bg-text-main/5 flex items-center justify-center animate-pulse">
              <span class="text-text-main/40 font-medium">获取推荐中...</span>
            </div>
            
            <div 
              class="absolute inset-0 bg-black/20 flex items-center justify-center opacity-0 hover:opacity-100 transition-opacity cursor-pointer backdrop-blur-[2px]"
            >
              <div class="w-12 h-12 rounded-full bg-white/20 backdrop-blur-md flex items-center justify-center text-white">
                <Icon :icon="isPersonalFmPlaying ? iconPause : iconPlay" width="24" height="24" />
              </div>
            </div>
          </div>

          <div class="w-full flex items-center justify-center gap-6">
            <Button
              variant="unstyled"
              size="none"
              class="w-16 h-16 rounded-full bg-text-main/5 hover:bg-text-main/10 text-text-main/70 hover:text-text-main transition-colors flex items-center justify-center disabled:opacity-50"
              :disabled="personalFmLoading || !personalFmCurrentDisc"
              title="不喜欢，切换下一首"
              @click="handleDislikePersonalFm"
            >
              <Icon :icon="iconHeartOff" width="24" height="24" />
            </Button>
            
            <Button
              variant="unstyled"
              size="none"
              class="w-20 h-20 rounded-full bg-primary text-white shadow-lg shadow-primary/30 hover:scale-105 active:scale-95 transition-all flex items-center justify-center"
              :disabled="personalFmLoading"
              @click="handlePlayPersonalFm"
            >
              <span v-if="personalFmLoading" class="w-8 h-8 rounded-full border-4 border-white/30 border-t-white animate-spin"></span>
              <Icon v-else :icon="isPersonalFmPlaying ? iconPause : iconPlay" width="36" height="36" />
            </Button>
          </div>
        </div>

        <div class="flex-1 w-full flex flex-col justify-center gap-8 text-center md:text-left">
          
          <div class="flex flex-col gap-3 min-h-[120px]">
            <div v-if="personalFmCurrentTrackReason" class="inline-flex items-center self-center md:self-start px-3 py-1 rounded-full bg-primary/10 text-primary text-xs font-bold tracking-wide">
              {{ personalFmCurrentTrackReason }}
            </div>
            
            <h1 class="text-3xl md:text-4xl lg:text-5xl font-extrabold text-text-main tracking-tight line-clamp-2">
              {{ personalFmCurrentDisc?.title || '音乐电台' }}
            </h1>
            <div class="text-lg md:text-xl font-semibold text-text-main/70 mt-1 line-clamp-1">
              {{ personalFmCurrentDisc?.artist || '探索发现未知的旋律' }}
            </div>
            
            <div class="flex flex-wrap items-center justify-center md:justify-start gap-2 mt-3">
              <span 
                v-for="item in personalFmCurrentTrackInfoChips" 
                :key="item"
                class="px-3 py-1 rounded-lg bg-text-main/5 border border-text-main/10 text-xs font-semibold text-text-main/60"
              >
                {{ item }}
              </span>
            </div>
          </div>

          <hr class="border-text-main/10 w-full max-w-md mx-auto md:mx-0" />

          <div class="flex flex-col gap-6">
            <div class="flex flex-col gap-3">
              <span class="text-xs font-bold text-text-main/50 uppercase tracking-widest">音乐池选择</span>
              <div class="flex flex-wrap justify-center md:justify-start gap-2">
                <button
                  v-for="option in personalFmSongPoolOptions"
                  :key="option.value"
                  class="px-5 py-2.5 rounded-xl text-sm font-bold transition-all disabled:opacity-50"
                  :class="[
                    option.value === selectedPersonalFmSongPoolId 
                      ? 'bg-text-main text-bg-main shadow-md' 
                      : 'bg-text-main/5 text-text-main/70 hover:bg-text-main/10'
                  ]"
                  :disabled="personalFmLoading"
                  @click="handleChangePersonalFmSongPool(option.value)"
                >
                  {{ option.label }}
                </button>
              </div>
            </div>

            <div class="flex flex-col gap-3">
              <span class="text-xs font-bold text-text-main/50 uppercase tracking-widest">播放模式</span>
              <div class="flex flex-wrap justify-center md:justify-start gap-2">
                <button
                  v-for="option in personalFmModeOptions"
                  :key="option.value"
                  class="px-5 py-2.5 rounded-xl text-sm font-bold transition-all disabled:opacity-50"
                  :class="[
                    option.value === selectedPersonalFmMode 
                      ? 'bg-primary text-white shadow-md shadow-primary/20' 
                      : 'bg-text-main/5 text-text-main/70 hover:bg-text-main/10'
                  ]"
                  :disabled="personalFmLoading"
                  @click="handleChangePersonalFmMode(option.value)"
                >
                  {{ option.label }}
                </button>
              </div>
            </div>
          </div>

          <div v-if="personalFmSideTracks.length" class="mt-4 flex flex-col gap-3">
            <span class="text-xs font-bold text-text-main/50 uppercase tracking-widest">即将播放</span>
            <div class="flex items-center justify-center md:justify-start gap-3 overflow-x-auto scrollbar-hide py-2">
              <button
                v-for="(track, index) in personalFmSideTracks"
                :key="`${track.id}:${index}`"
                class="relative w-14 h-14 md:w-16 md:h-16 flex-shrink-0 rounded-xl overflow-hidden border border-text-main/10 hover:border-primary/50 transition-colors group"
                :title="`播放 ${track.title}`"
                @click="handleSelectPersonalFmTrack(track)"
              >
                <Cover :url="track.coverUrl" :size="120" class="w-full h-full object-cover" />
                <div class="absolute inset-0 bg-black/40 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
                   <Icon :icon="iconPlay" width="20" height="20" class="text-white" />
                </div>
              </button>
            </div>
          </div>

        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.personal-fm-view {
  animation: fade-in 0.4s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.scrollbar-hide::-webkit-scrollbar {
  display: none;
}
.scrollbar-hide {
  -ms-overflow-style: none;
  scrollbar-width: none;
}

@keyframes fade-in {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>