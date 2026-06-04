<script setup lang="ts">
defineOptions({ name: 'radio' });
import { computed, onMounted, ref } from 'vue';
import { getRadioClasses, getRadioRecommend, getRadioSongs } from '@/api/radio';
import { mapRadioMeta, mapRadioSong } from '@/utils/mappers';
import type { RadioMeta } from '@/models/radio';
import type { Song } from '@/models/song';
import SliverHeader from '@/components/music/DetailPageSliverHeader.vue';
import RadioCard from '@/components/music/RadioCard.vue';
import CustomTabBar from '@/components/ui/CustomTabBar.vue';
import Button from '@/components/ui/Button.vue';
import { usePlaylistStore } from '@/stores/playlist';
import { usePlayerStore } from '@/stores/player';
import { useSettingStore } from '@/stores/setting';
import { useToastStore } from '@/stores/toast';
import { replaceQueueAndPlay } from '@/utils/playback';
import { isGeckoView } from '@/utils/nativeBridge';
import { iconPlay, iconDeviceSpeaker } from '@/icons';

const playlistStore = usePlaylistStore();
const playerStore = usePlayerStore();
const settingStore = useSettingStore();
const toastStore = useToastStore();

const isPortrait = isGeckoView;

const loadingRecommend = ref(true);
const loadingClasses = ref(true);
const recommendedRadios = ref<RadioMeta[]>([]);
const currentSection = ref<'recommend' | 'all'>('recommend');
const activeClassTab = ref(0);

// ---- 全部电台分类数据 ----

/** 推荐API中的原始数据（保留 heat / description） */
interface RecommendRawItem {
  fmid: number;
  heat: number;
  description: string;
  classname: string;
  classid: number;
}

const recommendRawMap = ref<Map<number, RecommendRawItem>>(new Map());

/** 一级分类 Tab：classname → classid 映射 */
interface ClassTab {
  classname: string;
  classid: number;
  radios: RadioMeta[];
}

const classTabs = ref<ClassTab[]>([]);

// 加载推荐电台
const loadRecommend = async () => {
  loadingRecommend.value = true;
  try {
    const res = await getRadioRecommend();
    const list = Array.isArray(res?.data) ? res.data : [];
    recommendedRadios.value = list.map((item: unknown) => mapRadioMeta(item));

    // 构建原始数据 map（用于补充 heat / description）
    const rawMap = new Map<number, RecommendRawItem>();
    for (const item of list) {
      const rec = item as Record<string, unknown>;
      const fmid = Number(rec.fmid) || 0;
      if (fmid) {
        rawMap.set(fmid, {
          fmid,
          heat: Number(rec.heat) || 0,
          description: String(rec.description || ''),
          classname: String(rec.classname || ''),
          classid: Number(rec.classid) || 0,
        });
      }
    }
    recommendRawMap.value = rawMap;
  } catch {
    toastStore.loadFailed('推荐电台');
  } finally {
    loadingRecommend.value = false;
  }
};

// 加载全部分类电台
const loadClasses = async () => {
  loadingClasses.value = true;
  try {
    const res = await getRadioClasses();
    const classList = res?.data?.class_list;
    if (!Array.isArray(classList)) {
      classTabs.value = [];
      return;
    }

    // 1) 从推荐数据提取 classname → classid 映射（去重，保持顺序）
    const classnameOrder: string[] = [];
    const classnameToClassid = new Map<string, number>();
    for (const [, raw] of recommendRawMap.value) {
      const cn = raw.classname;
      if (cn && !classnameToClassid.has(cn)) {
        classnameOrder.push(cn);
        classnameToClassid.set(cn, raw.classid);
      }
    }

    // 2) 按 classid 索引 class_list 中的 fmlist
    const classidToFmlist = new Map<number, unknown[]>();
    for (const cls of classList) {
      const c = cls as Record<string, unknown>;
      const cid = Number(c.classid) || 0;
      const fmlist = Array.isArray(c.fmlist) ? c.fmlist : [];
      classidToFmlist.set(cid, fmlist);
    }

    // 3) 构建分类 Tab
    const tabs: ClassTab[] = [];
    for (const cn of classnameOrder) {
      const cid = classnameToClassid.get(cn) || 0;
      const fmlist = classidToFmlist.get(cid) || [];

      // 映射为 RadioMeta，并用推荐数据补充 heat / description
      const radios = fmlist.map((fm: unknown) => {
        const meta = mapRadioMeta(fm);
        const raw = recommendRawMap.value.get(meta.fmid);
        if (raw) {
          return {
            ...meta,
            description: meta.description || raw.description,
            heat: meta.heat ?? raw.heat,
            classname: cn,
            classid: cid,
          } as RadioMeta;
        }
        return { ...meta, classname: cn, classid: cid } as RadioMeta;
      });

      // 按 heat 降序排列
      radios.sort((a, b) => (b.heat ?? 0) - (a.heat ?? 0));

      tabs.push({ classname: cn, classid: cid, radios });
    }

    classTabs.value = tabs;
  } catch {
    toastStore.loadFailed('电台分类');
  } finally {
    loadingClasses.value = false;
  }
};

