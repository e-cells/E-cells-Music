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
 * @param fmid 电台 ID，可以传多个以逗号分割
 * @param fmoffset 歌曲偏移
 */
export function getRadioSongs(fmid: number | string, fmoffset = 0) {
  return request.get('/fm/songs', {
    params: { fmid, fmoffset },
  });
}
