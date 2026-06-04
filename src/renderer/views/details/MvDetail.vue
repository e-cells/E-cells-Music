<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { getSongMv, getVideoDetail, getVideoPrivilege, getVideoUrl } from '@/api/video';
import { formatDate, formatDuration, formatPlayCount } from '@/utils/format';
import { useToastStore } from '@/stores/toast';
import type { VideoMeta, VideoSource } from '@/models/video';
import Image from '@/components/ui/Image.vue';
import {
  extractVideoUrl,
  mapVideoMeta,
  mapVideoMetaList,
  mapVideoSourcesFromPrivilege,
  mergeVideoSources,
} from '@/utils/mappers/video';
import { usePlayerStore } from '@/stores/player';
import { useSettingStore } from '@/stores/setting';
import { iconFullscreen, iconExitFullscreen, iconPlay, iconPause } from '@/icons';

// 引入 Native 桥接工具与物理返回键拦截钩子
import { isGeckoView, NativeOrientationBridge, NativeDecoderBridge } from '@/utils/nativeBridge';
import { useHardwareBack } from '@/composables/useHardwareBack';

const route = useRoute();
const toastStore = useToastStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();

const videoRef = ref<HTMLVideoElement | null>(null);
const loading = ref(false);
const sourceLoading = ref(false);
const meta = ref<VideoMeta | null>(null);
const mvVersions = ref<VideoMeta[]>([]);
const currentVersionIndex = ref(0);
const currentSourceHash = ref('');
const currentVideoUrl = ref('');
const playbackError = ref('');

// === 伪全屏状态控制 ===
const isPseudoFullscreen = ref(false);

