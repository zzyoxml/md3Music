package com.md3music.md3music

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 悬浮窗听歌识曲服务。
 *
 * 悬浮窗按钮点击「识别」→ 回调 Dart 发起 MediaProjection 授权（MainActivity）→
 * 授权成功后本服务用 AudioPlaybackCapture 采集系统音频（8000Hz/16bit/mono），
 * 每 8s 一段把 PCM 回调 Dart → Dart 复用酷狗指纹识曲链路识别 → 命中后回传
 * 结果在此悬浮窗显示歌名/歌手 + 播放按钮。
 *
 * 采集循环由 Dart 侧控制：每段完成后本服务阻塞等待 `continueCapture` /
 * `stopCapture`，避免原生侧自行决定重试次数。
 */
class FloatingRecognitionService : Service() {

    companion object {
        const val TAG = "FloatingRecognition"
        const val CHANNEL_ID = "floating_recognition_channel"
        const val NOTIFICATION_ID = 2001
        const val ACTION_START = "com.md3music.md3music.RECOG_START"
        const val ACTION_STOP = "com.md3music.md3music.RECOG_STOP"
        const val ACTION_CONTINUE = "com.md3music.md3music.RECOG_CONTINUE"
        const val ACTION_STOP_CAPTURE = "com.md3music.md3music.RECOG_STOP_CAPTURE"
        const val ACTION_SET_RESULT = "com.md3music.md3music.RECOG_SET_RESULT"
        const val ACTION_SET_STATUS = "com.md3music.md3music.RECOG_SET_STATUS"
        const val ACTION_SET_THEME = "com.md3music.md3music.RECOG_SET_THEME"
        const val EXTRA_RESULT = "result"
        const val EXTRA_STATUS = "status"
        const val EXTRA_THEME_COLORS = "themeColors"
        const val DART_CHANNEL = "com.md3music.md3music/floating_recognition"

        // 采集参数：8000Hz / 16bit / mono，8s = 128KB
        const val SAMPLE_RATE = 8000
        const val SEGMENT_BYTES = SAMPLE_RATE * 2 * 8

        // 状态
        const val STATE_IDLE = 0
        const val STATE_LISTENING = 1
        const val STATE_RECOGNIZING = 2
        const val STATE_RESULT = 3

        @Volatile
        private var instance: FloatingRecognitionService? = null

        /** 服务是否正在运行（MainActivity 用于避免误 startService 复活已停止的服务） */
        fun isRunning(): Boolean = instance != null

        /** MainActivity 授权完成后注入 MediaProjection token（静态转发到服务实例） */
        fun onProjectionResult(resultCode: Int, data: Intent?) {
            instance?.handleProjectionResult(resultCode, data)
        }
    }

    private var windowManager: WindowManager? = null
    private var rootView: LinearLayout? = null
    private var micButton: View? = null
    private var musicNoteIconView: MusicNoteIconView? = null
    private var resultPanel: LinearLayout? = null
    private var songNameText: TextView? = null
    private var artistText: TextView? = null
    private var params: WindowManager.LayoutParams? = null

    // 底部"拖到这里关闭"区域（独立 overlay，不可触摸）
    private var closeZoneView: View? = null
    private var closeZoneIcon: ImageView? = null
    private var closeZoneParams: WindowManager.LayoutParams? = null
    private var isOverCloseZone = false

    // touch/drag — 全方向拖动
    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false
    private var dragStartTime = 0L

    // 状态机
    private var state = STATE_IDLE
    private var pendingCapture = false // 等待投影授权

    // 采集资源
    private var projectionResultCode = 0
    private var projectionData: Intent? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    @Volatile
    private var captureThread: Thread? = null
    private val captureLock = Object()
    @Volatile
    private var stopRequested = false
    private var continueAllowed = false

