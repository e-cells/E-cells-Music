<script setup lang="ts">
defineOptions({ name: 'home' });
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useUserStore } from '@/stores/user';
import { useSettingStore } from '@/stores/setting';
import { isGeckoView } from '@/utils/nativeBridge';
import { getPlaylistByCategory, getTopIP } from '@/api/playlist';
import PlaylistCard from '@/components/music/PlaylistCard.vue';
import { mapPlaylistMeta } from '@/utils/mappers';
import { extractList } from '@/utils/extractors';
import type { PlaylistMeta } from '@/models/playlist';
import { iconPlay, iconSparkles, iconChevronRight } from '@/icons';
import Button from '@/components/ui/Button.vue';
import UserAgreementDialog from '@/components/app/UserAgreementDialog.vue';

withDefaults(defineProps<{ showHeader?: boolean }>(), { showHeader: true });
const isPortrait = computed(() => {
  if (!isGeckoView) return false;
  if (settingStore.screenOrientation === 'portrait') return true;
  if (settingStore.screenOrientation === 'landscape') return false;
  return window.innerWidth < window.innerHeight;
});

interface RecommendSectionState {
  loading: boolean;
  error: string;
}

interface PlaylistCardProps {
  id: string | number;
  name: string;
  coverUrl: string;
  creator?: string;
  songCount?: number;
}

const router = useRouter();
const userStore = useUserStore();
const settingStore = useSettingStore();
const showUserAgreement = ref(false);

const currentSection = ref<'recommend' | 'topIp'>('recommend');

const todayLabel = computed(() => new Date().getDate().toString());

const greeting = computed(() => {
  const hour = new Date().getHours();
  const base =
    hour < 6
      ? '凌晨好'
      : hour < 9
        ? '早上好'
        : hour < 12
          ? '上午好'
          : hour < 14
            ? '中午好'
            : hour < 18
              ? '下午好'
              : '晚上好';
  const nickname = userStore.info?.nickname;
  return userStore.isLoggedIn && nickname ? `${nickname}, ${base}` : base;
});

const recommendedPlaylists = ref<PlaylistMeta[]>([]);
const topIpPlaylists = ref<PlaylistMeta[]>([]);

const recommendState = ref<RecommendSectionState>({ loading: true, error: '' });
const topIpState = ref<RecommendSectionState>({ loading: true, error: '' });

const extractPlaylistList = (payload: unknown): unknown[] => extractList(payload);
const extractIpList = (payload: unknown): unknown[] => extractList(payload);

const loadRecommendPlaylists = async () => {
  recommendState.value = { loading: true, error: '' };
  try {
    const res = await getPlaylistByCategory('0', 0, 10); 
    recommendedPlaylists.value = extractPlaylistList(res).map((item) => mapPlaylistMeta(item));
  } catch {
    recommendState.value = { loading: false, error: '推荐歌单加载失败' };
    return;
  }
  recommendState.value = { loading: false, error: '' };
};

const loadTopIp = async () => {
  topIpState.value = { loading: true, error: '' };
  try {
    const res = await getTopIP();
    topIpPlaylists.value = extractIpList(res)
      .filter((item) => typeof item === 'object' && item !== null)
      .filter((item) => {
        const record = item as Record<string, unknown>;
        const extra = record.extra as Record<string, unknown> | undefined;
        const globalId = extra?.global_collection_id ?? extra?.global_special_id;
        return record.type === 1 && Boolean(globalId);
      })
      .map((item) => mapPlaylistMeta(item))
      .slice(0, 10); 
  } catch {
    topIpState.value = { loading: false, error: '编辑精选加载失败' };
    return;
  }
  topIpState.value = { loading: false, error: '' };
};

const openRecommend = () => {
  router.push({ name: 'recommend-songs' });
};

const openRanking = () => {
  router.push({ name: 'ranking' });
};

const resolvePlaylistRouteId = (entry: PlaylistMeta) =>
  entry.listCreateGid || entry.globalCollectionId || entry.listCreateListid || entry.id;

