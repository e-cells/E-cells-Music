<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { iconTriangleAlert } from '@/icons';
import { useDeviceStore } from '@/stores/device';
import { usePlayerStore } from '@/stores/player';
import { usePlaylistStore } from '@/stores/playlist';
import { useSettingStore } from '@/stores/setting';
import { useToastStore } from '@/stores/toast';
import { useUserStore } from '@/stores/user';
import { ensureDevice } from '@/utils/device';
import logger from '@/utils/logger';
import Button from '@/components/ui/Button.vue';
import OverlayHeader from '@/layouts/OverlayHeader.vue';
import type { ApiServerStatus } from '@/../shared/api-server';

const router = useRouter();
const deviceStore = useDeviceStore();
const playerStore = usePlayerStore();
const playlistStore = usePlaylistStore();
const settingStore = useSettingStore();
const toastStore = useToastStore();
const userStore = useUserStore();
const statusMessage = ref('正在倾听穿林打叶声...');
const hasError = ref(false);
const isDeviceReady = ref(false);
const hasCompletedStartup = ref(false);
let isNavigating = false;

const ensureDeviceReady = async () => {
  if (deviceStore.info?.dfid || isDeviceReady.value) {
    isDeviceReady.value = true;
    return;
  }

  statusMessage.value = '正在系紧芒鞋...';

  try {
    await ensureDevice();
  } catch {
    // Android WebView 环境下网络可能不稳定，允许注册失败后继续
    logger.warn('Loading', 'Device registration failed, continuing anyway');
  }

  if (!deviceStore.info?.dfid) {
    // 非桌面环境（Android WebView）允许跳过设备注册
    if (!window.electron) {
      logger.warn('Loading', 'No dfid available, starting in limited mode');
      isDeviceReady.value = true;
      return;
    }
    throw new Error('设备注册失败');
  }

  isDeviceReady.value = true;
  logger.info('Loading', 'Device registered', deviceStore.info);
};

const navigateToHome = () => {
  if (isNavigating) return;
  isNavigating = true;
  router.push('/main/home');
};

const maybeAutoReceiveVip = async () => {
  if (!settingStore.autoReceiveVip || !userStore.isLoggedIn) return;

  try {
    await userStore.fetchUserInfoOnce();
    await userStore.autoReceiveVipIfNeeded();
  } catch (error) {
    logger.warn('Loading', 'Auto receive VIP after startup skipped:', error);
  }
};

const completeStartup = async () => {
  if (hasCompletedStartup.value) return;
  hasCompletedStartup.value = true;

  // 检查 mpv 播放引擎是否可用（在线模式下跳过）
  if (window.electron?.mpv) {
    statusMessage.value = '正在准备竹杖...';
    try {
      const mpvReady = await window.electron?.mpv?.available();
      if (!mpvReady) {
        logger.error('Loading', 'mpv player engine is not available');
        statusMessage.value = '播放引擎初始化失败';
        hasError.value = true;
        hasCompletedStartup.value = false;
        return;
      }
      logger.info('Loading', 'mpv player engine is available');
    } catch (error) {
      logger.error('Loading', 'mpv availability check failed:', error);
      statusMessage.value = '播放引擎检查失败';
      hasError.value = true;
      hasCompletedStartup.value = false;
      return;
    }
  } else {
    logger.info('Loading', 'Online mode - skipping MPV check (browser audio)');
  }

  await maybeAutoReceiveVip();

  // 成功后的最终提示，呼应诗句
  statusMessage.value = '一蓑烟雨任平生...';
  window.setTimeout(() => {
    navigateToHome();
  }, 1200); // 稍微延长一点时间，让用户品味一下意境
};

const applyStatus = async (status: ApiServerStatus) => {
  logger.info('Loading', 'API status', status);

  if (status.state === 'ready') {
    hasError.value = false;
    try {
      await ensureDeviceReady();
      await completeStartup();
    } catch (error) {
      logger.error('Loading', 'Device init failed:', error);
      statusMessage.value = error instanceof Error ? error.message : String(error);
      hasError.value = true;
    }
    return;
  }

  // idle 或 failed 都视为需要启动
  statusMessage.value = status.error || '服务未就绪';
  hasError.value = true;
};

