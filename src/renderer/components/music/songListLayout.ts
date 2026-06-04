export const SONG_LIST_INDEX_COL_WIDTH = 40;
export const SONG_LIST_ALBUM_COL_WIDTH = 142;
export const SONG_LIST_LYRIC_COL_WIDTH = 260;
export const SONG_LIST_DURATION_COL_WIDTH = 68;
export const SONG_LIST_TITLE_OFFSET_WITH_COVER = 58;

export const SONG_LIST_INDEX_COL_WIDTH_COMPACT = 32;
export const SONG_LIST_ALBUM_COL_WIDTH_COMPACT = 96;
export const SONG_LIST_DURATION_COL_WIDTH_COMPACT = 52;

interface GridOptions {
  showIndex: boolean;
  showAlbum: boolean;
  showDuration: boolean;
  lyricColumn?: boolean;
  compact?: boolean;
}

export const buildSongListGridTemplate = ({
  showIndex,
  showAlbum,
  showDuration,
  lyricColumn,
  compact,
}: GridOptions): string => {
  const columns: string[] = [];

  if (showIndex) {
    columns.push(`${compact ? SONG_LIST_INDEX_COL_WIDTH_COMPACT : SONG_LIST_INDEX_COL_WIDTH}px`);
  }

  columns.push('minmax(0, 1fr)');

  if (showAlbum) {
    columns.push(
      `${lyricColumn ? SONG_LIST_LYRIC_COL_WIDTH : compact ? SONG_LIST_ALBUM_COL_WIDTH_COMPACT : SONG_LIST_ALBUM_COL_WIDTH}px`,
    );
  }

  if (showDuration) {
    columns.push(
      `${compact ? SONG_LIST_DURATION_COL_WIDTH_COMPACT : SONG_LIST_DURATION_COL_WIDTH}px`,
    );
  }

  return columns.join(' ');
};
