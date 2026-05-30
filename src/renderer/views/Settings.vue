<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted, watch } from 'vue';
import { useSettingStore, type PortraitCoverStyle, type VoiceSearchMode } from '@/stores/setting';
import { usePlayerStore } from '@/stores/player';
import { useThemeStore, type AccentMode } from '@/stores/theme';
import { ACCENT_PRESETS } from '@/utils/color';
import { useLyricColorPicker } from '@/utils/useLyricColorPicker';
import { useLyricStore } from '@/stores/lyric';
import { useToastStore } from '@/stores/toast';
import { isGeckoView, NativeLyricBridge, NativeAudioBridge, NativeUpdateBridge } from '@/utils/nativeBridge';
import { useDesktopLyricStore } from '@/desktopLyric/store';
import type { AudioQualityValue } from '@/types';
import type { ThemeMode } from '../../shared/app';
import Select from '@/components/ui/Select.vue';
import Slider from '@/components/ui/Slider.vue';
import Switch from '@/components/ui/Switch.vue';
import Dialog from '@/components/ui/Dialog.vue';
import Button from '@/components/ui/Button.vue';
import Scrollbar from '@/components/ui/Scrollbar.vue';
import InputNumber from '@/components/ui/InputNumber.vue';
import Input from '@/components/ui/Input.vue';
import ColorPickerDialog from '@/components/ui/ColorPickerDialog.vue';
import DisclaimerDialog from '@/components/app/DisclaimerDialog.vue';
import PageLyricIcon from '@/components/ui/PageLyricIcon.vue';

// 引入 package.json 以自动获取版本号
import pkg from '../../../package.json';

import { marked } from 'marked';
import {
  iconPalette,
  iconPlayerPlay,
  iconVolume2,
  iconFlask,
  iconInfo,
  iconExternalLink,
  iconChevronRight,
  iconWorld,
  iconTypography,
  iconDatabase,
} from '@/icons';

const settingStore = useSettingStore();
const playerStore = usePlayerStore();
const lyricStore = useLyricStore();
const themeStore = useThemeStore();
const toastStore = useToastStore();
const desktopLyricStore = useDesktopLyricStore();
const showDisclaimer = ref(false);

// ── Android 桌面歌词 ──
const androidLyricEnabled = ref(false);
const androidLyricFontSize = ref(18);
const androidLyricLightColorIndex = ref(0);
const androidLyricDarkColorIndex = ref(0);
const androidLyricDoubleLine = ref(false);
const androidLyricWidthPercent = ref(100);
const androidLyricStrokeEnabled = ref(false);
const androidLyricAlignment = ref('center');
const androidLyricLocked = ref(false);
let androidLyricPollTimer = 0;

const ANDROID_LYRIC_PREFIX = 'android_lyric_';

const saveAndroidLyricState = () => {
  try {
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}enabled`, String(androidLyricEnabled.value));
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}fontSize`, String(androidLyricFontSize.value));
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}lightColorIndex`, String(androidLyricLightColorIndex.value));
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}darkColorIndex`, String(androidLyricDarkColorIndex.value));
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}colorIndex`, String(androidLyricLightColorIndex.value)); // 兼容
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}doubleLine`, String(androidLyricDoubleLine.value));
    localStorage.setItem(
      `${ANDROID_LYRIC_PREFIX}widthPercent`,
      String(androidLyricWidthPercent.value),
    );
    localStorage.setItem(
      `${ANDROID_LYRIC_PREFIX}strokeEnabled`,
      String(androidLyricStrokeEnabled.value),
    );
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}alignment`, androidLyricAlignment.value);
    localStorage.setItem(`${ANDROID_LYRIC_PREFIX}locked`, String(androidLyricLocked.value));
  } catch {}
};

const restoreAndroidLyricState = async () => {
  try {
    const nativeSettings = (await NativeLyricBridge.getLyricSettings().catch(() => null)) as any;
    if (
      nativeSettings &&
      typeof nativeSettings === 'object' &&
      nativeSettings.fontSize !== undefined
    ) {
      if (typeof nativeSettings.fontSize === 'number')
        androidLyricFontSize.value = nativeSettings.fontSize;
      if (typeof nativeSettings.lightColorIndex === 'number')
        androidLyricLightColorIndex.value = nativeSettings.lightColorIndex;
      if (typeof nativeSettings.darkColorIndex === 'number')
        androidLyricDarkColorIndex.value = nativeSettings.darkColorIndex;
      if (typeof nativeSettings.doubleLine === 'boolean')
        androidLyricDoubleLine.value = nativeSettings.doubleLine;
      if (typeof nativeSettings.locked === 'boolean')
        androidLyricLocked.value = nativeSettings.locked;
      if (typeof nativeSettings.widthPercent === 'number')
        androidLyricWidthPercent.value = nativeSettings.widthPercent;
      if (typeof nativeSettings.strokeEnabled === 'boolean')
        androidLyricStrokeEnabled.value = nativeSettings.strokeEnabled;
      if (typeof nativeSettings.alignment === 'string')
        androidLyricAlignment.value = nativeSettings.alignment;
      if (typeof nativeSettings.enabled === 'boolean')
        androidLyricEnabled.value = nativeSettings.enabled;
    } else {
      const savedFontSize = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}fontSize`);
      const savedLightColorIndex = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}lightColorIndex`);
      const savedDarkColorIndex = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}darkColorIndex`);
      const savedColorIndex = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}colorIndex`);
      const savedDoubleLine = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}doubleLine`);
      const savedWidthPercent = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}widthPercent`);
      const savedStrokeEnabled = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}strokeEnabled`);
      const savedAlignment = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}alignment`);
      const savedLocked = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}locked`);
      if (savedFontSize) androidLyricFontSize.value = Number(savedFontSize);
      if (savedLightColorIndex) androidLyricLightColorIndex.value = Number(savedLightColorIndex);
      if (savedDarkColorIndex) androidLyricDarkColorIndex.value = Number(savedDarkColorIndex);
      if (!savedLightColorIndex && savedColorIndex) {
        androidLyricLightColorIndex.value = Number(savedColorIndex);
        androidLyricDarkColorIndex.value = Number(savedColorIndex);
      }
      if (savedDoubleLine) androidLyricDoubleLine.value = savedDoubleLine === 'true';
      if (savedWidthPercent) androidLyricWidthPercent.value = Number(savedWidthPercent);
      if (savedStrokeEnabled) androidLyricStrokeEnabled.value = savedStrokeEnabled === 'true';
      if (savedAlignment) androidLyricAlignment.value = savedAlignment;
      if (savedLocked) androidLyricLocked.value = savedLocked === 'true';
    }

    if (!androidLyricEnabled.value) {
      const savedEnabled = localStorage.getItem(`${ANDROID_LYRIC_PREFIX}enabled`);
      if (savedEnabled === 'true') {
        androidLyricEnabled.value = true;
        handleAndroidLyricToggle(true);
      }
    }
    saveAndroidLyricState();
  } catch {}
};

