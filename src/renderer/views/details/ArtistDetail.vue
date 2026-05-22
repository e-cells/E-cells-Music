<script setup lang="ts">
defineOptions({ name: 'artist-detail' });
import { ref, shallowRef, onMounted, onUnmounted, computed, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useRouteId } from '@/utils/useRouteId';
import {
  getArtistDetail,
  getArtistSongs,
  getArtistAlbums,
  getArtistVideos,
  followArtist,
  unfollowArtist,
} from '@/api/artist';
import SliverHeader from '@/components/music/DetailPageSliverHeader.vue';
import ActionRow from '@/components/music/DetailPageActionRow.vue';
import SongList from '@/components/music/SongList.vue';
import SongListHeader from '@/components/music/SongListHeader.vue';
import AlbumCard from '@/components/music/AlbumCard.vue';
import MvCard from '@/components/music/MvCard.vue';
import Tabs from '@/components/ui/Tabs.vue';
import TabsList from '@/components/ui/TabsList.vue';
import TabsTrigger from '@/components/ui/TabsTrigger.vue';
import TabsContent from '@/components/ui/TabsContent.vue';
import VirtualGrid from '@/components/ui/VirtualGrid.vue';
import Badge from '@/components/ui/Badge.vue';
import Dialog from '@/components/ui/Dialog.vue';
import BatchActionDrawer from '@/components/music/BatchActionDrawer.vue';
import { usePlaylistStore } from '@/stores/playlist';
import type { Song } from '@/models/song';
import { mapAlbumMeta, mapArtistDetailMeta, mapArtistSong } from '@/utils/mappers';
import { usePlayerStore } from '@/stores/player';
import { useSettingStore } from '@/stores/setting';
import { useUserStore } from '@/stores/user';
import { useToastStore } from '@/stores/toast';
import { PagedSongLoader } from '@/utils/PagedSongLoader';
import type { SortField, SortOrder } from '@/components/music/SongListHeader.vue';
import {
  iconCurrentLocation,
  iconSearch,
  iconPlay,
  iconList,
  iconHeart,
  iconHeartFilled,
} from '@/icons';
import { replaceQueueAndPlay } from '@/utils/playback';
import Button from '@/components/ui/Button.vue';
import { extractFirstObject, extractList } from '@/utils/extractors';

// 引入移动端检测和紧凑布局所需组件
import { isGeckoView } from '@/utils/nativeBridge';
import Cover from '@/components/ui/Cover.vue';

interface ArtistAlbumCardProps {
  id: string | number;
  name: string;
  coverUrl: string;
  artist?: string;
  publishTime?: string;
}

interface ArtistMvCardProps {
  videoId: string | number;
  hash: string;
  title: string;
  coverUrl: string;
  artist?: string;
  duration?: number;
  publishDate?: string;
  albumAudioId?: string | number;
}

const isPortrait = isGeckoView;

const playlistStore = usePlaylistStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();
const userStore = useUserStore();
const toastStore = useToastStore();

const router = useRouter();
const { id: currentId, onIdChange } = useRouteId();
const getArtistId = () => currentId.value;

const formatFansCount = (count: number): string => {
  if (count >= 10000) return `${(count / 10000).toFixed(1).replace(/\.0$/, '')}万`;
  return String(count);
};

const loading = ref(true);
const loadingSongs = ref(true);
const loadingAlbums = ref(false);
const loadingMvs = ref(false);
const artist = ref<ReturnType<typeof mapArtistDetailMeta> | null>(null);

// 使用 shallowRef 避免对成千上万个歌曲对象进行深层响应式代理，极大提升性能
const songs = shallowRef<Song[]>([]);
const albums = shallowRef<ReturnType<typeof mapAlbumMeta>[]>([]);
const albumPage = ref(1);
const albumHasMore = ref(false);
const albumFetched = ref(false);
const mvs = shallowRef<ArtistMvCardProps[]>([]);
const mvTotal = ref(0);
const mvPage = ref(1);
const mvHasMore = ref(false);
const mvFetched = ref(false);
const mvTag = ref<'all' | 'official' | 'live' | 'fan' | 'artist'>('all');

