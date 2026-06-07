# MV 播放器：HTML5 → 纯 FFmpeg 解码

## Context

当前 MV 播放使用 HTML5 `<video>` 元素作为主要解码方式，仅在 HTML5 失败后才回退到 ExoPlayer + FFmpeg 软解码。原生播放器以 TextureView 悬浮覆盖在 GeckoView 上方。用户需求：

1. MV 播放始终使用 FFmpeg 解码，不依赖 HTML5
2. 播放器视觉上嵌入页面（通过占位 div 位置跟踪实现）
3. 未全屏时宽度 100%，高度根据视频宽高比自适应
4. 自动适配横屏和竖屏视频

## 方案

**增强型覆盖 + 滚动跟踪**：移除 HTML5 video，始终走 ExoPlayer + FFmpeg，通过 IntersectionObserver + scroll 事件实时同步 TextureView 到占位 div 位置。

## 修改文件

### 1. `src/renderer/views/details/MvDetail.vue`（主要改动）

#### 模板

- 移除 `<video>` 元素及其所有事件绑定
- 添加占位 `<div>`，显示封面图作为加载前预览
- `mv-player-box` 容器保持不变，控制栏、全屏按钮、loading 等保持不变
- 占位 div 的 `aspect-ratio` 通过 `:style` 动态绑定

#### 脚本

**移除的代码：**
- `videoRef` ref
- `playbackMode` 状态（不再需要 'html5'）
- `decodeCheckDone` 标记
- `fallbackAttempts` 数组及相关类型
- `executeFallbackChain()` 整个降级链
- `tryNextSource()` 片源自动切换
- `handleVideoError()` HTML5 错误处理
- `handleVideoTimeUpdate()` HTML5 解码检测
- `handleLoadedMetadata()` HTML5 元数据
- `handleTimeUpdateForControls()` 中 HTML5 分支
- `toggleVideoPlay()` 中 HTML5 分支
- `applySeek()` 中 HTML5 分支
- `destroyVideoPlayer()` 中 HTML5 清理
- `handleVisibilityChange()` 中 HTML5 暂停
- `buildDetailedError()`、`translateErrorReason()`、`handleAllSourcesExhausted()` 等降级链辅助函数

**新增/修改的代码：**
- `videoAspectRatio` ref：存储视频宽高比字符串（如 '16/9'、'9/16'），默认 '16/9'
- `loadVideoUrl()` 简化：获取 URL → 直接调用 `NativeVideoBridge.loadVideo({ url, decodeMode: 'software' })` → 等待 prepared → play
- `nativeVideoPrepared` 事件监听：从事件数据中提取 `videoWidth` 和 `videoHeight`，计算并设置 `videoAspectRatio`
- `IntersectionObserver`：监听 `.mv-player-box` 可见性，不可见时隐藏 TextureView，可见时重新定位
- `handleNativeSurfaceUpdate()` 增强：使用 requestAnimationFrame 节流，减少位置计算频率
- 非 GeckoView 环境显示"需要原生环境支持"提示

#### 样式

- `.mv-player-box` 移除固定 `aspect-ratio: 16/9`，改为动态绑定
- `.mv-video` 移除（不再有 video 元素）
- 新增 `.mv-native-placeholder`：全黑背景，封面图居中显示

### 2. `NativeVideoPlayer.java`（小改动）

- `loadVideo()` 方法：忽略 `decodeMode` 参数，始终使用 `EXTENSION_RENDERER_MODE_PREFER`
- **必须**：`nativeVideoPrepared` 事件中增加 `videoWidth` 和 `videoHeight` 字段（当前只有 `duration`）。在 `onPlaybackStateChanged(STATE_READY)` 中从 ExoPlayer 获取视频尺寸：
  ```java
  int width = player.getVideoSize().width;
  int height = player.getVideoSize().height;
  emitEvent("nativeVideoPrepared",
      "{\"duration\":" + durationSec
      + ",\"videoWidth\":" + width
      + ",\"videoHeight\":" + height + "}");
  ```

### 3. 其他文件（不变）

- `nativeBridge.ts`：现有 API 足够
- `activity_main.xml`：现有布局足够
- `PassThroughTextureView.java`：不变
- `NativeAudioPlugin.java`：不变

## 数据流

```
用户打开 MV 页面
  → fetchMvMeta() 获取元数据
  → loadVideoUrl(hash) 获取播放地址
  → NativeVideoBridge.loadVideo({ url, decodeMode: 'software' })
  → NativeVideoPlayer: ExoPlayer + FFmpeg 解码
  → nativeVideoPrepared 事件（含视频尺寸）
  → 动态设置占位 div 的 aspect-ratio
  → NativeVideoBridge.play() + setSurfaceBounds()
  → IntersectionObserver + scroll 持续同步位置
```

## 横竖屏适配

- `nativeVideoPrepared` 事件携带 `videoWidth` 和 `videoHeight`
- 计算 `aspect-ratio: ${videoWidth}/${videoHeight}`
- 横屏视频（如 1920×1080）→ `aspect-ratio: 16/9`
- 竖屏视频（如 1080×1920）→ `aspect-ratio: 9/16`
- 更新后 nextTick → updateNativeSurfaceBounds() 同步 TextureView

## 验证方式

1. 打开 MV 详情页，确认视频通过 FFmpeg 解码播放（显示"FFmpeg 软件解码"标记）
2. 滚动页面，TextureView 跟随占位 div 移动，滚出视口时隐藏
3. 播放横屏 MV，确认播放器为 16:9 宽屏比例
4. 播放竖屏 MV，确认播放器为竖屏比例
5. 全屏切换正常工作，退出全屏后恢复原始位置和尺寸
6. 控制栏（播放/暂停、进度条、时间显示）正常工作
7. 切换不同片源正常工作
