<script setup lang="ts">
defineOptions({ name: 'playlist-detail' });
import { ref, shallowRef, onMounted, onBeforeUnmount, computed, watch } from 'vue';
import { useRouteId } from '@/utils/useRouteId';
import { getPlaylistDetail, getPlaylistTracks } from '@/api/playlist';
import { getPlaylistComments } from '@/api/comment';
import SliverHeader from '@/components/music/DetailPageSliverHeader.vue';
import ActionRow from '@/components/music/DetailPageActionRow.vue';
import SongList from '@/components/music/SongList.vue';
import SongListHeader from '@/components/music/SongListHeader.vue';
import Avatar from '@/components/ui/Avatar.vue';
import Tabs from '@/components/ui/Tabs.vue';
import TabsList from '@/components/ui/TabsList.vue';
import TabsTrigger from '@/components/ui/TabsTrigger.vue';
import TabsContent from '@/components/ui/TabsContent.vue';
import Badge from '@/components/ui/Badge.vue';
import Dialog from '@/components/ui/Dialog.vue';
import CommentList from '@/components/music/CommentList.vue';
import BatchActionDrawer from '@/components/music/BatchActionDrawer.vue';
import type { Song } from '@/models/song';
import { formatDate } from '@/utils/format';
import { useUserStore } from '@/stores/user';
import Button from '@/components/ui/Button.vue';
import Tooltip from '@/components/ui/Tooltip.vue';
import { mapPlaylistMeta, resolvePlaylistTrackQueryId, mapCommentItem } from '@/utils/mappers';
import { parsePlaylistTracks } from '@/utils/mappers';
import type { PlaylistMeta } from '@/models/playlist';
import type { Comment } from '@/models/comment';
import type { SortField, SortOrder } from '@/components/music/SongListHeader.vue';
import { usePlaylistStore } from '@/stores/playlist';
import { usePlayerStore } from '@/stores/player';
import { useSettingStore } from '@/stores/setting';
import {
  iconCurrentLocation,
  iconSearch,
  iconPlay,
  iconList,
  iconMusic,
  iconHeart,
  iconHeartFilled,
  iconInfo,
} from '@/icons';
import { replaceQueueAndPlay } from '@/utils/playback';
import { useToastStore } from '@/stores/toast';
import { toRecord } from '../../../shared/object';
import { PagedSongLoader } from '@/utils/PagedSongLoader';
import { isGeckoView } from '@/utils/nativeBridge';
import Cover from '@/components/ui/Cover.vue';

const parseIntSafe = (value: unknown): number => {
  if (value == null) return 0;
  if (typeof value === 'number') return value;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isNaN(parsed) ? 0 : parsed;
};

const { id: currentId, onIdChange } = useRouteId();
const getPlaylistId = () => currentId.value;

const isPortrait = isGeckoView;

const loading = ref(true);
const playlist = ref<PlaylistMeta | null>(null);

// 使用 shallowRef 极大减少响应式开销
const songs = shallowRef<Song[]>([]);
const loadedSongCount = ref(0);

const playlistFilteredInvalidCount = ref(0);
const activeTab = ref('songs');
const loadingComments = ref(false);
const comments = ref<Comment[]>([]);
const hotComments = ref<Comment[]>([]);
const commentTotal = ref(0);
const commentPage = ref(1);
const hasMoreComments = ref(true);
const showIntroDialog = ref(false);
const showBatchDrawer = ref(false);

// 搜索和定位逻辑
const searchQuery = ref('');
const songListRef = ref<{ scrollToActive?: () => void } | null>(null);
const sliverHeaderRef = ref<{ currentHeight?: number } | null>(null);
const userStore = useUserStore();
const playlistStore = usePlaylistStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();
const toastStore = useToastStore();

const isOwnerPlaylist = computed(() => {
  const meta = playlist.value;
  const currentUserId = userStore.info?.userid;
  return !!meta && !!currentUserId && meta.listCreateUserid === currentUserId && meta.source !== 2;
});

