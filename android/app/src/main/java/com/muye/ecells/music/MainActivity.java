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
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.view.TextureView;
import android.view.Gravity;
import android.graphics.Color;
import android.content.res.Configuration;

import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.splashscreen.SplashScreen;
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

    private static final String TAG = "EcellsMusic";
    private static final int REQUEST_NOTIFICATION_PERMISSION = 1001;
    private static final int REQUEST_INSTALL_PERMISSION = 2002;

    private GeckoView geckoView;
    private GeckoSession session;
    private volatile GeckoRuntime runtime; // volatile: 跨线程赋值后 UI 线程需立即可见
    private NativeAudioPlugin audioPlugin;
    private AssetServer assetServer;
    private String pendingVoiceSearchQuery = null;
    private int lastNightMode = -1;
    private volatile boolean isPageReady = false;
    private View loadingOverlay; // 原生加载遮罩层（图标 + 标语）

    // === localStorage 恢复脚本缓存 ===
    private volatile String cachedRestoreScript = null;
    private volatile boolean spDirty = true; // SP 数据变更标记，初始为 true 强制首次构建

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
        SplashScreen splashScreen = SplashScreen.installSplashScreen(this);
        splashScreen.setKeepOnScreenCondition(() -> !isPageReady);
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
        
        // 根据前端 Pinia 持久化的主题设置，动态设置 DecorView 背景色
        // 确保原生容器背景与前端页面背景一致，消除启动时的色差闪烁
        boolean isDarkBg = true; // 默认暗黑
        try {
            android.content.SharedPreferences sp = getSharedPreferences("pinia_stores", Context.MODE_PRIVATE);
            String settingJson = sp.getString("setting", null);
            if (settingJson != null) {
                JSONObject settingObj = new JSONObject(settingJson);
                String theme = settingObj.optString("theme", "system");
                if ("dark".equals(theme)) {
                    isDarkBg = true;
                } else if ("light".equals(theme)) {
                    isDarkBg = false;
                } else {
                    // system 或 sensor：跟随 Android 系统夜间模式
                    int nightMode = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
                    isDarkBg = (nightMode == Configuration.UI_MODE_NIGHT_YES);
                }
            }
        } catch (Exception e) {
            // 读取失败，使用默认暗黑
        }
        getWindow().getDecorView().setBackgroundColor(Color.parseColor(isDarkBg ? "#030406" : "#eef2f7"));

        try {
            sensorManager = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
            if (sensorManager != null) {
                lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT);
                registerLightSensorIfNeeded();
            }

            setContentView(R.layout.activity_main);
            geckoView = findViewById(R.id.geckoView);

            // 原生视频播放器的 TextureView 覆盖层
            TextureView nativeVideoSurface = findViewById(R.id.nativeVideoSurface);

            // 创建原生加载遮罩层（图标 + 标语），覆盖在 GeckoView 之上
            // 原生 SplashScreen 退出后用户看到此遮罩，等 Vue 挂载完毕后通过 native://hideSplash 淡出
            loadingOverlay = createLoadingOverlay(isDarkBg);
            ((FrameLayout) geckoView.getParent()).addView(loadingOverlay, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

            geckoView.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
                @Override
                public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                    // 不对 GeckoView 设置 padding，避免触摸坐标偏移
                    // 状态栏高度已通过 JS 注入 window.__STATUS_BAR_HEIGHT__ 传递给前端
                    // 前端通过 env(safe-area-inset-*) 和 __STATUS_BAR_HEIGHT__ 自行处理安全区域
                    return insets;
                }
            });

            // 不依赖 GeckoView 的操作，立即在主线程执行
            handleVoiceSearchIntent(getIntent());
            createNotificationChannels();
            requestNotificationPermission();

            // === 并行初始化：两条轨道同时启动 ===
            // 轨道A（IO线程）：AssetServer + AudioCacheManager + ApkUpdateManager
            // 轨道B（UI线程）：GeckoRuntime.create() — 必须在 Activity 的 UI 线程创建
            // 汇合后：initGeckoView（session.open + loadUri）
            // 效果：GeckoRuntime.create() 和 AssetServer 启动并行执行，省去串行等待时间

            final TextureView finalNativeVideoSurface = nativeVideoSurface;

            // 用于两条轨道同步的 CountDownLatch
            CountDownLatch initLatch = new CountDownLatch(2);
            AtomicReference<AssetServer> serverRef = new AtomicReference<>();
            AtomicReference<Exception> serverError = new AtomicReference<>();
            AtomicReference<Exception> runtimeError = new AtomicReference<>();

            // 轨道A：IO 密集型操作（AssetServer 启动、缓存初始化、更新管理器初始化）
            new Thread(() -> {
                try {
                    AssetServer server = new AssetServer(MainActivity.this);
                    server.startServer();
                    AudioCacheManager.initialize(MainActivity.this);
                    ApkUpdateManager.initialize(MainActivity.this);
                    serverRef.set(server);
                    Log.i(TAG, "轨道A完成: AssetServer + CacheManager + UpdateManager 已初始化");
                } catch (Exception e) {
                    serverError.set(e);
                    Log.e(TAG, "轨道A失败", e);
                }
                initLatch.countDown();
            }, "init-server").start();

            // 轨道B：GeckoRuntime 创建
            // GeckoRuntime.create() 必须在主线程调用，通过 runOnUiThread + CountDownLatch 同步
            // 与轨道A并行执行，省去原来 AssetServer 完成后才创建 GeckoRuntime 的串行等待
            new Thread(() -> {
                try {
                    // 先检查是否已有预创建的 GeckoRuntime（由 MusicApplication 或进程复用）
                    GeckoRuntime existingRuntime = MusicApplication.getGeckoRuntime();
                    if (existingRuntime != null) {
                        runtime = existingRuntime;
                        Log.i(TAG, "轨道B完成: 复用已有 GeckoRuntime（耗时≈0ms）");
                    } else {
                        // 在 UI 线程创建 GeckoRuntime（与原始代码行为一致）
                        final CountDownLatch rtLatch = new CountDownLatch(1);
                        runOnUiThread(() -> {
                            try {
                                org.mozilla.geckoview.ContentBlocking.Settings cbSettings =
                                    new org.mozilla.geckoview.ContentBlocking.Settings.Builder()
                                        .antiTracking(org.mozilla.geckoview.ContentBlocking.AntiTracking.NONE)
                                        .strictSocialTrackingProtection(false)
                                        .build();
                                runtime = GeckoRuntime.create(MainActivity.this,
                                    new GeckoRuntimeSettings.Builder()
                                        .contentBlocking(cbSettings)
                                        .build()
                                );
                                MusicApplication.setGeckoRuntime(runtime);
                                Log.i(TAG, "轨道B完成: GeckoRuntime 创建成功");
                            } catch (Throwable t) {
                                // catch Throwable 而非 Exception，捕获 UnsatisfiedLinkError 等致命错误
                                runtimeError.set(new Exception("GeckoRuntime 创建失败: " + t.getMessage(), t));
                                Log.e(TAG, "轨道B失败: GeckoRuntime 创建异常", t);
                            }
                            rtLatch.countDown();
                        });
                        rtLatch.await(5, TimeUnit.SECONDS);
                    }
                } catch (Exception e) {
                    runtimeError.set(e);
                    Log.e(TAG, "轨道B异常", e);
                }
                initLatch.countDown();
            }, "init-runtime").start();

            // 汇合线程：等待两条轨道都完成后，执行 GeckoView 初始化
            new Thread(() -> {
                try {
                    initLatch.await(10, TimeUnit.SECONDS);
                    runOnUiThread(() -> {
                        // 检查错误
                        if (serverError.get() != null) {
                            showErrorScreen("服务器初始化失败: " + serverError.get().getMessage());
                            return;
                        }
                        if (runtimeError.get() != null || runtime == null) {
                            showErrorScreen("运行时初始化失败");
                            return;
                        }
                        try {
                            assetServer = serverRef.get();
                            initGeckoView(finalNativeVideoSurface);
                        } catch (Exception e) {
                            showErrorScreen("视图初始化失败: " + e.getMessage());
                        }
                    });
                } catch (Exception e) {
                    runOnUiThread(() -> showErrorScreen("初始化超时: " + e.getMessage()));
                }
            }, "init-join").start();

        } catch (Exception e) {
            showErrorScreen("初始化失败: " + e.getMessage());
        }
    }

    private void initGeckoView(TextureView nativeVideoSurface) {
        // GeckoRuntime 已由 MusicApplication 预创建，或由并行轨道B fallback 创建
        // 此处 runtime 已就绪，直接进行 Session 配置和页面加载
        if (runtime == null) {
            showErrorScreen("GeckoRuntime 未初始化");
            return;
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
                    // === 前端通知关闭原生启动屏 + 淡出加载遮罩 ===
                    if (uri.startsWith("native://hideSplash")) {
                        isPageReady = true;
                        // 在 UI 线程淡出原生加载遮罩层
                        runOnUiThread(() -> {
                            if (loadingOverlay != null) {
                                loadingOverlay.animate()
                                    .alpha(0f)
                                    .setDuration(400)
                                    .withEndAction(() -> {
                                        if (loadingOverlay != null) {
                                            FrameLayout parent = (FrameLayout) loadingOverlay.getParent();
                                            if (parent != null) parent.removeView(loadingOverlay);
                                            loadingOverlay = null;
                                        }
                                    })
                                    .start();
                            }
                        });
                        return GeckoResult.fromValue(prompt.confirm("ok"));
                    }
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
                // 不在此处关闭 SplashScreen，等前端 Loading.vue 挂载完成后通过 native://hideSplash 通知
                // === 页面开始加载时，从 SharedPreferences 恢复 store 数据到 localStorage ===
                // 此时 JS 还未执行，localStorage 写入会在 Pinia rehydrate 之前生效
                // 使用缓存的恢复脚本，避免每次页面加载都重新构建
                try {
                    String script = getRestoreScript();
                    if (script != null && !script.isEmpty()) {
                        evalJs(script);
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

                    // === 页面加载完成后再启动 MediaNotificationService ===
                    MediaNotificationService.setPendingActivity(MainActivity.this);
                    Intent serviceIntent = new Intent(MainActivity.this, MediaNotificationService.class);
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent);
                    } else {
                        startService(serviceIntent);
                    }
                }
            }
        });

        session.open(runtime);
        geckoView.setSession(session);

        String url = assetServer.getBaseUrl() + "index.html";
        session.loadUri(url);
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

    /**
     * 获取缓存的 localStorage 恢复脚本。
     * 仅在 SharedPreferences 数据变更时重新构建，避免每次 onPageStart 重复拼接字符串。
     */
    private String getRestoreScript() {
        if (cachedRestoreScript != null && !spDirty) {
            return cachedRestoreScript;
        }

        try {
            android.content.SharedPreferences sp = getSharedPreferences("pinia_stores", Context.MODE_PRIVATE);
            java.util.Map<String, ?> all = sp.getAll();
            if (all.isEmpty()) {
                cachedRestoreScript = "";
                spDirty = false;
                return cachedRestoreScript;
            }

            StringBuilder sb = new StringBuilder("try{");
            for (java.util.Map.Entry<String, ?> entry : all.entrySet()) {
                String key = entry.getKey();
                String val = String.valueOf(entry.getValue());
                String quotedVal = JSONObject.quote(val);
                String quotedKey = JSONObject.quote(key);
                sb.append("localStorage.setItem(").append(quotedKey).append(",").append(quotedVal).append(");");
            }
            sb.append("}catch(e){}");

            cachedRestoreScript = sb.toString();
            spDirty = false;
            return cachedRestoreScript;
        } catch (Exception e) {
            Log.w(TAG, "Failed to build restore script", e);
            return "";
        }
    }

    /**
     * 使恢复脚本缓存失效。
     * 由 NativeAudioPlugin.persistStore 成功写入 SP 后调用。
     */
    void invalidateRestoreCache() {
        spDirty = true;
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

    /**
     * 创建原生加载遮罩层，覆盖在 GeckoView 之上。
     * 显示 App 图标 + 标语文字，背景色与主题匹配。
     * 原生 SplashScreen 退出后用户看到此遮罩，等 Vue 挂载完毕后淡出消失。
     */
    private View createLoadingOverlay(boolean isDark) {
        float density = getResources().getDisplayMetrics().density;

        // 外层容器：全屏、主题背景色
        FrameLayout overlay = new FrameLayout(this);
        overlay.setBackgroundColor(Color.parseColor(isDark ? "#030406" : "#eef2f7"));

        // 内容区：纵向排列，居中
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER_HORIZONTAL);

        // App 图标
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.ic_launcher);
        int iconSize = (int) (72 * density); // 72dp
        content.addView(icon, new LinearLayout.LayoutParams(iconSize, iconSize));

        // APP 名称 "易格音乐"
        TextView appName = new TextView(this);
        appName.setText("易格音乐");
        appName.setTextColor(isDark
            ? Color.parseColor("#E0E0E0")  // 暗黑：浅灰白
            : Color.parseColor("#333333")); // 亮色：深灰
        appName.setTextSize(20); // sp
        appName.setLetterSpacing(0.12f);
        android.graphics.Typeface typefaceBold = android.graphics.Typeface.create(
            android.graphics.Typeface.SANS_SERIF, android.graphics.Typeface.BOLD);
        appName.setTypeface(typefaceBold);
        LinearLayout.LayoutParams nameParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        nameParams.topMargin = (int) (20 * density); // 图标与名称间距 20dp
        content.addView(appName, nameParams);

        // 标语文字 "懂你的每一首热爱"
        TextView tagline = new TextView(this);
        tagline.setText("懂你的每一首热爱");
        tagline.setTextColor(isDark
            ? Color.argb(0x99, 0xFF, 0xFF, 0xFF)  // 暗黑：60% 白色
            : Color.argb(0x99, 0x00, 0x00, 0x00)); // 亮色：60% 黑色
        tagline.setTextSize(14); // sp
        tagline.setLetterSpacing(0.08f);
        LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        textParams.topMargin = (int) (8 * density); // 名称与标语间距 8dp
        content.addView(tagline, textParams);

        FrameLayout.LayoutParams contentParams = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        contentParams.gravity = Gravity.CENTER;
        overlay.addView(content, contentParams);

        return overlay;
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
            NotificationChannel playbackChannel = new NotificationChannel("EcellsMusic_playback", "EcellsMusic 播放控制", NotificationManager.IMPORTANCE_LOW);
            playbackChannel.setShowBadge(false);
            nm.createNotificationChannel(playbackChannel);

            NotificationChannel lyricChannel = new NotificationChannel("EcellsMusic_lyric_overlay", "EcellsMusic 桌面歌词", NotificationManager.IMPORTANCE_LOW);
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