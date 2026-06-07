# MV 纯 FFmpeg 解码播放器 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 MV 播放从 HTML5 video 切换为纯 ExoPlayer + FFmpeg 软解码，播放器嵌入页面并自适应横竖屏。

**Architecture:** 前端 MvDetail.vue 移除 HTML5 `<video>` 元素，改为占位 div，通过 IntersectionObserver + scroll 事件实时同步原生 TextureView 位置。NativeVideoPlayer.java 始终启用 FFmpeg 软解码，并在 prepared 事件中返回视频尺寸用于动态宽高比计算。

**Tech Stack:** Vue 3 + TypeScript（前端），ExoPlayer + FFmpeg（Android 原生），GeckoView bridge（通信）

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `android/app/src/main/java/com/muye/ecells/music/NativeVideoPlayer.java` | Modify | 始终 FFmpeg 解码 + prepared 事件返回视频尺寸 |
| `src/renderer/views/details/MvDetail.vue` | Modify | 移除 HTML5 video，纯 FFmpeg 播放 + 占位 div + IntersectionObserver |

---

### Task 1: NativeVideoPlayer.java — 始终使用 FFmpeg + 返回视频尺寸

**Files:**
- Modify: `android/app/src/main/java/com/muye/ecells/music/NativeVideoPlayer.java`

- [ ] **Step 1: 修改 `loadVideo` 方法，始终启用 FFmpeg 软解码**

将 `loadVideo` 方法中的解码模式判断逻辑替换为始终使用 `EXTENSION_RENDERER_MODE_PREFER`：

找到这段代码（约 86-100 行）：
```java
            // 根据解码模式创建 RenderersFactory
            DefaultRenderersFactory renderersFactory = new DefaultRenderersFactory(activity);
            if ("software".equals(decodeMode)) {
                // 优先使用 FFmpeg 扩展软件解码器
                renderersFactory.setExtensionRendererMode(
                    DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
                );
                Log.i(TAG, "使用 FFmpeg 软件解码模式");
            } else {
                // 默认仅硬件解码器，禁用扩展渲染器
                renderersFactory.setExtensionRendererMode(
                    DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF
                );
                Log.i(TAG, "使用硬件解码模式");
            }
```

替换为：
```java
            // MV 播放始终使用 FFmpeg 软件解码（确保所有视频格式兼容）
            DefaultRenderersFactory renderersFactory = new DefaultRenderersFactory(activity);
            renderersFactory.setExtensionRendererMode(
                DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
            );
            Log.i(TAG, "使用 FFmpeg 软件解码模式");
```

- [ ] **Step 2: 在 `nativeVideoPrepared` 事件中添加视频尺寸**

找到 `onPlaybackStateChanged` 回调中的 `STATE_READY` 分支（约 114-121 行）：

```java
                    if (playbackState == Player.STATE_READY) {
                        isPrepared = true;
                        long durationMs = player.getDuration();
                        double durationSec = durationMs > 0 ? durationMs / 1000.0 : 0;
                        emitEvent("nativeVideoPrepared",
                            "{\"duration\":" + durationSec + "}");
                    }
```

替换为：

```java
                    if (playbackState == Player.STATE_READY) {
                        isPrepared = true;
                        long durationMs = player.getDuration();
                        double durationSec = durationMs > 0 ? durationMs / 1000.0 : 0;
                        int videoWidth = 0;
                        int videoHeight = 0;
                        androidx.media3.common.VideoSize videoSize = player.getVideoSize();
                        if (videoSize != null) {
                            videoWidth = videoSize.width;
                            videoHeight = videoSize.height;
                        }
                        Log.i(TAG, "视频尺寸: " + videoWidth + "x" + videoHeight);
                        emitEvent("nativeVideoPrepared",
                            "{\"duration\":" + durationSec
                            + ",\"videoWidth\":" + videoWidth
                            + ",\"videoHeight\":" + videoHeight + "}");
                    }
```

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/com/muye/ecells/music/NativeVideoPlayer.java
git commit -m "refactor: NativeVideoPlayer always use FFmpeg, add video dimensions to prepared event"
```

---

### Task 2: MvDetail.vue — 移除 HTML5 相关代码，简化播放逻辑

**Files:**
- Modify: `src/renderer/views/details/MvDetail.vue`

这是最大的改动。按以下步骤逐步修改。

- [ ] **Step 1: 移除不再需要的导入和状态变量**

在 `<script setup>` 中，移除以下不再需要的代码块：

**移除 `videoRef`（第 29 行）：**
```typescript
const videoRef = ref<HTMLVideoElement | null>(null);
```

**移除整个回退链状态块（第 39-53 行）：**
```typescript
// === 原生视频播放器状态（ExoPlayer + FFmpeg 降级） ===
const playbackMode = ref<'html5' | 'native-sw'>('html5');
const nativeVideoActive = ref(false);
const nativeVideoPlaying = ref(false);
const isFallbackInProgress = ref(false);
let nativeVideoPreparedResolver: ((value: boolean) => void) | null = null;