const activeTab = ref('songs');
const loadedSongCount = ref(0);
const showBatchDrawer = ref(false);
const showIntroDialog = ref(false);
const togglingFollow = ref(false);

const searchQuery = ref('');
const songListRef = ref<{ scrollToActive?: () => void } | null>(null);

// 修复 Tabs 固定高度问题，移除响应式的 sliverHeaderRef.value?.currentHeight
const tabsTop = computed(() => {
  if (isPortrait) return 0;
  return 56;
});

const sortField = ref<SortField | null>(null);
const sortOrder = ref<SortOrder>(null);

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
  const data = songs.value;
  if (!sortField.value || !sortOrder.value || data.length === 0) return data;

  if (sortField.value === 'index') {
    return sortOrder.value === 'asc' ? data : [...data].reverse();
  }

  const direction = sortOrder.value === 'asc' ? 1 : -1;
  const compareText = (a: string, b: string) =>
    a.localeCompare(b, 'zh-Hans-CN', { sensitivity: 'base' });

  // 仅在需要排序时创建副本
  return [...data].sort((a, b) => {
    switch (sortField.value) {
      case 'title':
        return compareText(a.title, b.title) * direction;
      case 'album':
        return compareText(a.album ?? '', b.album ?? '') * direction;
      case 'duration':
        return (a.duration - b.duration) * direction;
      default:
        return 0;
    }
  });
});

// 歌曲分页加载器
let songLoader: PagedSongLoader<Song> | null = null;

const fetchAllArtistSongs = (totalCount: number) => {
  if (!songLoader || songLoader.fullyLoaded) return;
  if (songLoader.count >= totalCount) return;
  void songLoader.loadRemaining();
};

const fetchData = async () => {
  const artistId = getArtistId();
  loading.value = true;
  loadingSongs.value = true;

  // 0. 确保关注列表已加载
  void userStore.ensureFollowedArtists();

  // 1. 获取歌手详情
  const detailTask = getArtistDetail(artistId)
    .then((res) => {
      const detailRaw = extractFirstObject(res);
      if (detailRaw) {
        artist.value = mapArtistDetailMeta(detailRaw);
      }
      loading.value = false;
    })
    .catch(() => {
      loading.value = false;
    });

  // 2. 中止上一次加载
  if (songLoader) {
    songLoader.abort();
  }

  // 3. 创建加载器获取歌曲
  songLoader = new PagedSongLoader<Song>(
    async (page, pageSize) => {
      const res = await getArtistSongs(artistId, page, pageSize, 'hot');
      const items = extractList(res).map((item) => mapArtistSong(artistId, item));
      return { items, hasMore: items.length >= pageSize };
    },
    {
      pageSize: 200,
      concurrency: 3,
      dedupeKey: (song) => String(song.id),
      logTag: 'ArtistSongsLoader',
      onPageLoaded(allItems) {
        songs.value = allItems.slice();
        loadedSongCount.value = allItems.length;
      },
      onComplete(allItems) {
        songs.value = allItems.slice();
        loadedSongCount.value = allItems.length;
      },
      onError() {
        toastStore.loadFailed('歌手歌曲');
      },
    }
  );

  const songsTask = songLoader
    .loadFirstPage()
    .then(() => {
      loadingSongs.value = false;
      const totalSongs = artist.value?.songCount ?? songLoader!.count;
      if (totalSongs > songLoader!.count) {
        fetchAllArtistSongs(totalSongs);
      }
    })
    .catch(() => {
      loadingSongs.value = false;
    });

  await Promise.allSettled([detailTask, songsTask]);
};

// id 变化时重置数据（仅同路由间切换，如歌手A→歌手B）
onIdChange(() => {
  artist.value = null;
  songs.value = [];
  albums.value = [];
  mvs.value = [];
  mvFetched.value = false;
  mvTotal.value = 0;
  mvPage.value = 1;
  mvHasMore.value = false;
  albumPage.value = 1;
  albumHasMore.value = false;
  albumFetched.value = false;
  loadedSongCount.value = 0;
  searchQuery.value = '';
  sortField.value = null;
  sortOrder.value = null;
  activeTab.value = 'songs';
  if (songLoader) {
    songLoader.abort();
    songLoader = null;
  }
  void fetchData();
});