const togglePseudoFullscreen = async () => {
  const isMobileNative = isGeckoView || /Android/i.test(navigator.userAgent);
  if (isPseudoFullscreen.value) {
    // 退出伪全屏
    isPseudoFullscreen.value = false;
    document.documentElement.style.overflow = '';
    if (isMobileNative) {
      void NativeOrientationBridge.setFullScreen(false);
      void NativeOrientationBridge.setOrientation(settingStore.screenOrientation);
    }
  } else {
    // 进入伪全屏：先调用原生 API 强制横屏，等待生效后再应用 CSS 全屏
    if (isMobileNative) {
      void NativeOrientationBridge.setFullScreen(true);
      void NativeOrientationBridge.setOrientation('landscape');
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
    isPseudoFullscreen.value = true;
    document.documentElement.style.overflow = 'hidden';
  }
};

// === 自定义控制栏（Android 端） ===
const showControls = ref(true);
let controlsTimer: ReturnType<typeof setTimeout> | null = null;
const currentTime = ref(0);
const duration = ref(0);
const progressBarRef = ref<HTMLDivElement | null>(null);
const isDragging = ref(false);

const formatTime = (seconds: number): string => {
  if (!isFinite(seconds) || seconds < 0) return '0:00';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
};

const progressPercent = computed(() => {
  if (duration.value <= 0) return 0;
  return (currentTime.value / duration.value) * 100;
});

const handleTimeUpdateForControls = () => {
  if (!isDragging.value && videoRef.value) {
    currentTime.value = videoRef.value.currentTime;
    duration.value = videoRef.value.duration || 0;
  }
};

const handleLoadedMetadata = () => {
  if (videoRef.value) {
    duration.value = videoRef.value.duration || 0;
  }
};

const resetControlsTimer = () => {
  showControls.value = true;
  if (controlsTimer) clearTimeout(controlsTimer);
  controlsTimer = setTimeout(() => {
    if (videoRef.value && !videoRef.value.paused) {
      showControls.value = false;
    }
  }, 3000);
};

const toggleVideoPlay = (e?: Event) => {
  e?.stopPropagation();
  const video = videoRef.value;
  if (!video || loading.value || sourceLoading.value) return;
  if (video.paused) {
    video.play().catch(() => {});
  } else {
    video.pause();
  }
};

const getProgressFromEvent = (e: MouseEvent | TouchEvent): number => {
  const el = progressBarRef.value;
  if (!el) return 0;
  const rect = el.getBoundingClientRect();
  const clientX = 'touches' in e ? e.touches[0]?.clientX ?? e.changedTouches[0]?.clientX : e.clientX;
  if (clientX === undefined) return 0;
  const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  return ratio * (duration.value || 0);
};

const applySeek = (time: number) => {
  const video = videoRef.value;
  if (!video) return;
  video.currentTime = time;
  currentTime.value = time;
};

const handleProgressPointerDown = (e: MouseEvent | TouchEvent) => {
  e.preventDefault();
  isDragging.value = true;
  const time = getProgressFromEvent(e);
  applySeek(time);
  resetControlsTimer();
};

const handleProgressPointerMove = (e: MouseEvent | TouchEvent) => {
  if (!isDragging.value) return;
  const time = getProgressFromEvent(e);
  currentTime.value = time;
};

const handleProgressPointerUp = (e: MouseEvent | TouchEvent) => {
  if (!isDragging.value) return;
  isDragging.value = false;
  const time = getProgressFromEvent(e);
  applySeek(time);
};

const cleanupDragListeners = () => {
  isDragging.value = false;
  document.removeEventListener('mousemove', handleProgressPointerMove);
  document.removeEventListener('mouseup', handleProgressPointerUp);
  document.removeEventListener('touchmove', handleProgressPointerMove);
  document.removeEventListener('touchend', handleProgressPointerUp);
};

const setupDragListeners = () => {
  document.addEventListener('mousemove', handleProgressPointerMove);
  document.addEventListener('mouseup', handleProgressPointerUp);
  document.addEventListener('touchmove', handleProgressPointerMove, { passive: false });
  document.addEventListener('touchend', handleProgressPointerUp);
};

// === 解码能力检测 ===
const decoderCapabilities = ref<string[]>([]);

const fetchDecoderCapabilities = async () => {
  if (!isGeckoView) return;
  try {
    const result = await NativeDecoderBridge.getCapabilities();
    if (result?.codecs?.length) {
      decoderCapabilities.value = result.codecs;
    }
  } catch {
    // 检测失败时使用默认兼容策略
  }
};

const compatibleSources = computed(() => {
  const sources = meta.value?.sources ?? [];
  if (!decoderCapabilities.value.length) return sources;
  return sources.filter((s) => s.codec && decoderCapabilities.value.includes(s.codec));
});

const routeHash = computed(() => String(route.query.hash ?? route.params.id ?? '').trim());
const routeVideoId = computed(() => String(route.query.videoId ?? route.params.id ?? '').trim());
const routeAlbumAudioId = computed(() =>
  String(route.query.albumAudioId ?? route.query.mixSongId ?? '').trim(),
);

const fallbackTitle = computed(() => String(route.query.title ?? 'MV播放'));
const fallbackArtist = computed(() => String(route.query.artist ?? ''));
const fallbackCover = computed(() => String(route.query.cover ?? ''));

const title = computed(() => meta.value?.title || fallbackTitle.value || 'MV播放');
const cover = computed(() => meta.value?.coverUrl || fallbackCover.value || '');
const authorLine = computed(() => {
  const authors = meta.value?.authors?.map((item) => item.name).filter(Boolean) ?? [];
  if (authors.length > 0) return authors.join(' / ');
  return meta.value?.artistName || fallbackArtist.value || '未知歌手';
});
const tagList = computed(() => meta.value?.tags?.map((item) => item.name).filter(Boolean) ?? []);
const sourceList = computed(() => meta.value?.sources ?? []);

const hasPrevVersion = computed(() => currentVersionIndex.value > 0);
const hasNextVersion = computed(() => currentVersionIndex.value < mvVersions.value.length - 1);
const authorList = computed(() => meta.value?.authors ?? []);
const primaryAuthor = computed(() => authorList.value[0] ?? null);
const hasDescription = computed(() => Boolean(meta.value?.description?.trim()));
const editionList = computed(() => {
  const items = [meta.value?.topic, meta.value?.remark]
    .map((item) => String(item ?? '').trim())
    .filter(Boolean);
  return [...new Set(items)];
});
const stats = computed(() => [
  { label: '播放量', value: formatPlayCount(meta.value?.playCount) },
  { label: '时长', value: formatDuration(meta.value?.duration) },
  { label: '收藏', value: formatPlayCount(meta.value?.collectionCount) },
  { label: '下载', value: formatPlayCount(meta.value?.downloadCount) },
]);
const publishText = computed(() =>
  meta.value?.publishTime ? formatDate(meta.value.publishTime) : '未知',
);

const buildInitialMeta = (): VideoMeta => ({
  id: routeVideoId.value || routeHash.value,
  hash: routeHash.value,
  title: fallbackTitle.value || 'MV播放',
  coverUrl: fallbackCover.value,
  duration: 0,
  artistName: fallbackArtist.value,
  authors: fallbackArtist.value
    ? fallbackArtist.value
        .split(/[,/，]/)
        .map((item) => item.trim())
        .filter(Boolean)
        .map((name) => ({ name }))
    : [],
  tags: [],
  sources: routeHash.value ? [{ hash: routeHash.value, url: '', label: '默认', codec: '' }] : [],
});

const mergeMeta = (nextMeta: VideoMeta | null) => {
  if (!nextMeta) return;
  const current = meta.value ?? buildInitialMeta();
  meta.value = {
    ...current,
    ...nextMeta,
    title: nextMeta.title || current.title,
    coverUrl: nextMeta.coverUrl || current.coverUrl,
    description: nextMeta.description || current.description,
    remark: nextMeta.remark || current.remark,
    topic: nextMeta.topic || current.topic,
    artistName: nextMeta.artistName || current.artistName,
    albumName: nextMeta.albumName || current.albumName,
    authors: nextMeta.authors?.length ? nextMeta.authors : current.authors,
    tags: nextMeta.tags?.length ? nextMeta.tags : current.tags,
    sources: mergeVideoSources(current.sources ?? [], nextMeta.sources ?? []),
    duration: nextMeta.duration || current.duration,
    playCount: nextMeta.playCount ?? current.playCount,
    publishTime: nextMeta.publishTime ?? current.publishTime,
    collectionCount: nextMeta.collectionCount ?? current.collectionCount,
    downloadCount: nextMeta.downloadCount ?? current.downloadCount,
    hotScore: nextMeta.hotScore ?? current.hotScore,
    recommend: nextMeta.recommend ?? current.recommend,
  };
};

// 车机环境优先选 H.264 编码片源（兼容性最好）
const isMobileNative = isGeckoView || /Android/i.test(navigator.userAgent);

const pickPreferredSource = (sources: VideoSource[]): VideoSource | null => {
  if (!sources.length) return null;
  if (isMobileNative) {
    const h264 = sources.find((s) => s.codec === 'H.264');
    if (h264) return h264;
  }
  return sources[0];
};

const syncCurrentSource = () => {
  if (!meta.value) return;
  const sources = meta.value.sources ?? [];

  // 如果当前 hash 仍在可用片源中，检查是否需要升级到 H.264
  if (currentSourceHash.value && sources.some((s) => s.hash === currentSourceHash.value)) {
    if (!isMobileNative) return;
    const current = sources.find((s) => s.hash === currentSourceHash.value);
    // 车机环境：当前是 H.265 且有 H.264 替代品时自动切换
    if (current?.codec === 'H.265') {
      const h264 = sources.find((s) => s.codec === 'H.264');
      if (h264) {
        currentSourceHash.value = h264.hash;
        return;
      }
    }
    return;
  }

  const target = pickPreferredSource(sources);
  currentSourceHash.value = target?.hash ?? '';
};

const pauseMusicPlayback = async () => {
  if (!playerStore.isPlaying) return;
  await playerStore.togglePlay().catch(() => undefined);
};

// === 视频加载：防止并发，旧调用自动作废 ===
let loadVideoGeneration = 0;

const loadVideoUrl = async (hash: string) => {
  if (!hash) return;
  const gen = ++loadVideoGeneration;
  sourceLoading.value = true;
  playbackError.value = '';
  decodeCheckDone = false;

  let decodeTimeout: ReturnType<typeof setTimeout> | null = null;

  try {
    const response = await getVideoUrl(hash);
    if (gen !== loadVideoGeneration) return;
    const url = extractVideoUrl(response, hash, isMobileNative);
    if (!url) throw new Error('empty-url');
    currentVideoUrl.value = url;
    await nextTick();
    if (gen !== loadVideoGeneration) return;
    if (videoRef.value) {
      await pauseMusicPlayback();
      videoRef.value.load();
      // 解码快速探测：2 秒内无画面则自动降级
      if (isMobileNative) {
        decodeTimeout = setTimeout(() => {
          if (gen !== loadVideoGeneration) return;
          const v = videoRef.value;
          if (v && v.videoWidth === 0 && v.videoHeight === 0 && !playbackError.value) {
            handleVideoError();
          }
        }, 2000);
      }
      await videoRef.value.play().catch(() => undefined);
    }
  } catch {
    if (gen !== loadVideoGeneration) return;
    currentVideoUrl.value = '';
    playbackError.value = '当前视频暂时无法播放';
    toastStore.loadFailed('MV');
  } finally {
    if (decodeTimeout) clearTimeout(decodeTimeout);
    if (gen === loadVideoGeneration) {
      sourceLoading.value = false;
    }
  }
};

const applySources = (sources: VideoSource[]) => {
  if (!sources.length) return;
  meta.value = {
    ...(meta.value ?? buildInitialMeta()),
    sources: mergeVideoSources(meta.value?.sources ?? [], sources),
  };
  syncCurrentSource();
};

const applyVersion = (nextMeta: VideoMeta) => {
  const sources = nextMeta.sources ?? [];
  meta.value = {
    ...buildInitialMeta(),
    ...nextMeta,
    sources,
  };
  currentSourceHash.value = pickPreferredSource(sources)?.hash ?? nextMeta.hash ?? '';
  currentVideoUrl.value = '';
  playbackError.value = '';
  failedSourceHashes.value.clear();
};

const fetchMvMeta = async () => {
  loading.value = true;
  meta.value = buildInitialMeta();
  mvVersions.value = [];
  currentVersionIndex.value = 0;
  failedSourceHashes.value.clear();
  try {
    const tasks: Promise<unknown>[] = [];
    if (routeAlbumAudioId.value) tasks.push(getSongMv(routeAlbumAudioId.value));
    if (routeVideoId.value && routeVideoId.value !== routeHash.value)
      tasks.push(getVideoDetail(routeVideoId.value));
    if (routeHash.value) tasks.push(getVideoPrivilege(routeHash.value));

    const results = await Promise.allSettled(tasks);
    for (const result of results) {
      if (result.status !== 'fulfilled') continue;
      const payload = result.value;
      const versionList = mapVideoMetaList(payload);
      if (versionList.length > 0) {
        mvVersions.value = versionList;
        currentVersionIndex.value = 0;
        applyVersion(versionList[0]);
      }
      mergeMeta(mapVideoMeta(payload, routeHash.value));
      applySources(mapVideoSourcesFromPrivilege(payload));
    }

    syncCurrentSource();
    if (routeHash.value && !currentSourceHash.value) {
      currentSourceHash.value = routeHash.value;
    }
  } finally {
    loading.value = false;
  }
};

// === 解码失败自动降级 ===
const failedSourceHashes = ref(new Set<string>());
let decodeCheckDone = false;

const handleVideoError = () => {
  failedSourceHashes.value.add(currentSourceHash.value);

  const sources = meta.value?.sources ?? [];
  // 优先切换到不同编解码器的片源（如 H.265 → H.264），跳过同编解码器的低分辨率
  const currentSource = sources.find((s) => s.hash === currentSourceHash.value);
  const currentCodec = currentSource?.codec;
  const differentCodec = sources.find(
    (s) => !failedSourceHashes.value.has(s.hash) && s.codec !== currentCodec,
  );
  const nextSource = differentCodec ?? sources.find((s) => !failedSourceHashes.value.has(s.hash));

  if (nextSource) {
    toastStore.show(`当前片源播放失败，正在切换到 ${nextSource.label}${nextSource.codec ? ` ${nextSource.codec}` : ''}...`);
    changeSource(nextSource.hash);
  } else {
    playbackError.value = '视频解码失败，所有片源均无法播放';
  }
};

// 检测"有进度条无画面"：H.265 在不支持的车机上会播放音频但 videoWidth 永远为 0
const handleVideoTimeUpdate = () => {
  // 正在加载新片源时跳过，避免旧视频事件的竞态误判
  if (decodeCheckDone || sourceLoading.value) return;
  const video = videoRef.value;
  if (!video || video.currentTime <= 0) return;

  decodeCheckDone = true;

  // 有播放进度但视频帧尺寸为 0 → 编解码器不支持
  if (video.videoWidth === 0 || video.videoHeight === 0) {
    handleVideoError();
  }
};

const changeSource = (hash: string) => {
  if (!hash || hash === currentSourceHash.value) return;
  currentSourceHash.value = hash;
  decodeCheckDone = false;
};

const handleVideoPlay = () => {
  void pauseMusicPlayback();
};

const destroyVideoPlayer = () => {
  const video = videoRef.value;
  if (!video) return;
  video.pause();
  video.removeAttribute('src');
  video.load();
  currentVideoUrl.value = '';
};

const switchVersion = (offset: -1 | 1) => {
  const nextIndex = currentVersionIndex.value + offset;
  if (nextIndex < 0 || nextIndex >= mvVersions.value.length) return;
  const nextMeta = mvVersions.value[nextIndex];
  if (!nextMeta) return;
  currentVersionIndex.value = nextIndex;
  applyVersion(nextMeta);
};

// === 增强：处理物理返回键（伪全屏时拦截） ===
useHardwareBack(isPseudoFullscreen, () => {
  togglePseudoFullscreen();
  return true; // 拦截路由返回
});

// === 增强：处理 App 切换到后台的自动暂停 ===
const handleVisibilityChange = () => {
  if (document.hidden && videoRef.value && !videoRef.value.paused) {
    videoRef.value.pause(); 
  }
};


onMounted(async () => {
  meta.value = buildInitialMeta();
  await fetchMvMeta();

  // 挂载可见性监听（App 切换到后台时自动暂停）
  document.addEventListener('visibilitychange', handleVisibilityChange);

  // 检测设备视频解码能力
  void fetchDecoderCapabilities();

  // 进度条拖拽全局监听
  if (isMobileNative) setupDragListeners();
});

onBeforeUnmount(() => {
  destroyVideoPlayer();

  // 清除控制栏定时器与拖拽监听
  if (controlsTimer) clearTimeout(controlsTimer);
  cleanupDragListeners();

  // 退出伪全屏（如果激活）
  if (isPseudoFullscreen.value) {
    isPseudoFullscreen.value = false;
    document.documentElement.style.overflow = '';
    const isMobileNative = isGeckoView || /Android/i.test(navigator.userAgent);
    if (isMobileNative) {
      void NativeOrientationBridge.setFullScreen(false);
      void NativeOrientationBridge.setOrientation(settingStore.screenOrientation);
    }
  }

  document.removeEventListener('visibilitychange', handleVisibilityChange);
});

watch(
  () => currentSourceHash.value,
  (hash) => {
    if (!hash) return;
    void loadVideoUrl(hash);
  },
  { immediate: true },
);
</script>

<template>
  <div class="mv-page bg-bg-main min-h-full">
    <div class="mv-player-wrap">
      <div class="mv-player-box" :class="{ 'is-pseudo-fullscreen': isPseudoFullscreen }" @mousemove="isMobileNative ? resetControlsTimer() : undefined" @touchstart="isMobileNative ? resetControlsTimer() : undefined">
        <video
          ref="videoRef"
          class="mv-video"
          :controls="!isMobileNative"
          preload="metadata"
          playsinline
          :poster="cover"
          @play="handleVideoPlay"
          @error="handleVideoError"
          @timeupdate="handleVideoTimeUpdate; handleTimeUpdateForControls()"
          @loadedmetadata="handleLoadedMetadata"
        >
          <source v-if="currentVideoUrl" :src="currentVideoUrl" />
        </video>

        <div v-if="loading || sourceLoading" class="mv-overlay-state">
          <div class="mv-loading-spinner"></div>
          <span>{{ sourceLoading ? '正在切换片源...' : '正在加载 MV ...' }}</span>
        </div>

        <div v-else-if="!currentVideoUrl" class="mv-overlay-state">
          <span>{{ playbackError || '暂无可播放的视频' }}</span>
        </div>

        <button
          type="button"
          class="mv-fullscreen-btn"
          @click.stop="togglePseudoFullscreen"
        >
          <Icon :icon="isPseudoFullscreen ? iconExitFullscreen : iconFullscreen" width="20" height="20" />
        </button>

        <div v-if="isMobileNative" class="mv-controls" :class="{ 'mv-controls--hidden': !showControls }">
          <button type="button" class="mv-ctrl-play" @click.stop="toggleVideoPlay">
            <Icon :icon="videoRef?.paused ? iconPlay : iconPause" width="20" height="20" />
          </button>
          <div
            ref="progressBarRef"
            class="mv-ctrl-progress"
            @mousedown.prevent="handleProgressPointerDown"
            @touchstart.prevent="handleProgressPointerDown"
          >
            <div class="mv-ctrl-progress-track">
              <div class="mv-ctrl-progress-fill" :style="{ width: progressPercent + '%' }"></div>
              <div
                class="mv-ctrl-progress-thumb"
                :class="{ 'mv-ctrl-progress-thumb--active': isDragging }"
                :style="{ left: progressPercent + '%' }"
              ></div>
            </div>
          </div>
          <span class="mv-ctrl-time">{{ formatTime(currentTime) }} / {{ formatTime(duration) }}</span>
        </div>
      </div>
    </div>

    <div class="mv-detail-wrap">
      <section class="card-block card-block--hero">
        <div class="mv-main-head">
          <div class="mv-cover-thumb">
            <Image :src="cover" :alt="title" class="mv-cover-img" />
          </div>
          <div class="mv-title-block">
            <div v-if="meta?.recommend" class="mv-recommend">推荐版本</div>
            <h1 class="mv-title">{{ title }}</h1>
            <div class="mv-meta-line">
              <Image
                v-if="primaryAuthor?.avatar"
                :src="primaryAuthor.avatar"
                :alt="authorLine"
                class="mv-inline-author-avatar"
              />
              <span class="mv-author">{{ authorLine }}</span>
              <span class="mv-meta-separator">·</span>
              <span class="mv-submeta">发布于 {{ publishText }}</span>
            </div>
          </div>

          <div v-if="mvVersions.length > 1" class="mv-version-switcher">
            <button
              type="button"
              class="mv-version-button"
              :disabled="!hasPrevVersion"
              @click="switchVersion(-1)"
            >
              上一版
            </button>
            <div class="mv-version-index">
              {{ currentVersionIndex + 1 }} / {{ mvVersions.length }}
            </div>
            <button
              type="button"
              class="mv-version-button"
              :disabled="!hasNextVersion"
              @click="switchVersion(1)"
            >
              下一版
            </button>
          </div>
        </div>

        <div class="mv-stat-grid">
          <div v-for="item in stats" :key="item.label" class="mv-stat-item">
            <div class="mv-stat-label">{{ item.label }}</div>
            <div class="mv-stat-value">{{ item.value }}</div>
          </div>
        </div>

        <div v-if="editionList.length" class="mv-tags mv-tags--edition">
          <span v-for="item in editionList" :key="item" class="mv-tag mv-tag--edition">{{
            item
          }}</span>
        </div>

        <div v-if="tagList.length" class="mv-tags">
          <span v-for="tag in tagList" :key="tag" class="mv-tag">{{ tag }}</span>
        </div>

        <div v-if="hasDescription" class="mv-description">{{ meta?.description }}</div>
      </section>

      <section class="card-block">
        <div class="section-title">视频片源</div>
        <div class="mv-source-list">
          <button
            v-for="source in sourceList"
            :key="source.hash"
            type="button"
            class="mv-source-card"
            :class="{ 'is-active': source.hash === currentSourceHash }"
            @click="changeSource(source.hash)"
          >
            <div class="mv-source-row">
              <div class="mv-source-main">
                <div class="mv-source-copy">
                  <div class="mv-source-title">{{ source.label }}</div>
                  <div class="mv-source-badges">
                    <span v-if="source.codec" class="mv-source-badge">{{ source.codec }}</span>
                    <span v-if="source.width && source.height" class="mv-source-badge"
                      >{{ source.width }}×{{ source.height }}</span
                    >
                    <span v-if="source.bitrate" class="mv-source-badge"
                      >{{ Math.round(source.bitrate / 1000) }} kbps</span
                    >
                    <span v-if="source.size" class="mv-source-badge"
                      >{{ (source.size / 1024 / 1024).toFixed(1) }} MB</span
                    >
                  </div>
                </div>
              </div>
              <div class="mv-source-status">
                {{ source.hash === currentSourceHash ? '当前播放' : '切换' }}
              </div>
            </div>
          </button>

          <div v-if="!sourceList.length && !loading" class="mv-empty-hint">暂无更多片源</div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.mv-player-wrap,
.mv-detail-wrap {
  width: min(1120px, calc(100% - 32px));
  margin: 0 auto;
}

.mv-player-wrap {
  padding-top: 16px;
}

.mv-player-box {
  position: relative;
  overflow: hidden;
  aspect-ratio: 16 / 9;
  border-radius: 18px;
  background: #000;
}

.mv-video {
  width: 100%;
  height: 100%;
  object-fit: contain;
  background: #000;
}

/* === 全屏切换按钮 === */
.mv-fullscreen-btn {
  position: absolute;
  top: auto;
  bottom: 50px;
  right: 10px;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 10px;
  border: none;
  background: rgba(0, 0, 0, 0.45);
  color: rgba(255, 255, 255, 0.9);
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.2s ease, background 0.2s ease;
  backdrop-filter: blur(6px);
  -webkit-backdrop-filter: blur(6px);
}

.mv-player-box:hover .mv-fullscreen-btn,
.mv-fullscreen-btn:focus-visible {
  opacity: 1;
}

.mv-fullscreen-btn:hover {
  background: rgba(0, 0, 0, 0.65);
}

/* === CSS 伪全屏核心样式 === */
.mv-player-box.is-pseudo-fullscreen {
  position: fixed;
  inset: 0;
  z-index: 10000;
  width: 100vw;
  height: 100vh;
  border-radius: 0;
  margin: 0;
  background: #000;
}

/* 伪全屏时按钮始终可见，尺寸更大 */
.mv-player-box.is-pseudo-fullscreen .mv-fullscreen-btn {
  opacity: 1;
  top: auto;
  bottom: 56px;
  right: 16px;
  width: 42px;
  height: 42px;
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.12);
}

