/**
 * 设备性能等级检测
 *
 * 参考 nativeBridge.ts 中 isGeckoView 的模式，提供轻量级的性能分级。
 * 结果在首次调用后缓存，后续调用直接返回。
 */

export type PerformanceTier = 'high' | 'medium' | 'low';

let cachedTier: PerformanceTier | null = null;

/**
 * 检测当前设备性能等级
 *
 * 分级依据：
 * - navigator.deviceMemory（GB）— Chrome / GeckoView 支持
 * - navigator.hardwareConcurrency — CPU 核心数
 * - 简单的主线程响应时间测试
 */
export function getPerformanceTier(): PerformanceTier {
  if (cachedTier) return cachedTier;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const nav = navigator as any;
  const isGeckoView = typeof window !== 'undefined' && !!(window as any).__GECKOVIEW__;

  const deviceMemory: number | undefined = nav.deviceMemory; // 单位 GB
  const cores: number = navigator.hardwareConcurrency || 2;

  // 简单主线程响应测试：强制一次同步布局并测量耗时
  const start = performance.now();
  const el = document.createElement('div');
  el.style.cssText = 'position:fixed;left:-9999px;width:100px;height:100px;';
  document.body.appendChild(el);
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  el.offsetWidth; // 强制同步布局
  document.body.removeChild(el);
  const layoutTime = performance.now() - start;

  let tier: PerformanceTier;

  if (isGeckoView) {
    // GeckoView 本身开销大，移动端 8G RAM 以下均视为低端
    if (deviceMemory !== undefined && deviceMemory <= 8) {
      tier = 'low';
    } else if (cores <= 8 && layoutTime > 2) {
      tier = 'low';
    } else if (cores <= 8 && layoutTime > 1) {
      tier = 'medium';
    } else {
      tier = 'medium'; // GeckoView 默认 medium
    }
  } else {
    // 桌面 Electron
    if (cores >= 8 && (deviceMemory === undefined || deviceMemory >= 8)) {
      tier = 'high';
    } else if (cores >= 4) {
      tier = 'medium';
    } else {
      tier = 'low';
    }
  }

  cachedTier = tier;
  return tier;
}

/** 当前设备是否为低性能（GeckoView 8G RAM 以下 / 少核心 / 响应慢） */
export function isLowPerformance(): boolean {
  return getPerformanceTier() === 'low';
}
