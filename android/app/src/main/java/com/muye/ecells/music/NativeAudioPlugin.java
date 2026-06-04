package com.muye.ecells.music;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.view.View;
import android.view.WindowManager;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.media.PlaybackParams;
import android.media.audiofx.Equalizer;
import android.media.audiofx.BassBoost;
import android.media.audiofx.Virtualizer;
import android.media.audiofx.PresetReverb;
import android.net.Uri;
import android.os.Build;
import android.Manifest;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

import java.io.IOException;
import java.io.File;
import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Map;
import java.util.List;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;

public class NativeAudioPlugin {

    private static final String TAG = "NativeAudio";

    private final WeakReference<MainActivity> activityRef;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaPlayer mediaPlayer;
    private boolean isPrepared = false;
    private double playbackRate = 1.0;
    private Runnable timeUpdateRunnable;
    private Integer pendingSeekMs = null;
    private String currentCacheKey = null;
    private boolean playingFromCache = false;
    private int lastKnownPositionMs = 0;
    private float volumeValue = 1.0f;
    private String lastAppliedEffect = "none";
    private String lastAppliedEqGains = null;
    private Runnable pendingCacheDownload = null;

    // 缓存所有 Pinia store 的最新数据，供 onPause 时直接同步写盘
    private final Map<String, String> storeCache = new HashMap<>();

    // AudioFX
    private Equalizer equalizer;
    private BassBoost bassBoost;
    private Virtualizer virtualizer;
    private PresetReverb reverb;
    private short eqNumberOfBands = 0;
    private int[] eqCenterFreqs;

    public NativeAudioPlugin(MainActivity activity, Object session) {
        this.activityRef = new WeakReference<>(activity);

        // Listen for lock state changes from LyricOverlayService and forward to JS
        LyricOverlayService.setOnSettingsChangedListener((locked) -> {
            emitEvent("lyricLockChanged", "{\"locked\":" + locked + "}");
        });
    }

    /** 获取 Activity 引用，如果已被回收则返回 null */
    private MainActivity getActivity() {
        MainActivity a = activityRef.get();
        if (a != null && !a.isDestroyed()) return a;
        return null;
    }

    public void handleUri(String uriString) {
        try {
            Uri uri = Uri.parse(uriString);
            String method = uri.getHost();
            Map<String, String> params = new HashMap<>();
            for (String key : uri.getQueryParameterNames()) {
                params.put(key, uri.getQueryParameter(key));
            }
            String callbackId = params.remove("_callbackId");

            switch (method) {
                case "loadAudio":
                    onLoadAudio(params, callbackId);
                    break;
                case "play":
                    onPlay(callbackId);
                    break;
                case "pause":
                    onPause(callbackId);
                    break;
                case "stop":
                    onStop(callbackId);
                    break;
                case "seek":
                    onSeek(params, callbackId);
                    break;
                case "setVolume":
                    onSetVolume(params, callbackId);
                    break;
                case "setRate":
                    onSetRate(params, callbackId);
                    break;
                case "getDuration":
                    onGetDuration(callbackId);
                    break;
                case "getCurrentTime":
                    onGetCurrentTime(callbackId);
                    break;
                case "setLoop":
                    onSetLoop(params, callbackId);
                    break;
                case "unload":
                    onUnload(callbackId);
                    break;
                case "updateMediaMetadata":
                    // Check if this is a lyric overlay command piggybacking on metadata channel
                    if (params.containsKey("__lyricAction")) {
                        onLyricAction(params, callbackId);
                    } else {
                        onUpdateMediaMetadata(params);
                        resolveCallback(callbackId, "{}");
                    }
                    break;
                case "updateMediaPlaybackState":
                    onUpdateMediaPlaybackState(params);
                    resolveCallback(callbackId, "{}");
                    break;
                case "showFloatingLyric":
                    onShowFloatingLyric(params, callbackId);
                    break;
                case "hideFloatingLyric":
                    onHideFloatingLyric(callbackId);
                    break;
                case "updateLyric":
                    onUpdateLyric(params, callbackId);
                    break;
                case "updateLyricSettings":
                    onUpdateLyricSettings(params, callbackId);
                    break;
                case "setLyricTheme":
                    onSetLyricTheme(params, callbackId);
                    break;
                case "checkOverlayPermission":
                    onCheckOverlayPermission(callbackId);
                    break;
                case "requestOverlayPermission":
                    onRequestOverlayPermission(callbackId);
                    break;
                case "checkLyricReady":
                    onCheckLyricReady(callbackId);
                    break;
                case "checkBatteryOptimization":
                    onCheckBatteryOptimization(callbackId);
                    break;
                case "requestBatteryOptimization":
                    onRequestBatteryOptimization(callbackId);
                    break;
                case "getLyricSettings":
                    onGetLyricSettings(callbackId);
                    break;
                case "setOrientation":
                    onSetOrientation(params, callbackId);
                    break;
                default:
                    rejectCallback(callbackId, "Unknown method: " + method);
                    break;
            }
        } catch (Exception e) {
            Log.e(TAG, "handleUri error for " + uriString, e);
            // Try to reject the callback so JS doesn't hang
            try {
                String cbId = null;
                Uri parsed = Uri.parse(uriString);
                cbId = parsed.getQueryParameter("_callbackId");
                if (cbId != null) {
                    rejectCallback(cbId, "Native error: " + e.getClass().getSimpleName() + ": " + e.getMessage());
                }
            } catch (Exception ignored) {}
        }
    }

    // ── Synchronous handler for PromptDelegate bridge ──

    public String handleUriSync(final String uriString) {
        // persistStore 直接执行，不经过主线程调度
        // GeckoView PromptDelegate 在非主线程执行，handler.post + CountDownLatch 会超时导致数据丢失
        if (uriString.startsWith("native://persistStore")) {
            return processPersistStoreSync(uriString);
        }
        // Must run on UI thread for Activity/Service access
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return processUriSync(uriString);
        }
        final String[] result = new String[]{"{}"};
        final CountDownLatch latch = new CountDownLatch(1);
        handler.post(() -> {
            try {
                result[0] = processUriSync(uriString);
            } catch (Exception e) {
                result[0] = "{\"__nativeError\":\"" + e.getClass().getSimpleName() + ": " + e.getMessage() + "\"}";
            }
            latch.countDown();
        });
        try {
            latch.await(3, java.util.concurrent.TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            return "{\"__nativeError\":\"Operation interrupted\"}";
        }
        return result[0];
    }

    // persistStore 专用处理：不依赖主线程调度，直接在调用线程同步写盘
    private String processPersistStoreSync(String uriString) {
        try {
            Uri uri = Uri.parse(uriString);
            Map<String, String> params = new HashMap<>();
            for (String key : uri.getQueryParameterNames()) {
                params.put(key, uri.getQueryParameter(key));
            }
            return onPersistStoreSync(params);
        } catch (Exception e) {
            return "{\"__nativeError\":\"" + e.getMessage().replace("\"", "'") + "\"}";
        }
    }

