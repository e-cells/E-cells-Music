<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useUserStore } from '@/stores/user';
import { usePlaylistStore } from '@/stores/playlist';
import Avatar from '@/components/ui/Avatar.vue';
import Cover from '@/components/ui/Cover.vue';
import { iconHeart, iconPulse, iconCloud, iconClock, iconSettings } from '@/icons';
import type { PlaylistMeta } from '@/models/playlist';

const router = useRouter();
const userStore = useUserStore();
const playlistStore = usePlaylistStore();

const isLoggedIn = computed(() => userStore.isLoggedIn);
const userInfo = computed(() => userStore.info);

const currentUserId = computed(() => userStore.info?.userid);

const createdPlaylists = computed(() => playlistStore.getCreatedPlaylists(currentUserId.value));

const favoritedPlaylists = computed(() =>
  playlistStore.userPlaylists.filter(
    (p) => p.source !== 2 && p.listCreateUserid !== currentUserId.value,
  ),
);

const resolvePlaylistRouteId = (entry: PlaylistMeta) =>
  entry.listCreateGid || entry.globalCollectionId || entry.listCreateListid || entry.id;

// 歌单激活状态 ('created' | 'favorited')
const activePlaylistTab = ref<'created' | 'favorited'>('created');

const libraryItems = [
  { name: '我最喜爱', icon: iconHeart, route: '/main/favorites', color: '#EF4444' },
  { name: '私人 FM', icon: iconPulse, route: '/main/personal-fm', color: '#8B5CF6' },
  { name: '我的云盘', icon: iconCloud, route: '/main/cloud', color: '#3B82F6' },
  { name: '播放历史', icon: iconClock, route: '/main/history', color: '#F59E0B' },
];

const navigateTo = (path: string) => router.push(path);
const goToLogin = () => router.push('/login');
const openPlaylist = (entry: PlaylistMeta) => {
  const id = resolvePlaylistRouteId(entry);
  router.push(`/main/playlist/${id}`);
};

onMounted(() => {
  if (userStore.isLoggedIn && playlistStore.userPlaylists.length === 0) {
    void playlistStore.fetchUserPlaylists();
  }
});
</script>

<template>
  <div class="portrait-my h-full overflow-y-auto pt-safe pb-safe bg-bg-main">
    <div class="px-5 md:px-6">
      
      <div class="my-header pt-2 pb-6">
        <div class="user-card group" @click="isLoggedIn ? navigateTo('/main/profile') : goToLogin()">
          <div class="absolute inset-0 bg-gradient-to-br from-primary/10 to-transparent opacity-60 dark:opacity-20 pointer-events-none"></div>
          
          <div class="user-avatar-wrap relative z-10">
            <Avatar :src="isLoggedIn ? userInfo?.pic : ''" class="w-full h-full object-cover" />
          </div>
          
          <div class="user-meta relative z-10">
            <span class="user-name">{{ isLoggedIn ? userInfo?.nickname : '立即登录' }}</span>
            <span class="user-level">
              {{ isLoggedIn ? `Lv. ${userInfo?.p_grade || 0} 尊享会员` : '登录以同步你的音乐资产' }}
            </span>
          </div>
          
          <button
            type="button"
            class="settings-btn-inline relative z-10"
            @click.stop="navigateTo('/main/settings')"
          >
            <Icon :icon="iconSettings" width="20" height="20" />
          </button>
        </div>
      </div>

      <div class="section mb-8">
        <h2 class="section-title">我的乐库</h2>
        <div class="library-grid">
          <button
            v-for="item in libraryItems"
            :key="item.name"
            type="button"
            class="library-item"
            @click="navigateTo(item.route)"
          >
            <div class="library-icon shadow-sm" :style="{ background: item.color + '15', color: item.color }">
              <Icon :icon="item.icon" width="22" height="22" />
            </div>
            <span class="library-label">{{ item.name }}</span>
          </button>
        </div>
      </div>

      <div v-if="isLoggedIn && (createdPlaylists.length > 0 || favoritedPlaylists.length > 0)" class="section mb-6">
        
        <div class="flex items-center gap-3.5 select-none mb-4 px-1">
          <span 
            :class="['section-tab-title', activePlaylistTab === 'created' ? 'is-active' : '']"
            @click="activePlaylistTab = 'created'"
          >
            创建的歌单
            <span class="tab-count-badge">{{ createdPlaylists.length }}</span>
          </span>
          
          <span class="text-text-secondary/15 font-light text-[15px] pointer-events-none">|</span>
          
          <span 
            :class="['section-tab-title', activePlaylistTab === 'favorited' ? 'is-active' : '']"
            @click="activePlaylistTab = 'favorited'"
          >
            收藏的歌单
            <span class="tab-count-badge">{{ favoritedPlaylists.length }}</span>
          </span>
        </div>
        
        <div class="mt-2">
          <div v-if="activePlaylistTab === 'created'" class="playlist-list animate-list-slide">
            <button
              v-for="pl in createdPlaylists"
              :key="pl.listid || pl.id"
              type="button"
              class="playlist-item"
              @click="openPlaylist(pl)"
            >
              <Cover
                :url="pl.pic"
                :size="120"
                :width="48"
                :height="48"
                :borderRadius="12"
                class="shrink-0 shadow-sm border border-black/5 dark:border-white/5"
              />
              <div class="playlist-info">
                <span class="playlist-name">{{ pl.name }}</span>
                <span class="playlist-count">{{ pl.count ?? 0 }} 首歌曲</span>
              </div>
            </button>
          </div>

          <div v-if="activePlaylistTab === 'favorited'" class="playlist-list animate-list-slide">
            <button
              v-for="pl in favoritedPlaylists"
              :key="pl.listid || pl.id"
              type="button"
              class="playlist-item"
              @click="openPlaylist(pl)"
            >
              <Cover
                :url="pl.pic"
                :size="120"
                :width="48"
                :height="48"
                :borderRadius="12"
                class="shrink-0 shadow-sm border border-black/5 dark:border-white/5"
              />
              <div class="playlist-info">
                <span class="playlist-name">{{ pl.name }}</span>
                <span class="playlist-count">创建者: {{ pl.nickname || 'Unknown' }}</span>
              </div>
            </button>
          </div>
        </div>

      </div>

    </div>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* 裁剪多余的安全区重叠 */
