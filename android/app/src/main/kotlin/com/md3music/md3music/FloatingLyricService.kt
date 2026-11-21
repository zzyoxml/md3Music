package com.md3music.md3music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.app.NotificationCompat
import kotlin.math.roundToInt

/// 单个字的卡拉OK时间戳（text 为该字文本，供原生按 paint 测量字宽）
class WordTiming(val text: String, val startMs: Long, val durMs: Long)

// 卡拉OK链路诊断日志 TAG（暂停冻结问题排查用，同文件两个类共用）
private const val KARAOKE_LOG = "KaraokeDebug"

class FloatingLyricService : Service() {
    private var windowManager: WindowManager? = null
    private var rootView: LinearLayout? = null
    /** 面板上区：歌词预览，常驻可见。 */
    private var lyricArea: View? = null
    /** 面板下区的外层容器：展开/收起动画就作用在它的高度上（负责"露出多少"）。 */
    private var controlHolder: FrameLayout? = null
    /** 面板下区的真实内容：按钮行 + 进度条 + 设置面板。 */
    private var controlInner: View? = null
    private var lyricText1: GradientTextView? = null
    private var lyricText2: GradientTextView? = null
    private var params: WindowManager.LayoutParams? = null
    // SCREEN_OFF/ON 广播接收器（onCreate 注册，onDestroy 注销）
    private var screenReceiver: BroadcastReceiver? = null

    // touch/drag — vertical only
    private var initialY = 0
    private var initialTouchY = 0f
    private var isDragging = false
    private var dragStartTime = 0L
    private var expanded = false
    /// 下区高度动画。重复触发必须先 cancel —— 否则两个 animator 同时改同一份
    /// layoutParams.height，窗口高度会来回跳。
    private var heightAnimator: ValueAnimator? = null
    /// 本次按下的落点是否在上区（歌词预览）；只有落在上区的轻点才展开/收起。
    private var touchOnLyricArea = false
    private var locked = false

    // config
    private var fontSizeSp = 18f
    // 「显示大小」档位（Dart 侧 ThemeProvider.displayScale）。
    // 与 fontSizeSp 分开存：± 按钮与回传 Dart 的配置始终用未缩放的基准字号，
    // 只在 setTextSize 时乘上本系数，避免往返放大 / 撞上 12~32sp 的钳制区间。
    private var displayScale = 1f
    private var doubleLine = false
    private var opacity = 50
    private var gradientStart = 0xFF00E5FF.toInt()
    private var gradientEnd = 0xFFFF00FF.toInt()
    private var unplayedColor = 0xFFFFFFFF.toInt()
    private var isPlayingFlag = false
    // 当前悬浮窗宽度与歌词换行最大宽度（旋转时随 displayMetrics 重算）
    private var windowWidthPx = 0
    private var lyricMaxWidthPx = 0

    // views
    private var lockButton: ImageView? = null
    private var playPauseButton: ImageView? = null
    /** 设置按钮：面板收起时是「设置」图标，展开时换成「关闭」（X）。 */
    private var settingsButton: ImageView? = null
    private var progressBar: LyricProgressBar? = null
    private var settingsPanel: View? = null
    private var colorPanel: View? = null
    private var colorMode = 0

    // 设置面板重做（2026-10-10）后需要回填选中态与读数的控件引用。
    // 原生 View 没有数据绑定，只能显式持有引用在 applyConfig / 回调里刷新。
    private var colorModeSeg: SegmentControl? = null
    private var lineCountSeg: SegmentControl? = null
    /** 四个预设色块的外框 + 第 5 个「自定义」外框：选中时点亮描边环。 */
    private var presetFrames: List<View> = emptyList()
    /** 「自定义」色块的渐变本体：随自定义槽位实时重画。 */
    private var customSwatchView: View? = null
    // 自定义配色槽位。拖色相/未唱写这里，**不写** gradientStart 那份 ——
    // 预设是常量不能被拖坏，第 5 个「自定义」色块读的就是这份。
    private var customStart = 0xFF00E5FF.toInt()
    private var customEnd = 0xFFFF00FF.toInt()
    private var customUnplayed = 0xFFFFFFFF.toInt()

    // ===== 面板内容反色（背景不透明度 < 50 时整套面板切深色，见 applyPanelTheme）=====
    // 悬浮窗读不到下层像素（跨应用无免权限方案），无法按背景亮度自适应；
    // 但深色底一旦透明，下层十有八九是浅色壁纸/浅色应用，白字必然不可读 ——
    // 用户拍板：不透明度低于 50 就直接反色，这是能落地的最优规则。
    private var panelDarkContent = false
    private val themedValueViews = mutableListOf<TextView>()
    private val themedLabelViews = mutableListOf<TextView>()
    private val themedIconViews = mutableListOf<ImageView>()
    private val themedTextButtons = mutableListOf<TextView>()
    private val themedThumbs = mutableListOf<SeekBar>()
    private val themedSegments = mutableListOf<SegmentControl>()
    /**
     * 最近一次选中的预设下标（**记忆**，不是"当前亮哪个环"）。
     *
     * 环点亮哪一个由 [matchedPresetIndex] 按真实颜色值算出来；本字段只用于
     * 「切回预设配色时恢复哪一组」—— 进入自调颜色后**不清零**，
     * 否则用户切回来时没有任何依据可恢复。
     */
    private var lastPresetIndex = 0
    private var fontSizeValue: TextView? = null
    private var opacityValue: TextView? = null
    private var sungHueValue: TextView? = null
    private var unsungHueValue: TextView? = null