const currentPlaylistIds = computed(() => {
  const meta = playlist.value;
  if (!meta) return [] as string[];
  return [meta.id, meta.listid, meta.listCreateListid, meta.globalCollectionId, meta.listCreateGid]
    .filter((item): item is string | number => item !== undefined && item !== null && item !== '')
    .map((item) => String(item));
});

const isFavoritePlaylist = computed(() => {
  if (!playlist.value) return false;
  const currentIds = currentPlaylistIds.value;
  if (currentIds.length === 0) return false;
  const currentUserId = userStore.info?.userid;
  return playlistStore.userPlaylists.some((entry) => {
    if (entry.source === 2) return false;
    if (currentUserId && entry.listCreateUserid === currentUserId) return false;
    const entryIds = [
      entry.id,
      entry.listid,
      entry.listCreateListid,
      entry.globalCollectionId,
      entry.listCreateGid,
    ]
      .filter((item): item is string | number => item !== undefined && item !== null && item !== '')
      .map((item) => String(item));
    return entryIds.some((id) => currentIds.includes(id));
  });
});

const songTotalCount = computed(() => {
  const metaCount = playlist.value?.count ?? 0;
  return metaCount > 0 ? metaCount : loadedSongCount.value;
});

const playlistTags = computed(() => {
  const raw = playlist.value?.tags ?? '';
  return raw
    .split(',')
    .map((tag) => tag.trim())
    .filter((tag) => tag.length > 0);
});

const playlistCommentId = computed(() => {
  const meta = playlist.value;
  if (!meta) return getPlaylistId();
  if (meta.globalCollectionId) return meta.globalCollectionId;
  if (meta.listCreateGid) return meta.listCreateGid;
  if (meta.listCreateUserid && meta.listCreateListid) {
    return `collection_3_${meta.listCreateUserid}_${meta.listCreateListid}_0`;
  }
  return getPlaylistId();
});

const fetchComments = async (reset = false) => {
  if (loadingComments.value) return;
  if (reset) {
    commentPage.value = 1;
    comments.value = [];
    hotComments.value = [];
    commentTotal.value = 0;
    hasMoreComments.value = true;
  }
  if (!hasMoreComments.value) return;

  loadingComments.value = true;
  try {
    const res = await getPlaylistComments(playlistCommentId.value, commentPage.value, 30, {
      showClassify: commentPage.value === 1,
      showHotwordList: commentPage.value === 1,
    });
    if (
      res &&
      typeof res === 'object' &&
      'status' in res &&
      (res as { status?: number }).status === 1
    ) {
      const record = toRecord(res);
      const data = toRecord(record.data ?? record.info ?? record);
      const listCandidate = data.list ?? data.comments ?? [];
      const hotCandidate = data.hot_list ?? data.weight_list ?? [];
      const list = Array.isArray(listCandidate) ? listCandidate : [];
      const hotList = Array.isArray(hotCandidate) ? hotCandidate : [];
      const mapped = list.map(mapCommentItem).filter((item) => item.content.length > 0);
      const mappedHot = hotList.map(mapCommentItem).filter((item) => item.content.length > 0);
      if (reset) {
        hotComments.value = mappedHot.map((item) => ({ ...item }));
      }
      comments.value = reset ? mapped : [...comments.value, ...mapped];

      const totalRaw =
        data.total ?? data.count ?? record.total ?? record.count ?? commentTotal.value;
      const totalValue = parseIntSafe(totalRaw);
      if (totalValue > 0) {
        commentTotal.value = totalValue;
        hasMoreComments.value = comments.value.length < totalValue;
      } else {
        hasMoreComments.value = mapped.length > 0;
      }

      if (hasMoreComments.value) {
        commentPage.value += 1;
      }
    } else {
      hasMoreComments.value = false;
    }
  } catch (e) {
    console.error('Fetch playlist comments error:', e);
    hasMoreComments.value = false;
  } finally {
    loadingComments.value = false;
  }
};

// 计算 Tabs 的 sticky top 位置
const tabsTop = computed(() => {
  if (isPortrait) return 0;
  return 56;
});