.mv-player-box.is-pseudo-fullscreen .mv-fullscreen-btn:hover {
  background: rgba(255, 255, 255, 0.22);
}

/* === 自定义控制栏（Android 端） === */
.mv-controls {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  z-index: 5;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 14px;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.75));
  opacity: 1;
  transition: opacity 0.3s ease;
}

.mv-controls--hidden {
  opacity: 0;
  pointer-events: none;
}

.mv-ctrl-play {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  border-radius: 8px;
  border: none;
  background: rgba(255, 255, 255, 0.12);
  color: rgba(255, 255, 255, 0.92);
  cursor: pointer;
  flex-shrink: 0;
  -webkit-tap-highlight-color: transparent;
}

.mv-ctrl-play:active {
  background: rgba(255, 255, 255, 0.2);
}

.mv-ctrl-progress {
  flex: 1;
  min-width: 0;
  height: 28px;
  display: flex;
  align-items: center;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}

.mv-ctrl-progress-track {
  position: relative;
  width: 100%;
  height: 4px;
  border-radius: 2px;
  background: rgba(255, 255, 255, 0.2);
}

.mv-ctrl-progress-fill {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  border-radius: 2px;
  background: rgba(255, 255, 255, 0.85);
  transition: width 0.1s linear;
}

.mv-ctrl-progress-thumb {
  position: absolute;
  top: 50%;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: #fff;
  transform: translate(-50%, -50%);
  opacity: 0;
  transition: opacity 0.15s ease;
}