    companion object {
        private const val TAG = "FloatingLyricService"
        const val CHANNEL_ID = "floating_lyric_channel"
        // 注意：不能与媒体3 now-playing 通知（1001）撞号，否则桌面歌词一开
        // startForeground(1001, ...) 会直接覆盖媒体通知 → 媒体卡片消失。
        // AudioPlaybackService 保活通知用 1002，这里用 1003 保持唯一。
        const val NOTIFICATION_ID = 1003
        private const val PREFS_NAME = "floating_lyric"
        private const val KEY_Y_PX = "y_px"
        // 阶段8：桌面歌词运行标志。开启期间本服务常驻 FGS（1003 可见通知）撑住
        // 进程前台，AudioPlaybackService 据此让位（不再显示保活空通知 1002）。
        @Volatile
        var isRunning = false
        // 悬浮窗窗口是否已真正 addView 成功。与 isRunning 分开存：MainActivity
        // 据此区分"服务存活但窗口未添加"（权限竞态/显示层拒绝）与真正可显示，
        // 并回填 startFloatingLyric 的真实结果，杜绝开关状态与窗口不一致。
        @Volatile
        var viewAdded = false
        // 屏幕亮灭（熄屏时通知 Dart 侧 tick 休眠省电；点亮恢复）
        @Volatile
        var screenOn = true
        // 运行中的服务实例（同进程直达调用用；onCreate 置位、onDestroy 清空）
        @Volatile
        var instance: FloatingLyricService? = null
        const val ACTION_UPDATE_LYRIC = "com.md3music.md3music.UPDATE_LYRIC"
        const val ACTION_UPDATE_TITLE = "com.md3music.md3music.UPDATE_TITLE"
        const val ACTION_UPDATE_PROGRESS = "com.md3music.md3music.UPDATE_PROGRESS"
        const val ACTION_SET_CONFIG = "com.md3music.md3music.SET_CONFIG"
        const val ACTION_SET_PLAYING = "com.md3music.md3music.SET_PLAYING"
        const val ACTION_STOP = "com.md3music.md3music.STOP_LYRIC"
        const val ACTION_TOGGLE_LOCK = "com.md3music.md3music.TOGGLE_LOCK"
        const val EXTRA_LYRIC = "lyric"
        const val EXTRA_NEXT_LYRIC = "nextLyric"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PLACEHOLDER = "placeholder"
        const val EXTRA_WORDS = "words"
        const val EXTRA_LINE_POSITION = "linePosition"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_FONT_SIZE = "fontSize"
        const val EXTRA_DISPLAY_SCALE = "displayScale"
        const val EXTRA_DOUBLE_LINE = "doubleLine"
        const val EXTRA_OPACITY = "opacity"
        const val EXTRA_LOCKED = "locked"
        const val EXTRA_GRADIENT_START = "gradientStart"
        const val EXTRA_GRADIENT_END = "gradientEnd"
        const val EXTRA_UNPLAYED_COLOR = "unplayedColor"
        /** 配色模式：0 = 预设配色，1 = 自调颜色（与 Dart 侧 kColorMode* 一致）。 */
        const val EXTRA_COLOR_MODE = "colorMode"
        /** 最近选中的预设下标；切回预设配色时据此恢复。 */
        const val EXTRA_PRESET_INDEX = "activePreset"
        /** 自定义配色槽位：拖色相/未唱写这里，预设永远是常量。 */
        const val EXTRA_CUSTOM_GRAD_START = "customStart"
        const val EXTRA_CUSTOM_GRAD_END = "customEnd"
        const val EXTRA_CUSTOM_UNPLAYED = "customUnplayed"
        const val EXTRA_IS_PLAYING = "isPlaying"

        val PRESETS = listOf(
            0xFF00E5FF.toInt() to 0xFFFF00FF.toInt(),
            0xFFFF4081.toInt() to 0xFFFFC400.toInt(),
            0xFF00E676.toInt() to 0xFF00B0FF.toInt(),
            0xFFFFFFFF.toInt() to 0xFFFFFFFF.toInt()
        )

        /// 预设自带的未唱色。卡拉OK二分色里"未唱"就该是白的，否则和已唱分不开；
        /// 选任何预设都会把未唱色重置回这个值（用户要求：预设的未唱为白色）。
        const val PRESET_UNPLAYED = 0xFFFFFFFF.toInt()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // 更新歌词等通道可能在用户撤销悬浮窗权限后再次拉起本服务，不能只依赖
        // MainActivity 的首次开启检查。ColorOS 会对 2038 窗口直接抛 BadTokenException，
        // 若从 onCreate 逸出会杀死整个播放器进程，连带重建并清空 MediaSession actions。
        if (!hasOverlayPermission()) {
            Log.w(TAG, "Overlay permission missing; floating lyric service stopped")
            MainActivity.completeFloatingStart(false)
            stopSelf()
            return
        }
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        if (!createFloatingView()) {
            Log.w(TAG, "Floating view not created; service stopped")
            MainActivity.completeFloatingStart(false)
            stopSelf()
            return
        }
        viewAdded = true
        // 通知 MainActivity 回填 startFloatingLyric 的真实结果（悬浮窗已成功 addView）
        MainActivity.completeFloatingStart(true)
        // 熄屏感知：动态注册 SCREEN_OFF/ON（照搬锁屏歌词接收器模式），
        // 转发到 Dart 做 tick 门控（熄屏且未开锁屏歌词时休眠省电）
        try {
            screenReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    screenOn = intent?.action != Intent.ACTION_SCREEN_OFF
                    val engine = io.flutter.embedding.engine.FlutterEngineCache.getInstance()
                        .get("md3music_engine") ?: return
                    io.flutter.plugin.common.MethodChannel(
                        engine.dartExecutor.binaryMessenger,
                        "com.md3music.md3music/floating_lyric"
                    ).invokeMethod("screenStateChanged", mapOf("on" to screenOn))
                }
            }
            val screenFilter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }
            registerReceiver(screenReceiver, screenFilter)
        } catch (_: Exception) {}
        isRunning = true
        instance = this
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // 悬浮窗未创建（服务刚起/已销毁）时无需处理；post 到下一帧按最终
        // displayMetrics 重排，规避个别 ROM 回调时尺寸尚未刷新的时序问题。
        rootView?.post { relayoutForOrientation() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!hasOverlayPermission()) {
            Log.w(TAG, "Overlay permission revoked; ignoring floating lyric update")
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_UPDATE_LYRIC -> {
                handleUpdateLyric(
                    intent.getStringExtra(EXTRA_LYRIC) ?: "",
                    intent.getStringExtra(EXTRA_NEXT_LYRIC),
                    intent.getStringExtra(EXTRA_PLACEHOLDER) ?: "",
                    intent.getStringExtra(EXTRA_WORDS) ?: "[]",
                    intent.getLongExtra(EXTRA_LINE_POSITION, 0L)
                )
            }
            ACTION_UPDATE_TITLE -> {}
            ACTION_UPDATE_PROGRESS -> {
                handleUpdateProgress(
                    intent.getLongExtra(EXTRA_POSITION, 0L),
                    intent.getLongExtra(EXTRA_DURATION, 0L)
                )
            }
            ACTION_SET_CONFIG -> {
                handleSetConfig(
                    intent.getFloatExtra(EXTRA_FONT_SIZE, fontSizeSp),
                    intent.getFloatExtra(EXTRA_DISPLAY_SCALE, displayScale),
                    intent.getBooleanExtra(EXTRA_DOUBLE_LINE, doubleLine),
                    intent.getIntExtra(EXTRA_OPACITY, opacity),
                    intent.getBooleanExtra(EXTRA_LOCKED, locked),
                    intent.getIntExtra(EXTRA_GRADIENT_START, gradientStart),
                    intent.getIntExtra(EXTRA_GRADIENT_END, gradientEnd),
                    intent.getIntExtra(EXTRA_UNPLAYED_COLOR, unplayedColor),
                    intent.getIntExtra(EXTRA_COLOR_MODE, colorMode),
                    intent.getIntExtra(EXTRA_PRESET_INDEX, lastPresetIndex),
                    intent.getIntExtra(EXTRA_CUSTOM_GRAD_START, customStart),
                    intent.getIntExtra(EXTRA_CUSTOM_GRAD_END, customEnd),
                    intent.getIntExtra(EXTRA_CUSTOM_UNPLAYED, customUnplayed)
                )
            }
            ACTION_SET_PLAYING -> {
                handleSetPlaying(intent.getBooleanExtra(EXTRA_IS_PLAYING, isPlayingFlag))
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TOGGLE_LOCK -> {
                setLocked(!locked)
            }
        }
        return START_STICKY
    }

    /// 同进程直达调用入口（MainActivity handler 直接调用，省去 Intent 中转）。
    /// 与 onStartCommand 分支共用同一实现，保证两条路径行为一致。
    fun handleUpdateLyric(lyric: String, nextLyric: String?, placeholder: String,
                          wordsJson: String, basePosMs: Long) {
        updateLyric(lyric, nextLyric, placeholder, parseWords(wordsJson), basePosMs)
    }

    fun handleUpdateProgress(pos: Long, dur: Long) {
        progressBar?.updateProgress(pos, dur)
        lyricText1?.onKaraokePositionSync(pos, isPlayingFlag)
    }

    fun handleSetPlaying(playing: Boolean) {
        isPlayingFlag = playing
        Log.d(TAG, "SET_PLAYING -> $isPlayingFlag")
        playPauseButton?.setImageResource(
            if (isPlayingFlag) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play
        )
        lyricText1?.onKaraokePlayingChanged(isPlayingFlag)
    }

    /// 可空参数 = 字段不变（保持与 intent extra 缺省语义一致）
    fun handleSetConfig(fontSize: Float?, displayScale: Float?, doubleLine: Boolean?,
                        opacity: Int?, locked: Boolean?,
                        gradientStart: Int?, gradientEnd: Int?, unplayedColor: Int?,
                        colorMode: Int?, activePreset: Int?,
                        customStart: Int?, customEnd: Int?, customUnplayed: Int?) {
        fontSize?.let { fontSizeSp = it }
        displayScale?.let { this.displayScale = it }
        doubleLine?.let { this.doubleLine = it }
        opacity?.let { this.opacity = it }
        locked?.let {
            if (it != this.locked) {
                this.locked = it
                applyLockState()
            }
        }
        gradientStart?.let { this.gradientStart = it }
        gradientEnd?.let { this.gradientEnd = it }
        unplayedColor?.let { this.unplayedColor = it }
        colorMode?.let { this.colorMode = if (it == 1) 1 else 0 }
        activePreset?.let { this.lastPresetIndex = it.coerceIn(0, PRESETS.size - 1) }
        customStart?.let { this.customStart = it }
        customEnd?.let { this.customEnd = it }
        customUnplayed?.let { this.customUnplayed = it }
        applyConfig()
    }

    private fun hasOverlayPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun setLocked(value: Boolean) {
        if (locked == value) return
        locked = value
        lockButton?.setImageResource(
            if (locked) android.R.drawable.ic_lock_lock
            else android.R.drawable.ic_lock_idle_lock
        )
        applyLockState()
        sendConfigUpdate()
        updateNotification()
    }

    /// Apply lock state: toggle click-through
    private fun applyLockState() {
        val wm = windowManager ?: return
        val p = params ?: return
        val root = rootView ?: return

        if (locked) {
            // Collapse expanded panel when locking
            setExpanded(false, animate = false)

            // Add FLAG_NOT_TOUCHABLE for click-through
            p.flags = p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            try {
                wm.updateViewLayout(root, p)
            } catch (_: Exception) {}
        } else {
            // Remove FLAG_NOT_TOUCHABLE
            p.flags = p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            try {
                wm.updateViewLayout(root, p)
            } catch (_: Exception) {}
        }
    }

    // 实际下发给 TextView 的字号：基准字号 × 「显示大小」档位。
    private fun scaledFontSizeSp(): Float = fontSizeSp * displayScale

    private fun applyConfig() {
        lyricText1?.setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledFontSizeSp())
        lyricText2?.setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledFontSizeSp())
        lyricText2?.visibility = if (doubleLine) View.VISIBLE else View.GONE

        lyricText1?.setGradient(gradientStart, gradientEnd)
        lyricText2?.setGradient(gradientStart, gradientEnd)
        // 同步未唱色给文本视图（KRC 逐字二分色模式下未唱部分用此色）
        lyricText1?.setUnplayedColor(unplayedColor)
        lyricText2?.setUnplayedColor(unplayedColor)

        // Background opacity
        val bgAlpha = (opacity * 255 / 100).coerceIn(0, 255)
        val bgColor = (bgAlpha shl 24) or 0x000000
        (rootView?.background as? GradientDrawable)?.apply {
            setColor(bgColor)
        }
        // GradientDrawable.setColor 只改 Drawable 自身状态，**不会让宿主重绘**；
        // 而末尾的 updateLyric 在歌词文本未变时是幂等的（不 setText、不 invalidate）。
        // 两条路都不重绘 ⇒ 从设置页改不透明度时悬浮窗"没反应"。必须补这一刀。
        rootView?.invalidate()

        // 背景不透明度跨越 50% 阈值时整套面板内容反色（白 ↔ 深色）
        applyPanelTheme()

        progressBar?.setGradient(gradientStart, gradientEnd, unplayedColor)
        // 面板读数与选中态跟着配置走：Dart 侧下发新配置时，悬浮窗内的面板
        // 也不会停留在旧值上（两端共用同一份状态是本项目的既有约定）。
        refreshPanelReadouts()
        updateLyric(lyricText1?.text?.toString() ?: "", lyricText2?.text?.toString())
    }

    /// 解析 Dart 下发的逐字时间戳 JSON（[{"t":"字","s":起始ms,"d":时长ms}]）。
    /// t 文本保留给 WordTiming（原生按 paint 测量字宽），解析失败回退为无逐字。
    private fun parseWords(json: String): List<WordTiming> {
        if (json.isEmpty() || json == "[]") return emptyList()
        return try {
            val arr = org.json.JSONArray(json)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                WordTiming(o.getString("t"), o.getLong("s"), o.getLong("d"))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /// 更新悬浮窗歌词文本。
    ///
    /// - [placeholder] 非空：显示占位文案（加载中/暂无歌词/加载失败，由 Dart 显式下发）
    /// - [placeholder] 为空且 [lyric] 为空串：间奏期显示空白，不再误显"歌词加载中..."
    private fun updateLyric(
        lyric: String,
        nextLyric: String?,
        placeholder: String = "",
        words: List<WordTiming> = emptyList(),
        basePosMs: Long = 0L,
    ) {
        val safeLyric = placeholder.ifEmpty { lyric }
        val t1 = lyricText1 ?: return
        // 幂等：文本未变不重设，避免 setText 触发无效 invalidate/requestLayout
        // （applyConfig 与 Dart 侧重复推送都会走到这里）
        if (t1.text?.toString() != safeLyric) {
            t1.text = safeLyric
        }
        if (words.isNotEmpty()) {
            t1.setKaraokeLine(words, basePosMs, isPlayingFlag)
        } else {
            t1.clearKaraoke()
        }
        if (doubleLine) {
            lyricText2?.text = nextLyric ?: ""
            lyricText2?.visibility = if (nextLyric.isNullOrEmpty()) View.INVISIBLE else View.VISIBLE
        } else {
            lyricText2?.visibility = View.GONE
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "桌面歌词悬浮窗"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val stopIntent = Intent(this, FloatingLyricService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val lockIntent = Intent(this, FloatingLyricService::class.java).apply {
            action = ACTION_TOGGLE_LOCK
        }
        val lockPendingIntent = PendingIntent.getService(
            this, 1, lockIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val lockIcon = if (locked) android.R.drawable.ic_lock_lock
                       else android.R.drawable.ic_lock_idle_lock
        val lockText = if (locked) "解锁歌词" else "锁定歌词"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MD3Music 桌面歌词")
            .setContentText(if (locked) "已锁定 · 点击穿透" else "已开启 · 可拖动")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .addAction(lockIcon, lockText, lockPendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "关闭", stopPendingIntent)
            .build()
    }

    /// Update notification when lock state changes
    private fun updateNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(NOTIFICATION_ID, createNotification())
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()

    private fun sp(v: Float): Float =
        v * resources.displayMetrics.scaledDensity

    private fun createFloatingView(): Boolean {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        // ===== 唯一容器 =====
        // 背景 / 圆角 / 描边 / 内边距只在这一层定义，上下两区都是它的直接子视图。
        // 之前是「rootView 半透明底」+「展开区再叠一层实心黑底」两层叠加，真机上
        // 被看成上下割裂的两块（一块透、一块黑），故合并成单层（2026-10-10）。
        // 不透明度仍然只作用于这唯一一层底色 —— 那本来就是这项设置的语义。
        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0xCC000000.toInt())
                // 不描边：那圈 1dp 白色轮廓线在浅色壁纸上很扎眼（用户要求去掉）
            }
            setPadding(dp(20), dp(12), dp(20), dp(12))
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val root = rootView as LinearLayout

        // ===== 上区：歌词预览，常驻可见 =====
        // 注意：这里**不能** setOnClickListener —— 一旦可点击，View.onTouchEvent
        // 就会消费掉整条事件序列，歌词区上按住拖动悬浮窗就失效了（拖动监听挂在 root
        // 上，靠子视图不消费才收得到）。展开/收起改由 root 的触摸监听按下点落在
        // 哪个区来决定，见 setupTouchListener。
        lyricArea = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val col = lyricArea as LinearLayout

        // 窗口宽度固定：随文字变化宽度会触发 WindowManager 重定位
        // （先瞬移后动画回中）。固定后 gravity 居中恒成立，永不跳动。
        // 只留 16dp 边距：5 个色块（预设×4 + 自定义）+ 分段控件要在内容区排下，
        // 32dp 时第 5 个色块被裁掉（2026-10-10 用户反馈）。
        windowWidthPx = resources.displayMetrics.widthPixels - dp(16)
        val fixedWindowWidth = windowWidthPx

        // 歌词文本最大宽度：窗口宽减去根 padding(20×2)，LinearLayout 约束实际生效，
        // maxWidth 保留为兜底，防止超长歌词撑破窗口
        lyricMaxWidthPx = fixedWindowWidth - dp(40)
        val lyricMaxWidth = lyricMaxWidthPx

        lyricText1 = GradientTextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledFontSizeSp())
            gravity = Gravity.CENTER
            maxLines = 2
            maxWidth = lyricMaxWidth
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(6), dp(8), dp(4))
        }
        lyricText2 = GradientTextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledFontSizeSp())
            gravity = Gravity.CENTER
            maxLines = 2
            maxWidth = lyricMaxWidth
            setPadding(dp(8), dp(2), dp(8), dp(6))
            visibility = View.GONE
        }
        col.addView(lyricText1)
        col.addView(lyricText2)
        root.addView(col)

        // ===== 下区：操作面板 =====
        // 两层结构：外层 controlHolder 承担"露出多少"（高度动画的作用点），
        // 内层 controlInner 是真实内容。收缩时内层保持自然高度、被外层裁掉，
        // 于是观感是"从上往下展开"；把动画直接作用在内层会让它被压扁，
        // 按钮行和滑块会在动画中途变形抖动。
        val holder = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0
            )
            setClipChildren(true)
            visibility = View.GONE
        }
        controlHolder = holder
        controlInner = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val exp = controlInner as LinearLayout

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(8))
        }
        val iconSize = dp(20)
        val iconPad = dp(10)
        lockButton = makeIconButton(android.R.drawable.ic_lock_idle_lock) { setLocked(!locked) }
        val prevButton = makeIconButton(android.R.drawable.ic_media_previous) { sendAction("previous") }
        playPauseButton = makeIconButton(android.R.drawable.ic_media_play) { sendAction("play") }
        val nextButton = makeIconButton(android.R.drawable.ic_media_next) { sendAction("next") }
        val settingsBtn = makeIconButton(android.R.drawable.ic_menu_preferences) { toggleSettingsPanel() }
        // 存引用：设置面板开合时这颗按钮要在「设置」与「关闭」之间换图标，
        // 见 applySettingsButtonIcon()。
        settingsButton = settingsBtn

        listOf(lockButton, prevButton, playPauseButton, nextButton, settingsBtn).forEach {
            val lp = LinearLayout.LayoutParams(iconSize + iconPad * 2, iconSize + iconPad * 2)
            lp.setMargins(dp(6), 0, dp(6), 0)
            buttonRow.addView(it, lp)
        }
        exp.addView(buttonRow)

        progressBar = LyricProgressBar(this).apply {
            setGradient(gradientStart, gradientEnd, unplayedColor)
        }
        val pbLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(4))
        pbLp.setMargins(dp(12), 0, dp(12), dp(8))
        progressBar?.layoutParams = pbLp
        exp.addView(progressBar)

        settingsPanel = createSettingsPanel()
        exp.addView(settingsPanel)

        holder.addView(
            exp,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(holder)

        setupTouchListener(root)

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            fixedWindowWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            // Centered horizontally, vertical position adjustable
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0  // Always centered: X locked to 0
            // 恢复上次拖动位置；clamp 防止换机/旋转后屏幕变矮导致位置落在屏幕外
            y = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .getInt(KEY_Y_PX, dp(80))
                .coerceIn(0, resources.displayMetrics.heightPixels - dp(120))
        }

        return try {
            windowManager?.addView(rootView, params)
            true
        } catch (e: WindowManager.BadTokenException) {
            // 权限可能在 canDrawOverlays() 与 addView() 之间被撤销；把竞态收口在服务内，
            // 不能让桌面歌词的可选功能拖垮播放器与 MediaSession。
            Log.w(TAG, "Unable to add overlay window: ${e.message}")
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "Overlay window rejected: ${e.message}")
            false
        }
    }

    /// 按当前显示尺寸重算悬浮窗宽度与纵向位置。
    /// 修复横屏开启（缓存了宽屏尺寸）后转竖屏时，窗口宽 > 屏宽导致
    /// CENTER_HORIZONTAL 无法居中的错位；两个方向旋转都走这里，行为一致。
    private fun relayoutForOrientation() {
        val root = rootView ?: return
        val p = params ?: return
        val wm = windowManager ?: return

        // 与 createFloatingView 的初始宽度保持同一条规则（screen - 16dp）
        val newWidth = resources.displayMetrics.widthPixels - dp(16)
        val newMaxWidth = newWidth - dp(40)
        windowWidthPx = newWidth
        lyricMaxWidthPx = newMaxWidth

        p.width = newWidth
        // 旋转后屏幕高度变化，重新 clamp 纵向位置，防止落在屏幕外
        p.y = p.y.coerceIn(0, resources.displayMetrics.heightPixels - dp(120))

        // 换行宽度跟随新窗口宽：更新 maxWidth 后 requestLayout 触发重测量，
        // 渐变 shader 会在下次 onDraw 按新 width 自动重建（见 ensureGradientShader）
        lyricText1?.maxWidth = newMaxWidth
        lyricText2?.maxWidth = newMaxWidth
        lyricText1?.requestLayout()
        lyricText2?.requestLayout()
        root.requestLayout()

        try {
            wm.updateViewLayout(root, p)
        } catch (_: Exception) {}
    }

    private fun toggleExpanded() {
        if (isDragging) return
        if (locked) return  // Can't expand when locked
        setExpanded(!expanded, animate = true)
    }

    /// 展开 / 收起下区。
    ///
    /// 动画只改 [controlHolder] 的高度，窗口本身是 `gravity=TOP + WRAP_CONTENT`，
    /// 高度变化时顶边不动、底边延伸 —— 面板整体位置稳定，不会上下跳。
    private fun setExpanded(expand: Boolean, animate: Boolean) {
        expanded = expand
        val holder = controlHolder ?: return
        val natural = measureControlHeight()
        val from = if (holder.visibility == View.GONE) 0 else currentControlHeight()
        val to = if (expand) natural else 0

        cancelHeightAnimation()
        if (!animate || natural <= 0 || from == to) {
            applyControlHeight(to)
            holder.visibility = if (expand) View.VISIBLE else View.GONE
            holder.alpha = 1f
            releaseControlHeight(holder, to == 0)
            return
        }

        runControlHeightAnimation(from, to, natural) {
            if (to == 0) holder.visibility = View.GONE
            holder.alpha = 1f
            releaseControlHeight(holder, to == 0)
        }
    }

    private fun toggleSettingsPanel() {
        val panel = settingsPanel ?: return
        panel.visibility = if (panel.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        applySettingsButtonIcon()
        // 设置面板开合会改变下区高度，同样走高度动画，避免窗口高度瞬跳
        syncControlHeight()
    }

    /// 底部那颗「设置」按钮的图标跟着设置面板的开合走：收起 → 设置（扳手），
    /// 展开 → X。
    ///
    /// 同一个按钮既是入口也是出口 —— 面板展开后满屏都是滑块，用户第一反应是
    /// 回到刚才那个按钮上把它关掉；图标不变的话没人知道它现在就是"关闭"。
    private fun applySettingsButtonIcon() {
        val opened = settingsPanel?.visibility == View.VISIBLE
        settingsButton?.setImageResource(
            if (opened) android.R.drawable.ic_menu_close_clear_cancel
            else android.R.drawable.ic_menu_preferences
        )
    }

    /// 下区内容高度变了（开合设置面板 / 自调颜色区、配色模式切换）之后，
    /// 把 [controlHolder] 的高度重新对齐到内容自然高度，走同一套动画。
    ///
    /// 收起态（[expanded] == false）直接返回：此时 holder 本就该是 GONE/0，
    /// 而 [measureControlHeight] 量的是内容自然高度，套上去会把收起态撑开。
    private fun syncControlHeight(animate: Boolean = true) {
        if (!expanded) return
        val target = measureControlHeight()
        val current = currentControlHeight()
        if (current == target) return
        if (!animate) {
            applyControlHeight(target)
            controlHolder?.let { releaseControlHeight(it, false) }
            return
        }
        runControlHeightAnimation(current, target, target) {
            controlHolder?.let { releaseControlHeight(it, false) }
        }
    }

    /// 下区当前的实际高度。
    ///
    /// 展开稳定态下 `layoutParams.height` 是 `WRAP_CONTENT(-2)`，直接拿它当动画
    /// 起点会得到 -2 —— 必须退回实测高度。
    private fun currentControlHeight(): Int {
        val holder = controlHolder ?: return 0
        val lp = holder.layoutParams ?: return 0
        return if (lp.height >= 0) lp.height else holder.measuredHeight
    }

    /// 把 [controlHolder] 的高度设为 [h] 并请求重排。
    private fun applyControlHeight(h: Int) {
        val holder = controlHolder ?: return
        val lp = holder.layoutParams
            ?: LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, h
            ).also { holder.layoutParams = it }
        lp.height = h
        holder.requestLayout()
    }

    /// 动画期间 [controlInner] 被钉成固定高度（外层裁切而非压缩），
    /// 结束后交还给 WRAP_CONTENT —— 否则之后开合设置面板就长不高了。
    private fun releaseControlHeight(holder: FrameLayout, collapsed: Boolean) {
        controlInner?.layoutParams?.height = ViewGroup.LayoutParams.WRAP_CONTENT
        holder.layoutParams?.height =
            if (collapsed) 0 else ViewGroup.LayoutParams.WRAP_CONTENT
        holder.requestLayout()
    }

    /// 中断在跑的高度动画。
    ///
    /// `cancel()` 会补触发一次 `onAnimationEnd`，如果回调还挂着，旧动画的收尾逻辑
    /// （设 GONE / 交还 WRAP_CONTENT）会抢在新动画前面执行 —— 必须先摘回调再 cancel。
    private fun cancelHeightAnimation() {
        heightAnimator?.apply {
            removeAllListeners()
            removeAllUpdateListeners()
            cancel()
        }
        heightAnimator = null
    }

    private fun runControlHeightAnimation(from: Int, to: Int, natural: Int, onEnd: () -> Unit) {
        val holder = controlHolder ?: return
        val inner = controlInner ?: return
        cancelHeightAnimation()

        holder.visibility = View.VISIBLE
        // 钉住内层高度：这样外层收缩时只是裁掉它，不会把内容压扁
        inner.layoutParams?.height = natural
        inner.requestLayout()

        val expanding = to > from
        heightAnimator = ValueAnimator.ofInt(from, to).apply {
            duration = 220
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                applyControlHeight(it.animatedValue as Int)
                holder.alpha = if (expanding) it.animatedFraction else 1f
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    applyControlHeight(to)
                    onEnd()
                }
            })
            start()
        }
    }

    /// 量出下区在**当前内容**下的自然高度（设置面板开合会改变它）。
    private fun measureControlHeight(): Int {
        val inner = controlInner ?: return 0
        val widthSpec = View.MeasureSpec.makeMeasureSpec(
            (windowWidthPx - dp(40)).coerceAtLeast(0), View.MeasureSpec.EXACTLY
        )
        inner.measure(widthSpec, View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        return inner.measuredHeight
    }

    private fun createSettingsPanel(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            visibility = View.GONE
        }

        // ---- 配色模式：分段控件（原来是两个外观完全一致的胶囊按钮，
        //      没有任何选中态，用户在真机上根本看不出当前处于哪个模式）----
        val modeSeg = SegmentControl(listOf("预设配色", "自调颜色")) { index ->
            switchColorMode(index)
        }
        colorModeSeg = modeSeg
        root.addView(modeSeg)

        // ---- 预设色板 ----
        val presetRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(6))
        }
        // 四个预设是**常量**，色块永远画 PRESETS 里的颜色 —— 拖色相写的是
        // 自定义槽位，绝不会污染这里（用户要求：预设色不能改）。
        val presetList = PRESETS.mapIndexed { index, pair ->
            val start = pair.first
            val end = pair.second
            // 外层 FrameLayout 只负责"选中环"，内层才是渐变块本身。
            // 原实现在同一个 GradientDrawable 上先 setColor(start) 又换 background，
            // 结果真机上四个色块全是单色，双色渐变压根没渲染出来。
            val frame = FrameLayout(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(46), dp(46)).apply {
                    setMargins(dp(4), 0, dp(4), 0)
                }
                setOnClickListener { selectPreset(index) }
            }
            val swatch = View(this).apply {
                background = GradientDrawable(
                    GradientDrawable.Orientation.LEFT_RIGHT,
                    intArrayOf(start, end)
                ).apply { cornerRadius = dp(9).toFloat() }
            }
            frame.addView(
                swatch,
                FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER)
            )
            presetRow.addView(frame)
            frame
        }

        // ---- 第 5 个：自定义 ----
        // 画的是**自定义槽位**当前的颜色，随自调结果实时重画（refreshCustomSwatch）；
        // 点击 = 应用自定义槽位并切到「自调颜色」。
        val customFrame = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(46), dp(46)).apply {
                setMargins(dp(4), 0, dp(4), 0)
            }
            setOnClickListener { applyCustomColors() }
        }
        customSwatchView = View(this).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(customStart, customEnd)
            ).apply { cornerRadius = dp(9).toFloat() }
        }
        customFrame.addView(
            customSwatchView,
            FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER)
        )
        presetRow.addView(customFrame)

        // 选中环的下标空间 = 4 个预设 + 1 个自定义（index == PRESETS.size）
        presetFrames = presetList + customFrame
        root.addView(presetRow)
        refreshPresetSelection()

        colorPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            visibility = View.GONE
        }
        val cp = colorPanel as LinearLayout

        // 自调颜色：拖动「已唱」会把渐变两端并成同一个色（渐变异构为单色），
        // 这是既有行为，面板不做改变，但读数会如实反映当前色相。
        val sungPair = makeColorSeekRow("已唱", gradientStart, onColor = { color ->
            // 拖动中仅预览（赋值+重绘），松手才 sendConfigUpdate 持久化。
            // 写的是**自定义槽位** + 当前生效渐变；预设是常量，永远不会被这里改到。
            gradientStart = color
            gradientEnd = color
            customStart = color
            customEnd = color
            colorMode = 1
            applyConfig()
        }, onCommitted = {
            sendConfigUpdate()
        })
        val unsungPair = makeColorSeekRow("未唱", unplayedColor, onColor = { color ->
            // 未唱色也是自调的一部分：预设模式下的未唱固定为白，
            // 拖这个滑块就等于进入「自调颜色」。
            unplayedColor = color
            customUnplayed = color
            colorMode = 1
            applyConfig()
        }, onCommitted = {
            sendConfigUpdate()
        })
        sungHueValue = sungPair.second
        unsungHueValue = unsungPair.second
        cp.addView(sungPair.first)
        cp.addView(unsungPair.first)
        root.addView(cp)

        // ---- 不透明度 ----
        // 轨道从"全透"渐变到"近全黑"，滑块停在哪、悬浮窗背景就是哪个值。
        // 原来是一条灰色矩形，看不出和透明度有什么关系。
        val opacityPair = makeValueSeekRow(
            label = "不透明度",
            max = 100,
            initial = opacity,
            trackColors = intArrayOf(0x00000000, 0xEB000000.toInt()),
            format = { "$it%" },
            onValue = { value ->
                // 拖动中仅实时预览：持久化在松手时一次性完成
                // （每次移动都 sendConfigUpdate 会触发通道往返 + 写盘风暴）
                opacity = value
                applyConfig()
            },
            onCommitted = { sendConfigUpdate() }
        )
        opacityValue = opacityPair.second
        root.addView(opacityPair.first)

        // ---- 字号：A− / 当前值 / A+ ----
        // 中间常驻读数。原来只有两个按钮，拖到一半完全不知道当前是几号字。
        val fontRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(4))
        }
        fontRow.addView(makeTextButton("A−") {
            fontSizeSp = (fontSizeSp - 2f).coerceAtLeast(12f)
            sendConfigUpdate()
            applyConfig()
        })
        fontSizeValue = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
            themedValueViews.add(this)
        }
        fontRow.addView(
            fontSizeValue,
            LinearLayout.LayoutParams(dp(64), ViewGroup.LayoutParams.WRAP_CONTENT)
        )
        fontRow.addView(makeTextButton("A+") {
            fontSizeSp = (fontSizeSp + 2f).coerceAtMost(32f)
            sendConfigUpdate()
            applyConfig()
        })
        root.addView(fontRow)

        // ---- 行式：分段控件 ----
        // 原来是一个按钮，文案写的是"点一下会变成什么"（当前单行时它写着「双行」），
        // 极易读反；换成显示"当前是什么"的分段控件。
        val lineSeg = SegmentControl(listOf("单行", "双行")) { index ->
            doubleLine = index == 1
            sendConfigUpdate()
            applyConfig()
        }
        lineSeg.select(if (doubleLine) 1 else 0, notify = false)
        lineCountSeg = lineSeg
        root.addView(
            lineSeg,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, dp(4), 0, 0) }
        )

        return root
    }

    /// 切换配色模式。
    ///
    /// 「预设配色」→ 恢复 [lastPresetIndex] 那一组（未唱 = 白）；
    /// 「自调颜色」→ 恢复自定义槽位。两个方向都可逆，且不会出现
    /// "模式显示 A、颜色却是 B"的错位。
    private fun switchColorMode(mode: Int) {
        colorMode = if (mode == 1) 1 else 0
        if (colorMode == 0) {
            val pair = PRESETS[lastPresetIndex.coerceIn(0, PRESETS.size - 1)]
            gradientStart = pair.first
            gradientEnd = pair.second
            unplayedColor = PRESET_UNPLAYED
        } else {
            gradientStart = customStart
            gradientEnd = customEnd
            unplayedColor = customUnplayed
        }
        applyColorModeUi()
        syncControlHeight()
        applyConfig()
        sendConfigUpdate()
    }

    /// 选中一组预设：未唱色一并重置为白，同时把配色模式切回「预设配色」。
    ///
    /// 预设是**常量** —— 这里只读 [PRESETS]，拖色相产生的一切都进自定义槽位。
    /// 「未唱为白」也是预设的一部分，不重置的话卡拉OK已唱/未唱分不开。
    private fun selectPreset(index: Int) {
        val pair = PRESETS.getOrNull(index) ?: return
        lastPresetIndex = index
        colorMode = 0
        gradientStart = pair.first
        gradientEnd = pair.second
        unplayedColor = PRESET_UNPLAYED
        applyColorModeUi()
        // 点预设会把「自调颜色」区收起来（那属于自调模式），下区高度随之缩短
        syncControlHeight()
        applyConfig()
        sendConfigUpdate()
    }

    /// 应用自定义槽位（第 5 个「自定义」色块 / 切到「自调颜色」）。
    private fun applyCustomColors() {
        colorMode = 1
        gradientStart = customStart
        gradientEnd = customEnd
        unplayedColor = customUnplayed
        applyColorModeUi()
        // 从预设模式切过来会把「自调颜色」区展开，下区高度随之变长
        syncControlHeight()
        applyConfig()
        sendConfigUpdate()
    }

    /// 把 [colorMode] 落到分段控件与「自调颜色」区的可见性上。
    /// 这是一个纯 UI 回填动作，任何改动模式的路径都必须过它，避免两处各写一份。
    private fun applyColorModeUi() {
        colorModeSeg?.select(colorMode, notify = false)
        colorPanel?.visibility = if (colorMode == 1) View.VISIBLE else View.GONE
    }

    /// 回填"当前命中哪个预设"的选中环。
    ///
    /// 选中态跟**配色模式**走（模式才是唯一真相）：
    ///   - 预设配色 → 按真实颜色值匹配四个预设（理论上恒命中 lastPresetIndex）；
    ///   - 自调颜色 → 只亮第 5 个「自定义」，且要求当前渐变确实等于自定义槽位。
    /// 这样 Dart 侧改颜色下发过来时环会自动跟着动，两端不会各亮各的。
    private fun refreshPresetSelection() {
        presetFrames.forEachIndexed { index, frame ->
            val selected = if (colorMode == 0) {
                index < PRESETS.size && index == matchedPresetIndex()
            } else {
                index == PRESETS.size &&
                    gradientStart == customStart && gradientEnd == customEnd
            }
            frame.background = GradientDrawable().apply {
                cornerRadius = dp(13).toFloat()
                setColor(Color.TRANSPARENT)
                if (selected) {
                    // 选中环跟面板主题走：反色态用深色，浅色壁纸上才可见
                    setStroke(dp(2), panelMainColor())
                }
            }
        }
    }

    /// 重画「自定义」色块：画的是自定义槽位当前的颜色，随自调结果实时变。
    private fun refreshCustomSwatch() {
        customSwatchView?.background = GradientDrawable(
            GradientDrawable.Orientation.LEFT_RIGHT,
            intArrayOf(customStart, customEnd)
        ).apply { cornerRadius = dp(9).toFloat() }
    }

    /// 当前渐变**实际等于**哪一组预设；都不等（自定义配色）时返回 -1。
    private fun matchedPresetIndex(): Int =
        PRESETS.indexOfFirst {
            it.first == gradientStart && it.second == gradientEnd
        }

    /// 面板内容主色（文字 / 图标 / 滑块 / 选中环）：反色态深灰，常态白。
    private fun panelMainColor(): Int =
        if (panelDarkContent) 0xFF1B1B1B.toInt() else 0xFFFFFFFF.toInt()

    /// 面板标签次要色：反色态深灰，常态浅灰。
    private fun panelLabelColor(): Int =
        if (panelDarkContent) 0xFF666666.toInt() else 0xFFCCCCCC.toInt()

    /// 面板内容反色：背景不透明度 < 50 时，深色底几乎全透，白字落在浅色
    /// 壁纸上完全不可读 —— 此时整套面板内容（文字 / 图标 / 滑块 / 分段控件 /
    /// 选中环 / 根容器描边）切深色。只在**跨越 50% 阈值**时重刷一次，
    /// 拖动不透明度滑块不会反复重设 thumb（thumb 重设会让拖动中的 SeekBar 跳）。
    private fun applyPanelTheme() {
        val dark = opacity < 50
        if (dark == panelDarkContent) return
        panelDarkContent = dark
        val main = panelMainColor()
        val label = panelLabelColor()
        themedValueViews.forEach { it.setTextColor(main) }
        themedLabelViews.forEach { it.setTextColor(label) }
        themedIconViews.forEach { it.setColorFilter(main) }
        themedTextButtons.forEach { btn ->
            btn.setTextColor(main)
            btn.background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(if (dark) 0x33000000 else 0x33FFFFFF)
                setStroke(
                    1,
                    android.content.res.ColorStateList.valueOf(
                        if (dark) 0x55000000 else 0x55FFFFFF
                    )
                )
            }
        }
        themedThumbs.forEach { it.thumb = sliderThumb(main) }
        themedSegments.forEach { it.applyTheme(dark) }
        refreshPresetSelection()
    }

    /// 刷新面板上所有读数（字号 / 不透明度 / 色相 / 行式）。
    ///
    /// 由 [applyConfig] 统一调用 —— 这样 Dart 侧改配置下发过来时，
    /// 悬浮窗内的面板读数也会跟着变，不会出现"两边显示不一致"。
    private fun refreshPanelReadouts() {
        fontSizeValue?.text = "${fontSizeSp.roundToInt()} sp"
        opacityValue?.text = "$opacity%"
        val sungHsv = FloatArray(3)
        Color.colorToHSV(gradientStart, sungHsv)
        val unsungHsv = FloatArray(3)
        Color.colorToHSV(unplayedColor, unsungHsv)
        sungHueValue?.text = "${sungHsv[0].roundToInt().coerceIn(0, 360)}°"
        unsungHueValue?.text = "${unsungHsv[0].roundToInt().coerceIn(0, 360)}°"
        lineCountSeg?.select(if (doubleLine) 1 else 0, notify = false)
        // 模式与预设选中环同样跟着配置走：Dart 侧换了配色/模式，原生面板的
        // 分段控件、自调区开合、色板选中环必须一起动，否则两端显示不一致。
        applyColorModeUi()
        refreshPresetSelection()
        // 「自定义」色块画的是自定义槽位的颜色，Dart 侧自调后要跟着重画
        refreshCustomSwatch()
    }

    /// 颜色滑杆：拖动中实时预览颜色（仅赋值+重绘），松手才提交（sendConfigUpdate）。
    ///
    /// 返回 (行, 色相读数 TextView)，调用方持有读数，交给 [refreshPanelReadouts]
    /// 统一回填 —— Dart 侧改配置下发过来时读数才会跟着动。
    private fun makeColorSeekRow(
        label: String,
        initialColor: Int,
        onColor: (Int) -> Unit,
        onCommitted: () -> Unit
    ): Pair<LinearLayout, TextView> {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        val tv = TextView(this).apply {
            text = label
            setTextColor(0xFFCCCCCC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(dp(52), ViewGroup.LayoutParams.WRAP_CONTENT)
            themedLabelViews.add(this)
        }
        val value = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(dp(44), ViewGroup.LayoutParams.WRAP_CONTENT)
            themedValueViews.add(this)
        }
        // Convert ARGB color to HSV hue (0-360) for SeekBar initial position
        val hsv = FloatArray(3)
        Color.colorToHSV(initialColor, hsv)
        val initialHue = hsv[0].toInt().coerceIn(0, 360)

        val seek = SeekBar(this).apply {
            max = 360
            progress = initialHue
            val rainbow = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(
                Color.RED, Color.YELLOW, Color.GREEN, Color.CYAN, Color.BLUE, Color.MAGENTA, Color.RED
            ))
            rainbow.cornerRadius = dp(4).toFloat()
            progressDrawable = insetTrack(rainbow)
            thumb = sliderThumb(0xFFFFFFFF.toInt())
            splitTrack = false
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            themedThumbs.add(this)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        val newHsv = floatArrayOf(progress.toFloat(), 1f, 1f)
                        onColor(Color.HSVToColor(newHsv))
                    }
                    value.text = "${progress.coerceIn(0, 360)}°"
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    onCommitted()
                }
            })
        }
        row.addView(tv)
        row.addView(seek)
        row.addView(value)
        return row to value
    }

    /// SeekBar 的细轨道：GradientDrawable 本身没有固有高度，SeekBar 会把它
    /// 拉伸到与 thumb 等高（真机上表现为一条很粗的色带）。套一层 InsetDrawable
    /// 留出上下内边距，就能画出"细轨道 + 圆滑块"的现代外观。
    private fun insetTrack(inner: Drawable): Drawable =
        InsetDrawable(inner, 0, dp(5), 0, dp(5))

    /// SeekBar 的圆滑块。系统默认 thumb 是 48dp 高的老式胶囊，必须换掉。
    private fun sliderThumb(color: Int): Drawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setSize(dp(18), dp(18))
        setColor(color)
        setStroke(dp(2), 0x59000000)
    }

    /// 通用"标签 + 滑杆 + 读数"行（不透明度用）。
    ///
    /// [trackColors] 直接决定轨道外观：不透明度那条是从全透明渐变到近全黑的，
    /// 滑块停在哪、悬浮窗背景就是哪个值 —— 比原来那条灰条诚实得多。
    private fun makeValueSeekRow(
        label: String,
        max: Int,
        initial: Int,
        trackColors: IntArray,
        format: (Int) -> String,
        onValue: (Int) -> Unit,
        onCommitted: () -> Unit
    ): Pair<LinearLayout, TextView> {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        val tv = TextView(this).apply {
            text = label
            setTextColor(0xFFCCCCCC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(dp(64), ViewGroup.LayoutParams.WRAP_CONTENT)
            themedLabelViews.add(this)
        }
        val value = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(dp(44), ViewGroup.LayoutParams.WRAP_CONTENT)
            themedValueViews.add(this)
        }
        val seek = SeekBar(this).apply {
            this.max = max
            progress = initial
            val track = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                trackColors
            ).apply { cornerRadius = dp(4).toFloat() }
            progressDrawable = insetTrack(track)
            thumb = sliderThumb(0xFFFFFFFF.toInt())
            splitTrack = false
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            themedThumbs.add(this)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) onValue(progress)
                    value.text = format(progress)
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    onCommitted()
                }
            })
        }
        row.addView(tv)
        row.addView(seek)
        row.addView(value)
        return row to value
    }

    /// 分段控件：一个圆角容器里并排若干等宽项，选中项填实底。
    ///
    /// 用来替代原来那排"长得一模一样、看不出选没选"的胶囊按钮（模式切换与
    /// 行式切换）。原生没有现成组件，这里自己拼。
    private inner class SegmentControl(
        labels: List<String>,
        private val onSelected: (Int) -> Unit
    ) : LinearLayout(this@FloatingLyricService) {

        private val items = mutableListOf<TextView>()
        private var selectedIndex = 0

        init {
            orientation = HORIZONTAL
            setPadding(dp(3), dp(3), dp(3), dp(3))
            labels.forEachIndexed { index, label ->
                val item = TextView(context).apply {
                    text = label
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    gravity = Gravity.CENTER
                    setPadding(dp(12), dp(7), dp(12), dp(7))
                    setOnClickListener { select(index) }
                }
                addView(item, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                items.add(item)
            }
            themedSegments.add(this)
            applyTheme(panelDarkContent)
        }

        /** [notify] = false 用于程序化同步选中态，不会反过来触发业务回调。 */
        fun select(index: Int, notify: Boolean = true) {
            selectedIndex = index.coerceIn(0, items.size - 1)
            applyTheme(panelDarkContent)
            if (notify) onSelected(selectedIndex)
        }

        /// 按 [dark] 主题重画容器底与各选项；选中态填实底、未选中透底。
        /// 反色（dark = 不透明度 < 50）时白系换成黑系，浅色壁纸上才看得清。
        fun applyTheme(dark: Boolean) {
            background = GradientDrawable().apply {
                cornerRadius = dp(19).toFloat()
                setColor(if (dark) 0x2B000000 else 0x2BFFFFFF)
            }
            items.forEachIndexed { index, item ->
                val on = index == selectedIndex
                item.setTextColor(
                    if (dark) (if (on) 0xFF1B1B1B.toInt() else 0xB3000000.toInt())
                    else (if (on) 0xFFFFFFFF.toInt() else 0xB3FFFFFF.toInt())
                )
                item.background = GradientDrawable().apply {
                    cornerRadius = dp(16).toFloat()
                    setColor(
                        if (on) (if (dark) 0x59000000 else 0x59FFFFFF)
                        else Color.TRANSPARENT
                    )
                }
            }
        }
    }

    private fun makeTextButton(text: String, onClick: (View) -> Unit): TextView {
        return TextView(this).apply {
            this.text = text
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(8), dp(14), dp(8))
            val gd = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0x33FFFFFF)
                setStroke(1, android.content.res.ColorStateList.valueOf(0x55FFFFFF))
            }
            background = gd
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.setMargins(dp(6), 0, dp(6), 0)
            layoutParams = lp
            themedTextButtons.add(this)
            setOnClickListener { onClick(this) }
        }
    }

    private fun makeIconButton(resId: Int, onClick: () -> Unit): ImageView {
        return ImageView(this).apply {
            setImageResource(resId)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            setColorFilter(0xFFFFFFFF.toInt())
            themedIconViews.add(this)
            setOnClickListener { onClick() }
        }
    }

    private fun sendAction(action: String) {
        val engine = io.flutter.embedding.engine.FlutterEngineCache.getInstance().get("md3music_engine")
        if (engine != null) {
            io.flutter.plugin.common.MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/floating_lyric"
            ).invokeMethod("desktopLyricAction", action)
        } else {
            MainActivity.sendDesktopLyricAction(action)
        }
    }

    private fun sendConfigUpdate() {
        val engine = io.flutter.embedding.engine.FlutterEngineCache.getInstance().get("md3music_engine")
        val args = hashMapOf(
            "fontSize" to fontSizeSp,
            "doubleLine" to doubleLine,
            "opacity" to opacity,
            "locked" to locked,
            // 颜色以**无符号 Long** 下发：Kotlin Int 的 ARGB 是负数
            // （0xFFFF00FF.toInt() = -65281），直接放 map 到 Dart 侧就是负数，
            // 回灌进 SharedPreferences / Color() 全是错色。转 Long（INT64 编码）
            // 后 Dart 收到的是正确的无符号值。
            "gradientStart" to (gradientStart.toLong() and 0xFFFFFFFFL),
            "gradientEnd" to (gradientEnd.toLong() and 0xFFFFFFFFL),
            "unplayedColor" to (unplayedColor.toLong() and 0xFFFFFFFFL),
            "colorMode" to colorMode,
            "activePreset" to lastPresetIndex,
            "customStart" to (customStart.toLong() and 0xFFFFFFFFL),
            "customEnd" to (customEnd.toLong() and 0xFFFFFFFFL),
            "customUnplayed" to (customUnplayed.toLong() and 0xFFFFFFFFL)
        )
        if (engine != null) {
            io.flutter.plugin.common.MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/floating_lyric"
            ).invokeMethod("desktopLyricConfigChanged", args)
        }
    }

    /// Touch listener: vertical-only drag (X locked at center)
    private fun setupTouchListener(view: View) {
        view.setOnTouchListener { _, event ->
            if (locked) return@setOnTouchListener false

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialY = params?.y ?: 0
                    initialTouchY = event.rawY
                    isDragging = false
                    dragStartTime = System.currentTimeMillis()
                    // 记下按在哪个区：只有按在上区（歌词预览）的轻点才展开/收起，
                    // 按下区（按钮行 / 进度条 / 设置面板）的空白处不该把面板收起来。
                    touchOnLyricArea = lyricArea?.let {
                        event.y >= it.top && event.y <= it.bottom
                    } ?: false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = event.rawY - initialTouchY
                    if (Math.abs(dy) > 10) {
                        isDragging = true
                    }
                    if (isDragging) {
                        // Only move vertically — X stays at 0 (centered)
                        params?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(rootView, params)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (isDragging) {
                        params?.y?.let { y ->
                            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                                .edit()
                                .putInt(KEY_Y_PX, y)
                                .apply()
                        }
                    }
                    if (!isDragging && System.currentTimeMillis() - dragStartTime < 300 &&
                        touchOnLyricArea
                    ) {
                        toggleExpanded()
                    }
                    isDragging = false
                    true
                }
                else -> false
            }
        }
    }

    override fun onDestroy() {
        isRunning = false
        viewAdded = false
        instance = null
        screenReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        screenReceiver = null
        screenOn = true
        // 阶段8：桌面歌词让位结束，通知保活服务立即恢复前台（不等 30s 周期更新）
        try {
            startService(Intent(this, AudioPlaybackService::class.java).apply {
                action = AudioPlaybackService.ACTION_REFRESH_FOREGROUND
            })
        } catch (_: Exception) {}
        super.onDestroy()
        rootView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
    }
}

