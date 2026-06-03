<script setup lang="ts">
defineOptions({ name: 'radio-detail' });
import { ref, shallowRef, onMounted, onBeforeUnmount, computed } from 'vue';
import { useRoute } from 'vue-router';
import { useRouteId } from '@/utils/useRouteId';
import { getRadioSongs, consumePrefetch } from '@/api/radio';
import { mapRadioSong } from '@/utils/mappers';
import { loadRadioSongs, saveRadioSongs } from '@/utils/radioCache';
import type { Song } from '@/models/song';
import type { RadioMeta } from '@/models/radio';
import SliverHeader from '@/components/music/DetailPageSliverHeader.vue';
import ActionRow from '@/components/music/DetailPageActionRow.vue';
import SongList from '@/components/music/SongList.vue';
import SongListHeader from '@/components/music/SongListHeader.vue';
import BatchActionDrawer from '@/components/music/BatchActionDrawer.vue';
import Badge from '@/components/ui/Badge.vue';
import Button from '@/components/ui/Button.vue';
import Cover from '@/components/ui/Cover.vue';
import { usePlaylistStore } from '@/stores/playlist';
import { usePlayerStore } from '@/stores/player';
import { useSettingStore } from '@/stores/setting';
import { useToastStore } from '@/stores/toast';
import { replaceQueueAndPlay } from '@/utils/playback';
import { PagedSongLoader } from '@/utils/PagedSongLoader';
import { isGeckoView } from '@/utils/nativeBridge';
import type { SortField, SortOrder } from '@/components/music/SongListHeader.vue';
import {
  iconPlay,
  iconList,
  iconCurrentLocation,
  iconSearch,
  iconMusic,
} from '@/icons';

const route = useRoute();
const { id: currentId, onIdChange } = useRouteId();
const getFmid = () => currentId.value;

const isPortrait = isGeckoView;

const loading = ref(true);
const songs = shallowRef<Song[]>([]);

// 从 route query 获取初始元数据
const radioMeta = ref<RadioMeta | null>(null);

const searchQuery = ref('');
const showBatchDrawer = ref(false);
const songListRef = ref<{ scrollToActive?: () => void } | null>(null);

const sortField = ref<SortField | null>(null);
const sortOrder = ref<SortOrder>(null);

let songLoader: PagedSongLoader<Song> | null = null;

const playlistStore = usePlaylistStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();
const toastStore = useToastStore();

const activeSongId = computed(() => playerStore.currentTrackId ?? undefined);
const displaySongCount = computed(() => songs.value.length);

const handleSort = (field: SortField) => {
  if (sortField.value === field) {
    if (sortOrder.value === 'asc') {
      sortOrder.value = 'desc';
    } else if (sortOrder.value === 'desc') {
      sortField.value = null;
      sortOrder.value = null;
    }
  } else {
    sortField.value = field;
    sortOrder.value = 'asc';
  }
};

const sortedSongs = computed(() => {
  const base = songs.value.slice();
  if (!sortField.value || !sortOrder.value) return base;
  const compareText = (a: string, b: string) =>
    a.localeCompare(b, 'zh-Hans-CN', { sensitivity: 'base' });
  const indexMap = new Map<string, number>();
  songs.value.forEach((song, index) => {
    indexMap.set(song.id, index);
  });
  const direction = sortOrder.value === 'asc' ? 1 : -1;

  return base.sort((a, b) => {
    switch (sortField.value) {
      case 'title':
        return compareText(a.title, b.title) * direction;
      case 'album':
        return compareText(a.album ?? '', b.album ?? '') * direction;
      case 'duration':
        return (a.duration - b.duration) * direction;
      case 'index':
        return ((indexMap.get(a.id) ?? 0) - (indexMap.get(b.id) ?? 0)) * direction;
      default:
        return 0;
    }
  });
});

/**
 * 创建 PagedSongLoader 的通用工厂函数
 * @param silent 静默模式：后台刷新时不弹错误 toast（路径1/2使用）
 */
