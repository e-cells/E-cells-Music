<script setup lang="ts">
import { computed, ref, watch, onMounted, onUnmounted, nextTick } from 'vue';
import Cover from '@/components/ui/Cover.vue';
import QualityPopover from '@/components/player/QualityPopover.vue';
import EffectPopover from '@/components/player/EffectPopover.vue';
import PlayerQueueDrawer from '@/components/music/PlayerQueueDrawer.vue';
import CommentDrawer from '@/components/music/CommentDrawer.vue';
import Popover from '@/components/ui/Popover.vue';
import Slider from '@/components/ui/Slider.vue';
import Badge from '@/components/ui/Badge.vue';
import ColorPickerDialog from '@/components/ui/ColorPickerDialog.vue';
import { usePlayerControls } from '@/utils/usePlayerControls';
import { usePlaylistStore } from '@/stores/playlist';
import { useLyricStore } from '@/stores/lyric';
import { useSettingStore } from '@/stores/setting';
import { useLyricColorPicker } from '@/utils/useLyricColorPicker';
import { useSwipeGesture } from '@/composables/useSwipeGesture';
import { useHardwareBack } from '@/composables/useHardwareBack';
import { getCoverUrl } from '@/utils/cover';
import { getMusicComments } from '@/api/comment';
import {
  iconPlay,
  iconPause,
  iconSkipBack,
  iconSkipForward,
  iconHeart,
  iconHeartFilled,
  iconMusic,
  iconSlidersHorizontal,
  iconList,
  iconMessageCircle,
  iconTypography,
} from '@/icons';

const props = defineProps<{ active?: boolean }>();
const emit = defineEmits<{ exit: [] }>();

const {
  player: playerStore,
  currentTrack,
  isFavorite,
  toggleFavorite,
  playModeIcon,
  cyclePlayMode,
  isQueueDrawerOpen,
  audioQualityButtonBadge,
  audioEffectButtonBadge,
} = usePlayerControls();

const lyricStore = useLyricStore();
const settingStore = useSettingStore();
const playlistStore = usePlaylistStore();
const coverStyle = computed(() => settingStore.portraitCoverStyle);

const rootRef = ref<HTMLElement | null>(null);
const lyricListRef = ref<HTMLElement | null>(null);
const isUserScrollingLyrics = ref(false);
const showLyrics = ref(false);
const isCommentDrawerOpen = ref(false);
let userScrollResumeTimer: number | null = null;

const queueSongCount = computed(() => playlistStore.defaultList.length);
const commentCount = ref(0);

const fetchCommentCount = async () => {
  const track = currentTrack.value;
  if (!track) { commentCount.value = 0; return; }
  const mixSongId = track.mixSongId ?? track.id;
  if (!mixSongId) { commentCount.value = 0; return; }
  try {
    const res = await getMusicComments(mixSongId, 1, 1);
    if (currentTrack.value !== track) return;
    if (!res || typeof res !== 'object') { commentCount.value = 0; return; }
    const record = res as Record<string, unknown>;
    const payload = (record.data && typeof record.data === 'object' ? record.data : record) as Record<string, unknown>;
    const total = Number(payload.count ?? payload.total ?? record.count ?? record.total ?? 0) || 0;
    commentCount.value = total;
  } catch { commentCount.value = 0; }
};

// 手势：向下滑动依然可以退出播放页
const { bind: bindSwipe, unbind: unbindSwipe } = useSwipeGesture(rootRef, {
  onSwipeDown: () => emit('exit'),
  threshold: 100,
  excludeSelector: '.lyric-scroll, .play-controls',
});

// 物理返回键/渠道手势拦截
useHardwareBack(
  () => props.active ?? false,
  () => {
    if (isQueueDrawerOpen.value || isCommentDrawerOpen.value || lyricColorPicker.isOpen.value) {
      return false;
    }
    emit('exit');
    return true;
  }
);

const coverUrl = computed(() => getCoverUrl(currentTrack.value?.coverUrl, 500));
const bgCoverUrl = computed(() => getCoverUrl(currentTrack.value?.coverUrl, 120));
const isPlaying = computed(() => playerStore.isPlaying);
const hasLyrics = computed(() => lyricStore.lines.length > 0);
const hasActiveTrack = computed(() => Boolean(currentTrack.value));
const currentIndex = computed(() => lyricStore.currentIndex);


