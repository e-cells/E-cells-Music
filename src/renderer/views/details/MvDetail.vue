<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
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
import { useMvPlaylistStore } from '@/stores/mvPlaylist';
import { isGeckoView, NativeMvPlayerBridge } from '@/utils/nativeBridge';
import { iconPlay } from '@/icons';

const route = useRoute();
const toastStore = useToastStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();
const mvPlaylistStore = useMvPlaylistStore();

const loading = ref(false);
const sourceLoading = ref(false);
const meta = ref<VideoMeta | null>(null);
const mvVersions = ref<VideoMeta[]>([]);
const currentVersionIndex = ref(0);
const currentSourceHash = ref('');
const playbackError = ref('');
const isLaunching = ref(false);

const isMobileNative = isGeckoView || /Android/i.test(navigator.userAgent);

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

// 封面区域是否可点击（数据已加载且有可用片源）
const canPlay = computed(() =>
  !loading.value && !isLaunching.value && currentSourceHash.value && isGeckoView,
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

  if (currentSourceHash.value && sources.some((s) => s.hash === currentSourceHash.value)) {
    if (!isMobileNative) return;
    const current = sources.find((s) => s.hash === currentSourceHash.value);
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

// === 点击封面/播放按钮触发播放 ===
let loadVideoGeneration = 0;

const handlePlayClick = async () => {
  if (!currentSourceHash.value || isLaunching.value) return;
  if (!isGeckoView) {
    playbackError.value = 'MV 播放需要原生环境支持';
    return;
  }

  const gen = ++loadVideoGeneration;
  isLaunching.value = true;
  sourceLoading.value = true;
  playbackError.value = '';

  try {
    const hash = currentSourceHash.value;
    const response = await getVideoUrl(hash);
    if (gen !== loadVideoGeneration) return;
    const url = extractVideoUrl(response, hash, isMobileNative);
    if (!url) throw new Error('empty-url');

    await pauseMusicPlayback();

    // 设置 MV 播放列表 store 并注册事件监听
    mvPlaylistStore.setupListeners();

    // 启动原生 MV 播放 Activity（单个 MV，无播放列表）
    await NativeMvPlayerBridge.openMvPlayer({
      url,
      title: title.value,
      author: authorLine.value,
      coverUrl: cover.value,
      hash,
    });
  } catch {
    if (gen !== loadVideoGeneration) return;
    playbackError.value = '当前视频暂时无法播放';
    toastStore.loadFailed('MV');
  } finally {
    if (gen === loadVideoGeneration) {
      sourceLoading.value = false;
      isLaunching.value = false;
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
  playbackError.value = '';
};

const fetchMvMeta = async () => {
  loading.value = true;
  meta.value = buildInitialMeta();
  mvVersions.value = [];
  currentVersionIndex.value = 0;
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

const changeSource = (hash: string) => {
  if (!hash || hash === currentSourceHash.value) return;
  currentSourceHash.value = hash;
};

const switchVersion = (offset: -1 | 1) => {
  const nextIndex = currentVersionIndex.value + offset;
  if (nextIndex < 0 || nextIndex >= mvVersions.value.length) return;
  const nextMeta = mvVersions.value[nextIndex];
  if (!nextMeta) return;
  currentVersionIndex.value = nextIndex;
  applyVersion(nextMeta);
};

onMounted(async () => {
  meta.value = buildInitialMeta();
  await fetchMvMeta();
});

onBeforeUnmount(() => {
  mvPlaylistStore.cleanup();
});
</script>

<template>
  <div class="mv-page bg-bg-main min-h-full">
    <!-- 加载中 -->
    <div v-if="loading" class="mv-loading-state">
      <div class="mv-loading-spinner"></div>
      <span>正在加载 MV ...</span>
    </div>

    <template v-else>
      <!-- 封面大图 + 播放按钮 -->
      <div class="mv-cover-hero" @click="handlePlayClick">
        <Image v-if="cover" :src="cover" :alt="title" class="mv-cover-hero-img" />
        <div class="mv-cover-hero-overlay">
          <div v-if="isLaunching || sourceLoading" class="mv-cover-loading">
            <div class="mv-loading-spinner"></div>
          </div>
          <button
            v-else-if="canPlay"
            type="button"
            class="mv-cover-play-btn"
            @click.stop="handlePlayClick"
          >
            <Icon :icon="iconPlay" width="36" height="36" />
          </button>
          <div v-else-if="playbackError" class="mv-cover-error">
            <span>{{ playbackError }}</span>
          </div>
        </div>
      </div>

      <!-- 详情信息 -->
      <div class="mv-detail-wrap">
        <section class="card-block card-block--hero">
          <div class="mv-main-head">
            <div class="mv-title-block" style="padding-left: 0;">
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
    </template>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* === 封面大图 Hero === */
.mv-cover-hero {
  position: relative;
  width: 100%;
  aspect-ratio: 16 / 9;
  max-height: 360px;
  overflow: hidden;
  background: #000;
  cursor: pointer;
}

.mv-cover-hero-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.mv-cover-hero-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.25);
  transition: background 0.2s ease;
}

.mv-cover-hero:hover .mv-cover-hero-overlay {
  background: rgba(0, 0, 0, 0.4);
}

.mv-cover-play-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 64px;
  height: 64px;
  border-radius: 50%;
  border: none;
  background: rgba(255, 255, 255, 0.2);
  color: #fff;
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
  cursor: pointer;
  transition: all 0.2s ease;
}

.mv-cover-play-btn:hover {
  background: rgba(255, 255, 255, 0.35);
  transform: scale(1.08);
}

.mv-cover-loading {
  color: #fff;
}

.mv-cover-error {
  color: rgba(255, 255, 255, 0.85);
  font-size: 13px;
  text-align: center;
  max-width: 80%;
}

/* === 详情区 === */
.mv-detail-wrap {
  width: min(1120px, calc(100% - 32px));
  margin: 0 auto;
  padding: 18px 0 28px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.mv-loading-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  padding: 80px 20px;
  color: rgba(255, 255, 255, 0.84);
}

.mv-loading-spinner {
  width: 28px;
  height: 28px;
  border: 3px solid rgba(255, 255, 255, 0.18);
  border-top-color: rgba(255, 255, 255, 0.92);
  border-radius: 999px;
  animation: mv-spin 0.9s linear infinite;
}

.mv-error-text {
  max-width: 80%;
  text-align: center;
  white-space: pre-line;
  font-size: 13px;
  line-height: 1.6;
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
  .mv-cover-hero {
    max-height: 240px;
  }

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