const createLoader = (
  fmid: number,
  opts: {
    onPageLoaded?: (allItems: readonly Song[]) => void;
    onComplete?: (allItems: readonly Song[]) => void;
    silent?: boolean;
  },
) =>
  new PagedSongLoader<Song>(
    async (page, pageSize) => {
      const fmoffset = (page - 1) * pageSize;
      const res = await getRadioSongs(fmid, fmoffset);
      const payload = Array.isArray(res?.data) ? res.data : [];
      const songsRaw =
        payload.length > 0 && Array.isArray(payload[0]?.songs)
          ? payload[0].songs
          : [];
      if (songsRaw.length === 0) return { items: [], hasMore: false };
      const mapped = songsRaw.map((item: unknown) => mapRadioSong(item));
      const hasMore = songsRaw.length >= pageSize;
      return { items: mapped, hasMore };
    },
    {
      pageSize: 20,
      concurrency: 3,
      initialPages: 5,
      dedupeKey: (song) => String(song.id),
      logTag: 'RadioDetailLoader',
      onPageLoaded: opts.onPageLoaded,
      onComplete: opts.onComplete,
      onError() {
        if (!opts.silent) {
          toastStore.loadFailed('电台歌曲');
        }
      },
    },
  );

const fetchData = async () => {
  loading.value = true;
  songs.value = [];

  const query = route.query;
  radioMeta.value = {
    fmid: Number(getFmid()),
    name: (query.name as string) || '电台',
    description: (query.desc as string) || '',
    coverUrl: (query.cover as string) || '',
    bannerUrl: '',
    fmtype: 0,
  };

  const fmid = getFmid();

  // 中止前一个加载器
  if (songLoader) {
    songLoader.abort();
  }

  try {
    // ═══ 路径 1：持久化缓存命中 → 瞬间展示，后台全量刷新 ═══
    const diskSongs = loadRadioSongs(fmid);
    if (diskSongs && diskSongs.length > 0) {
      songs.value = diskSongs.slice();
      loading.value = false;

      // 后台全量刷新：从 API 重新加载所有歌曲
      // onPageLoaded 不更新显示，避免缓存与 API 数据差异导致条数跳动
      // silent: true → 后台刷新失败不弹 toast，保留缓存数据
      const diskSongsCount = diskSongs.length;
      songLoader = createLoader(fmid, {
        silent: true,
        onComplete(allItems) {
          // 以 API 返回的最新全量数据为准，更新列表和缓存
          songs.value = allItems.slice();
          saveRadioSongs(fmid, allItems.slice());
          if (radioMeta.value) {
            radioMeta.value = {
              ...radioMeta.value,
              description: radioMeta.value.description || `共 ${allItems.length} 首`,
            };
          }
          // 新歌提示
          const newCount = allItems.length - diskSongsCount;
          if (newCount > 0) {
            toastStore.success(`已更新 ${newCount} 首新歌曲`);
          }
          // 如果用户已在播放该电台，同步更新播放队列
          const queueId = `queue:radio:${fmid}`;
          if (playlistStore.activeQueueId === queueId) {
            playlistStore.setPlaybackQueueWithOptions(
              allItems.slice() as Song[],
              0,
              {
                queueId,
                title: radioMeta.value?.name || '电台',
                subtitle: '电台',
                type: 'radio',
                dynamic: true,
              },
            );
          }
        },
      });
      void songLoader.loadFirstPage().then(() => {
        if (!songLoader?.fullyLoaded) void songLoader?.loadRemaining();
      });
      return;
    }

    // ═══ 路径 2：预加载缓存命中 → 零等待展示前 60 首 ═══
    const prefetched = await consumePrefetch(fmid);
    if (prefetched) {
      const seenIds = new Set<string>();
      const initialSongs: Song[] = [];

      for (const res of prefetched) {
        const payload = Array.isArray((res as Record<string, unknown>)?.data)
          ? (res as Record<string, unknown>).data
          : [];
        for (const item of payload as Record<string, unknown>[]) {
          const songsRaw = Array.isArray(item?.songs) ? item.songs : [];
          for (const s of songsRaw) {
            const song = mapRadioSong(s);
            const key = String(song.id);
            if (!seenIds.has(key)) {
              seenIds.add(key);
              initialSongs.push(song);
            }
          }
        }
      }

      songs.value = initialSongs;
      loading.value = false;

      // 后台加载全部数据（从第 1 页开始，loader 内部会去重已有的）
      // silent: true → 已有预加载数据展示，后台失败不弹 toast
      songLoader = createLoader(fmid, {
        silent: true,
        onPageLoaded(allItems) {
          // 合并预加载歌曲和后续歌曲
          const mergedSeen = new Set(seenIds);
          const merged = [...initialSongs];
          for (const song of allItems) {
            const key = String(song.id);
            if (!mergedSeen.has(key)) {
              mergedSeen.add(key);
              merged.push(song);
            }
          }
          songs.value = merged;
        },
        onComplete(allItems) {
          const mergedSeen = new Set(seenIds);
          const merged = [...initialSongs];
          for (const song of allItems) {
            const key = String(song.id);
            if (!mergedSeen.has(key)) {
              mergedSeen.add(key);
              merged.push(song);
            }
          }
          songs.value = merged;
          saveRadioSongs(fmid, merged);
          if (radioMeta.value) {
            radioMeta.value = {
              ...radioMeta.value,
              description: radioMeta.value.description || `共 ${merged.length} 首`,
            };
          }
        },
      });
      void songLoader.loadFirstPage().then(() => {
        if (!songLoader?.fullyLoaded) void songLoader?.loadRemaining();
      });
      return;
    }

    // ═══ 路径 3：全部未命中 → 正常并发加载 ═══
    songLoader = createLoader(fmid, {
      onPageLoaded(allItems) {
        songs.value = allItems.slice();
      },
      onComplete(allItems) {
        songs.value = allItems.slice();
        saveRadioSongs(fmid, allItems.slice());
        if (radioMeta.value) {
          radioMeta.value = {
            ...radioMeta.value,
            description: radioMeta.value.description || `共 ${allItems.length} 首`,
          };
        }
      },
    });

    await songLoader.loadFirstPage();
    loading.value = false;

    if (!songLoader.fullyLoaded) {
      void songLoader.loadRemaining();
    }
  } catch {
    // 只在没有任何数据时才报错（有缓存或预加载数据时静默失败）
    if (songs.value.length === 0) {
      toastStore.loadFailed('电台歌曲');
    }
    loading.value = false;
  }
};

