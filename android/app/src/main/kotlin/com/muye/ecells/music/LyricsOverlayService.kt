package com.muye.ecells.music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference

/**
 * 桌面歌词悬浮窗服务 —— 移植自易格音乐（E-cells-Music）LyricOverlayService.java。
 *
 * 与旧版（逐句/逐字 IPC 推送 + 前台隐藏自愈）的根本区别：
 * - **原生歌词引擎**：Flutter 侧整首歌词一次性下发（loadLyrics），本服务用
 *   单调时钟锚定播放位置、二分查找当前句、按"下一显示边界 - 40ms"精确延时
 *   自调度刷新，不再依赖逐句推送，也不存在"推送丢失空到下一句"的竞态。
 * - **常显**：开启即显示（含应用在前台），关闭即隐藏停服；没有前后台切换
 *   隐藏/重建那套机制。
 * - **无悬浮窗按钮**：锁定（=完全触摸穿透 + 背景透明）、关闭、宽度全部由
 *   设置页操作，与易格一致。
 */
class LyricsOverlayService : Service() {

    companion object {
        private const val TAG = "LyricOverlay"
        // 沿用时音旧通知 ID/渠道 ID：升级安装不会残留两条"桌面歌词"通知/渠道。
        private const val NOTIFICATION_ID = 9001
        private const val CHANNEL_ID = "shiyin_music.lyric_overlay"
        // 与易格同名（旧版时音是 lyrics_overlay_prefs，带 s；两文件互不影响，
        // 旧文件自然废弃）。注意别拼错。
        private const val PREFS_NAME = "lyric_overlay_prefs"

        private val LIGHT_COLOR_HEX = arrayOf(
            "#000000", "#333333", "#1A237E", "#880E4F", "#1B5E20", "#263238", "#4E342E"
        )
        private val DARK_COLOR_HEX = arrayOf(
            "#FFFFFF", "#E0E0E0", "#FFCA28", "#00E5FF", "#69F0AE", "#FF4081", "#B388FF"
        )

        // 提前唤醒量：给车机 CPU 留 UI 渲染准备时间（易格同值）。
        private const val RENDER_ADVANCE_MS = 40L
        private const val MIN_POLL_MS = 16L

        // 光感值（深色阈值）出厂默认与合法范围（与 Flutter 侧
        // AndroidLyricSettings 对齐）：环境亮度 ≤ 阈值判深色、≥ 阈值×2 判浅色，
        // 区间内保持原状态，避免车机光感跳动导致颜色抖动。阈值可由用户经
        // 设置页「光感值」调整（白天进隧道等场景调高，使歌词提前切深色）。
        private const val DEFAULT_SENSOR_DARK_THRESHOLD = 15f
        private const val SENSOR_DARK_THRESHOLD_MIN = 5f
        private const val SENSOR_DARK_THRESHOLD_MAX = 1000f

        /** 运行中实例（MainActivity 不经绑定直接调用公开方法，易格同构）。 */
        @Volatile
        private var instanceRef: WeakReference<LyricsOverlayService>? = null

        val instance: LyricsOverlayService?
            get() = instanceRef?.get()

        /**
         * 锁定状态经悬浮窗「锁定」按钮变更时回推 Flutter 的回调
         * （MainActivity 在配置引擎时注入）。同进程直调，无序列化开销；
         * 服务重建不丢线（挂在 companion 上）。
         */
        @Volatile
        var lockChangedListener: ((Boolean) -> Unit)? = null
    }

    /** 原生歌词行数据（Flutter 侧 JSON 解析产物）。 */
    data class LyricLineData(val timeMs: Long, val text: String, val translation: String)

    private lateinit var prefs: SharedPreferences
    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var line1: TextView? = null
    private var line2: TextView? = null
    private var controlBar: View? = null
    private var params: WindowManager.LayoutParams? = null
    private val handler = Handler(Looper.getMainLooper())

    var isVisible = false
        private set

    // ---- 设置项（默认值与 Flutter 侧 AndroidLyricSettings 对齐）----
    private var isLocked = false
    private var lightColorIndex = 0
    private var darkColorIndex = 0
    private var themeMode = "system" // light / dark / system / sensor
    private var fontSize = 18f
    private var doubleLine = true
    private var lyricWidthPercent = 100
    private var lyricStrokeEnabled = false
    private var lyricAlignment = "center" // left / center / right

    // 光感值（lux，深色阈值）：浅色阈值不单独存储，恒为深色阈值 ×2。
    private var sensorDarkThreshold = DEFAULT_SENSOR_DARK_THRESHOLD
    private var sensorLightThreshold = DEFAULT_SENSOR_DARK_THRESHOLD * 2f
    // 最近一次 lux 读数：阈值被用户调整时立即按新阈值重判，不等下一帧传感器事件。
    private var lastLux = -1f

