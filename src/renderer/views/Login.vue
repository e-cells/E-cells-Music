<script setup lang="ts">
import { ref, onMounted, onUnmounted, reactive, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useUserStore } from '@/stores/user';
import { useSettingStore } from '@/stores/setting';
import {
  getLoginQrKey,
  createLoginQr,
  checkLoginQr,
  sendSmsCode,
  loginBySms,
  createWxLogin,
  checkWxLogin,
  loginByOpenPlat,
} from '@/api/user';
import logger from '@/utils/logger';
import { closeTransientView } from '@/utils/navigation';

// 引入封装后的 UI 组件
import Tabs from '@/components/ui/Tabs.vue';
import TabsList from '@/components/ui/TabsList.vue';
import TabsTrigger from '@/components/ui/TabsTrigger.vue';
import TabsContent from '@/components/ui/TabsContent.vue';
import Input from '@/components/ui/Input.vue';
import Button from '@/components/ui/Button.vue';

import OverlayHeader from '@/layouts/OverlayHeader.vue';
import Image from '@/components/ui/Image.vue';
import {
  iconBotMessageSquare,
  iconCheck,
  iconChevronLeft,
  iconInfo,
  iconQrCode,
  iconRefreshCw,
  iconSmartphone,
  iconSparkles,
} from '@/icons';

const router = useRouter();
const userStore = useUserStore();
const settingStore = useSettingStore();

const triggerAutoReceiveVipAfterLogin = () => {
  if (!settingStore.autoReceiveVip) return;

  void userStore
    .fetchUserInfoOnce()
    .then(() => userStore.autoReceiveVipIfNeeded())
    .catch((e) => {
      console.warn('triggerAutoReceiveVipAfterLogin failed:', e);
    });
};

// 当前选中的 Tab (0: 扫码, 1: 验证码, 2: 微信)
const activeTab = ref('0');

const closeLoginPage = async () => {
  await closeTransientView(router, { query: router.currentRoute.value.query });
};

// --- 酷狗扫码逻辑 ---
const qrKey = ref<string | undefined>(undefined);
const qrUrl = ref<string | undefined>(undefined);
const qrStatus = ref(1);
const isLoadingQr = ref(false);
const qrError = ref('');
let isPollingQr = false;
let isLoginDone = false;

const loadQrCode = async () => {
  if (activeTab.value !== '0' || isLoginDone) return;
  isLoadingQr.value = true;
  qrUrl.value = undefined;
  qrError.value = '';
  isPollingQr = false;
  try {
    const keyRes: any = await getLoginQrKey();
    const currentKey = keyRes?.data?.qrcode || keyRes?.data?.key;
    if (keyRes?.status === 1 && currentKey) {
      qrKey.value = currentKey;
      qrStatus.value = 1;
      if (keyRes.data.qrcode_img) {
        qrUrl.value = keyRes.data.qrcode_img;
        startCheckStatus();
      } else {
        const createRes: any = await createLoginQr(qrKey.value!);
        if (createRes?.status === 1 && createRes?.data?.qrcode_img) {
          qrUrl.value = createRes.data.qrcode_img;
          startCheckStatus();
        }
      }
    }
  } catch (e) {
    logger.error('Login', 'Load QR Error:', e);
    qrError.value = '二维码加载失败，请稍后重试';
    qrStatus.value = 0;
  } finally {
    isLoadingQr.value = false;
  }
};