.mv-ctrl-progress-thumb--active,
.mv-ctrl-progress:hover .mv-ctrl-progress-thumb {
  opacity: 1;
}

.mv-ctrl-time {
  font-size: 12px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.75);
  white-space: nowrap;
  flex-shrink: 0;
}

/* 全屏模式下控制栏样式调整 */
.mv-player-box.is-pseudo-fullscreen .mv-controls {
  padding: 14px 20px;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.8));
}

.mv-player-box.is-pseudo-fullscreen .mv-ctrl-play {
  width: 38px;
  height: 38px;
  border-radius: 10px;
}

.mv-player-box.is-pseudo-fullscreen .mv-ctrl-progress {
  height: 32px;
}

.mv-player-box.is-pseudo-fullscreen .mv-ctrl-progress-track {
  height: 5px;
  border-radius: 3px;
}

.mv-player-box.is-pseudo-fullscreen .mv-ctrl-progress-thumb {
  width: 14px;
  height: 14px;
}

.mv-overlay-state {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  color: rgba(255, 255, 255, 0.84);
  background: rgba(0, 0, 0, 0.36);
  backdrop-filter: blur(6px);
}

.mv-loading-spinner {
  width: 28px;
  height: 28px;
  border: 3px solid rgba(255, 255, 255, 0.18);
  border-top-color: rgba(255, 255, 255, 0.92);
  border-radius: 999px;
  animation: mv-spin 0.9s linear infinite;
}

