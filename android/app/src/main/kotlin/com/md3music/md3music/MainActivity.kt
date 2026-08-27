package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.annotation.TargetApi
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.support.v4.media.session.MediaSessionCompat
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.md3music.md3music.AudioPlaybackService
import com.md3music.md3music.FloatingLyricService
import java.io.File

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.md3music.md3music/floating_lyric"
    private val FOLDER_PICKER_CHANNEL = "com.md3music.md3music/folder_picker"
    private val FONT_PICKER_CHANNEL = "com.md3music.md3music/font_picker"
    private val BACKGROUND_PICKER_CHANNEL = "com.md3music.md3music/background_picker"
    private val MEDIA_STORE_CHANNEL = "com.md3music.md3music/media_store"
    private val HOME_WIDGET_CHANNEL = "com.md3music.md3music/home_widget"
    private val RECOGNITION_CHANNEL = "com.md3music.md3music/floating_recognition"
    private val PIP_CHANNEL = "com.md3music.md3music/pip"
    private val MIUIX_DISCOVER_CHANNEL = "com.md3music.md3music/miuix_discover"
    private val TASK_CHANNEL = "com.md3music.md3music/task"
    private var pendingDesktopLyricAction: String? = null
    private var folderPickerResult: MethodChannel.Result? = null
    private var fontPickerResult: MethodChannel.Result? = null
    private var backgroundPickerResult: MethodChannel.Result? = null
    // 悬浮窗识曲 channel：MediaProjection 授权结果等原生→Dart 回调
    private var recognitionChannel: MethodChannel? = null
    // MV 画中画 channel：原生→Dart 回调 onPipModeChanged
    private var pipChannel: MethodChannel? = null

    companion object {
        private const val FOLDER_PICKER_REQUEST_CODE = 9999
        private const val FONT_PICKER_REQUEST_CODE = 10000
        private const val RECOGNITION_PROJECTION_REQUEST = 10001
        private const val BACKGROUND_PICKER_REQUEST_CODE = 10002

        // 静态引用：让 Service 也能调用 MethodChannel（无 FlutterEngine 缓存时走这里）
        private var cachedEngine: FlutterEngine? = null
        private var cachedChannel: MethodChannel? = null
        // KugouApiService 单例引用，便于 Activity onDestroy / onTrimMemory 时确定性关停
        @Volatile private var kugouApiService: KugouApiService? = null
        // 频谱插件引用，Activity 销毁时释放 Visualizer
        @Volatile private var spectrumPlugin: SpectrumPlugin? = null

        // MV 画中画：Dart 端标记视频是否播放中（按 Home 自动进入画中画用）
        @Volatile private var pipVideoActive = false
        // MV 视频宽高比（宽/高），用于画中画窗口比例
        @Volatile private var pipAspectRatio: Rational = Rational(16, 9)

        // 记录自定义插件已注册到的引擎：provideFlutterEngine 复用后台（headless）
        // 引擎时 configureFlutterEngine 会再次执行，若对同一引擎重复注册
        // UsbAudioPlugin 会注册两个拔插广播接收器（无法 unregister），导致 USB
        // 事件被处理两次；而新引擎（进程被杀后重建）仍需注册，故按引擎身份判断。
        private var customPluginsEngine: FlutterEngine? = null

        fun setKugouApiService(service: KugouApiService?) {
            kugouApiService = service
        }

        /** Activity 销毁或被系统回收时调用，尽力通知本地 API 服务器停止监听 */
        fun shutdownNodeJs() {
            try {
                kugouApiService?.stopServer()
            } catch (_: Exception) {
                // 进程即将销毁，吞掉异常
            }
        }

        fun sendDesktopLyricAction(action: String) {
            cachedChannel?.invokeMethod("desktopLyricAction", action)
        }

        fun sendDesktopLyricConfigChanged(config: Map<String, Any?>) {
            cachedChannel?.invokeMethod("desktopLyricConfigChanged", config)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 高刷新率适配：主动向系统声明最高刷新率偏好，避免被 ROM 的高刷新率管理
        // 归为「跟随应用内设置」而锁在 60Hz。Flutter 引擎从不调用
        // Surface.setFrameRate()，系统无法得知 App 需要高刷，须在此显式声明。
        applyOptimalRefreshRate()
        // 退出缩小动画时露出系统桌面：FlutterView 背景透明，
        // 配合 NormalTheme 的透明 windowBackground，页面缩小后透出桌面（微信同款）。
        try {
            findViewById<io.flutter.embedding.android.FlutterView>(FLUTTER_VIEW_ID)
                ?.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        } catch (_: Exception) {
            // 个别 ROM 可能不支持，忽略即可
        }
    }

    override fun onResume() {
        super.onResume()
        // 回到前台（如从画中画/锁屏/切后台返回）时重新应用，
        // 防止被系统降频后未恢复（偶现锁 60Hz 的场景之一）。
        applyOptimalRefreshRate()
    }

    /// 向系统请求当前分辨率下可用的最高刷新率。
    ///
    /// - API 30+：设置 `preferredRefreshRate`（只改刷新率、不改分辨率，
    ///   LTPO 屏仍可动态降频省电），为 refresh_rate 插件推荐做法。
    /// - API 23~29：设置 `preferredDisplayModeId`（无 preferredRefreshRate 时
    ///   只能指定完整显示模式，故保持当前分辨率匹配，避免分辨率被切换）。
    /// - API 34+：开启触摸提频（触摸/滚动时升到高刷，更跟手）。
    private fun applyOptimalRefreshRate() {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            val display = windowManager.defaultDisplay
            val currentMode = display.mode
            // 与当前分辨率一致、刷新率最高的显示模式
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == currentMode.physicalWidth &&
                        it.physicalHeight == currentMode.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: return
            val lp = window.attributes
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                lp.preferredRefreshRate = best.refreshRate
            } else {
                lp.preferredDisplayModeId = best.modeId
            }
            window.attributes = lp // 重新 setAttributes 使偏好生效
            // frameRateBoostOnTouchEnabled 为 API 34（Android 14）引入，低于此版本
            // 调用会抛 NoSuchMethodError（Error 而非 Exception），曾致低版本设备启动崩溃。
            // 门槛必须用 VANILLA_ICE_CREAM(34)，不能用 UPSIDE_DOWN_CAKE(33)。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                try {
                    window.frameRateBoostOnTouchEnabled = true
                } catch (_: Throwable) {
                    // 个别 ROM 即便到达 API 34 仍可能不支持，单独吞掉（高刷非致命）
                }
            }
        } catch (_: Throwable) {
            // 个别 ROM 可能不支持，忽略即可（高刷非致命）
            // 用 Throwable 而非 Exception：NoSuchMethodError/LinkageError 是 Error，
            // 低版本设备调用高版本方法抛出的崩溃必须被吞掉而非上抛。
        }
    }

    /// 复用后台（headless）FlutterEngine：线控耳机「唤醒播放」被拉起时，
    /// AudioPlaybackService 已创建并运行完整 App（main() 已执行、PlayerProvider
    /// 正在恢复播放状态）。此处返回缓存引擎，避免创建第二个 FlutterEngine 导致
    /// 双 Dart 隔离区 / 双音频会话冲突。引擎不可用时走默认逻辑新建。
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        val cached = FlutterEngineCache.getInstance().get("md3music_engine")
        if (cached != null && cached.dartExecutor.isExecutingDart()) {
            return cached
        }
        return super.provideFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 缓存引擎：Service 端没有 FlutterEngine 时（app 进程被回收场景），能复用
        FlutterEngineCache.getInstance().put("md3music_engine", flutterEngine)
        cachedEngine = flutterEngine
        cachedChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)

        // 将 FlutterEngine 传递给 AudioPlaybackService
        AudioPlaybackService.setFlutterEngine(flutterEngine)

        // 自定义插件仅对同一引擎注册一次：引擎被复用（provideFlutterEngine 返回
        // 缓存引擎）时 configureFlutterEngine 会再次执行，重复注册会注册两个
        // USB 拔插广播接收器
        if (customPluginsEngine !== flutterEngine) {
            customPluginsEngine = flutterEngine

            // 注册均衡器插件：Android 原生 Equalizer，绑定 just_audio 的 audio session ID
            EqualizerPlugin().register(flutterEngine)

            // 注册频谱可视化插件：Android 原生 Visualizer，回传 FFT 数据给 Dart 端绘制环形频谱
            spectrumPlugin = SpectrumPlugin().also { it.register(flutterEngine) }

            // 注册 USB 独占输出插件：MethodChannel + 动态拔插广播 + AudioSink 拦截桥接
            UsbAudioPlugin(this).register(flutterEngine)

            // 注册 MetadataWriterPlugin：处理下载完成后嵌入元数据（标题/艺术家/专辑/封面/歌词）
            MetadataWriterPlugin().register(flutterEngine)

            // 注册 Miuix 发现页测试通道：Dart 设置页点击后打开原生 Compose + miuix 页面，
            // 并携带本地 Rust API 服务器当前端口（原生页据此直连取数）。
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                MIUIX_DISCOVER_CHANNEL,
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val port = call.argument<Number>("port")?.toInt() ?: 0
                        try {
                            startActivity(
                                Intent(this, MiuixDiscoverActivity::class.java)
                                    .putExtra(MiuixDiscoverActivity.EXTRA_PORT, port),
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // 初始化本地 API 服务器（KugouApiService 含 JNI external 方法，
        // 如果 .so 的 JNI 符号名与当前包名不匹配，实例化可能触发类验证错误，
        // 这里包一层 try-catch，失败时 Dart 端会走 dart:ffi 兜底）。
        android.util.Log.d("MainActivity", "Initializing KugouApiService...")
        try {
            val apiSvc = KugouApiService(this, flutterEngine)
            setKugouApiService(apiSvc)
            android.util.Log.d("MainActivity", "KugouApiService initialized")
        } catch (e: Throwable) {
            android.util.Log.e("MainActivity", "KugouApiService init failed: ${e.message}")
            setKugouApiService(null)
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startFloatingLyric" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                        startActivity(intent)
                        result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                    } else {
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_UPDATE_LYRIC
                            putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                            putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                }
                "updateLyric" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_LYRIC
                        putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_NEXT_LYRIC, call.argument<String>("nextLyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_SUNG_CHAR_COUNT, call.argument<Int>("sungCharCount") ?: -1)
                    }
                    startService(intent)
                    result.success(true)
                }
                "updateTitle" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_TITLE
                        putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    }
                    startService(intent)
                    result.success(true)
                }
                "updateProgress" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_PROGRESS
                        putExtra(FloatingLyricService.EXTRA_POSITION, (call.argument<Number>("position")?.toLong() ?: 0L))
                        putExtra(FloatingLyricService.EXTRA_DURATION, (call.argument<Number>("duration")?.toLong() ?: 0L))
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopFloatingLyric" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply { action = FloatingLyricService.ACTION_STOP }
                    startService(intent)
                    result.success(true)
                }
                "hasOverlayPermission" -> {
                    result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Settings.canDrawOverlays(this) else true)
                }
                "setDesktopLyricConfig" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_SET_CONFIG
                        call.argument<Double>(FloatingLyricService.EXTRA_FONT_SIZE)?.let {
                            putExtra(FloatingLyricService.EXTRA_FONT_SIZE, it.toFloat())
                        }
                        call.argument<Double>(FloatingLyricService.EXTRA_DISPLAY_SCALE)?.let {
                            putExtra(FloatingLyricService.EXTRA_DISPLAY_SCALE, it.toFloat())
                        }
                        call.argument<Boolean>(FloatingLyricService.EXTRA_DOUBLE_LINE)?.let {
                            putExtra(FloatingLyricService.EXTRA_DOUBLE_LINE, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_OPACITY)?.let {
                            putExtra(FloatingLyricService.EXTRA_OPACITY, it)
                        }
                        call.argument<Boolean>(FloatingLyricService.EXTRA_LOCKED)?.let {
                            putExtra(FloatingLyricService.EXTRA_LOCKED, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_GRADIENT_START)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_START, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_GRADIENT_END)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_END, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_UNPLAYED_COLOR)?.let {
                            putExtra(FloatingLyricService.EXTRA_UNPLAYED_COLOR, it)
                        }
                    }
                    startService(intent)
                    result.success(true)
                }
                "setPlaying" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_SET_PLAYING
                        putExtra(
                            FloatingLyricService.EXTRA_IS_PLAYING,
                            call.argument<Boolean>(FloatingLyricService.EXTRA_IS_PLAYING) ?: false
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                "seekTo" -> {
                    // seekTo 由 MediaSession 直接调用，无需额外处理
                    result.success(true)
                }
                "showNotification", "updateNotification" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        putExtra(AudioPlaybackService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        putExtra(AudioPlaybackService.EXTRA_ARTIST, call.argument<String>("artist") ?: "")
                        putExtra(AudioPlaybackService.EXTRA_ART_URL, call.argument<String>("artUrl"))
                        putExtra(AudioPlaybackService.EXTRA_FALLBACK_FILE_PATH, call.argument<String>("fallbackFilePath"))
                        putExtra(AudioPlaybackService.EXTRA_IS_PLAYING, call.argument<Boolean>("isPlaying") ?: false)
                        putExtra(AudioPlaybackService.EXTRA_POSITION, call.argument<Number>("position")?.toLong() ?: 0L)
                        putExtra(AudioPlaybackService.EXTRA_DURATION, call.argument<Number>("duration")?.toLong() ?: 0L)
                        putExtra(
                            AudioPlaybackService.EXTRA_DESKTOP_LYRIC_ENABLED,
                            call.argument<Boolean>(AudioPlaybackService.EXTRA_DESKTOP_LYRIC_ENABLED) ?: false
                        )
                        putExtra(
                            AudioPlaybackService.EXTRA_IS_FAVORITED,
                            call.argument<Boolean>(AudioPlaybackService.EXTRA_IS_FAVORITED) ?: false
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "hideNotification" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                // 蓝牙歌词：更新当前歌词文本（title→歌词，artist→「作者 - 标题」由原生端处理）
                "updateBluetoothLyric" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_UPDATE_BT_LYRIC
                        putExtra(
                            AudioPlaybackService.EXTRA_BT_LYRIC_TEXT,
                            call.argument<String>("lyric") ?: ""
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                // 蓝牙歌词：开关切换
                "setBluetoothLyricEnabled" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_SET_BT_LYRIC_ENABLED
                        putExtra(
                            AudioPlaybackService.EXTRA_BT_LYRIC_ENABLED,
                            call.argument<Boolean>("enabled") ?: false
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                // LyricInfo 歌词转发：写入 MediaSession 元数据 extras.lyricInfo
                // （空字符串表示移除，切歌/功能关闭时使用）
                "updateLyricInfo" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_UPDATE_LYRIC_INFO
                        putExtra(
                            AudioPlaybackService.EXTRA_LYRIC_INFO,
                            call.argument<String>("lyricInfo") ?: ""
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                // 锁屏歌词：开关 / 数据推送（headless 唤醒场景由 AudioPlaybackService 兜底）
                "showLockScreenLyric" -> {
                    result.success(true)
                }
                "hideLockScreenLyric" -> {
                    LockScreenLyricActivity.dismiss()
                    result.success(true)
                }
                "updateLockScreenLyric" -> {
                    LockScreenLyricActivity.applyCall(call)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册悬浮窗识曲 MethodChannel：Dart 控制悬浮窗服务 + MediaProjection 授权
        // （原生→Dart 回调 onProjectionResult/onSegmentCaptured/onFloatingAction
        //  由 Service 经 FlutterEngineCache 直接 invokeMethod，见 FloatingRecognitionService）
        val recognitionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RECOGNITION_CHANNEL
        )
        this.recognitionChannel = recognitionChannel
        recognitionChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT < 29) {
                        result.error("UNSUPPORTED", "仅支持 Android 10 及以上", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                    } else {
                        val intent = Intent(this, FloatingRecognitionService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                }
                "stop" -> {
                    // 服务未运行时直接返回，避免 startService 复活已停止的悬浮窗
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_STOP
                            }
                        )
                    }
                    result.success(true)
                }
                "requestProjection" -> {
                    val pm = getSystemService(android.media.projection.MediaProjectionManager::class.java)
                    startActivityForResult(pm.createScreenCaptureIntent(), RECOGNITION_PROJECTION_REQUEST)
                    result.success(true)
                }
                "continueCapture" -> {
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_CONTINUE
                            }
                        )
                    }
                    result.success(true)
                }
                "stopCapture" -> {
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_STOP_CAPTURE
                            }
                        )
                    }
                    result.success(true)
                }
                "setResult" -> {
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_SET_RESULT
                                putExtra(
                                    FloatingRecognitionService.EXTRA_RESULT,
                                    call.argument<String>("result") ?: ""
                                )
                            }
                        )
                    }
                    result.success(true)
                }
                "setStatus" -> {
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_SET_STATUS
                                putExtra(
                                    FloatingRecognitionService.EXTRA_STATUS,
                                    call.argument<String>("status") ?: ""
                                )
                            }
                        )
                    }
                    result.success(true)
                }
                "setThemeColors" -> {
                    if (FloatingRecognitionService.isRunning()) {
                        startService(
                            Intent(this, FloatingRecognitionService::class.java).apply {
                                action = FloatingRecognitionService.ACTION_SET_THEME
                                // Dart int（64 位）解码为 Long，用 Number 接收
                                val colors = call.argument<HashMap<String, Number>>("colors")
                                if (colors != null) {
                                    putExtra(FloatingRecognitionService.EXTRA_THEME_COLORS, colors)
                                }
                            }
                        )
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册 Lyricon Provider MethodChannel，让 Dart 端能控制 Lyricon 播放器
        // （逻辑与 AudioPlaybackService.setupHeadlessChannels 共用，见该函数）
        AudioPlaybackService.registerLyriconChannel(flutterEngine)
        // 注册 SuperLyric MethodChannel，让 Dart 端能推送当前歌词行到 SuperLyric
        AudioPlaybackService.registerSuperLyricChannel(flutterEngine)

        // 注册文件夹选择器 MethodChannel
        val folderPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOLDER_PICKER_CHANNEL
        )
        folderPickerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> {
                    folderPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    startActivityForResult(intent, FOLDER_PICKER_REQUEST_CODE)
                }
                "getPersistedUriPermission" -> {
                    val treeUri = call.argument<String>("uri")
                    if (treeUri != null) {
                        try {
                            val uri = Uri.parse(treeUri)
                            contentResolver.takePersistableUriPermission(
                                uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PERMISSION_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_URI", "URI is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 注册字体文件选择器 MethodChannel
        // 用 ACTION_OPEN_DOCUMENT 打开系统文件选择器，过滤 TTF/OTF 文件
        // 选中后原生端把 content URI 流拷贝到 filesDir/fonts/user_custom.ttf
        // 返回真实路径给 Dart 端用 FontLoader 加载
        val fontPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FONT_PICKER_CHANNEL
        )
        fontPickerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFontFile" -> {
                    fontPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        // 主 MIME：font/ttf；EXTRA_MIME_TYPES 兼容 OTF 与未注册 MIME
                        type = "font/ttf"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "font/ttf",
                                "font/otf",
                                "font/sfnt",
                                "application/x-font-ttf",
                                "application/x-font-otf",
                                "application/x-font-truetype",
                                "application/octet-stream"
                            )
                        )
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, FONT_PICKER_REQUEST_CODE)
                }
                else -> result.notImplemented()
            }
        }

        // 注册背景图片选择器 MethodChannel
        // 用 ACTION_OPEN_DOCUMENT 打开系统图片选择器，过滤常见图片 MIME
        // 选中后原生端把 content URI 流拷贝到 filesDir/background/bg.<ext>
        // 返回真实路径给 Dart 端用 Image.file 渲染 + PaletteGenerator 莫奈取色
        val backgroundPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_PICKER_CHANNEL
        )
        backgroundPickerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickBackgroundImage" -> {
                    backgroundPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, BACKGROUND_PICKER_REQUEST_CODE)
                }
                else -> result.notImplemented()
            }
        }

        // 注册 MediaStore 扫描器 MethodChannel
        // Android 11+ 沙箱模式下，通过 MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        // 可以读取系统已索引的所有音频（含网易云/QQ 音乐/酷狗等通过 MediaStore 公开的部分）。
        val mediaStoreChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_STORE_CHANNEL
        )
        mediaStoreChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkVersion" -> {
                    result.success(Build.VERSION.SDK_INT)
                }
                "queryAudioFiles" -> {
                    try {
                        // MediaStore 查询是同步阻塞的，在子线程执行避免 ANR
                        Thread {
                            try {
                                val files = MediaStoreScanner.queryAudioFiles(this)
                                runOnUiThread { result.success(files) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("QUERY_ERROR", e.message, null)
                                }
                            }
                        }.start()
                    } catch (e: Exception) {
                        result.error("QUERY_ERROR", e.message, null)
                    }
                }
                "resolveLocalPath" -> {
                    // 把 content:// URI 解析为真实文件路径（just_audio 可播放）
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("INVALID_URI", "uri is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val path = MediaStoreScanner.resolveLocalPath(this, uriStr)
                            runOnUiThread { result.success(path) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("RESOLVE_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // 注册桌面小组件 MethodChannel：Flutter 侧推送播放状态到 AppWidget
        val homeWidgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOME_WIDGET_CHANNEL
        )
        homeWidgetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val position = call.argument<Number>("position")?.toLong() ?: 0L
                    val duration = call.argument<Number>("duration")?.toLong() ?: 0L
                    MusicWidgetProvider.updateAllWidgets(
                        this, title, artist, isPlaying, position, duration
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册屏幕常亮 MethodChannel：Dart 端 WakelockService 调用，开关 FLAG_KEEP_SCREEN_ON
        val wakelockChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.md3music.md3music/wakelock"
        )
        wakelockChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册任务控制 MethodChannel：Dart 双击返回 → 回到桌面挂后台
        // 用 moveTaskToBack(等同按 Home)，不销毁 Activity、不杀进程，
        // 播放器与本地 Rust 服务器都保持运行，重新打开瞬时恢复。
        val taskChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TASK_CHANNEL
        )
        taskChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "moveToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册 MV 画中画 MethodChannel：Dart 端进入画中画 / 标记视频播放中
        // （API 26+ 才支持，低版本由 Dart 端隐藏入口）
        val pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PIP_CHANNEL
        )
        this.pipChannel = pipChannel
        pipChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.error("UNSUPPORTED", "仅支持 Android 8.0 及以上", null)
                    } else {
                        enterPipMode()
                        result.success(true)
                    }
                }
                "setVideoActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    val width = call.argument<Number>("width")?.toInt()
                    val height = call.argument<Number>("height")?.toInt()
                    if (width != null && height != null && width > 0 && height > 0) {
                        pipAspectRatio = Rational(width, height)
                    }
                    pipVideoActive = active
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册原生震动通道：绕过 HyperOS 丢弃的 View.performHapticFeedback，
        // 用 VibratorManager + VibrationEffect.createPredefined 直写马达。
        // 同时实现 m3e_core 的 m3e_haptics/haptics channel（type: dragTexture/
        // tickCrossing/bookendUpper/bookendLower），修复其全部震动点。
        val hapticsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "md3music/haptics"
        )
        hapticsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "vibrate" -> handleHapticVibrate(call, result)
                else -> result.notImplemented()
            }
        }

        val m3eHapticsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "m3e_haptics/haptics"
        )
        m3eHapticsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "vibrate" -> handleHapticVibrate(call, result)
                else -> result.notImplemented()
            }
        }
    }

    /// 原生震动分发：把 Dart/m3e_core 传入的语义 type 映射到系统预定义
    /// VibrationEffect，直写马达。绝不回调 error（让 Dart 端走 fallback）。
    ///
    /// - SDK>=31：VibratorManager.defaultVibrator
    /// - SDK 29~30：Vibrator.vibrate(effect)
    /// - SDK<29：Vibrator.vibrate(30)（无 VibrationEffect 支持）
    ///
    /// 注意：VibrationEffect 仅在 API 29+ 存在，所有相关引用都收敛在 SDK 守卫分支内，
    /// 低版本设备不会执行到（否则触发 NoClassDefFoundError）。
    private fun handleHapticVibrate(call: MethodCall, result: MethodChannel.Result) {
        val type = call.argument<String>("type") ?: ""
        val amplitude = call.argument<Double>("amplitude") ?: 0.5
        // 未知 type：直接返回 false（让 Dart 走 fallback），不触发马达
        val knownTypes = setOf(
            "click", "bookendLower", "tick", "dragTexture", "tickCrossing",
            "heavy", "bookendUpper", "double", "longPress",
        )
        if (type !in knownTypes) {
            Log.d("HapticDebug", "vibrate type=$type amp=$amplitude ok=false")
            result.success(false)
            return
        }
        var handled = false
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                    val vibrator =
                        getSystemService(VibratorManager::class.java).defaultVibrator
                    vibrator.vibrate(buildHapticEffect(type, amplitude))
                    handled = true
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    getSystemService(Vibrator::class.java)
                        ?.vibrate(buildHapticEffect(type, amplitude))
                    handled = true
                }
                else -> {
                    @Suppress("DEPRECATION")
                    getSystemService(Vibrator::class.java)?.vibrate(30)
                    handled = true
                }
            }
        } catch (_: Throwable) {
            handled = false
        }
        Log.d("HapticDebug", "vibrate type=$type amp=$amplitude ok=$handled")
        result.success(handled)
    }

    /// 仅 API 29+ 调用：把语义 type 映射为预定义 VibrationEffect。
    /// 未知 type 回退到 EFFECT_TICK（仍算成功触发，避免 Dart 走失效 fallback）。
    @TargetApi(Build.VERSION_CODES.Q)
    private fun buildHapticEffect(type: String, amplitude: Double): VibrationEffect {
        return when (type) {
            "click", "bookendLower" ->
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
            "tick", "dragTexture" ->
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
            "tickCrossing" ->
                if (amplitude >= 0.5) {
                    VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                } else {
                    VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
                }
            "heavy", "bookendUpper" ->
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
            "double" ->
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK)
            "longPress" ->
                VibrationEffect.createOneShot(25, VibrationEffect.DEFAULT_AMPLITUDE)
            else ->
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
        }
    }

    /// 以当前保存的视频宽高比进入画中画（API 26+）。
    private fun enterPipMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (isInPictureInPictureMode) return
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(pipAspectRatio)
            .build()
        enterPictureInPictureMode(params)
    }

    /// 画中画模式切换回调：通知 Dart 端切换到纯视频布局 / 恢复完整页面。
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        try {
            pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
        } catch (_: Exception) {
            // Flutter 引擎可能尚未就绪，忽略
        }
    }

    /// 用户按 Home 离开当前页面：视频播放中自动进入画中画（MV 播放场景）。
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            pipVideoActive && !isInPictureInPictureMode
        ) {
            enterPipMode()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FOLDER_PICKER_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!
                // 持久化 URI 权限
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}
                folderPickerResult?.success(treeUri.toString())
            } else {
                folderPickerResult?.success(null)
            }
            folderPickerResult = null
        } else if (requestCode == FONT_PICKER_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                // 后台线程：把 content URI 流拷贝到 filesDir/fonts/user_custom.ttf
                // 拷贝成功后在主线程返回真实路径给 Flutter
                Thread {
                    try {
                        val targetDir = File(filesDir, "fonts").apply { mkdirs() }
                        val targetFile = File(targetDir, "user_custom.ttf")
                        contentResolver.openInputStream(uri).use { input ->
                            targetFile.outputStream().use { output ->
                                input?.copyTo(output)
                            }
                        }
                        // 关键：success 与清空 fontPickerResult 必须在同一个主线程任务里原子完成
                        // 否则子线程的 fontPickerResult = null 会在主线程处理 success 之前执行，
                        // 导致 ?.success(...) 被空安全调用跳过，Dart 端 invokeMethod 永远收不到回调
                        runOnUiThread {
                            fontPickerResult?.success(targetFile.absolutePath)
                            fontPickerResult = null
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            fontPickerResult?.error("COPY_FAILED", e.message, null)
                            fontPickerResult = null
                        }
                    }
                }.start()
            } else {
                fontPickerResult?.success(null)
                fontPickerResult = null
            }
        } else if (requestCode == BACKGROUND_PICKER_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                // 后台线程：把 content URI 流拷贝到 filesDir/background/bg_<ts>.<ext>
                Thread {
                    try {
                        val targetDir = File(filesDir, "background").apply { mkdirs() }
                        // 时间戳命名：每次更换图片路径必然不同，Dart 端据此触发刷新
                        // + 新的 FileImage 缓存键（固定文件名会导致更换后仍显示旧图）
                        val targetFile = File(
                            targetDir,
                            "bg_${System.currentTimeMillis()}.${guessImageExtension(uri)}"
                        )
                        contentResolver.openInputStream(uri).use { input ->
                            targetFile.outputStream().use { output ->
                                input?.copyTo(output)
                            }
                        }
                        // 拷贝成功后清理旧背景文件，避免累积
                        targetDir.listFiles()?.forEach { old ->
                            if (old.isFile && old.absolutePath != targetFile.absolutePath) old.delete()
                        }
                        // 与字体选择器同理：success 与清空 result 必须同一主线程任务原子完成
                        runOnUiThread {
                            backgroundPickerResult?.success(targetFile.absolutePath)
                            backgroundPickerResult = null
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            backgroundPickerResult?.error("COPY_FAILED", e.message, null)
                            backgroundPickerResult = null
                        }
                    }
                }.start()
            } else {
                backgroundPickerResult?.success(null)
                backgroundPickerResult = null
            }
        } else if (requestCode == RECOGNITION_PROJECTION_REQUEST) {
            // 悬浮窗识曲：MediaProjection 授权结果 → 注入服务 + 通知 Dart
            val granted = resultCode == RESULT_OK && data != null
            recognitionChannel?.invokeMethod("onProjectionResult", granted)
            FloatingRecognitionService.onProjectionResult(resultCode, data)
        }
    }

    /// 根据 content URI 推断图片扩展名（MIME → ext；取不到时用 URI 文件名后缀，再兜底 jpg）。
    private fun guessImageExtension(uri: Uri): String {
        return try {
            val mime = contentResolver.getType(uri)
            when (mime) {
                "image/png" -> "png"
                "image/webp" -> "webp"
                "image/gif" -> "gif"
                "image/bmp" -> "bmp"
                "image/heic", "image/heif" -> "heic"
                "image/svg+xml" -> "svg"
                else -> {
                    uri.lastPathSegment?.substringAfterLast('.', "")
                        ?.takeIf { it.isNotBlank() && it.length <= 5 }
                        ?: "jpg"
                }
            }
        } catch (_: Exception) {
            "jpg"
        }
    }

    override fun onDestroy() {
        // Activity 销毁（含应用从最近任务划掉时系统先回调 onDestroy 再杀进程）
        // 同步通知 Rust 服务器停止监听，释放端口
        shutdownNodeJs()
        // 释放频谱 Visualizer，避免 native 资源泄漏
        try { spectrumPlugin?.cleanup() } catch (_: Throwable) {}
        spectrumPlugin = null
        cachedEngine = null
        cachedChannel = null
        recognitionChannel = null
        pipChannel = null
        pipVideoActive = false
        super.onDestroy()
    }
}
