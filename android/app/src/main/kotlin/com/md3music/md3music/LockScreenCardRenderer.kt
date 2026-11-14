package com.md3music.md3music

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.text.TextPaint
import android.text.TextUtils
import android.view.View

/// 卡片绘制所需的一帧数据快照（由 LockScreenLyricView 组装，渲染器只读）。
internal data class LockCardState(
    val title: String = "",
    val artist: String = "",
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val isPlaying: Boolean = false,
    val isFavorited: Boolean = false,
    val accentColor: Int = 0,
)

/// 锁屏歌词底部「Now Playing」玻璃卡片渲染器。
///
/// 设计要点（对应功耗预算）：
/// - 图标全部预烤成小位图并缓存，绘制期只 `drawBitmap`，避免每帧解析 VectorDrawable；
/// - 文本 ellipsize 结果按「文本 + 可用宽 + 字号」缓存，只在数据/尺寸变化时重排；
/// - 卡片本身无循环动画，静止时不产生任何重绘。
///
/// 几何口径与 [LockScreenCardLogic] 共用同一份常量，保证「画在哪」与「点在哪」一致。
internal class LockScreenCardRenderer(private val host: View) {

    companion object {
        /// 卡片底色：12% 白，透出背景模糊封面形成玻璃感。
        private const val CARD_FILL = 0x1FFFFFFF
        /// 卡片描边：20% 白，1dp。
        private const val CARD_STROKE = 0x33FFFFFF
        /// 播放圆钮底色（比卡片略亮，作为主操作视觉焦点）。
        private const val PLAY_FILL = 0x26FFFFFF
        /// 播放圆钮描边：白 80%。
        private const val PLAY_STROKE = 0xCCFFFFFF.toInt()
        /// 收藏红心：与 App 内 FavoritesProvider 的红心语义色对齐。
        /// 这里不用动态取色：封面主色可能是任意颜色，染成绿色/蓝色会让「已收藏」不可辨识。
        private const val FAVORITE_ON = 0xFFFF4D5E.toInt()
        /// 未收藏描边心：白 80%。
        private const val FAVORITE_OFF = 0xCCFFFFFF.toInt()

        /// 封面缩略图边长（px 基准 144，按密度换算由调用方传入）。
        const val COVER_THUMB_PX = 144

        /// 在后台线程把封面解码结果烤成圆角缩略图（144px、12dp 圆角）。
        ///
        /// 用 BitmapShader + 圆角矩形裁剪，一次成型；返回的位图与入参互不共享像素，
        /// 调用方可安全回收原图。
        fun bakeCoverThumbnail(src: Bitmap, sizePx: Int, radiusPx: Float): Bitmap {
            val size = sizePx.coerceAtLeast(1)
            val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
            // centerCrop：等比放大到覆盖正方形后居中裁切
            val scale = maxOf(size / src.width.toFloat(), size / src.height.toFloat())
            val dw = src.width * scale
            val dh = src.height * scale
            val dx = (size - dw) / 2f
            val dy = (size - dh) / 2f
            val matrix = android.graphics.Matrix().apply {
                setScale(scale, scale)
                postTranslate(dx, dy)
            }
            paint.shader = BitmapShader(src, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                setLocalMatrix(matrix)
            }
            canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), radiusPx, radiusPx, paint)
            return out
        }
    }

    private val density = host.resources.displayMetrics.density
    // 字体缩放比（用户设置的大字体）：用 configuration.fontScale，避免 scaledDensity 弃用告警
    private val fontScale = host.resources.configuration.fontScale.coerceIn(0.8f, 2.0f)

    private val cardPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CARD_FILL }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = CARD_STROKE
    }
    private val playFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = PLAY_FILL }
    private val playStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = PLAY_STROKE
    }
    private val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textSize = sp(15f)
        typeface = mediumTypeface()
    }
    private val artistPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x99FFFFFF.toInt()
        textSize = sp(12f)
    }
    private val timePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x8CFFFFFF.toInt()
        textSize = sp(11f)
    }
    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x33FFFFFF }
    private val trackFgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
    private val coverPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x59FFFFFF }
    private val bitmapRect = RectF()
    /// 复用矩形：绘制期零分配（每帧会画轨道/进度各一次）。
    private val tmpRect = RectF()

    /// 时间文本缓存：`formatTime` 的结果按秒缓存，避免每帧拼两个字符串。
    private var elapsedSecCache = -1L
    private var elapsedTextCache = ""
    private var totalSecCache = -1L
    private var totalTextCache = ""

    private fun elapsedText(ms: Long): String {
        val sec = (ms / 1000L).coerceAtLeast(0L)
        if (sec != elapsedSecCache) {
            elapsedSecCache = sec
            elapsedTextCache = LockScreenCardLogic.formatTime(sec * 1000L)
        }
        return elapsedTextCache
    }

    private fun totalText(ms: Long): String {
        val sec = (ms / 1000L).coerceAtLeast(0L)
        if (sec != totalSecCache) {
            totalSecCache = sec
            totalTextCache = LockScreenCardLogic.formatTime(sec * 1000L)
        }
        return totalTextCache
    }

    /// 图标位图缓存：同「资源 + 边长 + 着色」只烘焙一次，绘制期零解析、零分配。
    ///
    /// 不用 `HashMap<Long, Bitmap>`：三元组塞不进 64 位（资源 id 32 + 边长 16 + 颜色 32），
    /// 截断后不同 drawable 可能撞 key 串图。条目上限很小（≤32），线性扫描比较三个 Int
    /// 比装箱 Long 更快且完全精确。
    private class IconEntry(val resId: Int, val sizePx: Int, val tint: Int, val bitmap: Bitmap)

    private val iconCache = ArrayList<IconEntry>(16)

    /// 封面圆角缩略图（后台线程烤好后投递到主线程）。
    private var coverThumb: Bitmap? = null

    private var titleCacheKey: String? = null
    private var titleCacheWidth = -1f
    private var titleCacheSize = -1f
    private var titleCacheValue: CharSequence = ""

    private var artistCacheKey: String? = null
    private var artistCacheWidth = -1f
    private var artistCacheSize = -1f
    private var artistCacheValue: CharSequence = ""

    /// 字体缩放比：1.3 倍字体时卡片按同比例长高，避免文字压到进度行。
    val densityScale: Float get() = fontScale

    fun setCoverThumbnail(bitmap: Bitmap?) {
        if (coverThumb === bitmap) return
        // 换歌时旧缩略图不再被引用：由这里回收，避免每首歌漏一张 144px 位图
        val old = coverThumb
        coverThumb = bitmap
        if (old != null && old !== bitmap && !old.isRecycled) old.recycle()
    }

    /// 尺寸变化（旋转/分屏）时清空图标缓存：位图尺寸已变，旧缓存全部作废。
    fun clearIconCache() {
        for (entry in iconCache) {
            if (!entry.bitmap.isRecycled) entry.bitmap.recycle()
        }
        iconCache.clear()
    }

    fun release() {
        clearIconCache()
        coverThumb?.let { if (!it.isRecycled) it.recycle() }
        coverThumb = null
    }

    /// 绘制整张卡片。调用方保证 [rects] 与 [mode] 来自同一份几何计算。
    fun draw(
        canvas: Canvas,
        geo: CardGeometry,
        mode: CardMode,
        state: LockCardState,
        rects: Map<CardButton, CardGeometry>,
        pressed: CardButton?,
    ) {
        val radius = dp(LockScreenCardLogic.radiusDp)
        val cardRect = RectF(geo.left, geo.top, geo.right, geo.bottom)
        canvas.drawRoundRect(cardRect, radius, radius, cardPaint)
        strokePaint.strokeWidth = dp(1f)
        canvas.drawRoundRect(cardRect, radius, radius, strokePaint)

        if (mode == CardMode.compact) {
            drawCompactRow(canvas, geo, state, rects, pressed)
        } else {
            drawFullRows(canvas, geo, state, rects, pressed)
        }
    }

    // ================= full 档：三行 =================

    private fun drawFullRows(
        canvas: Canvas,
        geo: CardGeometry,
        state: LockCardState,
        rects: Map<CardButton, CardGeometry>,
        pressed: CardButton?,
    ) {
        val pad = dp(LockScreenCardLogic.paddingDp)
        val innerLeft = geo.left + pad
        val innerRight = geo.right - pad
        val row1Top = geo.top + pad
        // 行 1 高度与 LockScreenCardLogic 共用同一口径：字体放大到文本块高于封面时
        // 才长高，行 2/行 3 的下推位置必须跟着它走，否则会与卡片底边错位。
        val row1H = dp(LockScreenCardLogic.row1HeightDp(CardMode.full, fontScale))
        val coverSize = dp(LockScreenCardLogic.coverDp)

        // 行 1：封面（在行高内垂直居中）+ 歌名/歌手 + 投屏键
        drawCover(canvas, innerLeft, row1Top + (row1H - coverSize) / 2f, coverSize)
        val textLeft = innerLeft + coverSize + dp(LockScreenCardLogic.gap1Dp)
        val castRect = rects[CardButton.cast]
        val textRight = (castRect?.left ?: innerRight) - dp(8f)
        drawTitleAndArtist(canvas, textLeft, row1Top, row1H, textRight - textLeft, state)
        castRect?.let {
            drawIcon(canvas, R.drawable.lockcard_ic_cast, it, 0xE6FFFFFF.toInt())
        }

        // 行 2：五键
        val row2Top = row1Top + row1H + dp(LockScreenCardLogic.gap1Dp)
        rects[CardButton.favorite]?.let {
            // 按压态统一提亮，与其它按钮一致
            val tint = when {
                pressed == CardButton.favorite -> 0xFFFFFFFF.toInt()
                state.isFavorited -> FAVORITE_ON
                else -> FAVORITE_OFF
            }
            val res = if (state.isFavorited) R.drawable.lockcard_ic_heart_on else R.drawable.lockcard_ic_heart_off
            drawIcon(canvas, res, it, tint)
        }
        rects[CardButton.previous]?.let {
            drawIcon(canvas, R.drawable.lockcard_ic_previous, it, if (pressed == CardButton.previous) 0xFFFFFFFF.toInt() else 0xE6FFFFFF.toInt())
        }
        rects[CardButton.next]?.let {
            drawIcon(canvas, R.drawable.lockcard_ic_next, it, if (pressed == CardButton.next) 0xFFFFFFFF.toInt() else 0xE6FFFFFF.toInt())
        }
        rects[CardButton.queue]?.let {
            drawIcon(canvas, R.drawable.lockcard_ic_queue, it, if (pressed == CardButton.queue) 0xFFFFFFFF.toInt() else 0xE6FFFFFF.toInt())
        }
        rects[CardButton.playPause]?.let {
            drawPlayButton(canvas, it, state.isPlaying)
        }

        // 行 3：时间 + 进度（时长未知时整行隐藏，卡片高度已同步减高）
        if (state.durationMs > 0L) {
            val row3Top = row2Top + dp(LockScreenCardLogic.transportDp) + dp(LockScreenCardLogic.gap2Dp)
            drawProgressRow(canvas, innerLeft, innerRight, row3Top, state)
        }
    }

    // ================= compact 档：单行 =================

    private fun drawCompactRow(
        canvas: Canvas,
        geo: CardGeometry,
        state: LockCardState,
        rects: Map<CardButton, CardGeometry>,
        pressed: CardButton?,
    ) {
        val pad = dp(LockScreenCardLogic.paddingDp)
        val innerLeft = geo.left + pad
        val innerRight = geo.right - pad
        val coverSize = dp(LockScreenCardLogic.compactCoverDp)
        val row1H = dp(LockScreenCardLogic.row1HeightDp(CardMode.compact, fontScale))
        val rowTop = geo.top + pad

        drawCover(canvas, innerLeft, rowTop + (row1H - coverSize) / 2f, coverSize)
        val textLeft = innerLeft + coverSize + dp(LockScreenCardLogic.gap1Dp)
        val playRect = rects[CardButton.playPause]
        val textRight = (playRect?.left ?: innerRight) - dp(8f)
        drawTitleAndArtist(canvas, textLeft, rowTop, row1H, textRight - textLeft, state)
        playRect?.let { drawPlayButton(canvas, it, state.isPlaying) }

        if (state.durationMs > 0L) {
            // 进度条贴卡片底，不画时间文本（紧凑档没有横向空间）
            val trackTop = geo.bottom - pad - dp(LockScreenCardLogic.trackDp)
            val ratio = LockScreenCardLogic.progressRatio(state.positionMs, state.durationMs)
            drawTrack(canvas, innerLeft, innerRight, trackTop, ratio)
        }
    }

    // ================= 组件 =================

    private fun drawCover(canvas: Canvas, left: Float, top: Float, size: Float) {
        val radius = dp(12f)
        val thumb = coverThumb
        if (thumb != null && !thumb.isRecycled) {
            bitmapRect.set(left, top, left + size, top + size)
            canvas.drawBitmap(thumb, null, bitmapRect, coverPaint)
        } else {
            // 无封面：半透明占位块 + 音符图标
            tmpRect.set(left, top, left + size, top + size)
            cardPaint.color = 0x26FFFFFF
            canvas.drawRoundRect(tmpRect, radius, radius, cardPaint)
            cardPaint.color = CARD_FILL
            val icon = iconBitmap(R.drawable.lockcard_ic_note, (size * 0.55f).toInt(), 0x8CFFFFFF.toInt())
            val iconSize = size * 0.55f
            val iconOffset = (size - iconSize) / 2f
            bitmapRect.set(left + iconOffset, top + iconOffset, left + iconOffset + iconSize, top + iconOffset + iconSize)
            canvas.drawBitmap(icon, null, bitmapRect, coverPaint)
        }
    }

    private fun drawTitleAndArtist(
        canvas: Canvas,
        left: Float,
        top: Float,
        height: Float,
        maxWidth: Float,
        state: LockCardState,
    ) {
        if (maxWidth <= 0f) return
        val title = ellipsizeTitle(state.title, maxWidth)
        val artist = ellipsizeArtist(state.artist, maxWidth)
        val titleFm = titlePaint.fontMetrics
        val artistFm = artistPaint.fontMetrics
        val titleH = titlePaint.textSize * 1.25f
        val artistH = artistPaint.textSize * 1.25f
        val blockH = titleH + artistH
        val blockTop = top + (height - blockH) / 2f
        if (title.isNotEmpty()) {
            canvas.drawText(
                title, 0, title.length, left,
                blockTop + titleH / 2f - (titleFm.ascent + titleFm.descent) / 2f, titlePaint
            )
        }
        if (artist.isNotEmpty()) {
            canvas.drawText(
                artist, 0, artist.length, left,
                blockTop + titleH + artistH / 2f - (artistFm.ascent + artistFm.descent) / 2f, artistPaint
            )
        }
    }

    private fun drawPlayButton(canvas: Canvas, rect: CardGeometry, isPlaying: Boolean) {
        val cx = (rect.left + rect.right) / 2f
        val cy = (rect.top + rect.bottom) / 2f
        val r = minOf(rect.width, rect.height) / 2f
        canvas.drawCircle(cx, cy, r, playFillPaint)
        playStrokePaint.strokeWidth = dp(1.5f)
        canvas.drawCircle(cx, cy, r, playStrokePaint)
        val res = if (isPlaying) R.drawable.lockcard_ic_pause else R.drawable.lockcard_ic_play
        val iconSize = (r * 1.1f).toInt().coerceAtLeast(1)
        val bmp = iconBitmap(res, iconSize, 0xFFFFFFFF.toInt())
        bitmapRect.set(cx - iconSize / 2f, cy - iconSize / 2f, cx + iconSize / 2f, cy + iconSize / 2f)
        canvas.drawBitmap(bmp, null, bitmapRect, coverPaint)
    }

    private fun drawProgressRow(canvas: Canvas, left: Float, right: Float, top: Float, state: LockCardState) {
        val elapsed = elapsedText(state.positionMs)
        val total = totalText(state.durationMs)
        val fm = timePaint.fontMetrics
        val centerY = top + dp(LockScreenCardLogic.progressRowDp) / 2f
        val baseline = centerY - (fm.ascent + fm.descent) / 2f
        canvas.drawText(elapsed, left, baseline, timePaint)
        val totalW = timePaint.measureText(total)
        canvas.drawText(total, right - totalW, baseline, timePaint)
        val elapsedW = timePaint.measureText(elapsed)
        val trackLeft = left + elapsedW + dp(8f)
        val trackRight = right - totalW - dp(8f)
        if (trackRight - trackLeft <= 0f) return
        val trackTop = centerY - dp(LockScreenCardLogic.trackDp) / 2f
        drawTrack(canvas, trackLeft, trackRight, trackTop, LockScreenCardLogic.progressRatio(state.positionMs, state.durationMs))
    }

    private fun drawTrack(canvas: Canvas, left: Float, right: Float, top: Float, ratio: Float) {
        val h = dp(LockScreenCardLogic.trackDp)
        val r = h / 2f
        tmpRect.set(left, top, right, top + h)
        canvas.drawRoundRect(tmpRect, r, r, trackPaint)
        if (ratio > 0f) {
            tmpRect.set(left, top, left + (right - left) * ratio, top + h)
            canvas.drawRoundRect(tmpRect, r, r, trackFgPaint)
        }
    }

    private fun drawIcon(canvas: Canvas, resId: Int, rect: CardGeometry, tint: Int) {
        val size = dp(LockScreenCardLogic.castIconDp).toInt()
        val bmp = iconBitmap(resId, size, tint)
        val cx = (rect.left + rect.right) / 2f
        val cy = (rect.top + rect.bottom) / 2f
        bitmapRect.set(cx - size / 2f, cy - size / 2f, cx + size / 2f, cy + size / 2f)
        canvas.drawBitmap(bmp, null, bitmapRect, coverPaint)
    }

    /// 图标位图缓存：同尺寸同色只烘焙一次，绘制期零解析开销。
    private fun iconBitmap(resId: Int, sizePx: Int, tint: Int): Bitmap {
        val size = sizePx.coerceAtLeast(1)
        for (entry in iconCache) {
            if (entry.resId == resId && entry.sizePx == size && entry.tint == tint &&
                !entry.bitmap.isRecycled
            ) {
                return entry.bitmap
            }
        }
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val drawable = host.resources.getDrawable(resId, null)
        if (drawable == null) {
            // 资源缺失时返回空位图：宁可少一个图标，也不要整帧绘制 NPE
            iconCache.add(IconEntry(resId, size, tint, bmp))
            return bmp
        }
        drawable.mutate()
        drawable.setTint(tint)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        // 按压态会额外产生一组白色变体，上限 32 条足够覆盖 9 个图标 × 2 态
        if (iconCache.size >= 32) {
            val eldest = iconCache.removeAt(0)
            if (!eldest.bitmap.isRecycled) eldest.bitmap.recycle()
        }
        iconCache.add(IconEntry(resId, size, tint, bmp))
        return bmp
    }

    // ================= 文本 ellipsize 缓存 =================

    private fun ellipsizeTitle(text: String, maxWidth: Float): CharSequence =
        if (text == titleCacheKey && maxWidth == titleCacheWidth && titlePaint.textSize == titleCacheSize) {
            titleCacheValue
        } else {
            val v = TextUtils.ellipsize(text, titlePaint, maxWidth, TextUtils.TruncateAt.END)
            titleCacheKey = text
            titleCacheWidth = maxWidth
            titleCacheSize = titlePaint.textSize
            titleCacheValue = v
            v
        }

    private fun ellipsizeArtist(text: String, maxWidth: Float): CharSequence =
        if (text == artistCacheKey && maxWidth == artistCacheWidth && artistPaint.textSize == artistCacheSize) {
            artistCacheValue
        } else {
            val v = TextUtils.ellipsize(text, artistPaint, maxWidth, TextUtils.TruncateAt.END)
            artistCacheKey = text
            artistCacheWidth = maxWidth
            artistCacheSize = artistPaint.textSize
            artistCacheValue = v
            v
        }

    private fun mediumTypeface(): Typeface = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        Typeface.create(Typeface.DEFAULT, 600, false)
    } else {
        Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }

    private fun dp(v: Float): Float = v * density

    private fun sp(v: Float): Float = v * density * fontScale
}
