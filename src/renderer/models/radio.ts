/**
 * 电台元数据
 * 同时兼容 /fm/class 和 /fm/recommend 两种数据源
 */
export interface RadioMeta {
  /** 电台唯一 ID */
  fmid: number;
  /** 电台名称 */
  name: string;
  /** 电台描述 */
  description: string;
  /** 封面图 URL（已替换 {size}） */
  coverUrl: string;
  /** Banner 图 URL（已替换 {size}） */
  bannerUrl: string;
  /** 电台类型 */
  fmtype: number;
  /** 分类 ID */
  classid?: number;
  /** 分类名称 */
  classname?: string;
  /** 热度 */
  heat?: number;
  /** 排序位置 */
  position?: number;
  /** 父级 ID */
  parentId?: number;
  /** 播放类型 */
  broadcastType?: string;
}

/**
 * 电台分类
 */
export interface RadioClass {
  /** 分类 ID */
  classid: number;
  /** 分类名称（从分类下的电台 classname 推导，或用默认标签） */
  name: string;
  /** 该分类下的电台列表 */
  radios: RadioMeta[];
}