// 排序逻辑
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

const handleTabChange = (value: string | number) => {
  activeTab.value = String(value);
  if (value === 'comments' && comments.value.length === 0) {
    fetchComments(true);
  }
};

// 滚动加载更多评论
const maybeFetchMoreComments = () => {
  if (activeTab.value !== 'comments') return;
  if (loadingComments.value || !hasMoreComments.value) return;

  const scrollTop = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
  const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
  const fullHeight = document.documentElement.scrollHeight || document.body.scrollHeight || 0;

  if (fullHeight - scrollTop - viewportHeight <= 400) {
    fetchComments();
  }
};

// 歌曲分页加载器
let songLoader: PagedSongLoader<Song> | null = null;

const fetchData = async () => {
  loading.value = true;
  try {
    const detailRes = await getPlaylistDetail(getPlaylistId());
    if (detailRes) {
      const { status, data } = detailRes;
      if (status === 1) {
        if (data?.[0]) {
          playlist.value = mapPlaylistMeta(data?.[0]);
        }
      }
    }

    const playlistMeta = playlist.value;
    const currentUserId = userStore.info?.userid;
    const queryId = resolvePlaylistTrackQueryId(getPlaylistId(), {
      listid: playlistMeta?.listid,
      listCreateGid: playlistMeta?.listCreateGid,
      listCreateUserid: playlistMeta?.listCreateUserid,
      currentUserId,
    });

    if (songLoader) {
      songLoader.abort();
    }

    playlistFilteredInvalidCount.value = 0;

    songLoader = new PagedSongLoader<Song>(
      async (page, pageSize) => {
        const res = await getPlaylistTracks(queryId, page, pageSize);
        if (!res || typeof res !== 'object') return { items: [], hasMore: false };
        const hasStatus = 'status' in res;
        const statusOk = hasStatus && (res as { status?: number }).status === 1;
        const hasPayload = 'data' in res || 'info' in res;
        if (!statusOk && !hasPayload) return { items: [], hasMore: false };

        const payload =
          'data' in res
            ? (res as { data?: unknown }).data
            : 'info' in res
              ? (res as { info?: unknown }).info
              : res;
        const { songs: parsedSongs, filteredCount } = parsePlaylistTracks(payload ?? res);
        playlistFilteredInvalidCount.value += filteredCount;
        const hasMore = parsedSongs.length + filteredCount >= pageSize;
        return { items: parsedSongs, hasMore };
      },
      {
        pageSize: 200,
        concurrency: 3,
        dedupeKey: (song) => String(song.id),
        logTag: 'PlaylistDetailLoader',
        onPageLoaded(allItems) {
          songs.value = allItems.slice();
          loadedSongCount.value = allItems.length;
        },
        onComplete(allItems) {
          songs.value = allItems.slice();
          loadedSongCount.value = allItems.length;
        },
        onError() {
          toastStore.loadFailed('歌单歌曲');
        },
      },
    );

    await songLoader.loadFirstPage();

    const targetTotal = playlistMeta?.count ?? 0;
    if (!songLoader.fullyLoaded && targetTotal > songLoader.count) {
      void songLoader.loadRemaining();
    }
  } catch (e) {
    console.error('Fetch playlist error:', e);
  } finally {
    loading.value = false;
  }
};

onMounted(() => {
  fetchData();
  window.addEventListener('scroll', maybeFetchMoreComments, { passive: true });
});

onIdChange(() => {
  playlist.value = null;
  songs.value = [];
  loadedSongCount.value = 0;
  playlistFilteredInvalidCount.value = 0;
  comments.value = [];
  hotComments.value = [];
  commentPage.value = 1;
  commentTotal.value = 0;
  hasMoreComments.value = true;
  if (songLoader) {
    songLoader.abort();
    songLoader = null;
  }
  fetchData();
  if (activeTab.value === 'comments') {
    fetchComments(true);
  }
});

onBeforeUnmount(() => {
  window.removeEventListener('scroll', maybeFetchMoreComments);
});