const androidLyricLightColors = [
  { label: '纯黑', value: 0, hex: '#000000' },
  { label: '深灰', value: 1, hex: '#333333' },
  { label: '靛蓝', value: 2, hex: '#1A237E' },
  { label: '玫红', value: 3, hex: '#880E4F' },
  { label: '墨绿', value: 4, hex: '#1B5E20' },
  { label: '蓝灰', value: 5, hex: '#263238' },
  { label: '棕褐', value: 6, hex: '#4E342E' },
];

const androidLyricDarkColors = [
  { label: '纯白', value: 0, hex: '#FFFFFF' },
  { label: '浅灰', value: 1, hex: '#E0E0E0' },
  { label: '琥珀', value: 2, hex: '#FFCA28' },
  { label: '青蓝', value: 3, hex: '#00E5FF' },
  { label: '薄荷', value: 4, hex: '#69F0AE' },
  { label: '粉红', value: 5, hex: '#FF4081' },
  { label: '淡紫', value: 6, hex: '#B388FF' },
];

const lyricPermOverlayGranted = ref(false);
const lyricPermNotificationGranted = ref(false);
const lyricPermBatteryIgnoring = ref(false);

const checkAndroidLyricPermissions = async () => {
  try {
    const perm = await NativeLyricBridge.checkLyricPermission();
    lyricPermOverlayGranted.value = perm.overlayGranted;
    lyricPermNotificationGranted.value = perm.notificationGranted;
  } catch {}
  try {
    const batt = await NativeLyricBridge.checkBatteryOptimization();
    lyricPermBatteryIgnoring.value = batt.ignoring;
  } catch {}
};

const handleAndroidLyricToggle = async (enabled: boolean) => {
  if (!enabled) {
    androidLyricEnabled.value = false;
    saveAndroidLyricState();
    desktopLyricStore.setEnabled(false);
    await NativeLyricBridge.hideFloatingLyric().catch(() => {});
    return;
  }
  try {
    const permResult = await NativeLyricBridge.checkLyricPermission();
    if (!permResult.overlayGranted || !permResult.notificationGranted) {
      const missing: string[] = [];
      if (!permResult.overlayGranted) missing.push('"显示在其他应用上层"');
      if (!permResult.notificationGranted) missing.push('"通知"');
      toastStore.warning(
        `缺少${missing.join('、')}权限，请前往系统设置 → 应用管理 → EchoMusic 开启`,
      );
      if (!permResult.overlayGranted) {
        await NativeLyricBridge.requestOverlayPermission();
      }
      return;
    }

    const showResult = await NativeLyricBridge.showFloatingLyric();
    if (showResult.shown) {
      androidLyricEnabled.value = true;
      saveAndroidLyricState();
      desktopLyricStore.setEnabled(true);
    }
  } catch (e: any) {
    androidLyricEnabled.value = false;
    saveAndroidLyricState();
    const msg = String(e?.message || '未知错误');
    toastStore.warning(`桌面歌词开启失败: ${msg}`);
  }
};

const handleAndroidLyricSettingChange = () => {
  saveAndroidLyricState();
  desktopLyricStore.setLocal({
    doubleLine: androidLyricDoubleLine.value,
    locked: androidLyricLocked.value,
  });
  NativeLyricBridge.updateLyricSettings({
    lightColorIndex: androidLyricLightColorIndex.value,
    darkColorIndex: androidLyricDarkColorIndex.value,
    colorIndex: androidLyricLightColorIndex.value,
    fontSize: androidLyricFontSize.value,
    doubleLine: androidLyricDoubleLine.value,
    widthPercent: androidLyricWidthPercent.value,
    strokeEnabled: androidLyricStrokeEnabled.value,
    alignment: androidLyricAlignment.value,
    locked: androidLyricLocked.value,
  });
};

// ── 缓存管理（Android）──
const cacheInfo = ref({ sizeBytes: 0, fileCount: 0, maxSizeBytes: 500 * 1024 * 1024 });
const cacheUsageText = computed(() => {
  const mb = (cacheInfo.value.sizeBytes / (1024 * 1024)).toFixed(1);
  const maxMb = (cacheInfo.value.maxSizeBytes / (1024 * 1024)).toFixed(0);
  return `${mb} MB / ${maxMb} MB（${cacheInfo.value.fileCount} 首歌曲）`;
});

const refreshCacheInfo = async () => {
  if (!isGeckoView) return;
  try {
    const info = await NativeAudioBridge.getCacheInfo();
    if (info && typeof info === 'object') {
      cacheInfo.value = {
        sizeBytes: info.sizeBytes ?? 0,
        fileCount: info.fileCount ?? 0,
        maxSizeBytes: info.maxSizeBytes ?? 500 * 1024 * 1024,
      };
    }
  } catch {}
};

const handleCacheSizeChange = async (mb: number | string) => {
  const value = typeof mb === 'string' ? parseInt(mb, 10) : mb;
  if (!Number.isFinite(value)) return;
  settingStore.cacheSizeLimitMb = value;
  if (isGeckoView) {
    await NativeAudioBridge.setCacheSizeLimit({ mb: value }).catch(() => {});
    await refreshCacheInfo();
  }
};