const getPlaylistCardProps = (entry: PlaylistMeta): PlaylistCardProps => {
  return {
    id: resolvePlaylistRouteId(entry),
    name: entry.name,
    coverUrl: entry.pic,
    creator: entry.nickname,
    songCount: entry.count,
  };
};

const recommendedPlaylistCards = computed(() =>
  recommendedPlaylists.value.map((entry) => getPlaylistCardProps(entry)),
);

const topIpPlaylistCards = computed(() =>
  topIpPlaylists.value.map((entry) => getPlaylistCardProps(entry)),
);

onMounted(() => {
  showUserAgreement.value = !settingStore.userAgreementAccepted;
  if (userStore.isLoggedIn) {
    void userStore.fetchUserInfoOnce();
  }
  void loadRecommendPlaylists();
  void loadTopIp();
});

const handleAcceptAgreement = () => {
  settingStore.acceptUserAgreement();
};

const handleRejectAgreement = () => {
  window.electron?.ipcRenderer?.send('quit-app', null);
};
</script>

<template>
  <div :class="['home-view', isPortrait ? 'px-0 pt-0 pb-8' : 'px-4 md:px-10 pt-4 pb-10']">
    
    <div v-if="showHeader" :class="['home-header relative', isPortrait ? 'px-5 mb-3' : 'mb-8']">
      <div class="relative z-10 pt-0">
        <div class="text-[26px] font-bold tracking-tight text-text-main leading-tight">{{ greeting }}</div>
        <div class="text-[13px] font-medium text-text-secondary/70 mt-0.5">今天想听点什么？</div>
      </div>
    </div>

    <div :class="['home-feature-row', isPortrait ? 'px-5' : '']">
      <Button variant="unstyled" size="none" class="home-feature-card group" @click="openRecommend">
        <div class="feature-icon gradient-primary group-active:scale-95 transition-transform">
          {{ todayLabel }}
        </div>
        <div class="feature-meta">
          <div class="feature-title">每日推荐</div>
          <div class="feature-sub">为你量身定制</div>
        </div>
      </Button>
      <Button variant="unstyled" size="none" class="home-feature-card group" @click="openRanking">
        <div class="feature-icon gradient-secondary group-active:scale-95 transition-transform">
          <Icon :icon="iconSparkles" width="28" height="28" class="landscape-icon" />
        </div>
        <div class="feature-meta">
          <div class="feature-title">排行榜</div>
          <div class="feature-sub">发现流行热歌</div>
        </div>
      </Button>
    </div>

    <section :class="['home-section mt-6 md:mt-10', isPortrait ? 'px-5' : '']">
      <div class="section-header">
        <div class="flex items-center gap-3.5 select-none">
          <span 
            :class="['section-tab-title', currentSection === 'recommend' ? 'is-active' : '']"
            @click="currentSection = 'recommend'"
          >推荐歌单</span>
          
          <span class="text-text-secondary/15 font-light text-[15px] pointer-events-none">|</span>
          
          <span 
            :class="['section-tab-title', currentSection === 'topIp' ? 'is-active' : '']"
            @click="currentSection = 'topIp'"
          >编辑精选</span>
        </div>
        
        <button class="section-more text-text-secondary/40 hover:text-primary transition-colors flex items-center">
          <Icon :icon="iconChevronRight" width="18" height="18" />
        </button>
      </div>

      <div class="mt-3 md:mt-4">
        <div v-if="currentSection === 'recommend'" class="animate-list-slide">
          <div v-if="recommendState.loading" class="section-placeholder">加载中...</div>
          <div v-else-if="recommendState.error" class="section-placeholder">{{ recommendState.error }}</div>
          <div v-else class="flex flex-col gap-1">
            <PlaylistCard
              v-for="item in recommendedPlaylistCards"
              :key="item.id"
              v-bind="item"
              layout="list"
              class="w-full"
            />
          </div>
        </div>

        <div v-if="currentSection === 'topIp'" class="animate-list-slide">
          <div v-if="topIpState.loading" class="section-placeholder">加载中...</div>
          <div v-else-if="topIpState.error" class="section-placeholder">{{ topIpState.error }}</div>
          <div v-else class="flex flex-col gap-1">
            <PlaylistCard
              v-for="item in topIpPlaylistCards"
              :key="item.id"
              v-bind="item"
              layout="list"
              class="w-full"
            />
          </div>
        </div>
      </div>
    </section>
  </div>

  <UserAgreementDialog
    v-model:open="showUserAgreement"
    @accept="handleAcceptAgreement"
    @reject="handleRejectAgreement"
  />
