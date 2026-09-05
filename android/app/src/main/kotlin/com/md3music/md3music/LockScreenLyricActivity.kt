package com.md3music.md3music

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Choreographer
import android.view.View
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs
import kotlin.math.exp

/// 锁屏歌词逐字单元。
class LockLyricWord(val text: String, val startMs: Long, val durMs: Long)

/// 锁屏歌词单行：整行文本 + 预拆分逐字（可为空）+ 副行文本（翻译/罗马音，由 Dart 侧按模式选好）。
class LockLyricLine(
    val text: String,
    val startMs: Long,
    val durMs: Long,
    val words: List<LockLyricWord>,
    val sub: String,
)

/// 锁屏歌词整屏数据快照（跨组件共享的不可变值对象）。
///
/// 协议对齐 Dart `MediaNotificationService`：
/// - `updateLockScreenLyricData`：整首歌词 + 样式一次推送 → `applyDataCall`
/// - `updateLockScreenProgress`：500ms 节流轻量进度 → `applyProgressCall`
/// - `updateLockScreenAccent`：封面主色异步提取完成 → `applyAccentCall`
data class LockScreenLyricData(
    val lines: List<LockLyricLine> = emptyList(),
    val placeholder: String = "",
    val currentPositionMs: Long = 0L,
    val durationMs: Long = 0L,
    val isPlaying: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val artUrl: String? = null,
    val fallbackFilePath: String? = null,
    val fontSize: Float = 15f,
    val fontWeight: Int = 500,
    val lineHeightMultiplier: Float = 1.5f,
    val fontSource: Int = 0,
    val customFontPath: String? = null,
    val showTranslation: Boolean = true,
    val displayMode: Int = 0,
    val useDynamicColor: Boolean = true,
    val accentColor: Int = 0,
)

/// 锁屏歌词 Activity：全屏覆盖在锁屏上方，渲染 AM 对齐的全屏滚动歌词列表。
class LockScreenLyricActivity : Activity() {