// 迷你歌词五行数据
const miniPrevPrevLine = computed(() => {
  const idx = lyricStore.currentIndex;
  if (idx <= 1) return null;
  return lyricStore.lines[idx - 2] ?? null;
});
const miniPrevLine = computed(() => {
  const idx = lyricStore.currentIndex;
  if (idx <= 0) return null;
  return lyricStore.lines[idx - 1] ?? null;
});
const miniCurrentLine = computed(() => {
  const idx = lyricStore.currentIndex;
  if (idx < 0) return null;
  return lyricStore.lines[idx] ?? null;
});
const miniNextLine = computed(() => {
  const idx = lyricStore.currentIndex;
  if (idx < 0 || idx >= lyricStore.lines.length - 1) return null;
  return lyricStore.lines[idx + 1] ?? null;
});
const miniNextNextLine = computed(() => {
  const idx = lyricStore.currentIndex;
  if (idx < 0 || idx >= lyricStore.lines.length - 2) return null;
  return lyricStore.lines[idx + 2] ?? null;
});
const isYrcLine = (line: { characters: unknown[] }) => (line.characters?.length ?? 0) > 1;

// 歌词设置
const lyricColorPicker = useLyricColorPicker();
const effectivePlayedColor = computed(() => lyricStore.effectivePlayedColor);
const effectiveUnplayedColor = computed(() => lyricStore.effectiveUnplayedColor);
const fontSizeLabel = computed(() => `${Math.round(lyricStore.fontScale * 100)}%`);
const fontWeightLabel = computed(() => `W${lyricStore.fontWeightValue}`);

const coverSize = computed(() => Math.min(280, Math.floor(window.innerWidth * 0.65)));
// 【优化】缩小经典方形封面尺寸，给 5 行歌词留出更宽裕的空间
const squareCoverSize = computed(() => Math.min(260, Math.floor(window.innerWidth * 0.65)));

const artistText = computed(() => {
  const track = currentTrack.value;
  if (!track) return '';
  if (track.artists?.length) return track.artists.map((a) => a.name).join(' / ');
  return track.artist ?? '';
});

const currentTrackLyricHash = computed(() =>
  String(currentTrack.value?.hash ?? currentTrack.value?.id ?? '').trim(),
);

const formatTime = (seconds: number) => {
  if (!seconds || isNaN(seconds)) return '00:00';
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
};

// ── 歌词滚动 ──

const clearUserScrollTimer = () => {
  if (userScrollResumeTimer !== null) {
    window.clearTimeout(userScrollResumeTimer);
    userScrollResumeTimer = null;
  }
};

const scheduleResumeFollowScroll = () => {
  clearUserScrollTimer();
  userScrollResumeTimer = window.setTimeout(() => {
    userScrollResumeTimer = null;
    isUserScrollingLyrics.value = false;
    scrollToCurrentLine(true);
  }, 5000);
};

const handleLyricTouchStart = () => {
  if (!hasLyrics.value) return;
  isUserScrollingLyrics.value = true;
  clearUserScrollTimer();
};

const handleLyricTouchEnd = () => {
  if (!hasLyrics.value) return;
  scheduleResumeFollowScroll();
};

const scrollToCurrentLine = (smooth: boolean) => {
  const container = lyricListRef.value;
  const index = lyricStore.currentIndex;
  if (!container || index < 0 || isUserScrollingLyrics.value) return;

  const target = container.querySelector<HTMLElement>(`[data-lyric-index="${index}"]`);
  if (!target) return;

  const containerRect = container.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();
  const offset =
    targetRect.top -
    containerRect.top +
    container.scrollTop -
    container.clientHeight * 0.45 +
    targetRect.height / 2;
  container.scrollTo({ top: Math.max(0, offset), behavior: smooth ? 'smooth' : 'auto' });
};

// ── 自定义进度条 ──

const progressValue = ref(0);
const isDragging = ref(false);
const progressTrackRef = ref<HTMLElement | null>(null);

watch(
  () => playerStore.currentTime,
  (t) => {
    if (!isDragging.value) progressValue.value = t;
  },
);

const progressRatio = computed(() => {
  const d = playerStore.duration;
  if (!d || d <= 0) return 0;
  return Math.min(1, Math.max(0, progressValue.value / d));
});

