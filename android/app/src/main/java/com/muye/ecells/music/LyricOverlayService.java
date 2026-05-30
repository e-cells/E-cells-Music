package com.muye.ecells.music;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;

public class LyricOverlayService extends Service {

    private static final String TAG = "LyricOverlay";
    private static final int NOTIFICATION_ID = 1002;
    private static final String CHANNEL_ID = "echomusic_lyric_overlay";
    private static final String PREFS_NAME = "lyric_overlay_prefs";

    private static final String[] LIGHT_COLOR_HEX = {
        "#000000", "#333333", "#1A237E", "#880E4F", "#1B5E20", "#263238", "#4E342E"
    };
    private static final String[] DARK_COLOR_HEX = {
        "#FFFFFF", "#E0E0E0", "#FFCA28", "#00E5FF", "#69F0AE", "#FF4081", "#B388FF"
    };

    // Native lyric line data
    public static class LyricLineData {
        public long timeMs;
        public String text;
        public String translation;

        public LyricLineData(long timeMs, String text, String translation) {
            this.timeMs = timeMs;
            this.text = text;
            this.translation = translation;
        }
    }

    private static WeakReference<LyricOverlayService> instanceRef;

    public interface OnSettingsChangedListener {
        void onLockChanged(boolean locked);
    }

    private static OnSettingsChangedListener settingsChangedListener;

    public static void setOnSettingsChangedListener(OnSettingsChangedListener listener) {
        settingsChangedListener = listener;
    }

    public static LyricOverlayService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    private WindowManager windowManager;
    private View overlayView;
    private TextView line1;
    private TextView line2;
    private ImageView lockIcon;
    private WindowManager.LayoutParams params;
    private SharedPreferences prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private boolean isVisible = false;
    private boolean isLocked = false;
    private int lightColorIndex = 0;
    private int darkColorIndex = 0;
    private String themeMode = "system"; // "light", "dark", "system"
    private float fontSize = 18f;
    private boolean doubleLine = true;
    private int lyricWidthPercent = 100;
    private boolean lyricStrokeEnabled = false;
    private String lyricAlignment = "center";

    // BroadcastReceiver backup for theme changes on systems that don't
    // reliably call onConfigurationChanged() on background Services
    private BroadcastReceiver configChangeReceiver;

    // Periodic theme polling fallback (10s interval)
    private int lastDetectedNightMode = -1;
    private Runnable themePollRunnable;

    // Drag state
    private int initialX, initialY;
    private float initialTouchX, initialTouchY;
    private boolean isDragging = false;

    // Native lyric engine state
    private List<LyricLineData> lyrics = new ArrayList<>();
    private long basePlaybackMs = 0;
    private long baseSystemMs = 0;
    private boolean isPlaying = false;
    private int currentLineIndex = -1;
    private Runnable lyricTimerRunnable;

    // Screen on/off state
    private BroadcastReceiver screenReceiver;
    private boolean isScreenOn = true;

    @Override
    public void onCreate() {
        super.onCreate();
        instanceRef = new WeakReference<>(this);
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);

        // Restore persisted settings
        lightColorIndex = prefs.getInt("light_color_index", 0);
        darkColorIndex = prefs.getInt("dark_color_index", 0);
        themeMode = prefs.getString("theme_mode", "system");
        // 兼容旧版本迁移
        if (prefs.contains("color_index") && !prefs.contains("light_color_index")) {
            int oldIndex = prefs.getInt("color_index", 3);
            lightColorIndex = Math.max(0, Math.min(oldIndex, LIGHT_COLOR_HEX.length - 1));
            darkColorIndex = Math.max(0, Math.min(oldIndex, DARK_COLOR_HEX.length - 1));
        }
        fontSize = prefs.getFloat("font_size", 18f);
        doubleLine = prefs.getBoolean("double_line", true);
        isLocked = prefs.getBoolean("is_locked", false);
        lyricWidthPercent = prefs.getInt("width_percent", 100);
        lyricStrokeEnabled = prefs.getBoolean("stroke_enabled", false);
        lyricAlignment = prefs.getString("alignment", "center");