const isFollowed = computed(() => userStore.isArtistFollowed(artist.value?.id ?? ''));

const isRequestSuccessful = (payload: unknown) => {
  if (!payload || typeof payload !== 'object') return false;
  const record = payload as Record<string, unknown>;
  return record.status === 1 || record.code === 200 || record.error_code === 0;
};

const toggleArtistFollow = async () => {
  if (!artist.value || togglingFollow.value) return;

  if (!userStore.isLoggedIn) {
    toastStore.loginRequired('关注歌手');
    await router.push({ name: 'login' });
    return;
  }

  togglingFollow.value = true;
  const previousFollowed = isFollowed.value;

  try {
    const response = previousFollowed
      ? await unfollowArtist(artist.value.id)
      : await followArtist(artist.value.id);

    if (isRequestSuccessful(response)) {
      if (previousFollowed) {
        userStore.removeFollowedArtist(artist.value.id);
        toastStore.actionCompleted('已取消关注');
      } else {
        userStore.addFollowedArtist(artist.value.id);
        toastStore.actionSucceeded('关注');
      }
    } else {
      toastStore.actionFailed(previousFollowed ? '取消关注' : '关注');
    }
  } catch {
    toastStore.actionFailed(previousFollowed ? '取消关注' : '关注');
  } finally {
    togglingFollow.value = false;
  }
};

const secondaryActions = computed(() => {
  if (!artist.value || !userStore.isLoggedIn) return [];

  return [
    {
      icon: isFollowed.value ? iconHeartFilled : iconHeart,
      label: togglingFollow.value
        ? isFollowed.value
          ? '取消中...'
          : '关注中...'
        : isFollowed.value
          ? '已关注'
          : '关注',
      emphasized: isFollowed.value,
      tone: 'favorite' as const,
      onTap: toggleArtistFollow,
    },
  ];
});

const handleSongDoubleTapPlay = async (song: Song) => {
  await replaceQueueAndPlay(playlistStore, playerStore, songs.value, 0, song, {
    queueId: `queue:artist:${artist.value?.id ?? getArtistId()}`,
    title: artist.value?.name || '歌手',
    subtitle: '',
    type: 'artist',
  });
};

const handlePlayAll = async () => {
  if (songs.value.length === 0) return;
  const queueOpts = {
    queueId: `queue:artist:${artist.value?.id ?? getArtistId()}`,
    title: artist.value?.name || '歌手',
    subtitle: '',
    type: 'artist' as const,
  };
  await replaceQueueAndPlay(playlistStore, playerStore, songs.value, 0, undefined, queueOpts);
  // 后台等待全部加载完，静默更新播放队列
  if (songLoader && !songLoader.fullyLoaded) {
    const allSongs = await songLoader.waitForAll();
    if (allSongs.length > songs.value.length) {
      playlistStore.setPlaybackQueueWithOptions(allSongs.slice() as Song[], 0, queueOpts);
    }
  }
};
const openBatchDrawer = () => {
  if (songs.value.length === 0) return;
  showBatchDrawer.value = true;
};
const handleLocate = () => songListRef.value?.scrollToActive?.();

const getAlbumCardProps = (album: ReturnType<typeof mapAlbumMeta>): ArtistAlbumCardProps => {
  return {
    id: album.id,
    name: album.name,
    coverUrl: album.pic,
    artist: album.singerName,
    publishTime: album.publishTime,
  };
};

const albumCards = computed(() => albums.value.map((entry) => getAlbumCardProps(entry)));

const mapMvItem = (item: Record<string, unknown>): ArtistMvCardProps => {
  const hdpic = String(item.hdpic ?? item.cover ?? '').replace('{size}', '400');
  const cover = String(item.cover ?? '');
  return {
    videoId: item.video_id as string | number,
    hash: String(item.mkv_qhd_hash ?? item.mkv_sd_hash ?? ''),
    title: String(item.video_name ?? ''),
    coverUrl: hdpic || cover,
    artist: String(item.author_name ?? ''),
    duration: Number(item.timelength ?? 0),
    publishDate: String(item.publish_date ?? '').split(' ')[0],
    albumAudioId: item.album_audio_id as string | number | undefined,
  };
};