const cacheRatio = computed(() => {
  return Math.min(1, Math.max(0, playerStore.cacheProgress));
});

const getTimeFromEvent = (e: TouchEvent | MouseEvent): number => {
  const track = progressTrackRef.value;
  if (!track) return 0;
  const rect = track.getBoundingClientRect();
  let clientX: number;
  if ('touches' in e) {
    clientX = e.touches[0]?.clientX ?? e.changedTouches[0]?.clientX ?? 0;
  } else {
    clientX = e.clientX;
  }
  const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  return ratio * (playerStore.duration || 0);
};

const handleProgressTouchStart = (e: TouchEvent) => {
  e.preventDefault();
  isDragging.value = true;
  playerStore.notifySeekStart();
  progressValue.value = getTimeFromEvent(e);
};

const handleProgressTouchMove = (e: TouchEvent) => {
  e.preventDefault();
  if (!isDragging.value) return;
  progressValue.value = getTimeFromEvent(e);
};

const handleProgressTouchEnd = (e: TouchEvent) => {
  e.preventDefault();
  if (!isDragging.value) return;
  isDragging.value = false;
  playerStore.notifySeekEnd();
  playerStore.seek(progressValue.value);
};

const handleProgressClick = (e: MouseEvent) => {
  if (isDragging.value) return;
  const time = getTimeFromEvent(e);
  if (time <= 0) return;
  playerStore.notifySeekStart();
  playerStore.notifySeekEnd();
  playerStore.seek(time);
};

// ── 歌词加载 ──

const ensureLyrics = () => {
  const track = currentTrack.value;
  if (!track) return;
  const hash = currentTrackLyricHash.value;
  if (!hash) {
    if (!hasLyrics.value) lyricStore.clear('', '暂无歌词');
    return;
  }
  if (lyricStore.loadedHash !== hash) {
    if (track.lyric) {
      lyricStore.setLyric(track.lyric, hash);
    } else if (!hasLyrics.value) {
      lyricStore.clear(hash, '歌词加载中...');
    }
  }
  void lyricStore.fetchLyrics(hash, { preserveCurrent: Boolean(track.lyric) });
};

// ── 播放控制 ──

const togglePlay = () => void playerStore.togglePlay();
const prevTrack = () => playerStore.prev();
const nextTrack = () => playerStore.next();
const handleLineClick = (time: number) => playerStore.seek(time);
const toggleLyrics = () => {
  showLyrics.value = !showLyrics.value;
  if (showLyrics.value) {
    setTimeout(() => scrollToCurrentLine(false), 150);
  }
};

// ── 生命周期 ──

watch(
  () => playerStore.currentTime,
  (value) => {
    if (hasLyrics.value) {
      lyricStore.updateCurrentIndex(value, true);
    }
  },
);

watch(currentTrackLyricHash, () => { ensureLyrics(); fetchCommentCount(); });
watch(currentIndex, () => nextTick(() => scrollToCurrentLine(true)));
watch(
  () => props.active,
  (nowActive) => {
    if (nowActive) {
      setTimeout(() => scrollToCurrentLine(false), 150);
    }
  },
);

onMounted(() => {
  bindSwipe();
  ensureLyrics();
  fetchCommentCount();
});

onUnmounted(() => {
  unbindSwipe();
  clearUserScrollTimer();
});
</script>

