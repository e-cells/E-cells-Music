import { getSongMv, getVideoDetail, getVideoPrivilege, getVideoUrl } from '@/api/video';
import {
  extractVideoUrl,
  mapVideoMeta,
  mapVideoMetaList,
  mapVideoSourcesFromPrivilege,
  mergeVideoSources,
} from '@/utils/mappers/video';
import type { VideoSource } from '@/models/video';
import { usePlayerStore } from '@/stores/player';
import { useToastStore } from '@/stores/toast';
import { useMvPlaylistStore } from '@/stores/mvPlaylist';
import { useSettingStore } from '@/stores/setting';
import { isGeckoView, NativeMvPlayerBridge } from '@/utils/nativeBridge';
import router from '@/router';

export interface LaunchMvOptions {
  hash: string;
  videoId?: string;
  albumAudioId?: string;
  title?: string;
  artist?: string;
  cover?: string;
}

const isMobileNative = isGeckoView || /Android/i.test(navigator.userAgent);

/** 所有环境优先 H.264（原生软解码需要，Web 浏览器兼容性最佳） */
const pickPreferredSource = (sources: VideoSource[]): VideoSource | null => {
  if (!sources.length) return null;
  const h264 = sources.find((s) => s.codec === 'H.264');
  if (h264) return h264;
  return sources[0];
};

/** 将片源列表编码为 "hash|label,hash|label,..." 格式供原生层使用 */
const encodeSourceHashes = (sources: VideoSource[], preferred: VideoSource): string => {
  // 把首选源排到第一个
  const ordered = [preferred, ...sources.filter((s) => s.hash !== preferred.hash)];
  return ordered
    .map((s) => {
      const parts: string[] = [];
      parts.push(s.label || '默认');
      if (s.codec) parts.push(s.codec);
      return `${s.hash}|${parts.join(' ')}`;
    })
    .join(',');
};

let launchGeneration = 0;

/**
 * 统一的 MV 启动函数。
 * 跳过详情页，直接获取元数据、解析最佳片源、启动原生播放器。
 */
