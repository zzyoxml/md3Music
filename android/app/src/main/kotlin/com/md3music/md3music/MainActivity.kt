package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.ComponentName
import android.content.Intent
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.annotation.TargetApi
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.Display
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.md3music.md3music.AudioPlaybackService
import com.md3music.md3music.FloatingLyricService
import java.io.File

/// MethodChannel Int 参数的 Number 安全读取。
///
/// Dart 的 ARGB 颜色（如 0xFFFF00FF = 4294901751）超出 Int32，经
/// StandardMessageCodec 到 Java 侧是 **Long**（UINT32 解码为 `& 0xffffffffL`）。
/// `call.argument<Int>` 对 Long 会 ClassCastException → 返回 null，
/// putExtra 被静默跳过 —— 这就是「App 设置页改颜色，悬浮窗不同步」的根因
/// （字号/不透明度等小整数不受影响）。统一按 Number 读再转 Int。
private fun MethodCall.intArg(key: String): Int? =
    (argument<Any?>(key) as? Number)?.toInt()

/// 滑块震动的原生闸门，由 Dart 侧 AppHaptics 下发（见 setSliderEnabled）。
///
/// m3e_core 的滑条震动不经我们的 Dart 封装，它自己直连 m3e_haptics/haptics 通道，
/// 所以「滑块调节」的开关与类型覆盖都只能在这一侧生效。放进程级 object 而非
/// Activity 字段：引擎复用路径下 configureFlutterEngine 会再次执行，字段会被重置成
/// 默认值，而 Dart 不会重新下发，闸门就会悄悄失效。
private object HapticsGate {
    @Volatile
    var sliderEnabled: Boolean = true