<template>
  <div ref="rootRef" class="portrait-play h-full flex flex-col relative overflow-hidden bg-bg-main">
    <div v-if="bgCoverUrl" class="play-bg transition-all duration-700" :style="{ backgroundImage: `url(${bgCoverUrl})` }"></div>
    <div class="play-bg-overlay"></div>

    <div class="play-top-bar shrink-0 pt-safe mt-2 px-4 flex items-center w-full gap-2">
      <div v-if="currentTrack" class="top-bar-info flex-1 flex items-center min-w-0 gap-3 px-1 animate-fade-in">
        <img :src="coverUrl" class="w-9 h-9 rounded object-cover shadow-sm shrink-0" alt="cover" />
        <div class="min-w-0 flex flex-col items-start justify-center text-left">
          <span class="top-title truncate w-full leading-tight">{{ currentTrack.title }}</span>
          <span class="top-artist truncate w-full leading-tight mt-1">{{ artistText }}</span>
        </div>
      </div>
      <div v-else class="flex-1"></div>

      <button
        type="button"
        class="top-bar-btn lyric-toggle-btn shrink-0"
        :class="{ 'is-active': showLyrics }"
        @click="toggleLyrics"
      >
        <span class="font-bold text-[15px]">词</span>
      </button>
    </div>

    <template v-if="!showLyrics">
      <div
        v-if="hasActiveTrack"
        class="cover-center-area flex-1 min-h-0 flex flex-col items-center justify-center gap-10"
        @click="hasLyrics && toggleLyrics()"
      >
        <div
          v-if="coverStyle === 'square'"
          :style="{ width: `${squareCoverSize}px`, height: `${squareCoverSize}px` }"
        >
          <Cover
            :url="currentTrack?.coverUrl ?? ''"
            :size="600"
            :width="squareCoverSize"
            :height="squareCoverSize"
            :borderRadius="16"
            class="w-full h-full object-cover"
          />
        </div>

        <div
          v-else-if="coverStyle === 'disc'"
          class="dvd-cover-wrap"
          :class="{ 'is-paused': !isPlaying || !active }"
          :style="{ width: `${coverSize}px`, height: `${coverSize}px` }"
        >
          <div class="dvd-rim"></div>
          <Cover
            :url="currentTrack?.coverUrl ?? ''"
            :size="600"
            :width="coverSize"
            :height="coverSize"
            :borderRadius="'50%'"
            class="w-full h-full object-cover rounded-full"
          />
          <div class="dvd-hole"></div>
        </div>

        <div
          v-else-if="coverStyle === 'breathing'"
          class="breathing-cover-wrap"
          :class="{ 'is-paused': !isPlaying || !active }"
          :style="{ width: `${coverSize}px`, height: `${coverSize}px` }"
        >
          <Cover
            :url="currentTrack?.coverUrl ?? ''"
            :size="600"
            :width="coverSize"
            :height="coverSize"
            :borderRadius="'50%'"
            class="w-full h-full object-cover rounded-full"
          />
        </div>
        
        <div class="mini-lyric-area w-full max-w-[85%]" @click.stop="toggleLyrics">
          <div v-if="hasLyrics && miniCurrentLine" class="lyric-mask w-full">
            <div v-if="miniPrevPrevLine" class="mini-lyric-line is-dimmer">{{ miniPrevPrevLine.text }}</div>
            <div v-else class="mini-lyric-line is-dimmer is-empty">&nbsp;</div>

            <div v-if="miniPrevLine" class="mini-lyric-line is-dim">{{ miniPrevLine.text }}</div>
            <div v-else class="mini-lyric-line is-dim is-empty">&nbsp;</div>
            
            <div class="mini-lyric-line is-current">
              <template v-if="miniCurrentLine.characters && isYrcLine(miniCurrentLine)">
                <span
                  v-for="(char, ci) in miniCurrentLine.characters"
                  :key="ci"
                  :class="['mini-lyric-char', char.highlighted ? 'is-highlighted' : '']"
                >{{ char.text }}</span>
              </template>
              <template v-else>{{ miniCurrentLine.text }}</template>
            </div>
            
            <div v-if="miniNextLine" class="mini-lyric-line is-dim">{{ miniNextLine.text }}</div>
            <div v-else class="mini-lyric-line is-dim is-empty">&nbsp;</div>

            <div v-if="miniNextNextLine" class="mini-lyric-line is-dimmer">{{ miniNextNextLine.text }}</div>
            <div v-else class="mini-lyric-line is-dimmer is-empty">&nbsp;</div>
          </div>
          <div v-else-if="hasLyrics" class="cover-hint text-center text-sm font-medium text-text-main/50 mt-4">
            点击查看完整歌词
          </div>
        </div>
      </div>
    </template>

    <template v-else>
      <div class="lyric-click-shield shrink-0"></div>
      <div
        v-if="hasLyrics"
        ref="lyricListRef"
        class="lyric-scroll flex-1 min-h-0 overflow-y-auto w-full"
        @touchstart="handleLyricTouchStart"
        @touchend="handleLyricTouchEnd"
      >
        <div class="lyric-list">
          <div
            v-for="(line, i) in lyricStore.lines"
            :key="i"
            :data-lyric-index="i"
            :class="['lyric-line', i === currentIndex ? 'is-active' : '']"
            @click="line.time >= 0 && handleLineClick(line.time)"
          >
            <span
              v-if="line.characters && line.characters.length > 1"
              class="lyric-text"
              :style="{
                fontSize: `${(i === currentIndex ? 1.4 : 1.1) * lyricStore.fontScale}rem`,
                fontWeight: i === currentIndex ? String(lyricStore.fontWeightValue) : '500',
              }"
            >
              <span
                v-for="(char, ci) in line.characters"
                :key="ci"
                :class="['lyric-char', char.highlighted ? 'is-highlighted' : '']"
                >{{ char.text }}</span
              >
            </span>
            <span
              v-else
              class="lyric-text"
              :style="{
                fontSize: `${(i === currentIndex ? 1.4 : 1.1) * lyricStore.fontScale}rem`,
                fontWeight: i === currentIndex ? String(lyricStore.fontWeightValue) : '500',
              }"
            >{{ line.text }}</span>
            <span
              v-if="line.translated"
              class="lyric-translation"
              :style="{ fontSize: `${0.9 * lyricStore.fontScale}rem` }"
            >{{ line.translated }}</span>
          </div>
          <div class="lyric-spacer"></div>
        </div>
      </div>
    </template>

    <div class="play-controls shrink-0 mt-auto pb-safe">
      <div class="progress-row">
        <span class="time-label">{{ formatTime(progressValue) }}</span>
        <div
          ref="progressTrackRef"
          class="progress-bar-wrap group"
          @click="handleProgressClick"
          @touchstart.prevent="handleProgressTouchStart"
          @touchmove.prevent="handleProgressTouchMove"
          @touchend.prevent="handleProgressTouchEnd"
        >
          <div class="progress-track group-active:h-2 transition-all">
            <div v-if="cacheRatio > 0" class="progress-cache" :style="{ width: cacheRatio * 100 + '%' }"></div>
            <div class="progress-range" :style="{ width: progressRatio * 100 + '%' }"></div>
            <div class="progress-thumb scale-0 group-active:scale-100 transition-transform" :style="{ left: progressRatio * 100 + '%' }"></div>
          </div>
        </div>
        <span class="time-label">{{ formatTime(playerStore.duration) }}</span>
      </div>

      <div class="main-controls mt-3">
        <button type="button" class="ctrl-btn" @click="cyclePlayMode">
          <Icon :icon="playModeIcon" width="22" height="22" class="opacity-80" />
        </button>
        <button type="button" class="ctrl-btn" @click="prevTrack">
          <Icon :icon="iconSkipBack" width="30" height="30" />
        </button>
        
        <button type="button" class="ctrl-play" @click="togglePlay">
          <Icon :icon="isPlaying ? iconPause : iconPlay" width="36" height="36" class="text-white" />
        </button>
        
        <button type="button" class="ctrl-btn" @click="nextTrack">
          <Icon :icon="iconSkipForward" width="30" height="30" />
        </button>
        <button type="button" class="ctrl-btn" @click="toggleFavorite">
          <Icon
            :icon="isFavorite ? iconHeartFilled : iconHeart"
            width="22"
            height="22"
            :class="isFavorite ? 'text-red-500' : 'opacity-80'"
          />
        </button>
      </div>

      <div class="extra-controls mt-5 mb-2">
        <EffectPopover variant="lyric" side="top">
          <template #trigger>
            <button type="button" class="extra-icon-btn"
              :class="{ 'is-active': playerStore.audioEffect !== 'none' || playerStore.equalizerGains.some((g: number) => g !== 0) }"
              title="音效与均衡器"
            >
              <span class="relative inline-flex items-center justify-center">
                <Icon :icon="iconSlidersHorizontal" width="22" height="22" />
                <Badge v-if="currentTrack && settingStore.showAudioQualityBadge && audioEffectButtonBadge" :count="audioEffectButtonBadge" class="absolute -top-2" style="right: -12px" />
              </span>
            </button>
          </template>
        </EffectPopover>
        <QualityPopover>
          <template #trigger>
            <button type="button" class="extra-icon-btn" title="音质">
              <span class="relative inline-flex items-center justify-center">
                <Icon :icon="iconMusic" width="22" height="22" />
                <Badge v-if="currentTrack && settingStore.showAudioQualityBadge" :count="audioQualityButtonBadge" class="absolute -top-2" style="right: -12px" />
              </span>
            </button>
          </template>
        </QualityPopover>
        <button type="button" class="extra-icon-btn" title="播放列表" @click="isQueueDrawerOpen = true">
          <span class="relative inline-flex items-center justify-center">
            <Icon :icon="iconList" width="22" height="22" />
            <Badge v-if="queueSongCount > 0" :count="queueSongCount > 99 ? '99+' : queueSongCount" class="absolute -top-2" style="right: -12px" />
          </span>
        </button>
        <button type="button" class="extra-icon-btn" title="评论" @click="isCommentDrawerOpen = true">
          <span class="relative inline-flex items-center justify-center">
            <Icon :icon="iconMessageCircle" width="22" height="22" />
            <Badge v-if="commentCount > 0" :count="commentCount > 99 ? '99+' : commentCount" class="absolute -top-2" style="right: -12px" />
          </span>
        </button>

        <Popover
          v-if="showLyrics"
          trigger="click"
          align="end"
          side="top"
          :side-offset="12"
          content-class="portrait-lyric-settings-popover bg-bg-sidebar/95 backdrop-blur-xl border border-border-light/20 shadow-2xl rounded-2xl p-5"
        >
          <template #trigger>
            <button type="button" class="extra-icon-btn" title="歌词字体">
              <Icon :icon="iconTypography" width="22" height="22" />
            </button>
          </template>
          <div class="portrait-lyric-settings space-y-5">
            <div>
              <div class="pls-row">
                <span class="pls-label">字体大小</span>
                <span class="pls-value">{{ fontSizeLabel }}</span>
              </div>
              <Slider
                :model-value="lyricStore.fontScale"
                :min="0.7"
                :max="1.4"
                :step="0.1"
                @update:model-value="(v: number) => lyricStore.updateFontScale(v)"
                class="h-[6px] w-full mt-2"
              />
            </div>
            <div>
              <div class="pls-row">
                <span class="pls-label">字体粗细</span>
                <span class="pls-value">{{ fontWeightLabel }}</span>
              </div>
              <Slider
                :model-value="lyricStore.fontWeightIndex"
                :min="0"
                :max="8"
                :step="1"
                @update:model-value="(v: number) => lyricStore.updateFontWeight(v)"
                class="h-[6px] w-full mt-2"
              />
            </div>
          </div>
        </Popover>
      </div>
    </div>

    <PlayerQueueDrawer v-model:open="isQueueDrawerOpen" />
    <ColorPickerDialog
      :open="lyricColorPicker.isOpen.value"
      :title="lyricColorPicker.activeTitle.value"
      :value="lyricColorPicker.activeValue.value"
      :presets="lyricColorPicker.presets"
      @update:open="(open: boolean) => !open && lyricColorPicker.close()"
      @confirm="lyricColorPicker.apply"
    />
    <CommentDrawer
      v-if="currentTrack"
      v-model:open="isCommentDrawerOpen"
      :resourceId="currentTrack.mixSongId ? String(currentTrack.mixSongId) : String(currentTrack.id)"
      resourceType="music"
      :mixSongId="currentTrack.mixSongId ? String(currentTrack.mixSongId) : String(currentTrack.id)"
      title="评论"
    />
  </div>