export async function launchMv(options: LaunchMvOptions): Promise<void> {
  const { hash, videoId, albumAudioId, title, artist, cover } = options;

  if (!hash && !videoId) return;
  if (!isGeckoView) {
    // Web 端：导航到 MV 详情页，由详情页的 HTML5 播放器处理
    router.push({
      name: 'mv-detail',
      params: { id: hash || videoId },
      query: {
        ...(hash && { hash }),
        ...(videoId && { videoId }),
        ...(albumAudioId && { albumAudioId }),
        ...(title && { title }),
        ...(artist && { artist }),
        ...(cover && { cover }),
      },
    });
    return;
  }

  const gen = ++launchGeneration;

  const playerStore = usePlayerStore();
  const toastStore = useToastStore();
  const mvPlaylistStore = useMvPlaylistStore();

  // 暂停音乐
  if (playerStore.isPlaying) {
    await playerStore.togglePlay().catch(() => undefined);
  }

  const loadingToastId = toastStore.show('正在加载 MV ...');

  try {
    // ── 并行获取 MV 元数据 ──
    const tasks: Promise<unknown>[] = [];
    if (albumAudioId) tasks.push(getSongMv(albumAudioId));
    if (videoId && videoId !== hash) tasks.push(getVideoDetail(videoId));
    if (hash) tasks.push(getVideoPrivilege(hash));

    // 合并所有片源
    let allSources: VideoSource[] = [];
    let fallbackTitle = title || 'MV播放';
    let fallbackArtist = artist || '';
    let fallbackCover = cover || '';
    let bestHash = hash;

    if (tasks.length > 0) {
      const results = await Promise.allSettled(tasks);
      for (const result of results) {
        if (result.status !== 'fulfilled') continue;
        const payload = result.value;

        // 合并元数据
        const meta = mapVideoMeta(payload, hash);
        if (meta) {
          if (meta.title && meta.title !== 'MV播放') fallbackTitle = meta.title;
          if (meta.artistName) fallbackArtist = meta.artistName;
          if (meta.coverUrl) fallbackCover = meta.coverUrl;
        }

        // 合并片源
        const versionList = mapVideoMetaList(payload);
        if (versionList.length > 0 && versionList[0].sources) {
          allSources = mergeVideoSources(allSources, versionList[0].sources);
        }
        if (meta?.sources) {
          allSources = mergeVideoSources(allSources, meta.sources);
        }
        const privSources = mapVideoSourcesFromPrivilege(payload);
        if (privSources.length) {
          allSources = mergeVideoSources(allSources, privSources);
        }
      }
    }

    if (gen !== launchGeneration) return;

    // 如果没获取到片源，使用传入的 hash 作为唯一源
    if (allSources.length === 0 && hash) {
      allSources = [{ hash, url: '', label: '默认', codec: '' }];
    }

    // 选择首选片源
    const preferred = pickPreferredSource(allSources) ?? allSources[0];
    bestHash = preferred.hash;

    // ── 获取播放 URL ──
    const response = await getVideoUrl(bestHash);
    if (gen !== launchGeneration) return;
    const url = extractVideoUrl(response, bestHash, isMobileNative);
    if (!url) throw new Error('empty-url');

    // ── 构建源列表字符串 ──
    const sourceHashes = allSources.length > 1 ? encodeSourceHashes(allSources, preferred) : '';

    // ── 检测横屏 ──
    const isLandscape =
      typeof window !== 'undefined' && window.innerWidth > window.innerHeight;

    // ── 启动原生播放器 ──
    mvPlaylistStore.setupListeners();

    await NativeMvPlayerBridge.openMvPlayer({
      url,
      title: fallbackTitle,
      author: fallbackArtist,
      coverUrl: fallbackCover,
      hash: bestHash,
      sourceHashes,
      autoFullscreen: isLandscape ? 'true' : 'false',
      screenOrientation: useSettingStore().screenOrientation,
    });

export interface MvPlaylistItem {
  hash: string;
  title: string;
  artist: string;
  coverUrl: string;
}

/**
 * 带播放列表的 MV 启动函数。
 * 用于点击单个 MV 卡片时，将当前列表所有 MV 加载为播放列表并从点击项开始播放。
 */
export async function launchMvWithPlaylist(options: {
  playlist: MvPlaylistItem[];
  startIndex: number;
  hash: string;
  videoId?: string;
  albumAudioId?: string;
  title?: string;
  artist?: string;
  cover?: string;
}): Promise<void> {
  const { playlist, startIndex } = options;

  if (!playlist.length || startIndex < 0 || startIndex >= playlist.length) return;
  if (!isGeckoView) {
    // Web 端：导航到 MV 详情页
    const item = playlist[startIndex];
    router.push({
      name: 'mv-detail',
      params: { id: item.hash || options.hash || options.videoId },
      query: {
        hash: item.hash || options.hash,
        ...(options.videoId && { videoId: options.videoId }),
        ...(options.albumAudioId && { albumAudioId: options.albumAudioId }),
        title: item.title || options.title,
        artist: item.artist || options.artist,
        cover: item.coverUrl || options.cover,
      },
    });
    return;
  }

  const gen = ++launchGeneration;

  const playerStore = usePlayerStore();
  const toastStore = useToastStore();
  const mvPlaylistStore = useMvPlaylistStore();

  // 暂停音乐
  if (playerStore.isPlaying) {
    await playerStore.togglePlay().catch(() => undefined);
  }

  const loadingToastId = toastStore.show('正在加载 MV ...');

  try {
    const isLandscape =
      typeof window !== 'undefined' && window.innerWidth > window.innerHeight;

    // 并行获取 MV 元数据和片源（复用 launchMv 的片源解析逻辑）
    const { videoId, albumAudioId, title, artist, cover } = options;
    const tasks: Promise<unknown>[] = [];
    if (albumAudioId) tasks.push(getSongMv(albumAudioId));
    if (videoId && videoId !== options.hash) tasks.push(getVideoDetail(videoId));
    if (options.hash) tasks.push(getVideoPrivilege(options.hash));

    let allSources: VideoSource[] = [];
    let bestHash = options.hash;

    if (tasks.length > 0) {
      const results = await Promise.allSettled(tasks);
      for (const result of results) {
        if (result.status !== 'fulfilled') continue;
        const payload = result.value;
        const meta = mapVideoMeta(payload, options.hash);
        const versionList = mapVideoMetaList(payload);
        if (versionList.length > 0 && versionList[0].sources) {
          allSources = mergeVideoSources(allSources, versionList[0].sources);
        }
        if (meta?.sources) {
          allSources = mergeVideoSources(allSources, meta.sources);
        }
        const privSources = mapVideoSourcesFromPrivilege(payload);
        if (privSources.length) {
          allSources = mergeVideoSources(allSources, privSources);
        }
      }
    }

    if (gen !== launchGeneration) return;

    if (allSources.length === 0 && options.hash) {
      allSources = [{ hash: options.hash, url: '', label: '默认', codec: '' }];
    }

    const preferred = pickPreferredSource(allSources) ?? allSources[0];
    bestHash = preferred.hash;

    // 获取播放 URL
    const response = await getVideoUrl(bestHash);
    if (gen !== launchGeneration) return;
    const url = extractVideoUrl(response, bestHash, isMobileNative);
    if (!url) throw new Error('empty-url');

    const sourceHashes = allSources.length > 1 ? encodeSourceHashes(allSources, preferred) : '';

    // 设置播放列表 store 并注册事件监听
    mvPlaylistStore.setPlaylist(playlist, startIndex);
    mvPlaylistStore.setupListeners();

    // 启动原生 Activity，传递播放列表
    await NativeMvPlayerBridge.openMvPlayer({
      url,
      title: title || playlist[startIndex].title,
      author: artist || playlist[startIndex].artist,
      coverUrl: cover || playlist[startIndex].coverUrl,
      hash: bestHash,
      playlist: JSON.stringify(playlist),
      startIndex,
      sourceHashes,
      autoFullscreen: isLandscape ? 'true' : 'false',
      screenOrientation: useSettingStore().screenOrientation,
    });

    toastStore.remove(loadingToastId);
  } catch {
    if (gen !== launchGeneration) return;
    toastStore.loadFailed('MV');
  }
}
