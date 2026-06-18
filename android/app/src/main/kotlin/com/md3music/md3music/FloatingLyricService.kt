package com.md3music.md3music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.os.Build
import android.os.IBinder
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache

class FloatingLyricService : Service() {
    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var collapsedPanel: View? = null
    private var expandedPanel: View? = null
    private var lyricText1: GradientTextView? = null
    private var lyricText2: GradientTextView? = null
    private var params: WindowManager.LayoutParams? = null

    // touch/drag
    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false
    private var dragStartTime = 0L
    private var expanded = false
    private var locked = false

    // config
    private var fontSizeSp = 18f
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
    private var colorMode = 0 // 0=预设, 1=自调

    companion object {
        const val CHANNEL_ID = "floating_lyric_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_UPDATE_LYRIC = "com.md3music.md3music.UPDATE_LYRIC"
        const val ACTION_UPDATE_TITLE = "com.md3music.md3music.UPDATE_TITLE"
        const val ACTION_UPDATE_PROGRESS = "com.md3music.md3music.UPDATE_PROGRESS"
        const val ACTION_SET_CONFIG = "com.md3music.md3music.SET_CONFIG"
        const val ACTION_SET_PLAYING = "com.md3music.md3music.SET_PLAYING"
        const val ACTION_STOP = "com.md3music.md3music.STOP_LYRIC"
        const val EXTRA_LYRIC = "lyric"
        const val EXTRA_NEXT_LYRIC = "nextLyric"
        const val EXTRA_TITLE = "title"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_FONT_SIZE = "fontSize"
        const val EXTRA_DOUBLE_LINE = "doubleLine"
        const val EXTRA_OPACITY = "opacity"
        const val EXTRA_LOCKED = "locked"
        const val EXTRA_GRADIENT_START = "gradientStart"
        const val EXTRA_GRADIENT_END = "gradientEnd"
        const val EXTRA_UNPLAYED_COLOR = "unplayedColor"
        const val EXTRA_IS_PLAYING = "isPlaying"

        // 预设配色
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
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        createFloatingView()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE_LYRIC -> {
                val lyric = intent.getStringExtra(EXTRA_LYRIC) ?: ""
                val next = intent.getStringExtra(EXTRA_NEXT_LYRIC)
                updateLyric(lyric, next)
            }
            ACTION_UPDATE_TITLE -> {
                // 标题不常驻显示，忽略即可
            }
            ACTION_UPDATE_PROGRESS -> {
                val pos = intent.getLongExtra(EXTRA_POSITION, 0L)
                val dur = intent.getLongExtra(EXTRA_DURATION, 0L)
                progressBar?.updateProgress(pos, dur)
            }
            ACTION_SET_CONFIG -> {
                intent.getFloatExtra(EXTRA_FONT_SIZE, fontSizeSp).let { fontSizeSp = it }
                intent.getBooleanExtra(EXTRA_DOUBLE_LINE, doubleLine).let { doubleLine = it }
                intent.getIntExtra(EXTRA_OPACITY, opacity).let { opacity = it }
                intent.getBooleanExtra(EXTRA_LOCKED, locked).let { locked = it }
                intent.getIntExtra(EXTRA_GRADIENT_START, gradientStart).let { gradientStart = it }
                intent.getIntExtra(EXTRA_GRADIENT_END, gradientEnd).let { gradientEnd = it }
                intent.getIntExtra(EXTRA_UNPLAYED_COLOR, unplayedColor).let { unplayedColor = it }
                applyConfig()
            }
            ACTION_SET_PLAYING -> {
                isPlayingFlag = intent.getBooleanExtra(EXTRA_IS_PLAYING, isPlayingFlag)
                playPauseButton?.setImageResource(
                    if (isPlayingFlag) android.R.drawable.ic_media_pause
                    else android.R.drawable.ic_media_play
                )
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    private fun setLocked(value: Boolean) {
        locked = value
        lockButton?.setImageResource(
            if (locked) android.R.drawable.ic_lock_lock
            else android.R.drawable.ic_lock_idle_lock
        )
    }

    private fun applyConfig() {
        lyricText1?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
        lyricText2?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
        lyricText2?.visibility = if (doubleLine) View.VISIBLE else View.GONE

        lyricText1?.setGradient(gradientStart, gradientEnd)
        lyricText2?.setGradient(gradientStart, gradientEnd)

        // 背景透明度
        val bgAlpha = (opacity * 255 / 100).coerceIn(0, 255)
        val bgColor = (bgAlpha shl 24) or 0x000000
        (rootView?.background as? GradientDrawable)?.apply {
            setColor(bgColor)
        }

        progressBar?.setGradient(gradientStart, gradientEnd, unplayedColor)
        updateLyric(lyricText1?.text?.toString() ?: "", lyricText2?.text?.toString())
    }

    private fun updateLyric(lyric: String, nextLyric: String?) {
        val safeLyric = lyric.ifEmpty { "歌词加载中..." }
        lyricText1?.text = safeLyric
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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MD3Music")
            .setContentText("桌面歌词已开启")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "关闭", stopPendingIntent)
            .build()
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()

    private fun sp(v: Float): Float =
        v * resources.displayMetrics.scaledDensity

    private fun createFloatingView() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        rootView = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0xCC000000.toInt())
            }
            setPadding(dp(20), dp(12), dp(20), dp(12))
            setOnClickListener { toggleExpanded() }
        }

        // ===== 收起面板：只显示歌词 =====
        collapsedPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }

        lyricText1 = GradientTextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
            gravity = Gravity.CENTER
            maxLines = 1
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        lyricText2 = GradientTextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSizeSp)
            gravity = Gravity.CENTER
            maxLines = 1
            setPadding(dp(8), dp(2), dp(8), dp(4))
            visibility = View.GONE
        }
        (collapsedPanel as LinearLayout).addView(lyricText1)
        (collapsedPanel as LinearLayout).addView(lyricText2)

        // ===== 展开面板：控制栏 + 进度条 + 设置 =====
        expandedPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
        }
        val exp = expandedPanel as LinearLayout

        // 控制按钮行
        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(8))
        }
        val iconSize = dp(20)
        val iconPad = dp(10)
        lockButton = makeIconButton(android.R.drawable.ic_lock_idle_lock) { sendAction("lock"); setLocked(!locked) }
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

        // 进度条
        progressBar = LyricProgressBar(this).apply {
            setGradient(gradientStart, gradientEnd, unplayedColor)
        }
        val pbLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(4))
        pbLp.setMargins(dp(12), 0, dp(12), dp(8))
        progressBar?.layoutParams = pbLp
        exp.addView(progressBar)

        // 设置面板
        settingsPanel = createSettingsPanel()
        exp.addView(settingsPanel)

        rootView?.addView(collapsedPanel)
        rootView?.addView(expandedPanel)

        setupTouchListener(rootView!!)

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(80)
        }

        windowManager?.addView(rootView, params)
    }

    private fun toggleExpanded() {
        if (isDragging) return
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

        // 预设/自调 切换
        val modeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val presetBtn = makeTextButton("预设配色") { switchColorMode(0) }
        val customBtn = makeTextButton("自调颜色") { switchColorMode(1) }
        modeRow.addView(presetBtn)
        modeRow.addView(customBtn)
        root.addView(modeRow)

        // 预设色块
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
                    // 简单双色：用 layer 或 gradient
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

        // 自调颜色面板（已唱/未唱）
        colorPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            visibility = View.GONE
        }
        val cp = colorPanel as LinearLayout

        val sungRow = makeColorSeekRow("已唱") { color ->
            gradientStart = color
            gradientEnd = color
            sendConfigUpdate()
            applyConfig()
        }
        val unsungRow = makeColorSeekRow("未唱") { color ->
            unplayedColor = color
            sendConfigUpdate()
            applyConfig()
        }
        cp.addView(sungRow)
        cp.addView(unsungRow)
        root.addView(cp)

        // 透明度
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
                        opacity = progress
                        sendConfigUpdate()
                        applyConfig()
                    }
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {}
            })
        }
        opacityRow.addView(opacityLabel)
        opacityRow.addView(opacitySeek)
        root.addView(opacityRow)

        // 字号 + 双行
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

    private fun makeColorSeekRow(label: String, onColor: (Int) -> Unit): LinearLayout {
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
        val seek = SeekBar(this).apply {
            max = 360
            progress = 180
            val rainbow = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(
                Color.RED, Color.YELLOW, Color.GREEN, Color.CYAN, Color.BLUE, Color.MAGENTA, Color.RED
            ))
            rainbow.cornerRadius = dp(2).toFloat()
            progressDrawable = rainbow
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        val hsv = floatArrayOf(progress.toFloat(), 1f, 1f)
                        onColor(Color.HSVToColor(hsv))
                    }
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {}
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
                setStroke(1, 0x55FFFFFF)
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
        val engine = FlutterEngineCache.getInstance().get("md3music_engine")
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
        val engine = FlutterEngineCache.getInstance().get("md3music_engine")
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

    private fun setupTouchListener(view: View) {
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params?.x ?: 0
                    initialY = params?.y ?: 0
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    dragStartTime = System.currentTimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (locked) return@setOnTouchListener true
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
                        isDragging = true
                    }
                    if (isDragging) {
                        params?.x = initialX + dx.toInt()
                        params?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(rootView, params)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
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
        super.onDestroy()
        rootView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
    }
}