</template>

<style scoped>
@reference "@/style.css";

.home-view {
  animation: fade-in 0.6s cubic-bezier(0.4, 0, 0.2, 1);
  min-height: 100vh;
}

.home-header {
  margin-bottom: 16px;
}

/* 顶部金刚区双卡片基础样式 (适配移动端竖屏) */
.home-feature-row {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}

.home-feature-card {
  display: flex;
  align-items: center;
  gap: 12px;
  height: 80px;
  padding: 0 16px;
  border-radius: 20px;
  background: color-mix(in srgb, var(--color-text-main) 3%, transparent);
  border: 1px solid color-mix(in srgb, var(--color-text-main) 5%, transparent);
  box-shadow: inset 0 2px 4px color-mix(in srgb, #fff 10%, transparent);
  transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
  -webkit-tap-highlight-color: transparent;
}

.dark .home-feature-card {
  background: rgba(255, 255, 255, 0.04);
  border-color: rgba(255, 255, 255, 0.07);
  box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.04);
}

.home-feature-card:active {
  transform: scale(0.96);
  background: color-mix(in srgb, var(--color-text-main) 6%, transparent);
}

.feature-icon {
  width: 48px;
  height: 48px;
  border-radius: 14px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-weight: 800;
  font-size: 18px;
  box-shadow: 0 8px 16px color-mix(in srgb, currentColor 30%, transparent);
}

.landscape-icon {
  width: 20px;
  height: 20px;
}

.gradient-primary {
  background: linear-gradient(135deg, var(--color-primary), color-mix(in srgb, var(--color-primary) 60%, #000));
}

.gradient-secondary {
  background: linear-gradient(135deg, var(--color-secondary), color-mix(in srgb, var(--color-secondary) 60%, #000));
}

.feature-meta {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  min-w: 0;
}

.feature-title {
  font-size: 15px;
  font-weight: 700;
  color: var(--color-text-main);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  width: 100%;
  text-align: left; 
}

.feature-sub {
  font-size: 11px;
  font-weight: 600;
  color: color-mix(in srgb, var(--color-text-main) 45%, transparent);
  margin-top: 2px;
  text-align: left; 
}

/* =========================================
   桌面端横屏优化：卡片更厚实，间距更大
   ========================================= */
@media (min-width: 768px) {
  .home-feature-row {
    gap: 24px;
  }
  .home-feature-card {
    height: 110px; /* 增加卡片高度，防止拉伸后看起来像一条线 */
    padding: 0 24px;
    border-radius: 24px;
    gap: 20px;
  }
  .feature-icon {
    width: 64px;
    height: 64px;
    border-radius: 20px;
    font-size: 26px; /* 放大今日日期的字体 */
  }
  .landscape-icon {
    width: 28px;
    height: 28px;
  }
  .feature-title {
    font-size: 18px;
  }
  .feature-sub {
    font-size: 13px;
    margin-top: 4px;
  }
}

/* 栏目标题行结构 */
.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 8px;
}

.section-tab-title {
  font-size: 16px;
  font-weight: 600;
  color: color-mix(in srgb, var(--color-text-main) 40%, transparent);
  cursor: pointer;
  transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
  -webkit-tap-highlight-color: transparent;
}

.section-tab-title.is-active {
  font-size: 19px;
  font-weight: 800;
  color: var(--color-text-main);
}

.animate-list-slide {
  animation: list-slide-in 0.4s cubic-bezier(0.16, 1, 0.3, 1) forwards;
}

@keyframes list-slide-in {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.section-placeholder {
  height: 120px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 500;
  color: color-mix(in srgb, var(--color-text-main) 40%, transparent);
}

@keyframes fade-in {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>