/// Gradient text view with contrast optimization for low opacity
///
/// 逐字二分色支持（KRC）：当前行携带 KRC 字级时间戳（karaokeActive 为 true）时，
/// onDraw 中先画整行白色（未唱色），再 clipRect 已唱宽度画渐变色，实现
/// "已唱渐变 / 未唱白"的二分色效果；无逐字时间戳（LRC/纯文本）时整行渐变色（保持原行为）
class GradientTextView(context: Context) : TextView(context) {
    private var startColor = 0xFF00E5FF.toInt()
    private var endColor = 0xFFFF00FF.toInt()
    // 未唱色（白色），用于逐字二分色模式下绘制未唱部分
    private var unplayedColor = 0xFFFFFFFF.toInt()

    // P0: 缓存 LinearGradient shader，避免 onDraw 每帧新建对象引发 GC 卡顿。
    // shader 只与颜色和宽度相关，仅在它们变化时重建
    private var gradientShader: LinearGradient? = null
    private var shaderWidth = 0f
    private var shaderStartColor = 0
    private var shaderEndColor = 0

    // 每行文本的累计字符宽度缓存：charWidths[i] = 前 i 个字符的像素宽度。
    // 仅在文本变化时测量一次，onDraw 逐字模式下查表 O(1)，
    // 替代旧的每帧 paint.measureText(text, 0, n) O(n) 测量。
    private var charWidths: FloatArray = FloatArray(0)
    private var widthsForText: String? = null

