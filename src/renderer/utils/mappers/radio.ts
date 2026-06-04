import type { Song } from '@/models/song';
import type { RadioMeta } from '@/models/radio';
import {
  EMPTY_RECORD,
  formatPic,
  getCoverUrl,
  getRecord,
  normalizeText,
  parseIntSafe,
  parseOptionalInt,
  pickValue,
  processSongTitle,
  readString,
  toRecord,
} from './shared';

/**
 * 将 /fm/class 和 /fm/recommend 的原始数据映射为 RadioMeta
 */
export const mapRadioMeta = (json: unknown): RadioMeta => {
  const record = toRecord(json);

  return {
    fmid: parseIntSafe(pickValue(record.fmid, 0)),
    name: normalizeText(readString(pickValue(record.fmname, ''), '')),
    description: normalizeText(readString(pickValue(record.description, ''), '')),
    coverUrl: formatPic(pickValue(record.imgurl, '')),
    bannerUrl: formatPic(pickValue(record.banner, '')),
    fmtype: parseIntSafe(pickValue(record.fmtype, 0)),
    classid: parseOptionalInt(pickValue(record.classid, undefined)),
    classname: normalizeText(readString(pickValue(record.classname, ''), '')),
    heat: parseOptionalInt(pickValue(record.heat, undefined)),
    position: parseOptionalInt(pickValue(record.position, undefined)),
    parentId: parseOptionalInt(pickValue(record.parentId, undefined)),
    broadcastType: readString(pickValue(record.broadcast_type, ''), '') || undefined,
  };
};

/**
 * 将 /fm/songs 返回的歌曲数据映射为 Song
 *
 * API 返回的 name 字段格式为 "歌手 - 歌名"
 * time 字段为毫秒
 */
export const mapRadioSong = (json: unknown): Song => {
  const record = toRecord(json);
  const transParam = getRecord(record, 'trans_param') ?? EMPTY_RECORD;

  // name 格式: "歌手 - 歌名"
  const rawName = readString(pickValue(record.name, record.songname, ''), '');
  const title = processSongTitle(rawName);
  let artistName = '';
  if (rawName.includes(' - ')) {
    artistName = rawName.split(' - ')[0].trim();
  }

  const hash = readString(pickValue(record.hash, ''), '');
  const cover = formatPic(pickValue(transParam.union_cover, ''));
  const durationRaw = parseIntSafe(pickValue(record.time, record['320time'], 0));
  // time 可能是毫秒（>10000）或秒
  const duration = durationRaw > 10000 ? Math.floor(durationRaw / 1000) : durationRaw;
  const albumName = normalizeText(readString(pickValue(record.album_name, record.albumname, ''), ''));

  const artists = artistName ? [{ name: artistName }] : [];

  return {
    id: readString(
      pickValue(record.mixsongid, record.album_audio_id, record.audio_id, record.sid, hash, ''),
    ),
    songId: readString(pickValue(record.songid, record.song_id, record.audio_id, '')),
    title: title || '未知歌曲',
    name: title || '未知歌曲',
    artist: normalizeText(artistName) || '未知歌手',
    artists,
    singers: artists,
    album: albumName,
    albumName,
    albumId: readString(pickValue(record.album_id, record.albumid, ''), ''),
    duration,
    coverUrl: getCoverUrl(cover, 400),
    cover,
    audioUrl: '',
    hash,
    mixSongId: parseIntSafe(
      pickValue(record.mixsongid, record.album_audio_id, record.audio_id, 0),
    ),
    fileId: parseOptionalInt(
      pickValue(record.fileid, record.file_id, record.Audioid, record.audio_id),
    ),
    privilege: parseOptionalInt(pickValue(record.privilege, undefined)),
    payType: parseOptionalInt(pickValue(record.pay_type, undefined)),
    oldCpy: parseOptionalInt(pickValue(record.old_cpy, undefined)),
  };
};
