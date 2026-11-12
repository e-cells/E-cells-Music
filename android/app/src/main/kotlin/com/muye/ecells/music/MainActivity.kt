package com.muye.ecells.music

import android.Manifest
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.app.SearchManager
import android.provider.MediaStore
import android.provider.Settings
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import android.os.Handler
import android.util.Log
import android.os.Looper
import android.view.WindowManager
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import com.hchen.superlyricapi.SuperLyricHelper
import com.hchen.superlyricapi.SuperLyricData
import com.hchen.superlyricapi.SuperLyricLine
import com.hchen.superlyricapi.SuperLyricWord
import java.io.File
import kotlin.concurrent.thread

class MainActivity : AudioServiceActivity() {
    // 易格音乐同款启动画面（LaunchTheme = Theme.SplashScreen）：必须在
    // super.onCreate 之前安装，否则 API 31+ 不应用自定义启动屏、26-30 无
    // 兼容层。经 SplashCompat（Java 桥接）调用：core-splashscreen 把
    // installSplashScreen 编译成伴生扩展形态，本项目 Kotlin 2.2.20 无法
    // 解析该符号，Java 静态调用不受影响。
    override fun onCreate(savedInstanceState: Bundle?) {
        SplashCompat.install(this)
        super.onCreate(savedInstanceState)
    }