// 当前选中的分类 Tab
const activeClassTabItem = computed(() => {
  if (classTabs.value.length === 0) return null;
  const idx = Math.min(activeClassTab.value, classTabs.value.length - 1);
  return classTabs.value[idx];
});

const activeClassRadios = computed(() => activeClassTabItem.value?.radios ?? []);

const classTabNames = computed(() => classTabs.value.map((t) => t.classname));

// 播放全部（当前分类或推荐）
const handlePlayAll = async () => {
  const radios =
    currentSection.value === 'recommend'
      ? recommendedRadios.value.slice(0, 6)
      : activeClassRadios.value.slice(0, 6);
  if (radios.length === 0) return;

  try {
    const seenIds = new Set<string>();
    const allSongs: Song[] = [];

    // 所有电台同时请求（每个电台加载 2 页），用 Promise.allSettled 容错
    const results = await Promise.allSettled(
      radios.flatMap((radio) => [
        getRadioSongs(radio.fmid, 0),
        getRadioSongs(radio.fmid, 20),
      ]),
    );

    for (const result of results) {
      if (result.status !== 'fulfilled') continue;
      const payload = Array.isArray(result.value?.data) ? result.value.data : [];
      for (const item of payload) {
        const songsRaw = Array.isArray(item?.songs) ? item.songs : [];
        for (const s of songsRaw) {
          const song = mapRadioSong(s);
          const key = String(song.id);
          if (!seenIds.has(key)) {
            seenIds.add(key);
            allSongs.push(song);
          }
        }
      }
    }

    if (allSongs.length > 0) {
      await replaceQueueAndPlay(playlistStore, playerStore, allSongs, 0, undefined, {
        queueId: 'queue:radio:all',
        title: '电台',
        subtitle: '随机播放',
        type: 'radio',
        dynamic: false,
      });
    }
  } catch {
    toastStore.actionFailed('播放');
  }
};