</template>

<style scoped>
@reference "@/style.css";

.portrait-play {
  position: relative;
  background: var(--color-bg-main);
}

.play-bg {
  position: absolute;
  inset: 0;
  background-size: cover;
  background-position: center;
  filter: blur(40px) saturate(1.5) brightness(0.6);
  transform: scale(1.2) translateZ(0);
  will-change: transform, filter;
  z-index: 0;
}

.dark .play-bg {
  filter: blur(40px) saturate(1.2) brightness(0.3);
}

.play-bg-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, color-mix(in srgb, var(--color-bg-main) 10%, transparent) 0%, var(--color-bg-main) 100%);
  z-index: 1;
}

/* ── 顶部栏 ── */
.play-top-bar {
  position: relative;
  z-index: 2;
  height: 54px;
}

.top-bar-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  border-radius: 50%;
  color: var(--color-text-main);
  background: transparent;
  transition: all 0.2s ease;
}
.top-bar-btn:active {
  background: color-mix(in srgb, var(--color-text-main) 10%, transparent);
}

/* 词按钮激活状态 */
.lyric-toggle-btn.is-active {
  color: var(--color-primary);
  background: color-mix(in srgb, var(--color-primary) 15%, transparent);
}

.top-title {
  font-size: 14px;
  font-weight: 700;
  color: var(--color-text-main);
}