    companion object {
        private const val ACTION_USER_PRESENT = Intent.ACTION_USER_PRESENT

        @Volatile
        private var data = LockScreenLyricData()

        @Volatile
        private var runningActivity: LockScreenLyricActivity? = null

        fun currentData(): LockScreenLyricData = data

        /// 整包数据推送（切歌 / 歌词就绪 / 样式变化）。由 MainActivity / AudioPlaybackService 转发。
        fun applyDataCall(call: MethodCall) {
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val lines = mutableListOf<LockLyricLine>()
            val rawLines = args["lines"] as? List<*> ?: emptyList<Any?>()
            for (rawAny in rawLines) {
                if (rawAny is Map<*, *>) lines.add(parseLine(rawAny))
            }
            data = LockScreenLyricData(
                lines = lines,
                placeholder = args["placeholder"] as? String ?: "",
                currentPositionMs = (args["currentPositionMs"] as? Number)?.toLong() ?: 0L,
                durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0L,
                isPlaying = args["isPlaying"] as? Boolean ?: false,
                title = args["title"] as? String ?: "",
                artist = args["artist"] as? String ?: "",
                artUrl = args["artUrl"] as? String,
                fallbackFilePath = args["fallbackFilePath"] as? String,
                fontSize = (args["fontSize"] as? Number)?.toFloat() ?: 15f,
                fontWeight = (args["fontWeight"] as? Number)?.toInt() ?: 500,
                lineHeightMultiplier = (args["lineHeightMultiplier"] as? Number)?.toFloat() ?: 1.5f,
                fontSource = (args["fontSource"] as? Number)?.toInt() ?: 0,
                customFontPath = args["customFontPath"] as? String,
                showTranslation = args["showTranslation"] as? Boolean ?: true,
                displayMode = (args["displayMode"] as? Number)?.toInt() ?: 0,
                useDynamicColor = args["useDynamicColor"] as? Boolean ?: true,
                accentColor = data.accentColor, // 保留上次强调色，避免整包推送清空动态取色
            )
            runningActivity?.postDataUpdate()
        }

        private fun parseLine(raw: Map<*, *>): LockLyricLine {
            val text = raw["text"] as? String ?: ""
            val start = (raw["start"] as? Number)?.toLong() ?: 0L
            val dur = (raw["duration"] as? Number)?.toLong() ?: 0L
            val rawWords = raw["words"] as? List<*> ?: emptyList<Any?>()
            val rawStarts = raw["wordStarts"] as? List<*> ?: emptyList<Any?>()
            val rawDurs = raw["wordDurations"] as? List<*> ?: emptyList<Any?>()
            val words = ArrayList<LockLyricWord>(rawWords.size)
            for (i in rawWords.indices) {
                val wText = rawWords[i] as? String ?: continue
                words.add(
                    LockLyricWord(
                        wText,
                        (rawStarts.getOrNull(i) as? Number)?.toLong() ?: 0L,
                        (rawDurs.getOrNull(i) as? Number)?.toLong() ?: 0L,
                    )
                )
            }
            return LockLyricLine(text, start, dur, words, raw["sub"] as? String ?: "")
        }

        /// 轻量进度更新：只改位置/时长/播放态，不触碰歌词与测量缓存。
        fun applyProgressCall(call: MethodCall) {
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val d = data
            data = d.copy(
                currentPositionMs = (args["currentPositionMs"] as? Number)?.toLong() ?: d.currentPositionMs,
                durationMs = (args["durationMs"] as? Number)?.toLong() ?: d.durationMs,
                isPlaying = args["isPlaying"] as? Boolean ?: d.isPlaying,
            )
            runningActivity?.postProgressUpdate()
        }

        /// 封面主色推送：仅更新动态取色强调色。
        fun applyAccentCall(call: MethodCall) {
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val d = data
            data = d.copy(accentColor = (args["accentColor"] as? Number)?.toInt() ?: 0)
            runningActivity?.postDataUpdate()
        }

        fun start(context: Context) {
            android.util.Log.i("LockScreenLyric", "start() called, running=${runningActivity != null}")
            if (runningActivity != null) return
            try {
                val intent = Intent(context, LockScreenLyricActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                context.startActivity(intent)
                android.util.Log.i("LockScreenLyric", "startActivity ok")
            } catch (e: Exception) {
                android.util.Log.e("LockScreenLyric", "startActivity failed: $e")
            }
        }

        fun dismiss() {
            android.util.Log.i("LockScreenLyric", "dismiss() called")
            val act = runningActivity ?: return
            runningActivity = null
            try {
                act.runOnUiThread { act.finish() }
            } catch (_: Exception) {}
        }
    }

    private lateinit var lyricView: LockScreenLyricView
    private var userPresentReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        android.util.Log.i("LockScreenLyric", "onCreate")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setTurnScreenOn(false)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)

        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LOW_PROFILE
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = 0x00000000
            window.navigationBarColor = 0x00000000
        }

        lyricView = LockScreenLyricView(this)
        setContentView(lyricView)
        runningActivity = this

        userPresentReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_USER_PRESENT) {
                    android.util.Log.i("LockScreenLyric", "user present, dismiss")
                    finish()
                }
            }
        }
        try {
            registerReceiver(userPresentReceiver, IntentFilter(ACTION_USER_PRESENT))
        } catch (_: Exception) {}

        lyricView.applyLatestData()
    }

    override fun onStart() {
        super.onStart()
        android.util.Log.i("LockScreenLyric", "onStart")
        lyricView.applyLatestData()
    }

    override fun onStop() {
        super.onStop()
        android.util.Log.i("LockScreenLyric", "onStop (stay alive)")
        lyricView.onScreenHidden()
    }

    override fun onDestroy() {
        runningActivity = null
        userPresentReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        userPresentReceiver = null
        try { lyricView.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun postDataUpdate() {
        if (::lyricView.isInitialized) {
            runOnUiThread { lyricView.applyLatestData() }
        }
    }

    private fun postProgressUpdate() {
        if (::lyricView.isInitialized) {
            runOnUiThread { lyricView.applyProgressOnly() }
        }
    }
}

/// 单行歌词渲染前测量结果（换行拆分 + 块高，文本/样式变化时重建一次）。
private class RenderedLine(
    val rowTexts: List<String>,   // 主文本换行后的视觉行文本
    val rowStarts: IntArray,      // 逐字行：每视觉行的起始 word 索引；纯文本行为空
    val hasWords: Boolean,
    val height: Float,            // 块高（含换行与副行空间）
)

/// 锁屏歌词 Canvas 滚动渲染视图（AM Apple Music 风格对齐）。
///
/// 布局规范对齐 `lyric_layout.dart`：
/// - 当前行在歌词可视带内居中（见 topInset / leaveHeadRoom），避开顶部歌曲名与底部进度条
/// - 换行行高 = 主行高 × 0.8；副行字号 = max(主字 × 0.7, 12)，透明 0.5
/// - 非当前行暗态 alpha 0.2，当前行亮 0.92；动态取色为「85% 白 + 15% 主色」
/// - 位置由 Choreographer 帧循环用系统时钟自增推进，向低频真实位置做慢速指数校正
///   （避免每次 Dart 500ms 推送引起速度抖动 / 卡顿）
class LockScreenLyricView(context: Context) : View(context) {

    private val wrapFactor = 0.8f
    private val transOpacity = 0.5f
    private val darkAlpha = 0.20f
    private val brightAlpha = 0.92f
    private val dimMixRatio = 0.15f
    // 位置校正速率：越低越平滑；仅吸收与真实播放位置的轻微漂移，不制造可见跳变
    private val corrRate = 5.0
    private val scrollRate = 30.0
    private val seekJumpMs = 800L

    private var headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xB3FFFFFF.toInt()
        textAlign = Paint.Align.CENTER
    }
    private var dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x4DFFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private var brightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private var transPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x80FFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private var placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x66FFFFFF.toInt()
        textAlign = Paint.Align.CENTER
    }
    private val progressBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x33FFFFFF.toInt() }
    private val progressFgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
    private val bgDrawPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    private var backgroundBitmap: Bitmap? = null
    private var loadingBackground = false
    private var lastArtUrl: String? = null
    private var lastFallbackPath: String? = null
    private var pendingArt: String? = null
    private var pendingFallback: String? = null
    private var renderedBg: Bitmap? = null
    private var renderedBgW = 0
    private var renderedBgH = 0
    private var renderedBgSource: Bitmap? = null

    private var curLines: List<LockLyricLine> = emptyList()
    private var placeholder = ""
    private var headerTitle = ""
    private var headerArtist = ""
    private var authoritativePosMs = 0L
    private var durationMs = 0L
    private var isPlayingFlag = false

    private var curSize = 15f
    private var curWeight = 500
    private var curLineMult = 1.5f
    private var curShowTrans = true
    private var curAccent = 0
    private var curUseDynamic = false
    private var curFontSource = 0
    private var curCustomFontPath: String? = null

    private var rendered = listOf<RenderedLine>()
    private var lineTop = FloatArray(0)
    private var lineAlpha = FloatArray(0)
    private var layoutWidth = -1f
    private var layoutFontSize = -1f
    private var layoutLineMult = -1f
    private var layoutTransEnabled = -1

    private var curWordWidths = FloatArray(0)
    private var curWordStarts = FloatArray(0)
    private var lastMaskLineIdx = -1

    private var smoothPosMs = 0.0
    private var smoothScrollY = 0f
    private var lastFrameMs = 0L
    private var lastAuthorityMs = 0L
    private var wasPlayingFlag = false

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val now = SystemClock.uptimeMillis()
            val dtMs = if (lastFrameMs > 0) (now - lastFrameMs).toDouble() else 16.0
            lastFrameMs = now
            val dtSec = dtMs / 1000.0
            if (isPlayingFlag) {
                // 时钟自增推进：即使 Dart 短暂未推进度也连续行走，避免高亮卡死
                smoothPosMs += dtMs
                // 向低频真实位置（authoritative + 流失时间）做慢速指数校正，吸收漂移且不外抖
                val target = (
                    authoritativePosMs + (now - lastAuthorityMs)
                    ).toDouble().coerceAtMost(durationMs.toDouble())
                val diff = target - smoothPosMs
                val k = 1.0 - exp(-corrRate * dtSec)
                smoothPosMs += diff * k
                if (abs(diff) < 0.5) smoothPosMs = target
                advanceScroll(dtSec)
                advanceLineAlpha(dtSec)
                invalidate()
            }
            // 只要 attached 就无条件维持帧循环；isPlayingFlag 决定是否推进/重绘。
            // 锁屏可见时帧循环持续存活，isPlaying 一旦为真立即恢复滚动，
            // 彻底消除「首次锁屏/切歌竞态导致 Choreographer 空档而卡死」。
            if (isAttachedToWindow) {
                Choreographer.getInstance().postFrameCallback(this)
            } else {
                frameRunning = false
            }
        }
    }
    private var frameRunning = false

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // 只要视图可见就保持帧循环运行；isPlayingFlag 决定是否推进/重绘。
        // 这保证首次锁屏/切歌与整包推送竞态导致 isPlaying 那一刻为 false 时，
        // 帧循环仍活着，isPlaying 一转 true 立即恢复滚动，而非卡死等待重启时机。
        startFrameLoop()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE) {
            startFrameLoop()
        } else {
            stopFrameLoop()
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        stopFrameLoop()
    }

    fun release() {
        stopFrameLoop()
        renderedBg?.let { if (!it.isRecycled) it.recycle() }
        renderedBg = null
    }

    fun onScreenHidden() {
        stopFrameLoop()
    }

    private fun startFrameLoop() {
        if (frameRunning) return
        frameRunning = true
        lastFrameMs = 0L
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun stopFrameLoop() {
        frameRunning = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    /// 整包数据应用：重建样式与布局缓存、去皮封面、按需吸附位置。
    fun applyLatestData() {
        val d = LockScreenLyricActivity.currentData()
        curLines = d.lines
        placeholder = d.placeholder
        headerTitle = d.title
        headerArtist = d.artist
        authoritativePosMs = d.currentPositionMs
        durationMs = d.durationMs
        isPlayingFlag = d.isPlaying
        curSize = d.fontSize
        curWeight = d.fontWeight
        curLineMult = d.lineHeightMultiplier
        curShowTrans = d.showTranslation
        curAccent = d.accentColor
        curUseDynamic = d.useDynamicColor && d.accentColor != 0
        curFontSource = d.fontSource
        curCustomFontPath = d.customFontPath

        rebuildTypeface()
        resetLayoutCache()

        if (!isPlayingFlag || abs(authoritativePosMs - smoothPosMs) > seekJumpMs || !wasPlayingFlag) {
            smoothPosMs = authoritativePosMs.toDouble()
        }
        lastAuthorityMs = SystemClock.uptimeMillis()
        wasPlayingFlag = isPlayingFlag
        lastFrameMs = SystemClock.uptimeMillis()
        // 只续不灭：帧循环的生命由可见性（onAttached/onWindowVisibility/onStop）统一管控，
        // 避免此处按 isPlaying 停表造成竞态卡死；isPlaying 由 doFrame 内部判读。
        if (isPlayingFlag) startFrameLoop()

        if (d.artUrl != lastArtUrl || d.fallbackFilePath != lastFallbackPath) {
            lastArtUrl = d.artUrl
            lastFallbackPath = d.fallbackFilePath
            loadBackgroundBitmap(d.artUrl, d.fallbackFilePath)
        }
        invalidate()
    }

    /// 轻量进度应用：只改位置/播放态，不动布局。播放中由帧循环驱动重绘，
    /// 不额外 invalidate，避免与帧循环形成双重无效重绘导致卡顿。
    /// 不在此停表：帧循环生命由可见性统一管控，isPlaying 翻转由 doFrame 即时读取。
    fun applyProgressOnly() {
        val d = LockScreenLyricActivity.currentData()
        authoritativePosMs = d.currentPositionMs
        durationMs = d.durationMs
        isPlayingFlag = d.isPlaying
        if (!isPlayingFlag || abs(authoritativePosMs - smoothPosMs) > seekJumpMs || !wasPlayingFlag) {
            smoothPosMs = authoritativePosMs.toDouble()
        }
        lastAuthorityMs = SystemClock.uptimeMillis()
        wasPlayingFlag = isPlayingFlag
        lastFrameMs = SystemClock.uptimeMillis()
        if (isPlayingFlag) {
            startFrameLoop()
        } else {
            invalidate() // 暂停：静态位置需刷新一帧（帧循环仍在，isPlaying 翻转即恢复滚动）
        }
    }

    private fun resetLayoutCache() {
        layoutWidth = -1f
        layoutFontSize = -1f
        layoutLineMult = -1f
        layoutTransEnabled = -1
        rendered = emptyList()
        lineTop = FloatArray(0)
        lineAlpha = FloatArray(0)
        curWordWidths = FloatArray(0)
        curWordStarts = FloatArray(0)
        lastMaskLineIdx = -1
    }

    private fun rebuildTypeface() {
        val weight = curWeight.coerceIn(300, 900)
        val baseTypeface = resolveTypeface(weight)
        val curPx = dp(curSize).coerceIn(dp(12f), dp(60f))
        val transPx = (dp(maxOf(curSize * 0.7f, 12f))).coerceAtLeast(dp(10f))
        val headerSize = dp(13f)

        headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xB3FFFFFF.toInt()
            textSize = headerSize
            textAlign = Paint.Align.CENTER
        }
        dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x4DFFFFFF.toInt()
            textSize = curPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        brightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt()
            textSize = curPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        transPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x80FFFFFF.toInt()
            textSize = transPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x66FFFFFF.toInt()
            textSize = dp(15f)
            textAlign = Paint.Align.CENTER
        }
    }

    private fun resolveTypeface(weight: Int): Typeface {
        if (curFontSource == 2) {
            val path = curCustomFontPath
            if (path != null && File(path).exists()) {
                try { return Typeface.createFromFile(path) } catch (_: Exception) {}
            }
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Typeface.create(Typeface.DEFAULT, weight, false)
        } else {
            Typeface.create(Typeface.DEFAULT, if (weight >= 700) Typeface.BOLD else Typeface.NORMAL)
        }
    }

    private fun ensureRenderedBg() {
        val bmp = backgroundBitmap ?: return
        val vw = width
        val vh = height
        if (vw <= 0 || vh <= 0) return
        val layer = renderedBg
        if (layer != null && renderedBgW == vw && renderedBgH == vh && renderedBgSource === bmp) return
        val newLayer = Bitmap.createBitmap(vw, vh, Bitmap.Config.ARGB_8888)
        val c = Canvas(newLayer)
        if (bmp.width > 0 && bmp.height > 0) {
            val scale = maxOf(vw / bmp.width.toFloat(), vh / bmp.height.toFloat())
            val dstW = bmp.width * scale
            val dstH = bmp.height * scale
            val dx = (vw - dstW) / 2f
            val dy = (vh - dstH) / 2f
            c.drawBitmap(bmp, null, RectF(dx, dy, dx + dstW, dy + dstH), bgDrawPaint)
        }
        c.drawColor(0x66000000.toInt())
        if (layer != null && layer !== newLayer) layer.recycle()
        renderedBg = newLayer
        renderedBgW = vw
        renderedBgH = vh
        renderedBgSource = bmp
    }

    private fun loadBackgroundBitmap(artUrl: String?, fallbackFilePath: String?) {
        if (loadingBackground) {
            pendingArt = artUrl
            pendingFallback = fallbackFilePath
            return
        }
        loadingBackground = true
        Thread {
            try {
                val src = loadArtBitmap(artUrl, fallbackFilePath)
                if (src != null) {
                    val scale = 200f / maxOf(src.width, src.height).toFloat()
                    val smallW = (src.width * scale).toInt().coerceAtLeast(1)
                    val smallH = (src.height * scale).toInt().coerceAtLeast(1)
                    val scaled = Bitmap.createScaledBitmap(src, smallW, smallH, true)
                    if (scaled !== src) src.recycle()
                    val blurred = try {
                        val rs = android.renderscript.RenderScript.create(context)
                        val input = android.renderscript.Allocation.createFromBitmap(rs, scaled)
                        val output = android.renderscript.Allocation.createTyped(rs, input.type)
                        val blur = android.renderscript.ScriptIntrinsicBlur.create(rs, android.renderscript.Element.U8_4(rs))
                        blur.setRadius(25f)
                        blur.setInput(input)
                        blur.forEach(output)
                        output.copyTo(scaled)
                        rs.destroy()
                        scaled
                    } catch (_: Exception) {
                        val fallbackRatio = 48f / scaled.width.toFloat()
                        val fbW = 48
                        val fbH = (scaled.height.toFloat() * fallbackRatio).toInt().coerceAtLeast(1)
                        val fb = Bitmap.createScaledBitmap(scaled, fbW, fbH, true)
                        if (fb !== scaled) scaled.recycle()
                        fb
                    }
                    post {
                        backgroundBitmap = blurred
                        renderedBg = null
                        loadingBackground = false
                        repostPending()
                        invalidate()
                    }
                } else {
                    post {
                        loadingBackground = false
                        repostPending()
                        invalidate()
                    }
                }
            } catch (_: Exception) {
                post {
                    loadingBackground = false
                    repostPending()
                    invalidate()
                }
            }
        }.start()
    }

    private fun repostPending() {
        val pArt = pendingArt
        val pFall = pendingFallback
        pendingArt = null
        pendingFallback = null
        if (pArt != null || pFall != null) {
            loadBackgroundBitmap(pArt, pFall)
        }
    }

    private fun loadArtBitmap(artUrl: String?, fallbackFilePath: String?): Bitmap? {
        if (artUrl != null && (artUrl.startsWith("http://") || artUrl.startsWith("https://"))) {
            try {
                val conn = URL(artUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 10000
                conn.instanceFollowRedirects = true
                return try { BitmapFactory.decodeStream(conn.inputStream) } finally { conn.disconnect() }
            } catch (_: Exception) { null }
        }
        if (artUrl != null && artUrl.startsWith("content://")) {
            try {
                return context.contentResolver.openInputStream(Uri.parse(artUrl))
                    ?.use { BitmapFactory.decodeStream(it) }
            } catch (_: Exception) {}
        }
        val filePath = when {
            artUrl != null && artUrl.startsWith("local://") -> artUrl.substring("local://".length)
            artUrl != null && artUrl.startsWith("file://") -> Uri.parse(artUrl).path ?: artUrl.substring("file://".length)
            artUrl != null -> artUrl
            fallbackFilePath != null -> fallbackFilePath
            else -> return null
        }
        val lower = filePath.lowercase()
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp")) {
            return try { BitmapFactory.decodeFile(filePath) } catch (_: Exception) { null }
        }
        try {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(filePath)
                val art = retriever.embeddedPicture
                return if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
            } finally { try { retriever.release() } catch (_: Exception) {} }
        } catch (_: Exception) { return null }
    }

    // ================= 布局构建 =================

    private fun currentLineIndex(): Int {
        val ls = curLines
        if (ls.isEmpty()) return -1
        var a = 0
        var b = ls.size - 1
        var ans = -1
        val pos = smoothPosMs
        while (a <= b) {
            val m = (a + b).ushr(1)
            if (ls[m].startMs <= pos) { ans = m; a = m + 1 } else b = m - 1
        }
        return ans
    }

    /// 逐字行按 word 累加换行：返回每视觉行文本与对应起始 word 索引（bounds.size == texts.size）。
    private fun splitWords(ws: List<LockLyricWord>, maxWidth: Float): Pair<List<String>, IntArray> {
        val texts = ArrayList<String>()
        val bounds = ArrayList<Int>()
        bounds.add(0)
        val sb = StringBuilder()
        var dx = 0f
        for (i in ws.indices) {
            val ww = brightPaint.measureText(ws[i].text)
            if (sb.isNotEmpty() && dx + ww > maxWidth) {
                bounds.add(i)
                texts.add(sb.toString())
                sb.setLength(0)
                dx = 0f
            }
            sb.append(ws[i].text)
            dx += ww
        }
        texts.add(sb.toString())
        return Pair(texts, bounds.toIntArray())
    }

    /// 纯文本行按字符累加换行（中文/英文混排均可用）。
    private fun splitByChar(text: String, maxWidth: Float): List<String> {
        if (text.isEmpty()) return emptyList()
        if (maxWidth <= 0) return listOf(text)
        val res = ArrayList<String>()
        val sb = StringBuilder()
        var wAcc = 0f
        for (ch in text) {
            val cw = dimPaint.measureText(ch.toString())
            if (sb.isNotEmpty() && wAcc + cw > maxWidth) {
                res.add(sb.toString())
                sb.setLength(0); wAcc = 0f
            }
            if (sb.isEmpty() && ch == ' ') continue
            sb.append(ch); wAcc += cw
        }
        if (sb.isNotEmpty()) res.add(sb.toString())
        if (res.isEmpty()) res.add(text)
        return res
    }

    private fun subTextHeight(): Float =
        transPaint.textSize + transPaint.textSize * 0.3f

    /// 构建每行块高 + 换行拆分 + 前缀和。数据/样式/视口宽度变化时重建。
    private fun buildLayoutCache() {
        val ls = curLines
        val vw = width
        val vh = height
        val curPx = dp(curSize).coerceIn(dp(12f), dp(60f))
        layoutWidth = vw.toFloat()
        layoutFontSize = curPx
        layoutLineMult = curLineMult
        layoutTransEnabled = if (curShowTrans) 1 else 0
        rendered = emptyList()
        lineTop = FloatArray(ls.size)
        lineAlpha = FloatArray(ls.size)
        curWordWidths = FloatArray(0)
        curWordStarts = FloatArray(0)
        if (ls.isEmpty() || vw <= 0 || vh <= 0) return
        val maxW = vw - dp(curSize) * 2f
        val mainH = curPx * curLineMult
        val transH = if (curShowTrans) subTextHeight() else 0f

        val list = ArrayList<RenderedLine>(ls.size)
        var cursor = 0f
        for (li in ls.indices) {
            val line = ls[li]
            val hasW = line.words.isNotEmpty()
            val (rowTexts, rowStarts) = if (hasW) {
                splitWords(line.words, maxW)
            } else {
                Pair(splitByChar(line.text, maxW), IntArray(0))
            }
            val rows = rowTexts.size.coerceAtLeast(1)
            val hasSub = curShowTrans && line.sub.isNotEmpty()
            val h = mainH + (rows - 1) * mainH * wrapFactor + (if (hasSub) transH else 0f)
            lineTop[li] = cursor
            cursor += h
            list.add(RenderedLine(rowTexts, rowStarts, hasW, h))
        }
        rendered = list
        for (i in lineAlpha.indices) lineAlpha[i] = darkAlpha
        // 首次/重建后直接吸附到当前行，避免打开时从歌词顶部滚动到当前行的突兀动画
        smoothScrollY = scrollTargetFor(currentLineIndex())
        invalidate()
    }

    override fun onSizeChanged(w: Int, hIn: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, hIn, oldw, oldh)
        renderedBg = null
        resetLayoutCache()
        invalidate()
    }

    // ================= 帧推进 =================

    /// 顶部保留区：歌曲名 / 元信息在此之下，歌词不进入这里。
    private fun topInset(): Float = maxOf(dp(76f), dp(14f) + headerPaint.textSize * 2.2f)

    /// 底部保留区：进度条此前保留空间，歌词不进入这里。
    private fun bottomInset(): Float = dp(96f)

    /// 歌词可视带高度（顶/底保留区之间的可用高度）。
    private fun availH(): Float = (height - topInset() - bottomInset()).coerceAtLeast(0f)

    private fun maxScrollY(): Float {
        val n = rendered.size
        if (n == 0) return 0f
        val lastBottom = lineTop[n - 1] + rendered[n - 1].height
        return (lastBottom - availH()).coerceAtLeast(0f)
    }

    private fun scrollTargetFor(idx: Int): Float {
        if (idx !in rendered.indices) return 0f
        val center = lineTop[idx] + rendered[idx].height / 2f
        return (center - availH() * 0.5f).coerceIn(0f, maxScrollY())
    }

    private fun advanceScroll(dtSec: Double) {
        val idx = currentLineIndex()
        if (idx < 0 || rendered.isEmpty()) return
        val target = scrollTargetFor(idx)
        val k = 1.0 - exp(-scrollRate * dtSec)
        smoothScrollY += ((target - smoothScrollY) * k).toFloat()
        if (abs(target - smoothScrollY) < 0.5f) smoothScrollY = target
    }

    private fun advanceLineAlpha(dtSec: Double) {
        val idx = currentLineIndex()
        val n = lineAlpha.size
        if (n == 0) return
        val kDark = 1.0 - exp(-4.0 * dtSec)
        val kBright = 1.0 - exp(-24.0 * dtSec)
        for (i in 0 until n) {
            val target = if (i == idx) brightAlpha else darkAlpha
            val k = if (i == idx) kBright.toFloat() else kDark.toFloat()
            val next = lineAlpha[i] + (target - lineAlpha[i]) * k
            lineAlpha[i] = if (abs(next - target) < 0.001f) target else next
        }
    }

    /// 当前行逐字已唱像素掩码（全局行内累计，从 0 起）。
    private fun computeMaskX(): Float {
        val idx = currentLineIndex()
        if (idx !in curLines.indices) return 0f
        val line = curLines[idx]
        if (line.words.isEmpty()) return Float.MAX_VALUE
        if (lastMaskLineIdx != idx) {
            curWordWidths = FloatArray(0)
            curWordStarts = FloatArray(0)
            lastMaskLineIdx = idx
        }
        val n = line.words.size
        if (curWordWidths.size != n) {
            curWordWidths = FloatArray(n)
            curWordStarts = FloatArray(n)
            var acc = 0f
            for (i in 0 until n) {
                curWordWidths[i] = brightPaint.measureText(line.words[i].text)
                curWordStarts[i] = acc
                acc += curWordWidths[i]
            }
        }
        val pos = smoothPosMs
        var maskX = 0f
        for (i in 0 until n) {
            val st = line.words[i].startMs
            val en = st + line.words[i].durMs
            if (pos >= en) {
                maskX = curWordStarts[i] + curWordWidths[i]
            } else if (pos <= st) {
                break
            } else {
                val p = ((pos - st).toFloat() / (en - st).toFloat().coerceAtLeast(1f)).coerceIn(0f, 1f)
                maskX = curWordStarts[i] + curWordWidths[i] * p
                break
            }
        }
        return maskX
    }

    // ================= 绘制 =================

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return

        if (backgroundBitmap == null) {
            canvas.drawColor(0xFF000000.toInt())
        } else {
            ensureRenderedBg()
            renderedBg?.let { canvas.drawBitmap(it, 0f, 0f, null) }
                ?: canvas.drawColor(0xFF000000.toInt())
        }

        val header = if (headerArtist.isNotEmpty()) "$headerTitle · $headerArtist" else headerTitle
        if (header.isNotEmpty()) {
            val baseline = dp(56f) - (headerPaint.ascent() + headerPaint.descent()) / 2f
            canvas.drawText(header, w / 2f, baseline, headerPaint)
        }

        if (curLines.isEmpty()) {
            if (placeholder.isNotEmpty()) {
                val cy = topInset() + availH() * 0.5f
                canvas.drawText(
                    placeholder, w / 2f,
                    cy - (placeholderPaint.ascent() + placeholderPaint.descent()) / 2f,
                    placeholderPaint
                )
            }
            drawProgress(canvas, w, h)
            return
        }

        if (rendered.isEmpty() || needRebuildLayout()) buildLayoutCache()

        val curIdx = currentLineIndex()
        if (lineTop.isEmpty()) return
        val maskX = computeMaskX()
        val overscanPx = overscan()
        val sidePad = dp(curSize) * 1.0f
        val tInset = topInset()
        val bInset = bottomInset()

        // 将歌词绘制严格限制在可视带内，绝不越界顶/底保留区
        canvas.save()
        canvas.clipRect(0f, tInset - 1f, w, h - bInset + 1f)

        var first = upperBoundLine(lineTop, (smoothScrollY - overscanPx).toDouble())
        if (first > 0) first--
        if (first < 0) first = 0

        var i = first
        while (i < lineTop.size) {
            if (lineTop[i] - smoothScrollY + tInset > h - bInset + overscanPx) break
            if (i in rendered.indices) {
                drawLine(canvas, i, curIdx, rendered[i], lineTop[i] - smoothScrollY + tInset, sidePad, maskX)
            }
            i++
        }

        canvas.restore()

        drawProgress(canvas, w, h)
    }

    private fun needRebuildLayout(): Boolean {
        val vw = width
        val curPx = dp(curSize).coerceIn(dp(12f), dp(60f))
        if (rendered.isEmpty() && curLines.isNotEmpty()) return true
        if (layoutWidth != vw.toFloat()) return true
        if (layoutFontSize != curPx) return true
        if (layoutLineMult != curLineMult) return true
        if (layoutTransEnabled != (if (curShowTrans) 1 else 0)) return true
        return false
    }

    /// 找到第一个 top >= pos 的行索引。
    private fun upperBoundLine(tops: FloatArray, pos: Double): Int {
        var a = 0
        var b = tops.size - 1
        var ans = tops.size
        while (a <= b) {
            val m = (a + b).ushr(1)
            if (tops[m].toDouble() < pos) {
                a = m + 1
            } else {
                ans = m
                b = m - 1
            }
        }
        return ans
    }

    private fun overscan(): Float = dp(300f)

    private fun rowOffset(mainH: Float, ri: Int): Float =
        if (ri == 0) 0f else mainH + (ri - 1) * mainH * wrapFactor

    private fun mainLineHeightPx(): Float {
        val curPx = dp(curSize).coerceIn(dp(12f), dp(60f))
        return curPx * curLineMult
    }

    private fun drawLine(
        canvas: Canvas, idx: Int, curIdx: Int, rl: RenderedLine,
        topY: Float, baseX: Float, maskX: Float,
    ) {
        val line = if (idx in curLines.indices) curLines[idx] else return
        if (rl.rowTexts.isEmpty()) return
        val isCur = idx == curIdx
        if (isCur && rl.hasWords) {
            drawCurWordLine(canvas, line, rl, topY, baseX, maskX)
        } else {
            val alpha = if (isCur) brightAlpha else lineAlphaAt(idx)
            val fm = dimPaint.fontMetrics
            dimPaint.alpha = (alpha * 255).toInt().coerceIn(0, 255)
            val mainH = mainLineHeightPx()
            for (ri in rl.rowTexts.indices) {
                val rowY = topY + rowOffset(mainH, ri) - fm.ascent
                canvas.drawText(rl.rowTexts[ri], baseX, rowY, dimPaint)
            }
            drawSubIfNeeded(canvas, line, rl, topY, baseX)
        }
    }

    private fun lineAlphaAt(idx: Int): Float =
        if (idx in lineAlpha.indices) lineAlpha[idx] else darkAlpha

    /// 当前行逐字二分色：先全字暗色，再按 maskX 裁剪亮色。
    private fun drawCurWordLine(
        canvas: Canvas, line: LockLyricLine, rl: RenderedLine, topY: Float, baseX: Float, maskXIn: Float,
    ) {
        val mainH = mainLineHeightPx()
        val brightColor = if (curUseDynamic) mixWhiteAccent(curAccent, dimMixRatio) else 0xFFFFFFFF.toInt()
        brightPaint.color = brightColor

        val words = line.words
        val n = words.size
        if (n == 0) {
            dimPaint.alpha = (darkAlpha * 255).toInt()
            for (ri in rl.rowTexts.indices) {
                val rowY = topY + rowOffset(mainH, ri) - dimPaint.fontMetrics.ascent
                canvas.drawText(rl.rowTexts[ri], baseX, rowY, dimPaint)
            }
            drawSubIfNeeded(canvas, line, rl, topY, baseX)
            return
        }

        val starts = rl.rowStarts
        val rowCount = rl.rowTexts.size
        val lineTotalWidth = (curWordStarts[n - 1] + curWordWidths[n - 1])
        val maskX = maskXIn.coerceIn(0f, lineTotalWidth)

        // 第一遍：全部暗色
        dimPaint.alpha = (darkAlpha * 255).toInt()
        for (ri in 0 until rowCount) {
            val s = starts[ri]
            val e = if (ri + 1 < starts.size) starts[ri + 1] else n
            val rowY = topY + rowOffset(mainH, ri) - dimPaint.fontMetrics.ascent
            for (i in s until e) {
                canvas.drawText(words[i].text, baseX + (curWordStarts[i] - curWordStarts[s]), rowY, dimPaint)
            }
        }
        // 第二遍：clip 亮色
        if (maskX > 0f) {
            for (ri in 0 until rowCount) {
                val s = starts[ri]
                val e = if (ri + 1 < starts.size) starts[ri + 1] else n
                if (s >= e) continue
                val rowRel = curWordStarts[s]
                val rowWidth = (curWordStarts[e - 1] - rowRel) + curWordWidths[e - 1]
                val sung = (maskX - rowRel).coerceIn(0f, rowWidth)
                if (sung <= 0f) continue
                val rowY = topY + rowOffset(mainH, ri) - brightPaint.fontMetrics.ascent
                canvas.save()
                canvas.clipRect(baseX, topY, baseX + sung, topY + rl.height)
                for (i in s until e) {
                    canvas.drawText(words[i].text, baseX + (curWordStarts[i] - rowRel), rowY, brightPaint)
                }
                canvas.restore()
            }
        }
        drawSubIfNeeded(canvas, line, rl, topY, baseX)
    }

    /// 当前行副行（翻译/罗马音）绘制在主文本视觉行之后、块内底部。
    private fun drawSubIfNeeded(canvas: Canvas, line: LockLyricLine, rl: RenderedLine, topY: Float, baseX: Float) {
        if (!curShowTrans || line.sub.isEmpty()) return
        val mainH = mainLineHeightPx()
        val rows = rl.rowTexts.size.coerceAtLeast(1)
        val mainBottom = topY + mainH + (rows - 1) * mainH * wrapFactor
        val sidePad = dp(curSize) * 1.0f
        val maxW = (width - sidePad * 2f).coerceAtLeast(0f)
        val subRows = splitByChar(line.sub, maxW)
        transPaint.alpha = (transOpacity * 255).toInt()
        var y = mainBottom + transPaint.textSize * 0.3f - (transPaint.ascent() + transPaint.descent()) / 2f
        for (s in subRows) {
            canvas.drawText(s, baseX, y, transPaint)
            y += transPaint.textSize * 1.5f
        }
    }

    private fun mixWhiteAccent(accent: Int, ratio: Float): Int {
        val r = ((255 * (1 - ratio)) + ((accent shr 16) and 0xFF) * ratio).toInt().coerceIn(0, 255)
        val g = ((255 * (1 - ratio)) + ((accent shr 8) and 0xFF) * ratio).toInt().coerceIn(0, 255)
        val b = ((255 * (1 - ratio)) + (accent and 0xFF) * ratio).toInt().coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private fun drawProgress(canvas: Canvas, w: Float, h: Float) {
        if (durationMs <= 0) return
        val barW = w * 0.72f
        val barH = dp(3f)
        val cx = (w - barW) / 2f
        val cy = h - dp(70f)
        val ratio = (smoothPosMs / durationMs).toFloat().coerceIn(0f, 1f)
        val rect = RectF(cx, cy, cx + barW, cy + barH)
        canvas.drawRoundRect(rect, barH / 2f, barH / 2f, progressBgPaint)
        if (ratio > 0f) {
            val fg = RectF(cx, cy, cx + barW * ratio, cy + barH)
            canvas.drawRoundRect(fg, barH / 2f, barH / 2f, progressFgPaint)
        }
    }

    private fun dp(v: Float): Float = v * resources.displayMetrics.density
}