    /// 非空时覆盖 m3e 传来的 type（轻点/刻度/重击/双击/长按）；空则用 m3e 自己的类型。
    @Volatile
    var sliderType: String? = null
}

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.md3music.md3music/floating_lyric"
    private val FOLDER_PICKER_CHANNEL = "com.md3music.md3music/folder_picker"
    private val FONT_PICKER_CHANNEL = "com.md3music.md3music/font_picker"
    private val BACKGROUND_PICKER_CHANNEL = "com.md3music.md3music/background_picker"
    private val MEDIA_STORE_CHANNEL = "com.md3music.md3music/media_store"
    private val RECOGNITION_CHANNEL = "com.md3music.md3music/floating_recognition"
    private val PIP_CHANNEL = "com.md3music.md3music/pip"
    private val TASK_CHANNEL = "com.md3music.md3music/task"
    private var pendingDesktopLyricAction: String? = null
    private var folderPickerResult: MethodChannel.Result? = null
    private var fontPickerResult: MethodChannel.Result? = null
    private var backgroundPickerResult: MethodChannel.Result? = null
    // 悬浮窗识曲 channel：MediaProjection 授权结果等原生→Dart 回调
    private var recognitionChannel: MethodChannel? = null
    // MV 画中画 channel：原生→Dart 回调 onPipModeChanged
    private var pipChannel: MethodChannel? = null
    // 首次帧监听只注册一次（引擎复用路径 configureFlutterEngine 会再次执行）
    private var firstFrameListener: io.flutter.embedding.engine.renderer.FlutterUiDisplayListener? = null
    // IME 代理视图（TV 构建专用；FEATURE_TV=false 时为 null）。1×1 可聚焦 child，
    // 作为 FlutterView 的文本编辑器语义代理。
    private var imvProxyView: TvImeProxyView? = null

    companion object {
        private const val FOLDER_PICKER_REQUEST_CODE = 9999
        private const val FONT_PICKER_REQUEST_CODE = 10000
        private const val RECOGNITION_PROJECTION_REQUEST = 10001
        private const val BACKGROUND_PICKER_REQUEST_CODE = 10002

        // 静态引用：让 Service 也能调用 MethodChannel（无 FlutterEngine 缓存时走这里）
        private var cachedEngine: FlutterEngine? = null
        private var cachedChannel: MethodChannel? = null
        // KugouApiService 由应用进程持有。Activity 重建/退后台不能关停仍服务后台播放的 API。
        @Volatile private var kugouApiService: KugouApiService? = null
        // 频谱插件引用，Activity 销毁时释放 Visualizer
        @Volatile private var spectrumPlugin: SpectrumPlugin? = null

        // MD3Music fork v21：车机卡片深链的冷启动残留（Dart 引擎未就绪时暂存）
        @Volatile private var pendingOpenCardLyric = false

        // MV 画中画：Dart 端标记视频是否播放中（按 Home 自动进入画中画用）
        @Volatile private var pipVideoActive = false
        // MV 视频宽高比（宽/高），用于画中画窗口比例
        @Volatile private var pipAspectRatio: Rational = Rational(16, 9)

        // 悬浮窗启动结果回填的超时兜底：正常 onCreate 秒级完成；个别 ROM 若因故
        // 未触发 onCreate，在此按当前状态结算，避免 Dart 端 startFloatingLyric 永久挂起。
        private const val FLOATING_START_TIMEOUT_MS = 5000L

        // 记录自定义插件已注册到的引擎：provideFlutterEngine 复用后台（headless）
        // 引擎时 configureFlutterEngine 会再次执行，若对同一引擎重复注册
        // UsbAudioPlugin 会注册两个拔插广播接收器（无法 unregister），导致 USB
        // 事件被处理两次；而新引擎（进程被杀后重建）仍需注册，故按引擎身份判断。
        private var customPluginsEngine: FlutterEngine? = null
        @Volatile private var equalizerPlugin: EqualizerPlugin? = null
        @Volatile private var usbAudioPlugin: UsbAudioPlugin? = null
        @Volatile private var directPcmPlugin: DirectPcmPlugin? = null
        @Volatile private var musicHapticsPlugin: MusicHapticsPlugin? = null
        // 系统音频 Offload 通道（TV 也注册，故独立于 FEATURE_TV 分支）
        @Volatile private var audioOffloadPlugin: AudioOffloadPlugin? = null

        /** Activity 与 headless 服务共用自定义播放插件，避免缺 handler 和重复USB接收器。 */
        @Synchronized
        internal fun registerPlaybackPlugins(context: Context, engine: FlutterEngine) {
            if (customPluginsEngine === engine) return

            runCatching { spectrumPlugin?.cleanup() }
            runCatching { equalizerPlugin?.cleanup() }
            runCatching { usbAudioPlugin?.cleanup() }
            runCatching { directPcmPlugin?.cleanup() }
            runCatching { musicHapticsPlugin?.cleanup() }
            runCatching { audioOffloadPlugin?.cleanup() }
            customPluginsEngine = engine

            EqualizerPlugin().also {
                it.register(engine)
                equalizerPlugin = it
            }
            // 蝰蛇母带通道：将母带设置与十段均衡器增益发送到 just_audio 处理链。
            ViperDspPlugin().register(engine)
            spectrumPlugin = SpectrumPlugin().also { it.register(engine) }
            // 音乐节奏震动：预构建 VibrationEffect 缓存 + 专用线程点火。
            // runCatching 兜底：能力探测涉及多档 SDK_INT 守卫（hasAmplitudeControl 是
            // API 26 方法），任何遗漏都只能让功能降级，绝不允许把整个进程带崩——
            // issue #130 正是无守卫写在属性初始化器里，导致 Android 7.x TV 盒子
            // （rk3128）冷启动必崩。musicHapticsPlugin 保持 null 时各 cleanup 空跑无害，
            // 交互震动的 noteInteraction() 是 companion 静态方法，与实例无关。
            runCatching {
                MusicHapticsPlugin(context).also {
                    it.register(engine)
                    musicHapticsPlugin = it
                }
            }.onFailure {
                Log.w("MusicHaptics", "插件注册失败：$it")
            }
            // TV 版不编入 USB 独占/Direct PCM（BuildConfig.FEATURE_TV=false 跳过注册；
            // release 由 R8 剥离未引用类）。类字段保留（cleanup 空跑无害）。
            if (!BuildConfig.FEATURE_TV) {
                UsbAudioPlugin(context).also {
                    it.register(engine)
                    usbAudioPlugin = it
                }
                // 系统 Direct PCM 档（走系统 AudioTrack 的 bit-perfect 路径，与 USB 独占互斥）
                DirectPcmPlugin(context).also {
                    it.register(engine)
                    directPcmPlugin = it
                }
            }
            // 系统音频 Offload 通道：放在 FEATURE_TV 判断之外——电视盒子同样走
            // 系统 offload，必须编入。能力探测在插件内部后台预热，注册失败仅降级
            // 该功能（音质档位退回默认），不允许影响启动。
            runCatching {
                AudioOffloadPlugin(context).also {
                    it.register(engine)
                    audioOffloadPlugin = it
                }
            }.onFailure {
                Log.w("AudioOffload", "插件注册失败：$it")
            }
            ExternalEditorPlugin(context).register(engine)
            DiagnosticLogPlugin().register(engine)
            AutomixAnalysisPlugin().register(engine)
        }

        @Synchronized
        internal fun unregisterPlaybackPlugins(engine: FlutterEngine) {
            if (customPluginsEngine !== engine) return
            runCatching { spectrumPlugin?.cleanup() }
            runCatching { equalizerPlugin?.cleanup() }
            runCatching { usbAudioPlugin?.cleanup() }
            runCatching { directPcmPlugin?.cleanup() }
            runCatching { musicHapticsPlugin?.cleanup() }
            runCatching { audioOffloadPlugin?.cleanup() }
            spectrumPlugin = null
            equalizerPlugin = null
            usbAudioPlugin = null
            directPcmPlugin = null
            musicHapticsPlugin = null
            audioOffloadPlugin = null
            customPluginsEngine = null
        }

        fun setKugouApiService(service: KugouApiService?) {
            kugouApiService = service
        }

        /// 锁屏卡片「投屏/队列」等动作的待处理值：拉起 app 时若 Dart 尚未就绪，
        /// 动作留在这里，由 Dart `takePendingWidgetAction` 冷启动兜底拉取。
        @Volatile
        private var pendingWidgetAction: String? = null

        /// 锁屏卡片把 Flutter 侧动作转交给 App：存 pending + 以 NEW_TASK|SINGLE_TOP 拉起。
        ///
        /// 之所以不在锁屏内直接实现投屏/队列：两者都是 Flutter 页面，
        /// 在锁屏 Activity 里另做一套的成本与一致性风险都不划算（见计划「用户确认的设计决策」）。
        @JvmStatic
        fun requestWidgetAction(context: Context, action: String) {
            pendingWidgetAction = action
            try {
                val intent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("widget_action", action)
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.w("MainActivity", "requestWidgetAction failed: ${e.message}")
            }
        }

        /// Dart 冷启动拉取并清空 pending（取走即清空，避免重复执行）。
        fun takePendingWidgetAction(): String? {
            val action = pendingWidgetAction
            pendingWidgetAction = null
            return action
        }

        fun sendDesktopLyricAction(action: String) {
            cachedChannel?.invokeMethod("desktopLyricAction", action)
        }

        fun sendDesktopLyricConfigChanged(config: Map<String, Any?>) {
            cachedChannel?.invokeMethod("desktopLyricConfigChanged", config)
        }

        // ===== 悬浮窗启动结果回填（同进程直达，杜绝"假开启"） =====
        // startFloatingLyric 会把结果挂起，等服务 onCreate 真正完成悬浮窗
        // addView 后再回填真实结果；超时则按当前状态结算，避免 Dart 永久等待。
        @Volatile private var pendingFloatingStart: MethodChannel.Result? = null
        private var pendingFloatingTimeout: Runnable? = null
        private val floatingHandler = Handler(Looper.getMainLooper())

        /** FloatingLyricService 在 onCreate 完成 addView（或失败 stopSelf）后回填。 */
        fun completeFloatingStart(success: Boolean) {
            floatingHandler.post {
                pendingFloatingStart?.let { r ->
                    pendingFloatingStart = null
                    pendingFloatingTimeout?.let { floatingHandler.removeCallbacks(it) }
                    pendingFloatingTimeout = null
                    if (success) r.success(true) else r.success(false)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val createStartedAt = SystemClock.elapsedRealtime()
        Log.i("StartupTiming", "phase=activity_on_create_enter elapsed_realtime_ms=$createStartedAt")
        super.onCreate(savedInstanceState)
        Log.i(
            "StartupTiming",
            "phase=activity_on_create_super_complete elapsed_ms=${SystemClock.elapsedRealtime() - createStartedAt}",
        )
        // 本次启动被看门狗判定自动回退（resolveUseImpeller 已在 super.onCreate 中结算）：
        // UI 尚未就绪，直接弹系统 Toast（不依赖 Flutter 渲染）。
        if (RenderEngineManager.fellBackToSkiaThisLaunch) {
            runOnUiThread {
                android.widget.Toast.makeText(
                    this,
                    "已检测到 Impeller 多次异常，自动回退到 Skia 渲染",
                    android.widget.Toast.LENGTH_LONG,
                ).show()
            }
        }
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

        // IME 代理视图（TV 构建专用）：1×1 可聚焦 child（挂在 FlutterView 之内），
        // 作为 FlutterView 的文本编辑器语义代理，让低内存 Android TV
        // （config_preventImeStartupUnlessTextEditor=true）肯绑定 IME 会话。
        // 形态取自 Flutter PR #193074 正文所述的生产 workaround：1×1 子 View +
        // onCheckIsTextEditor 由 Dart 标志控制 + onCreateInputConnection 委托
        // FlutterView + checkInputConnectionProxy(flutterView)=true。
        if (BuildConfig.FEATURE_TV) {
            runCatching {
                val flutterView = findViewById<FlutterView>(FLUTTER_VIEW_ID)
                if (flutterView == null) {
                    Log.w("TvImeProxy", "FlutterView not found, IME proxy disabled")
                } else {
                    val proxy = TvImeProxyView(this)
                    proxy.flutterViewRef = flutterView
                    // 1×1、左上角；alpha=0（视觉不可见但可获焦，GONE 会失去焦点）。
                    flutterView.addView(
                        proxy,
                        ViewGroup.LayoutParams(1, 1),
                    )
                    imvProxyView = proxy
                    Log.i("TvImeProxy", "attached IME proxy view to FlutterView")
                }
            }.onFailure { error ->
                Log.w("TvImeProxy", "proxy view init failed: $error")
            }
        }

        // 桌面小部件冷启动拉起携带的动作（如登录卡 openLogin → 进登录页）。
        // 引擎尚未就绪时 Flutter 侧导航尚不可用，invokeMethod 静默失败即降级为打开 app。
        dispatchWidgetAction(intent?.getStringExtra("widget_action"))
        // MD3Music fork v21 车机卡片：sessionActivity 深链（media card 点击），冷启动入口
        maybeHandleOpenLyricIntent(intent)
        // 外部调用（文件管理器「用其他应用打开」等）：冷启动入口
        ExternalMediaBridge.onIntent(this, intent)
    }

    /**
     * MD3Music fork v21 车机卡片深链：卡片点击走 sessionActivity（启动意图带
     * md3_open_lyric_fullscreen 标记），判据为**设备级存在任一非默认屏**
     * （dm.displays 有 displayId≠DEFAULT_DISPLAY，与 MSS 连车唤醒判据同源）——
     * 不是"Activity 跑在虚拟屏"：投屏形态下 Flutter Activity 常驻手机主屏，
     * 车机/投影画面由 RunningStackSide 虚拟屏承载，按 Activity 所在屏判会恒判
     * 否。取舍：手机连接 PC 投屏/镜像产生第二显示时，主屏点卡片也会直达全屏
     * 歌词（同义"正在外投"，视为合理语义）；不满足则维持手机旧行为。
     */
    private fun maybeHandleOpenLyricIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("md3_open_lyric_fullscreen", false) != true) return
        val dm = getSystemService(DisplayManager::class.java) ?: return
        val projected = dm.displays.any { it.displayId != Display.DEFAULT_DISPLAY }
        if (!projected) return
        pendingOpenCardLyric = true
        dispatchOpenCardLyric()
    }

    private fun dispatchOpenCardLyric() {
        val engine = FlutterEngineCache.getInstance().get("md3music_engine")
            ?: return
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
                .invokeMethod("openCardLyricView", null)
        } catch (_: Exception) {
            // 引擎刚创建/未跑 Dart 时转发失败：留 pending 由 Dart postFrame 主动拉取
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 同步更新 intent：配置变更重建等场景下 getIntent() 也能拿到最新外部调用数据
        setIntent(intent)
        // singleTop 复用实例时（app 已在前台/后台存活），小部件动作走这里
        dispatchWidgetAction(intent.getStringExtra("widget_action"))
        // MD3Music fork v21 车机卡片：热启动入口
        maybeHandleOpenLyricIntent(intent)
        // 外部调用（文件管理器「用其他应用打开」等）：热启动入口
        ExternalMediaBridge.onIntent(this, intent)
    }

    /// 把小部件/锁屏卡片拉起 app 携带的 widget_action 转发给 Flutter。
    ///
    /// 已知动作：
    /// - `openLogin`：FM 登录卡 → 进登录页；
    /// - `openCast` / `openQueue`：锁屏卡片投屏键 / 队列键 → 由 Dart `LockScreenActionService` 打开对应面板。
    ///
    /// 引擎尚未就绪时 invokeMethod 静默失败，动作留在 pending 里等 Dart 拉取
    /// （与 ExternalMediaBridge 的 takePendingMedia 同一套已验证模式）。
    private fun dispatchWidgetAction(action: String?) {
        when (action) {
            "openLogin" -> {
                val engine = FlutterEngineCache.getInstance().get("md3music_engine") ?: return
                try {
                    MethodChannel(
                        engine.dartExecutor.binaryMessenger,
                        FLOATING_CHANNEL
                    ).invokeMethod("widgetFmOpenLogin", null)
                } catch (_: Exception) {
                    // 引擎刚创建/未跑 Dart 时转发失败：降级为仅打开 app
                }
            }
            "openCast", "openQueue" -> {
                // 先落 pending 再推送：冷启动早期通道未就绪也不会丢动作
                pendingWidgetAction = action
                try {
                    cachedChannel?.invokeMethod("widgetAction", action)
                } catch (_: Exception) {
                    // 同上：保留 pending，由 Dart takePendingWidgetAction 冷启动兜底
                }
            }
            else -> return
        }
    }

    override fun onResume() {
        super.onResume()
        // 回到前台（如从画中画/锁屏/切后台返回）时重新应用，
        // 防止被系统降频后未恢复（偶现锁 60Hz 的场景之一）。
        applyOptimalRefreshRate()
        // MD3Music fork v50：原子随身听点歌拉起兜底——岛端到本 App 的 MediaBrowser
        // 连接随进程重启断链后（D==null），岛点列表项会把 App 拉到前台且丢弃本次
        // 点击（真机 logcat 实证：Displayed LauncherModernIcon）。这里借 onResume
        // 重发一次岛 metadata：岛 onMetadataChanged 会刷新源/控制器，用户下一次
        // 点击即可正常下发 playFromMediaId。未初始化时为 no-op。
        try {
            com.ryanheise.just_audio.AudioPlayer.republishVivoIslandState()
        } catch (_: Throwable) {
        }
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

    /** 启用旧版或当前 launcher alias，并关闭另一个，避免桌面出现重复图标。 */
    private fun setLegacyLauncherIcon(useLegacy: Boolean) {
        val classPrefix = MainActivity::class.java.name.substringBeforeLast('.')
        val modern = ComponentName(this, "$classPrefix.LauncherModernIcon")
        val legacy = ComponentName(this, "$classPrefix.LauncherLegacyIcon")
        val selected = if (useLegacy) legacy else modern
        val disabled = if (useLegacy) modern else legacy
        packageManager.setComponentEnabledSetting(
            selected,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        packageManager.setComponentEnabledSetting(
            disabled,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    /// 复用后台（headless）FlutterEngine：线控耳机「唤醒播放」被拉起时，
    /// AudioPlaybackService 已创建并运行完整 App（main() 已执行、PlayerProvider
    /// 正在恢复播放状态）。此处返回缓存引擎，避免创建第二个 FlutterEngine 导致
    /// 双 Dart 隔离区 / 双音频会话冲突。引擎不可用时走默认逻辑新建。
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        val cached = FlutterEngineCache.getInstance().get("md3music_engine")
        if (cached != null && cached.dartExecutor.isExecutingDart() && isFlutterJniAttached(cached)) {
            // 宿主引擎复用路径：configureFlutterEngine 不保证执行，显式补注册 Lyrico 编辑插件
            try { ExternalEditorPlugin(this).register(cached) } catch (_: Throwable) {}
            return cached
        }
        if (cached != null) {
            // 有些 Android 版本/任务移除时序会留下“Dart 仍报告运行、JNI 已 detach”的缓存壳；
            // 复用后 FlutterView 首次布局会在 setViewportMetrics 崩溃。丢弃壳并走标准新引擎路径。
            Log.w("MainActivity", "discarding cached FlutterEngine: Dart or FlutterJNI is no longer active")
            if (FlutterEngineCache.getInstance().get("md3music_engine") === cached) {
                FlutterEngineCache.getInstance().remove("md3music_engine")
            }
            if (cachedEngine === cached) cachedEngine = null
        }
        return super.provideFlutterEngine(context)
    }

    private fun isFlutterJniAttached(engine: FlutterEngine): Boolean = try {
        // FlutterEngine 未公开 JNI attached 状态；以官方 embedding 的 FlutterJNI.isAttached 作防御性校验。
        val field = FlutterEngine::class.java.getDeclaredField("flutterJNI")
        field.isAccessible = true
        (field.get(engine) as? io.flutter.embedding.engine.FlutterJNI)?.isAttached == true
    } catch (error: Exception) {
        Log.w("MainActivity", "unable to inspect cached FlutterJNI attachment", error)
        false
    }

    // 引擎已交给进程缓存和播放服务持有；首个 Activity 也不能销毁它，
    // 否则新 Activity 接管缓存引擎时会触发 Flutter 的所有权断言。
    override fun shouldDestroyEngineWithHost(): Boolean = false


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        val configureStartedAt = SystemClock.elapsedRealtime()
        Log.i("StartupTiming", "phase=configure_flutter_engine_enter elapsed_realtime_ms=$configureStartedAt")
        super.configureFlutterEngine(flutterEngine)
        Log.i(
            "StartupTiming",
            "phase=configure_flutter_engine_super_complete elapsed_ms=${SystemClock.elapsedRealtime() - configureStartedAt}",
        )
        // 首帧监听：Impeller 成功渲染首帧 → 清零启动失败计数（证明本次未崩溃）。
        if (firstFrameListener == null) {
            val listener = object : io.flutter.embedding.engine.renderer.FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    Log.i(
                        "StartupTiming",
                        "phase=flutter_ui_displayed elapsed_realtime_ms=${SystemClock.elapsedRealtime()}",
                    )
                    RenderEngineManager.firstFrameConfirmed(this@MainActivity)
                }
                override fun onFlutterUiNoLongerDisplayed() {}
            }
            firstFrameListener = listener
            flutterEngine.renderer.addIsDisplayingFlutterUiListener(listener)
        }

        // 渲染引擎通道：设置页展示当前构建引擎（构建期 flavor 决定，运行时不可切换）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.md3music.md3music/render_engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrent" -> result.success(
                        if (RenderEngineManager.isImpellerBuild(this)) "impeller" else "skia"
                    )
                    else -> result.notImplemented()
                }
            }

        // 系统输出切换（Android 14+ 的输出切换器；小米 HyperOS 上即「妙播」面板）。
        // 失败只降级该入口：注册异常绝不能影响启动（同类兜底见 MusicHaptics/AudioOffload）。
        runCatching {
            MediaOutputPlugin(this).register(flutterEngine)
        }.onFailure {
            Log.w("MediaOutput", "插件注册失败：$it")
        }

        // 设置页切换当前启用的 launcher alias；DONT_KILL_APP 保证图标变更不打断播放。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.md3music.md3music/app_icon")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLegacyIcon" -> {
                        val useLegacy = call.arguments as? Boolean
                        if (useLegacy == null) {
                            result.error("INVALID_ARGUMENT", "enabled 必须为布尔值", null)
                        } else {
                            runCatching { setLegacyLauncherIcon(useLegacy) }
                                .onSuccess { result.success(null) }
                                .onFailure {
                                    result.error("ICON_SWITCH_FAILED", it.message, null)
                                }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 设备形态查询：TV 构建下 RemoteControlProvider 用 uiMode 判定是否 TV 设备。
        // 仅 FEATURE_TV 时注册（正常构建 Dart 侧无调用方）。
        if (BuildConfig.FEATURE_TV) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/device_form",
            ).setMethodCallHandler { call, result ->
                if (call.method == "isTv") {
                    val uiModeManager =
                        getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    result.success(
                        uiModeManager.currentModeType ==
                            Configuration.UI_MODE_TYPE_TELEVISION
                    )
                } else {
                    result.notImplemented()
                }
            }

            // IME 代理视图通道：把 Dart 侧的「输入框持焦」信号转发给原生代理 View，
            // 让低内存 Android TV（config_preventImeStartupUnlessTextEditor=true）肯绑定
            // IME 会话（Flutter #177360）。会话修好前遥控器按键一个都到不了软键盘。
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.md3music.md3music/ime_proxy")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setActive" -> {
                            val args = call.arguments as? Map<*, *>
                            val active = args?.get("active") as? Boolean ?: false
                            runCatching {
                                val proxy = imvProxyView
                                if (proxy != null) {
                                    proxy.imeActive = active
                                    if (active) {
                                        // 抢焦点：IMMS 判定「是否文本编辑器」问的就是
                                        // 持焦视图，不获焦则整个代理不生效。
                                        proxy.requestFocus()
                                    } else {
                                        proxy.clearFocus()
                                    }
                                    // 触发系统重新评估 onCheckIsTextEditor 并刷新会话绑定。
                                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                                        as? InputMethodManager
                                    imm?.restartInput(proxy)
                                    Log.i("TvImeProxy", "setActive=$active")
                                }
                            }.onFailure {
                                Log.e("TvImeProxy", "setActive failed: $it")
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
        }

        // 3D 封面：Depth Anything V2 ORT 推理 + 3 层切割（背景/中景/前景，带 alpha）
        // 3D 深度封面插件仅存在于 depth3d flavor（standard 包无此类、无 onnxruntime so）。
        // 用反射注册保持 MainActivity 对两个 flavor 通用；找不到类时静默跳过。
        // 注意：DepthCoverPlugin 是 Kotlin object，register 是实例方法——
        // 必须先取 INSTANCE 再反射，直接在 Class 上 getDeclaredMethod 会 NoSuchMethodException。
        runCatching {
            val pluginClass = Class.forName("com.md3music.md3music.DepthCoverPlugin")
            val pluginInstance = pluginClass.getDeclaredField("INSTANCE").get(null)
            pluginInstance.javaClass
                .getMethod(
                    "register",
                    android.app.Activity::class.java,
                    io.flutter.plugin.common.BinaryMessenger::class.java,
                )
                .invoke(pluginInstance, this, flutterEngine.dartExecutor.binaryMessenger)
        }.onFailure {
            android.util.Log.w("DepthCover", "depth3d 插件注册失败：$it")
        }

        // 端侧人声/伴奏分离（MSS tflite）仅存在于 standard / depth3d flavor：
        //   - 两个 flavor 的源集都含 src/stemsep/kotlin 与 src/stemsep/assets；
        //   - tv flavor 不含该源集（类不存在），反射注册失败后静默跳过；
        //   - 公开树导出时资产被剔除，插件自报 available=false，入口自动隐藏。
        // 与 DepthCoverPlugin 同一模式（Kotlin object → 先取 INSTANCE 再反射）。
        runCatching {
            val pluginClass = Class.forName("com.md3music.md3music.stem.StemSeparationPlugin")
            val pluginInstance = pluginClass.getDeclaredField("INSTANCE").get(null)
            pluginInstance.javaClass
                .getMethod(
                    "register",
                    android.content.Context::class.java,
                    io.flutter.plugin.common.BinaryMessenger::class.java,
                )
                .invoke(pluginInstance, this, flutterEngine.dartExecutor.binaryMessenger)
        }.onFailure {
            android.util.Log.w("StemSep", "端侧分离插件不可用（flavor 不含或注册失败）：$it")
        }

        // MD3Music fork（方向1）：前台 UI 引擎恢复启用媒体3会话（headless 引擎曾关闭），
        // 保证系统媒体会话始终=前台 UI 播放器。
        try { com.ryanheise.just_audio.AudioPlayer.setMediaSessionEnabled(true) } catch (_: Throwable) {}

        // 缓存引擎：Service 端没有 FlutterEngine 时（app 进程被回收场景），能复用
        FlutterEngineCache.getInstance().put("md3music_engine", flutterEngine)
        cachedEngine = flutterEngine
        cachedChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)

        // 外部调用（ACTION_VIEW 音频）通道：原生推送 onExternalMedia，Dart 拉取 takePendingMedia
        ExternalMediaBridge.registerChannel(flutterEngine)

        // 将 FlutterEngine 传递给 AudioPlaybackService
        AudioPlaybackService.setFlutterEngine(flutterEngine)

        registerPlaybackPlugins(applicationContext, flutterEngine)

        // 初始化本地 API 服务器（KugouApiService 含 JNI external 方法，
        // 如果 .so 的 JNI 符号名与当前包名不匹配，实例化可能触发类验证错误，
        // 这里包一层 try-catch，失败时 Dart 端会走 dart:ffi 兜底）。
        android.util.Log.d("MainActivity", "Initializing KugouApiService...")
        try {
            // API 服务由进程级静态引用持有，必须使用 applicationContext，避免旋转/重建后泄漏 Activity。
            val apiSvc = KugouApiService(applicationContext, flutterEngine)
            setKugouApiService(apiSvc)
            android.util.Log.d("MainActivity", "KugouApiService initialized")
        } catch (e: Throwable) {
            android.util.Log.e("MainActivity", "KugouApiService init failed: ${e.message}")
            setKugouApiService(null)
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // MD3Music fork v21 车机卡片：冷启动残留深链在 Dart 侧主动拉取
                "consumePendingOpenCardLyric" -> {
                    val pending = pendingOpenCardLyric
                    pendingOpenCardLyric = false
                    result.success(pending)
                }
                "startFloatingLyric" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                        startActivity(intent)
                        result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                    } else {
                        // 服务已在运行且悬浮窗已成功添加：直接成功（避免重复拉起服务）
                        if (FloatingLyricService.isRunning && FloatingLyricService.viewAdded) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        // 挂起结果：等服务 onCreate 真正完成 addView（或权限竞态失败
                        // stopSelf）后由 completeFloatingStart 回填真实结果，不再提前
                        // 返回 success，杜绝"开关已开但悬浮窗未出现"的假开启。
                        // MD3Music fork v28d：5s 窗口内重复调用先结算上一个挂起
                        // Result（按当前状态）并撤旧超时——否则旧 Result 悬挂泄漏
                        // （Dart Future 永久挂起），旧 timeout 到点还会抢用新
                        // Result 提前按旧状态回填。
                        pendingFloatingTimeout?.let { floatingHandler.removeCallbacks(it) }
                        pendingFloatingTimeout = null
                        pendingFloatingStart?.let { previous ->
                            pendingFloatingStart = null
                            previous.success(
                                FloatingLyricService.isRunning && FloatingLyricService.viewAdded
                            )
                        }
                        pendingFloatingStart = result
                        val timeout = Runnable { completeFloatingStart(FloatingLyricService.viewAdded) }
                        pendingFloatingTimeout = timeout
                        floatingHandler.postDelayed(timeout, FLOATING_START_TIMEOUT_MS)
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_UPDATE_LYRIC
                            putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                            putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        }
                        // v33：与 showNotification 调用点同构——前台被 ROM 拒时吞掉
                        // ForegroundServiceStartNotAllowedException（悬浮窗自身
                        // 台账已按失败路径自停，无 5s duty）。
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        } catch (t: Throwable) {
                            Log.w("MainActivity", "floating update start rejected: ${t.message}")
                        }
                    }
                }
                "updateLyric" -> {
                    val wordsRaw = call.argument<List<Object>>("words")
                    val wordsJson = if (wordsRaw != null) {
                        try {
                            org.json.JSONArray(wordsRaw).toString()
                        } catch (e: Exception) {
                            "[]"
                        }
                    } else {
                        "[]"
                    }
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_LYRIC
                        putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_NEXT_LYRIC, call.argument<String>("nextLyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_PLACEHOLDER, call.argument<String>("placeholder") ?: "")
                        putExtra(FloatingLyricService.EXTRA_WORDS, wordsJson)
                        putExtra(FloatingLyricService.EXTRA_LINE_POSITION,
                            (call.argument<Number>("positionMs")?.toLong() ?: 0L))
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
                "isFloatingLyricWindowRunning" -> {
                    // MD3Music fork：原生窗口实况查询。引擎被系统杀死后 Dart 侧开关
                    // 丢失（restoreFloatingFromNative 用它判断是否恢复悬浮窗推送）。
                    result.success(FloatingLyricService.isRunning && FloatingLyricService.viewAdded)
                }
                "setDesktopLyricConfig" -> {
                    // 窗口不在时不再把服务拉起来：设置页「锁定歌词」等配置推送
                    // 此前会无条件 startService，把一个谁都不会往里推词的空窗口
                    // 建出来（黑框）。配置本来会落 SharedPreferences，下次真正
                    // 开启（enable 随后会推同一份配置）时自然生效。
                    if (FloatingLyricService.isRunning && FloatingLyricService.viewAdded) {
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
                        call.intArg(FloatingLyricService.EXTRA_OPACITY)?.let {
                            putExtra(FloatingLyricService.EXTRA_OPACITY, it)
                        }
                        call.argument<Boolean>(FloatingLyricService.EXTRA_LOCKED)?.let {
                            putExtra(FloatingLyricService.EXTRA_LOCKED, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_GRADIENT_START)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_START, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_GRADIENT_END)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_END, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_UNPLAYED_COLOR)?.let {
                            putExtra(FloatingLyricService.EXTRA_UNPLAYED_COLOR, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_COLOR_MODE)?.let {
                            putExtra(FloatingLyricService.EXTRA_COLOR_MODE, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_PRESET_INDEX)?.let {
                            putExtra(FloatingLyricService.EXTRA_PRESET_INDEX, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_CUSTOM_GRAD_START)?.let {
                            putExtra(FloatingLyricService.EXTRA_CUSTOM_GRAD_START, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_CUSTOM_GRAD_END)?.let {
                            putExtra(FloatingLyricService.EXTRA_CUSTOM_GRAD_END, it)
                        }
                        call.intArg(FloatingLyricService.EXTRA_CUSTOM_UNPLAYED)?.let {
                            putExtra(FloatingLyricService.EXTRA_CUSTOM_UNPLAYED, it)
                        }
                        }
                        startService(intent)
                    }
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
                        putExtra(
                            AudioPlaybackService.EXTRA_MEDIA_ID,
                            call.argument<String>("songId") ?: ""
                        )
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
                        try {
                            startForegroundService(intent)
                        } catch (e: Exception) {
                            // 阶段6修复：App 转后台（导航等夺焦点）时后台启动前台服务会被系统
                            // 拒绝（ForegroundServiceStartNotAllowedException）。吞掉避免崩溃，
                            // 媒体通知由 media3 会话承载，保活服务稍后回到前台再恢复。
                            Log.w("MainActivity", "startForegroundService rejected: ${e.javaClass.simpleName}: ${e.message}")
                            // MD3Music fork（方案A·封面兜底）：服务启动被拒时媒体通知由
                            // media3 会话承载（不受影响），但封面注入依赖本服务前台启动——
                            // 直接调 AudioPlaybackService.injectCover 兜底注入封面到媒体3会话。
                            AudioPlaybackService.injectCover(
                                this@MainActivity,
                                call.argument<String>("songId") ?: "",
                                call.argument<String>("title") ?: "",
                                call.argument<String>("artist") ?: "",
                                call.argument<String>("artUrl"),
                                call.argument<String>("fallbackFilePath")
                            )
                        }
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                // 封面预取：切歌前把接下来数首封面下载到内存/磁盘缓存，切歌时命中秒显。
                // 该方法在 headless 引擎通道有处理，但 MainActivity 正常运行时的主通道缺失
                // → 预取静默失败。此处补注册，复用 AudioPlaybackService.prefetchCovers。
                "prefetchCover" -> {
                    val urls = call.argument<List<String>>("urls").orEmpty()
                    AudioPlaybackService.prefetchCovers(this, urls)
                    result.success(true)
                }
                // MD3Music fork v40：原子随身听三棵列表快照——headless 通道已有处理，
                // 但前台主通道（本 handler）缺失会让前台推送全部 notImplemented 被 Dart
                // 空 catch 吞掉（第六轮审查 P0）。补注册，转发 APS 的静态解析。
                "updateVivoMixLists" -> {
                    AudioPlaybackService.updateVivoMixLists(call.arguments)
                    result.success(true)
                }
                // MD3Music fork v50：岛状态回显——同上，前台主通道补注册（第六轮
                // 审查同款教训：headless 有而主通道缺 → 前台推送 notImplemented 被吞）。
                "updateVivoMixState" -> {
                    AudioPlaybackService.updateVivoMixState(call.arguments)
                    result.success(true)
                }
                // MD3Music fork v63：点歌后强制岛列表重拉（高亮立即跟随）——
                // 同 v50 教训：headless 通道有而主通道缺 → 前台推送被吞。
                "refreshVivoMixChildren" -> {
                    AudioPlaybackService.refreshVivoMixChildren()
                    result.success(true)
                }
                // 蓝牙歌词兼容通道；原生端保持共享 MediaSession 的歌曲身份不变。
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
                        putExtra(
                            AudioPlaybackService.EXTRA_MEDIA_ID,
                            call.argument<String>("songId") ?: ""
                        )
                        putExtra(
                            AudioPlaybackService.EXTRA_LYRIC_SESSION_GENERATION,
                            call.argument<Int>("sessionGeneration") ?: 0
                        )
                        putExtra(
                            AudioPlaybackService.EXTRA_HAS_LYRIC_TRANSLATION,
                            call.argument<Boolean>("hasTranslation") ?: false
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
                "updateLockScreenLyricData" -> {
                    LockScreenLyricActivity.applyDataCall(call)
                    result.success(true)
                }
                "updateLockScreenProgress" -> {
                    LockScreenLyricActivity.applyProgressCall(call)
                    result.success(true)
                }
                "updateLockScreenAccent" -> {
                    LockScreenLyricActivity.applyAccentCall(call)
                    result.success(true)
                }
                // 锁屏卡片收藏态增量同步：只翻红心，不重推歌词
                "updateLockScreenFavorite" -> {
                    LockScreenLyricActivity.applyFavoriteCall(call)
                    result.success(true)
                }
                // 冷启动时锁屏卡片动作（投屏/队列）可能在 Dart 就绪前触发：取走即清空
                "takePendingWidgetAction" -> {
                    result.success(takePendingWidgetAction())
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
                        // v33：与 :723 调用点同构——被拒不冒主线程（FRS 自身
                        // onSave 失败/停止路径自管，无 5s duty）。
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                        } catch (t: Throwable) {
                            Log.w("MainActivity", "recognition start rejected: ${t.message}")
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
        // 注册魅族 Flyme 状态栏歌词 MethodChannel（Dart 切行时推送当前歌词行）
        FlymeLyricBridge.registerChannel(flutterEngine, applicationContext)

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
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PERMISSION_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_URI", "URI is null", null)
                    }
                }
                "queryTreeAudioFiles" -> {
                    val treeUri = call.argument<String>("uri")
                    if (treeUri.isNullOrBlank()) {
                        result.error("INVALID_URI", "目录 URI 为空", null)
                    } else {
                        Thread {
                            try {
                                val files = SafAudioScanner.queryAudioFiles(this, treeUri)
                                runOnUiThread { result.success(files) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("TREE_SCAN_ERROR", error.message, null) }
                            }
                        }.start()
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
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
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

        // 图片保存到相册（长按评论图片保存）：UI 引擎专用，不需要注册到播放服务的
        // headless 引擎（那里没有查看器界面），故只在这里注册一次。
        ImageSaverPlugin(this).register(flutterEngine)

        // 注册桌面小组件 MethodChannel：Flutter 侧推送播放状态到 AppWidget
        HomeWidgetChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)

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

        // 注册任务控制 MethodChannel：
        // - moveToBack：TV「后台播放」/ 手机双击返回 → 回桌面挂后台。
        //   用 moveTaskToBack(等同按 Home)，不销毁 Activity、不杀进程，
        //   播放器与本地 Rust 服务器都保持运行，重新打开瞬时恢复。
        // - exitApp：TV「退出 App」→ Dart 侧已停播放/移除通知并关停 Rust
        //   服务，这里兜底停掉前台播放与媒体会话服务，再结束任务回桌面。
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
                "exitApp" -> {
                    // AudioPlaybackService 在 Manifest 里是 stopWithTask=false，
                    // 只 finish 会让它带着前台通知残留在后台，必须显式停。
                    try {
                        stopService(Intent(this, AudioPlaybackService::class.java))
                    } catch (_: Throwable) {
                    }
                    try {
                        stopService(Intent(this, MD3MusicMediaSessionService::class.java))
                    } catch (_: Throwable) {
                    }
                    Log.i("MainActivity", "exitApp: playback services stopped, finishing task")
                    result.success(true)
                    finishAndRemoveTask()
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
                "setSliderEnabled" -> {
                    HapticsGate.sliderEnabled =
                        call.argument<Boolean>("enabled") ?: true
                    HapticsGate.sliderType = call.argument<String>("type")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val m3eHapticsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "m3e_haptics/haptics"
        )
        m3eHapticsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // 拦住时回 success(true) 而非 error：m3e 的 applyTypedHaptic 只在
                // error 时回落 HapticFeedback，那样马达又被另一条路径驱动了。
                "vibrate" ->
                    if (HapticsGate.sliderEnabled)
                        handleHapticVibrate(call, result, HapticsGate.sliderType)
                    else result.success(true)
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
    private fun handleHapticVibrate(
        call: MethodCall,
        result: MethodChannel.Result,
        typeOverride: String? = null,
    ) {
        // 交互震动优先：通知音乐震动让位（两者共用同一个 Vibrator，是单通道）
        MusicHapticsPlugin.noteInteraction()
        val type = typeOverride ?: call.argument<String>("type") ?: ""
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
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
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
                // 保留可移动存储提供方的读取授权，避免选择器返回后 USB 文档授权立即失效。
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: SecurityException) {
                    // 部分文档提供方只授予临时权限；当前线程仍会立即复制内容。
                }
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
                        val input = contentResolver.openInputStream(uri)
                            ?: throw IllegalStateException("无法读取所选图片：$uri")
                        input.use { source ->
                            targetFile.outputStream().use { output -> source.copyTo(output) }
                        }
                        if (!targetFile.exists() || targetFile.length() == 0L) {
                            throw IllegalStateException("所选图片为空或读取失败：$uri")
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // 引擎接管时先解绑旧 Activity，再绑定新 Activity。不能等旧 onDestroy
        // 才清理共享引用，否则会把新 Activity 刚注册的通道一并清空。
        // 米窗关闭可能结束 Activity，但后台音频仍持有当前引擎。
        // 保留缓存供重开接管；失效引擎由 provideFlutterEngine 的 JNI 校验排除。
        firstFrameListener?.let { flutterEngine.renderer.removeIsDisplayingFlutterUiListener(it) }
        firstFrameListener = null
        // 释放 Visualizer，保留引擎插件引用，供后续 Activity 继续使用和清理。
        try { spectrumPlugin?.cleanup() } catch (_: Throwable) {}
        cachedEngine = null
        cachedChannel = null
        recognitionChannel = null
        pipChannel = null
        pipVideoActive = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