const fetchMvs = async (page = 1) => {
  const artistId = getArtistId();
  loadingMvs.value = true;
  try {
    const res = await getArtistVideos(artistId, page, 30, mvTag.value);
    const record = res && typeof res === 'object' ? (res as Record<string, unknown>) : {};
    const list = Array.isArray(record.data) ? record.data : [];
    const total = Number(record.total ?? 0);
    const mapped = list
      .map((item: unknown) =>
        item && typeof item === 'object' ? mapMvItem(item as Record<string, unknown>) : null,
      )
      .filter((item): item is ArtistMvCardProps => item !== null && !!item.videoId);

    if (page === 1) {
      mvs.value = mapped;
    } else {
      mvs.value = [...mvs.value, ...mapped];
    }
    mvTotal.value = total;
    mvPage.value = page;
    mvHasMore.value = mvs.value.length < total;
    mvFetched.value = true;
  } catch {
    if (page === 1) mvs.value = [];
  } finally {
    loadingMvs.value = false;
  }
};

const mvTagOptions = [
  { value: 'all' as const, label: '全部' },
  { value: 'official' as const, label: '官方' },
  { value: 'live' as const, label: '现场' },
  { value: 'fan' as const, label: '饭制' },
  { value: 'artist' as const, label: '歌手发布' },
];

const switchMvTag = (tag: typeof mvTag.value) => {
  if (tag === mvTag.value) return;
  mvTag.value = tag;
  mvs.value = [];
  mvTotal.value = 0;
  mvPage.value = 1;
  mvHasMore.value = false;
  mvFetched.value = false;
  void fetchMvs(1);
};

const fetchMoreAlbums = async () => {
  if (loadingAlbums.value || (!albumFetched.value ? false : !albumHasMore.value)) return;
  const artistId = getArtistId();
  const nextPage = albumFetched.value ? albumPage.value + 1 : 1;
  loadingAlbums.value = true;
  try {
    const res = await getArtistAlbums(artistId, nextPage, 30, 'hot');
    const fetched = extractList(res).map((item) => mapAlbumMeta(item));
    if (nextPage === 1) {
      albums.value = fetched;
    } else {
      albums.value = [...albums.value, ...fetched];
    }
    albumPage.value = nextPage;
    albumFetched.value = true;
    const totalAlbums = artist.value?.albumCount ?? 0;
    albumHasMore.value = fetched.length >= 30 && albums.value.length < totalAlbums;
  } catch {
    // 忽略
  } finally {
    loadingAlbums.value = false;
  }
};

// 切换到 MV/专辑 tab 时懒加载
watch(activeTab, (tab) => {
  if (tab === 'mvs' && !mvFetched.value) {
    void fetchMvs(1);
  }
  if (tab === 'albums' && !albumFetched.value) {
    void fetchMoreAlbums();
  }
});

// 滚动加载更多 MV 和专辑
// 兼容多端的滚动监听
const onViewportScroll = () => {
  const viewport = document.querySelector('.view-port');
  
  let scrollTop = 0;
  let scrollHeight = 0;
  let clientHeight = 0;

  // 如果存在 .view-port 则使用它，否则降级使用全局 window 滚动参数
  if (viewport) {
    scrollTop = viewport.scrollTop;
    scrollHeight = viewport.scrollHeight;
    clientHeight = viewport.clientHeight;
  } else {
    scrollTop = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
    clientHeight = window.innerHeight || document.documentElement.clientHeight || 0;
    scrollHeight = document.documentElement.scrollHeight || document.body.scrollHeight || 0;
  }

  // 距离底部 400px 时触发加载
  if (scrollHeight - scrollTop - clientHeight > 400) {
    if (activeTab.value === 'mvs' && mvHasMore.value && !loadingMvs.value) {
      void fetchMvs(mvPage.value + 1);
    }
    if (activeTab.value === 'albums' && albumHasMore.value && !loadingAlbums.value) {
      void fetchMoreAlbums();
    }
  }
};