const handleClearCache = async () => {
  if (!isGeckoView) return;
  await NativeAudioBridge.clearCache().catch(() => {});
  await refreshCacheInfo();
  toastStore.success('缓存已清除');
};

// ── 远端服务 ──
const isApiFocused = ref(false);
const isTestingConnection = ref(false);

const testConnection = async () => {
  isTestingConnection.value = true;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const base = (settingStore.apiBaseUrl || '').replace(/\/+$/, '');
    if (!base) {
      toastStore.warning('请先填写 API 地址');
      return;
    }
    await fetch(base, { method: 'HEAD', mode: 'no-cors', signal: controller.signal });
    clearTimeout(timeout);
    toastStore.success('API 连接成功');
  } catch {
    toastStore.warning('API 连接失败，请检查地址是否正确');
  } finally {
    isTestingConnection.value = false;
  }
};

// ── 主题色与模式选项 ──
const accentModeOptions: { label: string; value: AccentMode }[] = [
  { label: '跟随封面', value: 'cover' },
  { label: '预设主题', value: 'preset' },
  { label: '自定义', value: 'custom' },
];

const accentPresets = ACCENT_PRESETS;
const showAccentPicker = ref(false);
const accentPresetValues = accentPresets.map((item) => item.color);

const keepAliveOptions = [
  { label: '为您推荐', value: 'home' },
  { label: '每日推荐', value: 'recommend-songs' },
  { label: '排行榜', value: 'ranking' },
  { label: '探索发现', value: 'explore' },
  { label: '搜索', value: 'search-page' },
  { label: '我的云盘', value: 'cloud' },
  { label: '我最喜爱', value: 'favorites' },
  { label: '歌单详情', value: 'playlist-detail' },
  { label: '歌手详情', value: 'artist-detail' },
  { label: '专辑详情', value: 'album-detail' },
];

const lyricColorPicker = useLyricColorPicker();

const lyricFontSizeLabel = computed(() => `${Math.round(lyricStore.fontScale * 100)}%`);
const lyricFontWeightLabel = computed(() => `W${lyricStore.fontWeightValue}`);

const systemFontOptions = ref<{ label: string; value: string }[]>([]);
const globalFontOptions = computed(() => [
  { label: '系统默认', value: 'system-ui' },
  ...systemFontOptions.value,
]);
const lyricFontOptions = computed(() => [
  { label: '跟随全局', value: 'follow' },
  { label: '系统默认', value: 'system-ui' },
  ...systemFontOptions.value,
]);

const fetchSystemFonts = async () => {
  const fonts = await settingStore.fetchSystemFonts();
  const sorted = fonts.slice().sort((a, b) => {
    if (a === b) return 0;
    if (a.startsWith(b)) return 1;
    if (b.startsWith(a)) return -1;
    return a.localeCompare(b);
  });
  systemFontOptions.value = sorted.map((name) => ({ label: name, value: name }));
};

onMounted(() => {
  if (!isGeckoView) {
    settingStore.syncCloseBehavior();
    settingStore.syncTheme();
    void settingStore.hydrateAppInfo();
    void fetchSystemFonts();
  }
  if (isGeckoView) {
    void restoreAndroidLyricState();
    checkAndroidLyricPermissions();

    androidLyricPollTimer = window.setInterval(async () => {
      try {
        const ns = (await NativeLyricBridge.getLyricSettings()) as any;
        if (ns && typeof ns.locked === 'boolean') {
          if (androidLyricLocked.value !== ns.locked) {
            androidLyricLocked.value = ns.locked;
            saveAndroidLyricState();
          }
        }
      } catch {}
    }, 2000);

    void refreshCacheInfo();
    void NativeAudioBridge.setCacheSizeLimit({ mb: settingStore.cacheSizeLimitMb }).catch(() => {});
  }
});

onUnmounted(() => {
  if (androidLyricPollTimer) {
    clearInterval(androidLyricPollTimer);
    androidLyricPollTimer = 0;
  }
});

const handleVolumeNormalizationChange = (enabled: boolean) => {
  settingStore.volumeNormalization = enabled;
  playerStore.setVolumeNormalization(enabled);
};

const handleReferenceLufsSlider = (value: number) => {
  settingStore.volumeNormalizationLufs = value;
  playerStore.setReferenceLufs(value);
};

const showConfirmClear = ref(false);
const showChangelog = ref(false);
const changelogHtml = ref('');

// ── 新增：版本获取与更新检测相关 ──
const isCheckingUpdate = ref(false);
const showUpdateDialog = ref(false);
const latestVersionInfo = ref({
  version: '',
  releaseNotes: '',
  url: '',
  apkDownloadUrl: '',
  apkFileName: '',
});

// Android in-app update state
const updateDownloadPercent = ref(0);
const updateDownloadStatus = ref<'idle' | 'downloading' | 'downloaded' | 'error'>('idle');
const updateDownloadError = ref('');
const downloadedApkPath = ref('');
let updateProgressListener: { remove: () => void } | null = null;
let updateCompleteListener: { remove: () => void } | null = null;
let updateErrorListener: { remove: () => void } | null = null;

// 计算当前APP版本：优先使用主进程注入的 appVersion，降级使用 package.json 的 version
const currentAppVersion = computed(() => settingStore.appVersion || pkg.version || '1.0.0');

const aboutVersionText = computed(() => {
  if (isGeckoView) {
    return `易格音乐 v${currentAppVersion.value}`;
  }
  return `Version v${currentAppVersion.value} ${settingStore.isPrerelease ? '测试版' : '正式版'}`;
});