const handleSongDoubleTapPlay = async (song: Song) => {
  try {
    const fmid = radioMeta.value?.fmid ?? getFmid();
    const queueOpts = {
      queueId: `queue:radio:${fmid}`,
      title: radioMeta.value?.name || '电台',
      subtitle: '电台',
      type: 'radio',
      dynamic: true,
    };
    await replaceQueueAndPlay(playlistStore, playerStore, songs.value, 0, song, queueOpts);
    // 如果仍在后台加载，静默等待全部歌曲并更新播放队列
    if (songLoader && !songLoader.fullyLoaded) {
      const allSongs = await songLoader.waitForAll();
      playlistStore.setPlaybackQueueWithOptions(allSongs.slice() as Song[], 0, queueOpts);
    }
  } catch {
    toastStore.actionFailed('播放');
  }
};

const handlePlayAll = async () => {
  if (songs.value.length === 0) return;
  try {
    const fmid = radioMeta.value?.fmid ?? getFmid();
    const queueOpts = {
      queueId: `queue:radio:${fmid}`,
      title: radioMeta.value?.name || '电台',
      subtitle: '电台',
      type: 'radio' as const,
      dynamic: true,
    };
    await replaceQueueAndPlay(playlistStore, playerStore, songs.value, 0, undefined, queueOpts);
    // 如果仍在后台加载，静默等待全部歌曲并更新播放队列
    if (songLoader && !songLoader.fullyLoaded) {
      const allSongs = await songLoader.waitForAll();
      // 不管数量是否变化，都更新播放队列为最新完整数据
      playlistStore.setPlaybackQueueWithOptions(allSongs.slice() as Song[], 0, queueOpts);
    }
  } catch {
    toastStore.actionFailed('播放');
  }
};

const openBatchDrawer = () => {
  if (songs.value.length === 0) return;
  showBatchDrawer.value = true;
};

const handleLocate = () => songListRef.value?.scrollToActive?.();

onMounted(() => {
  fetchData();
});

onBeforeUnmount(() => {
  if (songLoader) {
    songLoader.abort();
    songLoader = null;
  }
});

