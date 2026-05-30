import { createApp } from 'vue';
import { createPinia } from 'pinia';
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate';
import { Icon } from '@iconify/vue';
import App from './App.vue';
import router from './router';
import { logger } from '@/utils/logger';
import { schedulePreloadLyric } from './utils/preloadLyric';
import './style.css';

const app = createApp(App);
const pinia = createPinia();

// === GeckoView localStorage 不刷盘修复 ===
// 覆盖 localStorage.setItem，让每次写入都同步写入 Android SharedPreferences。
// 不依赖 __persistToNativeReady 标志，始终尝试调用原生桥；
// 如果桥未就绪 window.prompt 会返回 null，原生层 onPause 也会通过 storeCache 兜底写盘。
const _originalSetItem = localStorage.setItem.bind(localStorage);
localStorage.setItem = function geckoViewSetItem(key: string, value: string) {
  _originalSetItem(key, value);
  try {
    const result = window.prompt(
      '__native__',
      `native://persistStore?storeId=${encodeURIComponent(key)}&data=${encodeURIComponent(value)}`,
    );
    if (result) {
      try {
        const parsed = JSON.parse(result);
        if (parsed?.__nativeError) {
          logger.error('App', `persistStore failed for ${key}: ${parsed.__nativeError}`);
        }
      } catch {}
    }
  } catch {
    // 桥不可用时静默失败（原生层 onPause 会通过 storeCache 兜底写盘）
  }
};

pinia.use(piniaPluginPersistedstate);

// 只对路由加载错误跳转错误页，其他错误仅记录日志
router.onError((error) => {
  logger.error('App', 'Router error', error);
  const currentRoute = router.currentRoute.value;
  if (currentRoute.name === 'error') return;
  void router.replace({
    name: 'error',
    query: {
      message: error instanceof Error ? error.message : String(error),
      status: 'Route Error',
      from: currentRoute.fullPath,
    },
  });
});

// Vue 组件渲染错误：仅记录，不跳转（Web 模式下 API/播放错误不应导致页面崩溃）
app.config.errorHandler = (err, instance, info) => {
  logger.error('App', 'Vue error', err, { info, component: instance?.$options?.name });
};

// 窗口错误：忽略媒体元素，其余仅记录
window.addEventListener('error', (event) => {
  const target = event.target as HTMLElement | null;
  if (
    target &&
    (target.tagName === 'AUDIO' || target.tagName === 'VIDEO' || target.tagName === 'SOURCE')
  ) {
    return;
  }
  logger.error('App', 'Window error', event.error ?? event.message, {
    filename: event.filename,
    lineno: event.lineno,
    colno: event.colno,
  });
});

// 未捕获的 Promise rejection：仅记录
window.addEventListener('unhandledrejection', (event) => {
  logger.error('App', 'Unhandled rejection', event.reason);
});

app.use(pinia);
app.use(router);
app.component('Icon', Icon);
app.mount('#app');

// APP 被杀死前强制持久化所有 store 状态（pagehide 是同步事件）
// localStorage.setItem 已被覆盖，会自动同步写入 SharedPreferences
window.addEventListener('pagehide', () => {
  try {
    const piniaState = pinia.state.value;
    for (const storeId of Object.keys(piniaState)) {
      localStorage.setItem(storeId, JSON.stringify(piniaState[storeId]));
    }
  } catch {}
});

// 暴露全局持久化函数，供原生层 onPause 时通过 evalJs 调用
(window as any).__persistAllStores = () => {
  try {
    const piniaState = pinia.state.value;
    for (const storeId of Object.keys(piniaState)) {
      localStorage.setItem(storeId, JSON.stringify(piniaState[storeId]));
    }
  } catch {}
};

schedulePreloadLyric();

// 注册 Service Worker（PWA 后台播放 & 媒体按键支持）
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  });
}