    private fun ensureCharWidths(text: String) {
        if (widthsForText == text) return
        val n = text.length
        val arr = FloatArray(n + 1)
        for (i in 1..n) arr[i] = arr[i - 1] + paint.measureText(text, i - 1, i)
        charWidths = arr
        widthsForText = text
    }

    // ===== KRC 逐字卡拉OK（原生自驱动） =====
    // Dart 在行切换时一次推送整行字级时间戳与当时播放位置；本视图按
    // elapsedRealtime 差值推算当前位置，只在字边界 postDelayed 唤醒一次
    // invalidate（每字约 200~500ms 一次），替代旧方案 Dart 100ms 高频推送。
    private var karaokeWords: List<WordTiming> = emptyList()
    private var wordWidths: FloatArray = FloatArray(0)
    private var karaokeBasePosMs = 0L
    private var karaokeBaseElapsedMs = 0L
    private var karaokeActive = false
    // 真冻结标志：暂停期间 estimatedKaraokePos 恒返回固定位（不按墙钟增长）
    private var karaokePaused = false
    // 多行已唱区域 clip：Path 成员复用，避免 onDraw 每帧分配
    private val krcClipPath = Path()

    private val karaokeTickRunnable = Runnable {
        if (!karaokeActive) return@Runnable
        // 熄屏时悬浮窗必然不可见（锁屏歌词是独立的 LockScreenLyricActivity，
        // 不用本视图），跳过这次重绘可省掉整条 View 遍历 + 合成。
        // 时钟不冻结：位置仍按 elapsedRealtime 估算，亮屏后下一拍直接补上正确
        // 进度，无需额外同步（Dart 侧熄屏停 tick 见 desktop_lyric_service
        // 的 _tickNeeded / onScreenStateChanged）。
        if (FloatingLyricService.screenOn) invalidate()
        scheduleKaraokeTick()
    }