interface DecodeAttemptLog {
  mode: 'html5' | 'native-sw';
  url: string;
  hash: string;
  codec: string;
  errorReason: string;
  timestamp: number;
}
const fallbackAttempts = ref<DecodeAttemptLog[]>([]);
```

**替换为纯 FFmpeg 播放器状态：**
```typescript
// === FFmpeg 原生视频播放器状态 ===
const nativeVideoActive = ref(false);
const nativeVideoPlaying = ref(false);
const isFallbackInProgress = ref(false);
let nativeVideoPreparedResolver: ((value: boolean) => void) | null = null;
const videoAspectRatio = ref('16/9');
```

**移除 `handleLoadedMetadata` 函数（第 122-126 行）：**
```typescript
const handleLoadedMetadata = () => {
  if (videoRef.value) {
    duration.value = videoRef.value.duration || 0;
  }
};
```

**修改 `resetControlsTimer`（第 129-136 行），移除 `videoRef` 引用：**

原代码：
```typescript
const resetControlsTimer = () => {
  showControls.value = true;
  if (controlsTimer) clearTimeout(controlsTimer);
  controlsTimer = setTimeout(() => {
    if (videoRef.value && !videoRef.value.paused) {
      showControls.value = false;
    }
  }, 3000);
};
```

替换为：
```typescript
const resetControlsTimer = () => {
  showControls.value = true;
  if (controlsTimer) clearTimeout(controlsTimer);
  controlsTimer = setTimeout(() => {
    if (nativeVideoPlaying.value) {
      showControls.value = false;
    }
  }, 3000);
};
```

**修改 `changeSource`（第 713-717 行），移除 `decodeCheckDone` 引用：**

原代码：
```typescript
const changeSource = (hash: string) => {
  if (!hash || hash === currentSourceHash.value) return;
  currentSourceHash.value = hash;
  decodeCheckDone = false;
};
```

替换为：
```typescript
const changeSource = (hash: string) => {
  if (!hash || hash === currentSourceHash.value) return;
  currentSourceHash.value = hash;
};
```

**修改 `handleTimeUpdateForControls`（第 113-120 行），移除 HTML5 分支：**

原代码：
```typescript
const handleTimeUpdateForControls = () => {
  // 原生播放器模式由 nativeVideoTimeUpdate 事件更新，此处跳过
  if (nativeVideoActive.value) return;
  if (!isDragging.value && videoRef.value) {
    currentTime.value = videoRef.value.currentTime;
    duration.value = videoRef.value.duration || 0;
  }
};
```

替换为：
```typescript
// 时间由 nativeVideoTimeUpdate 事件更新，此处不再需要
```
即完全移除此函数。

**修改 `toggleVideoPlay`（第 138-162 行），移除 HTML5 分支：**

原代码：
```typescript
const toggleVideoPlay = (e?: Event) => {
  e?.stopPropagation();
  if (loading.value || sourceLoading.value || isFallbackInProgress.value) return;

  // 原生播放器模式
  if (nativeVideoActive.value) {
    if (nativeVideoPlaying.value) {
      NativeVideoBridge.pause().catch(() => {});
      nativeVideoPlaying.value = false;
    } else {
      NativeVideoBridge.play().catch(() => {});
      nativeVideoPlaying.value = true;
    }
    return;
  }

  // HTML5 播放模式
  const video = videoRef.value;
  if (!video) return;
  if (video.paused) {
    video.play().catch(() => {});
  } else {
    video.pause();
  }
};
```

替换为：
```typescript
const toggleVideoPlay = (e?: Event) => {
  e?.stopPropagation();
  if (loading.value || sourceLoading.value || isFallbackInProgress.value) return;

  if (nativeVideoPlaying.value) {
    NativeVideoBridge.pause().catch(() => {});
    nativeVideoPlaying.value = false;
  } else {
    NativeVideoBridge.play().catch(() => {});
    nativeVideoPlaying.value = true;
  }
};
```

**修改 `applySeek`（第 174-185 行），移除 HTML5 分支：**

原代码：
```typescript
const applySeek = (time: number) => {
  currentTime.value = time;
  // 原生播放器模式
  if (nativeVideoActive.value) {
    NativeVideoBridge.seek({ timeMs: Math.round(time * 1000) }).catch(() => {});
    return;
  }
  // HTML5 模式
  const video = videoRef.value;
  if (!video) return;
  video.currentTime = time;
};
```

替换为：
```typescript
const applySeek = (time: number) => {
  currentTime.value = time;
  NativeVideoBridge.seek({ timeMs: Math.round(time * 1000) }).catch(() => {});
};
```

- [ ] **Step 2: 移除降级链相关函数**

删除以下整块函数（约第 489-696 行区域）：

- `failedSourceHashes` ref 和 `decodeCheckDone` 标记
- `translateErrorReason()` 函数
- `updateNativeSurfaceBounds()` 函数 — **保留此函数**，后面需要增强
- `tryNativePlayback()` 函数 — **保留此函数**，后面需要简化
- `buildDetailedError()` 函数
- `handleAllSourcesExhausted()` 函数
- `executeFallbackChain()` 函数
- `tryNextSource()` 函数
- `handleVideoError()` 函数
- `handleVideoTimeUpdate()` 函数

具体地：

**删除 `failedSourceHashes` 和 `decodeCheckDone`（约 490-491 行）：**
```typescript
const failedSourceHashes = ref(new Set<string>());
let decodeCheckDone = false;
```

**删除 `translateErrorReason`（约 494-503 行）：** 整个函数

**删除 `buildDetailedError`（约 563-593 行）：** 整个函数

**删除 `handleAllSourcesExhausted`（约 596-599 行）：** 整个函数

**删除 `executeFallbackChain`（约 602-664 行）：** 整个函数

**删除 `tryNextSource`（约 667-686 行）：** 整个函数

**删除 `handleVideoError`（约 688-696 行）：** 整个函数

**删除 `handleVideoTimeUpdate`（约 699-711 行）：** 整个函数

**简化 `loadVideoUrl`（约 372-424 行），** 替换整个函数为：

```typescript
const loadVideoUrl = async (hash: string) => {
  if (!hash) return;
  const gen = ++loadVideoGeneration;
  sourceLoading.value = true;
  playbackError.value = '';

  // 重置播放器状态
  if (nativeVideoActive.value) {
    nativeVideoActive.value = false;
    nativeVideoPlaying.value = false;
    await NativeVideoBridge.release().catch(() => {});
    await NativeVideoBridge.hideSurface().catch(() => {});
  }

  try {
    const response = await getVideoUrl(hash);
    if (gen !== loadVideoGeneration) return;
    const url = extractVideoUrl(response, hash, isMobileNative);
    if (!url) throw new Error('empty-url');

    // 非 GeckoView 环境无法使用原生播放器
    if (!isGeckoView) {
      playbackError.value = 'MV 播放需要原生环境支持';
      return;
    }

    await pauseMusicPlayback();

    // 直接使用 FFmpeg 软解码
    isFallbackInProgress.value = true;
    const result = await tryNativePlayback(url);
    if (gen !== loadVideoGeneration) return;

    if (result.success) {
      nativeVideoActive.value = true;
      await nextTick();
      await updateNativeSurfaceBounds();
    } else {
      playbackError.value = `视频播放失败: ${result.reason || '未知错误'}`;
      toastStore.loadFailed('MV');
    }
  } catch {
    if (gen !== loadVideoGeneration) return;
    playbackError.value = '当前视频暂时无法播放';
    toastStore.loadFailed('MV');
  } finally {
    if (gen === loadVideoGeneration) {
      sourceLoading.value = false;
      isFallbackInProgress.value = false;
    }
  }
};
```

**简化 `tryNativePlayback`（约 527-560 行），** 替换整个函数为：

```typescript
const tryNativePlayback = async (
  url: string,
): Promise<{ success: boolean; reason?: string }> => {
  try {
    await NativeVideoBridge.release();

    const result = await NativeVideoBridge.loadVideo({ url, decodeMode: 'software' });
    if (result?.__nativeError) {
      return { success: false, reason: result.__nativeError };
    }

    // 等待 nativeVideoPrepared 或 nativeVideoError 事件，最多 8 秒
    const prepared = await new Promise<boolean>((resolve) => {
      nativeVideoPreparedResolver = resolve;
      setTimeout(() => {
        nativeVideoPreparedResolver = null;
        resolve(false);
      }, 8000);
    });

    if (!prepared) {
      await NativeVideoBridge.release().catch(() => {});
      return { success: false, reason: '视频加载超时或解码失败' };
    }

    // 开始播放
    await NativeVideoBridge.play();
    nativeVideoPlaying.value = true;
    return { success: true };
  } catch (e: any) {
    return { success: false, reason: e?.message || '播放器调用失败' };
  }
};
```

**简化 `destroyVideoPlayer`（约 723-738 行），** 移除 HTML5 清理：

原代码：
```typescript
const destroyVideoPlayer = () => {
  // 释放原生视频播放器
  if (nativeVideoActive.value) {
    NativeVideoBridge.release().catch(() => {});
    NativeVideoBridge.hideSurface().catch(() => {});
    nativeVideoActive.value = false;
    nativeVideoPlaying.value = false;
  }
  // 释放 HTML5 视频
  const video = videoRef.value;
  if (!video) return;
  video.pause();
  video.removeAttribute('src');
  video.load();
  currentVideoUrl.value = '';
};
```

替换为：
```typescript
const destroyVideoPlayer = () => {
  if (nativeVideoActive.value) {
    NativeVideoBridge.release().catch(() => {});
    NativeVideoBridge.hideSurface().catch(() => {});
    nativeVideoActive.value = false;
    nativeVideoPlaying.value = false;
  }
  currentVideoUrl.value = '';
};
```

**修改 `handleVisibilityChange`（约 756-768 行），** 移除 HTML5 暂停：

原代码：
```typescript
const handleVisibilityChange = () => {
  if (document.hidden) {
    // 原生播放器暂停
    if (nativeVideoActive.value && nativeVideoPlaying.value) {
      NativeVideoBridge.pause().catch(() => {});
      nativeVideoPlaying.value = false;
    }
    // HTML5 播放器暂停
    if (videoRef.value && !videoRef.value.paused) {
      videoRef.value.pause();
    }
  }
};
```

替换为：
```typescript
const handleVisibilityChange = () => {
  if (document.hidden && nativeVideoActive.value && nativeVideoPlaying.value) {
    NativeVideoBridge.pause().catch(() => {});
    nativeVideoPlaying.value = false;
  }
};
```

**修改 `applyVersion`（约 435-451 行），** 移除 `playbackMode` 和 `fallbackAttempts`：

原代码中包含：
```typescript
    playbackMode.value = 'html5';
    fallbackAttempts.value = [];