const initStatus = async () => {
  try {
    // 如果 API 地址未配置，跳转到初始化页面
    if (!settingStore.apiBaseUrl?.trim()) {
      router.replace('/setup');
      return;
    }

    // 在线后端模式：跳过本地 API server 初始化，直接进入设备注册和播放引擎检查
    if (!window.electron?.apiServer) {
      logger.info('Loading', 'Online backend mode - skipping local API server init');
      try {
        await ensureDeviceReady();
        await completeStartup();
      } catch (error) {
        logger.error('Loading', 'Online mode init failed:', error);
        statusMessage.value = error instanceof Error ? error.message : String(error);
        hasError.value = true;
      }
      return;
    }

    let status = await window.electron.apiServer.status();

    // 如果还没就绪，主动触发初始化
    if (status.state !== 'ready') {
      statusMessage.value = '正在唤醒音乐世界...';
      const result = await window.electron.apiServer.start();
      if (!result?.success) {
        statusMessage.value = result?.error || '服务启动失败';
        hasError.value = true;
        return;
      }
      status = await window.electron.apiServer.status();
    }

    await applyStatus(status);
  } catch (error) {
    logger.error('Loading', 'Status init failed:', error);
    statusMessage.value = '读取启动状态失败';
    hasError.value = true;
  }
};

const retryStart = async () => {
  hasCompletedStartup.value = false;
  hasError.value = false;
  statusMessage.value = '重新披上蓑衣...';

  // 尝试重启 mpv 播放引擎
  try {
    await window.electron?.mpv?.restart();
  } catch (error) {
    logger.warn('Loading', 'mpv restart attempt failed:', error);
  }

  try {
    if (!window.electron?.apiServer) {
      try {
        await ensureDeviceReady();
      } catch {
        if (!window.electron) {
          isDeviceReady.value = true;
        } else {
          throw new Error('设备注册失败');
        }
      }
      await completeStartup();
      return;
    }
    const result = await window.electron.apiServer.start();
    if (!result?.success) {
      statusMessage.value = result?.error || '服务启动失败';
      hasError.value = true;
      return;
    }
    const status = await window.electron.apiServer.status();
    await applyStatus(status);
  } catch (error) {
    logger.error('Loading', 'Retry failed:', error);
    statusMessage.value = error instanceof Error ? error.message : String(error);
    hasError.value = true;
  }
};

const closeWindow = () => {
  window.close();
};

onMounted(async () => {
  await initStatus();
});

onUnmounted(() => {
  // 清理
});
</script>

<template>
  <div
    class="loading-view h-full w-full relative overflow-hidden bg-[#eef2f7] dark:bg-[#030406] text-black dark:text-white select-none transition-colors duration-500"
  >
    <OverlayHeader />

    <div class="absolute inset-0 bg-gradient-to-b from-transparent to-black/5 dark:to-white/5 pointer-events-none"></div>
    <div
      class="absolute -top-[100px] -right-[100px] w-[400px] h-[400px] rounded-full bg-primary/5 dark:bg-primary/10 blur-[80px] pointer-events-none"
    ></div>

    <main class="relative h-full flex flex-col items-center justify-center px-6">
      <div v-if="!hasError" class="flex flex-col items-center w-full max-w-2xl">
        
        <div class="poetic-window mb-10 shadow-xl dark:shadow-2xl">
          <div class="rain-layer"></div>
          <div class="bamboo b-1"></div>
          <div class="bamboo b-2"></div>
          <div class="bamboo b-3"></div>
          <div class="bamboo b-4"></div>
          <div class="ground-fog"></div>
          <div class="wanderer">
            <div class="hat"></div>
            <div class="cape"></div>
            <div class="leg left-leg"></div>
            <div class="leg right-leg"></div>
            <div class="staff"></div>
          </div>
        </div>

        <div class="flex flex-col items-center space-y-4 mb-10 text-center">
          <p class="poem-text">
            莫听穿林打叶声，何妨吟啸且徐行。
          </p>
          <p class="poem-text">
            竹杖芒鞋轻胜马，谁怕？一蓑烟雨任平生。
          </p>
        </div>

        <div class="flex flex-col items-center space-y-3 opacity-60 dark:opacity-50">
          <div class="flex items-center gap-1.5">
            <div class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce [animation-delay:-0.3s]"></div>
            <div class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce [animation-delay:-0.15s]"></div>
            <div class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce"></div>
          </div>
          <p class="text-[12px] font-medium tracking-[0.1em]">
            {{ statusMessage }}
          </p>
        </div>
      </div>

      <div v-else class="flex flex-col items-center space-y-6 px-10">
        <div class="w-16 h-16 rounded-full bg-red-500/10 flex items-center justify-center mb-2">
          <Icon class="text-red-500" :icon="iconTriangleAlert" width="32" height="32" />
        </div>
        <div class="text-center space-y-2">
          <h2 class="text-lg font-bold text-red-500/90">风雨骤歇，行路受阻</h2>
          <p class="text-sm text-black/60 dark:text-white/60 max-w-xs">{{ statusMessage }}</p>
        </div>
        <div class="flex gap-4 pt-6 no-drag">
          <Button variant="primary" size="sm" @click="retryStart"> 再次启程 </Button>
          <Button variant="secondary" size="sm" @click="closeWindow"> 退出 </Button>
        </div>
      </div>
    </main>

    <footer class="absolute bottom-6 left-0 right-0 text-center pointer-events-none">
      <span
        class="text-[11px] font-bold text-black/20 dark:text-white/20 uppercase tracking-[2px]"
        >易格音乐(E-cells-Music)</span
      >
    </footer>
  </div>
