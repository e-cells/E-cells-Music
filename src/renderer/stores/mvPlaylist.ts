import { defineStore } from 'pinia';
import { ref } from 'vue';
import { getVideoUrl } from '@/api/video';
import { extractVideoUrl } from '@/utils/mappers/video';
import logger from '@/utils/logger';
import { NativeMvPlayerBridge, addListener } from '@/utils/nativeBridge';

export interface MvPlaylistItem {
  hash: string;
  title: string;
  artist: string;
  coverUrl: string;
}

export const useMvPlaylistStore = defineStore('mv-playlist', () => {
  const playlist = ref<MvPlaylistItem[]>([]);
  const currentIndex = ref(-1);
  const isPlaying = ref(false);
  const resolveInProgress = ref(false);

  // 事件监听器移除函数
  let removeListenerFn: (() => void) | null = null;

  const setPlaylist = (items: MvPlaylistItem[], startIndex: number) => {
    playlist.value = items;
    currentIndex.value = startIndex;
    isPlaying.value = true;
  };

  /**
   * 设置 Native→Vue 事件监听器。
   * MvPlayerActivity 在需要下一个/上一个 MV 时发射事件，
   * 此处接收事件、解析 URL、回传给原生 Activity。
   */
  const setupListeners = () => {
    if (removeListenerFn) return; // 已注册

    removeListenerFn = addListener('mvPlaylistNeedUrl', (data: any) => {
      const index = typeof data?.index === 'number' ? data.index : -1;
      const hash = typeof data?.hash === 'string' ? data.hash : '';
      if (index < 0 || !hash) return;
      resolveAndSendUrl(index, hash);
    }).remove;
  };

  /**
   * 解析指定索引的 MV URL 并回传给原生 Activity。
   */
  const resolveAndSendUrl = async (index: number, hash: string) => {
    if (resolveInProgress.value) return;
    if (index < 0 || index >= playlist.value.length) return;

    resolveInProgress.value = true;
    try {
      const item = playlist.value[index];
      const response = await getVideoUrl(hash);
      const isMobileNative =
        typeof window !== 'undefined' &&
        !!(window as any).__GECKOVIEW__;
      const url = extractVideoUrl(response, hash, isMobileNative);

      if (!url) {
        logger.warn('MV playlist: failed to resolve URL for index', index);
        return;
      }

      currentIndex.value = index;
      await NativeMvPlayerBridge.loadMvVideo({
        url,
        title: item.title,
        author: item.artist,
        coverUrl: item.coverUrl,
        index,
      });
    } catch (e) {
      logger.warn('MV playlist: resolve error for index', index, e);
    } finally {
      resolveInProgress.value = false;
    }
  };

  const clear = () => {
    playlist.value = [];
    currentIndex.value = -1;
    isPlaying.value = false;
    cleanup();
  };

  const cleanup = () => {
    if (removeListenerFn) {
      removeListenerFn();
      removeListenerFn = null;
    }
  };

  return {
    playlist,
    currentIndex,
    isPlaying,
    resolveInProgress,
    setPlaylist,
    setupListeners,
    resolveAndSendUrl,
    clear,
    cleanup,
  };
});