onMounted(() => {
  void fetchData();
  // 同时监听 viewport 和 window，确保在任何布局下都不会漏掉滚动事件
  const viewport = document.querySelector('.view-port');
  viewport?.addEventListener('scroll', onViewportScroll, { passive: true });
  window.addEventListener('scroll', onViewportScroll, { passive: true });
});

onUnmounted(() => {
  const viewport = document.querySelector('.view-port');
  viewport?.removeEventListener('scroll', onViewportScroll);
  window.removeEventListener('scroll', onViewportScroll);
});
</script>

<template>
  <div class="artist-detail-container bg-bg-main min-h-full relative">
    <div v-if="!isPortrait && artist?.pic" class="artist-ambient-bg-wrap">
      <div class="artist-ambient-bg" :style="{ backgroundImage: `url(${artist.pic})` }"></div>
      <div class="artist-ambient-overlay"></div>
    </div>

    <div v-if="loading && !artist" class="flex items-center justify-center py-40 relative z-10">
      <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
    </div>

    <template v-else-if="artist">
      <template v-if="!isPortrait">
        <div class="relative z-10">
          <SliverHeader
            typeLabel="ARTIST"
            :title="artist.name"
            :coverUrl="artist.pic"
            :hasDetails="true"
            :expandedHeight="196"
          >
            <template #details>
              <div class="flex flex-col gap-1.5 text-text-main/60">
                <div class="text-[13px] font-semibold text-primary">
                  {{ artist.songCount || songs.length }} 歌曲 •
                  {{ artist.albumCount || albums.length }} 专辑
                  <template v-if="artist.mvCount"> • {{ artist.mvCount }} MV</template>
                </div>
                <div class="flex items-center gap-3 text-[12px] text-text-secondary">
                  <span v-if="artist.fansCount" class="flex items-center gap-1">
                    <span class="font-semibold text-text-main/80">{{
                      formatFansCount(artist.fansCount)
                    }}</span>
                    粉丝
                  </span>
                  <span v-if="artist.birthday">🎂 {{ artist.birthday }}</span>
                </div>
              </div>
            </template>

            <template #actions>
              <ActionRow
                :secondaryActions="secondaryActions"
                @play="handlePlayAll"
                @batch="openBatchDrawer"
              />
            </template>

            <template #collapsed-actions>
              <Button
                v-if="userStore.isLoggedIn"
                variant="unstyled"
                size="none"
                @click="toggleArtistFollow"
                class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-red-500 transition-colors"
              >
                <Icon :icon="isFollowed ? iconHeartFilled : iconHeart" width="18" height="18" />
              </Button>
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

          <div v-if="artist.intro" class="px-5 md:px-6 pt-[6px] pb-[6px]">
            <div class="text-[15px] font-semibold text-text-main">歌手介绍</div>
            <div class="mt-[6px] text-[12px] leading-relaxed text-text-secondary line-clamp-1 cursor-pointer hover:text-text-main transition-colors" @click="showIntroDialog = true">
              {{ artist.intro }}
            </div>
            <Button
              variant="unstyled"
              size="none"
              type="button"
              class="mt-[2px] text-[11px] font-semibold text-primary"
              @click="showIntroDialog = true"
            >
              查看详情
            </Button>
          </div>

          <Tabs v-model="activeTab" class="w-full">
            <div class="song-list-sticky sticky z-[110] bg-bg-main/75 backdrop-blur-xl border-b border-border-light/10 transition-colors" :style="{ top: `${tabsTop}px` }">
              <div class="px-5 md:px-6">
                <div class="flex items-center justify-between h-14">
                  <TabsList class="bg-transparent border-none gap-8">
                    <TabsTrigger value="songs">
                      <span class="relative">歌曲 <Badge v-if="loadedSongCount > 0" :count="loadedSongCount" class="scale-90 origin-left" /></span>
                    </TabsTrigger>
                    <TabsTrigger value="albums">
                      <span class="relative">专辑 <Badge v-if="albumFetched && albums.length > 0" :count="albums.length" class="scale-90 origin-left" /></span>
                    </TabsTrigger>
                    <TabsTrigger value="mvs">
                      <span class="relative">MV <Badge v-if="mvFetched && mvs.length > 0" :count="mvs.length" class="scale-90 origin-left" /></span>
                    </TabsTrigger>
                  </TabsList>

                  <div v-if="activeTab === 'songs'" class="flex items-center gap-2">
                    <div class="relative hidden sm:block">
                      <input
                        v-model="searchQuery"
                        type="text"
                        placeholder="搜索歌曲..."
                        class="song-search-input w-40 md:w-52 h-9 pl-8 pr-3 rounded-full bg-black/5 dark:bg-white/10 border border-transparent shadow-none text-text-main placeholder:text-text-main/50 outline-none text-[13px] transition-all focus:bg-black/10 dark:focus:bg-white/15"
                      />
                      <Icon
                        class="absolute left-3 top-1/2 -translate-y-1/2 text-text-main/50"
                        :icon="iconSearch"
                        width="14"
                        height="14"
                      />
                    </div>
                    <Button
                      variant="unstyled"
                      size="none"
                      @click="handleLocate"
                      class="song-locate-btn p-2 rounded-full text-text-main/70 hover:text-primary hover:bg-primary/10 transition-colors"
                      title="定位当前播放"
                    >
                      <Icon :icon="iconCurrentLocation" width="18" height="18" />
                    </Button>
                  </div>
                </div>
              </div>

              <SongListHeader
                v-if="activeTab === 'songs'"
                :sortField="sortField"
                :sortOrder="sortOrder"
                :showCover="true"
                paddingClass="px-5 md:px-6"
                @sort="handleSort"
              />
            </div>

            <div class="pb-safe relative z-[1]">
              <TabsContent value="songs" class="px-5 md:px-6 flex flex-col flex-1 min-h-0 pt-2">
                <SongList
                  ref="songListRef"
                  :songs="sortedSongs"
                  :searchQuery="searchQuery"
                  :loading="loadingSongs"
                  :active="activeTab === 'songs'"
                  :showCover="true"
                  :queueOptions="{
                    queueId: `queue:artist:${artist?.id ?? getArtistId()}`,
                    title: artist?.name || '歌手',
                    subtitle: '热门歌曲',
                    type: 'artist',
                  }"
                  :enableDefaultDoubleTapPlay="true"
                  :onSongDoubleTapPlay="
                    settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined
                  "
                />
              </TabsContent>

              <TabsContent value="albums" class="mt-4 px-5 md:px-6 pb-6">
                <VirtualGrid
                  class="px-2"
                  :items="albumCards"
                  :loading="loadingAlbums && albums.length === 0"
                  :active="activeTab === 'albums'"
                  :itemMinWidth="180"
                  :itemHeight="230"
                  :gap="20"
                  :overscan="3"
                  keyField="id"
                >
                  <template #default="{ item }">
                    <AlbumCard v-bind="item" />
                  </template>
                </VirtualGrid>
              </TabsContent>

              <TabsContent value="mvs" class="mt-4 px-5 md:px-6 pb-6">
                <div class="flex items-center gap-3 mb-4 px-2">
                  <div class="flex items-center gap-1.5">
                    <Button
                      v-for="opt in mvTagOptions"
                      :key="opt.value"
                      variant="unstyled"
                      size="none"
                      :class="['mv-tag-btn', mvTag === opt.value ? 'is-active' : '']"
                      @click="switchMvTag(opt.value)"
                    >
                      {{ opt.label }}
                    </Button>
                  </div>
                  <span v-if="mvFetched" class="text-[11px] text-text-secondary/60 ml-auto">
                    共 {{ mvTotal }} 个
                  </span>
                </div>
                <VirtualGrid
                  class="px-2"
                  :items="mvs"
                  :loading="loadingMvs && mvs.length === 0"
                  :active="activeTab === 'mvs'"
                  :itemMinWidth="200"
                  :itemHeight="180"
                  :gap="20"
                  :overscan="3"
                  keyField="videoId"
                >
                  <template #default="{ item }">
                    <MvCard v-bind="item" />
                  </template>
                </VirtualGrid>
              </TabsContent>
            </div>
          </Tabs>
        </div>
      </template>

      <template v-else>
        <div class="px-4 pt-3 relative z-10">
          <div class="flex items-start gap-3">
            <div class="w-14 h-14 rounded-full overflow-hidden shadow-lg shrink-0">
              <Cover :url="artist.pic" :size="160" :width="56" :height="56" />
            </div>
            <div class="min-w-0 flex-1 pt-0.5">
              <div class="text-[16px] font-extrabold text-text-main leading-snug line-clamp-2">{{ artist.name }}</div>
              <div class="flex items-center gap-2 mt-1">
                <span v-if="artist.fansCount" class="text-[12px] font-semibold text-text-main/70">{{ formatFansCount(artist.fansCount) }} 粉丝</span>
                <span v-if="artist.birthday" class="text-[11px] font-medium text-text-main/50">🎂 {{ artist.birthday }}</span>
              </div>
            </div>
          </div>

          <div class="flex items-center flex-wrap gap-1.5 mt-2.5">
            <span class="px-2 py-0.5 rounded text-[10px] font-bold tracking-[0.8px] uppercase text-primary bg-primary/10 border border-primary/15">ARTIST</span>
            <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-text-main/60 bg-black/5 dark:bg-white/5 px-2 py-0.5 rounded">
              {{ artist.songCount || songs.length }} 歌曲
            </span>
            <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-text-main/60 bg-black/5 dark:bg-white/5 px-2 py-0.5 rounded">
              {{ artist.albumCount || albums.length }} 专辑
            </span>
            <span v-if="artist.mvCount" class="inline-flex items-center gap-1 text-[11px] font-semibold text-text-main/60 bg-black/5 dark:bg-white/5 px-2 py-0.5 rounded">
              {{ artist.mvCount }} MV
            </span>
          </div>

          <div class="mt-2.5">
            <ActionRow
              :secondaryActions="secondaryActions"
              @play="handlePlayAll"
              @batch="openBatchDrawer"
            />
          </div>

          <div v-if="artist.intro" class="mt-2 pb-1">
            <div class="text-[12px] leading-relaxed text-text-secondary/70 line-clamp-2 cursor-pointer hover:text-text-main transition-colors" @click="showIntroDialog = true">
              {{ artist.intro }}
            </div>
          </div>
        </div>

        <Tabs v-model="activeTab" class="w-full relative z-10">
          <div class="song-list-sticky sticky z-[110] bg-bg-main" :style="{ top: `${tabsTop}px` }">
            <div class="border-b border-border-light/10 px-4">
              <div class="flex items-center justify-between h-10">
                <TabsList class="bg-transparent border-none gap-6">
                  <TabsTrigger value="songs" class="text-[13px]">
                    <span class="relative">歌曲 <Badge v-if="loadedSongCount > 0" :count="loadedSongCount" class="scale-90 origin-left" /></span>
                  </TabsTrigger>
                  <TabsTrigger value="albums" class="text-[13px]">
                    <span class="relative">专辑 <Badge v-if="albumFetched && albums.length > 0" :count="albums.length" class="-right-6 scale-90" /></span>
                  </TabsTrigger>
                  <TabsTrigger value="mvs" class="text-[13px]">
                    <span class="relative">MV <Badge v-if="mvFetched && mvs.length > 0" :count="mvs.length" class="-right-6 scale-90" /></span>
                  </TabsTrigger>
                </TabsList>

                <div v-if="activeTab === 'songs'" class="flex items-center gap-1.5">
                  <Button variant="unstyled" size="none" @click="handleLocate" class="song-locate-btn p-1.5 rounded-full text-text-main/60 hover:text-primary hover:bg-primary/10 transition-colors" title="定位当前播放">
                    <Icon :icon="iconCurrentLocation" width="16" height="16" />
                  </Button>
                </div>
              </div>
            </div>

            <SongListHeader
              v-if="activeTab === 'songs'"
              :sortField="sortField"
              :sortOrder="sortOrder"
              :showCover="true"
              paddingClass="px-4"
              @sort="handleSort"
            />
          </div>

          <div class="pb-safe relative z-[1]">
            <TabsContent value="songs" class="px-3 flex flex-col flex-1 min-h-0 pt-2">
              <SongList
                ref="songListRef"
                :songs="sortedSongs"
                :searchQuery="searchQuery"
                :loading="loadingSongs"
                :active="activeTab === 'songs'"
                :showCover="true"
                :queueOptions="{
                  queueId: `queue:artist:${artist?.id ?? getArtistId()}`,
                  title: artist?.name || '歌手',
                  subtitle: '热门歌曲',
                  type: 'artist',
                }"
                :enableDefaultDoubleTapPlay="true"
                :onSongDoubleTapPlay="
                  settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined
                "
              />
            </TabsContent>

            <TabsContent value="albums" class="mt-2 px-3 pb-4">
              <VirtualGrid
                class="px-2"
                :items="albumCards"
                :loading="loadingAlbums && albums.length === 0"
                :active="activeTab === 'albums'"
                :itemMinWidth="150"
                :itemHeight="200"
                :gap="16"
                :overscan="3"
                keyField="id"
              >
                <template #default="{ item }">
                  <AlbumCard v-bind="item" />
                </template>
              </VirtualGrid>
            </TabsContent>

            <TabsContent value="mvs" class="mt-2 px-3 pb-4">
              <div class="flex items-center flex-wrap gap-2 mb-3 px-2">
                <div class="flex items-center flex-wrap gap-1.5">
                  <Button
                    v-for="opt in mvTagOptions"
                    :key="opt.value"
                    variant="unstyled"
                    size="none"
                    :class="['mv-tag-btn', mvTag === opt.value ? 'is-active' : '']"
                    @click="switchMvTag(opt.value)"
                  >
                    {{ opt.label }}
                  </Button>
                </div>
                <span v-if="mvFetched" class="text-[11px] text-text-secondary/60 ml-auto">
                  共 {{ mvTotal }} 个
                </span>
              </div>
              <VirtualGrid
                class="px-2"
                :items="mvs"
                :loading="loadingMvs && mvs.length === 0"
                :active="activeTab === 'mvs'"
                :itemMinWidth="160"
                :itemHeight="140"
                :gap="16"
                :overscan="3"
                keyField="videoId"
              >
                <template #default="{ item }">
                  <MvCard v-bind="item" />
                </template>
              </VirtualGrid>
            </TabsContent>
          </div>
        </Tabs>
      </template>

      <BatchActionDrawer v-model:open="showBatchDrawer" :songs="songs" />

      <Dialog
        v-model:open="showIntroDialog"
        title="歌手介绍"
        :description="artist.intro"
        contentClass="detail-intro-dialog max-w-[720px]"
        descriptionClass="text-[13px] md:text-[14px] leading-relaxed"
        showClose
      />
    </template>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* 沉浸式弥散背景光晕 */