</template>

<style scoped>
.loading-view {
  animation: fade-in 0.8s ease-out;
}

@keyframes fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/* ── 诗句文字排版 ── */
.poem-text {
  font-family: "ZCOOL KuaiLe", "Kaiti SC", "STKaiti", "KaiTi", sans-serif; /* 尝试使用更圆润的字体 */
  font-size: clamp(16px, 4vw, 20px);
  letter-spacing: 0.1em;
  font-weight: 700;
  color: #4a5d53; /* 清新的松石绿 */
  text-shadow: 0 2px 8px rgba(74, 93, 83, 0.1);
}
.dark .poem-text {
  color: #e0ece6;
  text-shadow: 0 2px 10px rgba(0, 0, 0, 0.3);
}

/* ── Q版微缩景观容器 (明亮的新中式视窗) ── */
.poetic-window {
  position: relative;
  width: clamp(180px, 40vw, 240px);
  aspect-ratio: 1 / 1;
  border-radius: 50%;
  /* 清新的天空蓝渐变，像春日里的雨景 */
  background: linear-gradient(135deg, #e0f2fe 0%, #bae6fd 100%);
  overflow: hidden;
  border: 6px solid #ffffff;
  box-shadow: 
    0 10px 30px rgba(56, 189, 248, 0.2), 
    inset 0 0 20px rgba(255,255,255,0.8);
}
.dark .poetic-window {
  background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
  border-color: #334155;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
}

/* ── Q版透亮雨滴 ── */
.rain-layer {
  position: absolute;
  top: -50%; left: -50%;
  width: 200%; height: 200%;
  /* 雨滴变粗，颜色带一点明媚的白和暖色 */
  background-image: 
    linear-gradient(110deg, transparent 48%, rgba(255,255,255,0.6) 48%, rgba(255,255,255,0.6) 52%, transparent 52%),
    linear-gradient(110deg, transparent 68%, rgba(255,255,255,0.4) 68%, rgba(255,255,255,0.4) 72%, transparent 72%);
  background-size: 40px 60px, 80px 100px;
  animation: raining-q 0.6s linear infinite;
  z-index: 1;
  pointer-events: none;
}
@keyframes raining-q {
  0% { background-position: 0 0, 0 0; }
  100% { background-position: -20px 60px, -30px 100px; }
}

/* ── Q版圆润竹子 ── */
.bamboo {
  position: absolute;
  bottom: -5%;
  /* 明亮的薄荷绿/翠绿，带有高光 */
  background: linear-gradient(to right, #4ade80 0%, #22c55e 70%, #16a34a 100%);
  border-radius: 10px 10px 0 0; /* 竹子顶部变圆 */
  transform-origin: bottom center;
  animation: sway-q 3s ease-in-out infinite alternate;
  z-index: 2;
  box-shadow: inset -2px 0 5px rgba(0,0,0,0.1);
}
/* 竹节特效 (利用伪元素画白线模拟) */
.bamboo::after {
  content: '';
  position: absolute;
  top: 0; left: 0; right: 0; bottom: 0;
  background: repeating-linear-gradient(to bottom, transparent 0%, transparent 18%, rgba(255,255,255,0.3) 19%, rgba(0,0,0,0.1) 20%);
}
.dark .bamboo {
  background: linear-gradient(to right, #166534 0%, #14532d 100%);
}
/* 调整粗细，显得更可爱 */
.b-1 { left: 12%; width: 18px; height: 110%; animation-delay: 0s;}
.b-2 { left: 32%; width: 14px; height: 120%; animation-delay: -0.8s; opacity: 0.8; filter: blur(2px); z-index: 0;}
.b-3 { left: 75%; width: 22px; height: 105%; animation-delay: -1.5s;}
.b-4 { left: 88%; width: 12px; height: 115%; animation-delay: -2s; opacity: 0.9;}

@keyframes sway-q {
  0% { transform: rotate(-6deg); }
  100% { transform: rotate(4deg); }
}

/* ── 萌系草地/土坡 (替代原来的黑雾) ── */
.ground-fog {
  position: absolute;
  bottom: -10%; left: -10%; right: -10%;
  height: 35%;
  background: #86efac; /* 浅绿草地 */
  border-radius: 50% 50% 0 0; /* 变成一个圆弧形的小土坡 */
  z-index: 3;
  box-shadow: inset 0 10px 20px rgba(34, 197, 94, 0.3);
}
.dark .ground-fog { background: #064e3b; box-shadow: inset 0 10px 20px rgba(0, 0, 0, 0.5); }

/* ── Q版蓑衣行者 (可爱的包子人) ── */
.wanderer {
  position: absolute;
  bottom: 16%; /* 站在草坡上 */
  left: 50%;
  transform: translateX(-50%);
  width: 50px;
  height: 60px;
  z-index: 4;
  animation: walk-bounce 0.6s cubic-bezier(0.3, 2, 0.6, 0.8) infinite alternate; /* Q弹跳跃感 */
}

/* 胖胖的斗笠 */
.hat {
  position: absolute;
  top: 0; left: -5px;
  width: 60px; height: 20px;
  background: #fcd34d; /* 明亮的草帽黄 */
  border-radius: 50% 50% 10% 10%;
  transform: rotate(-10deg);
  z-index: 3;
  border: 2px solid #d97706; /* 描边增加卡通感 */
}
.dark .hat { background: #b45309; border-color: #78350f;}

/* 短款小披风 (蓑衣) */
.cape {
  position: absolute;
  top: 14px; left: 5px;
  width: 40px; height: 35px;
  background: #fbbf24;
  border-radius: 20px 20px 8px 8px; /* 圆滚滚的身体 */
  z-index: 2;
  border: 2px solid #d97706;
}
.dark .cape { background: #92400e; border-color: #78350f;}

/* 可爱的短竹杖 */
.staff {
  position: absolute;
  top: 20px; left: 42px;
  width: 6px; height: 45px;
  background: #78350f;
  border-radius: 3px;
  transform: rotate(15deg);
  transform-origin: 50% 20%;
  z-index: 1;
  animation: staff-tap 0.6s ease-in-out infinite alternate;
}
.dark .staff { background: #451a03; }

/* 小短腿 */
.leg {
  position: absolute;
  bottom: -6px;
  width: 8px; height: 12px;
  background: #475569;
  border-radius: 4px;
  z-index: 1;
}
.dark .leg { background: #1e293b; }
.left-leg {
  left: 15px;
  transform-origin: top center;
  animation: leg-run 0.6s ease-in-out infinite alternate;
}
.right-leg {
  left: 27px;
  transform-origin: top center;
  animation: leg-run 0.6s ease-in-out infinite alternate-reverse;
}

/* Q弹走路动画 */
@keyframes walk-bounce {
  0% { transform: translateX(-50%) translateY(0) scaleY(0.95); }
  100% { transform: translateX(-50%) translateY(-6px) scaleY(1.05); } /* 向上跳动并拉伸 */
}
@keyframes leg-run {
  0% { transform: rotate(-30deg) translateY(-2px); }
  100% { transform: rotate(20deg) translateY(0); }
}
@keyframes staff-tap {
  0% { transform: rotate(15deg) translateY(0); }
  100% { transform: rotate(25deg) translateY(-4px); }
}

/* ── 加载小圆点动画 ── */
.animate-bounce {
  animation: bounce 0.6s infinite cubic-bezier(0.45, 0.05, 0.55, 0.95);
  background-color: #10b981; /* 统一为年轻的绿 */
}

@keyframes bounce {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-8px); }
}
</style>