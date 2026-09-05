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
import android.graphics.drawable.GradientDrawable
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
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.app.NotificationCompat

/// 单个字的卡拉OK时间戳（text 为该字文本，供原生按 paint 测量字宽）
class WordTiming(val text: String, val startMs: Long, val durMs: Long)

// 卡拉OK链路诊断日志 TAG（暂停冻结问题排查用，同文件两个类共用）
private const val KARAOKE_LOG = "KaraokeDebug"

class FloatingLyricService : Service() {
    private var windowManager: WindowManager? = null
    private var rootView: LinearLayout? = null
    private var collapsedPanel: View? = null
    private var expandedPanel: View? = null
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
    private var locked = false

    // config
    private var fontSizeSp = 18f
    // 「显示大小」档位（Dart 侧 ThemeProvider.displayScale）。
    // 与 fontSizeSp 分开存：± 按钮与回传 Dart 的配置始终用未缩放的基准字号，
    // 只在 setTextSize 时乘上本系数，避免往返放大 / 撞上 12~32sp 的钳制区间。
    private var displayScale = 1f
    private var doubleLine = false
    private var opacity = 80
    private var gradientStart = 0xFF00E5FF.toInt()
    private var gradientEnd = 0xFFFF00FF.toInt()
    private var unplayedColor = 0xFF666666.toInt()
    private var isPlayingFlag = false

    // views
    private var lockButton: ImageView? = null
    private var playPauseButton: ImageView? = null
    private var progressBar: LyricProgressBar? = null
    private var settingsPanel: View? = null
    private var colorPanel: View? = null
    private var colorMode = 0

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
        const val EXTRA_IS_PLAYING = "isPlaying"

