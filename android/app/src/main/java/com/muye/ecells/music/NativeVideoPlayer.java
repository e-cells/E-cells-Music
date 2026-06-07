package com.muye.ecells.music;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.TextureView;
import android.widget.FrameLayout;

import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;

import org.json.JSONObject;

import java.lang.ref.WeakReference;

/**
 * 原生视频播放器，基于 ExoPlayer + FFmpeg 扩展。
 * 支持两种解码模式：
 * - hardware: 仅使用设备硬件 MediaCodec 解码器
 * - software: 启用 FFmpeg 软件解码回退（EXTENSION_RENDERER_MODE_PREFER）
 */
public class NativeVideoPlayer {

    private static final String TAG = "NativeVideoPlayer";

    private final WeakReference<MainActivity> activityRef;
    private final NativeAudioPlugin plugin;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextureView textureView;

    private ExoPlayer player;
    private String currentDecodeMode = "";
    private boolean isPrepared = false;
    private boolean isPlaying = false;

    // 进度更新 Runnable
    private Runnable timeUpdateRunnable;

    public NativeVideoPlayer(MainActivity activity, NativeAudioPlugin plugin) {
        this.activityRef = new WeakReference<>(activity);
        this.plugin = plugin;
    }

    public void setTextureView(TextureView view) {
        this.textureView = view;
    }

    private MainActivity getActivity() {
        MainActivity a = activityRef.get();
        if (a != null && !a.isDestroyed()) return a;
        return null;
    }

    // ── 核心方法 ──