watch(
  () => playlistCommentId.value,
  (nextId, prevId) => {
    if (nextId !== prevId && activeTab.value === 'comments') {
      fetchComments(true);
    }
  },
);

const secondaryActions = computed(() => {
  const actions = [] as {
    icon: typeof iconHeart;
    label: string;
    emphasized?: boolean;
    tone?: 'default' | 'favorite';
    onTap: () => void | Promise<void>;
  }[];

  if (!isOwnerPlaylist.value && userStore.isLoggedIn) {
    actions.push({
      icon: iconHeart,
      label: isFavoritePlaylist.value ? '已收藏' : '收藏',
      emphasized: isFavoritePlaylist.value,
      tone: 'favorite',
      onTap: async () => {
        if (!playlist.value) return;
        if (!userStore.isLoggedIn) return;
        if (isFavoritePlaylist.value) {
          await playlistStore.unfavoritePlaylist(playlist.value, userStore.info?.userid);
        } else {
          await playlistStore.favoritePlaylist(playlist.value, userStore.info?.userid);
        }
      },
    });
  }

  return actions;
});

const handleSongDoubleTapPlay = async (song: Song) => {
  await replaceQueueAndPlay(
    playlistStore,
    playerStore,
    songs.value,
    playlistFilteredInvalidCount.value,
    song,
    {
      queueId: `queue:playlist:${playlist.value?.id ?? getPlaylistId()}`,
      title: playlist.value?.name || '歌单',
      subtitle: playlist.value?.nickname || playlist.value?.list_create_username || '',
      type: 'playlist',
    },
  );
};

const handleRemovedFromPlaylist = (song: Song) => {
  songs.value = songs.value.filter((s) => String(s.id) !== String(song.id));
  loadedSongCount.value = songs.value.length;
  if (playlist.value && typeof playlist.value.count === 'number') {
    playlist.value = { ...playlist.value, count: Math.max(0, playlist.value.count - 1) };
  }
};

const handlePlayAll = async () => {
  if (songs.value.length === 0) return;
  const queueOpts = {
    queueId: `queue:playlist:${playlist.value?.id ?? getPlaylistId()}`,
    title: playlist.value?.name || '歌单',
    subtitle: playlist.value?.nickname || playlist.value?.list_create_username || '',
    type: 'playlist' as const,
  };
  await replaceQueueAndPlay(
    playlistStore,
    playerStore,
    songs.value,
    playlistFilteredInvalidCount.value,
    undefined,
    queueOpts,
  );
  if (songLoader && !songLoader.fullyLoaded) {
    const allSongs = await songLoader.waitForAll();
    if (allSongs.length > songs.value.length) {
      playlistStore.setPlaybackQueueWithOptions(
        allSongs.slice() as Song[],
        playlistFilteredInvalidCount.value,
        queueOpts,
      );
    }
  }
};
const openBatchDrawer = () => {
  if (songs.value.length === 0) return;
  showBatchDrawer.value = true;
};
const handleLocate = () => songListRef.value?.scrollToActive?.();

const activeSongId = computed(() => playerStore.currentTrackId ?? undefined);