    /// 设置当前行逐字时间戳。basePosMs 为 Dart 行提交时的播放位置。
    /// 字宽用当前 paint 按字文本测量一次（与 charWidths 同一测量基准）。
    fun setKaraokeLine(words: List<WordTiming>, basePosMs: Long, playing: Boolean) {
        Log.d(KARAOKE_LOG, "setKaraokeLine n=${words.size} basePos=$basePosMs playing=$playing")
        karaokeWords = words
        wordWidths = FloatArray(words.size) { paint.measureText(words[it].text) }
        karaokeBasePosMs = basePosMs
        karaokeBaseElapsedMs = SystemClock.elapsedRealtime()
        karaokeActive = karaokeWords.isNotEmpty()
        // 暂停中收到行提交也必须冻结：否则墙钟差从 0 重新起算，估算位置继续增长
        karaokePaused = !playing
        removeCallbacks(karaokeTickRunnable)
        if (karaokeActive && playing) scheduleKaraokeTick()
        invalidate()
    }

    fun clearKaraoke() {
        karaokeActive = false
        karaokeWords = emptyList()
        removeCallbacks(karaokeTickRunnable)
        invalidate()
    }

    /// 进度周期校正：本地估算与真实播放位置偏差超过 150ms 时重置基准
    /// （覆盖 seek / 音频焦点丢失等场景）。暂停时仅冻结调度。
    fun onKaraokePositionSync(posMs: Long, playing: Boolean) {
        if (!karaokeActive) return
        Log.d(KARAOKE_LOG, "posSync pos=$posMs playing=$playing paused=$karaokePaused")
        if (!playing) {
            karaokePaused = true
            removeCallbacks(karaokeTickRunnable)
            return
        }
        karaokePaused = false
        if (kotlin.math.abs(estimatedKaraokePos() - posMs) > 150) {
            karaokeBasePosMs = posMs
            karaokeBaseElapsedMs = SystemClock.elapsedRealtime()
        }
        scheduleKaraokeTick()
    }

