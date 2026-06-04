<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useSettingStore } from '@/stores/setting';
import { useToastStore } from '@/stores/toast';
import { isGeckoView } from '@/utils/nativeBridge';
import Button from '@/components/ui/Button.vue';
import Input from '@/components/ui/Input.vue';
import OverlayHeader from '@/layouts/OverlayHeader.vue';

const router = useRouter();
const settingStore = useSettingStore();
const toastStore = useToastStore();

const apiUrl = ref('');
const isTesting = ref(false);
const isConfirming = ref(false);
const testResult = ref<{ success: boolean; message: string } | null>(null);

const canConfirm = computed(() => apiUrl.value.trim().length > 0);

const testConnection = async () => {
  let base = apiUrl.value.trim().replace(/\/+$/, '');
  if (!base) {
    toastStore.warning('请先填写 API 地址');
    return;
  }
  
  // 自动补全 http:// 前缀
  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = `http://${base}`;
    apiUrl.value = base;
  }

  isTesting.value = true;
  testResult.value = null;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000); 
  try {
    // 核心改动：直接请求实际业务接口，避开根目录反向代理坑
    const response = await fetch(`${base}/search/default`, { 
      method: 'GET', 
      signal: controller.signal 
    });
    clearTimeout(timeout);
    
    if (response.ok) {
      // 强行解析 JSON，如果是网页 HTML 必然在这里崩掉直接跳到 catch
      const resData = await response.json();
      
      // 只要是合法的 JSON 对象，说明服务绝对真实有效
      if (resData && typeof resData === 'object') {
        testResult.value = { success: true, message: '连接成功，服务有效！' };
      } else {
        testResult.value = { success: false, message: '验证失败：接口返回数据格式不正确' };
      }
    } else {
      testResult.value = { success: false, message: `连接失败：服务器异常 (${response.status})` };
    }
  } catch (error: any) {
    clearTimeout(timeout);
    if (error.name === 'AbortError') {
      testResult.value = { success: false, message: '连接超时，请检查网络或端口' };
    } else if (error instanceof SyntaxError || error.name === 'SyntaxError') {
      // 成功抓获：把 HTML 当成 JSON 解析了，说明是假地址或劫持网页
      testResult.value = { success: false, message: '验证失败：该地址不是有效的音乐 API 服务' };
    } else {
      testResult.value = { success: false, message: '连接失败，请检查地址是否正确' };
    }
  } finally {
    isTesting.value = false;
  }
};

const confirm = async () => {
  let base = apiUrl.value.trim().replace(/\/+$/, '');
  if (!base) return;

  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = `http://${base}`;
    apiUrl.value = base;
  }

  isConfirming.value = true;
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const controller = new AbortController();
    timeout = setTimeout(() => controller.abort(), 5000);

    const response = await fetch(`${base}/search/default`, {
      method: 'GET',
      signal: controller.signal
    });
    clearTimeout(timeout);
    
    if (response.ok) {
      const resData = await response.json();
      if (resData && typeof resData === 'object') {
        settingStore.apiBaseUrl = base;
        router.replace('/');
      } else {
        toastStore.warning('验证失败：接口返回数据格式不正确');
      }
    } else {
      toastStore.warning(`服务验证失败：服务器返回异常 (${response.status})`);
    }
  } catch (error: any) {
    clearTimeout(timeout);
    if (error.name === 'AbortError') {
      toastStore.warning('连接超时，请检查服务是否开启');
    } else if (error instanceof SyntaxError || error.name === 'SyntaxError') {
      toastStore.warning('验证失败：该地址未返回有效的音乐接口数据');
    } else {
      toastStore.warning('连接失败，请检查地址是否正确');
    }
  } finally {
    isConfirming.value = false;
  }
};

onMounted(() => {
  apiUrl.value = settingStore.apiBaseUrl || '';
});
</script>

<template>
  <div
    class="setup-view h-full w-full relative overflow-hidden bg-bg-main text-text-main select-none transition-colors duration-500"
  >
    <OverlayHeader />

    <div class="absolute inset-0 bg-gradient-to-b from-bg-sidebar to-bg-main opacity-50"></div>

    <div
      class="absolute -top-[100px] -right-[100px] w-[300px] h-[300px] rounded-full bg-primary/5 dark:bg-primary/10 blur-3xl"
    ></div>

    <main class="relative h-full flex flex-col items-center justify-center">
      
      <div class="poetic-window mb-[30px] shadow-xl dark:shadow-2xl">
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

      <h1 class="text-[22px] font-black tracking-tight mb-2">初始化配置</h1>
      <p class="text-[13px] text-text-main/60 font-bold mb-8">请输入远端 API 服务地址</p>

      <div class="w-full max-w-[420px] px-10 space-y-4">
        <div class="flex gap-3">
          <Input
            v-model="apiUrl"
            placeholder="https://your-api-server.com"
            class="flex-1"
            :show-clear="true"
          />
          <Button
            variant="outline"
            size="md"
            :disabled="!apiUrl.trim() || isTesting"
            :loading="isTesting"
            @click="testConnection"
          >
            测试
          </Button>
        </div>

        <div
          v-if="testResult"
          class="text-[12px] font-bold px-2"
          :class="testResult.success ? 'text-green-500' : 'text-red-500'"
        >
          {{ testResult.message }}
        </div>

        <Button
          variant="primary"
          size="lg"
          class="w-full"
          :disabled="!canConfirm || isConfirming"
          :loading="isConfirming"
          @click="confirm"
        >
          确认并继续
        </Button>

        <p class="text-[12px] text-amber-500/90 font-bold text-center px-2 mt-4 leading-relaxed">
          注意！本软件完全免费，如您是从其它地方购买而来，请直接给卖家差评！
        </p>
      </div>
    </main>

    <footer class="absolute bottom-10 left-0 right-0 text-center pointer-events-none">
      <span
        class="text-[12px] font-bold text-text-main/40 tracking-[1.5px]"
        >竹杖芒鞋轻胜马，谁怕？一蓑烟雨任平生。</span
      >
    </footer>
  </div>