    // 识别中音符图标旋转动画
    private var spinAnimator: ObjectAnimator? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var captureReleased = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        // 先以 specialUse 类型启动前台服务（仅悬浮窗，不要求 MediaProjection 授权）。
        // Android 14+ 若在授权前就以 mediaProjection 类型 startForeground，系统会检查
        // PROJECT_MEDIA 权限——该权限须经 createScreenCaptureIntent 授权后才授予，
        // 未授权时 Android 15+ 直接抛 SecurityException（"Starting FGS with type
        // mediaProjection ... requires permissions ... PROJECT_MEDIA"）。
        // 授权成功后由 promoteToMediaProjectionType() 切换为 mediaProjection 类型。
        // Android 10~13 无此检查，可直接以 mediaProjection 类型启动。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }
        createFloatingView()
        createCloseZone()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> requestRecognition()
            ACTION_CONTINUE -> requestContinueCapture()
            ACTION_STOP_CAPTURE -> stopCapture()
            ACTION_SET_RESULT -> showResult(intent.getStringExtra(EXTRA_RESULT) ?: "")
            ACTION_SET_STATUS -> showStatus(intent.getStringExtra(EXTRA_STATUS) ?: "")
            ACTION_SET_THEME -> setThemeColors(intent)
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    // ===================== 悬浮窗 UI（MD3E 设计语言） =====================
    //
    // 色板参考 MD3E 深色主题 token：
    //   surfaceContainer      #1D1B20（面板背景）
    //   surfaceContainerHigh  #26242B（按钮空闲底）
    //   onSurface             #E6E0E9 / onSurfaceVariant #CAC4D0
    //   primary               #D0BCFF（聆听中）/ onPrimary #381E72
    //   tertiary              #EFB8C8（识别中）/ onTertiary #492532
    //   primaryContainer      #EADDFF（结果）/ onPrimaryContainer #21005D
    // 形状：按钮全圆，面板 24dp 大圆角（MD3E expressive）
    // 动效：聆听中 spring 脉冲缩放，结果面板淡入上滑

    // 主题色：默认 MD3E 深色 token，Dart 侧推送设置页莫奈/动态取色（setThemeColors）后覆盖。
    // 悬浮窗 UI 全部使用以下字段，保证配色与 App 主题一致。
    private var cBtnIdleBg = 0xFF26242B.toInt()
    private var cOnSurface = 0xFFE6E0E9.toInt()
    private var cOnSurfaceVariant = 0xFFCAC4D0.toInt()
    private var cListeningBg = 0xFFD0BCFF.toInt()
    private var cListeningIcon = 0xFF381E72.toInt()
    private var cRecognizingBg = 0xFFEFB8C8.toInt()
    private var cRecognizingIcon = 0xFF492532.toInt()
    private var cResultBg = 0xFFEADDFF.toInt()
    private var cResultIcon = 0xFF21005D.toInt()
    private var cPanelBg = 0xF21D1B20.toInt()
    private var cPanelStroke = 0x4049454F.toInt()

    // 面板/播放按钮背景引用：setThemeColors 时刷新
    private var panelBgGd: GradientDrawable? = null
    private var playBtnBgGd: GradientDrawable? = null

    private fun createFloatingView() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val root = rootView as LinearLayout