    /// 播放/暂停：暂停时进入真冻结（估算位置直接返回固定位，不再按墙钟增长）；
    /// 恢复时重置时钟差起点并重新调度。
    fun onKaraokePlayingChanged(playing: Boolean) {
        if (!karaokeActive) return
        Log.d(KARAOKE_LOG, "playingChanged playing=$playing paused=$karaokePaused")
        removeCallbacks(karaokeTickRunnable)
        if (!playing) {
            karaokeBasePosMs = estimatedKaraokePos()
            karaokePaused = true
        } else {
            karaokePaused = false
            karaokeBaseElapsedMs = SystemClock.elapsedRealtime()
            scheduleKaraokeTick()
        }
    }

    private fun estimatedKaraokePos(): Long {
        // 真冻结：暂停期间估算位置恒等于固定位。旧实现只重置基准起点，
        // elapsed 时钟差从 0 重新起算继续增长，暂停后逐字仍按墙钟推进。
        if (karaokePaused) return karaokeBasePosMs
        return karaokeBasePosMs + (SystemClock.elapsedRealtime() - karaokeBaseElapsedMs)
    }

    private fun scheduleKaraokeTick() {
        if (!karaokeActive || karaokePaused) return
        removeCallbacks(karaokeTickRunnable)
        // 平滑逐字 sweep：旧实现只在**字边界** postDelayed 一次，两帧之间
        // 没有任何重绘，sungKaraokeWidth 的当前字线性插值根本没机会显示 ——
        // 视觉上就是一个字一个字硬跳（用户反馈"像蹦出来的"）。
        // 改为卡拉OK进行中固定 ~30fps 连续重绘；插值本身是精确的，
        // 30fps 扫过单个字（200~500ms 宽）完全平滑。熄屏时 tick runnable
        // 会跳过 invalidate，暂停时这里直接 return，均无空转。
        postDelayed(karaokeTickRunnable, 32)
    }

