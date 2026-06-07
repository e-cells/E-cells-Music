package com.muye.ecells.music;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.os.Build;
import android.os.Bundle;
import android.provider.MediaStore;
import android.app.SearchManager;
import android.util.Log;
import android.view.View;
import android.view.WindowInsets;
import android.graphics.Insets;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.view.TextureView;
import android.view.Gravity;
import android.graphics.Color;
import android.content.res.Configuration;

import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.view.WindowCompat;
import org.json.JSONObject;
import org.mozilla.geckoview.GeckoView;
import org.mozilla.geckoview.GeckoSession;
import org.mozilla.geckoview.GeckoRuntime;
import org.mozilla.geckoview.GeckoRuntimeSettings;
import org.mozilla.geckoview.GeckoSessionSettings;
import org.mozilla.geckoview.AllowOrDeny;
import org.mozilla.geckoview.GeckoResult;
import org.mozilla.geckoview.GeckoSession.PromptDelegate;
import org.mozilla.geckoview.GeckoSession.PromptDelegate.TextPrompt;
import org.mozilla.geckoview.GeckoSession.PromptDelegate.PromptResponse;

public class MainActivity extends AppCompatActivity {

    private static final String TAG = "EchoMusic";
    private static final int REQUEST_NOTIFICATION_PERMISSION = 1001;
    private static final int REQUEST_INSTALL_PERMISSION = 2002;

    private GeckoView geckoView;
    private GeckoSession session;
    private GeckoRuntime runtime;
    private NativeAudioPlugin audioPlugin;
    private AssetServer assetServer;
    private String pendingVoiceSearchQuery = null;
    private int lastNightMode = -1;

    // === 主题跟随模式：默认跟随系统 ===
    private String themeAutoMode = "system"; // 可选值: "system" 或 "sensor"

    // === 光线传感器相关变量 ===
    private SensorManager sensorManager;
    private Sensor lightSensor;
    private boolean isSensorDark = false;
    private boolean hasInitSensorState = false;

    private static final float LIGHT_THRESHOLD_DARK = 15.0f;
    private static final float LIGHT_THRESHOLD_LIGHT = 30.0f;