    // 配置变化广播兜底：部分定制系统（尤其车机）不向后台 Service 回调
    // onConfigurationChanged，注册接收器补一条通路。
    private var configChangeReceiver: BroadcastReceiver? = null

    // 主题轮询兜底（system 模式）：上面两条通路都失灵时的最终保险。
    private var lastDetectedNightMode = -1
    private var themePollRunnable: Runnable? = null

    // 拖拽状态
    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false

    // ---- 原生歌词引擎状态 ----
    private var lyrics: List<LyricLineData> = emptyList()
    private var basePlaybackMs = 0L
    // 用 SystemClock.elapsedRealtime() 单调时钟，不受系统时间被改影响。
    private var baseElapsedMs = 0L
    private var isPlaying = false
    private var currentLineIndex = -1
    private var lyricTimerRunnable: Runnable? = null
    // 用户可调的悬浮窗歌词时间偏移（毫秒，作用于本引擎的位置计算）。
    private var lyricOffsetMs = 0L

    // 屏幕亮灭：灭屏暂停定时器/轮询/光感，亮屏恢复。
    private var screenReceiver: BroadcastReceiver? = null
    private var isScreenOn = true

    // 自主光感监听（sensor 模式）：脱离 Activity 生命周期，前台服务内闭环，
    // 让歌词在任何 App 覆盖到前台（如导航）时仍能实时变色。
    private var sensorManager: SensorManager? = null
    private var lightSensor: Sensor? = null
    private var isSensorDark = false
    private var hasInitSensorState = false
    private var lightSensorListener: SensorEventListener? = null

    override fun onCreate() {
        super.onCreate()
        instanceRef = WeakReference(this)
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        // 恢复持久化设置
        lightColorIndex = prefs.getInt("light_color_index", 0)
        darkColorIndex = prefs.getInt("dark_color_index", 0)
        themeMode = prefs.getString("theme_mode", "system") ?: "system"
        fontSize = prefs.getFloat("font_size", 18f)
        doubleLine = prefs.getBoolean("double_line", true)
        isLocked = prefs.getBoolean("is_locked", false)
        lyricWidthPercent = prefs.getInt("width_percent", 100)
        lyricStrokeEnabled = prefs.getBoolean("stroke_enabled", false)
        lyricAlignment = prefs.getString("alignment", "center") ?: "center"
        lyricOffsetMs = prefs.getLong("lyric_offset_ms", 0L)
        sensorDarkThreshold = prefs
            .getFloat("sensor_dark_threshold", DEFAULT_SENSOR_DARK_THRESHOLD)
            .coerceIn(SENSOR_DARK_THRESHOLD_MIN, SENSOR_DARK_THRESHOLD_MAX)
        sensorLightThreshold = sensorDarkThreshold * 2f

        createNotificationChannel()
        // 服务只在悬浮窗展示期间存活（开启=起服务、关闭=停服务），onCreate 即
        // 挂常驻通知，不存在旧版"幽灵通知"问题。
        // 三参调用显式带 mediaPlayback 类型（与 manifest 声明一致）；个别
        // 系统对该类型有活跃媒体会话等前置校验，失败回退两参调用再兜底——
        // 通知缺失不阻断悬浮窗展示。
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground(mediaPlayback) 失败，回退两参调用", e)
            runCatching { startForeground(NOTIFICATION_ID, buildNotification()) }
        }

