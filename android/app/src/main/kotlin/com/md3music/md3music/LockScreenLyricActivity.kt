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
import java.net.HttpURLConnection
import java.net.URL

/// 锁屏歌词数据快照（跨组件共享的不可变值对象）。
class LockScreenLyricData(
    val lineText: String = "",
    val prevText: String = "",
    val nextText: String = "",
    val words: List<String> = emptyList(),
    val wordStartTimes: LongArray = LongArray(0),
    val wordDurations: LongArray = LongArray(0),
    val currentPositionMs: Long = 0L,
    val durationMs: Long = 0L,
    val isPlaying: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val artUrl: String? = null,
    val fallbackFilePath: String? = null,
    val fontSize: Float = 22f,
    val fontWeight: Int = 600,
)

/// 锁屏歌词 Activity：全屏覆盖在锁屏上方，显示 AM 风格逐字歌词。
class LockScreenLyricActivity : Activity() {

    companion object {
        private const val ACTION_USER_PRESENT = Intent.ACTION_USER_PRESENT

        @Volatile
        private var data = LockScreenLyricData()

        @Volatile
        private var runningActivity: LockScreenLyricActivity? = null

        fun currentData(): LockScreenLyricData = data

        /// 由 MainActivity / AudioPlaybackService 转发 MethodChannel 调用。
        fun applyCall(call: MethodCall) {
            updateData(
                lineText = call.argument<String>("lineText") ?: "",
                prevText = call.argument<String>("prevText") ?: "",
                nextText = call.argument<String>("nextText") ?: "",
                words = call.argument<List<String>>("words") ?: emptyList(),
                wordStartTimes = (call.argument<List<Number>>("wordStartTimes")
                    ?: emptyList()).map { it.toLong() },
                wordDurations = (call.argument<List<Number>>("wordDurations")
                    ?: emptyList()).map { it.toLong() },
                currentPositionMs = call.argument<Number>("currentPositionMs")?.toLong() ?: 0L,
                durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
                isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                title = call.argument<String>("title") ?: "",
                artist = call.argument<String>("artist") ?: "",
                artUrl = call.argument<String>("artUrl"),
                fallbackFilePath = call.argument<String>("fallbackFilePath"),
                fontSize = (call.argument<Number>("fontSize")?.toFloat() ?: 22f),
                fontWeight = call.argument<Number>("fontWeight")?.toInt() ?: 600,
            )
        }

        fun updateData(
            lineText: String, prevText: String, nextText: String,
            words: List<String>, wordStartTimes: List<Long>, wordDurations: List<Long>,
            currentPositionMs: Long, durationMs: Long,
            isPlaying: Boolean, title: String, artist: String,
            artUrl: String? = null, fallbackFilePath: String? = null,
            fontSize: Float = 22f, fontWeight: Int = 600,
        ) {
            data = LockScreenLyricData(
                lineText = lineText, prevText = prevText, nextText = nextText,
                words = words, wordStartTimes = wordStartTimes.toLongArray(),
                wordDurations = wordDurations.toLongArray(),
                currentPositionMs = currentPositionMs, durationMs = durationMs,
                isPlaying = isPlaying, title = title, artist = artist,
                artUrl = artUrl, fallbackFilePath = fallbackFilePath,
                fontSize = fontSize, fontWeight = fontWeight,
            )
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

        // 沉浸式系统栏：隐藏状态栏 + 导航栏，内容延伸到全屏，消除底部导航栏黑边。
        // windowFullscreen 只隐藏状态栏；导航栏需在此显式隐藏并让 View 延伸覆盖。
        // IMMERSIVE_STICKY：从边缘滑动时临时显示系统栏，配合 FLAG_NOT_TOUCHABLE 不会误触。
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
}

/// 锁屏歌词 Canvas 渲染视图。
///
/// 特性：
/// - 模糊专辑封面背景（加载在线 URL / 本地内嵌封面，降采样 + 缩放实现模糊）
/// - 自动换行（总宽度超过视口时按单词换行，当前行支持多行二分色）
/// - 字号/字重同步 AM 歌词设置
/// - 布局：顶部歌名/艺术家 → 上一行 → 当前行（大字号，字级二分色）→ 下一行 → 底部进度条
/// - 原生 Choreographer 帧循环平滑推进位置
class LockScreenLyricView(context: Context) : View(context) {

    // 布局常量
    private val headerTop = dp(56f)
    private val subLineTopRatio = 0.36f
    private val currentLineCenterRatio = 0.55f
    private val subLineBottomRatio = 0.74f
    private val progressBottom = dp(70f)
    private val sidePadding = dp(24f)
    private val lineSpacing = dp(12f)

    private var headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xB3FFFFFF.toInt() // 70% 白
        textAlign = Paint.Align.CENTER
    }
    private var subPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x4DFFFFFF.toInt() // 30% 白
        textAlign = Paint.Align.CENTER
    }
    private var dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x59FFFFFF.toInt() // 35% 白：未唱
        textAlign = Paint.Align.LEFT
    }
    private var brightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt() // 全亮：已唱
        textAlign = Paint.Align.LEFT
    }
    // 无逐字（LRC/纯文本）时当前行整行显示的画笔（85% 白，居中）
    private var fallbackCurPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xD9FFFFFF.toInt()
        textAlign = Paint.Align.CENTER
    }
    private val progressBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x33FFFFFF.toInt()
    }
    private val progressFgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
    }

    // 背景模糊封面
    private var backgroundBitmap: Bitmap? = null
    private var loadingBackground = false
    private var lastArtUrl: String? = null
    private var lastFallbackPath: String? = null
    // cover 绘制 + 双线性滤波（拉伸放大时平滑，呈现重度模糊）
    private val bgDrawPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    // 背景预渲染整屏图层：封面/尺寸变化时重画一次，每帧 1:1 直绘（避免每帧全屏拉伸滤波）
    private var renderedBg: Bitmap? = null
    private var renderedBgW = 0
    private var renderedBgH = 0
    private var renderedBgSource: Bitmap? = null

    // 换行结果缓存：prev/next/无逐字当前行只在文本或字号变化时重算一次，
    // 避免每帧逐字符 measureText（曾导致动画卡顿）
    private class WrapCache {
        var text: String? = null
        var width: Float = -1f
        var size: Float = -1f
        var lines: List<String> = emptyList()
    }
    private val prevWrapCache = WrapCache()
    private val nextWrapCache = WrapCache()
    private val fallbackCurWrapCache = WrapCache()

    // 数据
    private var lineText = ""
    private var prevText = ""
    private var nextText = ""
    private var words: List<String> = emptyList()
    private var wordStarts = LongArray(0)
    private var wordDurs = LongArray(0)
    private var authoritativePosMs = 0L
    private var durationMs = 0L
    private var isPlayingFlag = false
    private var headerTitle = ""
    private var headerArtist = ""
    private var curFontSize = 22f
    private var curFontWeight = 600

    // 当前行字级测量缓存（数据变化时重算）
    private var wordWidths = FloatArray(0)
    private var wordStartXs = FloatArray(0)
    private var needMeasure = true

    // 换行：当前行拆成多条视觉行，每条视觉行的 word index 范围、总宽、起始 Y、
    // 起始 word 的全局累计 X（用于把全局 wordStartXs 转为行内相对坐标）
    private data class VisualLine(
        val startWord: Int, val endWord: Int, // [start, end)
        val width: Float,
        val y: Float,
        val relStart: Float, // wordStartXs[startWord]
    )
    private var visualLines: List<VisualLine> = emptyList()

    // 平滑位置（Double：亚毫秒累积，避免 Long 截断导致逐字台阶式抖动）
    private var smoothPosMs = 0.0
    private var lastFrameMs = 0L
    private var lastAuthorityMs = 0L
    private var wasPlayingFlag = false
    // 位置平滑参数（参考 AM 歌词视图的指数平滑模型）
    private val corrRate = 40.0            // 指数逼近速率：越大越跟手、越小越平滑
    private val seekJumpMs = 800L          // 超过此差视为 seek/切歌，直接吸附
    private val authorityFreshMs = 350L    // 权威位置新鲜窗口，超时停止外推

    // 帧循环
    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val now = SystemClock.uptimeMillis()
            if (isPlayingFlag) {
                val dtSec = if (lastFrameMs > 0) (now - lastFrameMs) / 1000.0 else 0.016
                lastFrameMs = now
                // 目标 = 权威位置 + 自上次权威以来的真实时间（始终外推）：
                // 播放中位置按真实时间 1:1 前进。权威推送被 ROM 限流（后台 1Hz 等）时
                // 掩码也不冻结、持续平滑推进；权威恢复后由指数逼近平滑校正漂移。
                val age = now - lastAuthorityMs
                val target = authoritativePosMs + age.toDouble()
                // 指数平滑逼近目标（亚毫秒累积，Double 无截断）
                val k = 1.0 - Math.exp(-corrRate * dtSec)
                smoothPosMs += (target - smoothPosMs) * k
                if (Math.abs(target - smoothPosMs) < 0.5) smoothPosMs = target
                invalidate()
                if (isAttachedToWindow) Choreographer.getInstance().postFrameCallback(this)
            } else {
                lastFrameMs = now
                stopFrameLoop()
                invalidate()
            }
        }
    }
    private var frameRunning = false

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (isPlayingFlag) startFrameLoop()
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

    /// 从静态持有者快照最新数据。
    /// 只在对应内容真正变化时标记需要重绘（文本/字号/封面），
    /// 避免 250ms 推送导致的每帧重复测量。
    fun applyLatestData() {
        val d = LockScreenLyricActivity.currentData()

        // 文本变化 → 记录（换行缓存由 WrapCache 内 text/width/size 对比自动失效）
        val lineChanged = lineText != d.lineText
        if (lineChanged) lineText = d.lineText
        if (prevText != d.prevText) prevText = d.prevText
        if (nextText != d.nextText) nextText = d.nextText
        words = d.words
        wordStarts = d.wordStartTimes
        wordDurs = d.wordDurations
        authoritativePosMs = d.currentPositionMs
        durationMs = d.durationMs
        isPlayingFlag = d.isPlaying
        headerTitle = d.title
        headerArtist = d.artist

        // 字体变化 → 重建画笔 + 当前行重测（换行缓存自动失效）
        val fontChanged = curFontSize != d.fontSize || curFontWeight != d.fontWeight
        if (fontChanged) {
            curFontSize = d.fontSize
            curFontWeight = d.fontWeight
            rebuildTypeface()
        }
        // 切行或字体变化时重测当前行宽度/换行
        if (lineChanged || fontChanged) needMeasure = true

        // 位置平滑更新（authoritativePosMs 已在上面赋值为 d.currentPositionMs）：
        // - 暂停：冻结在权威位置
        // - seek/切歌（与当前平滑位置差 > seekJumpMs）或刚开始播放 → 直接吸附权威位置
        // - 正常播放：只记录权威位置与时间戳，由帧循环按指数平滑逼近（避免 250ms 推送抖动）
        if (!isPlayingFlag) {
            smoothPosMs = authoritativePosMs.toDouble()
        } else if (Math.abs(authoritativePosMs - smoothPosMs) > seekJumpMs || !wasPlayingFlag) {
            smoothPosMs = authoritativePosMs.toDouble()
        }
        lastAuthorityMs = SystemClock.uptimeMillis()
        wasPlayingFlag = isPlayingFlag
        lastFrameMs = SystemClock.uptimeMillis()
        if (isPlayingFlag) startFrameLoop() else stopFrameLoop()

        // 封面 URL 或 Fallback 变化时异步加载背景
        if (d.artUrl != lastArtUrl || d.fallbackFilePath != lastFallbackPath) {
            lastArtUrl = d.artUrl
            lastFallbackPath = d.fallbackFilePath
            loadBackgroundBitmap(d.artUrl, d.fallbackFilePath)
        }

        invalidate()
    }

    private fun rebuildTypeface() {
        // 字重创建：API 28+ 用可变字重（Roboto/MiSans 为可变字体，300~900 真实生效）；
        // 低版本只能粗/常规二分（>=700 视为粗体）。不能直接 Typeface.create(family, weight)
        // —— 那个重载传的是样式常量，600 等中间值不会产生变体字重（表现为调粗细无效）。
        val weight = curFontWeight.coerceIn(300, 900)
        val tf = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Typeface.create(Typeface.DEFAULT, weight, false)
        } else {
            Typeface.create(
                Typeface.DEFAULT,
                if (weight >= 700) Typeface.BOLD else Typeface.NORMAL
            )
        }
        val curSize = dp(curFontSize).coerceIn(dp(14f), dp(60f))
        val subSize = dp(curFontSize * 0.6f).coerceAtLeast(dp(12f))
        val headerSize = dp(13f)

        headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xB3FFFFFF.toInt()
            textSize = headerSize
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT
        }
        subPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x4DFFFFFF.toInt()
            textSize = subSize
            textAlign = Paint.Align.CENTER
            typeface = tf
        }
        dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x59FFFFFF.toInt()
            textSize = curSize
            textAlign = Paint.Align.LEFT
            typeface = tf
        }
        brightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt()
            textSize = curSize
            textAlign = Paint.Align.LEFT
            typeface = tf
        }
        fallbackCurPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xD9FFFFFF.toInt()
            textSize = curSize
            textAlign = Paint.Align.CENTER
            typeface = tf
        }
    }

    /// 异步加载封面并用 RenderScript 做高斯模糊背景。
    ///
    /// 流程：加载原图 → 缩放到约 200px（控制内存）→ RenderScript ScriptIntrinsicBlur
    /// （radius=25，≈ AM 播放器 ImageFilter.blur(sigma 30)）→ cover 绘制全屏。
    /// 无 RenderScript 的设备降级到 48px 降采样拉伸（原逻辑）。
    private fun loadBackgroundBitmap(artUrl: String?, fallbackFilePath: String?) {
        if (loadingBackground) return
        loadingBackground = true
        Thread {
            try {
                val src = loadArtBitmap(artUrl, fallbackFilePath) ?: run {
                    loadingBackground = false; return@Thread
                }
                // 缩放到 200px 短边（控制内存 + 模糊渲染速度）
                val scale = 200f / maxOf(src.width, src.height).toFloat()
                val smallW = (src.width * scale).toInt().coerceAtLeast(1)
                val smallH = (src.height * scale).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(src, smallW, smallH, true)
                if (scaled !== src) src.recycle()

                // 高斯模糊（RenderScript，API 17+）
                val blurred = try {
                    val rs = android.renderscript.RenderScript.create(context)
                    val input = android.renderscript.Allocation.createFromBitmap(rs, scaled)
                    val output = android.renderscript.Allocation.createTyped(rs, input.type)
                    val blur = android.renderscript.ScriptIntrinsicBlur.create(rs, android.renderscript.Element.U8_4(rs))
                    blur.setRadius(25f) // sigma ≈ 30
                    blur.setInput(input)
                    blur.forEach(output)
                    output.copyTo(scaled)
                    rs.destroy()
                    scaled
                } catch (_: Exception) {
                    // 降级：48px 降采样 + 双线性滤波
                    val fallbackRatio = 48f / scaled.width.toFloat()
                    val fbW = 48
                    val fbH = (scaled.height.toFloat() * fallbackRatio).toInt().coerceAtLeast(1)
                    val fb = Bitmap.createScaledBitmap(scaled, fbW, fbH, true)
                    if (fb !== scaled) scaled.recycle()
                    fb
                }
                post {
                    backgroundBitmap = blurred
                    // 背景图变了 → 预渲染缓存失效，下次 onDraw 重画
                    renderedBg = null
                    invalidate()
                }
                loadingBackground = false
            } catch (_: Exception) { loadingBackground = false }
        }.start()
    }

    /// 加载封面 Bitmap（复用 AudioPlaybackService 类似逻辑）。
    private fun loadArtBitmap(artUrl: String?, fallbackFilePath: String?): Bitmap? {
        // 在线 URL
        if (artUrl != null && (artUrl.startsWith("http://") || artUrl.startsWith("https://"))) {
            try {
                val conn = URL(artUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 10000
                conn.instanceFollowRedirects = true
                return try { BitmapFactory.decodeStream(conn.inputStream) } finally { conn.disconnect() }
            } catch (_: Exception) { null }
        }
        // content://
        if (artUrl != null && artUrl.startsWith("content://")) {
            try {
                return context.contentResolver.openInputStream(Uri.parse(artUrl))?.use { BitmapFactory.decodeStream(it) }
            } catch (_: Exception) {}
        }
        // 音频文件内嵌封面
        val filePath = when {
            artUrl != null && artUrl.startsWith("local://") -> artUrl.substring("local://".length)
            artUrl != null && artUrl.startsWith("file://") -> Uri.parse(artUrl).path ?: artUrl.substring("file://".length)
            artUrl != null -> artUrl
            fallbackFilePath != null -> fallbackFilePath
            else -> return null
        }
        // 图片文件直接解码
        val lower = filePath.lowercase()
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp")) {
            return try { BitmapFactory.decodeFile(filePath) } catch (_: Exception) { null }
        }
        // 音频文件读内嵌封面
        try {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(filePath)
                val art = retriever.embeddedPicture
                return if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
            } finally { try { retriever.release() } catch (_: Exception) {} }
        } catch (_: Exception) { return null }
    }

    /// 预渲染整屏背景图层（模糊封面 cover 铺满 + 40% 黑遮罩）。
    /// 仅在封面图或视图尺寸变化时重画一次，之后每帧 1:1 直绘。
    private fun ensureRenderedBg() {
        val bmp = backgroundBitmap ?: return
        val vw = width
        val vh = height
        if (vw <= 0 || vh <= 0) return
        val layer = renderedBg
        if (layer != null && renderedBgW == vw && renderedBgH == vh && renderedBgSource === bmp) {
            return
        }
        val newLayer = Bitmap.createBitmap(vw, vh, Bitmap.Config.ARGB_8888)
        val c = Canvas(newLayer)
        val bmpW = bmp.width.toFloat()
        val bmpH = bmp.height.toFloat()
        if (bmpW > 0 && bmpH > 0) {
            val scale = maxOf(vw / bmpW, vh / bmpH)
            val dstW = bmpW * scale
            val dstH = bmpH * scale
            val dx = (vw - dstW) / 2f
            val dy = (vh - dstH) / 2f
            bgDrawPaint.alpha = 255
            c.drawBitmap(bmp, null, RectF(dx, dy, dx + dstW, dy + dstH), bgDrawPaint)
        }
        c.drawColor(0x66000000.toInt()) // 40% 黑遮罩保证文字可读
        if (layer != null && layer !== newLayer) layer.recycle()
        renderedBg = newLayer
        renderedBgW = vw
        renderedBgH = vh
        renderedBgSource = bmp
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return

        // 模糊封面背景：RenderScript 高斯模糊 + cover 铺满（不压缩拉伸）。
        // 已预渲染成整屏缓存图层，每帧 1:1 直绘（避免每帧全屏拉伸滤波开销）
        if (backgroundBitmap == null) {
            canvas.drawColor(0xFF000000.toInt())
        } else {
            ensureRenderedBg()
            val layer = renderedBg
            if (layer != null) {
                canvas.drawBitmap(layer, 0f, 0f, null)
            } else {
                canvas.drawColor(0xFF000000.toInt())
            }
        }

        // 顶部标题
        val header = if (headerArtist.isNotEmpty()) "$headerTitle · $headerArtist" else headerTitle
        if (header.isNotEmpty()) {
            val baseline = headerTop - (headerPaint.ascent() + headerPaint.descent()) / 2f
            canvas.drawText(header, w / 2f, baseline, headerPaint)
        }

        if (lineText.isEmpty()) {
            drawProgress(canvas, w, h)
            return
        }

        // 换行计算
        val maxWordWidth = w - sidePadding * 2
        if (words.isNotEmpty() && needMeasure) {
            // 测量当前行所有 word 宽度（全局累计 wordStartXs）
            wordWidths = FloatArray(words.size)
            wordStartXs = FloatArray(words.size)
            var acc = 0f
            for (i in words.indices) {
                wordWidths[i] = brightPaint.measureText(words[i])
                wordStartXs[i] = acc
                acc += wordWidths[i]
            }
            // 换行拆分（切歌 / 字体变化时重算）
            visualLines = buildVisualLines(maxWordWidth)
            needMeasure = false
        }

        if (words.isNotEmpty()) {
            // 计算 maskX（全局行内累计坐标）
            var maskX = 0f
            for (i in words.indices) {
                val st = wordStarts.getOrElse(i) { 0L }
                val en = st + wordDurs.getOrElse(i) { 0L }
                if (smoothPosMs >= en) {
                    maskX = wordStartXs[i] + wordWidths[i]
                } else if (smoothPosMs <= st) {
                    break
                } else {
                    val p = ((smoothPosMs - st) / (en - st)).toFloat()
                    maskX = wordStartXs[i] + wordWidths[i] * p
                    break
                }
            }

            // 上/下一行（暗色，居中，支持换行，换行结果缓存避免每帧测量）
            drawWrappedCentered(canvas, prevText, prevWrapCache, w, h * subLineTopRatio, subPaint, maxWordWidth)
            drawWrappedCentered(canvas, nextText, nextWrapCache, w, h * subLineBottomRatio, subPaint, maxWordWidth)

            // 当前行：逐视觉行绘制，字级二分色
            for (vl in visualLines) {
                val baseX = (w - vl.width) / 2f
                // 先暗色（全部字）
                for (i in vl.startWord until vl.endWord) {
                    canvas.drawText(words[i], baseX + (wordStartXs[i] - vl.relStart), vl.y, dimPaint)
                }
                // clipRect 亮色覆盖（本视觉行内已唱宽度）
                if (maskX > 0f) {
                    val sungInLine = (maskX - vl.relStart).coerceIn(0f, vl.width)
                    if (sungInLine > 0f) {
                        canvas.save()
                        canvas.clipRect(baseX, 0f, baseX + sungInLine, h)
                        for (i in vl.startWord until vl.endWord) {
                            canvas.drawText(words[i], baseX + (wordStartXs[i] - vl.relStart), vl.y, brightPaint)
                        }
                        canvas.restore()
                    }
                }
            }
        } else {
            // 无逐字：整行显示（支持换行，换行结果缓存避免每帧测量）
            drawWrappedCentered(canvas, prevText, prevWrapCache, w, h * subLineTopRatio, subPaint, maxWordWidth)
            drawWrappedCentered(canvas, lineText, fallbackCurWrapCache, w, h * currentLineCenterRatio, fallbackCurPaint, maxWordWidth)
            drawWrappedCentered(canvas, nextText, nextWrapCache, w, h * subLineBottomRatio, subPaint, maxWordWidth)
        }

        drawProgress(canvas, w, h)
    }

    /// 按最大宽度将当前行单词拆分为多条视觉行（第一遍切分，第二遍垂直居中分配 Y）。
    private fun buildVisualLines(maxWidth: Float): List<VisualLine> {
        if (words.isEmpty() || maxWidth <= 0) return emptyList()
        // 第一遍：切分，记录每条线的 word 范围、总宽、起始全局 X
        val segs = mutableListOf<VisualLine>()
        var i = 0
        while (i < words.size) {
            var wAcc = 0f
            val start = i
            while (i < words.size) {
                val w = wordWidths.getOrElse(i) { brightPaint.measureText(words[i]) }
                if (wAcc + w > maxWidth && wAcc > 0) break
                wAcc += w
                i++
            }
            if (i == start) i++ // 单个字超长也显示
            segs.add(VisualLine(start, i, wAcc, 0f, wordStartXs.getOrElse(start) { 0f }))
        }
        // 第二遍：垂直居中分配 y
        val lineH = dimPaint.textSize + lineSpacing
        val totalH = segs.size * lineH
        val y0 = height.toFloat() * currentLineCenterRatio - totalH / 2f
        return segs.mapIndexed { idx, seg ->
            VisualLine(seg.startWord, seg.endWord, seg.width, y0 + idx * lineH, seg.relStart)
        }
    }

    /// 将文本按最大宽度换行后居中绘制（上/下一行、无逐字当前行共用）。
    /// 换行结果缓存在 [cache] 中，仅 text/宽度/字号变化时重算，避免每帧逐字符测量。
    private fun drawWrappedCentered(
        canvas: Canvas,
        text: String,
        cache: WrapCache,
        w: Float,
        centerY: Float,
        paint: Paint,
        maxWidth: Float,
    ) {
        if (text.isEmpty()) return
        var lines = cache.lines
        if (cache.text != text || cache.width != maxWidth || cache.size != paint.textSize || lines.isEmpty()) {
            cache.text = text
            cache.width = maxWidth
            cache.size = paint.textSize
            cache.lines = wrapText(paint, text, maxWidth)
            lines = cache.lines
        }
        val lineH = paint.textSize * 1.35f
        val totalH = lines.size * lineH
        val y0 = centerY - totalH / 2f
        for ((idx, l) in lines.withIndex()) {
            val baseline = y0 + idx * lineH - (paint.ascent() + paint.descent()) / 2f
            canvas.drawText(l, w / 2f, baseline, paint)
        }
    }

    /// 逐字符按宽度换行（中文/英文混排均可；行首空格跳过）。
    private fun wrapText(paint: Paint, text: String, maxWidth: Float): List<String> {
        if (maxWidth <= 0) return listOf(text)
        val lines = mutableListOf<String>()
        val sb = StringBuilder()
        var wAcc = 0f
        for (ch in text) {
            val cw = paint.measureText(ch.toString())
            if (sb.isNotEmpty() && wAcc + cw > maxWidth) {
                lines.add(sb.toString())
                sb.clear()
                wAcc = 0f
            }
            if (sb.isEmpty() && ch == ' ') continue // 行首空格跳过
            sb.append(ch)
            wAcc += cw
        }
        if (sb.isNotEmpty()) lines.add(sb.toString())
        return lines
    }

    private fun drawProgress(canvas: Canvas, w: Float, h: Float) {
        if (durationMs <= 0) return
        val barW = w * 0.72f
        val barH = dp(3f)
        val cx = (w - barW) / 2f
        val cy = h - progressBottom
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