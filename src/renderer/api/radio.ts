import request from '@/utils/request';

/**
 * 获取电台分类列表（含全部电台）
 */
export function getRadioClasses() {
  return request.get('/fm/class');
}

/**
 * 获取推荐电台
 */
export function getRadioRecommend() {
  return request.get('/fm/recommend');
}

/**
 * 获取电台歌曲列表
 * 注意：API 的 fmsize 参数会导致异常（只返回5首），因此不传该参数，让API使用默认值（20首/页）
 * @param fmid 电台 ID
 * @param fmoffset 歌曲偏移
 */
export function getRadioSongs(fmid: number | string, fmoffset = 0) {
  return request.get('/fm/songs', {
    params: { fmid, fmoffset },
  });
}

// ─── 电台歌曲预加载缓存 ───

interface PrefetchEntry {
  promise: Promise<unknown>;
  timestamp: number;
}

/** 按 fmid 缓存预加载的 Promise，避免重复请求 */
const prefetchCache = new Map<number, PrefetchEntry>();

/** 缓存有效期：5 分钟 */
const PREFETCH_TTL = 5 * 60 * 1000;

/**
 * 预加载电台前 3 页歌曲（悬停/触摸时调用，不阻塞 UI）
 */
export function prefetchRadioSongs(fmid: number): void {
  if (prefetchCache.has(fmid)) return;

  const promise = Promise.all([
    getRadioSongs(fmid, 0),
    getRadioSongs(fmid, 20),
    getRadioSongs(fmid, 40),
  ]);

  prefetchCache.set(fmid, { promise, timestamp: Date.now() });

  // 5 分钟后自动清除
  setTimeout(() => prefetchCache.delete(fmid), PREFETCH_TTL);
}

/**
 * 获取预加载缓存（RadioDetail 进入时调用）
 * 返回 3 页原始数据或 null（未命中时）
 */
export async function consumePrefetch(
  fmid: number,
): Promise<unknown[] | null> {
  const entry = prefetchCache.get(fmid);
  if (!entry) return null;

  // 过期检查
  if (Date.now() - entry.timestamp > PREFETCH_TTL) {
    prefetchCache.delete(fmid);
    return null;
  }

  try {
    const results = await entry.promise;
    prefetchCache.delete(fmid); // 一次性消费
    return results as unknown[];
  } catch {
    prefetchCache.delete(fmid);
    return null;
  }
}