    private SensorEventListener lightSensorListener = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent event) {
            if (event.sensor.getType() == Sensor.TYPE_LIGHT) {
                float lux = event.values[0];
                boolean stateChanged = false;

                // 传感器持续在后台记录光线状态，不论当前是什么模式
                if (lux <= LIGHT_THRESHOLD_DARK) {
                    if (!isSensorDark || !hasInitSensorState) {
                        isSensorDark = true;
                        hasInitSensorState = true;
                        stateChanged = true;
                    }
                } else if (lux >= LIGHT_THRESHOLD_LIGHT) {
                    if (isSensorDark || !hasInitSensorState) {
                        isSensorDark = false;
                        hasInitSensorState = true;
                        stateChanged = true;
                    }
                }

                // 只有当用户设置为 "sensor" (光感模式) 时，才主动推送到前端
                if (stateChanged && "sensor".equals(themeAutoMode)) {
                    Log.i(TAG, "环境光变化 (" + lux + " lux), 强制切换模式: " + (isSensorDark ? "深色" : "浅色"));
                    pushSystemThemeToFrontend(isSensorDark);
                    // 直接通知桌面歌词服务，确保后台时也能更新歌词颜色
                    LyricOverlayService service = LyricOverlayService.getInstance();
                    if (service != null) {
                        service.setThemeMode(isSensorDark ? "dark" : "light");
                    }
                }
            }
        }

        @Override
        public void onAccuracyChanged(Sensor sensor, int accuracy) {}
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // FLAG_KEEP_SCREEN_ON 已移除，通过 native://setKeepScreenOn bridge 按需开启

        lastNightMode = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams layoutParams = getWindow().getAttributes();
            layoutParams.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(layoutParams);
        }
        
        getWindow().getDecorView().setBackgroundColor(Color.parseColor("#121212"));

        try {
            sensorManager = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
            if (sensorManager != null) {
                lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT);
                registerLightSensorIfNeeded();
            }

            assetServer = new AssetServer(this);
            assetServer.startServer();

            AudioCacheManager.initialize(this);
            ApkUpdateManager.initialize(this);

            setContentView(R.layout.activity_main);
            geckoView = findViewById(R.id.geckoView);

            // 原生视频播放器的 TextureView 覆盖层
            TextureView nativeVideoSurface = findViewById(R.id.nativeVideoSurface);

            geckoView.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
                @Override
                public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                    // 不对 GeckoView 设置 padding，避免触摸坐标偏移
                    // 状态栏高度已通过 JS 注入 window.__STATUS_BAR_HEIGHT__ 传递给前端
                    // 前端通过 env(safe-area-inset-*) 和 __STATUS_BAR_HEIGHT__ 自行处理安全区域
                    return insets;
                }
            });

            if (runtime == null) {
                org.mozilla.geckoview.ContentBlocking.Settings cbSettings =
                    new org.mozilla.geckoview.ContentBlocking.Settings.Builder()
                        .antiTracking(org.mozilla.geckoview.ContentBlocking.AntiTracking.NONE)
                        .strictSocialTrackingProtection(false)
                        .build();
                runtime = GeckoRuntime.create(this,
                    new GeckoRuntimeSettings.Builder()
                        .contentBlocking(cbSettings)
                        .build()
                );
            }

            session = new GeckoSession();
            session.getSettings().setUserAgentMode(GeckoSessionSettings.USER_AGENT_MODE_MOBILE);
            session.getSettings().setViewportMode(GeckoSessionSettings.VIEWPORT_MODE_MOBILE);
            session.getSettings().setAllowJavascript(true);

            audioPlugin = new NativeAudioPlugin(this, session);
            audioPlugin.setVideoTextureView(nativeVideoSurface);
            ApkUpdateManager.getInstance().setPlugin(audioPlugin);
            ApkUpdateManager.getInstance().cleanupOldApks();

            session.setNavigationDelegate(new GeckoSession.NavigationDelegate() {
                @Override
                public GeckoResult<AllowOrDeny> onLoadRequest(GeckoSession navSession, GeckoSession.NavigationDelegate.LoadRequest request) {
                    if (request.uri.startsWith("native://")) {
                        // === 拦截前端传来的设置更改 ===
                        if (request.uri.startsWith("native://setThemeAutoMode")) {
                            String mode = request.uri.substring(request.uri.indexOf("mode=") + 5);
                            setThemeAutoMode(mode);
                            return GeckoResult.deny();
                        }
                        audioPlugin.handleUri(request.uri);
                        return GeckoResult.deny();
                    }
                    return GeckoResult.allow();
                }
            });

            session.setPromptDelegate(new GeckoSession.PromptDelegate() {
                @Override
                public GeckoResult<PromptResponse> onTextPrompt(GeckoSession promptSession, TextPrompt prompt) {
                    String uri = prompt.defaultValue;
                    if (uri != null && uri.startsWith("native://")) {
                        // === 拦截前端传来的设置更改 (通过 prompt 方式) ===
                        if (uri.startsWith("native://setThemeAutoMode")) {
                            String mode = uri.substring(uri.indexOf("mode=") + 5);
                            setThemeAutoMode(mode);
                            return GeckoResult.fromValue(prompt.confirm("ok"));
                        }
                        String result = audioPlugin.handleUriSync(uri);
                        return GeckoResult.fromValue(prompt.confirm(result));
                    }
                    return GeckoResult.fromValue(prompt.dismiss());
                }
            });

            session.setProgressDelegate(new GeckoSession.ProgressDelegate() {
                @Override
                public void onPageStart(GeckoSession progSession, String url) {
                    // === 页面开始加载时，从 SharedPreferences 恢复 store 数据到 localStorage ===
                    // 此时 JS 还未执行，localStorage 写入会在 Pinia rehydrate 之前生效
                    try {
                        android.content.SharedPreferences sp = getSharedPreferences("pinia_stores", Context.MODE_PRIVATE);
                        java.util.Map<String, ?> all = sp.getAll();
                        if (!all.isEmpty()) {
                            StringBuilder sb = new StringBuilder("try{");
                            for (java.util.Map.Entry<String, ?> entry : all.entrySet()) {
                                String key = entry.getKey();
                                String val = String.valueOf(entry.getValue());
                                String quotedVal = JSONObject.quote(val);
                                String quotedKey = JSONObject.quote(key);
                                sb.append("localStorage.setItem(").append(quotedKey).append(",").append(quotedVal).append(");");
                            }
                            sb.append("}catch(e){}");
                            evalJs(sb.toString());
                        }
                    } catch (Exception e) {
                        Log.w("MainActivity", "Failed to restore SharedPreferences to localStorage", e);
                    }
                    // 提前启用原生持久化桥，防止 onPageStop success=false 时桥未启用导致设置丢失
                    evalJs("window.__persistToNativeReady=true;");
                }

                @Override
                public void onPageStop(GeckoSession progSession, boolean success) {
                    if (success) {
                        evalJs("window.__GECKOVIEW__=true;window.__persistToNativeReady=true;window.NativeBridge=window.NativeBridge||{_callbacks:{},_listeners:{}};");
                        evalJs("if(window.__pendingVoiceSearch&&window.NativeBridge._listeners['mediaButtonPlayFromSearch']){" +
                            "var q=window.__pendingVoiceSearch;delete window.__pendingVoiceSearch;" +
                            "window.NativeBridge._listeners['mediaButtonPlayFromSearch'].forEach(function(cb){cb(q);});}");
                        evalJs("try{var s=JSON.parse(localStorage.getItem('setting'));if(s&&s.screenOrientation)" +
                            "{window.prompt('__native__','native://setOrientation?orientation='+s.screenOrientation);}}catch(e){}");
                        evalJs("window.__STATUS_BAR_HEIGHT__=" + getStatusBarHeight() + ";");
                        
                        // === 页面加载完成时，读取前端保存的主题设置 ===
                        evalJs("try{var s=JSON.parse(localStorage.getItem('setting'));if(s&&s.theme){" +
                            "var m=(s.theme==='sensor')?'sensor':'system';" +
                            "window.prompt('__native__','native://setThemeAutoMode?mode='+m);}}catch(e){}");
                        
                    }
                }
            });

            session.open(runtime);
            geckoView.setSession(session);

            String url = assetServer.getBaseUrl() + "index.html";
            session.loadUri(url);

            handleVoiceSearchIntent(getIntent());
            createNotificationChannels();
            requestNotificationPermission();

            MediaNotificationService.setPendingActivity(this);
            Intent serviceIntent = new Intent(this, MediaNotificationService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent);
            } else {
                startService(serviceIntent);
            }

        } catch (Exception e) {
            showErrorScreen("初始化失败: " + e.getMessage());
        }
    }

    public void setKeepScreenOn(boolean keepOn) {
        runOnUiThread(() -> {
            if (keepOn) {
                getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            } else {
                getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            }
        });
    }

    private void registerLightSensorIfNeeded() {
        if (sensorManager != null && lightSensor != null && "sensor".equals(themeAutoMode)) {
            sensorManager.registerListener(lightSensorListener, lightSensor, SensorManager.SENSOR_DELAY_NORMAL);
        }
    }

    private void unregisterLightSensor() {
        if (sensorManager != null && lightSensorListener != null) {
            sensorManager.unregisterListener(lightSensorListener);
        }
    }

    public void setThemeAutoMode(String mode) {
        if (mode == null) return;
        String oldMode = this.themeAutoMode;
        this.themeAutoMode = mode;
        Log.i(TAG, "主题自动切换模式设置为: " + mode);

        if ("sensor".equals(mode) && !"sensor".equals(oldMode)) {
            registerLightSensorIfNeeded();
        } else if (!"sensor".equals(mode) && "sensor".equals(oldMode)) {
            unregisterLightSensor();
        }

        runOnUiThread(() -> pushSystemThemeToFrontend());
    }

    void evalJs(String script) {
        if (session != null && session.isOpen()) {
            session.loadUri("javascript:(function(){" + script + "})();");
        }
    }

    private void pushSystemThemeToFrontend(boolean isDark) {
        String script = "try {" +
            "  if (window.NativeBridge && window.NativeBridge._listeners && window.NativeBridge._listeners['onSystemThemeChanged']) {" +
            "    window.NativeBridge._listeners['onSystemThemeChanged'].forEach(function(cb){ cb(" + isDark + "); });" +
            "  }" +
            "} catch(e) {}";
        evalJs(script);
    }

    // 根据当前选定的模式，智能推送状态
    private void pushSystemThemeToFrontend() {
        if ("sensor".equals(themeAutoMode) && hasInitSensorState) {
            // 光感模式：使用传感器记录的状态
            pushSystemThemeToFrontend(isSensorDark);
        } else {
            // 系统模式（或传感器暂无数据）：使用系统 UI 状态
            int nightMode = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
            boolean isDark = (nightMode == Configuration.UI_MODE_NIGHT_YES);
            pushSystemThemeToFrontend(isDark);
        }
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        
        if (geckoView != null) {
            geckoView.requestApplyInsets();
        }

        int currentNightMode = newConfig.uiMode & Configuration.UI_MODE_NIGHT_MASK;
        boolean isCurrentlyDark = (currentNightMode == Configuration.UI_MODE_NIGHT_YES);
        lastNightMode = currentNightMode;
        
        // 只有当用户设置为 "system" (跟随系统) 时，才响应系统UI广播推送到前端
        if ("system".equals(themeAutoMode)) {
            pushSystemThemeToFrontend(isCurrentlyDark);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if ("sensor".equals(themeAutoMode)) {
            registerLightSensorIfNeeded();
        }
        evalJs("if(window.NativeBridge&&window.NativeBridge._listeners['onActivityResume']){window.NativeBridge._listeners['onActivityResume'].forEach(function(cb){cb();});}");
        pushSystemThemeToFrontend();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if ("sensor".equals(themeAutoMode)) {
            unregisterLightSensor();
        }
        // Activity 进入后台时，直接从原生层内存缓存同步写盘，
        // 不依赖 JS evalJs 异步调用，确保进程被 kill 前数据已落盘。
        if (audioPlugin != null) {
            audioPlugin.persistAllCachedStores();
        }
        evalJs("if(window.NativeBridge&&window.NativeBridge._listeners['onActivityPause']){window.NativeBridge._listeners['onActivityPause'].forEach(function(cb){cb();});}");
    }

    @Override
    protected void onDestroy() {
        if (sensorManager != null && lightSensorListener != null) {
            sensorManager.unregisterListener(lightSensorListener);
        }
        if (audioPlugin != null) {
            audioPlugin.release();
        }
        if (ApkUpdateManager.getInstance() != null) {
            ApkUpdateManager.getInstance().release();
        }
        stopService(new Intent(this, MediaNotificationService.class));
        stopService(new Intent(this, LyricOverlayService.class));
        if (session != null) {
            session.close();
        }
        if (assetServer != null) {
            assetServer.stop();
        }
        super.onDestroy();
    }

    private void showErrorScreen(String message) {
        try {
            FrameLayout layout = new FrameLayout(this);
            layout.setBackgroundColor(Color.BLACK);
            TextView tv = new TextView(this);
            tv.setText(message);
            tv.setTextColor(Color.WHITE);
            tv.setTextSize(16);
            layout.addView(tv, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER
            ));
            setContentView(layout);
        } catch (Exception ignored) {}
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleVoiceSearchIntent(intent);
    }

    private void handleVoiceSearchIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH.equals(action)) {
            String query = intent.getStringExtra(SearchManager.QUERY);
            Bundle extras = intent.getExtras();
            if (extras != null) {
                if (query == null || query.isEmpty()) query = extras.getString("query", "");
                String artist = extras.getString(MediaStore.EXTRA_MEDIA_ARTIST, "");
                String title = extras.getString(MediaStore.EXTRA_MEDIA_TITLE, "");
                if ((query == null || query.isEmpty()) && (!artist.isEmpty() || !title.isEmpty())) {
                    query = artist + " " + title;
                }
            }
            if (query != null && !query.isEmpty()) executeVoiceSearch(query.trim());
        }
    }

    private void executeVoiceSearch(String query) {
        String quoted = JSONObject.quote(query);
        evalJs(
            "if(window.NativeBridge&&window.NativeBridge._listeners&&window.NativeBridge._listeners['mediaButtonPlayFromSearch']){" +
            "window.NativeBridge._listeners['mediaButtonPlayFromSearch'].forEach(function(cb){cb(" + quoted + ");});" +
            "}else{window.__pendingVoiceSearch=" + quoted + ";}"
        );
    }

    public void updateMediaNotificationMetadata(String title, String artist, String coverUrl, long durationMs) {
        MediaNotificationService service = MediaNotificationService.getInstance();
        if (service != null) {
            service.setActivity(this);
            service.updateMetadata(title, artist, coverUrl, durationMs);
        }
    }

    public void updateMediaNotificationPlaybackState(boolean playing, long positionMs, long durationMs) {
        MediaNotificationService service = MediaNotificationService.getInstance();
        if (service != null) {
            service.setActivity(this);
            service.updatePlaybackState(playing, positionMs, durationMs);
        }
    }

    @Override
    public void onBackPressed() {
        if (session != null) {
            evalJs("if(window.NativeBridge&&window.NativeBridge.onBackPressed)window.NativeBridge.onBackPressed();else window.history.back();");
        }
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            NotificationChannel playbackChannel = new NotificationChannel("echomusic_playback", "EchoMusic 播放控制", NotificationManager.IMPORTANCE_LOW);
            playbackChannel.setShowBadge(false);
            nm.createNotificationChannel(playbackChannel);

            NotificationChannel lyricChannel = new NotificationChannel("echomusic_lyric_overlay", "EchoMusic 桌面歌词", NotificationManager.IMPORTANCE_LOW);
            lyricChannel.setShowBadge(false);
            nm.createNotificationChannel(lyricChannel);
        }
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, new String[]{ Manifest.permission.POST_NOTIFICATIONS }, REQUEST_NOTIFICATION_PERMISSION);
            }
        }
    }

    private int getStatusBarHeight() {
        int result = 0;
        int resourceId = getResources().getIdentifier("status_bar_height", "dimen", "android");
        if (resourceId > 0) result = getResources().getDimensionPixelSize(resourceId);
        return Math.round(result / getResources().getDisplayMetrics().density);
    }
}