.mv-detail-wrap {
  padding: 18px 0 28px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.card-block {
  padding: 18px;
  border-radius: 18px;
  background: var(--color-bg-card);
  border: 1px solid color-mix(in srgb, var(--color-border-light) 80%, transparent);
}

.card-block--hero {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.mv-main-head {
  display: flex;
  gap: 14px;
  align-items: center;
}

.mv-cover-thumb {
  width: 96px;
  height: 96px;
  overflow: hidden;
  border-radius: 14px;
  flex-shrink: 0;
}

.mv-cover-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.mv-title-block {
  min-width: 0;
  flex: 1;
}

.mv-version-switcher {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
  align-self: flex-start;
}

.mv-version-button {
  height: 34px;
  padding: 0 12px;
  border-radius: 999px;
  border: 1px solid color-mix(in srgb, var(--color-border-light) 80%, transparent);
  background: var(--bg-info-card);
  color: var(--color-text-main);
  font-size: 12px;
  font-weight: 700;
  transition: all 0.18s ease;
}

.mv-version-button:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.mv-version-index {
  min-width: 52px;
  text-align: center;
  font-size: 12px;
  font-weight: 700;
  color: var(--color-text-secondary);
}

.mv-recommend {
  display: inline-flex;
  align-items: center;
  height: 24px;
  padding: 0 8px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--color-primary) 12%, transparent);
  color: var(--color-primary);
  font-size: 11px;
  font-weight: 700;
}