        val PRESETS = listOf(
            0xFF00E5FF.toInt() to 0xFFFF00FF.toInt(),
            0xFFFF4081.toInt() to 0xFFFFC400.toInt(),
            0xFF00E676.toInt() to 0xFF00B0FF.toInt(),
            0xFFFFFFFF.toInt() to 0xFFFFFFFF.toInt()
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // 更新歌词等通道可能在用户撤销悬浮窗权限后再次拉起本服务，不能只依赖
        // MainActivity 的首次开启检查。ColorOS 会对 2038 窗口直接抛 BadTokenException，
        // 若从 onCreate 逸出会杀死整个播放器进程，连带重建并清空 MediaSession actions。
        if (!hasOverlayPermission()) {
            Log.w(TAG, "Overlay permission missing; floating lyric service stopped")
            stopSelf()
            return
        }
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        if (!createFloatingView()) {
            stopSelf()
            return
        }
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
                    intent.getIntExtra(EXTRA_UNPLAYED_COLOR, unplayedColor)
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
                        gradientStart: Int?, gradientEnd: Int?, unplayedColor: Int?) {
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
            expanded = false
            expandedPanel?.visibility = View.GONE

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

        // Contrast optimization: pass opacity to text views for shadow adjustment
        lyricText1?.setOpacityForContrast(opacity)
        lyricText2?.setOpacityForContrast(opacity)

        progressBar?.setGradient(gradientStart, gradientEnd, unplayedColor)
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

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0xCC000000.toInt())
            }
            setPadding(dp(20), dp(12), dp(20), dp(12))
            gravity = Gravity.CENTER_HORIZONTAL
            setOnClickListener { toggleExpanded() }
        }
        val root = rootView as LinearLayout

        // ===== collapsed panel: lyric only =====
        collapsedPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val col = collapsedPanel as LinearLayout

        // 窗口宽度固定：随文字变化宽度会触发 WindowManager 重定位
        // （先瞬移后动画回中）。固定后 gravity 居中恒成立，永不跳动。
        val fixedWindowWidth = resources.displayMetrics.widthPixels - dp(32)

        // 歌词文本最大宽度：窗口宽减去根 padding(20×2)，LinearLayout 约束实际生效，
        // maxWidth 保留为兜底，防止超长歌词撑破窗口
        val lyricMaxWidth = fixedWindowWidth - dp(40)

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

        // ===== expanded panel =====
        expandedPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
        }
        val exp = expandedPanel as LinearLayout

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
        val settingsButton = makeIconButton(android.R.drawable.ic_menu_preferences) { toggleSettingsPanel() }

        listOf(lockButton, prevButton, playPauseButton, nextButton, settingsButton).forEach {
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

        root.addView(expandedPanel)

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

    private fun toggleExpanded() {
        if (isDragging) return
        if (locked) return  // Can't expand when locked
        expanded = !expanded
        expandedPanel?.visibility = if (expanded) View.VISIBLE else View.GONE
    }

    private fun toggleSettingsPanel() {
        settingsPanel?.visibility = if (settingsPanel?.visibility == View.VISIBLE) View.GONE else View.VISIBLE
    }

    private fun createSettingsPanel(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            visibility = View.GONE
        }

        val modeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val presetBtn = makeTextButton("预设配色") { switchColorMode(0) }
        val customBtn = makeTextButton("自调颜色") { switchColorMode(1) }
        modeRow.addView(presetBtn)
        modeRow.addView(customBtn)
        root.addView(modeRow)

        val presetRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(8))
        }
        PRESETS.forEach { (start, end) ->
            val v = View(this).apply {
                val size = dp(32)
                layoutParams = LinearLayout.LayoutParams(size, size).apply {
                    setMargins(dp(6), 0, dp(6), 0)
                }
                background = GradientDrawable().apply {
                    cornerRadius = dp(6).toFloat()
                    setColor(start)
                    val g = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(start, end))
                    g.cornerRadius = dp(6).toFloat()
                    background = g
                }
                setOnClickListener {
                    gradientStart = start
                    gradientEnd = end
                    sendConfigUpdate()
                    applyConfig()
                }
            }
            presetRow.addView(v)
        }
        root.addView(presetRow)

        colorPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            visibility = View.GONE
        }
        val cp = colorPanel as LinearLayout

        val sungRow = makeColorSeekRow("已唱", gradientStart, onColor = { color ->
            // 拖动中仅预览（赋值+重绘），松手才 sendConfigUpdate 持久化
            gradientStart = color
            gradientEnd = color
            applyConfig()
        }, onCommitted = {
            sendConfigUpdate()
        })
        val unsungRow = makeColorSeekRow("未唱", unplayedColor, onColor = { color ->
            unplayedColor = color
            applyConfig()
        }, onCommitted = {
            sendConfigUpdate()
        })
        cp.addView(sungRow)
        cp.addView(unsungRow)
        root.addView(cp)

        // Opacity slider
        val opacityRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(6), 0, dp(6))
        }
        val opacityLabel = TextView(this).apply {
            text = "透明度"
            setTextColor(0xFFCCCCCC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(dp(50), ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val opacitySeek = SeekBar(this).apply {
            max = 100
            progress = opacity
            progressDrawable = GradientDrawable().apply {
                setColor(0xFF888888.toInt())
                cornerRadius = dp(2).toFloat()
            }
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        // 拖动中仅实时预览：持久化在松手时一次性完成
                        // （每次移动都 sendConfigUpdate 会触发通道往返+写盘风暴）
                        opacity = progress
                        applyConfig()
                    }
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    sendConfigUpdate()
                }
            })
        }
        opacityRow.addView(opacityLabel)
        opacityRow.addView(opacitySeek)
        root.addView(opacityRow)

        // Font size + double line
        val bottomRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(6), 0, 0)
        }
        bottomRow.addView(makeTextButton("A-") {
            fontSizeSp = (fontSizeSp - 2f).coerceAtLeast(12f)
            sendConfigUpdate()
            applyConfig()
        })
        bottomRow.addView(makeTextButton("A+") {
            fontSizeSp = (fontSizeSp + 2f).coerceAtMost(32f)
            sendConfigUpdate()
            applyConfig()
        })
        val doubleBtn = makeTextButton(if (doubleLine) "单行" else "双行") {
            doubleLine = !doubleLine
            (it as TextView).text = if (doubleLine) "单行" else "双行"
            sendConfigUpdate()
            applyConfig()
        }
        bottomRow.addView(doubleBtn)
        root.addView(bottomRow)

        return root
    }

    private fun switchColorMode(mode: Int) {
        colorMode = mode
        colorPanel?.visibility = if (mode == 1) View.VISIBLE else View.GONE
    }

    /// 颜色滑杆：拖动中实时预览颜色（仅赋值+重绘），松手才提交（sendConfigUpdate）
    private fun makeColorSeekRow(label: String, initialColor: Int, onColor: (Int) -> Unit, onCommitted: () -> Unit): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(6), 0, dp(6))
        }
        val tv = TextView(this).apply {
            text = label
            setTextColor(0xFFCCCCCC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(dp(50), ViewGroup.LayoutParams.WRAP_CONTENT)
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
            rainbow.cornerRadius = dp(2).toFloat()
            progressDrawable = rainbow
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        val newHsv = floatArrayOf(progress.toFloat(), 1f, 1f)
                        onColor(Color.HSVToColor(newHsv))
                    }
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    onCommitted()
                }
            })
        }
        row.addView(tv)
        row.addView(seek)
        return row
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
            setOnClickListener { onClick(this) }
        }
    }

    private fun makeIconButton(resId: Int, onClick: () -> Unit): ImageView {
        return ImageView(this).apply {
            setImageResource(resId)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            setColorFilter(0xFFFFFFFF.toInt())
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
            "gradientStart" to gradientStart,
            "gradientEnd" to gradientEnd,
            "unplayedColor" to unplayedColor
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
                    if (!isDragging && System.currentTimeMillis() - dragStartTime < 300) {
                        view.performClick()
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
/// onDraw 中先画整行灰色（未唱色），再 clipRect 已唱宽度画渐变色，实现
/// "已唱渐变 / 未唱灰"的二分色效果；无逐字时间戳（LRC/纯文本）时整行渐变色（保持原行为）
class GradientTextView(context: Context) : TextView(context) {
    private var startColor = 0xFF00E5FF.toInt()
    private var endColor = 0xFFFF00FF.toInt()
    private var bgOpacity = 80
    // 未唱色（灰色），用于逐字二分色模式下绘制未唱部分
    private var unplayedColor = 0xFF666666.toInt()

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
        invalidate()
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
        if (!karaokeActive) return
        removeCallbacks(karaokeTickRunnable)
        val pos = estimatedKaraokePos()
        val nextBoundary = karaokeWords
            .firstOrNull { it.startMs + it.durMs > pos }
            ?.let { it.startMs + it.durMs }
            ?: return
        postDelayed(karaokeTickRunnable, (nextBoundary - pos).coerceAtLeast(16))
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

    fun setOpacityForContrast(opacity: Int) {
        bgOpacity = opacity
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

        // Contrast optimization: add dark shadow/stroke when background opacity is low
        // This ensures text remains readable even on light backgrounds
        val shadowEnabled: Boolean
        val shadowRadius: Float
        val shadowColor: Int

        if (bgOpacity < 30) {
            // Very transparent background — strong shadow for readability
            shadowEnabled = true
            shadowRadius = 4f * resources.displayMetrics.density
            shadowColor = 0xCC000000.toInt()
        } else if (bgOpacity < 60) {
            // Semi-transparent — moderate shadow
            shadowEnabled = true
            shadowRadius = 2.5f * resources.displayMetrics.density
            shadowColor = 0x99000000.toInt()
        } else {
            // Opaque enough — subtle shadow for depth
            shadowEnabled = true
            shadowRadius = 1.5f * resources.displayMetrics.density
            shadowColor = 0x66000000.toInt()
        }

        if (shadowEnabled) {
            paint.setShadowLayer(shadowRadius, 0f, 1f * resources.displayMetrics.density, shadowColor)
        } else {
            paint.clearShadowLayer()
        }

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
                        // 已唱部分不要 shadow（避免双重 shadow），清掉再画
                        paint.clearShadowLayer()
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

        // Reset shadow after draw to avoid affecting other draws
        paint.clearShadowLayer()
    }
}

/// Progress bar: gradient played + unplayed color
class LyricProgressBar(context: Context) : View(context) {
    private var position = 0L
    private var duration = 0L
    private var gradientStart = 0xFF00E5FF.toInt()
    private var gradientEnd = 0xFFFF00FF.toInt()
    private var unplayedColor = 0xFF666666.toInt()
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