```

替换为：
```typescript
    videoAspectRatio.value = '16/9';
```

- [ ] **Step 3: 添加 IntersectionObserver 和增强 nativeVideoPrepared 监听**

**增强 `handleNativeSurfaceUpdate`（约 771-778 行），** 使用 requestAnimationFrame 节流：

原代码：
```typescript
let surfaceUpdateTimer: ReturnType<typeof setTimeout> | null = null;
const handleNativeSurfaceUpdate = () => {
  if (!nativeVideoActive.value) return;
  if (surfaceUpdateTimer) clearTimeout(surfaceUpdateTimer);
  surfaceUpdateTimer = setTimeout(() => {
    void updateNativeSurfaceBounds();
  }, 100);
};
```

替换为：
```typescript
let surfaceRafId: number | null = null;
const handleNativeSurfaceUpdate = () => {
  if (!nativeVideoActive.value || !isGeckoView) return;
  if (surfaceRafId !== null) return; // 已有待处理的帧，跳过
  surfaceRafId = requestAnimationFrame(() => {
    surfaceRafId = null;
    void updateNativeSurfaceBounds();
  });
};
```

**在 `onMounted` 中添加 IntersectionObserver（约 795 行后插入）：**

在 `onMounted` 内、`if (isGeckoView) {` 块的末尾（`addListener('nativeVideoTimeUpdate', ...)` 之后），添加：

```typescript
    // IntersectionObserver: 占位元素不可见时隐藏 TextureView
    const playerBox = document.querySelector('.mv-player-box');
    if (playerBox) {
      const observer = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (!nativeVideoActive.value) return;
            if (entry.isIntersecting) {
              NativeVideoBridge.showSurface().catch(() => {});
              handleNativeSurfaceUpdate();
            } else {
              NativeVideoBridge.hideSurface().catch(() => {});
            }
          }
        },
        { threshold: 0.1 }
      );
      observer.observe(playerBox);
      // 保存引用以便清理
      (window as any).__mvPlayerObserver = observer;
    }
