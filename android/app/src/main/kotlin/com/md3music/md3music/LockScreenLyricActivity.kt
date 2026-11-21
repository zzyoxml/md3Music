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
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Choreographer
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.hypot

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
/// - `updateLockScreenFavorite`：收藏翻转的增量同步 → `applyFavoriteCall`
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
    /// 当前歌曲是否已收藏（底部卡片红心态；Dart 侧收藏翻转后增量推送）。
    val isFavorited: Boolean = false,
)

/// 锁屏歌词 Activity：全屏覆盖在锁屏上方，渲染居中逐字歌词 + 底部玻璃卡片。
///
/// 窗口自 2026-10 升级起可触控（不再 `FLAG_NOT_TOUCHABLE`）：卡片按钮真实可点，
/// 上滑/双击/系统返回手势 → `requestDismissKeyguard` + `finish()` 解锁。
/// 渲染分层：背景模糊封面由 [ImageView] 承载（仅切歌/尺寸变化时替换），
/// 歌词与卡片在透明覆盖层 [LockScreenLyricView] 上绘制。
class LockScreenLyricActivity : Activity(), LockScreenLyricView.Listener {

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
                // 收藏态允许整包覆盖；Dart 旧版本不带该字段时沿用当前值
                isFavorited = args["isFavorited"] as? Boolean ?: data.isFavorited,
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

        /// 收藏态增量推送：只翻红心，不重推歌词与样式（避免整包重排）。
        fun applyFavoriteCall(call: MethodCall) {
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val d = data
            data = d.copy(isFavorited = args["isFavorited"] as? Boolean ?: d.isFavorited)
            runningActivity?.postFavoriteUpdate()
        }

        /// 拉起锁屏歌词层。
        ///
        /// [requireLocked] 传 true 时要求「当前确实在锁屏」才拉起（亮屏路径使用）：
        /// 屏幕亮起但设备已解锁（例如 App 正在前台播放、用户只是点亮屏幕）时，
        /// 这层可触控的全屏窗口会盖住 App，属于必须避免的误触场景。
        /// 熄屏路径不校验——熄屏后系统必定进入 keyguard，且个别 ROM 在熄屏瞬间
        /// 上报的 keyguard 状态有延迟。
        fun start(context: Context, requireLocked: Boolean = false) {
            android.util.Log.i("LockScreenLyric", "start() called, running=${runningActivity != null}")
            if (runningActivity != null) return
            if (requireLocked && !isKeyguardLocked(context)) {
                android.util.Log.i("LockScreenLyric", "start() skipped: keyguard not locked")
                return
            }
            try {
                val intent = Intent(context, LockScreenLyricActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    .putExtra(EXTRA_REQUIRE_LOCKED, requireLocked)
                context.startActivity(intent)
                android.util.Log.i("LockScreenLyric", "startActivity ok")
            } catch (e: Exception) {
                android.util.Log.e("LockScreenLyric", "startActivity failed: $e")
            }
        }

        /// 亮屏路径的二次校验标记：拉起瞬间与 onCreate 之间可能正好被解锁。
        private const val EXTRA_REQUIRE_LOCKED = "require_locked"

        /// 当前是否处于锁屏（无 keyguard 的机型恒为 false → 永不拉起，符合语义）。
        private fun isKeyguardLocked(context: Context): Boolean = try {
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
            km?.isKeyguardLocked == true
        } catch (_: Exception) {
            false
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
    private lateinit var backgroundView: ImageView
    private var userPresentReceiver: BroadcastReceiver? = null

    /// API 33+ 返回手势回调（低版本走 onBackPressed）。类型用 Any 避免低版本类加载。
    private var backCallback: Any? = null

    /// 解锁只执行一次：requestDismissKeyguard 与 finish 可能被多路（手势/返回键/按钮）触发。
    private var unlocking = false

    // ===== 背景模糊图加载状态（保留既有 pending 重投语义）=====
    private var loadingBackground = false
    private var lastArtUrl: String? = null
    private var lastFallbackPath: String? = null
    private var pendingArt: String? = null
    private var pendingFallback: String? = null
    private var backgroundBitmap: Bitmap? = null

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
        // 注意：这里不再加 FLAG_NOT_TOUCHABLE——卡片按钮与解锁手势都依赖真实触摸事件。
        applyImmersiveFlags()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = 0x00000000
            window.navigationBarColor = 0x00000000
        }

        setContentView(R.layout.lock_screen_lyric_root)
        backgroundView = findViewById(R.id.lock_bg)
        lyricView = findViewById(R.id.lock_lyric)
        lyricView.listener = this
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

        registerBackCallback()
        lyricView.applyLatestData()
        lyricView.startUnlockHint()
    }