    /// 按估算位置计算已唱像素宽度（已完成字累加 + 当前字线性插值）。
    private fun sungKaraokeWidth(): Float {
        val pos = estimatedKaraokePos()
        var w = 0f
        for (i in karaokeWords.indices) {
            val t = karaokeWords[i]
            when {
                pos >= t.startMs + t.durMs -> w += wordWidths[i]
                pos > t.startMs -> {
                    w += wordWidths[i] * ((pos - t.startMs).toFloat() / t.durMs)
                    break
                }
                else -> break
            }
        }
        return w
    }

    init {
        setTextColor(Color.WHITE)
    }

    fun setGradient(start: Int, end: Int) {
        if (startColor != start || endColor != end) {
            startColor = start
            endColor = end
            // 使 shader 缓存失效，下次 onDraw 重建
            gradientShader = null
            invalidate()
        }
    }

    fun setUnplayedColor(color: Int) {
        unplayedColor = color
        invalidate()
    }

    /// 获取（按需重建）整行渐变 shader。宽度未变化时复用上一帧实例
    private fun ensureGradientShader(): LinearGradient? {
        if (width <= 0) return null
        if (gradientShader == null ||
            shaderWidth != width.toFloat() ||
            shaderStartColor != startColor ||
            shaderEndColor != endColor
        ) {
            shaderWidth = width.toFloat()
            shaderStartColor = startColor
            shaderEndColor = endColor
            gradientShader = LinearGradient(
                0f, 0f, shaderWidth, 0f,
                startColor, endColor, Shader.TileMode.CLAMP
            )
        }
        return gradientShader
    }