.mv-title {
  margin-top: 6px;
  font-size: 24px;
  font-weight: 800;
  color: var(--color-text-main);
  line-height: 1.3;
}

.mv-author {
  font-size: 14px;
  font-weight: 700;
  color: var(--color-text-main);
}

.mv-meta-line {
  margin-top: 8px;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.mv-inline-author-avatar {
  width: 24px;
  height: 24px;
  border-radius: 999px;
  flex-shrink: 0;
}

.mv-meta-separator {
  color: var(--color-text-secondary);
  font-size: 13px;
}

.mv-submeta {
  font-size: 13px;
  color: var(--color-text-secondary);
}

.mv-stat-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px;
}

.mv-stat-item {
  padding: 14px;
  border-radius: 14px;
  background: var(--bg-info-card);
}

.mv-stat-label {
  font-size: 12px;
  color: var(--color-text-secondary);
}

.mv-stat-value {
  margin-top: 6px;
  font-size: 15px;
  font-weight: 800;
  color: var(--color-text-main);
}

.mv-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.mv-tags--edition {
  margin-top: -2px;
}

.mv-tag {
  display: inline-flex;
  align-items: center;
  height: 28px;
  padding: 0 10px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--color-primary) 10%, transparent);
  color: var(--color-primary);
  font-size: 12px;
  font-weight: 700;
}

