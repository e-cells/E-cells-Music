import type { Song } from '@/models/song';

const CACHE_PREFIX = 'radio_songs_';
const INDEX_KEY = 'radio_songs_index';
const CACHE_VERSION = 2;
/** 缓存有效期：30 分钟 */
const CACHE_TTL = 30 * 60 * 1000;
/** 最大缓存条目数 */
const MAX_CACHE_ENTRIES = 15;

// ─── 缓存精简字段：只保留展示和播放必需的字段 ───

interface CachedRadioSong {
  id: string;
  title: string;
  artist: string;
  album?: string;
  duration: number;
  coverUrl: string;
  hash: string;
  mixSongId: string | number;
  audioUrl: string;
  songId?: string;
  albumId?: string;
  artists?: Song['artists'];
  singers?: Song['singers'];
  privilege?: number;
  payType?: number;
}

interface RadioCacheEntry {
  version: number;
  timestamp: number;
  songs: CachedRadioSong[];
}

// ─── LRU 索引管理 ───

interface IndexEntry {
  fmid: number;
  timestamp: number;
}

function loadIndex(): IndexEntry[] {
  try {
    const raw = localStorage.getItem(INDEX_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveIndex(index: IndexEntry[]): void {
  try {
    localStorage.setItem(INDEX_KEY, JSON.stringify(index));
  } catch {
    // 静默忽略
  }
}

function touchIndex(fmid: number): void {
  const index = loadIndex().filter((e) => e.fmid !== fmid);
  index.push({ fmid, timestamp: Date.now() });
  saveIndex(index);
}

function evictOldest(): void {
  const index = loadIndex();
  if (index.length === 0) return;
  // 按时间排序，删除最旧的
  index.sort((a, b) => a.timestamp - b.timestamp);
  const oldest = index.shift();
  if (oldest) {
    localStorage.removeItem(`${CACHE_PREFIX}${oldest.fmid}`);
    saveIndex(index);
  }
}

// ─── Song ↔ CachedRadioSong 转换 ───

const CACHE_KEYS = new Set([
  'id', 'title', 'artist', 'album', 'duration',
  'coverUrl', 'hash', 'mixSongId', 'audioUrl',
  'songId', 'albumId', 'artists', 'singers',
  'privilege', 'payType',
]);

function toCachedSong(song: Song): CachedRadioSong {
  const cached: Record<string, unknown> = {};
  const source = song as unknown as Record<string, unknown>;
  for (const key of CACHE_KEYS) {
    if (source[key] !== undefined) {
      cached[key] = source[key];
    }
  }
  return cached as unknown as CachedRadioSong;
}

function toSong(cached: CachedRadioSong): Song {
  return cached as unknown as Song;
}

// ─── 公共 API ───

/**
 * 保存电台歌曲到 localStorage（精简字段 + LRU 淘汰）
 */
export function saveRadioSongs(fmid: number, songs: Song[]): void {
  try {
    const cachedSongs = songs.map(toCachedSong);
    const entry: RadioCacheEntry = {
      version: CACHE_VERSION,
      timestamp: Date.now(),
      songs: cachedSongs,
    };
    localStorage.setItem(`${CACHE_PREFIX}${fmid}`, JSON.stringify(entry));
    touchIndex(fmid);
  } catch {
    // localStorage 满，尝试淘汰最旧条目后重试
    evictOldest();
    try {
      const cachedSongs = songs.map(toCachedSong);
      const entry: RadioCacheEntry = {
        version: CACHE_VERSION,
        timestamp: Date.now(),
        songs: cachedSongs,
      };
      localStorage.setItem(`${CACHE_PREFIX}${fmid}`, JSON.stringify(entry));
      touchIndex(fmid);
    } catch {
      // 仍然失败，静默忽略
    }
  }

  // 检查缓存条目数上限
  const index = loadIndex();
  while (index.length > MAX_CACHE_ENTRIES) {
    const oldest = index.shift();
    if (oldest) {
      localStorage.removeItem(`${CACHE_PREFIX}${oldest.fmid}`);
    }
  }
  saveIndex(index);
}

/**
 * 读取电台歌曲缓存
 * 返回缓存的歌曲数组，过期或不存在返回 null
 */
export function loadRadioSongs(fmid: number): Song[] | null {
  try {
    const raw = localStorage.getItem(`${CACHE_PREFIX}${fmid}`);
    if (!raw) return null;

    const entry: RadioCacheEntry = JSON.parse(raw);

    // 版本不匹配
    if (entry.version !== CACHE_VERSION) {
      localStorage.removeItem(`${CACHE_PREFIX}${fmid}`);
      return null;
    }

    // 过期
    if (Date.now() - entry.timestamp > CACHE_TTL) {
      localStorage.removeItem(`${CACHE_PREFIX}${fmid}`);
      return null;
    }

    // 更新访问时间（LRU）
    touchIndex(fmid);

    return entry.songs.map(toSong);
  } catch {
    return null;
  }
}

/**
 * 清除指定电台缓存
 */
export function clearRadioCache(fmid: number): void {
  localStorage.removeItem(`${CACHE_PREFIX}${fmid}`);
  const index = loadIndex().filter((e) => e.fmid !== fmid);
  saveIndex(index);
}

/**
 * 清除所有电台歌曲缓存
 */
export function clearAllRadioCache(): void {
  const keysToRemove: string[] = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key?.startsWith(CACHE_PREFIX)) {
      keysToRemove.push(key);
    }
  }
  keysToRemove.forEach((key) => localStorage.removeItem(key));
  localStorage.removeItem(INDEX_KEY);
}
