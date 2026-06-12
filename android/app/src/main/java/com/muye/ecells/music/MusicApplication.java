package com.muye.ecells.music;

import android.app.Application;
import android.util.Log;

import org.mozilla.geckoview.GeckoRuntime;

/**
 * 自定义 Application，持有 GeckoRuntime 的全局引用。
 * GeckoRuntime 的创建在 MainActivity 中并行初始化时完成，
 * 此处仅作为进程级单例的持有者，不提前创建（避免 Application 阶段环境不完整导致崩溃）。
 */
public class MusicApplication extends Application {

    private static final String TAG = "MusicApplication";
    private static GeckoRuntime sGeckoRuntime;

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "MusicApplication onCreate");
        // GeckoRuntime 的创建移至 MainActivity 的并行轨道B中，
        // 确保在 Activity 上下文中创建，避免 Application 阶段缺少必要环境。
    }

    /**
     * 获取 GeckoRuntime 实例。
     * @return GeckoRuntime 或 null（如果尚未创建）
     */
    public static GeckoRuntime getGeckoRuntime() {
        return sGeckoRuntime;
    }

    /**
     * 设置 GeckoRuntime 实例（由 MainActivity 的并行初始化轨道调用）。
     */
    public static void setGeckoRuntime(GeckoRuntime runtime) {
        sGeckoRuntime = runtime;
    }
}
