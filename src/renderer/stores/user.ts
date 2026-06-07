import { defineStore } from 'pinia';
import {
  claimDayVip,
  getServerNow,
  getUserDetail,
  getUserFollow,
  getUserVipDetail,
  getVipMonthRecord,
  upgradeDayVip,
} from '@/api/user';
import type { User, UserExtendsInfo } from '@/models/user';
import { mapUser } from '@/utils/mappers';
import logger from '@/utils/logger';
import { useToastStore } from '@/stores/toast';

export type UserInfo = User;

interface ApiPayload {
  status?: number;
  data?: unknown;
  [key: string]: unknown;
}

const asApiPayload = (value: unknown): ApiPayload | null => {
  if (!value || typeof value !== 'object') return null;
  return value as ApiPayload;
};

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
};

const mergeExtendsInfo = (
  ...sources: Array<UserExtendsInfo | undefined>
): UserExtendsInfo | undefined => {
  const merged = sources.reduce<UserExtendsInfo>((acc, source) => {
    if (!source) return acc;
    return {
      ...acc,
      ...source,
      detail: isRecord(source.detail)
        ? {
            ...(isRecord(acc.detail) ? acc.detail : {}),
            ...source.detail,
          }
        : acc.detail,
      vip: isRecord(source.vip)
        ? {
            ...(isRecord(acc.vip) ? acc.vip : {}),
            ...source.vip,
          }
        : acc.vip,
    };
  }, {});

  return Object.keys(merged).length > 0 ? merged : undefined;
};

const normalizeUserInfo = (info: UserInfo): UserInfo => {
  const next = { ...info };

  if (
    (typeof next.userid !== 'number' || next.userid <= 0) &&
    typeof next.userId === 'number' &&
    next.userId > 0
  ) {
    next.userid = next.userId;
  }
  if (
    (typeof next.userId !== 'number' || next.userId <= 0) &&
    typeof next.userid === 'number' &&
    next.userid > 0
  ) {
    next.userId = next.userid;
  }

  return next;
};

const buildPatchedUserInfo = (current: UserInfo | null, patch: Partial<UserInfo>): UserInfo => {
  return normalizeUserInfo({
    ...(current ?? { userid: 0, token: '' }),
    ...patch,
  });
};