```

**修改 `nativeVideoPrepared` 事件监听，** 添加视频尺寸处理：

原代码（约 796-800 行）：
```typescript
    addListener('nativeVideoPrepared', (data: any) => {
      nativeVideoPlaying.value = false;
      if (nativeVideoPreparedResolver) {
        nativeVideoPreparedResolver(true);
        nativeVideoPreparedResolver = null;
      }
    });
```

替换为：
```typescript
    addListener('nativeVideoPrepared', (data: any) => {
      nativeVideoPlaying.value = false;
      // 根据视频尺寸动态调整播放器宽高比
      const vw = data?.videoWidth;
      const vh = data?.videoHeight;
      if (vw > 0 && vh > 0) {
        videoAspectRatio.value = `${vw}/${vh}`;
      }
      if (nativeVideoPreparedResolver) {
        nativeVideoPreparedResolver(true);
        nativeVideoPreparedResolver = null;
      }
    });
```

**在 `onBeforeUnmount` 中清理 IntersectionObserver：**

在 `onBeforeUnmount` 函数开头添加：
```typescript
  // 清理 IntersectionObserver
  const observer = (window as any).__mvPlayerObserver as IntersectionObserver | undefined;
  if (observer) {
    observer.disconnect();
    delete (window as any).__mvPlayerObserver;
  }