.mv-tag--edition {
  background: color-mix(in srgb, var(--color-text-main) 6%, transparent);
  color: var(--color-text-main);
}

.mv-description {
  font-size: 13px;
  line-height: 1.8;
  color: var(--color-text-secondary);
}

.section-title {
  margin-bottom: 14px;
  font-size: 15px;
  font-weight: 800;
  color: var(--color-text-main);
}

.mv-source-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.mv-source-card {
  padding: 14px 16px;
  border-radius: 14px;
  border: 1px solid color-mix(in srgb, var(--color-border-light) 80%, transparent);
  background: var(--bg-info-card);
  text-align: left;
  transition:
    border-color 0.18s ease,
    background 0.18s ease;
}

.mv-source-card.is-active {
  border-color: color-mix(in srgb, var(--color-primary) 60%, transparent);
  background: color-mix(in srgb, var(--color-primary) 7%, var(--bg-info-card));
}

.mv-source-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}

.mv-source-main {
  min-width: 0;
  flex: 1;
}

.mv-source-copy {
  min-width: 0;
  flex: 1;
}

.mv-source-title {
  font-size: 14px;
  font-weight: 800;
  color: var(--color-text-main);
}

.mv-source-badges {
  margin-top: 10px;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.mv-source-badge {
  display: inline-flex;
  align-items: center;
  height: 24px;
  padding: 0 8px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--color-primary) 8%, transparent);
  color: var(--color-text-main);
  font-size: 11px;
  font-weight: 700;
}

.mv-source-status {
  flex-shrink: 0;
  font-size: 12px;
  font-weight: 700;
  color: var(--color-primary);
}

.mv-empty-hint {
  padding: 8px 2px;
  font-size: 13px;
  color: var(--color-text-secondary);
}

@media (max-width: 768px) {
  .mv-player-wrap,
  .mv-detail-wrap {
    width: calc(100% - 24px);
  }

  .mv-main-head,
  .mv-source-row {
    flex-direction: column;
    align-items: flex-start;
  }

  .mv-version-switcher {
    margin-left: 0;
  }

  .mv-source-main {
    width: 100%;
  }

  .mv-stat-grid {
    grid-template-columns: 1fr 1fr;
  }
}

@keyframes mv-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>