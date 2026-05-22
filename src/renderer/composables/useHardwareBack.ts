import { onUnmounted, watch, type Ref } from 'vue';

// 全局返回键回调栈 (后进先出)
const backHandlers: Array<() => boolean | void> = [];

if (typeof window !== 'undefined') {
  // 挂载到全局，对接 MainActivity.java 中的返回键拦截
  (window as any).NativeBridge = (window as any).NativeBridge || {};
  (window as any).NativeBridge.onBackPressed = () => {
    // 从栈顶（最后打开的组件）向下遍历
    for (let i = backHandlers.length - 1; i >= 0; i--) {
      const handler = backHandlers[i];
      const isIntercepted = handler();
      if (isIntercepted !== false) {
        return; // 成功拦截，终止后续动作
      }
    }
    // 如果没有任何弹窗/抽屉需要拦截，执行原生的路由退回
    window.history.back();
  };
}

/**
 * 注册硬件返回键拦截
 * @param isActive 控制是否激活拦截的响应式变量（比如弹窗的 open 状态）
 * @param onBack 触发返回键时的回调，返回 true 表示拦截成功，false 放行
 */
export function useHardwareBack(isActive: Ref<boolean> | (() => boolean), onBack: () => boolean | void) {
  const register = () => {
    if (!backHandlers.includes(onBack)) backHandlers.push(onBack);
  };

  const unregister = () => {
    const idx = backHandlers.indexOf(onBack);
    if (idx > -1) backHandlers.splice(idx, 1);
  };

  watch(isActive, (val) => {
    if (val) register();
    else unregister();
  }, { immediate: true });

  onUnmounted(() => {
    unregister();
  });
}