        // 配置变化兜底接收器（见字段注释）。
        configChangeReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_CONFIGURATION_CHANGED && themeMode == "system") {
                    handler.post { applyColorToViews() }
                    Log.i(TAG, "BroadcastReceiver: system theme changed, reapplying lyric colors.")
                }
            }
        }
        ContextCompat.registerReceiver(
            this,
            configChangeReceiver,
            IntentFilter(Intent.ACTION_CONFIGURATION_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )

        lastDetectedNightMode =
            resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        startThemePolling()

        // 光感模式恢复：服务重建时若主题模式是 sensor，立即注册传感器。
        initSensorListener()
        if (themeMode == "sensor") {
            registerSensorIfNeeded()
        }

        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        isScreenOn = false
                        stopNativeLyricTimer()
                        stopThemePolling()
                        // 屏幕熄灭时注销光感监听，省电且歌词此时不可见。
                        unregisterSensor()
                        Log.i(TAG, "Screen off: paused lyric timer, theme polling and sensor")
                    }
                    Intent.ACTION_SCREEN_ON -> {
                        isScreenOn = true
                        if (isPlaying) {
                            startNativeLyricTimer()
                        }
                        startThemePolling()
                        registerSensorIfNeeded()
                        Log.i(TAG, "Screen on: resumed lyric timer, theme polling and sensor")
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            this,
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )

        Log.i(TAG, "LyricOverlayService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 服务由 MainActivity 显式 start/stop，无命令语义；不粘滞。
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopNativeLyricTimer()
        stopThemePolling()
        unregisterSensor()
        hideOverlay()
        configChangeReceiver?.let {
            runCatching { unregisterReceiver(it) }
                .onFailure { e -> Log.w(TAG, "Error unregistering configChangeReceiver", e) }
            configChangeReceiver = null
        }
        screenReceiver?.let {
            runCatching { unregisterReceiver(it) }
                .onFailure { e -> Log.w(TAG, "Error unregistering screenReceiver", e) }
            screenReceiver = null
        }
        instanceRef = null
        super.onDestroy()
        Log.i(TAG, "LyricOverlayService destroyed")
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 车机白天/黑夜模式切换时，跟随系统的配色需要重算。
        if (themeMode == "system") {
            handler.post { applyColorToViews() }
            Log.i(TAG, "System theme changed, reapplying lyric colors.")
        }
    }

    // ── 悬浮窗生命周期 ──

    fun showOverlay() {
        if (isVisible) return

        if (!Settings.canDrawOverlays(this)) {
            Log.e(TAG, "Overlay permission not granted, cannot show overlay")
            handler.post {
                Toast.makeText(
                    this,
                    "请在系统设置 -> 应用权限中允许易格音乐显示悬浮窗",
                    Toast.LENGTH_LONG
                ).show()
            }
            return
        }

        overlayView = LayoutInflater.from(this).inflate(R.layout.layout_floating_lyric, null)
        line1 = overlayView?.findViewById(R.id.lyric_line1)
        line2 = overlayView?.findViewById(R.id.lyric_line2)
        controlBar = overlayView?.findViewById(R.id.lyric_control_bar)
        wireControlButtons()

        // 跑马灯：无焦点窗口里 TextView 需要选中态才会滚动。
        line1?.isSelected = true
        line2?.isSelected = true

        // 应用持久化设置
        applyColorToViews()
        applyAlignmentToViews()
        applyStrokeToViews()
        line1?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        line2?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        line2?.visibility = if (doubleLine) View.VISIBLE else View.GONE

        @Suppress("DEPRECATION")
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager?.defaultDisplay?.getMetrics(metrics)
        val overlayWidth = metrics.widthPixels * lyricWidthPercent / 100

        params = WindowManager.LayoutParams(
            overlayWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // 恢复记忆位置，无记忆时默认靠近屏幕底部。
            val savedX = prefs.getInt("pos_x", -1)
            val savedY = prefs.getInt("pos_y", -1)
            if (savedX >= 0 && savedY >= 0) {
                x = savedX
                y = savedY
            } else {
                x = 0
                y = metrics.heightPixels - 300
            }
        }

        overlayView?.setOnTouchListener(dragListener)

        // 锁定态：穿透 + 透明 + 隐藏微调按钮（addView 前应用，flags 直接
        // 落在 params 上；updateViewLayout 未挂载时报错被 runCatching 吞掉）。
        if (isLocked) {
            applyLockToViews()
        } else {
            updateControlBarVisibility()
            updateLyricBackground()
        }

        try {
            windowManager?.addView(overlayView, params)
        } catch (e: Exception) {
            Log.w(TAG, "addView 失败", e)
            overlayView = null
            line1 = null
            line2 = null
            controlBar = null
            params = null
            return
        }
        isVisible = true
        prefs.edit().putBoolean("enabled", true).apply()
        // 建窗即按当前引擎状态刷一次内容（切歌/暂停期间重建也有正确的句子）。
        updateOverlayFromLyrics()
        Log.i(TAG, "Overlay shown")
    }

    fun hideOverlay() {
        if (!isVisible || overlayView == null) return
        try {
            windowManager?.removeView(overlayView)
        } catch (e: Exception) {
            Log.w(TAG, "Error removing overlay view", e)
        }
        overlayView = null
        line1 = null
        line2 = null
        controlBar = null
        isVisible = false
        stopNativeLyricTimer()
        prefs.edit().putBoolean("enabled", false).apply()
        Log.i(TAG, "Overlay hidden")
    }

    // ── 原生歌词引擎 ──

    /**
     * 整首歌词下发：Flutter 侧每首歌只推一次（切歌/歌词加载完成），
     * 之后由本引擎自行按时间轴推进。
     */
    fun loadLyrics(newLyrics: List<LyricLineData>?, currentTimeMs: Long, playing: Boolean) {
        lyrics = newLyrics ?: emptyList()
        basePlaybackMs = currentTimeMs
        baseElapsedMs = SystemClock.elapsedRealtime()
        isPlaying = playing
        currentLineIndex = -1
        startNativeLyricTimer()
        handler.post {
            if (playing && lyrics.isNotEmpty()) {
                val pos = currentPlaybackPosition()
                currentLineIndex = findLineIndex(pos)
                updateOverlayFromLyrics()
            } else if (lyrics.isEmpty()) {
                line1?.text = ""
                line2?.text = ""
            }
        }
    }

    fun setPlaybackState(playing: Boolean, currentTimeMs: Long) {
        basePlaybackMs = currentTimeMs
        baseElapsedMs = SystemClock.elapsedRealtime()
        isPlaying = playing
        if (playing) {
            startNativeLyricTimer()
        } else {
            stopNativeLyricTimer()
        }
    }

    fun seekTo(timeMs: Long) {
        basePlaybackMs = timeMs
        baseElapsedMs = SystemClock.elapsedRealtime()
        currentLineIndex = -1
        // 重启定时器：取消旧的（可能带长延迟），立即按新位置刷新并重排调度。
        if (isPlaying && lyrics.isNotEmpty()) {
            startNativeLyricTimer()
        }
    }

    /** 心跳校准：Flutter 侧每 30s 调一次，用精确位置重锚，防两端时钟漂移。 */
    fun calibratePosition(currentTimeMs: Long) {
        basePlaybackMs = currentTimeMs
        baseElapsedMs = SystemClock.elapsedRealtime()
    }

    private fun currentPlaybackPosition(): Long {
        if (!isPlaying) return basePlaybackMs + lyricOffsetMs
        return basePlaybackMs + (SystemClock.elapsedRealtime() - baseElapsedMs) + lyricOffsetMs
    }

    /** 二分查找：最后一条 timeMs <= pos 的行下标（无则 -1）。 */
    private fun findLineIndex(timeMs: Long): Int {
        var lo = 0
        var hi = lyrics.size - 1
        var result = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (lyrics[mid].timeMs <= timeMs) {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    private fun startNativeLyricTimer() {
        stopNativeLyricTimer()
        if (!isPlaying || lyrics.isEmpty()) return
        var lastPairStart = displayPairStart
        val runnable = object : Runnable {
            override fun run() {
                if (isPlaying && lyrics.isNotEmpty()) {
                    val pos = currentPlaybackPosition()
                    val newIndex = findLineIndex(pos)
                    if (newIndex != currentLineIndex) {
                        currentLineIndex = newIndex
                        if (doubleLine) {
                            // 双行模式：仅在 pairStart 变化时才刷新显示。
                            val newPairStart = displayPairStart
                            if (newPairStart != lastPairStart) {
                                lastPairStart = newPairStart
                                updateOverlayFromLyrics()
                            }
                        } else {
                            updateOverlayFromLyrics()
                        }
                    }
                }
                if (isPlaying) {
                    handler.postDelayed(this, computeLyricPollDelay())
                }
            }
        }
        lyricTimerRunnable = runnable
        handler.post(runnable)
    }

    /**
     * 计算距下一显示边界的精确毫秒数，提前 RENDER_ADVANCE_MS 唤醒给 UI
     * 渲染留时间——替代固定频率轮询，车机低性能 CPU 友好。
     */
    private fun computeLyricPollDelay(): Long {
        val nextIdx: Int = if (doubleLine && currentLineIndex >= 0) {
            // 双行模式：下一个关键时间点是 pairStart + 2 那行的起始时间。
            displayPairStart + 2
        } else {
            currentLineIndex + 1
        }
        if (nextIdx >= lyrics.size) {
            return 2000 // 末句之后不再有变化，低频空转
        }
        val pos = currentPlaybackPosition()
        val timeUntilNext = lyrics[nextIdx].timeMs - pos
        if (timeUntilNext <= 0) {
            return MIN_POLL_MS // 已过该时间点，立即重试
        }
        val delay = timeUntilNext - RENDER_ADVANCE_MS
        return delay.coerceAtLeast(MIN_POLL_MS)
    }

    private fun stopNativeLyricTimer() {
        lyricTimerRunnable?.let { handler.removeCallbacks(it) }
        lyricTimerRunnable = null
    }

    /**
     * 双行模式下当前应显示的 pair 起始索引。
     * 双行成对推进：歌手唱完第 N+1 行后才切换到 (N+2, N+3)。
     */
    private val displayPairStart: Int
        get() = if (doubleLine && currentLineIndex >= 0) {
            (currentLineIndex / 2) * 2
        } else {
            currentLineIndex
        }

    private fun updateOverlayFromLyrics() {
        val l1 = line1 ?: return
        val l2 = line2 ?: return
        if (currentLineIndex < 0 || currentLineIndex >= lyrics.size) {
            l1.text = ""
            l2.text = ""
            return
        }

        if (doubleLine) {
            // 双行成对模式：用 pairStart 决定显示哪两行。
            val pairStart = displayPairStart
            if (pairStart < 0 || pairStart >= lyrics.size) {
                l1.text = ""
                l2.text = ""
                return
            }
            l1.text = lyrics[pairStart].text
            val second = pairStart + 1
            l2.text = if (second < lyrics.size) lyrics[second].text else ""
        } else {
            // 单行模式：当前句 + 翻译（无翻译回退下一句文本）。
            val current = lyrics[currentLineIndex]
            l1.text = current.text
            val next = currentLineIndex + 1
            l2.text = when {
                current.translation.isNotEmpty() -> current.translation
                next < lyrics.size -> lyrics[next].text
                else -> ""
            }
        }
        // setText 会打断跑马灯，刷新后必须重设选中态。
        l1.isSelected = true
        l2.isSelected = true
    }

    // ── 设置应用（易格哨兵语义：非法/未变值不落盘不刷新）──

    fun applySettings(
        newLightColorIndex: Int,
        newDarkColorIndex: Int,
        newThemeMode: String?,
        newFontSize: Float,
        newDoubleLine: Boolean,
        newLocked: Boolean?,
        newWidthPercent: Int,
        newStrokeEnabled: Boolean,
        newAlignment: String?,
        newLyricOffsetMs: Long,
        newSensorDarkThreshold: Float,
    ) {
        if (newLightColorIndex in LIGHT_COLOR_HEX.indices) {
            lightColorIndex = newLightColorIndex
            prefs.edit().putInt("light_color_index", lightColorIndex).apply()
        }
        if (newDarkColorIndex in DARK_COLOR_HEX.indices) {
            darkColorIndex = newDarkColorIndex
            prefs.edit().putInt("dark_color_index", darkColorIndex).apply()
        }
        val themeChanged = newThemeMode != null &&
            newThemeMode in listOf("light", "dark", "system", "sensor") &&
            newThemeMode != themeMode
        val oldThemeMode = themeMode
        if (themeChanged) {
            themeMode = newThemeMode!!
            prefs.edit().putString("theme_mode", themeMode).apply()
        }
        if (newFontSize > 0f) {
            fontSize = newFontSize
            prefs.edit().putFloat("font_size", fontSize).apply()
        }
        val lineModeChanged = newDoubleLine != doubleLine
        if (lineModeChanged) {
            doubleLine = newDoubleLine
            prefs.edit().putBoolean("double_line", doubleLine).apply()
        }
        val lockChanged = newLocked != null && newLocked != isLocked
        if (lockChanged) {
            isLocked = newLocked!!
            prefs.edit().putBoolean("is_locked", isLocked).apply()
        }
        val widthChanged = newWidthPercent in 10..100 && newWidthPercent != lyricWidthPercent
        if (widthChanged) {
            lyricWidthPercent = newWidthPercent
            prefs.edit().putInt("width_percent", lyricWidthPercent).apply()
        }
        val strokeChanged = newStrokeEnabled != lyricStrokeEnabled
        if (strokeChanged) {
            lyricStrokeEnabled = newStrokeEnabled
            prefs.edit().putBoolean("stroke_enabled", lyricStrokeEnabled).apply()
        }
        val alignmentChanged = newAlignment != null && newAlignment != lyricAlignment
        if (alignmentChanged) {
            lyricAlignment = newAlignment!!
            prefs.edit().putString("alignment", lyricAlignment).apply()
        }
        // Long.MIN_VALUE 为哨兵值：表示 Flutter 侧未传递此参数，不覆盖当前值。
        if (newLyricOffsetMs != Long.MIN_VALUE && newLyricOffsetMs != lyricOffsetMs) {
            lyricOffsetMs = newLyricOffsetMs
            prefs.edit().putLong("lyric_offset_ms", lyricOffsetMs).apply()
        }
        // -1f 为哨兵值：表示 Flutter 侧未传递光感值，不覆盖当前值。
        val thresholdChanged = newSensorDarkThreshold >= SENSOR_DARK_THRESHOLD_MIN &&
            newSensorDarkThreshold != sensorDarkThreshold
        if (thresholdChanged) {
            sensorDarkThreshold =
                newSensorDarkThreshold.coerceAtMost(SENSOR_DARK_THRESHOLD_MAX)
            sensorLightThreshold = sensorDarkThreshold * 2f
            prefs.edit().putFloat("sensor_dark_threshold", sensorDarkThreshold).apply()
        }

        handler.post {
            if (line1 == null || overlayView == null) return@post
            // 光感值刚被调整：先按最近读数重判深浅，再统一重绘歌词颜色。
            if (thresholdChanged) {
                recomputeSensorState()
            }
            applyColorToViews()
            // system 轮询 / sensor 光感的启停与主题模式变化保持对称。
            if (themeChanged) {
                if (themeMode == "system") {
                    startThemePolling()
                } else if (oldThemeMode == "system") {
                    stopThemePolling()
                }
                if (themeMode == "sensor") {
                    registerSensorIfNeeded()
                } else if (oldThemeMode == "sensor") {
                    unregisterSensor()
                }
            }
            line1?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
            line2?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
            line2?.visibility = if (doubleLine) View.VISIBLE else View.GONE
            if (lockChanged) {
                applyLockToViews()
            }
            if (widthChanged) {
                params?.let { lp ->
                    @Suppress("DEPRECATION")
                    val metrics = DisplayMetrics()
                    @Suppress("DEPRECATION")
                    windowManager?.defaultDisplay?.getMetrics(metrics)
                    lp.width = metrics.widthPixels * lyricWidthPercent / 100
                    runCatching { windowManager?.updateViewLayout(overlayView, lp) }
                }
            }
            if (strokeChanged) {
                applyStrokeToViews()
            }
            if (alignmentChanged) {
                applyAlignmentToViews()
            }
            // 单双行切换后立即按新行数刷新内容并重启调度：pair 语义变化
            // （单行→双行时 displayPairStart 与定时器闭包里记住的
            // lastPairStart 不再可比），不重启会错位到下一次换句。
            if (lineModeChanged) {
                currentLineIndex = findLineIndex(currentPlaybackPosition())
                updateOverlayFromLyrics()
                if (isPlaying && lyrics.isNotEmpty()) {
                    startNativeLyricTimer()
                }
            }
        }
    }

    // ── 拖拽 ──

    private val dragListener = View.OnTouchListener { _, event ->
        if (isLocked) return@OnTouchListener false
        val lp = params ?: return@OnTouchListener false
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                initialX = lp.x
                initialY = lp.y
                initialTouchX = event.rawX
                initialTouchY = event.rawY
                isDragging = false
                true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - initialTouchX
                val dy = event.rawY - initialTouchY
                if (!isDragging && (kotlin.math.abs(dx) > 10 || kotlin.math.abs(dy) > 10)) {
                    isDragging = true
                }
                if (isDragging) {
                    lp.x = initialX + dx.toInt()
                    lp.y = initialY + dy.toInt()
                    clampToScreen(lp)
                    runCatching { windowManager?.updateViewLayout(overlayView, lp) }
                }
                true
            }
            MotionEvent.ACTION_UP -> {
                if (isDragging) {
                    prefs.edit()
                        .putInt("pos_x", lp.x)
                        .putInt("pos_y", lp.y)
                        .apply()
                }
                isDragging = false
                true
            }
            else -> false
        }
    }

    private fun clampToScreen(lp: WindowManager.LayoutParams) {
        @Suppress("DEPRECATION")
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager?.defaultDisplay?.getMetrics(metrics)
        var viewWidth = overlayView?.width ?: 0
        if (viewWidth <= 0) viewWidth = lp.width
        var viewHeight = overlayView?.height ?: 0
        if (viewHeight <= 0) viewHeight = lp.height

        val maxX = metrics.widthPixels - viewWidth
        val maxY = metrics.heightPixels - viewHeight
        lp.x = lp.x.coerceIn(0, maxX.coerceAtLeast(0))
        lp.y = lp.y.coerceIn(0, maxY.coerceAtLeast(0))
    }

    // ── 颜色 / 主题 ──

    /**
     * 光感监听器（sensor 模式专用）：迟滞防抖 + 直接重绘歌词颜色，
     * 使歌词在应用被其他应用覆盖到后台时仍能实时变色。
     */
    private fun initSensorListener() {
        if (lightSensorListener != null) return
        lightSensorListener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (event.sensor.type != Sensor.TYPE_LIGHT) return
                val lux = event.values[0]
                lastLux = lux
                var stateChanged = false
                if (lux <= sensorDarkThreshold) {
                    if (!isSensorDark || !hasInitSensorState) {
                        isSensorDark = true
                        hasInitSensorState = true
                        stateChanged = true
                    }
                } else if (lux >= sensorLightThreshold) {
                    if (isSensorDark || !hasInitSensorState) {
                        isSensorDark = false
                        hasInitSensorState = true
                        stateChanged = true
                    }
                }
                if (stateChanged && themeMode == "sensor") {
                    Log.i(TAG, "Sensor light changed ($lux lux) -> ${if (isSensorDark) "dark" else "light"}")
                    handler.post { applyColorToViews() }
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
    }

    private fun registerSensorIfNeeded() {
        if (themeMode != "sensor" || !isScreenOn) return
        if (sensorManager == null) {
            sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        }
        if (lightSensor == null) {
            lightSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_LIGHT)
        }
        if (lightSensor == null) {
            Log.w(TAG, "No TYPE_LIGHT sensor on device; sensor mode falls back to system UI mode")
            return
        }
        // initSensorListener 幂等，重复调用安全。
        initSensorListener()
        sensorManager?.registerListener(
            lightSensorListener, lightSensor, SensorManager.SENSOR_DELAY_NORMAL
        )
        Log.i(TAG, "Light sensor registered for lyric color (sensor mode)")
    }

    private fun unregisterSensor() {
        if (sensorManager != null && lightSensorListener != null) {
            sensorManager?.unregisterListener(lightSensorListener)
            Log.i(TAG, "Light sensor unregistered")
        }
    }

    /**
     * 光感值被用户调整后，按最近一次 lux 读数立即重判深浅状态（不等下一帧
     * 传感器事件）。只更新状态；重绘由调用方随后的 applyColorToViews 完成。
     */
    private fun recomputeSensorState() {
        if (lastLux < 0f) return
        if (lastLux <= sensorDarkThreshold) {
            if (!isSensorDark || !hasInitSensorState) {
                isSensorDark = true
                hasInitSensorState = true
                Log.i(TAG, "Sensor threshold adjusted; recompute ($lastLux lux) -> dark")
            }
        } else if (lastLux >= sensorLightThreshold) {
            if (isSensorDark || !hasInitSensorState) {
                isSensorDark = false
                hasInitSensorState = true
                Log.i(TAG, "Sensor threshold adjusted; recompute ($lastLux lux) -> light")
            }
        }
    }

    private fun applyColorToViews() {
        val l1 = line1 ?: return
        val l2 = line2 ?: return
        val colorArray: Array<String>
        val colorIdx: Int
        when (themeMode) {
            "light" -> {
                colorArray = LIGHT_COLOR_HEX
                colorIdx = lightColorIndex
            }
            "dark" -> {
                colorArray = DARK_COLOR_HEX
                colorIdx = darkColorIndex
            }
            "sensor" -> {
                // 尚未拿到读数时回退系统 UI 模式，避免首帧空白。
                val isDark = if (hasInitSensorState) isSensorDark
                else (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                    Configuration.UI_MODE_NIGHT_YES
                colorArray = if (isDark) DARK_COLOR_HEX else LIGHT_COLOR_HEX
                colorIdx = if (isDark) darkColorIndex else lightColorIndex
            }
            else -> {
                val nightMode =
                    resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
                val isDark = nightMode == Configuration.UI_MODE_NIGHT_YES
                colorArray = if (isDark) DARK_COLOR_HEX else LIGHT_COLOR_HEX
                colorIdx = if (isDark) darkColorIndex else lightColorIndex
            }
        }
        val color = Color.parseColor(colorArray[colorIdx])
        l1.setTextColor(color)
        l2.setTextColor(color)
    }

    /**
     * 仅在 system 模式且亮屏时轮询（配置广播与 onConfigurationChanged 都
     * 失灵时的最终兜底）。
     */
    private fun startThemePolling() {
        stopThemePolling()
        if (themeMode != "system" || !isScreenOn) return
        val runnable = object : Runnable {
            override fun run() {
                if (themeMode == "system" && isVisible && isScreenOn) {
                    val currentNightMode =
                        resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
                    if (lastDetectedNightMode >= 0 && currentNightMode != lastDetectedNightMode) {
                        applyColorToViews()
                        Log.i(TAG, "Theme poll: system theme changed, reapplying lyric colors.")
                    }
                    lastDetectedNightMode = currentNightMode
                }
                if (themeMode == "system" && isScreenOn) {
                    handler.postDelayed(this, 120000)
                }
            }
        }
        themePollRunnable = runnable
        handler.postDelayed(runnable, 120000)
    }

    private fun stopThemePolling() {
        themePollRunnable?.let { handler.removeCallbacks(it) }
        themePollRunnable = null
    }

    // ── 外观细节 ──

    private fun updateLyricBackground() {
        val root = overlayView ?: return
        if (isLocked) {
            root.setBackgroundColor(Color.TRANSPARENT)
        } else {
            root.setBackgroundResource(R.drawable.bg_floating_lyric)
        }
    }

    // ── 悬浮窗微调按钮行（未锁定时可见）──

    /** 微调步进：5dp/次。拖动是粗定位，按钮是车机上更稳的细定位。 */
    private val nudgeStepPx: Int
        get() = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, 5f, resources.displayMetrics
        ).toInt()

    private fun wireControlButtons() {
        val root = overlayView ?: return
        root.findViewById<View>(R.id.lyric_btn_nudge_left)
            ?.setOnClickListener { nudgeOverlay(-nudgeStepPx, 0) }
        root.findViewById<View>(R.id.lyric_btn_nudge_right)
            ?.setOnClickListener { nudgeOverlay(nudgeStepPx, 0) }
        root.findViewById<View>(R.id.lyric_btn_nudge_up)
            ?.setOnClickListener { nudgeOverlay(0, -nudgeStepPx) }
        root.findViewById<View>(R.id.lyric_btn_nudge_down)
            ?.setOnClickListener { nudgeOverlay(0, nudgeStepPx) }
        root.findViewById<View>(R.id.lyric_btn_lock)
            ?.setOnClickListener { lockFromControlBar() }
    }

    /** 按微调步进移动悬浮窗并持久化位置（与拖拽落点同一份 pos_x/pos_y）。 */
    private fun nudgeOverlay(dx: Int, dy: Int) {
        val view = overlayView ?: return
        val lp = params ?: return
        lp.x += dx
        lp.y += dy
        clampToScreen(lp)
        runCatching { windowManager?.updateViewLayout(view, lp) }
        prefs.edit().putInt("pos_x", lp.x).putInt("pos_y", lp.y).apply()
    }

    /** 悬浮窗「锁定」按钮：语义与设置页锁定开关一致，另回推 Flutter
     *  同步设置页开关状态（解锁入口仍在设置页）。 */
    private fun lockFromControlBar() {
        if (isLocked) return
        isLocked = true
        prefs.edit().putBoolean("is_locked", true).apply()
        applyLockToViews()
        Log.i(TAG, "Locked from floating control bar")
        lockChangedListener?.invoke(true)
    }

    /** 把当前锁定态落到窗口：触摸穿透、透明背景、微调按钮行显隐。 */
    private fun applyLockToViews() {
        val root = overlayView ?: return
        root.setOnTouchListener(if (isLocked) null else dragListener)
        updateTouchableFlag()
        updateLyricBackground()
        updateControlBarVisibility()
    }

    private fun updateControlBarVisibility() {
        controlBar?.visibility = if (isLocked) View.GONE else View.VISIBLE
    }

    private fun updateTouchableFlag() {
        val view = overlayView ?: return
        val lp = params ?: return
        lp.flags = if (isLocked) {
            lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        } else {
            lp.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        }
        runCatching { windowManager?.updateViewLayout(view, lp) }
    }

    private fun applyStrokeToViews() {
        val l1 = line1 ?: return
        val l2 = line2 ?: return
        if (lyricStrokeEnabled) {
            val strokeWidth = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP, fontSize * 0.04f, resources.displayMetrics
            )
            for (tv in listOf(l1, l2)) {
                tv.paint.style = Paint.Style.FILL_AND_STROKE
                tv.paint.strokeWidth = strokeWidth
                tv.setShadowLayer(strokeWidth, 0f, 0f, Color.BLACK)
            }
        } else {
            for (tv in listOf(l1, l2)) {
                tv.paint.style = Paint.Style.FILL
                tv.paint.strokeWidth = 0f
                tv.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
            }
        }
    }

    private fun applyAlignmentToViews() {
        val container = overlayView?.findViewById<LinearLayout>(R.id.lyric_text_container)
            ?: return
        val gravity = when (lyricAlignment) {
            "left" -> Gravity.START
            "right" -> Gravity.END
            else -> Gravity.CENTER
        }
        container.gravity = gravity
        container.setPadding(0, 0, 0, 0)
    }

    // ── 通知 ──

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "桌面歌词悬浮窗服务"
                setShowBadge(false)
            }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_lyrics_on)
            .setContentTitle("易格音乐 桌面歌词")
            .setContentText("桌面歌词正在运行")
            .setContentIntent(pending)
            .setShowWhen(false)
            .setOngoing(true)
            .build()
    }
}