</template>

<style scoped>
.setup-view {
  animation: fade-in 0.6s ease-out;
}

@keyframes fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/* ── Q版微缩景观容器 (适配 Setup 页面尺寸) ── */
.poetic-window {
  position: relative;
  width: 180px;  
  height: 180px;
  border-radius: 50%;
  background: linear-gradient(135deg, #e0f2fe 0%, #bae6fd 100%);
  overflow: hidden;
  border: 5px solid #ffffff;
  box-shadow: 
    0 10px 25px rgba(56, 189, 248, 0.15), 
    inset 0 0 15px rgba(255,255,255,0.8);
}
.dark .poetic-window {
  background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
  border-color: #334155;
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.4);
}

/* ── Q版透亮雨滴 ── */
.rain-layer {
  position: absolute;
  top: -50%; left: -50%;
  width: 200%; height: 200%;
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
  background: linear-gradient(to right, #4ade80 0%, #22c55e 70%, #16a34a 100%);
  border-radius: 10px 10px 0 0;
  transform-origin: bottom center;
  animation: sway-q 3s ease-in-out infinite alternate;
  z-index: 2;
  box-shadow: inset -2px 0 5px rgba(0,0,0,0.1);
}
.bamboo::after {
  content: '';
  position: absolute;
  top: 0; left: 0; right: 0; bottom: 0;
  background: repeating-linear-gradient(to bottom, transparent 0%, transparent 18%, rgba(255,255,255,0.3) 19%, rgba(0,0,0,0.1) 20%);
}
.dark .bamboo {
  background: linear-gradient(to right, #166534 0%, #14532d 100%);
}
.b-1 { left: 12%; width: 16px; height: 110%; animation-delay: 0s;}
.b-2 { left: 32%; width: 12px; height: 120%; animation-delay: -0.8s; opacity: 0.8; filter: blur(2px); z-index: 0;}
.b-3 { left: 75%; width: 20px; height: 105%; animation-delay: -1.5s;}
.b-4 { left: 88%; width: 10px; height: 115%; animation-delay: -2s; opacity: 0.9;}

@keyframes sway-q {
  0% { transform: rotate(-6deg); }
  100% { transform: rotate(4deg); }
}

/* ── 萌系草地/土坡 ── */
.ground-fog {
  position: absolute;
  bottom: -10%; left: -10%; right: -10%;
  height: 35%;
  background: #86efac;
  border-radius: 50% 50% 0 0;
  z-index: 3;
  box-shadow: inset 0 10px 20px rgba(34, 197, 94, 0.3);
}
.dark .ground-fog { background: #064e3b; box-shadow: inset 0 10px 20px rgba(0, 0, 0, 0.5); }

/* ── Q版蓑衣行者 ── */
.wanderer {
  position: absolute;
  bottom: 12%; 
  left: 50%;
  transform: translateX(-50%);
  width: 50px;
  height: 60px;
  z-index: 4;
  animation: walk-bounce 0.6s cubic-bezier(0.3, 2, 0.6, 0.8) infinite alternate;
}

/* 胖胖的斗笠 */
.hat {
  position: absolute;
  top: 0; left: -5px;
  width: 60px; height: 20px;
  background: #fcd34d;
  border-radius: 50% 50% 10% 10%;
  transform: rotate(-10deg);
  z-index: 3;
  border: 2px solid #d97706;
}
.dark .hat { background: #b45309; border-color: #78350f;}

/* 短款小披风 (蓑衣) */
.cape {
  position: absolute;
  top: 14px; left: 5px;
  width: 40px; height: 35px;
  background: #fbbf24;
  border-radius: 20px 20px 8px 8px;
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
  100% { transform: translateX(-50%) translateY(-6px) scaleY(1.05); }
}
@keyframes leg-run {
  0% { transform: rotate(-30deg) translateY(-2px); }
  100% { transform: rotate(20deg) translateY(0); }
}
@keyframes staff-tap {
  0% { transform: rotate(15deg) translateY(0); }
  100% { transform: rotate(25deg) translateY(-4px); }
}
</style>