// SVG 封面
const radioCoverSvg = computed(() => {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">
      <defs>
        <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#FF6B35" />
          <stop offset="100%" stop-color="#F7931E" />
        </linearGradient>
      </defs>
      <rect width="400" height="400" rx="60" fill="url(#g)" />
      <text x="50%" y="55%" text-anchor="middle" fill="#FFFFFF" font-size="140" font-weight="700" font-family="SF Pro Display, PingFang SC, Arial">
        FM
      </text>
    </svg>
  `;
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
});

onMounted(() => {
  // 先加载推荐数据（获取 classname→classid 映射），再加载分类
  void loadRecommend().then(() => void loadClasses());
});
</script>

<template>
  <div class="radio-view bg-bg-main min-h-full">

    <!-- ═══ 横屏模式 ═══ -->
    <template v-if="!isPortrait">
      <div v-if="loadingRecommend && loadingClasses" class="flex items-center justify-center py-24">
        <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
      </div>

      <template v-else>
        <SliverHeader
          typeLabel="RADIO"
          title="音乐电台"
          :coverUrl="radioCoverSvg"
          :hasDetails="true"
          :expandedHeight="176"
          :collapsedHeight="56"
        >
          <template #details>
            <div class="flex flex-col gap-2">
              <div class="text-[13px] font-semibold text-text-secondary">发现好声音，随心听</div>
            </div>
          </template>
        </SliverHeader>

        <!-- 栏目切换 -->
        <div class="px-6 mt-4">
          <div class="flex items-center gap-3.5 select-none mb-4">
            <span
              :class="['section-tab-title', currentSection === 'recommend' ? 'is-active' : '']"
              @click="currentSection = 'recommend'"
            >推荐电台</span>
            <span class="text-text-secondary/15 font-light text-[15px] pointer-events-none">|</span>
            <span
              :class="['section-tab-title', currentSection === 'all' ? 'is-active' : '']"
              @click="currentSection = 'all'"
            >全部电台</span>
          </div>
        </div>

        <!-- 推荐电台网格 -->
        <div v-if="currentSection === 'recommend'" class="px-6 pb-12">
          <div v-if="loadingRecommend" class="flex items-center justify-center py-20">
            <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          </div>
          <div v-else class="radio-grid">
            <RadioCard
              v-for="radio in recommendedRadios"
              :key="radio.fmid"
              :fmid="radio.fmid"
              :name="radio.name"
              :coverUrl="radio.coverUrl"
              :description="radio.description"
              layout="grid"
            />
          </div>
        </div>

        <!-- 全部电台 -->
        <div v-if="currentSection === 'all'" class="px-6 pb-12">
          <div v-if="loadingClasses" class="flex items-center justify-center py-20">
            <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          </div>
          <template v-else>
            <!-- 一级分类 Tab（classname） -->
            <div v-if="classTabs.length > 0" class="pl-[10px] mb-4">
              <CustomTabBar
                :tabs="classTabNames"
                :model-value="activeClassTab"
                @update:model-value="activeClassTab = $event"
              />
            </div>
            <!-- 当前分类下的电台（按 heat 降序） -->
            <div class="radio-grid">
              <RadioCard
                v-for="radio in activeClassRadios"
                :key="radio.fmid"
                :fmid="radio.fmid"
                :name="radio.name"
                :coverUrl="radio.coverUrl"
                :description="radio.description"
                layout="grid"
              />
            </div>
          </template>
        </div>
      </template>
    </template>

    <!-- ═══ 竖屏模式 ═══ -->
    <template v-else>
      <div v-if="loadingRecommend && loadingClasses" class="flex items-center justify-center py-24">
        <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
      </div>

      <template v-else>
        <!-- 紧凑头部 -->
        <div class="px-4 pt-3">
          <div class="flex items-center gap-3">
            <div class="w-14 h-14 rounded-[18px] gradient-radio-text flex items-center justify-center shrink-0 font-extrabold text-[13px] text-white shadow-sm leading-none">
              FM
            </div>
            <div class="min-w-0 flex-1">
              <div class="text-[16px] font-extrabold text-text-main">音乐电台</div>
              <div class="flex items-center gap-3 mt-0.5 text-[11px] text-text-secondary/80">
                <span class="inline-flex items-center gap-1">
                  <Icon :icon="iconDeviceSpeaker" width="11" height="11" />
                  发现好声音
                </span>
              </div>
            </div>
          </div>

          <div class="flex items-center gap-1.5 mt-2.5">
            <span class="px-2 py-0.5 rounded text-[10px] font-bold tracking-[0.8px] uppercase text-primary bg-primary/10 border border-primary/15">RADIO</span>
          </div>
        </div>

        <!-- 栏目切换 -->
        <div class="px-4 mt-4">
          <div class="flex items-center gap-3.5 select-none mb-3">
            <span
              :class="['section-tab-title', currentSection === 'recommend' ? 'is-active' : '']"
              @click="currentSection = 'recommend'"
            >推荐电台</span>
            <span class="text-text-secondary/15 font-light text-[15px] pointer-events-none">|</span>
            <span
              :class="['section-tab-title', currentSection === 'all' ? 'is-active' : '']"
              @click="currentSection = 'all'"
            >全部电台</span>
          </div>
        </div>

        <!-- 推荐电台网格 -->
        <div v-if="currentSection === 'recommend'" class="px-4 pb-12">
          <div v-if="loadingRecommend" class="flex items-center justify-center py-20">
            <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          </div>
          <div v-else class="radio-grid-mobile">
            <RadioCard
              v-for="radio in recommendedRadios"
              :key="radio.fmid"
              :fmid="radio.fmid"
              :name="radio.name"
              :coverUrl="radio.coverUrl"
              :description="radio.description"
              layout="grid"
            />
          </div>
        </div>

        <!-- 全部电台 -->
        <div v-if="currentSection === 'all'" class="pb-12">
          <div v-if="loadingClasses" class="flex items-center justify-center py-20">
            <div class="w-8 h-8 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          </div>
          <template v-else>
            <!-- 一级分类横向滚动（classname） -->
            <div class="class-scroll-row px-4 mb-3">
              <div class="flex gap-2 overflow-x-auto pb-2 scrollbar-none">
                <button
                  v-for="(tab, idx) in classTabs"
                  :key="tab.classid"
                  :class="[
                    'class-chip shrink-0 px-3 py-1.5 rounded-lg text-[12px] font-semibold transition-all',
                    idx === activeClassTab
                      ? 'bg-primary/15 text-primary border border-primary/25'
                      : 'bg-black/[0.04] dark:bg-white/[0.06] text-text-main/70 border border-transparent',
                  ]"
                  @click="activeClassTab = idx"
                >
                  {{ tab.classname }}
                </button>
              </div>
            </div>
            <!-- 当前分类下的电台网格（按 heat 降序） -->
            <div class="px-4">
              <div class="radio-grid-mobile">
                <RadioCard
                  v-for="radio in activeClassRadios"
                  :key="radio.fmid"
                  :fmid="radio.fmid"
                  :name="radio.name"
                  :coverUrl="radio.coverUrl"
                  :description="radio.description"
                  layout="grid"
                />
              </div>
            </div>
          </template>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.radio-view {
  animation: fade-in 0.6s cubic-bezier(0.4, 0, 0.2, 1);
}

.gradient-radio-text {
  background: linear-gradient(135deg, #FF6B35, color-mix(in srgb, #F7931E 60%, #000));
}

/* 播放按钮 */
.action-btn-play {
  @apply flex items-center gap-1.5 px-4 h-10 rounded-full text-[13px] font-bold transition-all active:scale-95 select-none;
  @apply bg-primary text-white hover:bg-primary-hover;
  box-shadow: 0 4px 12px color-mix(in srgb, var(--color-primary) 35%, transparent);
}

/* 栏目标题切换 */
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

/* 横屏网格 */
.radio-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 16px;
}

/* 竖屏网格 */
.radio-grid-mobile {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
  gap: 12px;
}

/* 竖屏分类滚动 */
.class-scroll-row {
  -webkit-overflow-scrolling: touch;
}

.scrollbar-none::-webkit-scrollbar {
  display: none;
}

.scrollbar-none {
  -ms-overflow-style: none;
  scrollbar-width: none;
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