const webviewEngineInfo = computed(() => {
  const ua = navigator.userAgent;
  if (/Gecko\//.test(ua) && !/Firefox\//.test(ua)) {
    const match = ua.match(/Gecko\/([\d.]+)/);
    return match ? `GeckoView ${match[1]}` : 'GeckoView';
  }
  if (/AppleWebKit\//.test(ua) && /Chrome\//.test(ua)) {
    const match = ua.match(/Chrome\/([\d.]+)/);
    return match ? `Blink ${match[1]}` : 'Blink';
  }
  if (/Gecko\//.test(ua) && /Firefox\//.test(ua)) {
    const match = ua.match(/Firefox\/([\d.]+)/);
    return match ? `Gecko ${match[1]}` : 'Gecko';
  }
  if (/AppleWebKit\//.test(ua)) {
    const match = ua.match(/Version\/([\d.]+)/);
    return match ? `WebKit ${match[1]}` : 'WebKit';
  }
  return '未知';
});

// 版本对比工具函数
const compareVersions = (v1: string, v2: string) => {
  const p1 = v1.replace(/^v/i, '').split('.').map(Number);
  const p2 = v2.replace(/^v/i, '').split('.').map(Number);
  for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
    const n1 = p1[i] || 0;
    const n2 = p2[i] || 0;
    if (n1 > n2) return 1;
    if (n1 < n2) return -1;
  }
  return 0;
};

// 从 GitHub Releases 获取最新版本
const checkForUpdates = async () => {
  if (isCheckingUpdate.value) return;
  isCheckingUpdate.value = true;
  try {
    const response = await fetch('https://api.github.com/repos/e-cells/E-cells-Music/releases/latest');
    if (!response.ok) throw new Error('网络请求失败');
    const data = await response.json();

    const latestTag = data.tag_name;
    if (compareVersions(latestTag, currentAppVersion.value) > 0) {
      let apkDownloadUrl = '';
      let apkFileName = '';

      // Auto-detect ABI and match APK for Android
      if (isGeckoView && data.assets && data.assets.length > 0) {
        try {
          const abiInfo = await NativeUpdateBridge.getDeviceAbiInfo();
          const bestAbi = abiInfo.bestMatch;
          const matchedAsset = data.assets.find((a: any) =>
            a.name && a.name.includes(`-${bestAbi}-`) && a.name.endsWith('.apk')
          );
          if (matchedAsset) {
            apkDownloadUrl = matchedAsset.browser_download_url;
            apkFileName = matchedAsset.name;
          }
        } catch (e) {
          console.warn('Failed to detect ABI for update:', e);
        }
      }

      latestVersionInfo.value = {
        version: latestTag,
        releaseNotes: data.body || '暂无更新说明',
        url: data.html_url,
        apkDownloadUrl,
        apkFileName,
      };
      showUpdateDialog.value = true;
    } else {
      toastStore.success('当前已是最新版本');
    }
  } catch (error) {
    toastStore.warning('检查更新失败，请检查网络连接');
    console.error('Update check failed:', error);
  } finally {
    isCheckingUpdate.value = false;
  }
};

const goToReleasePage = () => {
  handleOpenExternalUrl(latestVersionInfo.value.url);
  showUpdateDialog.value = false;
};

const cleanupUpdateListeners = () => {
  updateProgressListener?.remove();
  updateCompleteListener?.remove();
  updateErrorListener?.remove();
  updateProgressListener = null;
  updateCompleteListener = null;
  updateErrorListener = null;
};

const handleUpdateDownload = async () => {
  if (!latestVersionInfo.value.apkDownloadUrl) {
    goToReleasePage();
    return;
  }

  // Check install permission
  try {
    const perm = await NativeUpdateBridge.checkInstallPermission();
    if (!perm.granted) {
      await NativeUpdateBridge.requestInstallPermission();
      toastStore.warning('请在系统设置中允许安装未知来源应用');
      return;
    }
  } catch {}

  cleanupUpdateListeners();

  updateProgressListener = NativeUpdateBridge.addListener(
    'updateDownloadProgress',
    (data: any) => {
      updateDownloadStatus.value = 'downloading';
      updateDownloadPercent.value = Math.round((data.percent || 0) * 100);
    }
  );
  updateCompleteListener = NativeUpdateBridge.addListener(
    'updateDownloadComplete',
    (data: any) => {
      updateDownloadStatus.value = 'downloaded';
      downloadedApkPath.value = data.filePath || '';
      cleanupUpdateListeners();
    }
  );
  updateErrorListener = NativeUpdateBridge.addListener(
    'updateDownloadError',
    (data: any) => {
      updateDownloadStatus.value = 'error';
      updateDownloadError.value = data.error || '下载失败';
      cleanupUpdateListeners();
    }
  );

  updateDownloadStatus.value = 'downloading';
  updateDownloadPercent.value = 0;

  try {
    await NativeUpdateBridge.downloadApk({
      url: latestVersionInfo.value.apkDownloadUrl,
      fileName: latestVersionInfo.value.apkFileName,
    });
  } catch (e: any) {
    updateDownloadStatus.value = 'error';
    updateDownloadError.value = e.message || '下载失败';
    cleanupUpdateListeners();
  }
};

const handleUpdateInstall = async () => {
  if (!downloadedApkPath.value) return;
  try {
    await NativeUpdateBridge.installApk({ filePath: downloadedApkPath.value });
  } catch (e: any) {
    toastStore.warning('安装失败: ' + (e.message || '未知错误'));
  }
};

watch(showUpdateDialog, (open) => {
  if (!open) {
    updateDownloadStatus.value = 'idle';
    updateDownloadPercent.value = 0;
    updateDownloadError.value = '';
    downloadedApkPath.value = '';
    cleanupUpdateListeners();
  }
});
// ── 新增结束 ──

const audioQualityOptions = [
  { label: '标准品质', value: '128' },
  { label: 'HQ 高品质', value: '320' },
  { label: 'SQ 无损品质', value: 'flac' },
  { label: 'Hi-Res 品质', value: 'high' },
  { label: 'DSD 臻品音质', value: 'super' },
];

const themeOptions = [
  { label: '跟随系统', value: 'system' },
  ...(isGeckoView ? [{ label: '跟随光感器', value: 'sensor' }] : []),
  { label: '浅色模式', value: 'light' },
  { label: '深色模式', value: 'dark' },
];