.pt-safe {
  padding-top: 4px;
}
.pb-safe {
  padding-bottom: max(24px, calc(env(safe-area-inset-bottom, 0px) + 80px)); 
}

/* ── VIP 用户信息名片 ── */
.user-card {
  position: relative;
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 20px 20px;
  border-radius: 24px;
  overflow: hidden; /* ✨ 新增这一行：裁剪掉内部背景漏出来的直角 */
  background: var(--color-bg-sidebar);
  box-shadow: 0 12px 32px -12px color-mix(in srgb, var(--color-primary) 15%, transparent);
  border: 1px solid color-mix(in srgb, var(--color-primary) 15%, transparent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1), box-shadow 0.25s ease;
}

.dark .user-card {
  box-shadow: 0 12px 32px -12 rgba(0, 0, 0, 0.4);
  border-color: rgba(255, 255, 255, 0.05);
}

.user-card:active {
  transform: scale(0.96);
  box-shadow: 0 4px 12px -4px color-mix(in srgb, var(--color-primary) 15%, transparent);
}

.user-avatar-wrap {
  width: 56px;
  height: 56px;
  border-radius: 50%;
  overflow: hidden;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--color-primary) 12%, transparent);
  box-shadow: 0 4px 12px color-mix(in srgb, var(--color-primary) 20%, transparent);
}

.user-meta {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.user-name {
  font-size: 18px;
  font-weight: 800;
  color: var(--color-text-main);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  letter-spacing: 0.5px;
}

.user-level {
  font-size: 12px;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  font-weight: 600;
}

.settings-btn-inline {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 40px;
  height: 40px;
  border-radius: 50%;
  background: color-mix(in srgb, var(--color-text-main) 5%, transparent);
  color: color-mix(in srgb, var(--color-text-main) 60%, transparent);
  flex-shrink: 0;
  -webkit-tap-highlight-color: transparent;
  transition: all 0.2s ease;
}

.settings-btn-inline:active {
  background: color-mix(in srgb, var(--color-text-main) 10%, transparent);
  transform: scale(0.9);
}

/* ── 我的乐库 (Bento 磁贴) ── */
.section-title {
  font-size: 18px;
  font-weight: 800;
  color: var(--color-text-main);
  letter-spacing: 0.5px;
  margin-bottom: 14px;
  padding-left: 4px;
}

.library-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}

.library-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px 14px;
  border-radius: 20px;
  background: var(--color-bg-sidebar);
  border: 1px solid color-mix(in srgb, var(--color-border-light) 25%, transparent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}

.dark .library-item {
  background: rgba(255, 255, 255, 0.03);
  border-color: rgba(255, 255, 255, 0.06);
}

.library-item:active {
  transform: scale(0.95);
  background: color-mix(in srgb, var(--color-text-main) 6%, transparent);
}

.library-icon {
  width: 38px;
  height: 38px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.library-label {
  font-size: 14px;
  font-weight: 700;
  color: var(--color-text-main);
  white-space: nowrap;
}

/* ── Tab 标题 ── */
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

.tab-count-badge {
  font-size: 12px;
  font-weight: 500;
  opacity: 0.5;
  margin-left: 2px;
}

/* ── 无界歌单列表流 ── */
.playlist-list {
  display: flex;
  flex-direction: column;
}

.playlist-item {
  display: flex;
  align-items: center;
  gap: 14px;
  width: 100%;
  padding: 8px 4px;
  border-radius: 16px;
  background: transparent;
  border: none;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.2s ease, transform 0.2s ease;
}

.playlist-item:active {
  background: color-mix(in srgb, var(--color-text-main) 5%, transparent);
  transform: scale(0.98);
}

.playlist-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
  text-align: left;
}

.playlist-name {
  font-size: 15px;
  font-weight: 700;
  color: var(--color-text-main);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.playlist-count {
  font-size: 12px;
  font-weight: 500;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* 切换列表补间切入动效 */
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
</style>