        // 折叠态：圆形麦克风按钮（Canvas 绘制音符图标）
        micButton = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val size = dp(64)
            layoutParams = LinearLayout.LayoutParams(size, size)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(cBtnIdleBg)
            }
            // 悬浮窗级投影（API 21+）：深色半透明
            elevation = dp(6).toFloat()
        }
        val btn = micButton as LinearLayout
        musicNoteIconView = MusicNoteIconView(this).apply {
            setIconColor(cOnSurface)
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(34))
        }
        btn.addView(musicNoteIconView)
        root.addView(micButton)

        // 结果态：MD3E 大圆角 surfaceContainer 面板
        resultPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
            alpha = 0f
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(cPanelBg)
                setStroke(dp(1), cPanelStroke)
            }.also { panelBgGd = it }
            setPadding(dp(20), dp(16), dp(20), dp(14))
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.topMargin = dp(10)
            layoutParams = lp
        }
        val panel = resultPanel as LinearLayout

        // 歌名/歌手：点击文字直接播放（不触发 rootView 的收起/拖动逻辑）
        songNameText = TextView(this).apply {
            setTextColor(cOnSurface)
            textSize = sp(14f)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            setOnClickListener { sendToDart("onFloatingAction", "play") }
        }
        artistText = TextView(this).apply {
            setTextColor(cOnSurfaceVariant)
            textSize = sp(12f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            setPadding(0, dp(3), 0, 0)
            setOnClickListener { sendToDart("onFloatingAction", "play") }
        }
        panel.addView(songNameText)
        panel.addView(artistText)

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, 0)
        }
        // 播放：primaryContainer 圆形按钮；关闭：透明 + onSurfaceVariant 图标
        val playBtn = makeCircleIconButton(android.R.drawable.ic_media_play, cResultBg, cResultIcon) {
            sendToDart("onFloatingAction", "play")
        }
        (playBtn.background as? GradientDrawable)?.let { playBtnBgGd = it }
        val closeBtn = makeCircleIconButton(
            android.R.drawable.ic_menu_close_clear_cancel,
            Color.TRANSPARENT,
            cOnSurfaceVariant
        ) {
            dismissResult()
        }
        val rowLp = LinearLayout.LayoutParams(dp(44), dp(44))
        rowLp.setMargins(dp(8), 0, dp(8), 0)
        buttonRow.addView(playBtn, rowLp)
        buttonRow.addView(closeBtn, LinearLayout.LayoutParams(dp(44), dp(44)))
        panel.addView(buttonRow)

        root.addView(resultPanel)

        setupTouchListener(root)

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
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = dp(120)
        }

        windowManager?.addView(rootView, params)
    }

    /// MD3E 圆形图标按钮（全圆形状，可配置底色/图标色/尺寸）
    private fun makeCircleIconButton(
        resId: Int,
        bgColor: Int,
        iconColor: Int,
        onClick: () -> Unit
    ): ImageView {
        return ImageView(this).apply {
            setImageResource(resId)
            setColorFilter(iconColor)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(bgColor)
            }
            setPadding(dp(11), dp(11), dp(11), dp(11))
            setOnClickListener { onClick() }
        }
    }

    // ===================== 底部拖拽关闭区域 =====================

    /// 屏幕底部"拖到这里关闭"提示条（独立 overlay，点击穿透）。
    /// 红色大垃圾桶图标居中；拖动悬浮窗过程中显示；拖入区域背景高亮，松手即关闭服务。
    private fun createCloseZone() {
        val wm = windowManager ?: return
        val zone = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(0xE61D1B20.toInt())
                // 顶部大圆角，底部贴边
                cornerRadii = floatArrayOf(
                    dp(24).toFloat(), dp(24).toFloat(),
                    dp(24).toFloat(), dp(24).toFloat(),
                    0f, 0f, 0f, 0f
                )
            }
            setPadding(0, dp(8), 0, 0)
        }
        closeZoneIcon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_delete)
            // 常驻 error 红（MD3E 深色主题 error #FFB4AB）
            setColorFilter(0xFFFFB4AB.toInt())
            val s = dp(40)
            layoutParams = LinearLayout.LayoutParams(s, s)
        }
        zone.addView(closeZoneIcon)
        closeZoneView = zone

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        closeZoneParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            dp(110),
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM
            x = 0
            y = 0
        }
        wm.addView(zone, closeZoneParams)
        zone.visibility = View.GONE
    }

    private fun showCloseZone() {
        closeZoneView?.let { z ->
            if (z.visibility != View.VISIBLE) {
                z.visibility = View.VISIBLE
                z.alpha = 0f
                z.animate().alpha(1f).setDuration(160).start()
            }
        }
    }

    private fun hideCloseZone() {
        closeZoneView?.let { z ->
            z.animate().cancel()
            z.visibility = View.GONE
            resetCloseZoneHighlight()
        }
    }

    private fun setCloseZoneHighlight(on: Boolean) {
        if (isOverCloseZone == on) return
        isOverCloseZone = on
        val gd = closeZoneView?.background as? GradientDrawable ?: return
        // 拖入：背景 error 红高亮；移出：恢复深色
        gd.setColor(if (on) 0xE6B3261E.toInt() else 0xE61D1B20.toInt())
        if (on) {
            // 拖入关闭区域：轻微震动提示即将删除
            vibrate(40, 120)
        }
    }

    private fun resetCloseZoneHighlight() {
        isOverCloseZone = false
        val gd = closeZoneView?.background as? GradientDrawable ?: return
        gd.setColor(0xE61D1B20.toInt())
    }

    /// 震动反馈（API 26+ 用振幅，低版本回退 vibrate）。
    private fun vibrate(durationMs: Long, amplitude: Int) {
        val vibrator = getSystemService(VIBRATOR_SERVICE) as? Vibrator ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(durationMs, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(durationMs)
        }
    }

    /// 悬浮窗拖动中：判断悬浮窗底部是否进入关闭区域 → 高亮
    private fun updateCloseZoneHighlight() {
        val zone = closeZoneView ?: return
        val root = rootView ?: return
        val zoneLoc = IntArray(2)
        val rootLoc = IntArray(2)
        zone.getLocationOnScreen(zoneLoc)
        root.getLocationOnScreen(rootLoc)
        val rootBottom = rootLoc[1] + root.height
        setCloseZoneHighlight(rootBottom >= zoneLoc[1])
    }

    /// 拖动 + 点击判定（结果面板按钮区域触摸被按钮自身拦截，不触发拖动）
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
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
                        isDragging = true
                    }
                    if (isDragging) {
                        // 拖动时显示底部关闭区域并检测是否拖入
                        showCloseZone()
                        params?.x = initialX + dx.toInt()
                        params?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(rootView, params)
                        updateCloseZoneHighlight()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val shouldClose = isOverCloseZone
                    hideCloseZone()
                    if (shouldClose) {
                        // 拖入底部关闭区域：震动反馈后关闭悬浮窗服务
                        vibrate(120, 220)
                        stopSelf()
                        return@setOnTouchListener true
                    }
                    if (!isDragging && System.currentTimeMillis() - dragStartTime < 300) {
                        view.performClick()
                        onMicClick()
                    }
                    isDragging = false
                    true
                }
                else -> false
            }
        }
    }

    // ===================== 状态与交互 =====================

    private fun onMicClick() {
        when (state) {
            STATE_IDLE -> requestRecognition()
            STATE_RESULT -> dismissResult()
            else -> {} // LISTENING / RECOGNIZING 时忽略点击
        }
    }

    /// 请求开始一轮识别：先走 MediaProjection 授权（Dart → MainActivity）
    private fun requestRecognition() {
        if (Build.VERSION.SDK_INT < 29) {
            toast("仅支持 Android 10 及以上")
            return
        }
        if (pendingCapture || captureThread != null) return
        pendingCapture = true
        setState(STATE_LISTENING)
        sendToDart("onFloatingAction", "start")
    }

    /// 收起结果面板，回到按钮态（可再次识别）
    private fun dismissResult() {
        setState(STATE_IDLE)
    }

    private fun handleProjectionResult(resultCode: Int, data: Intent?) {
        if (resultCode != android.app.Activity.RESULT_OK || data == null) {
            pendingCapture = false
            setState(STATE_IDLE)
            toast("未授权，无法捕获系统音频")
            sendToDart("onProjectionResult", false)
            return
        }
        projectionResultCode = resultCode
        projectionData = data
        // 授权成功后把前台服务类型切换到 mediaProjection：Android 14+ 要求
        // getMediaProjection 前 FGS 运行时类型包含 mediaProjection，且此时
        // PROJECT_MEDIA 已由 createScreenCaptureIntent 授权授予，startForeground
        // 才能通过校验（Android 15+ 必须在授权后切换，否则 SecurityException）。
        promoteToMediaProjectionType()
        sendToDart("onProjectionResult", true)
        beginCaptureIfReady()
    }

    /// 把前台服务运行时类型从 specialUse 切换为 mediaProjection（授权成功后调用）。
    private fun promoteToMediaProjectionType() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        try {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
            Log.i(TAG, "promoteToMediaProjectionType: OK")
        } catch (e: Exception) {
            Log.e(TAG, "promoteToMediaProjectionType failed", e)
        }
    }

    /// 授权就绪后开始采集（首次）；已采集时跳过
    @Synchronized
    private fun beginCaptureIfReady() {
        if (!pendingCapture || projectionData == null) return
        if (captureThread != null) return
        pendingCapture = false
        captureReleased = false
        if (!createCapture()) {
            setState(STATE_IDLE)
            toast("无法捕获该音频，请重试")
            return
        }
        setState(STATE_LISTENING)
        captureThread = Thread { captureLoop() }.apply { start() }
    }

    @Synchronized
    private fun createCapture(): Boolean {
        if (Build.VERSION.SDK_INT < 29) {
            Log.e(TAG, "createCapture: SDK < 29")
            return false
        }
        try {
            val pm = getSystemService(MediaProjectionManager::class.java)
            val data = projectionData ?: run {
                Log.e(TAG, "createCapture: projectionData null")
                return false
            }
            val mp = pm.getMediaProjection(projectionResultCode, data) ?: run {
                Log.e(TAG, "createCapture: getMediaProjection null")
                return false
            }
            // Android 14+（API 34+）硬性要求：MediaProjection.start() 前必须注册
            // Callback，否则 AudioRecord.startRecording() 触发 start() 时抛
            // RemoteException（"MediaProjectionCallback must be registered"）。
            mp.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection onStop")
                }
            }, mainHandler)
            mediaProjection = mp

            val config = AudioPlaybackCaptureConfiguration.Builder(mp)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val rec = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minBuf, SEGMENT_BYTES))
                .build()
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "createCapture: AudioRecord state=${rec.state} (expected INITIALIZED)")
                return false
            }
            audioRecord = rec
            try {
                rec.startRecording()
            } catch (e: Exception) {
                Log.e(TAG, "createCapture: startRecording failed", e)
                return false
            }
            Log.i(TAG, "createCapture: OK, ${SAMPLE_RATE}Hz, buffer=${maxOf(minBuf, SEGMENT_BYTES)}")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "createCapture: exception", e)
            return false
        }
    }

    /// 采集线程：每 8s 一段回调 Dart，然后阻塞等待 continue/stop
    private fun captureLoop() {
        val recorder = audioRecord ?: return
        val buf = ByteArray(SEGMENT_BYTES)
        stopRequested = false
        while (!stopRequested) {
            var offset = 0
            while (offset < buf.size && !stopRequested) {
                val n = recorder.read(buf, offset, buf.size - offset)
                if (n > 0) {
                    offset += n
                } else if (n < 0) {
                    Log.e(TAG, "captureLoop: read error n=$n at offset=$offset")
                    break
                }
            }
            if (stopRequested) break
            if (offset < buf.size) {
                Log.e(TAG, "captureLoop: short read offset=$offset (expected ${buf.size}), stopping")
                break
            }

            // 一段（8s）采集完成，交给 Dart 识别
            Log.i(TAG, "captureLoop: segment ready, sending onSegmentCaptured")
            setState(STATE_RECOGNIZING)
            sendToDart("onSegmentCaptured", buf)

            // 等待 Dart 决定：continueCapture 继续 / stopCapture 停止
            synchronized(captureLock) {
                while (!stopRequested && !continueAllowed) {
                    try {
                        captureLock.wait()
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                Log.i(TAG, "captureLoop: resumed stop=$stopRequested continue=$continueAllowed")
                continueAllowed = false
            }
        }
        Log.i(TAG, "captureLoop: exit, releasing")
        releaseCapture()
    }

    @Synchronized
    private fun requestContinueCapture() {
        synchronized(captureLock) {
            continueAllowed = true
            captureLock.notifyAll()
        }
        setState(STATE_LISTENING)
    }

    @Synchronized
    private fun stopCapture() {
        synchronized(captureLock) {
            stopRequested = true
            captureLock.notifyAll()
        }
    }

    @Synchronized
    private fun releaseCapture() {
        if (captureReleased) return
        captureReleased = true
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null
        projectionData = null
        projectionResultCode = 0
        captureThread = null
        stopRequested = false
        continueAllowed = false
        // 命中结果后 stopCapture 也会走到这里：保持 RESULT 面板显示，
        // 只有未命中/空闲时才回按钮态
        if (state != STATE_RESULT) {
            setState(STATE_IDLE)
        }
    }

    /// Dart 识别命中：显示歌名/歌手 + 播放按钮
    /// 在 onStartCommand（主线程）同步更新状态：setState 立即写 state 字段，
    /// 避免与 releaseCapture 的 IDLE 重置竞态（若走 post 可能先 RESULT 后 IDLE）
    private fun showResult(resultJson: String) {
        try {
            val obj = JSONObject(resultJson)
            val name = obj.optString("songName", "").ifEmpty { "未知歌曲" }
            val artist = obj.optString("artist", "")
            songNameText?.text = name
            artistText?.text = artist
            artistText?.visibility = if (artist.isEmpty()) View.GONE else View.VISIBLE
            setState(STATE_RESULT)
        } catch (_: Exception) {}
    }

    /// Dart 状态提示（未识别/失败等），Toast 展示
    private fun showStatus(status: String) {
        if (status.isNotEmpty()) toast(status)
    }

    /// 接收 Dart 推送的主题色（设置页莫奈/动态取色），刷新悬浮窗配色
    /// 注意：Dart int（64 位）经 MethodChannel 到 Android 解码为 Long，
    /// 这里用 Number 接收并 toInt()，避免 Long→Integer ClassCastException
    private fun setThemeColors(intent: Intent) {
        @Suppress("UNCHECKED_CAST")
        val map = intent.getSerializableExtra(EXTRA_THEME_COLORS) as? HashMap<String, Number> ?: return
        map["surfaceContainerHighest"]?.toInt()?.let { cBtnIdleBg = it }
        map["onSurface"]?.toInt()?.let { cOnSurface = it }
        map["onSurfaceVariant"]?.toInt()?.let { cOnSurfaceVariant = it }
        map["primary"]?.toInt()?.let { cListeningBg = it }
        map["onPrimary"]?.toInt()?.let { cListeningIcon = it }
        map["tertiary"]?.toInt()?.let { cRecognizingBg = it }
        map["onTertiary"]?.toInt()?.let { cRecognizingIcon = it }
        map["primaryContainer"]?.toInt()?.let { cResultBg = it }
        map["onPrimaryContainer"]?.toInt()?.let { cResultIcon = it }
        map["surfaceContainer"]?.toInt()?.let { cPanelBg = it }
        map["outlineVariant"]?.toInt()?.let { cPanelStroke = it }
        mainHandler.post {
            // 刷新面板/按钮静态配色
            panelBgGd?.setColor(cPanelBg)
            panelBgGd?.setStroke(dp(1), cPanelStroke)
            playBtnBgGd?.setColor(cResultBg)
            songNameText?.setTextColor(cOnSurface)
            artistText?.setTextColor(cOnSurfaceVariant)
            // 刷新按钮/图标动态配色
            updateUi()
        }
    }

    private fun setState(newState: Int) {
        if (state == newState) return
        state = newState
        mainHandler.post { updateUi() }
    }

    private fun updateUi() {
        val btn = micButton ?: return
        val panel = resultPanel ?: return
        val gd = btn.background as? GradientDrawable ?: return
        val icon = musicNoteIconView ?: return
        when (state) {
            STATE_IDLE -> {
                gd.setColor(cBtnIdleBg)
                icon.setIconColor(cOnSurface)
                panel.visibility = View.GONE
                stopSpin()
            }
            STATE_LISTENING -> {
                gd.setColor(cListeningBg)
                icon.setIconColor(cListeningIcon)
                panel.visibility = View.GONE
                startSpin()
            }
            STATE_RECOGNIZING -> {
                gd.setColor(cRecognizingBg)
                icon.setIconColor(cRecognizingIcon)
                panel.visibility = View.GONE
                stopSpin()
            }
            STATE_RESULT -> {
                gd.setColor(cResultBg)
                icon.setIconColor(cResultIcon)
                showResultPanel()
                stopSpin()
            }
        }
    }

    /// 结果面板 MD3E 淡入上滑动效
    private fun showResultPanel() {
        val panel = resultPanel ?: return
        panel.visibility = View.VISIBLE
        panel.alpha = 0f
        panel.translationY = dp(10).toFloat()
        panel.animate()
            .alpha(1f)
            .translationY(0f)
            .setDuration(260)
            .setInterpolator(DecelerateInterpolator())
            .start()
    }

    /// 聆听中：音符图标匀速旋转（识别中不停）
    private fun startSpin() {
        stopSpin()
        val icon = musicNoteIconView ?: return
        icon.pivotX = icon.width / 2f
        icon.pivotY = icon.height / 2f
        spinAnimator = ObjectAnimator.ofFloat(icon, "rotation", 0f, 360f).apply {
            duration = 1200
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            start()
        }
    }

    private fun stopSpin() {
        spinAnimator?.cancel()
        spinAnimator = null
        musicNoteIconView?.rotation = 0f
    }

    // ===================== 通知 =====================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "悬浮窗识曲",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "悬浮窗听歌识曲"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val startIntent = Intent(this, FloatingRecognitionService::class.java).apply { action = ACTION_START }
        val startPendingIntent = PendingIntent.getService(
            this, 0, startIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, FloatingRecognitionService::class.java).apply { action = ACTION_STOP }
        val stopPendingIntent = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MD3Music 悬浮窗识曲")
            .setContentText("点击悬浮窗按钮识别正在播放的音乐")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_play, "开始识别", startPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "关闭", stopPendingIntent)
            .build()
    }

    // ===================== 工具 =====================

    private fun sendToDart(method: String, args: Any?) {
        // MethodChannel.invokeMethod 必须主线程执行（@UiThread），采集线程需切主线程
        mainHandler.post {
            val engine = FlutterEngineCache.getInstance().get("md3music_engine")
            if (engine != null) {
                try {
                    MethodChannel(engine.dartExecutor.binaryMessenger, DART_CHANNEL)
                        .invokeMethod(method, args)
                } catch (e: Exception) {
                    Log.e(TAG, "sendToDart($method) failed: $e")
                }
            } else {
                Log.e(TAG, "sendToDart($method): FlutterEngineCache has no md3music_engine")
            }
        }
    }

    private fun toast(msg: String) {
        mainHandler.post {
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun sp(v: Float): Float = v * resources.displayMetrics.scaledDensity

    override fun onDestroy() {
        super.onDestroy()
        // 停止采集线程并回收资源
        synchronized(captureLock) {
            stopRequested = true
            captureLock.notifyAll()
        }
        releaseCapture()
        rootView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        closeZoneView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        // 通知 Dart 服务已停止，同步悬浮窗开关状态（避免 Dart 误以为仍在运行）
        sendToDart("onServiceStopped", null)
        instance = null
    }
}

/// Canvas 绘制的音符图标（八分音符：符头椭圆 + 符杆 + 符尾旗）。
/// 颜色可配置，随悬浮窗状态切换；识别中由外部 ObjectAnimator 旋转。
class MusicNoteIconView(context: android.content.Context) : View(context) {
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val stemPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val path = Path()
    private var iconColor = Color.WHITE

    fun setIconColor(color: Int) {
        if (iconColor != color) {
            iconColor = color
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return
        fillPaint.color = iconColor
        stemPaint.color = iconColor
        stemPaint.strokeWidth = w * 0.08f
        path.reset()

        // 符头：略微倾斜的椭圆（左上方向）
        canvas.save()
        canvas.rotate(-15f, w * 0.30f, h * 0.74f)
        canvas.drawOval(w * 0.19f, h * 0.62f, w * 0.41f, h * 0.86f, fillPaint)
        canvas.restore()

        // 符杆：从符头右上竖直向上
        canvas.drawLine(w * 0.41f, h * 0.72f, w * 0.41f, h * 0.16f, stemPaint)

        // 符尾旗：从符杆顶端向下弯曲（两次贝塞尔）
        path.moveTo(w * 0.41f, h * 0.16f)
        path.quadTo(w * 0.63f, h * 0.26f, w * 0.50f, h * 0.44f)
        path.quadTo(w * 0.44f, h * 0.54f, w * 0.53f, h * 0.62f)
        canvas.drawPath(path, stemPaint)
    }
}
