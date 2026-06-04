import { useAuthStore } from '@/stores/auth';
import { useUserStore } from '@/stores/user';
import { useDeviceStore } from '@/stores/device';
import { useSettingStore } from '@/stores/setting';
import { ensureDevice } from './device';
import { logger } from './logger';

// --- 类型定义 ---

interface ApiRequestConfig {
  method: string;
  url: string;
  params?: Record<string, any>;
  data?: any;
  headers?: Record<string, string>;
}

interface ApiResponse {
  status: number;
  body: any;
  cookie?: string[];
  headers?: Record<string, string>;
}

interface RequestConfig {
  params?: Record<string, any>;
  data?: any;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

// --- 在线后端配置 ---

const getApiBaseUrl = (): string => {
  try {
    const store = useSettingStore();
    const base = (store.apiBaseUrl || '').replace(/\/+$/, '');
    if (base) return base;
  } catch {
    // store not available
  }
  // 回退到 .env 文件中的配置
  const envBase = (import.meta.env.VITE_API_BASE_URL || '').replace(/\/+$/, '');
  if (envBase) return envBase;
  return '';
};

// --- 拦截器逻辑（从原 axios 版本保留） ---

let isAuthExpiredNotified = false;

/**
 * 构建 Authorization header（复现原请求拦截器逻辑）
 */
const buildAuthHeader = (skipAuth: boolean): string => {
  if (skipAuth) return '';

  const authParts: string[] = [];
  const userStore = useUserStore();
  const deviceStore = useDeviceStore();

  // 注入用户信息
  if (userStore.info) {
    if (userStore.info.token) authParts.push(`token=${userStore.info.token}`);
    if (userStore.info.userid) authParts.push(`userid=${userStore.info.userid}`);
    if (userStore.info.t1) authParts.push(`t1=${userStore.info.t1}`);
  }

  // 注入设备信息
  if (deviceStore.info) {
    const device = deviceStore.info;
    if (device.dfid) authParts.push(`dfid=${device.dfid}`);
    if (device.mid) authParts.push(`KUGOU_API_MID=${device.mid}`);
    if (device.uuid) authParts.push(`uuid=${device.uuid}`);
    if (device.guid) authParts.push(`KUGOU_API_GUID=${device.guid}`);
    if (device.serverDev) authParts.push(`KUGOU_API_DEV=${device.serverDev}`);
    if (device.mac) authParts.push(`KUGOU_API_MAC=${device.mac}`);
  }

  return authParts.join(';');
};

/**
 * 检查身份是否过期（复现原响应拦截器逻辑）
 */
const checkAuthExpiration = (path: string, data: any): boolean => {
  if (!data || typeof data !== 'object') return false;

  const rules = [
    () => Number(data.error_code) === 20018,
    () => data.msg && typeof data.msg === 'string' && data.msg.includes('登录已过期'),
  ];

  void path;
  return rules.some((rule) => rule());
};

const handleAuthExpired = (path: string, responseStatus: number, data: unknown) => {
  const userStore = useUserStore();

  if (responseStatus === 0) return;

  if (!userStore.isLoggedIn || isAuthExpiredNotified || !checkAuthExpiration(path, data)) {
    return;
  }

  isAuthExpiredNotified = true;
  logger.warn('API', `Auth expired (Path: ${path})`);
  // 不立即 logout，只弹窗让用户确认
  useAuthStore().showSessionExpiredDialog();

  window.setTimeout(() => {
    isAuthExpiredNotified = false;
  }, 5000);
};

/**
 * 通过在线后端发送 HTTP 请求
 */
const httpOnlineRequest = async (
  method: string,
  url: string,
  config?: RequestConfig,
): Promise<ApiResponse> => {
  const skipAuth = config?.headers?.['X-Skip-Auth'] === '1';
  const headers: Record<string, string> = { ...(config?.headers || {}) };
  delete headers['X-Skip-Auth'];

  // 注入 Authorization
  const auth = buildAuthHeader(skipAuth);
  if (auth) {
    headers['Authorization'] = auth;
  }

  // 构建完整 URL
  const apiBase = getApiBaseUrl();
  if (!apiBase) {
    throw new Error('API 地址未配置，请先完成初始化设置');
  }
  const fullUrl = new URL(url, apiBase);
  if (config?.params) {
    for (const [key, value] of Object.entries(config.params)) {
      if (value !== null && value !== undefined) {
        fullUrl.searchParams.append(key, String(value));
      }
    }
  }

  const fetchOptions: RequestInit = {
    method,
    headers,
  };

  // 仅在有请求体时设置 Content-Type（GET 请求不应设置，避免不必要的 CORS 预检）
  if (config?.data && method !== 'GET') {
    fetchOptions.headers = {
      'Content-Type': 'application/json',
      ...headers,
    };
    fetchOptions.body = JSON.stringify(config.data);
  }

  // 设置请求超时，防止请求无限挂起阻塞 Promise.allSettled
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  // 合并外部 signal（用户主动取消）和超时 signal
  if (config?.signal) {
    config.signal.addEventListener('abort', () => controller.abort());
  }

  fetchOptions.signal = controller.signal;

  let response: Response;
  try {
    response = await fetch(fullUrl.toString(), fetchOptions);
  } finally {
    clearTimeout(timeoutId);
  }

  let body: any;
  try {
    body = await response.json();
  } catch {
    body = null;
  }

  return {
    status: response.status,
    body,
  };
};

/**
 * 发送 API 请求（统一入口）
 */
const ipcRequest = async (method: string, url: string, config?: RequestConfig): Promise<any> => {
  const skipAuth = config?.headers?.['X-Skip-Auth'] === '1';
  const headers: Record<string, string> = { ...(config?.headers || {}) };
  delete headers['X-Skip-Auth'];

  // 请求前确保设备已注册（跳过注册接口本身，避免循环调用）
  if (!skipAuth) {
    await ensureDevice();
  }

  const startTime = performance.now();
  let response: ApiResponse;
  let error: any = null;

  try {
    response = await httpOnlineRequest(method, url, config);
  } catch (e) {
    error = e;
    response = { status: 0, body: null };
  }

  const elapsed = (performance.now() - startTime).toFixed(1);

  // 格式化日志
  const params = config?.params || {};
  const paramStr = Object.keys(params).length
    ? Object.entries(params)
        .map(([k, v]) => `${k}=${v}`)
        .join('&')
    : '';
  const fullUrl = paramStr ? `${url}?${paramStr}` : url;

  if (error) {
    logger.error(
      'API',
      `[${method}] ${fullUrl} (HTTP)\n  ← ERROR (${elapsed}ms): ${error.message || error}`,
    );
    throw error;
  }

  let bodyPreview = '';
  if (response.body != null) {
    bodyPreview =
      typeof response.body === 'object' ? JSON.stringify(response.body) : String(response.body);
    if (bodyPreview.length > 2000) {
      bodyPreview = bodyPreview.substring(0, 2000) + '... (truncated)';
    }
  }

  const statusTag = response.status >= 400 ? '✗' : '✓';
  const auth = buildAuthHeader(skipAuth);
  const headerEntries = Object.entries(headers).filter(([k]) => k !== 'Authorization');

  const lines = [
    `${statusTag} [${method}] ${fullUrl} (HTTP)`,
    `  ├─ Auth: ${auth || '(none)'}`,
    ...(headerEntries.length
      ? [`  ├─ Headers: ${headerEntries.map(([k, v]) => `${k}: ${v}`).join(', ')}`]
      : []),
    ...(config?.data ? [`  ├─ Body: ${JSON.stringify(config.data)}`] : []),
    `  ├─ Status: ${response.status} | Time: ${elapsed}ms`,
    `  └─ Response: ${bodyPreview}`,
  ];

  logger.info('API', lines.join('\n'));

  // 响应拦截：auth 过期检测
  handleAuthExpired(url, response.status, response.body);

  // 处理错误状态
  if (response.status >= 400) {
    if (response.status === 502) {
      const body = response.body as { error_code?: number | string } | null;
      const code = body?.error_code;
      if (code != null && Number(code) !== 0) {
        logger.warn('API', `Upstream business error (error_code=${code})`);
      } else {
        logger.error('API', 'Bad gateway (502)');
      }
    }
    const err = new Error(`API Error: ${response.status}`);
    (err as any).response = response;
    throw err;
  }

  return response.body;
};

// --- 对外暴露的接口（与原 axios 版本保持一致） ---

const request = {
  get: (url: string, config?: RequestConfig) => ipcRequest('GET', url, config),
  post: (url: string, data?: any, config?: RequestConfig) =>
    ipcRequest('POST', url, { ...config, data }),
};

export default request;