    private String processUriSync(String uriString) {
        try {
            Uri uri = Uri.parse(uriString);
            String method = uri.getHost();
            Map<String, String> params = new HashMap<>();
            for (String key : uri.getQueryParameterNames()) {
                params.put(key, uri.getQueryParameter(key));
            }
            params.remove("_callbackId");

            switch (method) {
                case "loadAudio": return onLoadAudioSync(params);
                case "play": return onPlaySync();
                case "pause": return onPauseSync();
                case "stop": return onStopSync();
                case "seek": return onSeekSync(params);
                case "setVolume": return onSetVolumeSync(params);
                case "setRate": return onSetRateSync(params);
                case "getDuration": return onGetDurationSync();
                case "getCurrentTime": return onGetCurrentTimeSync();
                case "setLoop": return onSetLoopSync(params);
                case "unload": return onUnloadSync();
                case "updateMediaMetadata":
                    if (params.containsKey("__lyricAction")) {
                        return onLyricActionSync(params);
                    }
                    onUpdateMediaMetadata(params);
                    return "{}";
                case "updateMediaPlaybackState":
                    onUpdateMediaPlaybackState(params);
                    return "{}";
                case "showFloatingLyric": return onShowFloatingLyricSync();
                case "hideFloatingLyric": return onHideFloatingLyricSync();
                case "updateLyric": return onUpdateLyricSync(params);
                case "updateLyricSettings": return onUpdateLyricSettingsSync(params);
                case "setLyricTheme": return onSetLyricThemeSync(params);
                case "checkOverlayPermission": return onCheckOverlayPermissionSync();
                case "requestOverlayPermission": return onRequestOverlayPermissionSync();
                case "checkLyricReady": return onCheckLyricReadySync();
                case "checkBatteryOptimization": return onCheckBatteryOptimizationSync();
                case "requestBatteryOptimization": return onRequestBatteryOptimizationSync();
                case "getLyricSettings": return onGetLyricSettingsSync();
                case "setOrientation": return onSetOrientationSync(params);
                case "setFullScreen": return onSetFullScreenSync(params);
                case "openExternalUrl": return onOpenExternalUrlSync(params);
                case "openAppSettings": return onOpenAppSettingsSync();
                case "getCacheInfo": return onGetCacheInfoSync();
                case "clearCache": return onClearCacheSync();
                case "setCacheSizeLimit": return onSetCacheSizeLimitSync(params);
                case "preloadCache": return onPreloadCacheSync(params);
                // Native lyric engine methods
                case "loadLyrics": return onLoadLyricsSync(params);
                case "setPlaybackState": return onSetPlaybackStateSync(params);
                case "lyricSeekTo": return onLyricSeekToSync(params);
                case "setKeepScreenOn": return onSetKeepScreenOnSync(params);
                // Audio effects
                case "setEqualizer": return onSetEqualizerSync(params);
                case "setAudioEffect": return onSetAudioEffectSync(params);
                // APK update methods
                case "getDeviceAbiInfo": return onGetDeviceAbiInfoSync();
                case "downloadApk": return onDownloadApkSync(params);
                case "cancelApkDownload": return onCancelApkDownloadSync();
                case "installApk": return onInstallApkSync(params);
                case "checkInstallPermission": return onCheckInstallPermissionSync();
                case "requestInstallPermission": return onRequestInstallPermissionSync();
                // Pinia store 持久化到 SharedPreferences（同步写磁盘，绕过 GeckoView localStorage 不刷盘问题）
                case "persistStore": return onPersistStoreSync(params);
                default:
                    return "{\"__nativeError\":\"Unknown method: " + method + "\"}";
            }
        } catch (Exception e) {
            Log.e(TAG, "processUriSync error for " + uriString, e);
            String msg = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            return "{\"__nativeError\":\"" + msg.replace("\"", "'") + "\"}";
        }
    }

    // ── Sync audio helpers ──