        createNotificationChannel();
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        // Register BroadcastReceiver as backup for configuration changes.
        // Some custom Android systems (esp. car infotainment) don't reliably
        // deliver onConfigurationChanged() to background Services.
        configChangeReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (Intent.ACTION_CONFIGURATION_CHANGED.equals(intent.getAction())) {
                    if ("system".equals(themeMode)) {
                        handler.post(LyricOverlayService.this::applyColorToViews);
                        Log.i(TAG, "BroadcastReceiver: system theme changed, reapplying lyric colors.");
                    }
                }
            }
        };
        IntentFilter filter = new IntentFilter(Intent.ACTION_CONFIGURATION_CHANGED);
        registerReceiver(configChangeReceiver, filter);

        lastDetectedNightMode = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        startThemePolling();

        // Register screen on/off receiver to pause/resume timers when screen is off
        screenReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) {
                    isScreenOn = false;
                    stopNativeLyricTimer();
                    stopThemePolling();
                    Log.i(TAG, "Screen off: paused lyric timer and theme polling");
                } else if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) {
                    isScreenOn = true;
                    // Recalculate baseSystemMs to account for elapsed time while screen was off
                    if (isPlaying) {
                        startNativeLyricTimer();
                    }
                    startThemePolling();
                    Log.i(TAG, "Screen on: resumed lyric timer and theme polling");
                }
            }
        };
        IntentFilter screenFilter = new IntentFilter();
        screenFilter.addAction(Intent.ACTION_SCREEN_OFF);
        screenFilter.addAction(Intent.ACTION_SCREEN_ON);
        registerReceiver(screenReceiver, screenFilter);

        Log.i(TAG, "LyricOverlayService created");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_NOT_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        stopNativeLyricTimer();
        stopThemePolling();
        hideOverlay();
        if (configChangeReceiver != null) {
            try {
                unregisterReceiver(configChangeReceiver);
            } catch (Exception e) {
                Log.w(TAG, "Error unregistering configChangeReceiver", e);
            }
            configChangeReceiver = null;
        }
        if (screenReceiver != null) {
            try {
                unregisterReceiver(screenReceiver);
            } catch (Exception e) {
                Log.w(TAG, "Error unregistering screenReceiver", e);
            }
            screenReceiver = null;
        }
        settingsChangedListener = null;
        instanceRef = null;
        super.onDestroy();
        Log.i(TAG, "LyricOverlayService destroyed");
    }
    // ── Configuration changes ──
    
    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // 当车机系统配置（例如白天/黑夜模式）发生变化时触发
        // 如果歌词的颜色模式设置为“跟随系统” (system)，则重新计算并应用深浅色配置
        if ("system".equals(themeMode)) {
            handler.post(this::applyColorToViews);
            Log.i(TAG, "System theme changed, reapplying lyric colors.");
        }
    }
  

    // ── Overlay lifecycle ──

    public void showOverlay() {
        if (isVisible) return;

        // Check overlay permission before proceeding
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                Log.e(TAG, "Overlay permission not granted, cannot show overlay");
                // 改进：增加 Toast 提示，防止用户一脸懵
                handler.post(() -> android.widget.Toast.makeText(
                    this, 
                    "请在系统设置 -> 应用权限中允许 EchoMusic 显示悬浮窗", 
                    android.widget.Toast.LENGTH_LONG
                ).show());
                return;
            }
        }

        overlayView = LayoutInflater.from(this).inflate(R.layout.layout_floating_lyric, null);
        line1 = overlayView.findViewById(R.id.lyric_line1);
        line2 = overlayView.findViewById(R.id.lyric_line2);
        lockIcon = overlayView.findViewById(R.id.lyric_lock_icon);

        // Enable marquee scrolling for long lyrics
        line1.setSelected(true);
        line2.setSelected(true);

        // Apply persisted settings to views
        applyColorToViews();
        applyAlignmentToViews();
        line1.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        line2.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        line2.setVisibility(doubleLine ? View.VISIBLE : View.GONE);

        // Setup lock icon
        updateLockIcon();

        // Setup params
        DisplayMetrics metrics = new DisplayMetrics();
        windowManager.getDefaultDisplay().getMetrics(metrics);
        int overlayWidth = metrics.widthPixels * lyricWidthPercent / 100;

        int type = WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
        params = new WindowManager.LayoutParams(
            overlayWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        );
        params.gravity = Gravity.TOP | Gravity.START;

        // Restore position or default to bottom-center
        int savedX = prefs.getInt("pos_x", -1);
        int savedY = prefs.getInt("pos_y", -1);
        if (savedX >= 0 && savedY >= 0) {
            params.x = savedX;
            params.y = savedY;
        } else {
            // Default position: near bottom of screen
            params.x = 0;
            params.y = metrics.heightPixels - 300;
        }

        // Setup drag listener
        FrameLayout root = overlayView.findViewById(R.id.lyric_root);
        root.setOnTouchListener(dragListener);

        // Apply lock state
        if (isLocked) {
            root.setOnTouchListener(null);
            params.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        }

        updateLyricBackground();

        windowManager.addView(overlayView, params);
        isVisible = true;
        prefs.edit().putBoolean("enabled", true).apply();
        Log.i(TAG, "Overlay shown");
    }

    public void hideOverlay() {
        if (!isVisible || overlayView == null) return;
        try {
            windowManager.removeView(overlayView);
        } catch (Exception e) {
            Log.w(TAG, "Error removing overlay view", e);
        }
        overlayView = null;
        line1 = null;
        line2 = null;
        lockIcon = null;
        isVisible = false;
        stopNativeLyricTimer();
        prefs.edit().putBoolean("enabled", false).apply();
        Log.i(TAG, "Overlay hidden");
    }

    // ── Lyrics update ──

    public void updateLines(final String text1, final String text2) {
        handler.post(() -> {
            if (line1 != null) line1.setText(text1);
            if (line2 != null) line2.setText(text2);
        });
    }

    // ── Native lyric engine ──

    public void loadLyrics(List<LyricLineData> newLyrics, long currentTimeMs, boolean playing) {
        this.lyrics = newLyrics != null ? newLyrics : new ArrayList<>();
        this.basePlaybackMs = currentTimeMs;
        this.baseSystemMs = System.currentTimeMillis();
        this.isPlaying = playing;
        this.currentLineIndex = -1;
        startNativeLyricTimer();
        handler.post(() -> {
            if (playing && !lyrics.isEmpty()) {
                long pos = getCurrentPlaybackPosition();
                currentLineIndex = findLineIndex(pos);
                updateOverlayFromLyrics();
            } else if (lyrics.isEmpty() && line1 != null) {
                line1.setText("");
                line2.setText("");
            }
        });
    }

    public void setPlaybackState(boolean playing, long currentTimeMs) {
        this.basePlaybackMs = currentTimeMs;
        this.baseSystemMs = System.currentTimeMillis();
        this.isPlaying = playing;
        if (playing) {
            startNativeLyricTimer();
        } else {
            stopNativeLyricTimer();
        }
    }

    public void seekTo(long timeMs) {
        this.basePlaybackMs = timeMs;
        this.baseSystemMs = System.currentTimeMillis();
        this.currentLineIndex = -1;
        handler.post(() -> {
            if (isPlaying && !lyrics.isEmpty()) {
                long pos = getCurrentPlaybackPosition();
                currentLineIndex = findLineIndex(pos);
                updateOverlayFromLyrics();
            }
        });
    }

    private long getCurrentPlaybackPosition() {
        if (!isPlaying) return basePlaybackMs;
        return basePlaybackMs + (System.currentTimeMillis() - baseSystemMs);
    }

    private int findLineIndex(long timeMs) {
        int idx = -1;
        for (int i = 0; i < lyrics.size(); i++) {
            if (lyrics.get(i).timeMs <= timeMs) idx = i;
            else break;
        }
        return idx;
    }

    private void startNativeLyricTimer() {
        stopNativeLyricTimer();
        if (!isPlaying || lyrics.isEmpty()) return;
        final int[] lastPairStart = { getDisplayPairStart() };
        lyricTimerRunnable = new Runnable() {
            @Override
            public void run() {
                if (isPlaying && !lyrics.isEmpty()) {
                    long pos = getCurrentPlaybackPosition();
                    int newIndex = findLineIndex(pos);
                    if (newIndex != currentLineIndex) {
                        currentLineIndex = newIndex;
                        if (doubleLine) {
                            // 双行模式：仅在 pairStart 变化时才刷新显示
                            int newPairStart = getDisplayPairStart();
                            if (newPairStart != lastPairStart[0]) {
                                lastPairStart[0] = newPairStart;
                                updateOverlayFromLyrics();
                            }
                        } else {
                            updateOverlayFromLyrics();
                        }
                    }
                }
                if (isPlaying) {
                    handler.postDelayed(this, computeLyricPollDelay());
                }
            }
        };
        handler.post(lyricTimerRunnable);
    }

    /**
     * Compute adaptive polling delay based on time until next lyric line.
     * Long gaps between lines → longer delay (saves battery).
     * Approaching a line change → shorter delay (accuracy).
     *
     * 双行模式下，关注下一个 pair 边界（pairStart + 2）而非下一行。
     */
    private long computeLyricPollDelay() {
        int nextIdx;
        if (doubleLine && currentLineIndex >= 0) {
            // 双行模式：下一个关键时间点是 pairStart + 2 那行的起始时间
            nextIdx = getDisplayPairStart() + 2;
        } else {
            nextIdx = currentLineIndex + 1;
        }
        if (nextIdx >= lyrics.size()) {
            return 2000; // Last line, no more changes expected
        }
        long pos = getCurrentPlaybackPosition();
        long timeUntilNext = lyrics.get(nextIdx).timeMs - pos;
        if (timeUntilNext > 2000) {
            return 1000;
        } else if (timeUntilNext > 500) {
            return 200;
        } else {
            return 100;
        }
    }

    private void stopNativeLyricTimer() {
        if (lyricTimerRunnable != null) {
            handler.removeCallbacks(lyricTimerRunnable);
            lyricTimerRunnable = null;
        }
    }

    /**
     * 计算双行模式下当前应显示的 pair 起始索引。
     * 双行成对推进：歌手唱完第 N+1 行后才切换到 (N+2, N+3)。
     */
    private int getDisplayPairStart() {
        if (doubleLine && currentLineIndex >= 0) {
            return (currentLineIndex / 2) * 2;
        }
        return currentLineIndex;
    }

    private void updateOverlayFromLyrics() {
        if (line1 == null) return;
        if (currentLineIndex < 0 || currentLineIndex >= lyrics.size()) {
            line1.setText("");
            line2.setText("");
            return;
        }

        if (doubleLine) {
            // 双行成对模式：使用 pairStart 决定显示哪两行
            int pairStart = getDisplayPairStart();
            if (pairStart < 0 || pairStart >= lyrics.size()) {
                line1.setText("");
                line2.setText("");
                return;
            }
            LyricLineData first = lyrics.get(pairStart);
            line1.setText(first.text);
            String line2Text = "";
            if (pairStart + 1 < lyrics.size()) {
                LyricLineData second = lyrics.get(pairStart + 1);
                line2Text = second.text;
            }
            line2.setText(line2Text);
        } else {
            // 单行模式：保持原逻辑
            LyricLineData current = lyrics.get(currentLineIndex);
            line1.setText(current.text);
            String line2Text = "";
            if (current.translation != null && !current.translation.isEmpty()) {
                line2Text = current.translation;
            } else if (currentLineIndex + 1 < lyrics.size()) {
                line2Text = lyrics.get(currentLineIndex + 1).text;
            }
            line2.setText(line2Text);
        }
        line1.setSelected(true);
        line2.setSelected(true);
    }

    // ── Settings ──

    public void applySettings(int newLightColorIndex, int newDarkColorIndex, String newThemeMode,
            float newFontSize, boolean newDoubleLine, Boolean newLocked, int newWidthPercent,
            boolean newStrokeEnabled, String newAlignment) {
        if (newLightColorIndex >= 0 && newLightColorIndex < LIGHT_COLOR_HEX.length) {
            lightColorIndex = newLightColorIndex;
            prefs.edit().putInt("light_color_index", lightColorIndex).apply();
        }
        if (newDarkColorIndex >= 0 && newDarkColorIndex < DARK_COLOR_HEX.length) {
            darkColorIndex = newDarkColorIndex;
            prefs.edit().putInt("dark_color_index", darkColorIndex).apply();
        }
        final boolean themeChanged = (newThemeMode != null
            && (newThemeMode.equals("light") || newThemeMode.equals("dark") || newThemeMode.equals("system"))
            && !newThemeMode.equals(themeMode));
        final String oldThemeMode = themeMode;
        if (themeChanged) {
            themeMode = newThemeMode;
            prefs.edit().putString("theme_mode", themeMode).apply();
        }
        if (newFontSize > 0) {
            fontSize = newFontSize;
            prefs.edit().putFloat("font_size", fontSize).apply();
        }
        if (newDoubleLine != doubleLine) {
            doubleLine = newDoubleLine;
            prefs.edit().putBoolean("double_line", doubleLine).apply();
        }
        final boolean lockChanged = (newLocked != null && newLocked != isLocked);
        if (lockChanged) {
            isLocked = newLocked;
            prefs.edit().putBoolean("is_locked", isLocked).apply();
        }
        final boolean widthChanged = (newWidthPercent >= 10 && newWidthPercent <= 100 && newWidthPercent != lyricWidthPercent);
        if (widthChanged) {
            lyricWidthPercent = newWidthPercent;
            prefs.edit().putInt("width_percent", lyricWidthPercent).apply();
        }
        final boolean strokeChanged = (newStrokeEnabled != lyricStrokeEnabled);
        if (strokeChanged) {
            lyricStrokeEnabled = newStrokeEnabled;
            prefs.edit().putBoolean("stroke_enabled", lyricStrokeEnabled).apply();
        }
        final boolean alignmentChanged = (newAlignment != null && !newAlignment.equals(lyricAlignment));
        if (alignmentChanged) {
            lyricAlignment = newAlignment;
            prefs.edit().putString("alignment", lyricAlignment).apply();
        }

        handler.post(() -> {
            if (line1 == null || overlayView == null) return;
            applyColorToViews();
            // Start or stop theme polling when mode changes between "system" and others
            if (themeChanged) {
                if ("system".equals(themeMode)) {
                    startThemePolling();
                } else if ("system".equals(oldThemeMode)) {
                    stopThemePolling();
                }
            }
            line1.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
            line2.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
            line2.setVisibility(doubleLine ? View.VISIBLE : View.GONE);
            if (lockChanged) {
                FrameLayout root = overlayView.findViewById(R.id.lyric_root);
                root.setOnTouchListener(isLocked ? null : dragListener);
                updateTouchableFlag();
                updateLyricBackground();
            }
            if (widthChanged) {
                DisplayMetrics metrics = new DisplayMetrics();
                windowManager.getDefaultDisplay().getMetrics(metrics);
                params.width = metrics.widthPixels * lyricWidthPercent / 100;
                windowManager.updateViewLayout(overlayView, params);
            }
            if (strokeChanged) {
                applyStrokeToViews();
            }
            if (alignmentChanged) {
                applyAlignmentToViews();
            }
        });
    }

    // ── Drag ──

    private final View.OnTouchListener dragListener = new View.OnTouchListener() {
        @Override
        public boolean onTouch(View v, MotionEvent event) {
            if (isLocked) return false;

            switch (event.getAction()) {
                case MotionEvent.ACTION_DOWN:
                    initialX = params.x;
                    initialY = params.y;
                    initialTouchX = event.getRawX();
                    initialTouchY = event.getRawY();
                    isDragging = false;
                    return true;

                case MotionEvent.ACTION_MOVE:
                    float dx = event.getRawX() - initialTouchX;
                    float dy = event.getRawY() - initialTouchY;
                    if (!isDragging && (Math.abs(dx) > 10 || Math.abs(dy) > 10)) {
                        isDragging = true;
                    }
                    if (isDragging) {
                        params.x = initialX + (int) dx;
                        params.y = initialY + (int) dy;
                        clampToScreen();
                        windowManager.updateViewLayout(overlayView, params);
                    }
                    return true;

                case MotionEvent.ACTION_UP:
                    if (isDragging) {
                        prefs.edit()
                            .putInt("pos_x", params.x)
                            .putInt("pos_y", params.y)
                            .apply();
                    }
                    isDragging = false;
                    return true;
            }
            return false;
        }
    };

    private void clampToScreen() {
        DisplayMetrics metrics = new DisplayMetrics();
        windowManager.getDefaultDisplay().getMetrics(metrics);
        int viewWidth = overlayView.getWidth();
        if (viewWidth <= 0) viewWidth = params.width;
        int viewHeight = overlayView.getHeight();
        if (viewHeight <= 0) viewHeight = params.height;

        int minX = 0;
        int maxX = metrics.widthPixels - viewWidth;
        int minY = 0;
        int maxY = metrics.heightPixels - viewHeight;

        params.x = Math.max(minX, Math.min(params.x, maxX));
        params.y = Math.max(minY, Math.min(params.y, maxY));
    }

    // ── Lock/Unlock ──

    private void toggleLock() {
        isLocked = !isLocked;
        prefs.edit().putBoolean("is_locked", isLocked).apply();

        // Notify JS layer about lock state change
        if (settingsChangedListener != null) {
            settingsChangedListener.onLockChanged(isLocked);
        }

        handler.post(() -> {
            if (overlayView == null) return;
            FrameLayout root = overlayView.findViewById(R.id.lyric_root);
            root.setOnTouchListener(isLocked ? null : dragListener);
            updateTouchableFlag();
            updateLyricBackground();
        });
    }

    private void updateLockIcon() {
        if (lockIcon == null) return;
        lockIcon.setVisibility(View.GONE);
    }

    // ── Color ──

    public void setThemeMode(String mode) {
        if (mode == null || (!mode.equals("light") && !mode.equals("dark") && !mode.equals("system"))) return;
        if (mode.equals(themeMode)) return;
        String oldMode = themeMode;
        themeMode = mode;
        prefs.edit().putString("theme_mode", themeMode).apply();
        handler.post(() -> {
            applyColorToViews();
            // Start or stop polling based on mode change
            if ("system".equals(mode) && !"system".equals(oldMode)) {
                startThemePolling();
            } else if (!"system".equals(mode) && "system".equals(oldMode)) {
                stopThemePolling();
            }
        });
    }

    private void applyColorToViews() {
        if (line1 == null || line2 == null) return;
        String[] colorArray;
        int colorIdx;
        if ("light".equals(themeMode)) {
            colorArray = LIGHT_COLOR_HEX;
            colorIdx = lightColorIndex;
        } else if ("dark".equals(themeMode)) {
            colorArray = DARK_COLOR_HEX;
            colorIdx = darkColorIndex;
        } else {
            int nightMode = getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK;
            boolean isDark = (nightMode == Configuration.UI_MODE_NIGHT_YES);
            colorArray = isDark ? DARK_COLOR_HEX : LIGHT_COLOR_HEX;
            colorIdx = isDark ? darkColorIndex : lightColorIndex;
        }
        int color = Color.parseColor(colorArray[colorIdx]);
        line1.setTextColor(color);
        line2.setTextColor(color);
    }

    /**
     * Start theme polling only when themeMode is "system" and screen is on.
     * Called when theme mode changes to "system" or screen turns on.
     */
    private void startThemePolling() {
        stopThemePolling();
        if (!"system".equals(themeMode) || !isScreenOn) return;
        themePollRunnable = new Runnable() {
            @Override
            public void run() {
                if ("system".equals(themeMode) && isVisible && isScreenOn) {
                    int currentNightMode = getResources().getConfiguration().uiMode
                        & Configuration.UI_MODE_NIGHT_MASK;
                    if (lastDetectedNightMode >= 0 && currentNightMode != lastDetectedNightMode) {
                        applyColorToViews();
                        Log.i(TAG, "Theme poll: system theme changed, reapplying lyric colors.");
                    }
                    lastDetectedNightMode = currentNightMode;
                }
                // Stop self if conditions no longer met, otherwise continue
                if ("system".equals(themeMode) && isScreenOn) {
                    handler.postDelayed(this, 120000);
                }
            }
        };
        handler.postDelayed(themePollRunnable, 120000);
    }

    private void stopThemePolling() {
        if (themePollRunnable != null) {
            handler.removeCallbacks(themePollRunnable);
            themePollRunnable = null;
        }
    }

    private void updateLyricBackground() {
        if (overlayView == null) return;
        FrameLayout root = overlayView.findViewById(R.id.lyric_root);
        if (isLocked) {
            root.setBackgroundColor(Color.TRANSPARENT);
        } else {
            root.setBackgroundResource(R.drawable.bg_floating_lyric);
        }
    }

    private void updateTouchableFlag() {
        if (overlayView == null || params == null || windowManager == null) return;
        if (isLocked) {
            params.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        } else {
            params.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        }
        windowManager.updateViewLayout(overlayView, params);
    }

    private void applyStrokeToViews() {
        if (line1 == null || line2 == null) return;
        if (lyricStrokeEnabled) {
            float strokeWidth = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP, fontSize * 0.04f,
                getResources().getDisplayMetrics());
            for (TextView tv : new TextView[]{line1, line2}) {
                tv.getPaint().setStyle(Paint.Style.FILL_AND_STROKE);
                tv.getPaint().setStrokeWidth(strokeWidth);
                tv.setShadowLayer(strokeWidth, 0f, 0f, Color.BLACK);
            }
        } else {
            for (TextView tv : new TextView[]{line1, line2}) {
                tv.getPaint().setStyle(Paint.Style.FILL);
                tv.getPaint().setStrokeWidth(0);
                tv.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT);
            }
        }
    }

    private void applyAlignmentToViews() {
        if (overlayView == null) return;
        LinearLayout container = overlayView.findViewById(R.id.lyric_text_container);
        int gravity;
        switch (lyricAlignment) {
            case "left":  gravity = Gravity.START; break;
            case "right": gravity = Gravity.END; break;
            default:      gravity = Gravity.CENTER; break;
        }
        container.setGravity(gravity);
        container.setPadding(0, 0, 0, 0);
    }

    // ── Notification ──

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "EchoMusic 桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("桌面歌词浮窗服务");
            channel.setShowBadge(false);
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) {
                nm.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification() {
        Intent contentIntent = new Intent(this, MainActivity.class);
        contentIntent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pending = PendingIntent.getActivity(
            this, 0, contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        return new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("EchoMusic 桌面歌词")
            .setContentText("桌面歌词正在运行")
            .setContentIntent(pending)
            .setShowWhen(false)
            .setOngoing(true)
            .build();
    }

    // ── Utility ──

    public boolean isIgnoringBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            return pm.isIgnoringBatteryOptimizations(getPackageName());
        }
        return true;
    }

    public String getSettingsSnapshot() {
        try {
            org.json.JSONObject json = new org.json.JSONObject();
            json.put("fontSize", fontSize);
            json.put("lightColorIndex", lightColorIndex);
            json.put("darkColorIndex", darkColorIndex);
            json.put("themeMode", themeMode);
            json.put("colorIndex", lightColorIndex); // 兼容旧版
            json.put("doubleLine", doubleLine);
            json.put("locked", isLocked);
            json.put("widthPercent", lyricWidthPercent);
            json.put("strokeEnabled", lyricStrokeEnabled);
            json.put("alignment", lyricAlignment);
            json.put("enabled", isVisible);
            return json.toString();
        } catch (Exception e) {
            return "{}";
        }
    }
}