onIdChange(() => {
  radioMeta.value = null;
  songs.value = [];
  if (songLoader) {
    songLoader.abort();
    songLoader = null;
  }
  fetchData();
});
</script>

<template>
  <div class="radio-detail-view bg-bg-main min-h-full relative">

    <div v-if="!isPortrait && radioMeta?.coverUrl" class="radio-ambient-bg-wrap">
      <div class="radio-ambient-bg" :style="{ backgroundImage: `url(${radioMeta.coverUrl})` }"></div>
      <div class="radio-ambient-overlay"></div>
    </div>

    <div v-if="loading && !radioMeta" class="flex items-center justify-center py-40 relative z-10">
      <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
    </div>

    <template v-else-if="radioMeta">

      <!-- ═══ 横屏模式 ═══ -->
      <template v-if="!isPortrait">
        <div class="relative z-10">
          <SliverHeader
            typeLabel="RADIO"
            :title="radioMeta.name"
            :coverUrl="radioMeta.coverUrl || ''"
            :hasDetails="true"
          >
            <template #details>
              <div class="flex flex-col gap-2.5 w-full items-start text-left">
                <div class="flex items-center flex-wrap gap-2 text-[11px] font-semibold">
                  <span class="inline-flex items-center gap-1.5 text-text-main/70 bg-black/5 dark:bg-white/5 px-2.5 py-1 rounded-md backdrop-blur-md">
                    <Icon :icon="iconMusic" width="13" height="13" />
                    <span>{{ displaySongCount }}</span>
                  </span>
                </div>
                <div v-if="radioMeta.description" class="text-[13px] font-semibold text-text-secondary">
                  {{ radioMeta.description }}
                </div>
              </div>
            </template>

            <template #actions>
              <ActionRow @play="handlePlayAll" @batch="openBatchDrawer" />
            </template>

            <template #collapsed-actions>
              <Button
                variant="unstyled"
                size="none"
                @click="handlePlayAll"
                class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-primary transition-colors"
              >
                <Icon :icon="iconPlay" width="20" height="20" />
              </Button>
              <Button
                variant="unstyled"
                size="none"
                @click="openBatchDrawer"
                class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-text-main opacity-60 transition-colors"
              >
                <Icon :icon="iconList" width="18" height="18" />
              </Button>
            </template>
          </SliverHeader>

          <BatchActionDrawer v-model:open="showBatchDrawer" :songs="songs" :source-id="String(radioMeta.fmid)" />

          <div class="song-list-sticky sticky z-[110] bg-bg-main" :style="{ top: '56px' }">
            <div class="px-6 border-b border-border-light/10">
              <div class="flex items-center justify-between h-14">
                <div class="text-[14px] font-semibold text-text-main relative">
                  歌曲 <Badge :count="displaySongCount" />
                </div>
                <div class="flex items-center gap-2">
                  <div class="relative">
                    <input
                      v-model="searchQuery"
                      type="text"
                      placeholder="搜索歌曲..."
                      class="song-search-input w-52 h-9 pl-8 pr-3 rounded-lg bg-white border border-black/30 shadow-sm text-text-main placeholder:text-text-main/50 dark:bg-white/[0.08] dark:border-white/10 dark:shadow-none outline-none text-[12px] transition-all"
                    />
                    <Icon
                      class="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-main/60"
                      :icon="iconSearch"
                      width="14"
                      height="14"
                    />
                  </div>
                  <Button
                    variant="unstyled"
                    size="none"
                    @click="handleLocate"
                    class="song-locate-btn p-2 rounded-lg"
                    title="定位当前播放"
                  >
                    <Icon :icon="iconCurrentLocation" width="16" height="16" />
                  </Button>
                </div>
              </div>
            </div>

            <SongListHeader
              :sortField="sortField"
              :sortOrder="sortOrder"
              :showCover="true"
              paddingClass="px-6"
              @sort="handleSort"
            />
          </div>

          <div class="px-6 pb-12">
            <div v-if="loading" class="flex items-center justify-center py-20">
              <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
            </div>
            <SongList
              v-else
              ref="songListRef"
              :songs="sortedSongs"
              :searchQuery="searchQuery"
              :activeId="activeSongId"
              :showCover="true"
              :queueOptions="{
                queueId: `queue:radio:${radioMeta.fmid}`,
                title: radioMeta.name || '电台',
                subtitle: '电台',
                type: 'radio',
                dynamic: true,
              }"
              :enableDefaultDoubleTapPlay="true"
              :onSongDoubleTapPlay="settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined"
            />
          </div>
        </div>
      </template>

      <!-- ═══ 竖屏模式 ═══ -->
      <template v-else>
        <BatchActionDrawer v-model:open="showBatchDrawer" :songs="songs" :source-id="String(radioMeta.fmid)" />

        <!-- 头部详情 -->
        <div class="px-4 pt-3">
          <div class="flex items-start gap-3">
            <div class="w-14 h-14 rounded-xl overflow-hidden shadow-lg shrink-0">
              <Cover :url="radioMeta.coverUrl" :size="160" :width="56" :height="56" />
            </div>
            <div class="min-w-0 flex-1 pt-0.5">
              <div class="text-[16px] font-extrabold text-text-main leading-snug line-clamp-2">{{ radioMeta.name }}</div>
              <div class="flex items-center gap-2 mt-1">
                <span class="text-[12px] font-semibold text-text-main/70">{{ radioMeta.description }}</span>
              </div>
            </div>
          </div>

          <div class="flex items-center flex-wrap gap-1.5 mt-2.5">
            <span class="px-2 py-0.5 rounded text-[10px] font-bold tracking-[0.8px] uppercase text-primary bg-primary/10 border border-primary/15">RADIO</span>
            <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-text-main/60 bg-black/5 dark:bg-white/5 px-2 py-0.5 rounded">
              <Icon :icon="iconMusic" width="11" height="11" />
              {{ displaySongCount }} 首
            </span>
          </div>
        </div>

        <div class="song-list-sticky sticky z-[110] bg-bg-main" :style="{ top: '0px' }">
          <div class="px-4 pb-2 pt-2">
            <ActionRow @play="handlePlayAll" @batch="openBatchDrawer" />
          </div>
          <div class="border-b border-border-light/10 px-4">
            <div class="flex items-center justify-between h-10">
              <div class="text-[13px] font-semibold text-text-main relative">
                歌曲 <Badge :count="displaySongCount" class="scale-90 origin-left" />
              </div>
              <Button
                variant="unstyled"
                size="none"
                @click="handleLocate"
                class="song-locate-btn p-1.5 rounded-full text-text-main/60 hover:text-primary hover:bg-primary/10 transition-colors"
                title="定位当前播放"
              >
                <Icon :icon="iconCurrentLocation" width="16" height="16" />
              </Button>
            </div>
          </div>

          <SongListHeader
            :sortField="sortField"
            :sortOrder="sortOrder"
            :showCover="true"
            paddingClass="px-4"
            @sort="handleSort"
          />
        </div>

        <div class="pb-safe relative z-[1]">
          <div v-if="loading" class="flex items-center justify-center py-20">
            <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          </div>
          <div v-else class="px-3">
            <SongList
              ref="songListRef"
              :songs="sortedSongs"
              :searchQuery="searchQuery"
              :activeId="activeSongId"
              :showCover="true"
              :queueOptions="{
                queueId: `queue:radio:${radioMeta.fmid}`,
                title: radioMeta.name || '电台',
                subtitle: '电台',
                type: 'radio',
                dynamic: true,
              }"
              :enableDefaultDoubleTapPlay="true"
              :onSongDoubleTapPlay="settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined"
            />
          </div>
        </div>
      </template>

    </template>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* 沉浸式弥散背景光晕 */
.radio-ambient-bg-wrap {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 45vh;
  min-height: 380px;
  overflow: hidden;
  pointer-events: none;
  z-index: 0;
}

.radio-ambient-bg {
  width: 100%;
  height: 100%;
  background-size: cover;
  background-position: center;
  filter: blur(80px) saturate(160%);
  opacity: 0.35;
  transform: scale(1.3);
  transition: opacity 0.5s ease;
}

.dark .radio-ambient-bg {
  opacity: 0.25;
  filter: blur(90px) saturate(120%);
}

.radio-ambient-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(to bottom, transparent 0%, var(--color-bg-main) 95%);
}

.pb-safe {
  padding-bottom: max(24px, calc(env(safe-area-inset-bottom, 0px) + 24px));
}
</style>