    private String onLoadAudioSync(Map<String, String> params) {
        String url = params.get("url");
        if (url == null || url.isEmpty()) return "{\"__nativeError\":\"url is required\"}";
        releasePlayer();
        pendingSeekMs = null;
        currentCacheKey = null;
        playingFromCache = false;

        String hash = params.get("hash");
        String quality = params.get("quality");
        String dataSource = url;

        AudioCacheManager cacheManager = null;
        try {
            cacheManager = AudioCacheManager.getInstance();
        } catch (Exception e) {
            Log.w(TAG, "AudioCacheManager not available, skipping cache");
        }

        if (cacheManager != null && hash != null && !hash.isEmpty()) {
            String cacheKey = cacheManager.buildCacheKey(hash, quality);
            currentCacheKey = cacheKey;

            if (cacheKey != null && cacheManager.isCached(cacheKey)) {
                File cachedFile = cacheManager.getCachedFile(cacheKey);
                if (cachedFile != null) {
                    dataSource = cachedFile.getAbsolutePath();
                    playingFromCache = true;
                    Log.i(TAG, "Playing from cache: " + cacheKey);
                }
            }

            if (!playingFromCache && cacheKey != null) {
                // 延迟 3 秒启动缓存下载，优先保证 MediaPlayer 缓冲，减少带宽竞争
                final String downloadCacheKey = cacheKey;
                final String downloadUrl = url;
                final AudioCacheManager downloadCm = cacheManager;
                Runnable cacheRunnable = () -> {
                    if (downloadCacheKey.equals(currentCacheKey)) {
                        downloadCm.startDownload(downloadCacheKey, downloadUrl, new AudioCacheManager.DownloadProgressCallback() {
                            @Override
                            public void onProgress(String key, float percent) {
                                emitEvent("cacheProgress", "{\"cacheKey\":\"" + key + "\",\"percent\":" + percent + "}");
                            }
                            @Override
                            public void onComplete(String key) {
                                emitEvent("cacheProgress", "{\"cacheKey\":\"" + key + "\",\"percent\":1.0}");
                                switchToCachedSource(key);
                            }
                        });
                        Log.i(TAG, "Delayed cache download started: " + downloadCacheKey);
                    }
                };
                pendingCacheDownload = cacheRunnable;
                handler.postDelayed(cacheRunnable, 3000);
                Log.i(TAG, "Playing from remote, cache download scheduled: " + cacheKey);
            }

            if (playingFromCache && cacheKey != null) {
                emitEvent("cacheProgress", "{\"cacheKey\":\"" + cacheKey + "\",\"percent\":1.0}");
            }
        }

        try {
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build()
            );
            mediaPlayer.setOnPreparedListener(mp -> {
                isPrepared = true;
                double duration = mp.getDuration() / 1000.0;
                emitEvent("durationChange", "{\"duration\":" + duration + "}");
                if (pendingSeekMs != null) {
                    mp.seekTo(pendingSeekMs);
                    pendingSeekMs = null;
                }
            });
            mediaPlayer.setOnCompletionListener(mp -> {
                stopTimeUpdates();
                if (isPrematureCompletion(mp)) {
                    handlePrematureCompletion(mp);
                    return;
                }
                emitEvent("ended", "{}");
            });
            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                stopTimeUpdates();
                // If playing from cache failed, try remote URL as fallback
                if (playingFromCache && currentCacheKey != null) {
                    Log.w(TAG, "Cache playback failed, falling back to remote: " + currentCacheKey);
                    int fallbackPosition = 0;
                    try { fallbackPosition = mp.getCurrentPosition(); } catch (Exception ignored) {}
                    try {
                        AudioCacheManager cm = AudioCacheManager.getInstance();
                        cm.deleteCacheEntry(currentCacheKey);
                    } catch (Exception ignored) {}
                    playingFromCache = false;
                    try {
                        mp.release();
                    } catch (Exception ignored) {}
                    final int seekPosition = fallbackPosition;
                    mediaPlayer = new MediaPlayer();
                    mediaPlayer.setAudioAttributes(
                        new AudioAttributes.Builder()
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .build()
                    );
                    mediaPlayer.setOnPreparedListener(mp2 -> {
                        isPrepared = true;
                        double dur = mp2.getDuration() / 1000.0;
                        emitEvent("durationChange", "{\"duration\":" + dur + "}");
                        if (seekPosition > 0) {
                            mp2.seekTo(seekPosition);
                        } else if (pendingSeekMs != null) {
                            mp2.seekTo(pendingSeekMs);
                            pendingSeekMs = null;
                        }
                        mp2.start();
                        startTimeUpdates();
                        emitEvent("play", "{}");
                    });
                    mediaPlayer.setOnCompletionListener(mp2 -> {
                        stopTimeUpdates();
                        if (isPrematureCompletion(mp2)) {
                            handlePrematureCompletion(mp2);
                            return;
                        }
                        emitEvent("ended", "{}");
                    });
                    mediaPlayer.setOnErrorListener((mp2, w, ex) -> {
                        stopTimeUpdates();
                        emitEvent("error", "{\"what\":" + w + ",\"extra\":" + ex + "}");
                        isPrepared = false;
                        return true;
                    });
                    try {
                        mediaPlayer.setDataSource(url);
                        mediaPlayer.prepareAsync();
                        return true;
                    } catch (IOException e2) {
                        emitEvent("error", "{\"what\":" + what + ",\"extra\":" + extra + "}");
                        isPrepared = false;
                        return true;
                    }
                }
                emitEvent("error", "{\"what\":" + what + ",\"extra\":" + extra + "}");
                isPrepared = false;
                return true;
            });
            mediaPlayer.setOnSeekCompleteListener(mp -> {});
            mediaPlayer.setDataSource(dataSource);
            mediaPlayer.prepareAsync();
            return "{\"loaded\":true,\"fromCache\":" + playingFromCache + "}";
        } catch (IOException e) {
            return "{\"__nativeError\":\"Failed to load audio: " + e.getMessage() + "\"}";
        }
    }

    private String onPlaySync() {
        if (mediaPlayer == null) return "{\"__nativeError\":\"no audio loaded\"}";
        if (isPrepared) {
            mediaPlayer.start();
            startTimeUpdates();
            emitEvent("play", "{}");
        } else {
            mediaPlayer.setOnPreparedListener(mp -> {
                isPrepared = true;
                double duration = mp.getDuration() / 1000.0;
                emitEvent("durationChange", "{\"duration\":" + duration + "}");
                if (pendingSeekMs != null) {
                    mp.seekTo(pendingSeekMs);
                    pendingSeekMs = null;
                }
                mp.start();
                startTimeUpdates();
                emitEvent("play", "{}");
            });
        }
        return "{}";
    }

    private String onPauseSync() {
        if (mediaPlayer != null && mediaPlayer.isPlaying()) {
            mediaPlayer.pause();
            stopTimeUpdates();
            emitEvent("pause", "{}");
        }
        return "{}";
    }

    private String onStopSync() {
        if (mediaPlayer != null && isPrepared) {
            mediaPlayer.stop();
            isPrepared = false;
            stopTimeUpdates();
        }
        return "{}";
    }

    private String onSeekSync(Map<String, String> params) {
        String timeStr = params.get("time");
        if (timeStr == null) return "{\"__nativeError\":\"time is required\"}";
        int ms = (int) (Double.parseDouble(timeStr) * 1000);
        if (mediaPlayer != null && isPrepared) {
            mediaPlayer.seekTo(ms);
        } else if (mediaPlayer != null) {
            pendingSeekMs = ms;
        }
        return "{}";
    }

    private String onSetVolumeSync(Map<String, String> params) {
        String volumeStr = params.get("volume");
        if (volumeStr == null) return "{\"__nativeError\":\"volume is required\"}";
        float v = (float) Math.max(0, Math.min(1, Double.parseDouble(volumeStr)));
        volumeValue = v;
        if (mediaPlayer != null) mediaPlayer.setVolume(v, v);
        return "{}";
    }

    private String onSetRateSync(Map<String, String> params) {
        String rateStr = params.get("rate");
        if (rateStr == null) return "{\"__nativeError\":\"rate is required\"}";
        playbackRate = Math.max(0.1, Math.min(5.0, Double.parseDouble(rateStr)));
        if (mediaPlayer != null && isPrepared) applyPlaybackParams();
        return "{}";
    }

    private String onGetDurationSync() {
        if (mediaPlayer != null && isPrepared) {
            return "{\"duration\":" + (mediaPlayer.getDuration() / 1000.0) + "}";
        }
        return "{\"duration\":0}";
    }

    private String onGetCurrentTimeSync() {
        if (mediaPlayer != null && isPrepared) {
            return "{\"currentTime\":" + (mediaPlayer.getCurrentPosition() / 1000.0) + "}";
        }
        return "{\"currentTime\":0}";
    }

    private String onSetLoopSync(Map<String, String> params) {
        boolean loop = "true".equals(params.get("loop"));
        if (mediaPlayer != null) mediaPlayer.setLooping(loop);
        return "{}";
    }

    private String onUnloadSync() {
        releasePlayer();
        return "{}";
    }

    // ── Sync lyric helpers ──

    private String onLyricActionSync(Map<String, String> params) {
        String action = params.get("__lyricAction");
        if (action == null) return "{\"__nativeError\":\"Missing __lyricAction\"}";
        try {
            switch (action) {
                case "checkPermission": return checkLyricPermissionJson();
                case "requestOverlayPermission": return requestOverlayPermissionSync();
                case "show": return showFloatingLyricSync();
                case "hide": return hideFloatingLyricSync();
                case "updateLyric": return updateLyricSync(params);
                case "updateSettings": return updateLyricSettingsSync(params);
                case "setThemeMode": return onSetLyricThemeSync(params);
                default: return "{\"__nativeError\":\"Unknown lyric action: " + action + "\"}";
            }
        } catch (Exception e) {
            return "{\"__nativeError\":\"" + e.getMessage() + "\"}";
        }
    }

    private String checkLyricPermissionJson() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        boolean overlayGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(a);
        boolean notificationGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
            || a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
        return "{\"overlayGranted\":" + overlayGranted + ",\"notificationGranted\":" + notificationGranted + "}";
    }

    private String requestOverlayPermissionSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent intent = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + a.getPackageName()));
            a.startActivityForResult(intent, 2001);
        }
        return "{}";
    }

    private String showFloatingLyricSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(a)) {
            return "{\"__nativeError\":\"缺少悬浮窗权限\"}";
        }
        Intent serviceIntent = new Intent(a, LyricOverlayService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            a.startForegroundService(serviceIntent);
        } else {
            a.startService(serviceIntent);
        }
        handler.postDelayed(() -> {
            LyricOverlayService service = LyricOverlayService.getInstance();
            if (service != null) service.showOverlay();
        }, 300);
        return "{\"shown\":true}";
    }

    private String hideFloatingLyricSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.hideOverlay();
            a.stopService(new Intent(a, LyricOverlayService.class));
        }
        return "{\"hidden\":true}";
    }

    private String updateLyricSync(Map<String, String> params) {
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.updateLines(
                params.getOrDefault("line1", ""),
                params.getOrDefault("line2", "")
            );
        }
        return "{}";
    }

    private String updateLyricSettingsSync(Map<String, String> params) {
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            int lci = params.containsKey("lightColorIndex") ? Integer.parseInt(params.get("lightColorIndex")) : -1;
            int dci = params.containsKey("darkColorIndex") ? Integer.parseInt(params.get("darkColorIndex")) : -1;
            String tm = params.get("themeMode");
            float fs = params.containsKey("fontSize") ? Float.parseFloat(params.get("fontSize")) : -1;
            boolean dl = params.containsKey("doubleLine") && "true".equals(params.get("doubleLine"));
            Boolean lk = params.containsKey("locked") ? "true".equals(params.get("locked")) : null;
            int wp = params.containsKey("widthPercent") ? Integer.parseInt(params.get("widthPercent")) : -1;
            boolean se = params.containsKey("strokeEnabled") && "true".equals(params.get("strokeEnabled"));
            String al = params.get("alignment");
            service.applySettings(lci, dci, tm, fs, dl, lk, wp, se, al);
        }
        return "{}";
    }

    private String onShowFloatingLyricSync() { return showFloatingLyricSync(); }
    private String onHideFloatingLyricSync() { return hideFloatingLyricSync(); }
    private String onUpdateLyricSync(Map<String, String> p) { return updateLyricSync(p); }
    private String onUpdateLyricSettingsSync(Map<String, String> p) { return updateLyricSettingsSync(p); }
    private String onCheckOverlayPermissionSync() { return checkLyricPermissionJson(); }
    private String onRequestOverlayPermissionSync() { return requestOverlayPermissionSync(); }
    private String onCheckLyricReadySync() { return checkLyricPermissionJson(); }

    private String onGetLyricSettingsSync() {
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            return service.getSettingsSnapshot();
        }
        return "{}";
    }

    private String onSetLyricThemeSync(Map<String, String> params) {
        String mode = params.get("themeMode");
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null && mode != null) {
            service.setThemeMode(mode);
        }
        return "{}";
    }

    // ── Async lyric theme setter ──
    private void onSetLyricTheme(Map<String, String> params, String callbackId) {
        String result = onSetLyricThemeSync(params);
        resolveCallback(callbackId, result);
    }

    private void setLyricTheme(Map<String, String> params, String callbackId) {
        String result = onSetLyricThemeSync(params);
        resolveCallback(callbackId, result);
    }

    // ── Screen orientation ──

    private void onSetOrientation(Map<String, String> params, String callbackId) {
        String result = onSetOrientationSync(params);
        resolveCallback(callbackId, result);
    }

    private String onSetOrientationSync(Map<String, String> params) {
        String orientation = params.get("orientation");
        if (orientation == null) return "{}";
        handler.post(() -> {
            MainActivity a = getActivity();
            if (a == null) return;
            int requestedOrientation;
            switch (orientation) {
                case "portrait":
                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT;
                    a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                    a.getWindow().getDecorView().setSystemUiVisibility(0);
                    break;
                case "landscape":
                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE;
                    a.getWindow().getDecorView().setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    );
                    break;
                default: // "auto"
                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
                    a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                    a.getWindow().getDecorView().setSystemUiVisibility(0);
                    break;
            }
            a.setRequestedOrientation(requestedOrientation);
        });
        return "{}";
    }

    private String onSetFullScreenSync(Map<String, String> params) {
        boolean fullscreen = "true".equals(params.get("fullscreen"));
        handler.post(() -> {
            MainActivity a = getActivity();
            if (a == null) return;
            if (fullscreen) {
                a.getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                );
                a.getWindow().setStatusBarColor(Color.TRANSPARENT);
            } else {
                a.getWindow().getDecorView().setSystemUiVisibility(0);
                a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
            }
        });
        return "{}";
    }

    private String onOpenExternalUrlSync(Map<String, String> params) {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        String url = params.get("url");
        if (url != null && !url.isEmpty()) {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(intent);
        }
        return "{}";
    }

    private String onOpenAppSettingsSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:" + a.getPackageName()));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        a.startActivity(intent);
        return "{}";
    }

    // ── Cache management helpers ──

    private String onGetCacheInfoSync() {
        try {
            AudioCacheManager cm = AudioCacheManager.getInstance();
            long sizeBytes = cm.getCacheSize();
            int fileCount = cm.getCacheFileCount();
            long maxBytes = cm.getMaxSizeBytes();
            return "{\"sizeBytes\":" + sizeBytes + ",\"fileCount\":" + fileCount + ",\"maxSizeBytes\":" + maxBytes + "}";
        } catch (Exception e) {
            return "{\"sizeBytes\":0,\"fileCount\":0,\"maxSizeBytes\":0}";
        }
    }

    private String onClearCacheSync() {
        try {
            AudioCacheManager.getInstance().clearCache();
            return "{\"cleared\":true}";
        } catch (Exception e) {
            return "{\"__nativeError\":\"" + e.getMessage() + "\"}";
        }
    }

    private String onSetCacheSizeLimitSync(Map<String, String> params) {
        String mbStr = params.get("mb");
        if (mbStr == null) return "{\"__nativeError\":\"mb is required\"}";
        try {
            long mb = Long.parseLong(mbStr);
            AudioCacheManager.getInstance().setMaxSize(mb);
            return "{}";
        } catch (Exception e) {
            return "{\"__nativeError\":\"" + e.getMessage() + "\"}";
        }
    }

    private String onPreloadCacheSync(Map<String, String> params) {
        String url = params.get("url");
        String hash = params.get("hash");
        String quality = params.get("quality");
        if (url == null || hash == null) return "{}";
        try {
            AudioCacheManager cm = AudioCacheManager.getInstance();
            String cacheKey = cm.buildCacheKey(hash, quality);
            if (cacheKey != null) cm.preloadCache(cacheKey, url);
        } catch (Exception ignored) {}
        return "{}";
    }

    private String onCheckBatteryOptimizationSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        boolean ignoring = false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.os.PowerManager pm = (android.os.PowerManager) a.getSystemService(Context.POWER_SERVICE);
            ignoring = pm.isIgnoringBatteryOptimizations(a.getPackageName());
        }
        return "{\"ignoring\":" + ignoring + "}";
    }

    private String onRequestBatteryOptimizationSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            intent.setData(Uri.parse("package:" + a.getPackageName()));
            a.startActivity(intent);
        }
        return "{}";
    }

    // ── Native lyric engine handlers ──

    private String onLoadLyricsSync(Map<String, String> params) {
        String lyricsJson = params.get("lyrics");
        long currentTimeMs = 0;
        try { currentTimeMs = Long.parseLong(params.getOrDefault("currentTimeMs", "0")); } catch (NumberFormatException ignored) {}
        boolean playing = "true".equals(params.get("isPlaying"));

        List<LyricOverlayService.LyricLineData> lines = new ArrayList<>();
        if (lyricsJson != null && !lyricsJson.isEmpty()) {
            try {
                org.json.JSONArray arr = new org.json.JSONArray(lyricsJson);
                for (int i = 0; i < arr.length(); i++) {
                    org.json.JSONObject obj = arr.getJSONObject(i);
                    long t = obj.optLong("timeMs", 0);
                    String txt = obj.optString("text", "");
                    String trans = obj.optString("translation", "");
                    lines.add(new LyricOverlayService.LyricLineData(t, txt, trans));
                }
            } catch (Exception e) {
                Log.e(TAG, "Failed to parse lyrics JSON", e);
            }
        }

        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.loadLyrics(lines, currentTimeMs, playing);
        }
        return "{\"loaded\":true,\"lineCount\":" + lines.size() + "}";
    }

    private String onSetPlaybackStateSync(Map<String, String> params) {
        boolean playing = "true".equals(params.get("isPlaying"));
        long currentTimeMs = 0;
        try { currentTimeMs = Long.parseLong(params.getOrDefault("currentTimeMs", "0")); } catch (NumberFormatException ignored) {}

        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.setPlaybackState(playing, currentTimeMs);
        }
        return "{}";
    }

    private String onLyricSeekToSync(Map<String, String> params) {
        long timeMs = 0;
        try { timeMs = Long.parseLong(params.getOrDefault("currentTimeMs", "0")); } catch (NumberFormatException ignored) {}

        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.seekTo(timeMs);
        }
        return "{}";
    }

    private String onSetKeepScreenOnSync(Map<String, String> params) {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        boolean keepOn = "true".equals(params.get("keepOn"));
        a.setKeepScreenOn(keepOn);
        return "{}";
    }

    // ── APK update methods ──

    private String onGetDeviceAbiInfoSync() {
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr == null) return "{\"__nativeError\":\"ApkUpdateManager not initialized\"}";
        return mgr.getDeviceAbiInfo();
    }

    private String onDownloadApkSync(Map<String, String> params) {
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr == null) return "{\"__nativeError\":\"ApkUpdateManager not initialized\"}";
        String url = params.get("url");
        String fileName = params.get("fileName");
        if (url == null || url.isEmpty() || fileName == null || fileName.isEmpty()) {
            return "{\"__nativeError\":\"url and fileName are required\"}";
        }
        mgr.startDownloadApk(url, fileName);
        return "{\"started\":true}";
    }

    private String onCancelApkDownloadSync() {
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr != null) mgr.cancelDownload();
        return "{}";
    }

    private String onInstallApkSync(Map<String, String> params) {
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr == null) return "{\"__nativeError\":\"ApkUpdateManager not initialized\"}";
        String filePath = params.get("filePath");
        if (filePath == null || filePath.isEmpty()) {
            return "{\"__nativeError\":\"filePath is required\"}";
        }
        String error = mgr.installApk(filePath);
        if (error != null) {
            return "{\"__nativeError\":\"" + error.replace("\"", "'") + "\"}";
        }
        return "{\"installing\":true}";
    }

    private String onCheckInstallPermissionSync() {
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr == null) return "{\"granted\":false}";
        return "{\"granted\":" + mgr.canInstallApk() + "}";
    }

    private String onRequestInstallPermissionSync() {
        MainActivity a = getActivity();
        if (a == null) return "{}";
        ApkUpdateManager mgr = ApkUpdateManager.getInstance();
        if (mgr == null) return "{}";
        Intent intent = mgr.buildInstallPermissionIntent();
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(intent);
        }
        return "{}";
    }

    // -- Method implementations --

    private void onLoadAudio(Map<String, String> params, String callbackId) {
        String url = params.get("url");
        if (url == null || url.isEmpty()) {
            rejectCallback(callbackId, "url is required");
            return;
        }

        releasePlayer();

        try {
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build()
            );

            mediaPlayer.setOnPreparedListener(mp -> {
                isPrepared = true;
                double duration = mp.getDuration() / 1000.0;
                emitEvent("durationChange", "{\"duration\":" + duration + "}");
                if (pendingSeekMs != null) {
                    mp.seekTo(pendingSeekMs);
                    pendingSeekMs = null;
                }
            });

            mediaPlayer.setOnCompletionListener(mp -> {
                stopTimeUpdates();
                if (isPrematureCompletion(mp)) {
                    handlePrematureCompletion(mp);
                    return;
                }
                emitEvent("ended", "{}");
            });

            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                stopTimeUpdates();
                emitEvent("error", "{\"what\":" + what + ",\"extra\":" + extra + "}");
                isPrepared = false;
                return true;
            });

            mediaPlayer.setOnSeekCompleteListener(mp -> {});

            mediaPlayer.setDataSource(url);
            mediaPlayer.prepareAsync();

            resolveCallback(callbackId, "{\"loaded\":true}");

        } catch (IOException e) {
            rejectCallback(callbackId, "Failed to load audio: " + e.getMessage());
        }
    }

    private void onPlay(String callbackId) {
        if (mediaPlayer == null) {
            rejectCallback(callbackId, "no audio loaded");
            return;
        }

        if (isPrepared) {
            mediaPlayer.start();
            startTimeUpdates();
            emitEvent("play", "{}");
            resolveCallback(callbackId, "{}");
        } else {
            mediaPlayer.setOnPreparedListener(mp -> {
                isPrepared = true;
                double duration = mp.getDuration() / 1000.0;
                emitEvent("durationChange", "{\"duration\":" + duration + "}");
                if (pendingSeekMs != null) {
                    mp.seekTo(pendingSeekMs);
                    pendingSeekMs = null;
                }
                mp.start();
                startTimeUpdates();
                emitEvent("play", "{}");
            });
            resolveCallback(callbackId, "{}");
        }
    }

    private void onPause(String callbackId) {
        if (mediaPlayer != null && mediaPlayer.isPlaying()) {
            mediaPlayer.pause();
            stopTimeUpdates();
            emitEvent("pause", "{}");
        }
        resolveCallback(callbackId, "{}");
    }

    private void onStop(String callbackId) {
        if (mediaPlayer != null && isPrepared) {
            mediaPlayer.stop();
            isPrepared = false;
            stopTimeUpdates();
        }
        resolveCallback(callbackId, "{}");
    }

    private void onSeek(Map<String, String> params, String callbackId) {
        String timeStr = params.get("time");
        if (timeStr == null) {
            rejectCallback(callbackId, "time is required");
            return;
        }
        int ms = (int) (Double.parseDouble(timeStr) * 1000);
        if (mediaPlayer != null && isPrepared) {
            mediaPlayer.seekTo(ms);
        } else if (mediaPlayer != null) {
            pendingSeekMs = ms;
        }
        resolveCallback(callbackId, "{}");
    }

    private void onSetVolume(Map<String, String> params, String callbackId) {
        String volumeStr = params.get("volume");
        if (volumeStr == null) {
            rejectCallback(callbackId, "volume is required");
            return;
        }
        float v = (float) Math.max(0, Math.min(1, Double.parseDouble(volumeStr)));
        if (mediaPlayer != null) {
            mediaPlayer.setVolume(v, v);
        }
        resolveCallback(callbackId, "{}");
    }

    private void onSetRate(Map<String, String> params, String callbackId) {
        String rateStr = params.get("rate");
        if (rateStr == null) {
            rejectCallback(callbackId, "rate is required");
            return;
        }
        playbackRate = Math.max(0.1, Math.min(5.0, Double.parseDouble(rateStr)));
        if (mediaPlayer != null && isPrepared) {
            applyPlaybackParams();
        }
        resolveCallback(callbackId, "{}");
    }

    private void onGetDuration(String callbackId) {
        if (mediaPlayer != null && isPrepared) {
            double duration = mediaPlayer.getDuration() / 1000.0;
            resolveCallback(callbackId, "{\"duration\":" + duration + "}");
        } else {
            resolveCallback(callbackId, "{\"duration\":0}");
        }
    }

    private void onGetCurrentTime(String callbackId) {
        if (mediaPlayer != null && isPrepared) {
            double time = mediaPlayer.getCurrentPosition() / 1000.0;
            resolveCallback(callbackId, "{\"currentTime\":" + time + "}");
        } else {
            resolveCallback(callbackId, "{\"currentTime\":0}");
        }
    }

    private void onSetLoop(Map<String, String> params, String callbackId) {
        boolean loop = "true".equals(params.get("loop"));
        if (mediaPlayer != null) {
            mediaPlayer.setLooping(loop);
        }
        resolveCallback(callbackId, "{}");
    }

    private void onUnload(String callbackId) {
        releasePlayer();
        resolveCallback(callbackId, "{}");
    }

    // -- Playback params --

    private void applyPlaybackParams() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            try {
                PlaybackParams params = new PlaybackParams();
                params.setSpeed((float) playbackRate);
                mediaPlayer.setPlaybackParams(params);
            } catch (Exception e) {
                Log.w(TAG, "PlaybackParams not supported", e);
            }
        }
    }

    // -- Premature completion guard --

    private boolean isPrematureCompletion(MediaPlayer mp) {
        try {
            if (mp != null) {
                int duration = mp.getDuration();
                int position = mp.getCurrentPosition();
                if (duration > 0 && position < duration - 3000) {
                    // onCompletion 时 getCurrentPosition() 在某些设备上返回不准确的值，
                    // 使用最后已知位置作为后备判断
                    if (lastKnownPositionMs > 0 && lastKnownPositionMs >= duration - 3000) {
                        Log.i(TAG, "Legitimate completion: lastKnownPos=" + lastKnownPositionMs
                            + "ms, dur=" + duration + "ms (currentPos=" + position + "ms was inaccurate)");
                        return false;
                    }
                    Log.w(TAG, "Premature onCompletion: pos=" + position + "ms, dur=" + duration + "ms");
                    return true;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to check completion position", e);
        }
        return false;
    }

    private void handlePrematureCompletion(MediaPlayer mp) {
        if (mp == null) {
            emitEvent("error", "{\"what\":0,\"extra\":0,\"reason\":\"premature_completion\"}");
            isPrepared = false;
            return;
        }
        try {
            int position = mp.getCurrentPosition();
            mp.seekTo(position);
            mp.start();
            startTimeUpdates();
            Log.i(TAG, "Recovered from premature completion at " + position + "ms");
        } catch (Exception e) {
            Log.e(TAG, "Failed to recover from premature completion", e);
            emitEvent("error", "{\"what\":0,\"extra\":0,\"reason\":\"premature_completion\"}");
            isPrepared = false;
        }
    }

    // -- Time updates --

    /** 前台更新间隔 (ms) */
    private static final long TIME_UPDATE_INTERVAL_FOREGROUND = 500;
    /** 后台更新间隔 (ms) — 降低 evalJs 调用频率以省电 */
    private static final long TIME_UPDATE_INTERVAL_BACKGROUND = 3000;

    private void startTimeUpdates() {
        stopTimeUpdates();
        timeUpdateRunnable = new Runnable() {
            @Override
            public void run() {
                if (mediaPlayer != null && mediaPlayer.isPlaying()) {
                    int pos = mediaPlayer.getCurrentPosition();
                    lastKnownPositionMs = pos;
                    double time = pos / 1000.0;
                    emitEvent("timeUpdate", "{\"currentTime\":" + time + "}");
                }
                MainActivity a = getActivity();
                boolean isForeground = a != null && !a.isFinishing();
                long interval = isForeground
                    ? TIME_UPDATE_INTERVAL_FOREGROUND
                    : TIME_UPDATE_INTERVAL_BACKGROUND;
                handler.postDelayed(this, interval);
            }
        };
        handler.post(timeUpdateRunnable);
    }

    private void stopTimeUpdates() {
        if (timeUpdateRunnable != null) {
            handler.removeCallbacks(timeUpdateRunnable);
            timeUpdateRunnable = null;
        }
    }

    // -- Bridge communication --

    private void resolveCallback(String callbackId, String jsonResult) {
        if (callbackId == null) return;
        runOnUi(() -> {
            MainActivity a = getActivity();
            if (a == null) return;
            a.evalJs(
                "if(window.NativeBridge&&window.NativeBridge._callbacks['" + callbackId + "']){" +
                "window.NativeBridge._callbacks['" + callbackId + "'].resolve(" + jsonResult + ");" +
                "delete window.NativeBridge._callbacks['" + callbackId + "'];}"
            );
        });
    }

    private void rejectCallback(String callbackId, String errorMessage) {
        if (callbackId == null) return;
        String escaped = errorMessage.replace("\\", "\\\\").replace("'", "\\'");
        runOnUi(() -> {
            MainActivity a = getActivity();
            if (a == null) return;
            a.evalJs(
                "if(window.NativeBridge&&window.NativeBridge._callbacks['" + callbackId + "']){" +
                "window.NativeBridge._callbacks['" + callbackId + "'].reject(" +
                "new Error('" + escaped + "'));" +
                "delete window.NativeBridge._callbacks['" + callbackId + "'];}"
            );
        });
    }

    void emitEvent(String eventName, String jsonPayload) {
        runOnUi(() -> {
            MainActivity a = getActivity();
            if (a == null) return;
            a.evalJs(
                "if(window.NativeBridge&&window.NativeBridge._listeners['" + eventName + "']){" +
                "window.NativeBridge._listeners['" + eventName + "'].forEach(function(cb){" +
                "cb(" + jsonPayload + ");});}"
            );
        });
    }

    private void runOnUi(Runnable r) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            r.run();
        } else {
            handler.post(r);
        }
    }

    // -- Media notification helpers --

    // ── Lyric action dispatcher (piggybacks on updateMediaMetadata bridge) ──

    private void onLyricAction(Map<String, String> params, String callbackId) {
        String action = params.get("__lyricAction");
        Log.i(TAG, "Lyric action received: " + action);
        try {
            switch (action) {
                case "checkPermission": {
                    MainActivity a = getActivity();
                    if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
                    boolean overlayGranted = true;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        overlayGranted = Settings.canDrawOverlays(a);
                    }
                    boolean notificationGranted = true;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        notificationGranted = a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                            == PackageManager.PERMISSION_GRANTED;
                    }
                    resolveCallback(callbackId, "{\"overlayGranted\":" + overlayGranted
                        + ",\"notificationGranted\":" + notificationGranted + "}");
                    break;
                }
                case "requestOverlayPermission": {
                    MainActivity a = getActivity();
                    if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Intent intent = new Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:" + a.getPackageName())
                        );
                        a.startActivityForResult(intent, 2001);
                    }
                    resolveCallback(callbackId, "{}");
                    break;
                }
                case "show": {
                    MainActivity a = getActivity();
                    if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(a)) {
                        rejectCallback(callbackId, "缺少悬浮窗权限");
                        return;
                    }
                    Intent serviceIntent = new Intent(a, LyricOverlayService.class);
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        a.startForegroundService(serviceIntent);
                    } else {
                        a.startService(serviceIntent);
                    }
                    handler.postDelayed(() -> {
                        try {
                            LyricOverlayService service = LyricOverlayService.getInstance();
                            if (service != null) {
                                service.showOverlay();
                                resolveCallback(callbackId, "{\"shown\":true}");
                            } else {
                                rejectCallback(callbackId, "服务启动失败");
                            }
                        } catch (Exception e) {
                            rejectCallback(callbackId, "悬浮窗显示失败: " + e.getMessage());
                        }
                    }, 300);
                    break;
                }
                case "hide": {
                    MainActivity a = getActivity();
                    if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
                    LyricOverlayService service = LyricOverlayService.getInstance();
                    if (service != null) {
                        service.hideOverlay();
                        a.stopService(new Intent(a, LyricOverlayService.class));
                    }
                    resolveCallback(callbackId, "{\"hidden\":true}");
                    break;
                }
                case "updateLyric": {
                    String line1 = params.getOrDefault("line1", "");
                    String line2 = params.getOrDefault("line2", "");
                    LyricOverlayService service = LyricOverlayService.getInstance();
                    if (service != null) {
                        service.updateLines(line1, line2);
                    }
                    resolveCallback(callbackId, "{}");
                    break;
                }
                case "setThemeMode": {
                    setLyricTheme(params, callbackId);
                    break;
                }
                case "updateSettings": {
                    LyricOverlayService service = LyricOverlayService.getInstance();
                    if (service != null) {
                        int lightColorIndex = params.containsKey("lightColorIndex")
                            ? Integer.parseInt(params.get("lightColorIndex")) : -1;
                        int darkColorIndex = params.containsKey("darkColorIndex")
                            ? Integer.parseInt(params.get("darkColorIndex")) : -1;
                        String themeMode = params.get("themeMode");
                        float fontSize = params.containsKey("fontSize")
                            ? Float.parseFloat(params.get("fontSize")) : -1;
                        boolean doubleLine = params.containsKey("doubleLine")
                            && "true".equals(params.get("doubleLine"));
                        Boolean locked = params.containsKey("locked")
                            ? "true".equals(params.get("locked")) : null;
                        int widthPercent = params.containsKey("widthPercent")
                            ? Integer.parseInt(params.get("widthPercent")) : -1;
                        boolean strokeEnabled = params.containsKey("strokeEnabled")
                            && "true".equals(params.get("strokeEnabled"));
                        String alignment = params.get("alignment");
                        service.applySettings(lightColorIndex, darkColorIndex, themeMode, fontSize, doubleLine, locked, widthPercent, strokeEnabled, alignment);
                    }
                    resolveCallback(callbackId, "{}");
                    break;
                }
                default:
                    rejectCallback(callbackId, "Unknown lyric action: " + action);
                    break;
            }
        } catch (Exception e) {
            Log.e(TAG, "Lyric action failed: " + action, e);
            rejectCallback(callbackId, "操作失败: " + e.getClass().getSimpleName() + " " + e.getMessage());
        }
    }

    private void onShowFloatingLyric(Map<String, String> params, String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        // Check overlay permission BEFORE starting service
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(a)) {
                rejectCallback(callbackId, "Overlay permission not granted");
                return;
            }
        }

        try {
            Intent serviceIntent = new Intent(a, LyricOverlayService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                a.startForegroundService(serviceIntent);
            } else {
                a.startService(serviceIntent);
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to start LyricOverlayService", e);
            rejectCallback(callbackId, "Service start failed: " + e.getMessage());
            return;
        }

        // Give the service a moment to start, then show overlay
        handler.postDelayed(() -> {
            try {
                LyricOverlayService service = LyricOverlayService.getInstance();
                if (service != null) {
                    service.showOverlay();
                    resolveCallback(callbackId, "{\"shown\":true}");
                } else {
                    rejectCallback(callbackId, "Service instance not available");
                }
            } catch (Exception e) {
                Log.e(TAG, "Failed to show overlay", e);
                rejectCallback(callbackId, "Overlay failed: " + e.getMessage());
            }
        }, 300);
    }

    private void onHideFloatingLyric(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.hideOverlay();
            a.stopService(new Intent(a, LyricOverlayService.class));
        }
        resolveCallback(callbackId, "{\"hidden\":true}");
    }

    private void onUpdateLyric(Map<String, String> params, String callbackId) {
        String text1 = params.getOrDefault("line1", "");
        String text2 = params.getOrDefault("line2", "");
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            service.updateLines(text1, text2);
        }
        resolveCallback(callbackId, "{}");
    }

    private void onUpdateLyricSettings(Map<String, String> params, String callbackId) {
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service == null) {
            resolveCallback(callbackId, "{}");
            return;
        }
        int lightColorIndex = params.containsKey("lightColorIndex")
            ? Integer.parseInt(params.get("lightColorIndex")) : -1;
        int darkColorIndex = params.containsKey("darkColorIndex")
            ? Integer.parseInt(params.get("darkColorIndex")) : -1;
        String themeMode = params.get("themeMode");
        float fontSize = params.containsKey("fontSize")
            ? Float.parseFloat(params.get("fontSize")) : -1;
        boolean doubleLine = params.containsKey("doubleLine")
            && "true".equals(params.get("doubleLine"));
        Boolean locked = params.containsKey("locked")
            ? "true".equals(params.get("locked")) : null;
        int widthPercent = params.containsKey("widthPercent")
            ? Integer.parseInt(params.get("widthPercent")) : -1;
        boolean strokeEnabled = params.containsKey("strokeEnabled")
            && "true".equals(params.get("strokeEnabled"));
        String alignment = params.get("alignment");

        service.applySettings(lightColorIndex, darkColorIndex, themeMode, fontSize, doubleLine, locked, widthPercent, strokeEnabled, alignment);
        resolveCallback(callbackId, "{}");
    }

    private void onCheckOverlayPermission(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        boolean granted;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            granted = Settings.canDrawOverlays(a);
        } else {
            granted = true;
        }
        resolveCallback(callbackId, "{\"granted\":" + granted + "}");
    }

    private void onRequestOverlayPermission(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent intent = new Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + a.getPackageName())
            );
            a.startActivityForResult(intent, 2001);
        }
        resolveCallback(callbackId, "{}");
    }

    private void onCheckLyricReady(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        boolean overlayGranted = true;
        boolean notificationGranted = true;

        // Check overlay permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            overlayGranted = Settings.canDrawOverlays(a);
        }

        // Check notification permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationGranted = a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED;
        }

        resolveCallback(callbackId, "{\"overlayGranted\":" + overlayGranted
            + ",\"notificationGranted\":" + notificationGranted + "}");
    }

    private void onGetLyricSettings(String callbackId) {
        LyricOverlayService service = LyricOverlayService.getInstance();
        if (service != null) {
            resolveCallback(callbackId, service.getSettingsSnapshot());
        } else {
            resolveCallback(callbackId, "{}");
        }
    }

    private void onCheckBatteryOptimization(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        boolean ignoring = false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.os.PowerManager pm = (android.os.PowerManager) a.getSystemService(Context.POWER_SERVICE);
            ignoring = pm.isIgnoringBatteryOptimizations(a.getPackageName());
        }
        resolveCallback(callbackId, "{\"ignoring\":" + ignoring + "}");
    }

    private void onRequestBatteryOptimization(String callbackId) {
        MainActivity a = getActivity();
        if (a == null) { rejectCallback(callbackId, "Activity is destroyed"); return; }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            intent.setData(Uri.parse("package:" + a.getPackageName()));
            a.startActivity(intent);
        }
        resolveCallback(callbackId, "{}");
    }

    private void onUpdateMediaMetadata(Map<String, String> params) {
        MainActivity a = getActivity();
        if (a == null) return;
        String title = params.getOrDefault("title", "");
        String artist = params.getOrDefault("artist", "");
        String coverUrl = params.getOrDefault("coverUrl", "");
        long durationMs = 0;
        try { durationMs = Long.parseLong(params.getOrDefault("durationMs", "0")); } catch (NumberFormatException ignored) {}
        MediaNotificationService service = ensureMediaService();
        if (service != null) {
            service.setActivity(a);
            service.updateMetadata(title, artist, coverUrl, durationMs);
        }
    }

    private void onUpdateMediaPlaybackState(Map<String, String> params) {
        MainActivity a = getActivity();
        if (a == null) return;
        boolean playing = "true".equals(params.getOrDefault("isPlaying", "false"));
        long positionMs = 0;
        long durationMs = 0;
        try { positionMs = Long.parseLong(params.getOrDefault("positionMs", "0")); } catch (NumberFormatException ignored) {}
        try { durationMs = Long.parseLong(params.getOrDefault("durationMs", "0")); } catch (NumberFormatException ignored) {}
        MediaNotificationService service = ensureMediaService();
        if (service != null) {
            service.setActivity(a);
            service.updatePlaybackState(playing, positionMs, durationMs);
        }
    }

    /**
     * 确保 MediaNotificationService 正在运行。如果静态实例为 null（服务被系统杀死），
     * 尝试重新启动。返回服务实例，如果无法启动则返回 null。
     */
    private MediaNotificationService ensureMediaService() {
        MediaNotificationService service = MediaNotificationService.getInstance();
        if (service != null) return service;

        MainActivity a = getActivity();
        if (a == null) return null;

        Log.w(TAG, "MediaNotificationService instance is null, attempting restart");
        try {
            Intent serviceIntent = new Intent(a, MediaNotificationService.class);
            MediaNotificationService.setPendingActivity(a);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                a.startForegroundService(serviceIntent);
            } else {
                a.startService(serviceIntent);
            }
            service = MediaNotificationService.getInstance();
        } catch (Exception e) {
            Log.e(TAG, "Failed to restart MediaNotificationService", e);
        }
        return service;
    }

    // -- Pinia store 持久化到 SharedPreferences --

    private String onPersistStoreSync(Map<String, String> params) {
        String storeId = params.get("storeId");
        String data = params.get("data");
        if (storeId == null || data == null) {
            return "{\"__nativeError\":\"storeId and data are required\"}";
        }
        try {
            MainActivity a = getActivity();
            if (a == null) return "{\"__nativeError\":\"activity destroyed\"}";
            // 线程安全：先更新内存缓存
            synchronized (storeCache) {
                storeCache.put(storeId, data);
            }
            boolean ok = a.getSharedPreferences("pinia_stores", Context.MODE_PRIVATE)
                .edit()
                .putString(storeId, data)
                .commit(); // commit() 同步写磁盘，确保数据落盘
            if (!ok) {
                Log.e(TAG, "persistStore commit failed for " + storeId);
                return "{\"__nativeError\":\"commit failed\"}";
            }
            return "{\"ok\":true}";
        } catch (Exception e) {
            return "{\"__nativeError\":\"" + e.getMessage().replace("\"", "'") + "\"}";
        }
    }

    // onPause 时由 MainActivity 调用，直接从内存缓存同步写盘，完全不依赖 JS 层的 evalJs
    public void persistAllCachedStores() {
        MainActivity a = getActivity();
        if (a == null) return;
        android.content.SharedPreferences sp = a.getSharedPreferences("pinia_stores", Context.MODE_PRIVATE);
        android.content.SharedPreferences.Editor editor = sp.edit();
        synchronized (storeCache) {
            for (Map.Entry<String, String> entry : storeCache.entrySet()) {
                editor.putString(entry.getKey(), entry.getValue());
            }
        }
        boolean ok = editor.commit();
        if (!ok) {
            Log.e(TAG, "persistAllCachedStores commit failed");
        }
    }

    // -- Cleanup --

    private void releasePlayer() {
        stopTimeUpdates();
        pendingSeekMs = null;
        lastKnownPositionMs = 0;
        releaseAudioEffects();
        if (pendingCacheDownload != null) {
            handler.removeCallbacks(pendingCacheDownload);
            pendingCacheDownload = null;
        }
        if (mediaPlayer != null) {
            try {
                mediaPlayer.release();
            } catch (Exception ignored) {}
            mediaPlayer = null;
        }
        isPrepared = false;
    }

    public void release() {
        releasePlayer();
    }

    // ── AudioFX: Equalizer & Effects ──

    private String onSetEqualizerSync(Map<String, String> params) {
        String gainsStr = params.get("gains");
        if (gainsStr == null || gainsStr.isEmpty()) return "{\"__nativeError\":\"gains is required\"}";
        if (mediaPlayer == null) return "{\"__nativeError\":\"no audio loaded\"}";
        lastAppliedEqGains = gainsStr;

        try {
            if (equalizer == null) {
                int sessionId = mediaPlayer.getAudioSessionId();
                equalizer = new Equalizer(0, sessionId);
                eqNumberOfBands = equalizer.getNumberOfBands();
                eqCenterFreqs = new int[eqNumberOfBands];
                for (short i = 0; i < eqNumberOfBands; i++) {
                    eqCenterFreqs[i] = equalizer.getCenterFreq(i);
                }
                equalizer.setEnabled(true);
            }

            String[] gainStrs = gainsStr.split(",");
            int[] targetFreqs = {60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000};

            for (int i = 0; i < Math.min(gainStrs.length, 10); i++) {
                float gainDb;
                try { gainDb = Float.parseFloat(gainStrs[i].trim()); } catch (NumberFormatException e) { continue; }
                short bandIdx = findClosestBand(targetFreqs[i]);
                if (bandIdx >= 0) {
                    short[] range = equalizer.getBandLevelRange();
                    short millidB = (short) Math.max(range[0], Math.min(range[1], (int)(gainDb * 100)));
                    equalizer.setBandLevel(bandIdx, millidB);
                }
            }
            Log.i(TAG, "EQ applied: " + gainsStr);
            return "{\"applied\":true}";
        } catch (Exception e) {
            Log.e(TAG, "Failed to set equalizer", e);
            return "{\"__nativeError\":\"" + e.getMessage().replace("\"", "'") + "\"}";
        }
    }

    private String onSetAudioEffectSync(Map<String, String> params) {
        String effect = params.get("effect");
        if (effect == null) return "{\"__nativeError\":\"effect is required\"}";
        if (mediaPlayer == null) return "{\"__nativeError\":\"no audio loaded\"}";
        lastAppliedEffect = effect;

        try {
            int sessionId = mediaPlayer.getAudioSessionId();
            releaseAudioEffects();

            switch (effect) {
                case "viper_atmos":
                    virtualizer = new Virtualizer(0, sessionId);
                    virtualizer.setStrength((short) 900);
                    virtualizer.setEnabled(true);
                    Log.i(TAG, "Applied Virtualizer for atmos");
                    break;
                case "viper_tape":
                    reverb = new PresetReverb(0, sessionId);
                    reverb.setPreset(PresetReverb.PRESET_PLATE);
                    reverb.setEnabled(true);
                    Log.i(TAG, "Applied PresetReverb for tape");
                    break;
                case "viper_clear":
                    applyEqPresetEffect(sessionId, new int[]{0, 0, 0, 0, 0, 0, 0, 4, 4, 4});
                    Log.i(TAG, "Applied high-freq boost for clear");
                    break;
                case "none":
                default:
                    Log.i(TAG, "Audio effects cleared");
                    break;
            }
            return "{\"applied\":true,\"effect\":\"" + effect + "\"}";
        } catch (Exception e) {
            Log.e(TAG, "Failed to set audio effect: " + effect, e);
            return "{\"__nativeError\":\"" + e.getMessage().replace("\"", "'") + "\"}";
        }
    }

    private void applyEqPresetEffect(int sessionId, int[] gains) {
        try {
            if (equalizer == null) {
                equalizer = new Equalizer(0, sessionId);
                eqNumberOfBands = equalizer.getNumberOfBands();
                eqCenterFreqs = new int[eqNumberOfBands];
                for (short i = 0; i < eqNumberOfBands; i++) {
                    eqCenterFreqs[i] = equalizer.getCenterFreq(i);
                }
                equalizer.setEnabled(true);
            }
            int[] targetFreqs = {60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000};
            for (int i = 0; i < Math.min(gains.length, targetFreqs.length); i++) {
                short bandIdx = findClosestBand(targetFreqs[i]);
                if (bandIdx >= 0) {
                    short[] range = equalizer.getBandLevelRange();
                    short millidB = (short) Math.max(range[0], Math.min(range[1], gains[i] * 100));
                    equalizer.setBandLevel(bandIdx, millidB);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to apply EQ preset effect", e);
        }
    }

    private short findClosestBand(int targetFreqHz) {
        if (eqNumberOfBands == 0 || eqCenterFreqs == null) return -1;
        int targetMilliHz = targetFreqHz * 1000;
        short closest = 0;
        int minDelta = Integer.MAX_VALUE;
        for (short i = 0; i < eqNumberOfBands; i++) {
            int delta = Math.abs(eqCenterFreqs[i] - targetMilliHz);
            if (delta < minDelta) {
                minDelta = delta;
                closest = i;
            }
        }
        return closest;
    }

    private void releaseAudioEffects() {
        if (equalizer != null) {
            try { equalizer.release(); } catch (Exception ignored) {}
            equalizer = null;
            eqNumberOfBands = 0;
            eqCenterFreqs = null;
        }
        if (bassBoost != null) {
            try { bassBoost.release(); } catch (Exception ignored) {}
            bassBoost = null;
        }
        if (virtualizer != null) {
            try { virtualizer.release(); } catch (Exception ignored) {}
            virtualizer = null;
        }
        if (reverb != null) {
            try { reverb.release(); } catch (Exception ignored) {}
            reverb = null;
        }
    }

    // ── Cache-to-local seamless switch ──

    /**
     * 缓存下载完成后，将 MediaPlayer 的数据源从远程 URL 切换到本地缓存文件。
     * 由于 MediaPlayer 不支持运行时 setDataSource，需创建新实例。
     */
    private void switchToCachedSource(String cacheKey) {
        if (cacheKey == null || !cacheKey.equals(currentCacheKey)) return;
        if (playingFromCache) return;
        if (mediaPlayer == null || !isPrepared) return;

        try {
            AudioCacheManager cm = AudioCacheManager.getInstance();
            File cachedFile = cm.getCachedFile(cacheKey);
            if (cachedFile == null) return;

            int currentPositionMs = mediaPlayer.getCurrentPosition();
            boolean wasPlaying = mediaPlayer.isPlaying();
            float currentVolume = volumeValue;

            final MediaPlayer oldPlayer = mediaPlayer;
            stopTimeUpdates();

            MediaPlayer newPlayer = new MediaPlayer();
            newPlayer.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build()
            );

            newPlayer.setOnPreparedListener(mp -> {
                isPrepared = true;
                double duration = mp.getDuration() / 1000.0;
                emitEvent("durationChange", "{\"duration\":" + duration + "}");

                if (currentPositionMs > 0) {
                    mp.seekTo(currentPositionMs);
                }
                mp.setVolume(currentVolume, currentVolume);
                if (wasPlaying) {
                    mp.start();
                    startTimeUpdates();
                }
                playingFromCache = true;
                reapplyAudioEffects(mp.getAudioSessionId());
                Log.i(TAG, "Seamless switch to cache: " + cacheKey + " at " + currentPositionMs + "ms");
            });

            newPlayer.setOnCompletionListener(mp -> {
                stopTimeUpdates();
                if (isPrematureCompletion(mp)) {
                    handlePrematureCompletion(mp);
                    return;
                }
                emitEvent("ended", "{}");
            });

            newPlayer.setOnErrorListener((mp, what, extra) -> {
                stopTimeUpdates();
                emitEvent("error", "{\"what\":" + what + ",\"extra\":" + extra + "}");
                isPrepared = false;
                return true;
            });

            newPlayer.setOnSeekCompleteListener(mp -> {});

            newPlayer.setDataSource(cachedFile.getAbsolutePath());
            mediaPlayer = newPlayer;
            newPlayer.prepareAsync();

            // 延迟释放旧播放器，避免音频断裂
            handler.postDelayed(() -> {
                try { oldPlayer.release(); } catch (Exception ignored) {}
            }, 500);

        } catch (Exception e) {
            Log.w(TAG, "Failed to switch to cached source, continuing with remote", e);
        }
    }

    /**
     * 在 MediaPlayer 切换后，重新应用均衡器和音效到新的 audio session。
     */
    private void reapplyAudioEffects(int sessionId) {
        releaseAudioEffects();
        if (!"none".equals(lastAppliedEffect)) {
            applyEffectByName(lastAppliedEffect, sessionId);
        }
        if (lastAppliedEqGains != null) {
            applyEqGains(lastAppliedEqGains, sessionId);
        }
    }

    private void applyEffectByName(String effect, int sessionId) {
        try {
            switch (effect) {
                case "viper_atmos":
                    virtualizer = new Virtualizer(0, sessionId);
                    virtualizer.setStrength((short) 900);
                    virtualizer.setEnabled(true);
                    break;
                case "viper_tape":
                    reverb = new PresetReverb(0, sessionId);
                    reverb.setPreset(PresetReverb.PRESET_PLATE);
                    reverb.setEnabled(true);
                    break;
                case "viper_clear":
                    applyEqPresetEffect(sessionId, new int[]{0, 0, 0, 0, 0, 0, 0, 4, 4, 4});
                    break;
                case "none":
                default:
                    break;
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to reapply effect: " + effect, e);
        }
    }

    private void applyEqGains(String gainsStr, int sessionId) {
        try {
            if (equalizer == null) {
                equalizer = new Equalizer(0, sessionId);
                eqNumberOfBands = equalizer.getNumberOfBands();
                eqCenterFreqs = new int[eqNumberOfBands];
                for (short i = 0; i < eqNumberOfBands; i++) {
                    eqCenterFreqs[i] = equalizer.getCenterFreq(i);
                }
                equalizer.setEnabled(true);
            }
            String[] gainStrs = gainsStr.split(",");
            int[] targetFreqs = {60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000};
            for (int i = 0; i < Math.min(gainStrs.length, 10); i++) {
                float gainDb;
                try { gainDb = Float.parseFloat(gainStrs[i].trim()); } catch (NumberFormatException e) { continue; }
                short bandIdx = findClosestBand(targetFreqs[i]);
                if (bandIdx >= 0) {
                    short[] range = equalizer.getBandLevelRange();
                    short millidB = (short) Math.max(range[0], Math.min(range[1], (int)(gainDb * 100)));
                    equalizer.setBandLevel(bandIdx, millidB);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to reapply EQ gains", e);
        }
    }
}
