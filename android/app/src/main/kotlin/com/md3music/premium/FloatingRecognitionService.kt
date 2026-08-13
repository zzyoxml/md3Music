package com.md3music.premium

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
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
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
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
        const val ACTION_START = "com.md3music.premium.RECOG_START"
        const val ACTION_STOP = "com.md3music.premium.RECOG_STOP"
        const val ACTION_CONTINUE = "com.md3music.premium.RECOG_CONTINUE"
        const val ACTION_STOP_CAPTURE = "com.md3music.premium.RECOG_STOP_CAPTURE"
        const val ACTION_SET_RESULT = "com.md3music.premium.RECOG_SET_RESULT"
        const val ACTION_SET_STATUS = "com.md3music.premium.RECOG_SET_STATUS"
        const val EXTRA_RESULT = "result"
        const val EXTRA_STATUS = "status"
        const val DART_CHANNEL = "com.md3music.premium/floating_recognition"

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

        /** MainActivity 授权完成后注入 MediaProjection token（静态转发到服务实例） */
        fun onProjectionResult(resultCode: Int, data: Intent?) {
            instance?.handleProjectionResult(resultCode, data)
        }
    }

    private var windowManager: WindowManager? = null
    private var rootView: LinearLayout? = null
    private var micButton: View? = null
    private var resultPanel: LinearLayout? = null
    private var songNameText: TextView? = null
    private var artistText: TextView? = null
    private var params: WindowManager.LayoutParams? = null

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

    private var pulseAnimation: Animation? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var captureReleased = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        // Android 14+：MediaProjection 要求前台服务运行时类型包含 mediaProjection，
        // startForeground 必须显式声明该类型，否则 getMediaProjection 抛 SecurityException
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }
        createFloatingView()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> requestRecognition()
            ACTION_CONTINUE -> requestContinueCapture()
            ACTION_STOP_CAPTURE -> stopCapture()
            ACTION_SET_RESULT -> showResult(intent.getStringExtra(EXTRA_RESULT) ?: "")
            ACTION_SET_STATUS -> showStatus(intent.getStringExtra(EXTRA_STATUS) ?: "")
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    // ===================== 悬浮窗 UI =====================

    private fun createFloatingView() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val root = rootView as LinearLayout

        // 折叠态：圆形麦克风按钮
        micButton = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val size = dp(64)
            layoutParams = LinearLayout.LayoutParams(size, size)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xCC333333.toInt())
            }
            val mic = TextView(this@FloatingRecognitionService).apply {
                text = "🎤"
                textSize = 26f
                gravity = Gravity.CENTER
            }
            addView(mic, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        root.addView(micButton)

        // 结果态：歌名/歌手 + 播放/关闭按钮
        resultPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(0xE6202020.toInt())
            }
            setPadding(dp(18), dp(12), dp(18), dp(10))
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.topMargin = dp(8)
            layoutParams = lp
        }
        val panel = resultPanel as LinearLayout

        songNameText = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
        }
        artistText = TextView(this).apply {
            setTextColor(0xFFAAAAAA.toInt())
            textSize = 11f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            setPadding(0, dp(2), 0, 0)
        }
        panel.addView(songNameText)
        panel.addView(artistText)

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, 0)
        }
        val playBtn = makeIconButton(android.R.drawable.ic_media_play) {
            sendToDart("onFloatingAction", "play")
        }
        val closeBtn = makeIconButton(android.R.drawable.ic_menu_close_clear_cancel) {
            dismissResult()
        }
        buttonRow.addView(playBtn)
        buttonRow.addView(closeBtn)
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

    private fun makeIconButton(resId: Int, onClick: () -> Unit): ImageView {
        return ImageView(this).apply {
            setImageResource(resId)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            setColorFilter(Color.WHITE)
            setOnClickListener { onClick() }
        }
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
                        params?.x = initialX + dx.toInt()
                        params?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(rootView, params)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
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
        sendToDart("onProjectionResult", true)
        beginCaptureIfReady()
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

    private fun setState(newState: Int) {
        if (state == newState) return
        state = newState
        mainHandler.post { updateUi() }
    }

    private fun updateUi() {
        val btn = micButton ?: return
        val panel = resultPanel ?: return
        val gd = btn.background as? GradientDrawable ?: return
        when (state) {
            STATE_IDLE -> {
                gd.setColor(0xCC333333.toInt())
                panel.visibility = View.GONE
                stopPulse()
            }
            STATE_LISTENING -> {
                gd.setColor(0xE53935)
                panel.visibility = View.GONE
                startPulse()
            }
            STATE_RECOGNIZING -> {
                gd.setColor(0xF59E0B)
                panel.visibility = View.GONE
                stopPulse()
            }
            STATE_RESULT -> {
                gd.setColor(0xCC333333.toInt())
                panel.visibility = View.VISIBLE
                stopPulse()
            }
        }
    }

    private fun startPulse() {
        stopPulse()
        val anim = AlphaAnimation(1f, 0.35f).apply {
            duration = 600
            repeatCount = Animation.INFINITE
            repeatMode = Animation.REVERSE
            fillAfter = true
        }
        micButton?.startAnimation(anim)
        pulseAnimation = anim
    }

    private fun stopPulse() {
        pulseAnimation?.cancel()
        micButton?.clearAnimation()
        pulseAnimation = null
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
        instance = null
    }
}