```

同时在 `onBeforeUnmount` 中清理 surfaceRafId：
```typescript
  if (surfaceRafId !== null) {
    cancelAnimationFrame(surfaceRafId);
    surfaceRafId = null;
  }
```

并将 `surfaceUpdateTimer` 相关清理改为 `surfaceRafId`：
删除原有的 `surfaceUpdateTimer` 清理（如果有的话），用上面的 `surfaceRafId` 清理替代。

- [ ] **Step 4: 修改模板 — 移除 HTML5 video，添加占位 div**

找到模板中的 `<video>` 块（约 861-875 行）：

```html
        <video
          v-show="!nativeVideoActive"
          ref="videoRef"
          class="mv-video"
          :controls="!isMobileNative"
          preload="metadata"
          playsinline
          :poster="cover"
          @play="handleVideoPlay"
          @error="handleVideoError"
          @timeupdate="handleVideoTimeUpdate; handleTimeUpdateForControls()"
          @loadedmetadata="handleLoadedMetadata"
        >
          <source v-if="currentVideoUrl" :src="currentVideoUrl" />
        </video>
```

替换为：
```html
        <!-- FFmpeg 解码占位区域 -->
        <div class="mv-native-placeholder">
          <img v-if="cover && !nativeVideoActive" :src="cover" alt="" class="mv-placeholder-cover" />
        </div>
```

**修改 `.mv-player-box` 容器的样式绑定：**

找到：
```html
      <div class="mv-player-box" :class="{ 'is-pseudo-fullscreen': isPseudoFullscreen }" @mousemove="isMobileNative ? resetControlsTimer() : undefined" @touchstart="isMobileNative ? resetControlsTimer() : undefined">