    /**
     * 加载视频到 ExoPlayer。
     * @param url 视频地址
     * @param decodeMode "hardware" 或 "software"
     * @return JSON 结果
     */
    public String loadVideo(String url, String decodeMode) {
        try {
            // 释放旧实例
            releaseInternal();

            currentDecodeMode = decodeMode;
            isPrepared = false;
            isPlaying = false;

            MainActivity activity = getActivity();
            if (activity == null) {
                return errorJson("Activity is destroyed");
            }
            if (textureView == null) {
                return errorJson("TextureView not initialized");
            }
            if (url == null || url.isEmpty()) {
                return errorJson("URL is empty");
            }

            // MV 播放始终使用 FFmpeg 软件解码（确保所有视频格式兼容）
            DefaultRenderersFactory renderersFactory = new DefaultRenderersFactory(activity);
            renderersFactory.setExtensionRendererMode(
                DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
            );
            Log.i(TAG, "使用 FFmpeg 软件解码模式");

            // 创建 ExoPlayer
            player = new ExoPlayer.Builder(activity)
                .setRenderersFactory(renderersFactory)
                .setLoadControl(new DefaultLoadControl.Builder()
                    .setBufferDurationsMs(5000, 10000, 1000, 1000)
                    .build())
                .build();
            player.setVideoTextureView(textureView);

            // 监听播放事件
            player.addListener(new Player.Listener() {
                @Override
                public void onPlaybackStateChanged(int playbackState) {
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
                    } else if (playbackState == Player.STATE_ENDED) {
                        isPlaying = false;
                        stopTimeUpdates();
                        emitEvent("nativeVideoEnded", "{}");
                    }
                }

                @Override
                public void onPlayerError(PlaybackException error) {
                    isPrepared = false;
                    isPlaying = false;
                    stopTimeUpdates();
                    String errorMessage = error.getMessage();
                    if (errorMessage == null) errorMessage = error.getClass().getSimpleName();
                    int errorCode = error.errorCode;
                    Log.e(TAG, "ExoPlayer error (code=" + errorCode + "): " + errorMessage);

                    String safeMsg = errorMessage.replace("\"", "'").replace("\n", " ");
                    emitEvent("nativeVideoError",
                        "{\"code\":" + errorCode
                        + ",\"message\":\"" + safeMsg + "\""
                        + ",\"decodeMode\":\"" + currentDecodeMode + "\"}");
                }

                @Override
                public void onIsPlayingChanged(boolean playing) {
                    isPlaying = playing;
                }
            });

            // 设置媒体源并准备
            MediaItem mediaItem = new MediaItem.Builder()
                .setUri(url)
                .build();
            player.setMediaItem(mediaItem);
            player.prepare();

            Log.i(TAG, "视频加载中: " + url + " (mode=" + decodeMode + ")");
            return "{\"loading\":true,\"decodeMode\":\"" + decodeMode + "\"}";

        } catch (Exception e) {
            Log.e(TAG, "loadVideo failed", e);
            return errorJson(e.getMessage());
        }
    }

    public String play() {
        if (player == null) return errorJson("player not initialized");
        if (!isPrepared) return errorJson("player not prepared yet");
        player.play();
        startTimeUpdates();
        return "{\"playing\":true}";
    }

    public String pause() {
        if (player == null) return errorJson("player not initialized");
        player.pause();
        stopTimeUpdates();
        return "{\"paused\":true}";
    }

    public String seek(long timeMs) {
        if (player == null) return errorJson("player not initialized");
        player.seekTo(timeMs);
        return "{\"seeked\":true}";
    }

    public String getCurrentTime() {
        if (player == null) return "{\"currentTime\":0}";
        double timeSec = player.getCurrentPosition() / 1000.0;
        return "{\"currentTime\":" + timeSec + "}";
    }

    public String getDuration() {
        if (player == null) return "{\"duration\":0}";
        long durationMs = player.getDuration();
        double durationSec = durationMs > 0 ? durationMs / 1000.0 : 0;
        return "{\"duration\":" + durationSec + "}";
    }

    public String release() {
        releaseInternal();
        return "{\"released\":true}";
    }

    public String showSurface() {
        MainActivity activity = getActivity();
        if (activity == null || textureView == null) return errorJson("not available");
        activity.runOnUiThread(() -> {
            textureView.setVisibility(android.view.View.VISIBLE);
            textureView.bringToFront();
        });
        return "{\"shown\":true}";
    }

    public String hideSurface() {
        MainActivity activity = getActivity();
        if (activity == null || textureView == null) return errorJson("not available");
        activity.runOnUiThread(() -> {
            textureView.setVisibility(android.view.View.GONE);
        });
        return "{\"hidden\":true}";
    }

    /**
     * 动态设置 TextureView 的位置和大小（像素），用于非全屏时精确覆盖视频区域。
     * @param left   左边距（px）
     * @param top    上边距（px）
     * @param width  宽度（px）
     * @param height 高度（px）
     */
    public String setSurfaceBounds(int left, int top, int width, int height) {
        MainActivity activity = getActivity();
        if (activity == null || textureView == null) return errorJson("not available");
        activity.runOnUiThread(() -> {
            FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(width, height);
            params.leftMargin = left;
            params.topMargin = top;
            textureView.setLayoutParams(params);
            // 不拦截触摸事件，让点击穿透到下层 GeckoView，由 Web 层控制栏操作
            textureView.setClickable(false);
            textureView.setFocusable(false);
            textureView.setVisibility(android.view.View.VISIBLE);
            textureView.bringToFront();
        });
        return "{\"boundsSet\":true}";
    }

    // ── 内部方法 ──

    private void releaseInternal() {
        stopTimeUpdates();
        if (player != null) {
            try {
                player.stop();
                player.release();
            } catch (Exception ignored) {}
            player = null;
        }
        isPrepared = false;
        isPlaying = false;

        // 隐藏 TextureView 并恢复默认布局
        if (textureView != null) {
            MainActivity activity = getActivity();
            if (activity != null) {
                activity.runOnUiThread(() -> {
                    textureView.setVisibility(android.view.View.GONE);
                    // 恢复为全屏 match_parent，供下次使用
                    FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    );
                    params.leftMargin = 0;
                    params.topMargin = 0;
                    textureView.setLayoutParams(params);
                });
            }
        }
    }

    private void startTimeUpdates() {
        stopTimeUpdates();
        timeUpdateRunnable = new Runnable() {
            @Override
            public void run() {
                if (player == null || !isPlaying) return;
                long posMs = player.getCurrentPosition();
                long durMs = player.getDuration();
                double posSec = posMs / 1000.0;
                double durSec = durMs > 0 ? durMs / 1000.0 : 0;
                emitEvent("nativeVideoTimeUpdate",
                    "{\"currentTime\":" + posSec + ",\"duration\":" + durSec + "}");
                handler.postDelayed(this, 1000);
            }
        };
        handler.postDelayed(timeUpdateRunnable, 1000);
    }

    private void stopTimeUpdates() {
        if (timeUpdateRunnable != null) {
            handler.removeCallbacks(timeUpdateRunnable);
            timeUpdateRunnable = null;
        }
    }

    private void emitEvent(String eventName, String jsonPayload) {
        if (plugin != null) {
            plugin.emitEvent(eventName, jsonPayload);
        }
    }

    private String errorJson(String message) {
        if (message == null) message = "unknown error";
        String safeMsg = message.replace("\"", "'").replace("\n", " ");
        return "{\"__nativeError\":\"" + safeMsg + "\"}";
    }
}