    override fun onDraw(canvas: Canvas) {
        val width = measuredWidth.toFloat()

        // 只画文字本身：已唱用渐变色，未唱用未唱色。不描边、不投影、不铺底板
        // —— 用户要求去掉一切多余样式，可读性交给「不透明度」这一项设置。

        val text = text?.toString() ?: ""
        val enableKrcMode = karaokeActive && text.isNotEmpty()

        if (enableKrcMode) {
            // KRC 逐字二分色：先画整段灰色（未唱色），再按行 clip 已唱区域画渐变色
            // 1. 已唱像素宽度按估算播放位置计算（全文累计，已完成字累加 + 当前字线性插值）
            ensureCharWidths(text)
            val sungWidth = sungKaraokeWidth()

            // 2. 先画整段灰色（未唱色）
            //    注意：TextView.onDraw 会用 currentTextColor 覆盖 paint.color，
            //    所以必须用 setTextColor 切换，不能直接设 paint.color
            val savedTextColor = currentTextColor
            setTextColor(unplayedColor)
            paint.shader = null
            super.onDraw(canvas)

            // 3. 按行构造已唱区域（支持自动换行，maxLines=2）。
            //    TextView 绘制时画布已平移到 padding 内侧，Layout 的
            //    getLineLeft/Top 即绘制坐标（gravity=CENTER 的行内居中已含）。
            //    已唱宽度依次填充各行：行内已唱 = 全文已唱宽 - 行首字符累计宽。
            //    shader 优先于 color，渐变色会盖住灰色。
            if (sungWidth > 0f && width > 0) {
                val textLayout = layout
                if (textLayout != null) {
                    // canvas 在 onDraw 重写中处于视图坐标系；super.onDraw 内部才平移到
                    // padding 原点绘制 Layout。故 clip Path 需加偏移：Layout(0,0)
                    // 在视图坐标中的位置
                    val ox = totalPaddingLeft.toFloat()
                    val oy = extendedPaddingTop.toFloat()
                    krcClipPath.rewind()
                    for (line in 0 until textLayout.lineCount) {
                        val lineStart = textLayout.getLineStart(line)
                        val lineWidth = textLayout.getLineWidth(line)
                        val sungInLine = (sungWidth - charWidths[lineStart.coerceAtMost(text.length)])
                            .coerceIn(0f, lineWidth)
                        if (sungInLine <= 0f) break
                        val right = if (sungInLine >= lineWidth - 0.5f) {
                            textLayout.getLineRight(line)
                        } else {
                            textLayout.getLineLeft(line) + sungInLine
                        }
                        krcClipPath.addRect(
                            ox + textLayout.getLineLeft(line),
                            oy + textLayout.getLineTop(line).toFloat(),
                            ox + right,
                            oy + textLayout.getLineBottom(line).toFloat(),
                            Path.Direction.CW
                        )
                    }
                    if (!krcClipPath.isEmpty) {
                        canvas.save()
                        canvas.clipPath(krcClipPath)
                        // P0: 复用缓存的 shader，避免每帧新建 LinearGradient
                        paint.shader = ensureGradientShader()
                        super.onDraw(canvas)
                        canvas.restore()
                    }
                }
            }

            // 恢复 textColor（下次 onDraw 用）
            setTextColor(savedTextColor)
        } else {
            // LRC/纯文本：整行渐变色（原行为）
            if (width > 0) {
                // P0: 复用缓存的 shader，避免每帧新建 LinearGradient
                paint.shader = ensureGradientShader()
            }
            super.onDraw(canvas)
        }
    }
}

/// Progress bar: gradient played + unplayed color
class LyricProgressBar(context: Context) : View(context) {
    private var position = 0L
    private var duration = 0L
    private var gradientStart = 0xFF00E5FF.toInt()
    private var gradientEnd = 0xFFFF00FF.toInt()
    private var unplayedColor = 0xFFFFFFFF.toInt()
    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val playedPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val unplayedPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val barHeight = 6f
    // 零分配：RectF 成员复用；shader 覆盖全宽缓存复用，
    // 已唱部分按比例露出渐变——渐变不再随进度被"压缩"
    private val bgRect = RectF()
    private val playedRect = RectF()
    private var playedShader: LinearGradient? = null
    private var shaderKeyWidth = 0f

    fun updateProgress(pos: Long, dur: Long) {
        position = pos
        duration = dur
        invalidate()
    }

    fun setGradient(start: Int, end: Int, unplayed: Int) {
        gradientStart = start
        gradientEnd = end
        unplayedColor = unplayed
        playedShader = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return
        val cy = h / 2f
        val radius = barHeight / 2f

        bgRect.set(0f, cy - radius, w, cy + radius)
        bgPaint.color = unplayedColor
        canvas.drawRoundRect(bgRect, radius, radius, bgPaint)

        if (duration <= 0) return
        val ratio = (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
        val playedWidth = w * ratio
        if (playedWidth > 0f) {
            if (playedShader == null || shaderKeyWidth != w) {
                playedShader = LinearGradient(
                    0f, 0f, w, 0f,
                    gradientStart, gradientEnd, Shader.TileMode.CLAMP
                )
                shaderKeyWidth = w
            }
            playedPaint.shader = playedShader
            playedRect.set(0f, cy - radius, playedWidth, cy + radius)
            canvas.drawRoundRect(playedRect, radius, radius, playedPaint)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = (resources.displayMetrics.density * 6).toInt()
        setMeasuredDimension(w, h)
    }
}