const orientationOptions = [
  { label: '自动旋转', value: 'auto' },
  { label: '横屏锁定', value: 'landscape' },
  { label: '竖屏锁定', value: 'portrait' },
];

const portraitCoverStyleOptions = [
  { label: '经典方形', value: 'square' },
  { label: '光盘旋转', value: 'disc' },
  { label: '呼吸脉动', value: 'breathing' },
];

const voiceSearchModeOptions = [
  { label: '全部结果', value: 'all' },
  { label: '仅播首曲', value: 'first' },
];

const handleOpenExternalUrl = async (url: string) => {
  if (isGeckoView) {
    await NativeLyricBridge.openExternalUrl(url).catch(() => {});
    return;
  }
  if (window.electron?.ipcRenderer) {
    window.electron.ipcRenderer.send('open-external', url);
  }
};

const handleShowChangelog = async () => {
  try {
    const raw = await window.electron?.appInfo?.getChangelog();
    if (!raw) {
      changelogHtml.value = '<p>暂无更新日志</p>';
    } else {
      changelogHtml.value = marked.parse(raw, { async: false }) as string;
    }
  } catch {
    changelogHtml.value = '<p>无法读取更新日志</p>';
  }
  showChangelog.value = true;
};
</script>

<template>
  <div class="settings-view w-full min-h-full px-4 sm:px-8 pt-4 pb-8 space-y-8 sm:space-y-12 transition-colors duration-300">
    <header>
      <h1 class="text-[22px] font-black tracking-tight text-text-main">偏好设置</h1>
    </header>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconWorld" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">远端服务</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">服务地址</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">KuGouMusicApi地址</p>
          </div>
          <input
            :value="isApiFocused ? settingStore.apiBaseUrl : (settingStore.apiBaseUrl ? '*'.repeat(settingStore.apiBaseUrl.length) : '')"
            placeholder="https://example.com"
            class="w-[140px] sm:w-[280px] h-[44px] px-3 sm:px-4 bg-black/[0.03] dark:bg-white/[0.03] border border-transparent rounded-xl outline-none transition-all font-medium text-[13px] sm:text-[15px] placeholder:opacity-50"
            @focus="isApiFocused = true"
            @blur="isApiFocused = false"
            @input="settingStore.apiBaseUrl = ($event.target as HTMLInputElement).value"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">测试连接</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">验证当前 API 地址是否可达</p>
          </div>
          <Button
            variant="outline"
            size="xs"
            class="settings-button whitespace-nowrap"
            :disabled="isTestingConnection"
            @click="testConnection"
            >{{ isTestingConnection ? '测试中...' : '测试连接' }}</Button
          >
        </div>
      </div>
    </section>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconPalette" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">外观与界面</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">主题模式</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">选择您喜欢的主题外观</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="settingStore.theme"
            :options="themeOptions"
            @update:model-value="settingStore.setTheme($event as ThemeMode)"
          />
        </div>

        <div class="settings-divider"></div>
        <div v-if="isGeckoView" class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">屏幕方向</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">选择应用显示方向，重启后生效</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="settingStore.screenOrientation"
            :options="orientationOptions"
            @update:model-value="
              settingStore.setScreenOrientation(String($event) as 'auto' | 'landscape' | 'portrait')
            "
          />
        </div>
        <div v-if="isGeckoView" class="settings-divider"></div>
        <div v-if="isGeckoView" class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">播放封面样式</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">选择播放页的封面展示效果</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="settingStore.portraitCoverStyle"
            :options="portraitCoverStyleOptions"
            @update:model-value="settingStore.setPortraitCoverStyle($event as PortraitCoverStyle)"
          />
        </div>
        <div v-if="isGeckoView" class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">主题色来源</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">切歌自动跟随封面，或固定颜色</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="themeStore.accentMode"
            :options="accentModeOptions"
            @update:model-value="themeStore.setMode($event as AccentMode)"
          />
        </div>
        <div v-if="themeStore.accentMode === 'preset'" class="settings-item items-start">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">预设主题色</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">挑一个贴合心情的配色</p>
          </div>
          <div class="flex gap-2 flex-wrap sm:flex-nowrap justify-end max-w-[50%]">
            <button
              v-for="preset in accentPresets"
              :key="preset.id"
              type="button"
              class="accent-preset-swatch"
              :class="{ 'is-active': themeStore.presetId === preset.id }"
              :style="{ backgroundColor: preset.color }"
              :title="preset.name"
              @click="themeStore.setPreset(preset.id)"
            ></button>
          </div>
        </div>
        <div v-if="themeStore.accentMode === 'custom'" class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">自定义主题色</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">从色盘中选一种颜色固定为主题色</p>
          </div>
          <button
            type="button"
            class="settings-color-swatch flex-shrink-0"
            :style="{ backgroundColor: themeStore.customColor }"
            @click="showAccentPicker = true"
          ></button>
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">全局主题色</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">关闭后仅播放栏与歌词页跟随主题色</p>
          </div>
          <Switch
            :model-value="themeStore.globalAccent"
            @update:model-value="themeStore.setGlobalAccent(Boolean($event))"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">歌词字色跟随主题</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">已播色自动跟随主题色，手动颜色优先</p>
          </div>
          <Switch
            :model-value="themeStore.lyricAccentSync"
            @update:model-value="themeStore.setLyricAccentSync(Boolean($event))"
          />
        </div>
      </div>
    </section>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconPlayerPlay" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">播放体验</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">播放替换队列</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">双击播放单曲时用当前列表替换播放队列</p>
          </div>
          <Switch v-model="settingStore.replacePlaylist" />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">语音搜歌</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">选择语音搜索歌曲后的播放方式</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="settingStore.voiceSearchMode"
            :options="voiceSearchModeOptions"
            @update:model-value="settingStore.voiceSearchMode = $event as VoiceSearchMode"
          />
        </div>
        <template v-if="!isGeckoView">
          <div class="settings-divider"></div>
          <div class="settings-item">
            <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
              <h3 class="font-semibold text-[15px] sm:text-base truncate">淡入淡出播放</h3>
              <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">启用歌曲切换时的过渡效果</p>
            </div>
            <Switch v-model="settingStore.volumeFade" />
          </div>
          <div v-if="settingStore.volumeFade" class="settings-item">
            <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
              <h3 class="font-semibold text-[15px] sm:text-base truncate">淡入淡出时长</h3>
              <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">调整歌曲切换时的过渡时长</p>
            </div>
            <Slider
              class="w-28 sm:w-48 flex-shrink-0"
              :model-value="settingStore.volumeFadeTime"
              :min="500"
              :max="3000"
              :step="100"
              show-value
              :value-suffix="'ms'"
              @update:model-value="settingStore.volumeFadeTime = $event"
              @value-commit="settingStore.volumeFadeTime = $event"
            />
          </div>
        </template>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">启动后自动播放</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">打开 APP 时自动恢复上次播放的歌曲和进度</p>
          </div>
          <Switch
            :model-value="settingStore.autoPlayOnStart"
            @update:model-value="(value: boolean) => {
              settingStore.autoPlayOnStart = value;
              // 绕过 pinia-plugin-persistedstate，直接调用 localStorage.setItem
              // 确保覆盖函数中的 window.prompt 桥立即同步到 SharedPreferences
              try { localStorage.setItem('setting', JSON.stringify(settingStore.$state)); } catch {}
            }"
          />
        </div>
      </div>
    </section>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconVolume2" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">播放音质</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">默认音质</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">
              新歌曲默认按此音质解析，播放器中可临时覆盖当前歌曲
            </p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="settingStore.defaultAudioQuality"
            :options="audioQualityOptions"
            @update:model-value="settingStore.defaultAudioQuality = $event as AudioQualityValue"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">智能兼容模式</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">首选音质不可用时自动尝试备选</p>
          </div>
          <Switch v-model="settingStore.compatibilityMode" />
        </div>
      </div>
    </section>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <PageLyricIcon :size="18" />
        </div>
        <h2 class="text-lg font-bold">{{ isGeckoView ? '歌词页' : '页面歌词' }}</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">显示翻译</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">有翻译时在歌词页面中显示翻译行</p>
          </div>
          <Switch v-model="lyricStore.wantTranslation" />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">显示音译</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">有音译时在歌词页面中显示音译行</p>
          </div>
          <Switch v-model="lyricStore.wantRomanization" />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">字体大小</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">调整歌词页面的文字大小</p>
          </div>
          <Slider
            class="w-28 sm:w-48 flex-shrink-0"
            :model-value="lyricStore.fontScale"
            :min="0.7"
            :max="1.4"
            :step="0.1"
            show-value
            :format-value="() => lyricFontSizeLabel"
            @update:model-value="lyricStore.updateFontScale($event)"
            @value-commit="lyricStore.updateFontScale($event)"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">歌手写真背景</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">
              优先使用歌手写真作为背景
            </p>
          </div>
          <Switch v-model="settingStore.lyricArtistBackdrop" />
        </div>
      </div>
    </section>

    <section v-if="isGeckoView" class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconDatabase" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">缓存管理</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">缓存大小限制</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">
              超出限制后自动删除最久未播放的缓存（单位：MB）
            </p>
          </div>
          <InputNumber
            class="w-[110px] sm:w-[140px]"
            :model-value="settingStore.cacheSizeLimitMb"
            :min="100"
            :max="10240"
            :step="100"
            @update:model-value="handleCacheSizeChange"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">当前缓存用量</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">
              {{ cacheUsageText }}
            </p>
          </div>
          <Button
            variant="outline"
            size="xs"
            class="settings-button whitespace-nowrap"
            @click="handleClearCache"
          >清除缓存</Button>
        </div>
      </div>
    </section>

    <section v-if="isGeckoView" class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconPlayerPlay" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">桌面歌词</h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">开启桌面歌词</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">在其他应用上层显示悬浮歌词窗口</p>
          </div>
          <Switch
            :model-value="androidLyricEnabled"
            @update:model-value="handleAndroidLyricToggle($event)"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">歌词行数</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">选择显示单行或双行歌词</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="androidLyricDoubleLine ? 'double' : 'single'"
            :options="[
              { label: '单行歌词', value: 'single' },
              { label: '双行歌词', value: 'double' },
            ]"
            @update:model-value="
              androidLyricDoubleLine = $event === 'double';
              handleAndroidLyricSettingChange();
            "
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">字体大小</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">调整桌面歌词的文字大小</p>
          </div>
          <Slider
            class="w-28 sm:w-48 flex-shrink-0"
            :model-value="androidLyricFontSize"
            :min="5"
            :max="36"
            :step="1"
            show-value
            :value-suffix="'sp'"
            @update:model-value="androidLyricFontSize = $event"
            @value-commit="
              androidLyricFontSize = $event;
              handleAndroidLyricSettingChange();
            "
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">歌词条宽度</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">调整桌面歌词条的水平宽度</p>
          </div>
          <Slider
            class="w-28 sm:w-48 flex-shrink-0"
            :model-value="androidLyricWidthPercent"
            :min="1"
            :max="100"
            :step="5"
            show-value
            :value-suffix="'%'"
            @update:model-value="androidLyricWidthPercent = $event"
            @value-commit="handleAndroidLyricSettingChange()"
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">文字描边</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">为歌词添加黑色描边，背景复杂时更清晰</p>
          </div>
          <Switch
            :model-value="androidLyricStrokeEnabled"
            @update:model-value="
              androidLyricStrokeEnabled = $event;
              handleAndroidLyricSettingChange();
            "
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">对齐方式</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">设置歌词文字的水平对齐方向</p>
          </div>
          <Select
            class="w-[110px] sm:w-[180px]"
            :model-value="androidLyricAlignment"
            :options="[
              { label: '左对齐', value: 'left' },
              { label: '居中', value: 'center' },
              { label: '右对齐', value: 'right' },
            ]"
            @update:model-value="
              androidLyricAlignment = String($event);
              handleAndroidLyricSettingChange();
            "
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">锁定歌词</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">
              锁定后背景变透明且不可拖动
            </p>
          </div>
          <Switch
            :model-value="androidLyricLocked"
            @update:model-value="
              androidLyricLocked = $event;
              handleAndroidLyricSettingChange();
            "
          />
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item items-start">
          <div class="space-y-2 w-full flex-1 min-w-0 pr-2 sm:pr-4">
            <p class="text-[13px] font-semibold text-text-secondary">浅色主题颜色</p>
            <div class="flex gap-2 flex-wrap">
              <button
                v-for="c in androidLyricLightColors"
                :key="'light-' + c.value"
                type="button"
                class="android-lyric-color-swatch"
                :class="{ 'is-active': androidLyricLightColorIndex === c.value }"
                :style="{ backgroundColor: c.hex, border: c.hex === '#FFFFFF' ? '1px solid #ccc' : 'none' }"
                :title="c.label"
                @click="
                  androidLyricLightColorIndex = c.value;
                  handleAndroidLyricSettingChange();
                "
              ></button>
            </div>
          </div>
        </div>
        <div class="settings-item items-start">
          <div class="space-y-2 w-full flex-1 min-w-0 pr-2 sm:pr-4">
            <p class="text-[13px] font-semibold text-text-secondary">深色主题颜色</p>
            <div class="flex gap-2 flex-wrap">
              <button
                v-for="c in androidLyricDarkColors"
                :key="'dark-' + c.value"
                type="button"
                class="android-lyric-color-swatch"
                :class="{ 'is-active': androidLyricDarkColorIndex === c.value }"
                :style="{ backgroundColor: c.hex, border: c.hex === '#000000' ? '1px solid #666' : 'none' }"
                :title="c.label"
                @click="
                  androidLyricDarkColorIndex = c.value;
                  handleAndroidLyricSettingChange();
                "
              ></button>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="space-y-4 sm:space-y-6">
      <div class="flex items-center gap-3">
        <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Icon :icon="iconInfo" width="18" height="18" />
        </div>
        <h2 class="text-lg font-bold">
          {{ isGeckoView ? '关于 易格音乐' : '关于 易格音乐' }}
        </h2>
      </div>
      <div class="settings-card">
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">当前版本</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">{{ aboutVersionText }}</p>
          </div>
          <div class="flex items-center gap-2">
            <Button
              variant="ghost"
              size="xs"
              class="text-text-secondary text-sm font-semibold whitespace-nowrap"
              :disabled="isCheckingUpdate"
              @click="checkForUpdates"
            >
              {{ isCheckingUpdate ? '检查中...' : '检查更新' }}
            </Button>
            <Button
              v-if="!isGeckoView"
              variant="ghost"
              size="xs"
              class="text-text-secondary text-sm font-semibold whitespace-nowrap"
              @click="handleShowChangelog"
              >更新日志</Button
            >
          </div>
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">原项目地址</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">EchoMusic</p>
          </div>
          <Button
            variant="ghost"
            size="xs"
            class="text-text-secondary h-10 w-10 min-w-0 p-0 flex-shrink-0"
            @click="handleOpenExternalUrl('https://github.com/hoowhoami/EchoMusic')"
          >
            <Icon :icon="iconExternalLink" width="20" height="20" />
          </Button>
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">此项目地址</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">E-cells-Music</p>
          </div>
          <Button
            variant="ghost"
            size="xs"
            class="text-text-secondary h-10 w-10 min-w-0 p-0 flex-shrink-0"
            @click="handleOpenExternalUrl('https://github.com/e-cells/E-cells-Music')"
          >
            <Icon :icon="iconExternalLink" width="20" height="20" />
          </Button>
        </div>
        <div class="settings-divider"></div>
        <div class="settings-item">
          <div class="space-y-1 flex-1 min-w-0 pr-2 sm:pr-4">
            <h3 class="font-semibold text-[15px] sm:text-base truncate">WebView 内核</h3>
            <p class="text-[13px] sm:text-sm text-text-secondary leading-relaxed">{{ webviewEngineInfo }}</p>
          </div>
        </div>
      </div>
    </section>

    <Dialog
      v-model:open="showConfirmClear"
      title="清除应用数据"
      description="此操作将移除所有持久化设置与缓存，无法撤销。"
    >
      <template #footer>
        <Button class="settings-button" variant="outline" size="sm" @click="showConfirmClear = false">取消</Button>
        <Button class="settings-button danger" variant="danger" size="sm" @click="settingStore.clearAppData(); showConfirmClear = false;">确认清除</Button>
      </template>
    </Dialog>
    
    <Dialog v-model:open="showChangelog" :title="`更新日志`" showClose noScroll :content-style="{ width: '520px' }">
      <Scrollbar class="settings-update-changelog" :content-props="{ class: 'px-4 py-3' }">
        <div class="changelog-content" v-html="changelogHtml"></div>
      </Scrollbar>
      <template #footer>
        <Button variant="ghost" size="sm" @click="showChangelog = false">关闭</Button>
      </template>
    </Dialog>

    <Dialog v-model:open="showUpdateDialog" title="发现新版本" showClose noScroll :content-style="{ width: '420px' }">
      <div class="px-4 py-3 space-y-4">
        <p class="text-[14px] text-text-main">
          检测到新版本 <span class="font-bold text-primary">{{ latestVersionInfo.version }}</span>，当前版本为 {{ currentAppVersion }}。
        </p>
        <div class="text-[13px] text-text-secondary bg-black/5 dark:bg-white/5 p-3 rounded-lg max-h-[200px] overflow-y-auto whitespace-pre-wrap">
          {{ latestVersionInfo.releaseNotes }}
        </div>
        <div v-if="isGeckoView && latestVersionInfo.apkDownloadUrl && updateDownloadStatus !== 'idle'" class="space-y-2">
          <div v-if="updateDownloadStatus === 'downloading'" class="flex items-center gap-2">
            <span class="text-xs text-text-secondary shrink-0">{{ updateDownloadPercent }}%</span>
            <div class="flex-1 h-1.5 rounded-full bg-black/5 dark:bg-white/10 overflow-hidden">
              <div class="h-full rounded-full bg-primary transition-all duration-300"
                   :style="{ width: `${updateDownloadPercent}%` }"></div>
            </div>
          </div>
          <p v-else-if="updateDownloadStatus === 'error'" class="text-xs text-red-500">
            下载失败：{{ updateDownloadError }}
          </p>
          <p v-else-if="updateDownloadStatus === 'downloaded'" class="text-xs text-green-500">
            下载完成，点击「立即安装」安装新版本
          </p>
        </div>
      </div>
      <template #footer>
        <Button class="settings-button" variant="outline" size="sm" @click="showUpdateDialog = false">稍后更新</Button>
        <Button v-if="isGeckoView && latestVersionInfo.apkDownloadUrl && updateDownloadStatus === 'downloaded'"
                class="settings-button" style="background-color: var(--color-primary); color: #fff;"
                size="sm" @click="handleUpdateInstall">立即安装</Button>
        <Button v-else-if="isGeckoView && latestVersionInfo.apkDownloadUrl && updateDownloadStatus === 'downloading'"
                class="settings-button" variant="secondary" size="sm" disabled>下载中...</Button>
        <Button v-else-if="isGeckoView && latestVersionInfo.apkDownloadUrl"
                class="settings-button" style="background-color: var(--color-primary); color: #fff;"
                size="sm" @click="handleUpdateDownload">立即更新</Button>
        <Button v-else
                class="settings-button" style="background-color: var(--color-primary); color: #fff;"
                size="sm" @click="goToReleasePage">前往下载</Button>
      </template>
    </Dialog>

    <ColorPickerDialog
      :open="lyricColorPicker.isOpen.value"
      :title="lyricColorPicker.activeTitle.value"
      :value="lyricColorPicker.activeValue.value"
      :presets="lyricColorPicker.presets"
      @update:open="(open) => !open && lyricColorPicker.close()"
      @confirm="lyricColorPicker.apply"
    />
    <ColorPickerDialog
      :open="showAccentPicker"
      title="选择主题色"
      :value="themeStore.customColor"
      :presets="accentPresetValues"
      @update:open="(open) => (showAccentPicker = open)"
      @confirm="(color: string) => themeStore.setCustomColor(color)"
    />
    <DisclaimerDialog v-model:open="showDisclaimer" />
  </div>