/** 渐变文字 TextView */
class GradientTextView(context: Context) : TextView(context) {
    private var startColor = 0xFF00E5FF.toInt()
    private var endColor = 0xFFFF00FF.toInt()

    init {
        // 先设置默认白色，防止渐变 shader 未生效时文字不可见
        setTextColor(Color.WHITE)
    }

    fun setGradient(start: Int, end: Int) {
        startColor = start
        endColor = end
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val width = measuredWidth.toFloat()
        if (width > 0) {
            paint.shader = LinearGradient(
                0f, 0f, width, 0f,
                startColor, endColor, Shader.TileMode.CLAMP
            )
        }
        super.onDraw(canvas)
    }
}

/** 进度条：已唱渐变 + 未唱单色 */
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

    fun updateProgress(pos: Long, dur: Long) {
        position = pos
        duration = dur
        invalidate()
    }

    fun setGradient(start: Int, end: Int, unplayed: Int) {
        gradientStart = start
        gradientEnd = end
        unplayedColor = unplayed
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return
        val cy = h / 2f
        val radius = barHeight / 2f
        val rect = RectF(0f, cy - radius, w, cy + radius)

        // 未唱背景
        bgPaint.color = unplayedColor
        canvas.drawRoundRect(rect, radius, radius, bgPaint)

        if (duration <= 0) return
        val ratio = (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
        val playedWidth = w * ratio
        if (playedWidth > 0) {
            playedPaint.shader = LinearGradient(
                0f, 0f, playedWidth, 0f,
                gradientStart, gradientEnd, Shader.TileMode.CLAMP
            )
            val playedRect = RectF(0f, cy - radius, playedWidth, cy + radius)
            canvas.drawRoundRect(playedRect, radius, radius, playedPaint)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = (resources.displayMetrics.density * 6).toInt()
        setMeasuredDimension(w, h)
    }
}