    private val updateDownloads = mutableMapOf<Long, String>()
    private var downloadReceiverRegistered = false
    private var desktopLyricsChannel: MethodChannel? = null
    // 语音点歌（系统助手/车机语音）：冷启动时 Flutter 引擎尚未就绪，
    // query 先暂存在原生侧，Dart 侧 init 完成后经 ready 冲刷（易格同构）。
    private var voiceSearchChannel: MethodChannel? = null
    private var voiceSearchDartReady = false
    private var pendingVoiceSearchQuery: String? = null
    private var superLyricChannel: MethodChannel? = null
    private var superLyricRegistered = false
    // audio_effects channel 引用,供响度分析中途反向 invokeMethod 推进度给 Dart。
    private var audioEffectsChannel: MethodChannel? = null
    private var bassBoost: BassBoost? = null
    private var bassBoostSessionId: Int? = null
    private var equalizer: Equalizer? = null
    private var equalizerSessionId: Int? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int? = null
    private var virtualizer: Virtualizer? = null
    private var virtualizerSessionId: Int? = null
    // 当前响度分析的取消标志。切歌时调用 cancelLoudnessAnalysis 置 true,
    // 让解码循环立即结束,避免旧歌曲分析空跑占 CPU。
    @Volatile private var loudnessAnalysisCancelled: Boolean = false
    private var pendingPermissionResult: MethodChannel.Result? = null
    // 自定义下载路径（storage_access channel）的运行时写权限请求结果。
    private var pendingWritePermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val REQUEST_READ_AUDIO = 1001
        private const val REQUEST_WRITE_STORAGE = 1002
        private const val TAG_SUPER_LYRIC = "SuperLyricPublisher"
        private const val TAG_BLUETOOTH_LYRICS = "BluetoothLyrics"
        private const val TAG_LYRICS_OVERLAY = "LyricsOverlay"
        private const val TAG_VOICE_SEARCH = "VoiceSearch"
        private const val TAG_STORAGE_ACCESS = "StorageAccess"
    }

    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
            val fileName = updateDownloads.remove(downloadId) ?: return
            if (isDownloadSuccessful(downloadId)) {
                installDownloadedApk(fileName)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 车机检测：isAutomotive 判别车机。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAutomotive" -> result.success(isAutomotiveDevice())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "ecells_update.apk"
                        if (url.isNullOrBlank()) {
                            result.error("invalid_url", "APK download url is empty", null)
                            return@setMethodCallHandler
                        }

                        runCatching {
                            enqueueApkDownload(url, fileName)
                        }.onSuccess {
                            result.success(null)
                        }.onFailure { error ->
                            result.error("download_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/audio_effects")
            .also { audioEffectsChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getEqualizerConfig" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        runCatching {
                            equalizerConfig(audioSessionId)
                        }.onSuccess { config ->
                            result.success(config)
                        }.onFailure { error ->
                            result.error("equalizer_config_failed", error.message, null)
                        }
                    }
                    "configureEqualizer" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val levels = call.argument<List<Int>>("levels") ?: emptyList()

                        runCatching {
                            configureEqualizer(audioSessionId, enabled, levels)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseEqualizer()
                            result.error("equalizer_failed", error.message, null)
                        }
                    }
                    "configureBassBoost" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val strength = call.argument<Int>("strength") ?: 0

                        runCatching {
                            configureBassBoost(audioSessionId, enabled, strength)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseBassBoost()
                            result.error("bass_boost_failed", error.message, null)
                        }
                    }
                    "configureVirtualizer" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val strength = call.argument<Int>("strength") ?: 0

                        runCatching {
                            configureVirtualizer(audioSessionId, enabled, strength)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseVirtualizer()
                            result.error("virtualizer_failed", error.message, null)
                        }
                    }
                    "analyzeLoudness" -> {
                        val url = call.argument<String>("url")
                        val maxDurationMs = call.argument<Int>("maxDurationMs") ?: 1800000
                        val progressIntervalMs = call.argument<Int>("progressIntervalMs") ?: 500
                        if (url.isNullOrBlank()) {
                            result.error("invalid_url", "url is null or empty", null)
                            return@setMethodCallHandler
                        }
                        Log.i("Loudness", "channel analyzeLoudness 收到 url=$url interval=${progressIntervalMs}ms")
                        // 每次新分析重置取消标志。切歌时 Dart 侧调 cancelLoudnessAnalysis
                        // 置 true,解码循环检测到后立即抛异常结束,不再空跑。
                        loudnessAnalysisCancelled = false
                        val channel = audioEffectsChannel
                        thread {
                            try {
                                val analyzed = LoudnessAnalyzer.analyze(
                                    url,
                                    maxDurationMs,
                                    progressIntervalMs,
                                    isCancelled = { loudnessAnalysisCancelled },
                                    onProgress = { lufs, analyzedMs ->
                                        // 反向 invokeMethod 把中途 LUFS 推给 Dart,
                                        // Dart 侧用序号守卫决定是否应用。切到主线程调用
                                        // (Flutter MethodChannel 要求主线程)。
                                        if (channel != null && !loudnessAnalysisCancelled) {
                                            mainHandler.post {
                                                channel.invokeMethod(
                                                    "onLoudnessProgress",
                                                    mapOf(
                                                        "lufs" to lufs,
                                                        "analyzedMs" to analyzedMs
                                                    )
                                                )
                                            }
                                        }
                                    },
                                )
                                mainHandler.post {
                                    result.success(
                                        mapOf(
                                            "lufs" to analyzed.lufs,
                                            "sampleRate" to analyzed.sampleRate,
                                            "analyzedMs" to analyzed.analyzedMs
                                        )
                                    )
                                }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    if (loudnessAnalysisCancelled) {
                                        // 取消不算失败,返回 success(false) 让 Dart 侧
                                        // 走"已丢弃"路径(序号守卫也会拦截)。
                                        result.success(null)
                                    } else {
                                        result.error("analyze_failed", e.message, null)
                                    }
                                }
                            }
                        }
                    }
                    "cancelLoudnessAnalysis" -> {
                        // 切歌时调用,让正在跑的解码循环立即结束。
                        Log.i("Loudness", "channel cancelLoudnessAnalysis 取消在途分析")
                        loudnessAnalysisCancelled = true
                        result.success(true)
                    }
                    "configureLoudnessGain" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val gainMb = call.argument<Int>("gainMb") ?: 0
                        Log.i("Loudness", "channel configureLoudnessGain enabled=$enabled gainMb=$gainMb session=$audioSessionId")

                        runCatching {
                            configureLoudnessGain(audioSessionId, enabled, gainMb)
                        }.onSuccess { supported ->
                            Log.i("Loudness", "configureLoudnessGain 成功 supported=$supported gainMb=$gainMb")
                            result.success(supported)
                        }.onFailure { error ->
                            Log.e("Loudness", "configureLoudnessGain 失败 gainMb=$gainMb", error)
                            releaseLoudnessGain()
                            result.error("loudness_gain_failed", error.message, null)
                        }
                    }
                    "releaseLoudnessGain" -> {
                        releaseLoudnessGain()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/local_music")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> {
                        result.success(hasReadAudioPermission())
                    }
                    "requestPermission" -> {
                        if (hasReadAudioPermission()) {
                            result.success(true)
                        } else {
                            pendingPermissionResult = result
                            requestAudioPermission()
                        }
                    }
                    "getLocalSongs" -> {
                        if (!hasReadAudioPermission()) {
                            result.error("no_permission", "READ_MEDIA_AUDIO permission not granted", null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            queryLocalSongs()
                        }.onSuccess { songs ->
                            result.success(songs)
                        }.onFailure { error ->
                            result.error("query_failed", error.message, null)
                        }
                    }
                    "getAlbumArt" -> {
                        val albumId = call.argument<Number>("albumId")?.toLong()
                        if (albumId == null || albumId <= 0) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            getAlbumArtBytes(albumId)
                        }.onSuccess { bytes ->
                            result.success(bytes)
                        }.onFailure { error ->
                            result.error("album_art_failed", error.message, null)
                        }
                    }
                    "getEmbeddedLyrics" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrEmpty()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            getEmbeddedLyrics(filePath)
                        }.onSuccess { lyrics ->
                            result.success(lyrics)
                        }.onFailure { error ->
                            result.error("lyrics_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 自定义下载路径的公共目录写权限桥（设置-下载位置）：
        // API≤29 用 WRITE_EXTERNAL_STORAGE 运行时弹窗（配 manifest 的
        // requestLegacyExternalStorage，Android 10 也可裸写路径）；
        // API30+ 分区存储下改为用户在系统设置授予「所有文件访问」
        // （MANAGE_EXTERNAL_STORAGE），跳转后 Dart 侧经 onResume 重查。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/storage_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasWritePermission" -> {
                        result.success(hasWriteStoragePermission())
                    }
                    "requestWritePermission" -> {
                        if (hasWriteStoragePermission()) {
                            result.success(true)
                        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            // 已授权直接放行；否则跳「所有文件访问」设置页，
                            // 本调用不回布尔值（null=已跳转，回来后重查）。
                            try {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(null)
                            } catch (error: Exception) {
                                // 个别 ROM 精简了该 Activity：兜底到通用
                                // 「所有文件访问」列表页。
                                runCatching {
                                    val fallback = Intent(
                                        Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION
                                    )
                                    fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(fallback)
                                }
                                Log.w(TAG_STORAGE_ACCESS, "跳转所有文件访问设置失败: ${error.message}")
                                result.success(null)
                            }
                        } else {
                            pendingWritePermissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                REQUEST_WRITE_STORAGE
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 桌面歌词（易格方案）：服务实例驱动，不再经 intent action 派发。
        // Flutter 侧整首歌词一次下发（loadLyrics），原生引擎自算当前句。
        desktopLyricsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "shiyin_music/desktop_lyrics"
        )
        desktopLyricsChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }
                    "show" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("no_permission", "No overlay permission", null)
                            return@setMethodCallHandler
                        }
                        // 易格模式：起前台服务 + 300ms 延迟建窗（给 startForeground
                        // 留落地时间）。服务可能因重建而 instance 为空，延迟到
                        // handler 里再取实例。
                        runCatching {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(
                                    Intent(this, LyricsOverlayService::class.java)
                                )
                            } else {
                                startService(Intent(this, LyricsOverlayService::class.java))
                            }
                        }.onFailure {
                            Log.w(TAG_LYRICS_OVERLAY, "启动歌词服务失败: ${it.message}")
                        }
                        mainHandler.postDelayed({
                            LyricsOverlayService.instance?.showOverlay()
                        }, 300)
                        result.success(null)
                    }
                    "hide" -> {
                        LyricsOverlayService.instance?.hideOverlay()
                        runCatching { stopService(Intent(this, LyricsOverlayService::class.java)) }
                        result.success(null)
                    }
                    "loadLyrics" -> {
                        // 整首歌词一次下发：[{timeMs, text, translation}] JSON。
                        val lyricsJson = call.argument<String>("lyrics") ?: "[]"
                        val currentTimeMs = (call.argument<Number>("currentTimeMs") ?: 0).toLong()
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val lines = parseLyricLines(lyricsJson)
                        withLyricService { it.loadLyrics(lines, currentTimeMs, isPlaying) }
                        result.success(null)
                    }
                    "setPlaybackState" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val currentTimeMs = (call.argument<Number>("currentTimeMs") ?: 0).toLong()
                        withLyricService { it.setPlaybackState(isPlaying, currentTimeMs) }
                        result.success(null)
                    }
                    "seekTo" -> {
                        val currentTimeMs = (call.argument<Number>("currentTimeMs") ?: 0).toLong()
                        withLyricService { it.seekTo(currentTimeMs) }
                        result.success(null)
                    }
                    "calibratePosition" -> {
                        val currentTimeMs = (call.argument<Number>("currentTimeMs") ?: 0).toLong()
                        withLyricService { it.calibratePosition(currentTimeMs) }
                        result.success(null)
                    }
                    "updateSettings" -> {
                        // 易格字段集 + 哨兵语义：非法/缺省值不覆盖当前值
                        //（见 LyricsOverlayService.applySettings）。
                        val lightColorIndex = call.argument<Number>("lightColorIndex")?.toInt() ?: -1
                        val darkColorIndex = call.argument<Number>("darkColorIndex")?.toInt() ?: -1
                        val themeMode = call.argument<String>("themeMode")
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 0f
                        val doubleLine = call.argument<Boolean>("doubleLine")
                        val locked = call.argument<Boolean>("locked")
                        val widthPercent = call.argument<Number>("widthPercent")?.toInt() ?: -1
                        val strokeEnabled = call.argument<Boolean>("strokeEnabled") ?: false
                        val alignment = call.argument<String>("alignment")
                        val lyricOffsetMs = (call.argument<Number>("lyricOffsetMs")
                            ?: Long.MIN_VALUE).toLong()
                        // 光感值（-1f 哨兵 = 未传，不覆盖）
                        val sensorDarkThreshold = (call.argument<Number>("sensorDarkThreshold")
                            ?: -1.0).toFloat()
                        withLyricService {
                            it.applySettings(
                                lightColorIndex,
                                darkColorIndex,
                                themeMode,
                                fontSize,
                                doubleLine ?: true,
                                locked,
                                widthPercent,
                                strokeEnabled,
                                alignment,
                                lyricOffsetMs,
                                sensorDarkThreshold
                            )
                        }
                        result.success(null)
                    }
                    "isVisible" -> {
                        result.success(LyricsOverlayService.instance?.isVisible == true)
                    }
                    // 通知卡片自定义按钮（桌面歌词开关等）在应用后台时触发，
                    // Flutter 侧的应用内 Toast 不可见，只能走原生 Toast 提示。
                    "showToast" -> {
                        val message = call.argument<String>("message") ?: ""
                        Log.d("SYNOTIF", "showToast: $message")
                        if (message.isNotEmpty()) {
                            runCatching {
                                Toast.makeText(
                                    applicationContext,
                                    message,
                                    Toast.LENGTH_LONG
                                ).show()
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 悬浮窗「锁定」按钮：锁定状态经服务回推 Flutter，同步设置页开关。
        // 挂在 companion 上，服务重建不丢线；回调统一切主线程（MethodChannel
        // 要求主线程调用）。
        LyricsOverlayService.lockChangedListener = { locked ->
            mainHandler.post {
                desktopLyricsChannel?.invokeMethod(
                    "onLockChanged",
                    mapOf("locked" to locked)
                )
            }
        }

        // SuperLyric 系统歌词发布（Xposed）
        superLyricChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "shiyin_music/super_lyric"
        )
        superLyricChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> {
                    runCatching {
                        SuperLyricHelper.isAvailable()
                    }.onSuccess { available ->
                        result.success(available)
                    }.onFailure { error ->
                        Log.w(TAG_SUPER_LYRIC, "isAvailable failed: ${error.message}")
                        result.success(false)
                    }
                }
                "registerPublisher" -> {
                    runCatching {
                        if (!superLyricRegistered) {
                            SuperLyricHelper.registerPublisher()
                            superLyricRegistered = true
                        }
                        val registered = runCatching {
                            SuperLyricHelper.isPublisherRegistered()
                        }.getOrNull() ?: superLyricRegistered
                        Log.d(TAG_SUPER_LYRIC, "registerPublisher: registered=$registered")
                        result.success(registered)
                    }.onFailure { error ->
                        Log.w(TAG_SUPER_LYRIC, "registerPublisher failed: ${error.message}")
                        result.success(false)
                    }
                }
                "unregisterPublisher" -> {
                    runCatching {
                        if (superLyricRegistered) {
                            SuperLyricHelper.unregisterPublisher()
                            superLyricRegistered = false
                        }
                        result.success(null)
                    }.onFailure {
                        result.success(null)
                    }
                }
                "sendLyric" -> {
                    runCatching {
                        if (!superLyricRegistered) {
                            SuperLyricHelper.registerPublisher()
                            superLyricRegistered = true
                        }
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val album = call.argument<String>("album") ?: ""
                        val lyricText = call.argument<String>("lyricText") ?: ""
                        val lyricStartTime =
                            (call.argument<Number>("lyricStartTime"))?.toLong() ?: 0L
                        val lyricEndTime =
                            (call.argument<Number>("lyricEndTime"))?.toLong() ?: 0L
                        val secondaryText = call.argument<String>("secondaryText")
                        val translationText = call.argument<String>("translationText")
                        val words = call.argument<List<Map<String, Any>>>("words")

                        val lyricData = SuperLyricData()
                            .setTitle(title)
                            .setArtist(artist)
                            .setAlbum(album)

                        val lyricWords: Array<SuperLyricWord>? = words?.mapNotNull { w ->
                            val wordText = w["word"] as? String
                            val wordStart = (w["startTime"] as? Number)?.toLong()
                            val wordEnd = (w["endTime"] as? Number)?.toLong()
                            if (wordText != null && wordStart != null && wordEnd != null) {
                                SuperLyricWord(wordText, wordStart, wordEnd)
                            } else null
                        }?.takeIf { it.isNotEmpty() }?.toTypedArray()

                        val mainLyric = if (lyricWords != null) {
                            SuperLyricLine(lyricText, lyricWords, lyricStartTime, lyricEndTime)
                        } else {
                            SuperLyricLine(lyricText, lyricStartTime, lyricEndTime)
                        }
                        lyricData.setLyric(mainLyric)

                        if (!secondaryText.isNullOrBlank()) {
                            lyricData.setSecondary(
                                SuperLyricLine(secondaryText, lyricStartTime, lyricEndTime)
                            )
                        }
                        if (!translationText.isNullOrBlank()) {
                            lyricData.setTranslation(
                                SuperLyricLine(translationText, lyricStartTime, lyricEndTime)
                            )
                        }
                        SuperLyricHelper.sendLyric(lyricData)
                        Log.d(
                            TAG_SUPER_LYRIC,
                            "sendLyric ok: \"$lyricText\" ($lyricStartTime-$lyricEndTime ms), words=${lyricWords?.size ?: 0}"
                        )
                        result.success(true)
                    }.onFailure { error ->
                        Log.w(TAG_SUPER_LYRIC, "sendLyric failed: ${error.message}")
                        result.error("send_lyric_failed", error.message, null)
                    }
                }
                "sendStop" -> {
                    runCatching {
                        if (!superLyricRegistered) {
                            SuperLyricHelper.registerPublisher()
                            superLyricRegistered = true
                        }
                        SuperLyricHelper.sendStop(SuperLyricData())
                        Log.d(TAG_SUPER_LYRIC, "sendStop ok")
                        result.success(true)
                    }.onFailure { error ->
                        Log.w(TAG_SUPER_LYRIC, "sendStop failed: ${error.message}")
                        result.error("send_stop_failed", error.message, null)
                    }
                }
                "debugState" -> {
                    result.success(
                        mapOf(
                            "serviceAvailable" to
                                (runCatching { SuperLyricHelper.isAvailable() }.getOrNull() ?: false),
                            "localRegisteredFlag" to superLyricRegistered,
                            "publisherRegistered" to
                                (runCatching { SuperLyricHelper.isPublisherRegistered() }
                                    .getOrNull() ?: false),
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }

        // 车载蓝牙歌词广播（标准 + 厂商兼容）
        val btLyricChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "shiyin_music/bluetooth_lyrics"
        )
        btLyricChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "broadcastMetaChanged" -> {
                    runCatching {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val album = call.argument<String>("album") ?: ""
                        val lyric = call.argument<String>("lyric") ?: ""
                        val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                        val durationMs = (call.argument<Number>("durationMs") ?: 0).toLong()
                        val playing = call.argument<Boolean>("playing") ?: false
                        val track = (call.argument<Number>("track") ?: 0).toInt()
                        val listSize = (call.argument<Number>("listSize") ?: 0).toInt()

                        val extras = Bundle().apply {
                            putString("track", title)
                            putString("artist", artist)
                            putString("album", album)
                            putString("id", "")
                            putLong("position", positionMs)
                            putLong("duration", durationMs)
                            putBoolean("playing", playing)
                            putInt("ListSize", listSize)
                            putInt("trackPos", track)
                            putString("lyric", lyric)
                            putString("currentLyric", lyric)
                            putString("DISPLAY_NAME", title)
                        }

                        sendOrderedBroadcast(Intent("com.android.music.metachanged").apply {
                            putExtras(extras)
                            setPackage(null)
                        }, null)
                        sendBroadcast(Intent("com.netease.cloudmusic.metachanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })
                        sendBroadcast(Intent("com.tencent.qqmusic.metachanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })
                        sendBroadcast(Intent("com.kugou.android.metachanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })
                        sendBroadcast(Intent("cn.kuwo.player.metachanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })

                        Log.d(
                            TAG_BLUETOOTH_LYRICS,
                            "metaChanged ok: \"$title\"/\"$artist\", lyric=\"${lyric.take(24)}\", pos=${positionMs}ms"
                        )
                        result.success(true)
                    }.onFailure { error ->
                        Log.w(TAG_BLUETOOTH_LYRICS, "broadcastMetaChanged failed: ${error.message}")
                        result.success(false)
                    }
                }
                "broadcastPlayStateChanged" -> {
                    runCatching {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val album = call.argument<String>("album") ?: ""
                        val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                        val durationMs = (call.argument<Number>("durationMs") ?: 0).toLong()
                        val playing = call.argument<Boolean>("playing") ?: false

                        val extras = Bundle().apply {
                            putString("track", title)
                            putString("artist", artist)
                            putString("album", album)
                            putLong("position", positionMs)
                            putLong("duration", durationMs)
                            putBoolean("playing", playing)
                        }
                        sendBroadcast(Intent("com.android.music.playstatechanged").apply {
                            putExtras(extras)
                            setPackage(null)
                        })
                        sendBroadcast(Intent("com.netease.cloudmusic.playstatechanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })
                        sendBroadcast(Intent("com.tencent.qqmusic.playstatechanged").apply {
                            putExtras(Bundle(extras))
                            setPackage(null)
                        })
                        Log.d(
                            TAG_BLUETOOTH_LYRICS,
                            "playStateChanged ok: \"$title\", playing=$playing, pos=${positionMs}ms"
                        )
                        result.success(true)
                    }.onFailure { error ->
                        Log.w(TAG_BLUETOOTH_LYRICS, "broadcastPlayStateChanged failed: ${error.message}")
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 听歌识曲麦克风采集(PCM 8000Hz/16bit/单声道,见 AudioCaptureHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/audio_capture")
            .setMethodCallHandler { call, result ->
                AudioCaptureHandler.handle(call, result, this)
            }

        // 语音点歌（系统助手/车机语音）：Dart 侧初始化完成后调 ready，
        // 原生把冷启动期间暂存的 query 冲刷过去。
        voiceSearchChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "shiyin_music/voice_search"
        )
        voiceSearchChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    voiceSearchDartReady = true
                    pendingVoiceSearchQuery?.let { query ->
                        voiceSearchChannel?.invokeMethod(
                            "onVoiceSearch",
                            mapOf("query" to query)
                        )
                    }
                    pendingVoiceSearchQuery = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 冷启动兜底：Activity 被助手语音直接拉起时，intent 在引擎配置
        // 阶段就已带 query（此时 Dart 必然未 ready，会走暂存）。
        handleVoiceSearchIntent(intent)
    }

    private fun readAudioPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun hasReadAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, readAudioPermission()) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestAudioPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(readAudioPermission()),
            REQUEST_READ_AUDIO
        )
    }

    /// 自定义下载路径的公共目录写权限是否已具备：
    /// API30+ = 「所有文件访问」已授予；API≤29 = WRITE_EXTERNAL_STORAGE
    /// 已授予（Android 10 需配 manifest 的 requestLegacyExternalStorage）。
    private fun hasWriteStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_READ_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
        if (requestCode == REQUEST_WRITE_STORAGE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingWritePermissionResult?.success(granted)
            pendingWritePermissionResult = null
        }
        AudioCaptureHandler.onRequestPermissionsResult(requestCode, grantResults)
    }

    private fun queryLocalSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.IS_MUSIC,
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(
                collection,
                projection,
                selection,
                null,
                sortOrder
            )

            cursor?.let {
                val idColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val dataColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                val albumIdColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)

                while (it.moveToNext()) {
                    val id = it.getLong(idColumn)
                    val title = it.getString(titleColumn) ?: "未知歌曲"
                    val artist = it.getString(artistColumn) ?: "未知艺人"
                    val album = it.getString(albumColumn) ?: ""
                    val duration = it.getLong(durationColumn)
                    val filePath = it.getString(dataColumn) ?: ""
                    val albumId = it.getLong(albumIdColumn)

                    // 构建专辑封面 URI
                    val albumArtUri = ContentUris.withAppendedId(
                        Uri.parse("content://media/external/audio/albumart"),
                        albumId
                    )

                    if (filePath.isNotEmpty()) {
                        songs.add(
                            mapOf(
                                "id" to filePath,
                                "title" to title,
                                "artist" to artist,
                                "album" to album,
                                "duration" to duration,
                                "filePath" to filePath,
                                "albumArtUri" to albumArtUri.toString(),
                            )
                        )
                    }
                }
            }
        } finally {
            cursor?.close()
        }

        return songs
    }

    /** 解析 Flutter 侧整首歌词 JSON：[{timeMs, text, translation}]。 */
    private fun parseLyricLines(json: String): List<LyricsOverlayService.LyricLineData> {
        val lines = mutableListOf<LyricsOverlayService.LyricLineData>()
        runCatching {
            val array = org.json.JSONArray(json)
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val timeMs = obj.optLong("timeMs", 0L)
                val text = obj.optString("text", "")
                val translation = obj.optString("translation", "")
                if (text.isNotEmpty()) {
                    lines.add(LyricsOverlayService.LyricLineData(timeMs, text, translation))
                }
            }
        }.onFailure {
            Log.w(TAG_LYRICS_OVERLAY, "歌词 JSON 解析失败: ${it.message}")
        }
        return lines
    }

    /**
     * 数据类调用（loadLyrics/setPlaybackState/seekTo/calibratePosition/
     * updateSettings）统一入口：服务实例未就绪时（show 的 startForegroundService
     * 到 onCreate 之间约有数百毫秒窗口）延迟重试一次，避免开启瞬间的
     * 首批歌词/设置推送被静默丢弃。
     */
    private fun withLyricService(block: (LyricsOverlayService) -> Unit) {
        val service = LyricsOverlayService.instance
        if (service != null) {
            block(service)
            return
        }
        mainHandler.postDelayed({
            LyricsOverlayService.instance?.let(block)
        }, 350)
    }

    // ── 语音点歌（系统助手/车机语音）──

    /**
     * 冷启动兜底：configureFlutterEngine 时 intent 可能已带着语音搜索
     * query（Activity 由助手语音唤起）。此时 Flutter 尚未 ready，query 会
     * 走 executeVoiceSearch 的暂存路径，Dart 侧 ready 后冲刷。
     */
    private fun handleVoiceSearchIntent(intent: Intent?) {
        if (intent?.action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return
        // query 优先级：SearchManager.QUERY → 自定义 "query" extra →
        // artist + title 组合（易格同构）。
        var query = intent.getStringExtra(SearchManager.QUERY)
        if (query.isNullOrBlank()) {
            query = intent.getStringExtra("query")
        }
        if (query.isNullOrBlank()) {
            val artist = intent.getStringExtra(MediaStore.EXTRA_MEDIA_ARTIST)
            val title = intent.getStringExtra(MediaStore.EXTRA_MEDIA_TITLE)
            val combined = listOfNotNull(artist, title)
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .trim()
            if (combined.isNotEmpty()) query = combined
        }
        if (query.isNullOrBlank()) return
        executeVoiceSearch(query.trim())
        Log.i(TAG_VOICE_SEARCH, "语音点歌 query=\"$query\"")
    }

    /** Dart 就绪则直接回推，否则暂存待 ready 冲刷。 */
    private fun executeVoiceSearch(query: String) {
        if (voiceSearchDartReady) {
            voiceSearchChannel?.invokeMethod("onVoiceSearch", mapOf("query" to query))
        } else {
            pendingVoiceSearchQuery = query
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // singleTop 热启动：助手语音在应用已运行时经 onNewIntent 送达。
        handleVoiceSearchIntent(intent)
    }

    private fun equalizerConfig(audioSessionId: Int?): Map<String, Any>? {
        if (audioSessionId == null || audioSessionId <= 0) {
            return null
        }
        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bands = (0 until effect.numberOfBands).map { index ->
            val band = index.toShort()
            mapOf(
                "centerHz" to effect.getCenterFreq(band) / 1000,
                "level" to effect.getBandLevel(band).toInt()
            )
        }
        return mapOf(
            "range" to listOf(range[0].toInt(), range[1].toInt()),
            "bands" to bands
        )
    }

    private fun configureEqualizer(
        audioSessionId: Int?,
        enabled: Boolean,
        levels: List<Int>
    ): Boolean {
        if (!enabled) {
            releaseEqualizer()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bandCount = minOf(effect.numberOfBands.toInt(), levels.size)
        for (index in 0 until bandCount) {
            val level = levels[index].coerceIn(range[0].toInt(), range[1].toInt())
            effect.setBandLevel(index.toShort(), level.toShort())
        }
        effect.enabled = true
        return true
    }

    private fun ensureEqualizer(audioSessionId: Int): Equalizer {
        if (equalizerSessionId == audioSessionId && equalizer != null) {
            return equalizer!!
        }
        releaseEqualizer()
        return Equalizer(0, audioSessionId).also {
            equalizer = it
            equalizerSessionId = audioSessionId
        }
    }

    private fun releaseEqualizer() {
        equalizer?.runCatching {
            enabled = false
            release()
        }
        equalizer = null
        equalizerSessionId = null
    }

    private fun configureBassBoost(
        audioSessionId: Int?,
        enabled: Boolean,
        strength: Int
    ): Boolean {
        if (!enabled) {
            releaseBassBoost()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (bassBoostSessionId == audioSessionId && bassBoost != null) {
            bassBoost!!
        } else {
            releaseBassBoost()
            BassBoost(0, audioSessionId).also {
                bassBoost = it
                bassBoostSessionId = audioSessionId
            }
        }

        val clampedStrength = strength.coerceIn(0, 1000).toShort()
        if (effect.strengthSupported) {
            effect.setStrength(clampedStrength)
        } else {
            effect.setStrength(if (clampedStrength > 0) 1000 else 0)
        }
        effect.enabled = true
        return true
    }

    private fun releaseBassBoost() {
        bassBoost?.runCatching {
            enabled = false
            release()
        }
        bassBoost = null
        bassBoostSessionId = null
    }

    /**
     * 配置环绕（Virtualizer）。API 31 起官方标记 deprecated 且推荐 Spatializer，
     * 但 Spatializer 是系统级查询/控制接口、不能按音频会话插入效果，对本应用
     * 场景不可用；Virtualizer 在 minSdk 26 全范围仍可工作。部分设备实现为空
     * 操作，由 strengthSupported 表达，效果差异属设备行为。
     */
    @Suppress("DEPRECATION")
    private fun configureVirtualizer(
        audioSessionId: Int?,
        enabled: Boolean,
        strength: Int
    ): Boolean {
        if (!enabled) {
            releaseVirtualizer()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (virtualizerSessionId == audioSessionId && virtualizer != null) {
            virtualizer!!
        } else {
            releaseVirtualizer()
            Virtualizer(0, audioSessionId).also {
                virtualizer = it
                virtualizerSessionId = audioSessionId
            }
        }

        val clampedStrength = strength.coerceIn(0, 1000).toShort()
        if (effect.strengthSupported) {
            effect.setStrength(clampedStrength)
        } else {
            effect.setStrength(if (clampedStrength > 0) 1000 else 0)
        }
        effect.enabled = true
        return true
    }

    @Suppress("DEPRECATION")
    private fun releaseVirtualizer() {
        virtualizer?.runCatching {
            enabled = false
            release()
        }
        virtualizer = null
        virtualizerSessionId = null
    }

    /**
     * 配置响度增益(基于已分析的 LUFS 差值)。
     * 使用 Android [LoudnessEnhancer] 仅放大轻歌(增益范围 0~1500 mB);
     * 响歌衰减由 Dart 侧 [AudioPlayer.setVolume] 完成,LoudnessEnhancer 不支持负增益。
     * 仿照 [configureBassBoost] 范式:sessionId 不变则复用,否则释放重建。
     */
    private fun configureLoudnessGain(
        audioSessionId: Int?,
        enabled: Boolean,
        gainMb: Int
    ): Boolean {
        if (!enabled) {
            releaseLoudnessGain()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (loudnessEnhancerSessionId == audioSessionId &&
            loudnessEnhancer != null
        ) {
            loudnessEnhancer!!
        } else {
            releaseLoudnessGain()
            LoudnessEnhancer(audioSessionId).also {
                loudnessEnhancer = it
                loudnessEnhancerSessionId = audioSessionId
            }
        }

        // LoudnessEnhancer 仅支持正向放大(setTargetGain 文档限定 "amplified"),
        // 负值衰减属未定义行为,故下限为 0;响歌衰减由 Dart 侧 setVolume 完成。
        val clampedGain = gainMb.coerceIn(0, 1500)
        effect.setTargetGain(clampedGain)
        effect.enabled = true
        return true
    }

    private fun releaseLoudnessGain() {
        loudnessEnhancer?.runCatching {
            enabled = false
            release()
        }
        loudnessEnhancer = null
        loudnessEnhancerSessionId = null
    }

    private fun enqueueApkDownload(url: String, fileName: String) {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle("易格音乐 更新包")
            .setDescription("正在下载新版本")
            .setMimeType("application/vnd.android.package-archive")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)

        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = downloadManager.enqueue(request)
        updateDownloads[downloadId] = fileName
        registerDownloadReceiver()
    }

    private fun registerDownloadReceiver() {
        if (downloadReceiverRegistered) {
            return
        }
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(downloadReceiver, filter)
        }
        downloadReceiverRegistered = true
    }

    private fun isDownloadSuccessful(downloadId: Long): Boolean {
        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val query = DownloadManager.Query().setFilterById(downloadId)
        var cursor: Cursor? = null
        return try {
            cursor = downloadManager.query(query)
            cursor != null &&
                cursor.moveToFirst() &&
                cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) ==
                DownloadManager.STATUS_SUCCESSFUL
        } finally {
            cursor?.close()
        }
    }

    private fun installDownloadedApk(fileName: String) {
        val apkFile = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
        if (!apkFile.exists()) {
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(installIntent)
    }

    /// 是否为 Android Automotive 车机设备。
    /// 仅依赖官方 FEATURE_AUTOMOTIVE 标记：国产定制 AOSP 车机通常未声明，
    /// 会判为 false，需用户在设置→个性化手动开启车机模式。
    private fun isAutomotiveDevice(): Boolean {
        return packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)
    }

    private fun getAlbumArtBytes(albumId: Long): ByteArray? {
        val uri = ContentUris.withAppendedId(
            Uri.parse("content://media/external/audio/albumart"),
            albumId
        )
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        }
    }

    private fun getEmbeddedLyrics(filePath: String): String? {
        return try {
            val retriever = android.media.MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            // METADATA_KEY_LYRICS = 26，API 29+ 才有常量名，直接用数字 key 兼容旧版本
            val lyrics = retriever.extractMetadata(26)
            retriever.release()
            lyrics
        } catch (e: Exception) {
            null
        }
    }

    override fun onDestroy() {
        releaseEqualizer()
        releaseBassBoost()
        releaseVirtualizer()
        releaseLoudnessGain()
        if (superLyricRegistered) {
            runCatching { SuperLyricHelper.unregisterPublisher() }
            superLyricRegistered = false
        }
        if (downloadReceiverRegistered) {
            unregisterReceiver(downloadReceiver)
            downloadReceiverRegistered = false
        }
        super.onDestroy()
    }
}