const sortedSongs = computed(() => {
  const data = songs.value;
  if (!sortField.value || !sortOrder.value || data.length === 0) return data;
  if (sortField.value === 'index') {
    return sortOrder.value === 'asc' ? data : [...data].reverse();
  }

  const direction = sortOrder.value === 'asc' ? 1 : -1;
  const compareText = (a: string, b: string) =>
    a.localeCompare(b, 'zh-Hans-CN', { sensitivity: 'base' });

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
</script>

<template>
  <div class="playlist-detail-container bg-bg-main min-h-full relative">

    <div v-if="!isPortrait && playlist?.pic" class="playlist-ambient-bg-wrap">
      <div class="playlist-ambient-bg" :style="{ backgroundImage: `url(${playlist.pic})` }"></div>
      <div class="playlist-ambient-overlay"></div>
    </div>

    <div v-if="loading && !playlist" class="flex items-center justify-center py-40 relative z-10">
      <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
    </div>

    <template v-else-if="playlist">

      <!-- ═══ 横屏模式：使用 SliverHeader ═══ -->
      <template v-if="!isPortrait">
        <div class="relative z-10">
          <SliverHeader
            ref="sliverHeaderRef"
            typeLabel="PLAYLIST"
            :title="playlist.name"
            :coverUrl="playlist.pic"
            :hasDetails="true"
          >
            <template #details>
              <div class="flex flex-col gap-2.5 w-full items-start text-left">
                <div class="flex items-center gap-3">
                  <div class="flex items-center gap-2">
                    <Avatar :src="playlist.userPic" :size="24" class="rounded-full overflow-hidden shadow-sm" />
                    <span class="text-[14px] font-bold text-text-main hover:text-primary transition-colors cursor-pointer">{{
                      playlist.nickname || 'Unknown'
                    }}</span>
                  </div>
                  <span class="text-[12px] font-semibold text-text-main/60"
                    >{{ formatDate(playlist.publishDate || playlist.createTime, 'YYYY-MM-DD') }}
                    {{ playlist.publishDate ? '发布' : '创建' }}</span
                  >
                </div>
                <div class="flex items-center flex-wrap gap-2 text-[11px] font-semibold">
                  <span class="playlist-song-count inline-flex items-center gap-1.5 text-text-main/70 bg-black/5 dark:bg-white/5 px-2.5 py-1 rounded-md backdrop-blur-md">
                    <Icon :icon="iconMusic" width="13" height="13" />
                    <span>{{ songTotalCount }}</span>
                    <Tooltip
                      v-if="playlistFilteredInvalidCount > 0"
                      side="bottom"
                      align="center"
                      :side-offset="10"
                      contentClass="song-filter-tooltip"
                    >
                      <template #trigger>
                        <Button variant="unstyled" size="none" class="song-filter-info-btn rounded-full ml-1">
                          <Icon :icon="iconInfo" width="14" height="14" />
                        </Button>
                      </template>
                      <span class="block whitespace-pre-line"
                        >当前列表已过滤 {{ playlistFilteredInvalidCount }} 首无效歌曲</span
                      >
                      <span class="block whitespace-pre-line text-[11px] opacity-70 mt-1">通常是因为歌曲信息缺失无法参与播放</span>
                    </Tooltip>
                  </span>
                  <span
                    v-for="tag in playlistTags"
                    :key="tag"
                    class="px-2.5 py-1 rounded-md text-[11px] font-bold text-primary bg-primary/10 border border-primary/15 backdrop-blur-md"
                  >
                    {{ tag }}
                  </span>
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
                v-if="!isOwnerPlaylist && userStore.isLoggedIn"
                variant="unstyled"
                size="none"
                @click="
                  () => {
                    if (!playlist) return;
                    if (isFavoritePlaylist) {
                      playlistStore.unfavoritePlaylist(playlist, userStore.info?.userid);
                    } else {
                      playlistStore.favoritePlaylist(playlist, userStore.info?.userid);
                    }
                  }
                "
                class="p-2 rounded-full hover:bg-black/10 dark:hover:bg-white/10 text-red-500 transition-colors"
              >
                <Icon :icon="isFavoritePlaylist ? iconHeartFilled : iconHeart" width="20" height="20" />
              </Button>
              <Button
                variant="unstyled"
                size="none"
                @click="handlePlayAll"
                class="p-2 rounded-full hover:bg-black/10 dark:hover:bg-white/10 text-primary transition-colors"
              >
                <Icon :icon="iconPlay" width="22" height="22" />
              </Button>
              <Button
                variant="unstyled"
                size="none"
                @click="openBatchDrawer"
                class="p-2 rounded-full hover:bg-black/10 dark:hover:bg-white/10 text-text-main opacity-70 transition-colors"
              >
                <Icon :icon="iconList" width="20" height="20" />
              </Button>
            </template>
          </SliverHeader>

          <BatchActionDrawer
            v-model:open="showBatchDrawer"
            :songs="songs"
            :source-id="playlist?.listid || playlist?.id"
          />

          <div v-if="playlist.intro" class="px-5 md:px-6 pt-2 pb-4">
            <div class="mt-1 text-[13px] leading-relaxed text-text-secondary/80 line-clamp-2 cursor-pointer hover:text-text-main transition-colors" @click="showIntroDialog = true">
              {{ playlist.intro }}
            </div>
          </div>

          <Tabs :model-value="activeTab" class="w-full" @update:model-value="handleTabChange">
            <div class="song-list-sticky sticky z-[110] bg-bg-main/75 backdrop-blur-xl border-b border-border-light/10 transition-colors" :style="{ top: `${tabsTop}px` }">
              <div class="px-5 md:px-6">
                <div class="flex items-center justify-between h-14">
                  <TabsList class="bg-transparent border-none gap-6 md:gap-8">
                    <TabsTrigger value="songs" class="text-[14px] md:text-[15px]">
                      <span class="relative">歌曲 <Badge :count="loadedSongCount" class="scale-90 origin-left" /></span>
                    </TabsTrigger>
                    <TabsTrigger value="comments" class="text-[14px] md:text-[15px]">
                      <span class="relative">
                        评论
                        <Badge v-if="commentTotal > 0" :count="commentTotal" class="-right-6 scale-90" />
                      </span>
                    </TabsTrigger>
                  </TabsList>

                  <div v-if="activeTab === 'songs'" class="flex items-center gap-1.5 md:gap-3">
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
              <TabsContent value="songs" class="px-3 md:px-6 flex flex-col flex-1 min-h-0 pt-2">
                <SongList
                  ref="songListRef"
                  :songs="sortedSongs"
                  :loading="loading"
                  :active="activeTab === 'songs'"
                  :searchQuery="searchQuery"
                  :activeId="activeSongId"
                  :showCover="true"
                  :queueOptions="{
                    queueId: `queue:playlist:${playlist?.id ?? getPlaylistId()}`,
                    title: playlist?.name || '歌单',
                    subtitle: playlist?.nickname || playlist?.list_create_username || '',
                    type: 'playlist',
                  }"
                  :queueFilteredInvalidCount="playlistFilteredInvalidCount"
                  :enableDefaultDoubleTapPlay="true"
                  :onSongDoubleTapPlay="
                    settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined
                  "
                  :parentPlaylistId="playlist.listid || playlist.id"
                  :enableRemoveFromPlaylist="isOwnerPlaylist"
                  :onRemovedFromPlaylist="handleRemovedFromPlaylist"
                />
              </TabsContent>

              <TabsContent value="comments" class="px-5 md:px-6 pt-5 pb-10">
                <div class="w-full">
                  <div v-if="hotComments.length" class="text-[14px] font-bold text-text-main mt-2 mb-4">热门评论</div>
                  <CommentList :comments="hotComments" :loading="loadingComments" resourceType="playlist" :fallbackMixSongId="String(currentId)" compact hide-empty />
                  <div v-if="comments.length" class="text-[14px] font-bold text-text-main mt-6 mb-4">最新评论</div>
                  <CommentList :comments="comments" :loading="loadingComments" :total="commentTotal" resourceType="playlist" :fallbackMixSongId="String(currentId)" compact :hide-empty="hotComments.length > 0" />
                  <div v-if="loadingComments || ((hotComments.length > 0 || comments.length > 0) && !hasMoreComments)" class="flex justify-center mt-8">
                    <div class="text-[12px] font-semibold text-text-secondary/60">{{ loadingComments ? '加载中...' : '已加载全部评论' }}</div>
                  </div>
                </div>
              </TabsContent>
            </div>
          </Tabs>
        </div>
      </template>

      <!-- ═══ 竖屏模式：紧凑布局 ═══ -->
      <template v-else>
        <BatchActionDrawer
          v-model:open="showBatchDrawer"
          :songs="songs"
          :source-id="playlist?.listid || playlist?.id"
        />

        <!-- 头部详情（跟随滚动） -->
        <div class="px-4 pt-3">
          <div class="flex items-start gap-3">
            <div class="w-14 h-14 rounded-xl overflow-hidden shadow-lg shrink-0">
              <Cover :url="playlist.pic" :size="160" :width="56" :height="56" />
            </div>
            <div class="min-w-0 flex-1 pt-0.5">
              <div class="text-[16px] font-extrabold text-text-main leading-snug line-clamp-2">{{ playlist.name }}</div>
              <div class="flex items-center gap-2 mt-1">
                <Avatar :src="playlist.userPic" :size="16" class="rounded-full overflow-hidden" />
                <span class="text-[12px] font-semibold text-text-main/70">{{ playlist.nickname || 'Unknown' }}</span>
                <span class="text-[11px] font-medium text-text-main/50">{{ formatDate(playlist.publishDate || playlist.createTime, 'YYYY-MM-DD') }} {{ playlist.publishDate ? '发布' : '创建' }}</span>
              </div>
            </div>
          </div>

          <div class="flex items-center flex-wrap gap-1.5 mt-2.5">
            <span class="px-2 py-0.5 rounded text-[10px] font-bold tracking-[0.8px] uppercase text-primary bg-primary/10 border border-primary/15">PLAYLIST</span>
            <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-text-main/60 bg-black/5 dark:bg-white/5 px-2 py-0.5 rounded">
              <Icon :icon="iconMusic" width="11" height="11" />
              {{ songTotalCount }} 首
              <Tooltip v-if="playlistFilteredInvalidCount > 0" side="bottom" align="center" :side-offset="6" contentClass="song-filter-tooltip">
                <template #trigger>
                  <Button variant="unstyled" size="none" class="song-filter-info-btn rounded-full">
                    <Icon :icon="iconInfo" width="12" height="12" />
                  </Button>
                </template>
                <span class="block whitespace-pre-line">当前列表已过滤 {{ playlistFilteredInvalidCount }} 首无效歌曲</span>
              </Tooltip>
            </span>
            <span
              v-for="tag in playlistTags"
              :key="tag"
              class="px-2 py-0.5 rounded text-[11px] font-bold text-primary/80 bg-primary/8 border border-primary/10"
            >
              {{ tag }}
            </span>
          </div>

          <div class="mt-2.5">
            <ActionRow
              :secondaryActions="secondaryActions"
              @play="handlePlayAll"
              @batch="openBatchDrawer"
            />
          </div>

          <div v-if="playlist.intro" class="mt-2 pb-1">
            <div class="text-[12px] leading-relaxed text-text-secondary/70 line-clamp-2 cursor-pointer hover:text-text-main transition-colors" @click="showIntroDialog = true">
              {{ playlist.intro }}
            </div>
          </div>
        </div>

        <Tabs :model-value="activeTab" class="w-full" @update:model-value="handleTabChange">
          <div class="song-list-sticky sticky z-[110] bg-bg-main" :style="{ top: `${tabsTop}px` }">
            <div class="border-b border-border-light/10 px-4">
              <div class="flex items-center justify-between h-10">
                <TabsList class="bg-transparent border-none gap-6">
                  <TabsTrigger value="songs" class="text-[13px]">
                    <span class="relative">歌曲 <Badge :count="loadedSongCount" class="scale-90 origin-left" /></span>
                  </TabsTrigger>
                  <TabsTrigger value="comments" class="text-[13px]">
                    <span class="relative">
                      评论
                      <Badge v-if="commentTotal > 0" :count="commentTotal" class="-right-6 scale-90" />
                    </span>
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
                :loading="loading"
                :active="activeTab === 'songs'"
                :searchQuery="searchQuery"
                :activeId="activeSongId"
                :showCover="true"
                :queueOptions="{
                  queueId: `queue:playlist:${playlist?.id ?? getPlaylistId()}`,
                  title: playlist?.name || '歌单',
                  subtitle: playlist?.nickname || playlist?.list_create_username || '',
                  type: 'playlist',
                }"
                :queueFilteredInvalidCount="playlistFilteredInvalidCount"
                :enableDefaultDoubleTapPlay="true"
                :onSongDoubleTapPlay="settingStore.replacePlaylist ? handleSongDoubleTapPlay : undefined"
                :parentPlaylistId="playlist.listid || playlist.id"
                :enableRemoveFromPlaylist="isOwnerPlaylist"
                :onRemovedFromPlaylist="handleRemovedFromPlaylist"
              />
            </TabsContent>

            <TabsContent value="comments" class="px-4 pt-4 pb-10">
              <div class="w-full">
                <div v-if="hotComments.length" class="text-[13px] font-bold text-text-main mt-1 mb-3">热门评论</div>
                <CommentList :comments="hotComments" :loading="loadingComments" resourceType="playlist" :fallbackMixSongId="String(currentId)" compact hide-empty />
                <div v-if="comments.length" class="text-[13px] font-bold text-text-main mt-5 mb-3">最新评论</div>
                <CommentList :comments="comments" :loading="loadingComments" :total="commentTotal" resourceType="playlist" :fallbackMixSongId="String(currentId)" compact :hide-empty="hotComments.length > 0" />
                <div v-if="loadingComments || ((hotComments.length > 0 || comments.length > 0) && !hasMoreComments)" class="flex justify-center mt-6">
                  <div class="text-[11px] font-semibold text-text-secondary/60">{{ loadingComments ? '加载中...' : '已加载全部评论' }}</div>
                </div>
              </div>
            </TabsContent>
          </div>
        </Tabs>
      </template>

      <Dialog
        v-model:open="showIntroDialog"
        :title="'歌单介绍'"
        :description="playlist.intro"
        contentClass="detail-intro-dialog max-w-[720px]"
        descriptionClass="text-[14px] leading-relaxed"
        showClose
      />
    </template>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* 沉浸式弥散背景光晕 */