```

替换为：
```html
      <div class="mv-player-box" :class="{ 'is-pseudo-fullscreen': isPseudoFullscreen }" :style="{ aspectRatio: videoAspectRatio }" @mousemove="isMobileNative ? resetControlsTimer() : undefined" @touchstart="isMobileNative ? resetControlsTimer() : undefined">
```

**修改控制栏中的播放/暂停图标判断（约 903 行）：**

原代码：
```html
            <Icon :icon="(nativeVideoActive ? !nativeVideoPlaying : videoRef?.paused) ? iconPlay : iconPause" width="20" height="20" />
```

替换为：
```html
            <Icon :icon="nativeVideoPlaying ? iconPause : iconPlay" width="20" height="20" />
```

**移除 "正在尝试其他解码方式" 提示中的相关条件：**

找到 loading overlay（约 882-887 行）：
```html
        <div v-if="loading || sourceLoading || isFallbackInProgress" class="mv-overlay-state">
          <div class="mv-loading-spinner"></div>
          <span v-if="isFallbackInProgress">正在尝试其他解码方式...</span>
          <span v-else-if="sourceLoading">正在切换片源...</span>
          <span v-else>正在加载 MV ...</span>
        </div>
```

替换为：
```html
        <div v-if="loading || sourceLoading || isFallbackInProgress" class="mv-overlay-state">
          <div class="mv-loading-spinner"></div>
          <span v-if="sourceLoading">正在切换片源...</span>
          <span v-else>正在加载 MV ...</span>
        </div>
```

- [ ] **Step 5: 修改样式**

**删除 `.mv-video` 样式块（约 1053-1058 行）：**
```css
.mv-video {
  width: 100%;
  height: 100%;
  object-fit: contain;
  background: #000;
}
```

**修改 `.mv-player-box` 样式（约 1045-1051 行），移除固定的 `aspect-ratio`：**

原代码：
```css
.mv-player-box {
  position: relative;
  overflow: hidden;
  aspect-ratio: 16 / 9;
  border-radius: 18px;
  background: #000;
}
```

替换为：
```css
.mv-player-box {
  position: relative;
  overflow: hidden;
  /* aspect-ratio 由 JS 动态设置，适应横屏/竖屏 */
  border-radius: 18px;
  background: #000;
}
```

**添加 `.mv-native-placeholder` 和 `.mv-placeholder-cover` 样式（在 `.mv-player-box` 之后）：**

```css
.mv-native-placeholder {
  position: absolute;
  inset: 0;
  background: #000;
}

.mv-placeholder-cover {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: contain;
  opacity: 0.5;
  pointer-events: none;
}
```

**修改全屏样式中的 `.mv-player-box.is-pseudo-fullscreen`（约 1093-1102 行）：**

现有样式已经使用 `width: 100vw; height: 100vh;` 覆盖 aspect-ratio，不需要修改。但为了确保全屏时忽略 aspect-ratio，确认样式块中包含：

```css
.mv-player-box.is-pseudo-fullscreen {
  position: fixed;
  inset: 0;
  z-index: 10000;
  width: 100vw;
  height: 100vh;
  border-radius: 0;
  margin: 0;
  background: #000;
}
```

这个已经是正确的，无需修改。

- [ ] **Step 6: Commit**

```bash
git add src/renderer/views/details/MvDetail.vue
git commit -m "feat: MV playback uses pure FFmpeg decoding, embedded player with scroll tracking"
```

---

## Verification

完成所有 Task 后，按以下步骤验证：

1. **构建前端**：运行 `npm run build` 确认无编译错误
2. **构建 Android**：运行 `./gradlew assembleDebug` 确认 Java 编译通过
3. **功能测试**（需要设备或模拟器）：
   - 打开 MV 详情页 → 视频通过 FFmpeg 解码播放，显示"FFmpeg 软件解码"标记
   - 滚动页面 → TextureView 跟随占位 div 移动，滚出视口时隐藏
   - 播放横屏 MV → 播放器显示为宽屏比例
   - 播放竖屏 MV → 播放器自动调整为竖屏比例
   - 点击全屏按钮 → 进入全屏，再点击退出 → 恢复原始位置和尺寸
   - 控制栏（播放/暂停、进度拖拽、时间显示）正常工作
   - 切换不同片源正常加载和播放
   - App 切到后台 → 视频自动暂停