.top-artist {
  font-size: 11px;
  color: color-mix(in srgb, var(--color-text-main) 60%, transparent);
}

/* ── 封面区 (重制版：光盘效果) ── */
.cover-center-area {
  position: relative;
  z-index: 2;
  -webkit-tap-highlight-color: transparent;
}

.dvd-cover-wrap {
  position: relative;
  border-radius: 50%;
  box-shadow: 0 20px 40px -10px rgba(0, 0, 0, 0.5);
  animation: dvd-rotate 24s linear infinite;
  will-change: transform;
}

.dvd-cover-wrap.is-paused {
  animation-play-state: paused;
}

@keyframes dvd-rotate {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}

/* 外围黑胶纹理层 */
.dvd-rim {
  position: absolute;
  inset: -6px; /* 比封面稍大一圈 */
  border-radius: 50%;
  background: linear-gradient(135deg, #111, #333, #111, #444, #111);
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.1), 0 8px 16px rgba(0,0,0,0.4);
  z-index: -1;
}

/* 中间的圆孔 */
.dvd-hole {
  position: absolute;
  top: 50%;
  left: 50%;
  width: 18%; /* 中心孔径比例 */
  height: 18%;
  transform: translate(-50%, -50%);
  border-radius: 50%;
  /* 颜色跟随外部容器以达到镂空的效果 */
  background: var(--color-bg-main); 
  /* 制造内圈边缘的光影和塑料感 */
  box-shadow: 
    inset 0 4px 6px rgba(0,0,0,0.3),
    inset 0 -2px 4px rgba(255,255,255,0.05),
    0 0 0 4px rgba(20,20,20,0.8),
    0 0 0 5px rgba(255,255,255,0.1);
  z-index: 2;
}