    /// 沉浸式全屏：隐藏状态栏/导航栏，锁屏上不留系统条。
    private fun applyImmersiveFlags() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LOW_PROFILE
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            )
    }

    override fun onStart() {
        super.onStart()
        android.util.Log.i("LockScreenLyric", "onStart")
        lyricView.applyLatestData()
    }

    override fun onResume() {
        super.onResume()
        // 亮屏路径的二次校验：拉起瞬间在锁屏、真正显示时已被解锁（指纹/面部）时，
        // 立即退出，避免可触控全屏层盖住 App。熄屏路径不带该标记，不做校验。
        if (intent?.getBooleanExtra(EXTRA_REQUIRE_LOCKED, false) == true &&
            !isKeyguardLocked(this)
        ) {
            android.util.Log.i("LockScreenLyric", "onResume: keyguard already dismissed, finish")
            finish()
        }
    }

    override fun onStop() {
        super.onStop()
        android.util.Log.i("LockScreenLyric", "onStop (stay alive)")
        lyricView.onScreenHidden()
    }

    override fun onDestroy() {
        runningActivity = null
        unregisterBackCallback()
        userPresentReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        userPresentReceiver = null
        backgroundBitmap?.let { if (!it.isRecycled) it.recycle() }
        backgroundBitmap = null
        try { lyricView.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    // ===== 返回键解锁 =====

    /// API 33+ 用 OnBackInvokedDispatcher（manifest 已开 enableOnBackInvokedCallback）。
    private fun registerBackCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            val callback = android.window.OnBackInvokedCallback { unlock() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                callback
            )
            backCallback = callback
        } catch (_: Throwable) {
            // 个别 ROM 不支持：保留 onBackPressed 兜底
        }
    }

    private fun unregisterBackCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val cb = backCallback as? android.window.OnBackInvokedCallback ?: return
        try { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(cb) } catch (_: Throwable) {}
        backCallback = null
    }

    // 返回手势：API 33+ 已走 OnBackInvokedDispatcher；低版本只能覆写已废弃的 onBackPressed
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        unlock()
    }

    /// 解锁：有密码机型露出系统 bouncer，无密码机型直达桌面；随后结束自身。
    ///
    /// 顺序有讲究：有密码时先让 bouncer 浮上来再收掉覆盖层（延迟 finish），
    /// 否则 finish 可能打断正在启动的解锁流程，用户看到的是「闪一下又回到锁屏」。
    private fun unlock() {
        if (unlocking) return
        unlocking = true
        var secure = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val km = getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
                secure = km?.isKeyguardSecure == true
                km?.requestDismissKeyguard(this, null)
            } catch (_: Exception) {
                // 非锁屏状态调用会抛异常：忽略，直接 finish 即可
            }
        }
        // 无论解锁是否成功都必须结束自身：最坏退化回「系统锁屏照常显示」，
        // 绝不把可触控的全屏覆盖层留在锁屏上（那会挡住系统解锁手势）。
        val delay = if (secure) 250L else 0L
        val decor = window?.decorView
        if (decor != null && delay > 0L) {
            decor.postDelayed({ try { finish() } catch (_: Exception) {} }, delay)
        } else {
            try { finish() } catch (_: Exception) {}
        }
    }

    // ===== 卡片动作派发 =====

    override fun onCardAction(button: CardButton) {
        when (button) {
            CardButton.favorite -> {
                // 乐观翻转：Dart 收藏接口返回后会用 updateLockScreenFavorite 推权威值纠正
                lyricView.flipFavoriteLocally()
                AudioPlaybackService.dispatchUiAction(this, AudioPlaybackService.ACTION_TOGGLE_FAVORITE)
            }
            CardButton.previous -> AudioPlaybackService.dispatchUiAction(this, AudioPlaybackService.ACTION_PREV)
            CardButton.playPause -> AudioPlaybackService.dispatchUiAction(this, AudioPlaybackService.ACTION_PLAY_PAUSE)
            CardButton.next -> AudioPlaybackService.dispatchUiAction(this, AudioPlaybackService.ACTION_NEXT)
            CardButton.cast -> requestAppAction("openCast")
            CardButton.queue -> requestAppAction("openQueue")
        }
    }

    /// 投屏/队列都是 Flutter 页面：拉起 App 并把动作交给 Dart，同时解锁退出锁屏层。
    private fun requestAppAction(action: String) {
        MainActivity.requestWidgetAction(this, action)
        // 直接 finish 会让 App 停在系统锁屏之后（MainActivity 不是 showWhenLocked），
        // 故走 unlock()：先 requestDismissKeyguard 再 finish，用户能真正看到目标面板。
        unlock()
    }

    /// View 侧上滑/双击手势的解锁请求。
    override fun onUnlockRequested() {
        unlock()
    }

    /// 封面变化：换背景模糊图与卡片圆角缩略图（同一套加载/挂起重投逻辑）。
    override fun onArtworkChanged(artUrl: String?, fallbackFilePath: String?) {
        updateBackground(artUrl, fallbackFilePath)
    }

    // ===== 数据回投 =====

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

    private fun postFavoriteUpdate() {
        if (::lyricView.isInitialized) {
            runOnUiThread { lyricView.applyFavoriteOnly() }
        }
    }

    // ===== 背景模糊图（下沉到 ImageView，只在切歌/尺寸变化时替换）=====

    private fun updateBackground(artUrl: String?, fallbackFilePath: String?) {
        if (artUrl == lastArtUrl && fallbackFilePath == lastFallbackPath) return
        lastArtUrl = artUrl
        lastFallbackPath = fallbackFilePath
        loadBackgroundBitmap(artUrl, fallbackFilePath)
    }

    /// 后台线程解码 + 模糊，主线程替换 ImageView 位图并投递封面缩略图。
    ///
    /// 保留既有「加载中再来的请求挂 pending、完成后重投」语义：
    /// 切歌很快时不会因为线程占用而丢掉最后一次封面。
    private fun loadBackgroundBitmap(artUrl: String?, fallbackFilePath: String?) {
        if (loadingBackground) {
            pendingArt = artUrl
            pendingFallback = fallbackFilePath
            return
        }
        loadingBackground = true
        Thread {
            var blurred: Bitmap? = null
            var thumb: Bitmap? = null
            try {
                val src = loadArtBitmap(artUrl, fallbackFilePath)
                if (src != null) {
                    // 先烤卡片缩略图（144px 起，按密度取整），再回收原图
                    val thumbSize = maxOf(
                        LockScreenCardRenderer.COVER_THUMB_PX,
                        (LockScreenCardLogic.coverDp * resources.displayMetrics.density).toInt()
                    ).coerceAtMost(384)
                    thumb = try {
                        LockScreenCardRenderer.bakeCoverThumbnail(
                            src, thumbSize, 12f * resources.displayMetrics.density
                        )
                    } catch (_: Exception) {
                        null
                    }
                    blurred = blurArtBitmap(src)
                    if (blurred == null) src.recycle()
                }
            } catch (_: Exception) {
                blurred = null
            }
            val finalBlur = blurred
            val finalThumb = thumb
            runOnUiThread {
                loadingBackground = false
                if (!isFinishing && !isDestroyed) {
                    if (finalBlur != null) {
                        val old = backgroundBitmap
                        backgroundBitmap = finalBlur
                        backgroundView.setImageBitmap(finalBlur)
                        if (old != null && old !== finalBlur && !old.isRecycled) old.recycle()
                    }
                    lyricView.setCoverThumbnail(finalThumb)
                } else {
                    finalBlur?.recycle()
                    finalThumb?.recycle()
                }
                repostPending()
            }
        }.start()
    }

    /// 降采样到 200px 长边后 RenderScript 模糊；失败退回重度降采样（视觉近似）。
    private fun blurArtBitmap(src: Bitmap): Bitmap? {
        val scale = 200f / maxOf(src.width, src.height).toFloat()
        val smallW = (src.width * scale).toInt().coerceAtLeast(1)
        val smallH = (src.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, smallW, smallH, true)
        if (scaled !== src) src.recycle()
        return try {
            val rs = android.renderscript.RenderScript.create(applicationContext)
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
                return contentResolver.openInputStream(Uri.parse(artUrl))
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
}

/// 单行歌词渲染前测量结果（换行拆分 + 块高 + 逐行 baseline + 副行拆分）。
///
/// 与 AM 播放页同口径的两处关键缓存：
/// - `rowBaselines`：每个视觉行的 baseline（相对行块顶）。旧实现绘制时用
///   `行顶 - ascent`，把行盒里的 leading 全压在字形下方；这里改为半行距模型
///   （见 [LockScreenLyricMetrics.baselineInBox]），字形在行盒内居中。
/// - `auxBaselines`：副行每个视觉行的 baseline。同样走半行距，且副行预留高度
///   按实际行数增长（`rows × 1.5em + 0.3em`）。
///
/// 两者都在布局重建时算好，绘制期只做 `topY + baselines[i]`，零每帧算术/分配。
/// 副行拆分（`splitByChar`）也随布局缓存，不再每帧重算。
private class RenderedLine(
    val rowTexts: List<String>,   // 主文本换行后的视觉行文本
    val rowStarts: IntArray,      // 逐字行：每视觉行的起始 word 索引；纯文本行为空
    val hasWords: Boolean,
    val height: Float,            // 块高（含换行与副行空间）
    val subRows: List<String>,    // 副行（翻译/罗马音）按可视宽拆分结果
    val rowBaselines: FloatArray, // 每个视觉行的 baseline（相对块顶）
    val auxBaselines: FloatArray, // 副行每个视觉行的 baseline（相对块顶）
)

/// 锁屏歌词 Canvas 滚动渲染视图（AM Apple Music 风格对齐）。
///
/// 布局规范对齐 `lyric_layout.dart`：
/// - 当前行在歌词可视带内居中（见 topInset / bottomInset，底部为玻璃卡片让位）
/// - 行盒半行距：换行视觉行盒 = 主行盒 × 0.8，行盒内 leading 上下各半（字形居中）；
///   副行字号 = max(主字 × 0.7, 可读下限)，副行行盒 = 1.5em，与主行间隙 0.3em，
///   副行预留高度随视觉行数增长 —— 口径与几何全部见 [LockScreenLyricMetrics]
/// - 非当前行暗态 alpha 0.2，当前行亮 0.92；动态取色为「85% 白 + 15% 主色」
/// - 位置由 Choreographer 帧循环用系统时钟自增推进，向低频真实位置做慢速指数校正
///   （避免每次 Dart 500ms 推送引起速度抖动 / 卡顿）
/// - 帧循环「60fps 封顶 + 静止即停表」：见 [LockScreenFrameGate] 与 doFrame 的停表条件
class LockScreenLyricView @JvmOverloads constructor(
    context: Context,
    attrs: android.util.AttributeSet? = null,
) : View(context, attrs) {

    /// 卡片按钮与解锁手势的回调（由 Activity 实现）。
    interface Listener {
        fun onCardAction(button: CardButton)
        /// 上滑/双击解锁请求。
        fun onUnlockRequested()
        /// 封面地址变化：由 Activity 换背景模糊图与卡片缩略图（只在切歌时触发）。
        fun onArtworkChanged(artUrl: String?, fallbackFilePath: String?)
    }

    private val transOpacity = 0.5f
    private val darkAlpha = 0.20f
    private val brightAlpha = 0.92f
    private val dimMixRatio = 0.15f
    // 位置校正速率：越低越平滑；仅吸收与真实播放位置的轻微漂移，不制造可见跳变
    private val corrRate = 5.0
    private val scrollRate = 30.0
    private val seekJumpMs = 800L

    /// 「上滑解锁」提示展示时长与淡出动画时长。
    private val hintVisibleMs = 2000L
    private val hintFadeMs = 400L
    private val hintText = "上滑或双击解锁"

    var listener: Listener? = null

    private val dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x4DFFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private val brightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private val transPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x80FFFFFF.toInt()
        textAlign = Paint.Align.LEFT
    }
    private val placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x66FFFFFF.toInt()
        textAlign = Paint.Align.CENTER
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x73FFFFFF.toInt()
        textAlign = Paint.Align.CENTER
    }

    private val cardRenderer = LockScreenCardRenderer(this)

    private var curLines: List<LockLyricLine> = emptyList()
    private var placeholder = ""
    private var title = ""
    private var artist = ""
    private var authoritativePosMs = 0L
    private var durationMs = 0L
    private var isPlayingFlag = false
    private var isFavorited = false

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

    /// 动画收敛标记：false 表示上一帧仍在运动，帧循环必须继续。
    private var scrollSettled = true
    private var alphaSettled = true

    /// 「上滑解锁」提示状态（亮屏后 2s 内 alpha 1→0，收敛即停表）。
    private var hintAnimating = false
    private var hintAlpha = 0f
    private var hintStartMs = 0L

    // ===== 卡片几何缓存（尺寸/档位/高度不变时复用，触摸与绘制共用同一份）=====
    private var cachedGeo: CardGeometry? = null
    private var cachedRects: Map<CardButton, CardGeometry> = emptyMap()
    private var cachedMode: CardMode = CardMode.full
    private var cachedGeoW = -1
    private var cachedGeoH = -1
    private var cachedHeightDp = -1f

    // ===== 触摸状态 =====
    private var downX = 0f
    private var downY = 0f
    private var pressedButton: CardButton? = null
    private var velocityTracker: VelocityTracker? = null
    private var lastTapUpMs = 0L

    private val frameGate = LockScreenFrameGate(16L)

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val now = SystemClock.uptimeMillis()
            // 停表条件：播放中 / 提示动画中 / 滚动未收敛 / 透明度未收敛，任一成立才继续
            val busy = isPlayingFlag || hintAnimating || !scrollSettled || !alphaSettled
            if (!busy) {
                frameRunning = false
                lastFrameMs = 0L
                return
            }
            // 120Hz 屏 vsync 约 8.3ms：闸门把实际重绘封顶在 60fps，
            // 位置推进用「上次真正绘制」的真实 dt，速度不失真。
            if (frameGate.shouldDraw(now)) {
                val dtMs = if (lastFrameMs > 0L) (now - lastFrameMs).toLong() else 16L
                lastFrameMs = now
                val dtSec = dtMs.coerceIn(1L, 100L) / 1000.0
                if (isPlayingFlag) advancePosition(dtSec, now)
                scrollSettled = advanceScroll(dtSec)
                alphaSettled = advanceLineAlpha(dtSec)
                if (hintAnimating) advanceHint(now)
                invalidate()
            }
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
        // 只要视图可见就（重新）启动帧循环；isPlaying 由 doFrame 判读。
        // 这保留「首次锁屏/切歌与整包推送竞态导致 isPlaying 那一刻为 false」的修复语义：
        // 数据/进度/可见性任一变化都会重启循环，isPlaying 转 true 时立即可推进。
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
        cardRenderer.release()
        velocityTracker?.recycle()
        velocityTracker = null
    }

    fun onScreenHidden() {
        stopFrameLoop()
    }

    /// 启动帧循环：重启时重置闸门，保证第一帧立即绘制。
    private fun startFrameLoop() {
        if (frameRunning) return
        frameRunning = true
        lastFrameMs = 0L
        frameGate.reset()
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun stopFrameLoop() {
        frameRunning = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    /// 请求重绘并确保帧循环活着（按钮态/收藏翻转/暂停刷新等一次性变化走这里）。
    fun requestRedraw() {
        startFrameLoop()
        invalidate()
    }

    /// 亮屏后展示「上滑或双击解锁」提示，2s 内淡出。
    fun startUnlockHint() {
        hintStartMs = SystemClock.uptimeMillis()
        hintAlpha = 1f
        hintAnimating = true
        requestRedraw()
    }

    /// 整包数据应用：重建样式与布局缓存、换背景/缩略图、按需吸附位置。
    fun applyLatestData() {
        val d = LockScreenLyricActivity.currentData()
        curLines = d.lines
        placeholder = d.placeholder
        title = d.title
        artist = d.artist
        authoritativePosMs = d.currentPositionMs
        durationMs = d.durationMs
        isPlayingFlag = d.isPlaying
        isFavorited = d.isFavorited
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
        lastFrameMs = 0L
        // 数据变化必须重启帧循环（保留「任何推送都重启」的竞态修复语义）；
        // 是否继续由 doFrame 的停表条件决定，静止时会在下一帧自行停下。
        requestRedraw()
        // 封面只在切歌/换歌时变：Activity 侧对同一地址去重，不会重复解码
        listener?.onArtworkChanged(d.artUrl, d.fallbackFilePath)
    }

    /// 轻量进度应用：只改位置/播放态，不动布局。
    /// 播放中由帧循环驱动重绘，不额外 invalidate（避免双重无效重绘）；
    /// 暂停时静态位置需要刷新一帧（帧循环会按停表条件自行收敛停下）。
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
        lastFrameMs = 0L
        if (isPlayingFlag) {
            startFrameLoop()
        } else {
            requestRedraw()
        }
    }

    /// 收藏态增量更新：只翻红心并重绘一帧。
    fun applyFavoriteOnly() {
        isFavorited = LockScreenLyricActivity.currentData().isFavorited
        requestRedraw()
    }

    /// 点击收藏后本地先翻转，等 Dart 的权威值回来纠正（网络失败时也不会毫无反馈）。
    fun flipFavoriteLocally() {
        isFavorited = !isFavorited
        requestRedraw()
    }

    fun setCoverThumbnail(bitmap: Bitmap?) {
        cardRenderer.setCoverThumbnail(bitmap)
        requestRedraw()
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
        // 布局重建后透明度/滚动都要重新收敛，否则暂停态下重排会停在暗态
        scrollSettled = false
        alphaSettled = false
        invalidateCardGeometry()
    }

    private fun rebuildTypeface() {
        val weight = curWeight.coerceIn(300, 900)
        val baseTypeface = resolveTypeface(weight)
        val curPx = dp(curSize).coerceIn(dp(12f), dp(60f))
        // 副行字号与 AM 同口径：max(主字 × 0.7, 可读下限)，下限按字重取 12/13
        val transPx = LockScreenLyricMetrics.auxFontSize(curPx, weight)
            .coerceAtLeast(dp(10f))

        dimPaint.apply {
            color = 0x4DFFFFFF.toInt()
            textSize = curPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        brightPaint.apply {
            color = 0xFFFFFFFF.toInt()
            textSize = curPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        transPaint.apply {
            color = 0x80FFFFFF.toInt()
            textSize = transPx
            textAlign = Paint.Align.LEFT
            typeface = baseTypeface
        }
        placeholderPaint.apply {
            color = 0x66FFFFFF.toInt()
            textSize = dp(15f)
            textAlign = Paint.Align.CENTER
        }
        hintPaint.textSize = dp(11f)
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

    /// 构建每行块高 + 换行拆分 + 逐行 baseline + 前缀和。数据/样式/视口宽度变化时重建。
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
        // 行盒半行距需要字体度量：主行与副行各取一次（绘制期不再读 fontMetrics）
        val mainFm = dimPaint.fontMetrics
        val mainAscAbs = -mainFm.ascent
        val mainDescent = mainFm.descent
        val auxFm = transPaint.fontMetrics
        val auxAscAbs = -auxFm.ascent
        val auxDescent = auxFm.descent
        val auxFontPx = transPaint.textSize

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
            // 副行拆分随布局缓存，绘制期不再每帧 splitByChar
            val subRows = if (hasSub) splitByChar(line.sub, maxW) else emptyList()
            val auxRows = subRows.size
            // 视觉行 baseline：半行距（行盒内 leading 上下各半），与 AM 的行盒模型同式
            val rowBaselines = FloatArray(rows)
            for (ri in 0 until rows) {
                rowBaselines[ri] = LockScreenLyricMetrics.mainRowBaseline(
                    mainH, ri, mainAscAbs, mainDescent,
                )
            }
            val auxBaselines = FloatArray(auxRows)
            for (aj in 0 until auxRows) {
                auxBaselines[aj] = LockScreenLyricMetrics.auxRowBaseline(
                    mainH, rows, auxFontPx, aj, auxAscAbs, auxDescent,
                )
            }
            // 块高与 AM 同式：主文本(含换行) + 副行预留(随副行行数增长)
            val h = LockScreenLyricMetrics.lineBlockHeight(mainH, rows, auxFontPx, auxRows)
            lineTop[li] = cursor
            cursor += h
            list.add(RenderedLine(rowTexts, rowStarts, hasW, h, subRows, rowBaselines, auxBaselines))
        }
        rendered = list
        for (i in lineAlpha.indices) lineAlpha[i] = darkAlpha
        // 首次/重建后直接吸附到当前行，避免打开时从歌词顶部滚动到当前行的突兀动画
        smoothScrollY = scrollTargetFor(currentLineIndex())
        scrollSettled = true
        alphaSettled = false
        invalidate()
    }

    override fun onSizeChanged(w: Int, hIn: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, hIn, oldw, oldh)
        cardRenderer.clearIconCache()
        invalidateCardGeometry()
        resetLayoutCache()
        requestRedraw()
    }

    // ================= 保留区 / 卡片几何 =================

    private fun density(): Float = resources.displayMetrics.density

    /// 状态栏高度（沉浸式下通常为 0，用于顶部保留区兜底）。
    private fun statusBarInset(): Float {
        val insets = rootWindowInsets ?: return 0f
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            insets.getInsets(android.view.WindowInsets.Type.statusBars()).top.toFloat()
        } else {
            @Suppress("DEPRECATION")
            insets.systemWindowInsetTop.toFloat()
        }
    }

    /// 顶部保留区：不再有「歌名 · 歌手」header，只留安全距离。
    private fun topInset(): Float = maxOf(dp(72f), statusBarInset() + dp(16f))

    /// 卡片是否展示：有歌曲信息或有歌词时展示。
    private fun showCard(): Boolean = title.isNotEmpty() || curLines.isNotEmpty()

    private fun cardMode(): CardMode =
        if (width > height) CardMode.compact else LockScreenCardLogic.resolveCardMode(height / density())

    private fun cardHeightDp(mode: CardMode): Float =
        LockScreenCardLogic.cardHeightDp(mode, cardRenderer.densityScale, showProgress = durationMs > 0L)

    /// 底部保留区：卡片高 + 32dp 外边距 + 16dp 间距；卡片隐藏时只留 40dp。
    private fun bottomInset(): Float {
        if (!showCard()) return dp(40f)
        return cardHeightDp(cardMode()) * density() + dp(LockScreenCardLogic.bottomMarginDp) + dp(16f)
    }

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

    private fun invalidateCardGeometry() {
        cachedGeo = null
        cachedRects = emptyMap()
        cachedGeoW = -1
        cachedGeoH = -1
        cachedHeightDp = -1f
    }

    /// 卡片几何（绘制与触摸共用）：尺寸/档位/高度不变时复用缓存。
    private fun ensureCardGeometry(): Pair<CardGeometry, Map<CardButton, CardGeometry>>? {
        val w = width
        val h = height
        if (w <= 0 || h <= 0) return null
        val mode = cardMode()
        val heightDp = cardHeightDp(mode)
        val geo = cachedGeo
        if (geo != null && cachedGeoW == w && cachedGeoH == h &&
            cachedHeightDp == heightDp && cachedMode == mode
        ) {
            return Pair(geo, cachedRects)
        }
        val newGeo = LockScreenCardLogic.cardGeometry(w.toFloat(), h.toFloat(), density(), heightDp)
        // 字体缩放要传进热区计算：行 1 长高时行 2 整体下移，否则点不中按钮
        val rects = LockScreenCardLogic.buttonRects(newGeo, density(), mode, cardRenderer.densityScale)
        cachedGeo = newGeo
        cachedRects = rects
        cachedGeoW = w
        cachedGeoH = h
        cachedHeightDp = heightDp
        cachedMode = mode
        return Pair(newGeo, rects)
    }

    // ================= 帧推进 =================

    /// 播放位置推进：时钟自增 + 向低频真实位置慢速指数校正。
    private fun advancePosition(dtSec: Double, now: Long) {
        smoothPosMs += dtSec * 1000.0
        val elapsed = (now - lastAuthorityMs).toDouble()
        val rawTarget = authoritativePosMs + elapsed
        // 时长未知（0）时不夹取，避免把位置拖回 0
        val target = if (durationMs > 0L) rawTarget.coerceAtMost(durationMs.toDouble()) else rawTarget
        val diff = target - smoothPosMs
        val k = 1.0 - exp(-corrRate * dtSec)
        smoothPosMs += diff * k
        if (abs(diff) < 0.5) smoothPosMs = target
        if (smoothPosMs < 0.0) smoothPosMs = 0.0
    }

    /// 滚动推进；返回是否已收敛（收敛后帧循环可以停表）。
    private fun advanceScroll(dtSec: Double): Boolean {
        val idx = currentLineIndex()
        if (idx < 0 || rendered.isEmpty()) return true
        val target = scrollTargetFor(idx)
        val k = 1.0 - exp(-scrollRate * dtSec)
        smoothScrollY += ((target - smoothScrollY) * k).toFloat()
        if (abs(target - smoothScrollY) < 0.5f) {
            smoothScrollY = target
            return true
        }
        return false
    }

    /// 行透明度推进；返回是否已全部收敛。
    private fun advanceLineAlpha(dtSec: Double): Boolean {
        val idx = currentLineIndex()
        val n = lineAlpha.size
        if (n == 0) return true
        val kDark = 1.0 - exp(-4.0 * dtSec)
        val kBright = 1.0 - exp(-24.0 * dtSec)
        var settled = true
        for (i in 0 until n) {
            val target = if (i == idx) brightAlpha else darkAlpha
            val k = if (i == idx) kBright.toFloat() else kDark.toFloat()
            val next = lineAlpha[i] + (target - lineAlpha[i]) * k
            if (abs(next - target) < 0.001f) {
                lineAlpha[i] = target
            } else {
                lineAlpha[i] = next
                settled = false
            }
        }
        return settled
    }

    /// 提示淡出：亮屏后 2s 内 alpha 1→0（之后 400ms 淡出）。
    private fun advanceHint(now: Long) {
        val elapsed = now - hintStartMs
        val fadeStart = hintVisibleMs
        hintAlpha = if (elapsed <= fadeStart) {
            1f
        } else {
            val t = ((elapsed - fadeStart).toFloat() / hintFadeMs).coerceIn(0f, 1f)
            1f - t
        }
        if (hintAlpha <= 0f) {
            hintAlpha = 0f
            hintAnimating = false
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

        // 背景（模糊封面）由 Activity 的 ImageView 承载，本层保持透明，不再每帧全屏 blit

        if (curLines.isEmpty()) {
            if (placeholder.isNotEmpty()) {
                val cy = topInset() + availH() * 0.5f
                canvas.drawText(
                    placeholder, w / 2f,
                    cy - (placeholderPaint.ascent() + placeholderPaint.descent()) / 2f,
                    placeholderPaint
                )
            }
            drawCardIfNeeded(canvas)
            drawUnlockHint(canvas, h)
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

        // 将歌词绘制严格限制在可视带内，绝不越界顶/底保留区（卡片区域）
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

        drawCardIfNeeded(canvas)
        drawUnlockHint(canvas, h)
    }

    private fun drawCardIfNeeded(canvas: Canvas) {
        if (!showCard()) return
        val geoPair = ensureCardGeometry() ?: return
        val state = LockCardState(
            title = title,
            artist = artist,
            positionMs = smoothPosMs.toLong(),
            durationMs = durationMs,
            isPlaying = isPlayingFlag,
            isFavorited = isFavorited,
            accentColor = curAccent,
        )
        cardRenderer.draw(canvas, geoPair.first, cachedMode, state, geoPair.second, pressedButton)
    }

    private fun drawUnlockHint(canvas: Canvas, h: Float) {
        if (!hintAnimating && hintAlpha <= 0f) return
        hintPaint.alpha = (hintAlpha * 0.45f * 255f).toInt().coerceIn(0, 255)
        val geo = ensureCardGeometry()?.first
        val baseline = (geo?.top ?: (h - dp(120f))) - dp(16f)
        canvas.drawText(hintText, width / 2f, baseline, hintPaint)
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
            dimPaint.alpha = (alpha * 255).toInt().coerceIn(0, 255)
            // baseline 已按「行盒半行距」在布局期算好，绘制期零算术
            for (ri in rl.rowTexts.indices) {
                canvas.drawText(rl.rowTexts[ri], baseX, topY + rl.rowBaselines[ri], dimPaint)
            }
            drawSubIfNeeded(canvas, rl, topY, baseX)
        }
    }

    private fun lineAlphaAt(idx: Int): Float =
        if (idx in lineAlpha.indices) lineAlpha[idx] else darkAlpha

    /// 当前行逐字二分色：先全字暗色，再按 maskX 裁剪亮色。
    private fun drawCurWordLine(
        canvas: Canvas, line: LockLyricLine, rl: RenderedLine, topY: Float, baseX: Float, maskXIn: Float,
    ) {
        val brightColor = if (curUseDynamic) mixWhiteAccent(curAccent, dimMixRatio) else 0xFFFFFFFF.toInt()
        brightPaint.color = brightColor

        val words = line.words
        val n = words.size
        if (n == 0) {
            dimPaint.alpha = (darkAlpha * 255).toInt()
            for (ri in rl.rowTexts.indices) {
                canvas.drawText(rl.rowTexts[ri], baseX, topY + rl.rowBaselines[ri], dimPaint)
            }
            drawSubIfNeeded(canvas, rl, topY, baseX)
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
            val rowY = topY + rl.rowBaselines[ri]
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
                val rowY = topY + rl.rowBaselines[ri]
                canvas.save()
                canvas.clipRect(baseX, topY, baseX + sung, topY + rl.height)
                for (i in s until e) {
                    canvas.drawText(words[i].text, baseX + (curWordStarts[i] - rowRel), rowY, brightPaint)
                }
                canvas.restore()
            }
        }
        drawSubIfNeeded(canvas, rl, topY, baseX)
    }

    /// 当前行副行（翻译/罗马音）绘制在主文本视觉行之后、块内底部。
    ///
    /// 位置口径与 AM 一致：`mainH(rows) + 0.3em` 起，每个副行视觉行占 `1.5em` 行盒、
    /// 盒内半行距居中。baseline 已在布局期算好（[RenderedLine.auxBaselines]），
    /// 这里只做绘制；副行换行时每行位置同样来自该表，不会互相挤压。
    private fun drawSubIfNeeded(canvas: Canvas, rl: RenderedLine, topY: Float, baseX: Float) {
        if (!curShowTrans || rl.subRows.isEmpty()) return
        transPaint.alpha = (transOpacity * 255).toInt()
        for (ri in rl.subRows.indices) {
            canvas.drawText(rl.subRows[ri], baseX, topY + rl.auxBaselines[ri], transPaint)
        }
    }

    private fun mixWhiteAccent(accent: Int, ratio: Float): Int {
        val r = ((255 * (1 - ratio)) + ((accent shr 16) and 0xFF) * ratio).toInt().coerceIn(0, 255)
        val g = ((255 * (1 - ratio)) + ((accent shr 8) and 0xFF) * ratio).toInt().coerceIn(0, 255)
        val b = ((255 * (1 - ratio)) + (accent and 0xFF) * ratio).toInt().coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    // ================= 触摸 =================

    private fun hitButton(x: Float, y: Float): CardButton? {
        val rects = ensureCardGeometry()?.second ?: return null
        return LockScreenCardLogic.hitTest(x, y, rects)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                velocityTracker?.recycle()
                velocityTracker = VelocityTracker.obtain().also { it.addMovement(event) }
                pressedButton = hitButton(event.x, event.y)
                if (pressedButton != null) requestRedraw()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                velocityTracker?.addMovement(event)
                // 向上拖动超过 24dp：视为解锁手势，取消按钮按压态
                if (pressedButton != null && downY - event.y > dp(24f)) {
                    pressedButton = null
                    requestRedraw()
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                velocityTracker?.addMovement(event)
                velocityTracker?.computeCurrentVelocity(1000)
                val vy = velocityTracker?.yVelocity ?: 0f
                velocityTracker?.recycle()
                velocityTracker = null

                val dy = event.y - downY
                val moved = hypot(event.x - downX, dy)
                val hit = hitButton(event.x, event.y)
                val pressed = pressedButton
                pressedButton = null

                // 1) 上滑解锁（位移或速度任一达标）
                if (LockScreenCardLogic.shouldUnlockSwipe(dy, vy, density())) {
                    requestRedraw()
                    listener?.onUnlockRequested()
                    return true
                }
                // 2) 双击解锁：仅限卡片外的歌词区（卡片内双击多半是想连点按钮）
                val inCard = ensureCardGeometry()?.first?.contains(event.x, event.y) == true
                if (hit == null && !inCard && moved < dp(12f)) {
                    val now = SystemClock.uptimeMillis()
                    if (now - lastTapUpMs in 1 until 300L) {
                        lastTapUpMs = 0L
                        listener?.onUnlockRequested()
                        return true
                    }
                    lastTapUpMs = now
                } else {
                    lastTapUpMs = 0L
                }
                // 3) 按钮点击：同一起止按钮 + 位移 < 12dp
                if (pressed != null && pressed == hit && moved < dp(12f)) {
                    performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    listener?.onCardAction(pressed)
                }
                requestRedraw()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                velocityTracker?.recycle()
                velocityTracker = null
                if (pressedButton != null) {
                    pressedButton = null
                    requestRedraw()
                }
                return true
            }
        }
        return true
    }

    private fun dp(v: Float): Float = v * resources.displayMetrics.density
}