</template>

<style scoped>
@reference "@/style.css";

.settings-view {
  animation: fade-in 0.6s cubic-bezier(0.4, 0, 0.2, 1);
}

.settings-card {
  @apply bg-bg-sidebar rounded-xl sm:rounded-2xl p-4 sm:p-6 space-y-4 sm:space-y-6 transition-colors duration-300 border border-border-light/40 overflow-visible;
}

.settings-item {
  @apply flex items-center justify-between gap-3 sm:gap-6;
}

.settings-divider {
  @apply h-px bg-border-light/40;
}

.settings-select {
  @apply bg-bg-main text-text-main border border-border-light rounded-lg px-3 py-1.5 text-sm font-semibold focus:outline-none min-w-[120px] sm:min-w-[160px];
}

.settings-text-input {
  width: 100%;
  max-width: 320px;
  height: 42px;
  padding: 0 14px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--color-border-light) 92%, transparent);
  background: color-mix(in srgb, var(--color-text-main) 4%, transparent);
  color: var(--color-text-main);
  font-size: 13px;
  font-weight: 600;
}

.settings-text-input:focus-visible {
  outline: none;
  box-shadow: none;
  border-color: color-mix(in srgb, var(--color-primary) 35%, var(--color-border-light));
}

.settings-color-input {
  width: 34px;
  height: 28px;
  padding: 0;
  border: 1px solid color-mix(in srgb, var(--color-border-light) 92%, transparent);
  border-radius: 8px;
  background: transparent;
}