/* ── 呼吸封面 ── */
.breathing-cover-wrap {
  position: relative;
  border-radius: 50%;
  border: 1px solid color-mix(in srgb, var(--color-text-main) 10%, transparent);
  animation: breathing 4s ease-in-out infinite;
  will-change: transform, box-shadow;
}

.breathing-cover-wrap.is-paused {
  animation-play-state: paused;
}

@keyframes breathing {
  0% {
    transform: scale(0.98);
    box-shadow: 0 10px 30px -10px rgba(0, 0, 0, 0.4);
  }
  50% {
    transform: scale(1.04);
    box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6);
  }
  100% {
    transform: scale(0.98);
    box-shadow: 0 10px 30px -10px rgba(0, 0, 0, 0.4);
  }
}

/* ── 迷你歌词 ── */
.lyric-mask {
  -webkit-mask-image: linear-gradient(180deg, transparent 0%, rgba(0,0,0,0.8) 20%, black 50%, rgba(0,0,0,0.8) 80%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0%, rgba(0,0,0,0.8) 20%, black 50%, rgba(0,0,0,0.8) 80%, transparent 100%);
  display: flex;
  flex-direction: column;
  align-items: center;
}

.mini-lyric-line {
  font-size: 14px;
  line-height: 1.8;
  font-weight: 500;
  width: 100%;
  text-align: center;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
}

.mini-lyric-line.is-dimmer {
  opacity: 0.15;
  transform: scale(0.9);
  color: var(--color-text-main);
}

.mini-lyric-line.is-dimmer.is-empty {
  visibility: hidden;
}

.mini-lyric-line.is-dim {
  opacity: 0.4;
  transform: scale(0.95);
  color: var(--color-text-main);
}

.mini-lyric-line.is-dim.is-empty {
  visibility: hidden;
}

.mini-lyric-line.is-current {
  font-size: 16px;
  font-weight: 700;
  color: var(--color-primary);
  opacity: 1;
  transform: scale(1);
  margin: 6px 0;
  text-shadow: 0 4px 12px color-mix(in srgb, var(--color-primary) 30%, transparent);
}

.mini-lyric-char {
  color: var(--color-text-main);
  transition: color 0.15s ease;
}

.mini-lyric-char.is-highlighted {
  color: var(--color-primary);
}