.artist-ambient-bg-wrap {
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

.artist-ambient-bg {
  width: 100%;
  height: 100%;
  background-size: cover;
  background-position: center;
  filter: blur(80px) saturate(160%);
  opacity: 0.35;
  transform: scale(1.3);
  transition: opacity 0.5s ease;
}

.dark .artist-ambient-bg {
  opacity: 0.25;
  filter: blur(90px) saturate(120%);
}

.artist-ambient-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(to bottom, transparent 0%, var(--color-bg-main) 95%);
}

.search-expand-enter-active,
.search-expand-leave-active {
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}
.search-expand-enter-from,
.search-expand-leave-to {
  opacity: 0;
  width: 0;
  transform: translateX(10px);
}

:deep(.song-list) {
  @apply px-0;
}

.mv-tag-btn {
  @apply px-3 py-1 md:py-1.5 rounded-lg text-[11px] md:text-[12px] font-semibold text-text-secondary/80 transition-all;
  background: transparent;
}

.mv-tag-btn:hover {
  @apply text-text-main;
  background: color-mix(in srgb, var(--color-text-main) 6%, transparent);
}

.mv-tag-btn.is-active {
  @apply text-primary;
  background: var(--color-primary-light);
}

.pb-safe {
  padding-bottom: max(24px, calc(env(safe-area-inset-bottom, 0px) + 24px));
}
</style>