.playlist-ambient-bg-wrap {
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

.playlist-ambient-bg {
  width: 100%;
  height: 100%;
  background-size: cover;
  background-position: center;
  filter: blur(80px) saturate(160%);
  opacity: 0.35;
  transform: scale(1.3);
  transition: opacity 0.5s ease;
}

.dark .playlist-ambient-bg {
  opacity: 0.25;
  filter: blur(90px) saturate(120%);
}

.playlist-ambient-overlay {
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

.playlist-song-count {
  gap: 4px;
}

.song-filter-info-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  color: #f59e0b;
  transition: all 0.2s ease;
}

.song-filter-info-btn:hover {
  color: #d97706;
  background: rgba(245, 158, 11, 0.14);
}

.song-filter-info-btn:active {
  transform: scale(0.96);
}

:deep(.song-filter-tooltip) {
  max-width: 280px;
  padding: 10px 12px;
  border-radius: 12px;
  background: var(--color-bg-card);
  color: var(--color-text-main);
  font-size: 12px;
  font-weight: 600;
  line-height: 1.45;
  box-shadow: 0 14px 28px rgba(0, 0, 0, 0.12);
  z-index: 150;
}

:deep(.song-list) {
  @apply px-0;
}

.pb-safe {
  padding-bottom: max(24px, calc(env(safe-area-inset-bottom, 0px) + 24px));
}

.comment-load-more {
  display: flex;
  justify-content: center;
  margin: 18px 0 12px;
}

.comment-loading-inline {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  font-size: 12px;
  font-weight: 600;
  color: var(--color-text-secondary);
}

.comment-end-hint {
  font-size: 12px;
  font-weight: 600;
  color: color-mix(in srgb, var(--color-text-main) 42%, transparent);
}

.comment-loading-spinner {
  width: 16px;
  height: 16px;
  border-radius: 999px;
  border: 2px solid color-mix(in srgb, var(--color-primary) 28%, transparent);
  border-top-color: var(--color-primary);
  animation: comment-spin 0.8s linear infinite;
}

@keyframes comment-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>