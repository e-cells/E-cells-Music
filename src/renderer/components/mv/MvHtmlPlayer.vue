<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  iconPlay,
  iconPause,
  iconFullscreen,
  iconExitFullscreen,
  iconX,
} from '@/icons';

const props = withDefaults(
  defineProps<{
    url: string;
    title?: string;
    coverUrl?: string;
    autoplay?: boolean;
  }>(),
  { autoplay: true },
);

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'error', message: string): void;
  (e: 'ended'): void;
}>();

const videoRef = ref<HTMLVideoElement | null>(null);
const containerRef = ref<HTMLDivElement | null>(null);

const isPlaying = ref(false);
const isLoading = ref(true);
const currentTime = ref(0);
const duration = ref(0);
const isSeeking = ref(false);
const isShowingControls = ref(true);
const isFullscreen = ref(false);
const errorMessage = ref('');
let hideTimer: ReturnType<typeof setTimeout> | null = null;

const HIDE_DELAY = 3000;

const formattedCurrent = computed(() => formatTime(currentTime.value));
const formattedDuration = computed(() => formatTime(duration.value));
const progress = computed(() =>
  duration.value > 0 ? (currentTime.value / duration.value) * 1000 : 0,
);

function formatTime(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const total = Math.floor(sec);
  const m = Math.floor(total / 60);
  const s = total % 60;
  if (m >= 60) {
    const h = Math.floor(m / 60);
    const rm = m % 60;
    return `${h}:${String(rm).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }
  return `${m}:${String(s).padStart(2, '0')}`;
}

// ── 控件显隐 ──

function showControls() {
  isShowingControls.value = true;
  cancelHideTimer();
  if (isPlaying.value) scheduleHideTimer();
}

function hideControls() {
  if (isSeeking.value) return;
  isShowingControls.value = false;
}

function scheduleHideTimer() {
  cancelHideTimer();
  hideTimer = setTimeout(hideControls, HIDE_DELAY);
}

function cancelHideTimer() {
  if (hideTimer != null) {
    clearTimeout(hideTimer);
    hideTimer = null;
  }
}

function toggleControls() {
  if (isShowingControls.value) {
    hideControls();
  } else {
    showControls();
  }
}

// ── 播放控制 ──

function togglePlayPause() {
  const v = videoRef.value;
  if (!v) return;
  if (v.paused || v.ended) {
    v.play().catch(() => {});
  } else {
    v.pause();
  }
}

// ── 进度条 ──

function onSeekInput(e: Event) {
  const target = e.target as HTMLInputElement;
  const val = Number(target.value);
  if (duration.value > 0) {
    currentTime.value = (val / 1000) * duration.value;
  }
}

function onSeekStart() {
  isSeeking.value = true;
  cancelHideTimer();
}

function onSeekEnd() {
  isSeeking.value = false;
  const v = videoRef.value;
  if (v && duration.value > 0) {
    const seekBar = document.getElementById('mv-html-seek') as HTMLInputElement | null;
    const val = seekBar ? Number(seekBar.value) : 0;
    v.currentTime = (val / 1000) * duration.value;
  }
  if (isPlaying.value) scheduleHideTimer();
}

// ── 全屏 ──

async function toggleFullscreen() {
  const el = containerRef.value;
  if (!el) return;
  try {
    if (document.fullscreenElement) {
      await document.exitFullscreen();
    } else {
      await el.requestFullscreen();
    }
  } catch {
    /* ignore */
  }
}

function onFullscreenChange() {
  isFullscreen.value = !!document.fullscreenElement;
}

// ── 视频事件 ──

function onPlay() {
  isPlaying.value = true;
  scheduleHideTimer();
}

function onPause() {
  isPlaying.value = false;
  cancelHideTimer();
  isShowingControls.value = true;
}

function onTimeUpdate() {
  if (!isSeeking.value && videoRef.value) {
    currentTime.value = videoRef.value.currentTime;
  }
}

function onDurationChange() {
  if (videoRef.value) {
    duration.value = videoRef.value.duration || 0;
  }
}

function onLoadedData() {
  isLoading.value = false;
}

function onWaiting() {
  isLoading.value = true;
}

function onCanPlay() {
  isLoading.value = false;
}

function onError() {
  isLoading.value = false;
  const msg = '视频加载失败';
  errorMessage.value = msg;
  emit('error', msg);
}

function onEnded() {
  isPlaying.value = false;
  cancelHideTimer();
  isShowingControls.value = true;
  emit('ended');
}

function handleClose() {
  const v = videoRef.value;
  if (v) {
    v.pause();
    v.removeAttribute('src');
    v.load();
  }
  emit('close');
}

// ── 生命周期 ──

onMounted(() => {
  document.addEventListener('fullscreenchange', onFullscreenChange);
});

onBeforeUnmount(() => {
  cancelHideTimer();
  document.removeEventListener('fullscreenchange', onFullscreenChange);
  const v = videoRef.value;
  if (v) {
    v.pause();
    v.removeAttribute('src');
    v.load();
  }
});

watch(
  () => props.url,
  () => {
    isLoading.value = true;
    errorMessage.value = '';
  },
);
</script>

<template>
  <div
    ref="containerRef"
    class="mv-html-player"
    :class="{ 'is-fullscreen': isFullscreen }"
    @mousemove="showControls"
    @touchend="toggleControls"
  >
    <!-- 视频 -->
    <video
      ref="videoRef"
      class="mv-html-video"
      :src="url"
      :poster="coverUrl"
      :autoplay="autoplay"
      playsinline
      preload="metadata"
      @play="onPlay"
      @pause="onPause"
      @timeupdate="onTimeUpdate"
      @durationchange="onDurationChange"
      @loadeddata="onLoadedData"
      @waiting="onWaiting"
      @canplay="onCanPlay"
      @error="onError"
      @ended="onEnded"
      @click.prevent="togglePlayPause"
    />

    <!-- 加载指示器 -->
    <div v-if="isLoading && !errorMessage" class="mv-html-loading">
      <div class="mv-html-spinner"></div>
    </div>

    <!-- 错误提示 -->
    <div v-if="errorMessage" class="mv-html-error">
      <span>{{ errorMessage }}</span>
    </div>

    <!-- 控制条 -->
    <Transition name="mv-html-fade">
      <div v-if="isShowingControls" class="mv-html-controls">
        <!-- 顶部：标题 + 关闭 -->
        <div class="mv-html-controls-top">
          <span class="mv-html-title">{{ title }}</span>
          <button type="button" class="mv-html-btn" @click.stop="handleClose">
            <Icon :icon="iconX" width="20" height="20" />
          </button>
        </div>

        <!-- 中间：播放按钮 -->
        <button
          v-if="!isLoading && !errorMessage"
          type="button"
          class="mv-html-center-btn"
          @click.stop="togglePlayPause"
        >
          <Icon
            :icon="isPlaying ? iconPause : iconPlay"
            width="36"
            height="36"
          />
        </button>

        <!-- 底部：进度条 + 时间 + 全屏 -->
        <div class="mv-html-controls-bottom">
          <div class="mv-html-progress-wrap">
            <input
              id="mv-html-seek"
              type="range"
              class="mv-html-seek"
              min="0"
              max="1000"
              :value="progress"
              @input="onSeekInput"
              @mousedown="onSeekStart"
              @touchstart="onSeekStart"
              @mouseup="onSeekEnd"
              @touchend="onSeekEnd"
            />
          </div>
          <div class="mv-html-time-row">
            <span class="mv-html-time">{{ formattedCurrent }} / {{ formattedDuration }}</span>
            <button type="button" class="mv-html-btn" @click.stop="toggleFullscreen">
              <Icon
                :icon="isFullscreen ? iconExitFullscreen : iconFullscreen"
                width="18"
                height="18"
              />
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.mv-html-player {
  position: relative;
  width: 100%;
  aspect-ratio: 16 / 9;
  max-height: 360px;
  overflow: hidden;
  background: #000;
  user-select: none;
}

.mv-html-player.is-fullscreen {
  max-height: none;
  width: 100vw;
  height: 100vh;
  aspect-ratio: unset;
}

.mv-html-video {
  width: 100%;
  height: 100%;
  object-fit: contain;
  display: block;
}

/* 加载 */
.mv-html-loading {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}

.mv-html-spinner {
  width: 36px;
  height: 36px;
  border: 3px solid rgba(255, 255, 255, 0.2);
  border-top-color: rgba(255, 255, 255, 0.9);
  border-radius: 50%;
  animation: mv-html-spin 0.8s linear infinite;
}

@keyframes mv-html-spin {
  to { transform: rotate(360deg); }
}

/* 错误 */
.mv-html-error {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255, 255, 255, 0.8);
  font-size: 14px;
  pointer-events: none;
}

/* 控制条整体 */
.mv-html-controls {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  pointer-events: none;
}

.mv-html-controls > * {
  pointer-events: auto;
}

/* 顶部 */
.mv-html-controls-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 12px;
  background: linear-gradient(to bottom, rgba(0, 0, 0, 0.6), transparent);
}

.mv-html-title {
  font-size: 14px;
  font-weight: 600;
  color: #fff;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
  margin-right: 8px;
}

/* 中间播放按钮 */
.mv-html-center-btn {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  align-items: center;
  justify-content: center;
  width: 56px;
  height: 56px;
  border-radius: 50%;
  border: none;
  background: rgba(255, 255, 255, 0.15);
  color: #fff;
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
  cursor: pointer;
  transition: all 0.2s ease;
}

.mv-html-center-btn:hover {
  background: rgba(255, 255, 255, 0.3);
  transform: translate(-50%, -50%) scale(1.08);
}

/* 底部 */
.mv-html-controls-bottom {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 0 12px 10px;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.7), transparent);
}

.mv-html-progress-wrap {
  width: 100%;
  height: 20px;
  display: flex;
  align-items: center;
}

.mv-html-seek {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: 4px;
  border-radius: 2px;
  background: rgba(255, 255, 255, 0.25);
  outline: none;
  cursor: pointer;
}

.mv-html-seek::-webkit-slider-thumb {
  -webkit-appearance: none;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--color-primary, #1db954);
  cursor: pointer;
}

.mv-html-seek::-moz-range-thumb {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--color-primary, #1db954);
  border: none;
  cursor: pointer;
}

.mv-html-time-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.mv-html-time {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.75);
  font-variant-numeric: tabular-nums;
}

.mv-html-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  background: none;
  border: none;
  color: rgba(255, 255, 255, 0.85);
  cursor: pointer;
  padding: 4px;
  border-radius: 4px;
  transition: color 0.15s;
}

.mv-html-btn:hover {
  color: #fff;
}

/* 过渡 */
.mv-html-fade-enter-active,
.mv-html-fade-leave-active {
  transition: opacity 0.25s ease;
}

.mv-html-fade-enter-from,
.mv-html-fade-leave-to {
  opacity: 0;
}
</style>