/* ── 歌词点击屏蔽层 ── */
.lyric-click-shield {
  height: 32px;
  position: relative;
  z-index: 10;
  flex-shrink: 0;
}

/* ── 大屏歌词区 ── */
.lyric-scroll {
  position: relative;
  z-index: 2;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
  -webkit-mask-image: linear-gradient(180deg, transparent 0%, black 15%, black 85%, transparent 100%);
}

.lyric-scroll::-webkit-scrollbar {
  display: none;
}

.lyric-list {
  padding: 15vh 20px 25vh;
}

.lyric-line {
  padding: 12px 10px;
  cursor: pointer;
  transition: opacity 0.4s ease, transform 0.4s ease;
  opacity: 0.35;
  transform: scale(0.95);
  text-align: center;
}

.lyric-line.is-active {
  opacity: 1;
  transform: scale(1);
}

.lyric-text {
  display: block;
  color: var(--color-text-main);
  line-height: 1.5;
  letter-spacing: 0.5px;
}

.lyric-line.is-active .lyric-text {
  color: var(--color-primary);
}

.lyric-translation {
  display: block;
  color: color-mix(in srgb, var(--color-text-main) 60%, transparent);
  margin-top: 6px;
  line-height: 1.4;
}

/* ── 底部控制区 ── */
.play-controls {
  position: relative;
  z-index: 10;
  background: linear-gradient(to top, var(--color-bg-main) 88%, transparent);
  padding-top: 20px;
  padding-left: 24px;
  padding-right: 24px;
}

/* ── 进度条 ── */
.progress-row {
  display: flex;
  align-items: center;
  gap: 12px;
}

.time-label {
  font-size: 11px;
  font-weight: 600;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  font-variant-numeric: tabular-nums;
  min-width: 40px;
}
.time-label:first-child { text-align: left; }
.time-label:last-child { text-align: right; }

.progress-bar-wrap {
  flex: 1;
  height: 44px;
  display: flex;
  align-items: center;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  touch-action: none;
}

.progress-track {
  position: relative;
  width: 100%;
  height: 4px;
  border-radius: 4px;
  background: color-mix(in srgb, var(--color-text-main) 12%, transparent);
}

.progress-range {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  border-radius: 4px;
  background: var(--color-primary);
  pointer-events: none;
}

.progress-cache {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  border-radius: 4px;
  background: color-mix(in srgb, var(--color-text-main) 20%, transparent);
  pointer-events: none;
  transition: width 0.3s;
}

.progress-thumb {
  position: absolute;
  top: 50%;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--color-primary);
  box-shadow: 0 0 10px color-mix(in srgb, var(--color-primary) 50%, transparent);
  transform: translate(-50%, -50%);
  pointer-events: none;
  transform-origin: center;
}

/* ── 主控制行 ── */
.main-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 10px;
}

.ctrl-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 50px;
  height: 50px;
  border-radius: 50%;
  color: var(--color-text-main);
  -webkit-tap-highlight-color: transparent;
}

.ctrl-play {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 68px;
  height: 68px;
  border-radius: 50%;
  background: var(--color-primary);
  box-shadow: 0 8px 24px color-mix(in srgb, var(--color-primary) 40%, transparent);
  transition: transform 0.2s cubic-bezier(0.4, 0, 0.2, 1);
  -webkit-tap-highlight-color: transparent;
}

.ctrl-play:active {
  transform: scale(0.9);
}

/* ── 附加控制行 ── */
.extra-controls {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 4px;
}

.extra-icon-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  border-radius: 50%;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  -webkit-tap-highlight-color: transparent;
  transition: all 0.2s ease;
  border: none;
  background: transparent;
}

.extra-icon-btn:active {
  transform: scale(0.9);
}

.extra-icon-btn:hover {
  color: var(--color-primary);
}

.extra-icon-btn.is-active {
  color: var(--color-primary);
}

/* ── 动画类 ── */
.animate-fade-in {
  animation: fadeIn 0.4s ease forwards;
}

@keyframes fadeIn {
  from { opacity: 0; transform: translateY(-4px); }
  to { opacity: 1; transform: translateY(0); }
}

/* ── 安全区适配 ── */
.pb-safe {
  padding-bottom: max(16px, calc(env(safe-area-inset-bottom, 0px) + 12px));
}
.pt-safe {
  padding-top: max(8px, env(safe-area-inset-top, 8px));
}
</style>