.dark .settings-number-input {
  color-scheme: dark;
}

.settings-number-input:focus-visible {
  outline: none;
  box-shadow: none;
  border-color: color-mix(in srgb, var(--color-primary) 35%, var(--color-border-light));
}

.settings-button {
  @apply px-3 sm:px-4 py-1.5 rounded-lg bg-primary/10 text-primary text-[12px] font-semibold hover:bg-primary/20 transition-colors;
}

.settings-button.danger {
  @apply bg-red-500/10 text-red-500 hover:bg-red-500/20;
}

.settings-color-swatch {
  width: 42px;
  height: 28px;
  border: 1px solid rgba(0, 0, 0, 0.08);
  border-radius: 999px;
  cursor: pointer;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.26);
}

.dark .settings-color-swatch {
  border-color: rgba(255, 255, 255, 0.12);
}

.accent-preset-swatch {
  width: 28px;
  height: 28px;
  border-radius: 999px;
  border: 2px solid transparent;
  cursor: pointer;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.26);
  transition: transform 0.15s ease, border-color 0.15s ease;
}

.accent-preset-swatch:hover {
  transform: scale(1.08);
}

.accent-preset-swatch.is-active {
  border-color: var(--color-text-main);
  transform: scale(1.08);
}

.android-lyric-color-swatch {
  width: 28px;
  height: 28px;
  border-radius: 999px;
  border: 2px solid transparent;
  cursor: pointer;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.26);
  transition: transform 0.15s ease, border-color 0.15s ease;
}

.android-lyric-color-swatch:hover {
  transform: scale(1.08);
}

.android-lyric-color-swatch.is-active {
  border-color: var(--color-primary);
  transform: scale(1.08);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-primary) 40%, transparent);
}

@keyframes fade-in {
  from { opacity: 0; transform: translateY(10px); }
  to { opacity: 1; transform: translateY(0); }
}
</style>