export const useUserStore = defineStore('user', {
  state: () => ({
    info: null as UserInfo | null,
    isLoggedIn: false,
    hasFetchedUserInfo: false,
    isFetchingUserInfo: false,
    isTvipClaimedToday: false,
    isSvipClaimedToday: false,
    isAutoClaimingVip: false,
    followedArtistIds: new Set<string>(),
    hasFetchedFollowedArtists: false,
  }),
  actions: {
    setUserInfo(info: UserInfo) {
      const nextInfo = normalizeUserInfo(info);
      this.$patch((state) => {
        state.info = nextInfo;
        state.isLoggedIn = !!nextInfo.token;
        if (!nextInfo.token) {
          state.hasFetchedUserInfo = false;
        }
      });
    },
    handleLoginSuccess(data: Record<string, unknown>) {
      this.hasFetchedUserInfo = false;

      const mapped = mapUser(data);
      const detailPayload = isRecord(data.detail)
        ? data.detail
        : isRecord(data.extendsInfo) &&
            isRecord((data.extendsInfo as Record<string, unknown>).detail)
          ? ((data.extendsInfo as Record<string, unknown>).detail as Record<string, unknown>)
          : isRecord(data)
            ? data
            : undefined;

      const vipPayload = isRecord(data.vip)
        ? data.vip
        : isRecord(data.extendsInfo) && isRecord((data.extendsInfo as Record<string, unknown>).vip)
          ? ((data.extendsInfo as Record<string, unknown>).vip as Record<string, unknown>)
          : undefined;

      const mergedExtends = mergeExtendsInfo(
        this.info?.extendsInfo,
        mapped.extendsInfo,
        detailPayload ? { detail: detailPayload } : undefined,
        vipPayload ? { vip: vipPayload } : undefined,
      );

      const nextInfo = buildPatchedUserInfo(this.info, {
        ...mapped,
        ...(mergedExtends
          ? {
              extends: mergedExtends,
              extendsInfo: mergedExtends,
              ...(mergedExtends.detail ? { detail: mergedExtends.detail } : {}),
              ...(mergedExtends.vip ? { vip: mergedExtends.vip } : {}),
            }
          : {}),
      });

      this.setUserInfo(nextInfo);
    },
    async fetchUserInfo() {
      if (!this.isLoggedIn) return;
      try {
        const [detailRes, vipRes] = await Promise.all([getUserDetail(), getUserVipDetail()]);
        const detailPayload = asApiPayload(detailRes);
        const vipPayload = asApiPayload(vipRes);

        if (detailPayload?.status === 1) {
          logger.info('UserStore', 'User detail fetched');
          const payload =
            detailPayload.data && typeof detailPayload.data === 'object'
              ? (detailPayload.data as Record<string, unknown>)
              : detailPayload;
          this.handleLoginSuccess(payload);
        }

        if (vipPayload?.status === 1 && this.info) {
          logger.info('UserStore', 'VIP detail fetched');
          const vipData =
            vipPayload.data && typeof vipPayload.data === 'object'
              ? (vipPayload.data as Record<string, unknown>)
              : undefined;
          const mergedExtends = mergeExtendsInfo(
            this.info.extendsInfo,
            vipData ? { vip: vipData } : undefined,
          );

          this.setUserInfo(
            buildPatchedUserInfo(this.info, {
              ...(vipData ? { vip: vipData } : {}),
              ...(mergedExtends ? { extends: mergedExtends, extendsInfo: mergedExtends } : {}),
            }),
          );
        }
      } catch (e) {
        logger.error('UserStore', 'Fetch user info error:', e);
      }
    },
    async fetchUserInfoOnce() {
      if (!this.isLoggedIn || this.hasFetchedUserInfo || this.isFetchingUserInfo) return;
      this.isFetchingUserInfo = true;
      try {
        await this.fetchUserInfo();
        this.hasFetchedUserInfo = true;
      } finally {
        this.isFetchingUserInfo = false;
      }
    },

    async autoReceiveVipIfNeeded() {
      if (!this.isLoggedIn || this.isAutoClaimingVip) return;
      this.isAutoClaimingVip = true;

      const toast = useToastStore();

      try {
        // 先从服务器查询今日领取状态，避免重复领取
        const { isTvipClaimedToday, isSvipClaimedToday } = await this.checkTodayClaimStatus();

        // 如果畅听和概念会员今日都已领取，直接跳过
        if (isTvipClaimedToday && isSvipClaimedToday) {
          logger.info('UserStore', 'VIP already claimed today (TVIP + SVIP), skipping auto-claim');
          return;
        }

        const today = await this.getServerToday();

        let claimSuccess = false;
        let upgradeSuccess = false;

        // 仅在畅听会员未领取时尝试领取
        if (!isTvipClaimedToday) {
          try {
            const res = await claimDayVip(today) as any;
            claimSuccess = res?.status === 1;
          } catch (e: any) {
            const msg = e?.response?.data?.error_message || e?.message || '';
            toast.warning(msg ? `自动领取失败：${msg}` : '自动领取失败，请稍后重试');
            logger.warn('UserStore', 'VIP claim: claimDayVip failed', e);
          }
        } else {
          // 畅听已领取，视为成功以继续升级流程
          claimSuccess = true;
          logger.info('UserStore', 'TVIP already claimed today, skipping claimDayVip');
        }

        // 仅在畅听已就绪且概念会员未升级时尝试升级
        if (claimSuccess && !isSvipClaimedToday) {
          try {
            const res = await upgradeDayVip() as any;
            upgradeSuccess = res?.status === 1 || res?.error_code === 297002;
          } catch (e) {
            logger.warn('UserStore', 'VIP claim: upgradeDayVip failed', e);
          }
        }

        // 有领取或升级操作时刷新用户信息
        if (!isTvipClaimedToday || (!isSvipClaimedToday && claimSuccess)) {
          try {
            await this.fetchUserInfo();
            this.hasFetchedUserInfo = true;
          } catch (e) {
            logger.warn('UserStore', 'VIP claim: fetchUserInfo failed', e);
          }
        }

        // 更新领取状态
        await this.checkTodayClaimStatus();

        // 仅对本次新领取的项目显示提示
        if (!isTvipClaimedToday && this.isTvipClaimedToday) {
          const expireDate = this.getVipExpireDate();
          toast.success(
            expireDate
              ? `自动领取成功，会员截至到 ${expireDate} 到期`
              : '畅听会员自动领取成功',
          );
        }
        if (!isSvipClaimedToday && this.isSvipClaimedToday && upgradeSuccess) {
          const svipExpire = this.getSvipExpireDate();
          toast.success(
            svipExpire
              ? `概念会员升级成功，截至到 ${svipExpire} 到期`
              : '概念会员自动升级成功',
          );
        }
      } catch (error) {
        logger.warn('UserStore', 'Auto receive VIP unexpected error:', error);
      } finally {
        this.isAutoClaimingVip = false;
      }
    },

    async checkTodayClaimStatus(): Promise<{ isTvipClaimedToday: boolean; isSvipClaimedToday: boolean }> {
      try {
        const today = await this.getServerToday();
        const recordRes = await getVipMonthRecord();
        const recordList: any[] = recordRes?.data?.list || [];

        const isTvipClaimed = recordList.some((item: any) => item.day === today);

        // 判断 SVIP 是否今日已升级：
        // 优先从记录项中查找升级标识字段，否则回退到检查 SVIP 的 vip_begin_time 是否为今日
        let isSvipClaimed = false;
        const todayRecord = recordList.find((item: any) => item.day === today);
        if (todayRecord) {
          if (todayRecord.is_upgrade || todayRecord.svip === 1 || todayRecord.product_type === 'svip') {
            isSvipClaimed = true;
          }
        }

        if (!isSvipClaimed && isTvipClaimed) {
          const vipInfo = (this.info?.extendsInfo as any)?.vip;
          const busiVip: any[] = vipInfo?.busi_vip || [];
          const svipEntry = busiVip.find((v: any) => v.product_type === 'svip' && v.is_vip === 1);
          if (svipEntry?.vip_begin_time) {
            try {
              const beginDate = new Date(svipEntry.vip_begin_time);
              const pad = (n: number) => n.toString().padStart(2, '0');
              const beginDay = `${beginDate.getFullYear()}-${pad(beginDate.getMonth() + 1)}-${pad(beginDate.getDate())}`;
              isSvipClaimed = beginDay === today;
            } catch {
              // 解析失败忽略
            }
          }
        }

        this.isTvipClaimedToday = isTvipClaimed;
        this.isSvipClaimedToday = isSvipClaimed;

        return { isTvipClaimedToday: isTvipClaimed, isSvipClaimedToday: isSvipClaimed };
      } catch (e) {
        logger.warn('UserStore', 'Failed to check claim status:', e);
        return { isTvipClaimedToday: this.isTvipClaimedToday, isSvipClaimedToday: this.isSvipClaimedToday };
      }
    },

    setClaimStatus(tvip: boolean, svip: boolean) {
      this.isTvipClaimedToday = tvip;
      this.isSvipClaimedToday = svip;
    },

    getVipExpireDate(): string | null {
      const vipInfo = (this.info?.extendsInfo as any)?.vip;
      const busiVip: any[] = vipInfo?.busi_vip || [];
      const tvip = busiVip.find((v: any) => v.product_type === 'tvip' && v.is_vip === 1);
      if (!tvip?.vip_end_time) return null;
      try {
        const d = new Date(tvip.vip_end_time);
        if (isNaN(d.getTime())) return null;
        const pad = (n: number) => n.toString().padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      } catch {
        return null;
      }
    },

    getSvipExpireDate(): string | null {
      const vipInfo = (this.info?.extendsInfo as any)?.vip;
      const busiVip: any[] = vipInfo?.busi_vip || [];
      const svip = busiVip.find((v: any) => v.product_type === 'svip' && v.is_vip === 1);
      if (!svip?.vip_end_time) return null;
      try {
        const d = new Date(svip.vip_end_time);
        if (isNaN(d.getTime())) return null;
        const pad = (n: number) => n.toString().padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      } catch {
        return null;
      }
    },
    logout() {
      this.info = null;
      this.isLoggedIn = false;
      this.hasFetchedUserInfo = false;
      this.isFetchingUserInfo = false;
      this.isTvipClaimedToday = false;
      this.isSvipClaimedToday = false;
      this.isAutoClaimingVip = false;
      this.followedArtistIds = new Set();
      this.hasFetchedFollowedArtists = false;
    },

    isArtistFollowed(artistId: string | number): boolean {
      return this.followedArtistIds.has(String(artistId));
    },

    addFollowedArtist(artistId: string | number) {
      this.followedArtistIds = new Set([...this.followedArtistIds, String(artistId)]);
    },

    removeFollowedArtist(artistId: string | number) {
      const next = new Set(this.followedArtistIds);
      next.delete(String(artistId));
      this.followedArtistIds = next;
    },

    async fetchFollowedArtists() {
      if (!this.isLoggedIn) return;
      try {
        const res = await getUserFollow();
        if (res && typeof res === 'object' && 'data' in res) {
          const data = (res as { data?: { lists?: unknown[] } }).data;
          const lists = Array.isArray(data?.lists) ? data.lists : [];
          const ids = new Set<string>();
          for (const item of lists) {
            const record = item as Record<string, unknown>;
            const id = String(record.singerid ?? record.userid ?? record.id ?? '');
            if (id) ids.add(id);
          }
          this.followedArtistIds = ids;
          this.hasFetchedFollowedArtists = true;
        }
      } catch (e) {
        logger.warn('UserStore', 'Fetch followed artists failed', e);
      }
    },

    async ensureFollowedArtists() {
      if (this.hasFetchedFollowedArtists) return;
      await this.fetchFollowedArtists();
    },

    async getServerToday(): Promise<string> {
      try {
        const res = await getServerNow();
        if (res && typeof res === 'object') {
          const record = res as unknown as Record<string, unknown>;
          const source = (
            record.data && typeof record.data === 'object' ? record.data : record
          ) as Record<string, unknown>;
          const candidates = [
            source.now,
            source.time,
            source.timestamp,
            source.server_time,
            source.serverTime,
          ];
          for (const candidate of candidates) {
            const value = Number(candidate);
            if (Number.isFinite(value) && value > 0) {
              // 服务器返回的是秒级或毫秒级时间戳
              const ms = value > 1e12 ? value : value * 1000;
              // 使用北京时间（UTC+8）格式化日期
              const date = new Date(ms);
              const offset = 8 * 60;
              const local = new Date(date.getTime() + offset * 60 * 1000);
              return local.toISOString().split('T')[0];
            }
          }
        }
      } catch (e) {
        logger.warn('UserStore', 'Failed to get server time, using local time', e);
      }
      // 兜底：使用本地时间（北京时间）
      const now = new Date();
      const offset = 8 * 60;
      const local = new Date(now.getTime() + offset * 60 * 1000);
      return local.toISOString().split('T')[0];
    },
  },
  persist: {
    omit: [
      'hasFetchedUserInfo',
      'isFetchingUserInfo',
      'isAutoClaimingVip',
      'followedArtistIds',
      'hasFetchedFollowedArtists',
    ],
  },
});