const startCheckStatus = async () => {
  if (isPollingQr || isLoginDone || activeTab.value !== '0') return;
  isPollingQr = true;
  logger.info('Login', 'Starting Kugou QR polling...');

  let consecutiveErrors = 0;
  const MAX_ERRORS = 3;

  while (isPollingQr && qrKey.value && activeTab.value === '0') {
    try {
      const res: any = await checkLoginQr(qrKey.value);
      if (!isPollingQr || activeTab.value !== '0') break;

      consecutiveErrors = 0;

      if (res) {
        const status = res.data?.status ?? res.status;
        qrStatus.value = status;
        if (status === 4 && res.data) {
          isPollingQr = false;
          isLoginDone = true;
          userStore.handleLoginSuccess(res.data);
          triggerAutoReceiveVipAfterLogin();
          await closeLoginPage();
          break;
        } else if (status === 0) {
          isPollingQr = false;
          break;
        }
      }
    } catch (e) {
      consecutiveErrors++;
      logger.error('Login', `Check QR Status Error (${consecutiveErrors}/${MAX_ERRORS}):`, e);
      if (consecutiveErrors >= MAX_ERRORS) {
        qrError.value = '扫码状态检查失败，请稍后重试';
        qrStatus.value = 0;
        break;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  isPollingQr = false;
  logger.info('Login', 'Kugou QR polling stopped.');
};

// --- 验证码登录逻辑 ---
const smsData = reactive({
  mobile: '',
  code: '',
  isSending: false,
  countdown: 0,
  error: '',
});
let smsTimer: any = null;

const startCountdown = () => {
  smsData.countdown = 60;
  smsTimer = setInterval(() => {
    smsData.countdown--;
    if (smsData.countdown <= 0) clearInterval(smsTimer);
  }, 1000);
};

const handleSendCode = async () => {
  const mobile = smsData.mobile ? smsData.mobile.toString().trim() : '';
  logger.info('Login', 'Attempting to send code to:', `"${mobile}"`, 'Length:', mobile.length);
  if (!/^1\d{10}$/.test(mobile)) {
    logger.warn('Login', 'Mobile validation failed for:', `"${mobile}"`);
    smsData.error = '请输入正确的手机号';
    return;
  }
  smsData.isSending = true;
  smsData.error = '';
  try {
    const res: any = await sendSmsCode(mobile);
    if (res.status === 1) {
      startCountdown();
    } else {
      smsData.error = res.error || '发送验证码失败，请稍后重试';
    }
  } catch {
    smsData.error = '发送验证码失败，请稍后重试';
  } finally {
    smsData.isSending = false;
  }
};

const handleSmsLogin = async () => {
  const mobile = smsData.mobile.trim();
  if (!mobile || !smsData.code) return;
  smsData.isSending = true;
  try {
    const res: any = await loginBySms(mobile, smsData.code);
    if (res.status === 1 && res.data) {
      isLoginDone = true;
      userStore.handleLoginSuccess(res.data);
      triggerAutoReceiveVipAfterLogin();
      await closeLoginPage();
    } else {
      smsData.error = res.error || '登录失败，请稍后重试';
    }
  } catch {
    smsData.error = '登录失败，请稍后重试';
  } finally {
    smsData.isSending = false;
  }
};

// --- 微信扫码逻辑 ---
const wxQr = reactive({
  url: '',
  uuid: '',
  status: 0, // 0: 等待, 1: 扫描, 2: 确认, 3: 过期
  isLoading: false,
  error: '',
});
let isPollingWx = false;

const loadWxQr = async () => {
  if (activeTab.value !== '2' || isLoginDone) return;
  wxQr.isLoading = true;
  wxQr.url = '';
  wxQr.status = 0;
  wxQr.error = '';
  isPollingWx = false;
  try {
    const res: any = await createWxLogin();
    if (res?.uuid) {
      wxQr.uuid = res.uuid;
      const base64 = res.qrcode?.qrcodebase64;
      if (base64) {
        wxQr.url = base64.startsWith('data:') ? base64 : `data:image/jpeg;base64,${base64}`;
      } else {
        wxQr.url = res.qrcode?.qrcodeurl || '';
      }
      startCheckWxStatus();
    }
  } catch (e) {
    logger.error('Login', 'Load Wx QR Error:', e);
    wxQr.error = '微信二维码加载失败，请稍后重试';
    wxQr.status = 3;
  } finally {
    wxQr.isLoading = false;
  }
};

const startCheckWxStatus = async () => {
  if (isPollingWx || isLoginDone || activeTab.value !== '2') return;
  isPollingWx = true;
  logger.info('Login', 'Starting WeChat polling...');

  while (isPollingWx && wxQr.uuid && activeTab.value === '2') {
    try {
      const res: any = await checkWxLogin(wxQr.uuid, Date.now());
      if (!isPollingWx || activeTab.value !== '2') break;
      if (res) {
        const code = res.wx_errcode || res.status;
        if (code === 405) {
          isPollingWx = false;
          const wxCode = res.wx_code;
          if (wxCode) {
            const loginRes: any = await loginByOpenPlat(wxCode);
            if (loginRes?.status === 1 || loginRes?.code === 200) {
              isLoginDone = true;
              userStore.handleLoginSuccess(loginRes.data || loginRes.body?.data || loginRes);
              triggerAutoReceiveVipAfterLogin();
              await closeLoginPage();
            }
          }
          break;
        } else if (code === 404) {
          wxQr.status = 1;
        } else if (code === 403 || code === 402) {
          wxQr.status = 3;
          isPollingWx = false;
          break;
        } else if (code === 408) {
          wxQr.status = 0;
        }
      }
    } catch (e) {
      logger.error('Login', 'Check Wx Status Error:', e);
      wxQr.error = '微信登录状态检查失败，请稍后重试';
      wxQr.status = 3;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  isPollingWx = false;
  logger.info('Login', 'WeChat polling stopped.');
};

const stopCheckStatus = () => {
  isPollingQr = false;
  isPollingWx = false;
};

// 监听 Tab 切换，触发对应逻辑
watch(activeTab, (newTab) => {
  if (isLoginDone) return;
  logger.info('Login', 'Tab changed to:', newTab);
  stopCheckStatus();
  if (newTab === '0') loadQrCode();
  else if (newTab === '2') loadWxQr();
});

onMounted(() => loadQrCode());
onUnmounted(() => {
  stopCheckStatus();
  if (smsTimer) clearInterval(smsTimer);
});
</script>

<template>
  <div
    class="login-page fixed inset-0 overflow-y-auto overflow-x-hidden bg-bg-main text-text-main transition-colors duration-500 select-none flex flex-col items-center pt-safe pb-6"
  >
    <div class="absolute inset-0 bg-gradient-to-br from-bg-sidebar via-bg-main to-bg-sidebar opacity-70 z-0"></div>
    <div class="absolute top-1/4 left-1/4 w-[500px] h-[500px] rounded-full bg-primary/[0.04] blur-[100px] pointer-events-none z-0"></div>
    <div class="absolute bottom-1/4 right-1/4 w-[500px] h-[500px] rounded-full bg-secondary/[0.03] blur-[100px] pointer-events-none z-0"></div>

    <OverlayHeader />

    <div class="w-full max-w-[400px] md:max-w-[800px] px-5 pt-3 z-50 flex items-center">
      <Button
        @click="closeLoginPage"
        variant="unstyled"
        size="none"
        class="h-10 w-10 min-w-0 rounded-full flex items-center justify-center text-text-main bg-black/[0.04] dark:bg-white/[0.08] hover:bg-black/[0.08] dark:hover:bg-white/[0.15] active:scale-90 transition-transform"
      >
        <Icon :icon="iconChevronLeft" width="22" height="22" />
      </Button>
    </div>

    <div class="flex-1 relative flex flex-col items-center justify-center w-full p-4 md:p-6 z-10 -mt-4 sm:-mt-8">
      
      <div
        class="tip-banner mb-6 px-5 py-2 rounded-full bg-gradient-to-r from-amber-500/10 via-amber-400/5 to-amber-500/0 dark:from-amber-400/10 dark:via-amber-400/5 dark:to-transparent border border-amber-500/20 dark:border-amber-400/20 backdrop-blur-xl inline-flex items-center gap-2.5 shadow-[0_6px_20px_rgba(251,191,36,0.05)] animate-fade-in-down"
      >
        <div class="tip-banner-icon shrink-0 relative w-5 h-5 flex items-center justify-center">
          <span class="absolute inset-0 rounded-full bg-amber-500/20 dark:bg-amber-400/20 tip-banner-pulse-ring"></span>
          <span class="relative w-4 h-4 rounded-full bg-gradient-to-br from-amber-400 to-amber-500 text-white flex items-center justify-center shadow-md">
            <Icon :icon="iconInfo" width="10" height="10" />
          </span>
        </div>
        <p class="text-[13px] font-bold text-amber-700/90 dark:text-amber-400/90 leading-none">
          首次使用请先注册<span class="underline decoration-amber-500/40 underline-offset-4 font-black">《酷狗概念版》</span>账号
        </p>
      </div>

      <Tabs v-model="activeTab" activationMode="manual" class="w-full max-w-[400px] md:max-w-[800px]">
        <div
          class="flex flex-col md:flex-row bg-bg-card/75 dark:bg-[#1C1C1E]/80 backdrop-blur-3xl border border-black/[0.05] dark:border-white/[0.06] rounded-[32px] shadow-[0_30px_70px_rgba(0,0,0,0.08)] overflow-hidden transition-all duration-500"
        >
          <div class="hidden md:flex w-1/2 flex-col justify-center items-center p-10 bg-gradient-to-b from-primary/[0.03] to-secondary/[0.03] relative border-r border-black/[0.03] dark:border-white/5">
            <div class="absolute -top-16 -left-16 w-36 h-36 bg-primary/10 rounded-full blur-3xl opacity-60"></div>
            <div class="absolute -bottom-16 -right-16 w-36 h-36 bg-secondary/10 rounded-full blur-3xl opacity-60"></div>
            
            <div class="w-20 h-20 rounded-2xl bg-gradient-to-tr from-primary to-secondary flex items-center justify-center shadow-xl text-white mb-6 transform hover:rotate-6 transition-transform duration-300">
              <Icon :icon="iconSparkles" width="36" height="36" />
            </div>
            <h2 class="text-xl font-black text-text-main tracking-wider">易格音乐</h2>
            <p class="text-[12px] text-text-secondary/70 font-semibold mt-2.5 text-center px-6 leading-relaxed">
              纯净 · 智联多端听歌体验<br>自适应大屏控制舱已就绪
            </p>
          </div>

          <div class="w-full md:w-1/2 flex flex-col justify-between p-6 sm:p-8 md:p-10 min-h-[380px] md:min-h-[440px]">
            <div class="flex-1 flex flex-col items-center justify-center">
              
              <TabsContent value="0" class="w-full animate-tab-fade flex flex-col items-center">
                <div class="text-center mb-6">
                  <h1 class="text-[24px] font-black tracking-tight text-text-main mb-1">酷狗扫码</h1>
                  <p class="text-[11px] opacity-40 font-bold uppercase tracking-[2px]">请使用酷狗音乐APP进行扫码</p>
                </div>
                <div class="relative w-44 h-44 bg-white p-3 rounded-[24px] shadow-lg border border-black/[0.01] hover:shadow-xl transition-shadow duration-300">
                  <Image :src="qrUrl" class="w-full h-full rounded-xl" />
                  <div v-if="qrStatus === 0" class="absolute inset-0 bg-white/95 rounded-[24px] flex flex-col items-center justify-center space-y-3 z-30 animate-fade-in">
                    <span class="text-[13px] font-bold text-text-main/60">{{ qrError || '二维码已失效' }}</span>
                    <Button @click="loadQrCode" variant="primary" size="xs" class="text-[12px] font-bold rounded-full shadow-md active:scale-95 transition-transform">重新加载</Button>
                  </div>
                  <div v-if="qrStatus === 2" class="absolute inset-0 bg-white/98 rounded-[24px] flex flex-col items-center justify-center space-y-4 z-30 animate-fade-in">
                    <div class="w-12 h-12 bg-green-500 rounded-full flex items-center justify-center text-white shadow-lg shadow-green-500/20">
                      <Icon :icon="iconCheck" width="26" height="26" />
                    </div>
                    <p class="text-[13px] font-bold text-green-600">请在手机端确认登录</p>
                  </div>
                </div>
                <div class="mt-5 w-full relative flex items-center justify-center">
                  <span class="text-[11px] font-bold opacity-35 uppercase tracking-[3px] animate-pulse">安全加密长轮询中</span>
                  <button class="absolute right-2 w-8 h-8 rounded-full flex items-center justify-center text-text-main/40 hover:text-primary hover:bg-primary/10 transition-all active:scale-90" :disabled="isLoadingQr" @click="loadQrCode">
                    <Icon :icon="iconRefreshCw" width="14" height="14" />
                  </button>
                </div>
              </TabsContent>

              <TabsContent value="1" class="w-full animate-tab-fade pb-2">
                <div class="text-center mb-6">
                  <h1 class="text-[24px] font-black tracking-tight text-text-main mb-1">手机快速登录</h1>
                  <p class="text-[11px] opacity-40 font-bold uppercase tracking-[2px]">免密快捷验证，畅听无阻</p>
                </div>
                <div class="flex flex-col space-y-4">
                  <Input v-model="smsData.mobile" type="tel" placeholder="请输入手机号码" inputClass="h-11 rounded-xl focus:ring-2 focus:ring-primary/20 transition-all" />
                  <div class="flex gap-3">
                    <Input v-model="smsData.code" placeholder="输入动态验证码" class="flex-1" inputClass="h-11 rounded-xl focus:ring-2 focus:ring-primary/20 transition-all" />
                    <Button variant="secondary" class="shrink-0 h-11 px-4 text-[13px] rounded-xl font-bold active:scale-[0.97] transition-transform" :disabled="smsData.countdown > 0" @click="handleSendCode">
                      {{ smsData.countdown > 0 ? `${smsData.countdown}s` : '获取验证码' }}
                    </Button>
                  </div>
                  <div class="h-4 flex items-center px-1">
                    <p v-if="smsData.error" class="text-[11px] text-red-500 font-bold flex items-center gap-1">⚠ {{ smsData.error }}</p>
                  </div>
                  <Button class="w-full h-11 rounded-xl font-bold text-[15px] shadow-lg shadow-primary/20 active:scale-[0.97] transition-transform" :loading="smsData.isSending" @click="handleSmsLogin">立即登入舱内</Button>
                </div>
              </TabsContent>

              <TabsContent value="2" class="w-full animate-tab-fade flex flex-col items-center">
                <div class="text-center mb-6">
                  <h1 class="text-[24px] font-black tracking-tight text-text-main mb-1">微信扫码</h1>
                  <p class="text-[11px] opacity-40 font-bold uppercase tracking-[2px]">请使用手机微信扫描二维码</p>
                </div>
                <div class="relative w-44 h-44 bg-white p-3 rounded-[24px] shadow-lg border border-black/[0.01] hover:shadow-xl transition-shadow duration-300">
                  <Image :src="wxQr.url" class="w-full h-full rounded-xl" />
                  <div v-if="wxQr.status === 3" class="absolute inset-0 bg-white/95 rounded-[24px] flex flex-col items-center justify-center space-y-3 z-30 animate-fade-in">
                    <span class="text-[13px] font-bold text-text-main/60">{{ wxQr.error || '二维码已过期' }}</span>
                    <Button @click="loadWxQr" variant="primary" size="xs" class="text-[12px] font-bold rounded-full bg-[#07C160] border-none text-white shadow-md active:scale-95 transition-transform">重新生成</Button>
                  </div>
                  <div v-if="wxQr.status === 1" class="absolute inset-0 bg-white/98 rounded-[24px] flex flex-col items-center justify-center space-y-4 z-30 animate-fade-in">
                    <div class="w-12 h-12 bg-[#07C160] rounded-full flex items-center justify-center text-white shadow-lg shadow-[#07C160]/20">
                      <Icon :icon="iconCheck" width="26" height="26" />
                    </div>
                    <p class="text-[13px] font-bold text-[#07C160]">微信端已成功扫描</p>
                  </div>
                </div>
                <div class="mt-5 w-full relative flex items-center justify-center">
                  <span class="text-[11px] font-bold text-[#07C160]/70 uppercase tracking-[3px] animate-pulse">微信互联互通保护中</span>
                  <button class="absolute right-2 w-8 h-8 rounded-full flex items-center justify-center text-text-main/40 hover:text-[#07C160] hover:bg-[#07C160]/10 transition-all active:scale-90" :disabled="wxQr.isLoading" @click="loadWxQr">
                    <Icon :icon="iconRefreshCw" width="14" height="14" />
                  </button>
                </div>
              </TabsContent>
            </div>

            <div class="mt-6 pt-5 border-t border-black/[0.04] dark:border-white/[0.04] flex flex-col items-center space-y-3.5">
              <span class="text-[11px] font-extrabold opacity-40 uppercase tracking-[3px]">切换其他登录方式</span>
              <TabsList class="gap-8 !h-auto items-center">
                <TabsTrigger value="0" class="group !h-auto !pb-0 items-center data-[state=active]:hidden [&_.active-line]:hidden">
                  <div class="w-12 h-12 rounded-full border border-border-light/70 dark:border-white/10 flex items-center justify-center text-primary/60 group-hover:text-primary transition-all group-active:scale-90 group-hover:bg-primary/5 shadow-sm">
                    <Icon :icon="iconQrCode" width="20" height="20" />
                  </div>
                </TabsTrigger>
                <TabsTrigger value="1" class="group !h-auto !pb-0 items-center data-[state=active]:hidden [&_.active-line]:hidden">
                  <div class="w-12 h-12 rounded-full border border-border-light/70 dark:border-white/10 flex items-center justify-center text-text-main/50 group-hover:text-primary transition-all group-active:scale-90 group-hover:bg-primary/5 shadow-sm">
                    <Icon :icon="iconSmartphone" width="20" height="20" />
                  </div>
                </TabsTrigger>
                <TabsTrigger value="2" class="group !h-auto !pb-0 items-center data-[state=active]:hidden [&_.active-line]:hidden">
                  <div class="w-12 h-12 rounded-full border border-border-light/70 dark:border-white/10 flex items-center justify-center text-[#07C160]/60 group-hover:text-[#07C160] transition-all group-active:scale-90 group-hover:bg-[#07C160]/5 shadow-sm">
                    <Icon :icon="iconBotMessageSquare" width="22" height="22" />
                  </div>
                </TabsTrigger>
              </TabsList>
            </div>
          </div>

        </div>
      </Tabs>
    </div>
  </div>
</template>

<style scoped>
.animate-tab-fade {
  animation: tab-slide-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) forwards;
}
@keyframes tab-slide-in {
  from {
    opacity: 0;
    transform: translateY(16px) scale(0.98);
  }
  to {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

.animate-fade-in {
  animation: fade-in-scale 0.3s cubic-bezier(0.16, 1, 0.3, 1) forwards;
}
@keyframes fade-in-scale {
  from { opacity: 0; transform: scale(0.95); }
  to { opacity: 1; transform: scale(1); }
}

.animate-fade-in-down {
  animation: fade-in-down-anim 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
}
@keyframes fade-in-down-anim {
  from { opacity: 0; transform: translateY(-10px); }
  to { opacity: 1; transform: translateY(0); }
}

.tip-banner-pulse-ring {
  animation: banner-glow-pulse 2.4s ease-in-out infinite;
}
@keyframes banner-glow-pulse {
  0%, 100% { transform: scale(1); opacity: 0.6; }
  50% { transform: scale(1.4); opacity: 0; }
}

/* 安全区置顶补正 */
.pt-safe {
  padding-top: max(12px, env(safe-area-inset-top, 12px));
}
.pb-safe {
  padding-bottom: max(16px, env(safe-area-inset-bottom, 16px));
}
</style>