package com.md3music.md3music

/// 锁屏卡片矩形区域（px）。
///
/// 只做纯几何运算，不依赖 `android.graphics.RectF`，因此可直接在 JVM 单测里验证。
internal data class CardGeometry(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top

    /// 命中判定：边界视为命中（闭区间），避免按钮边缘 1px 点不动。
    fun contains(x: Float, y: Float): Boolean = x in left..right && y in top..bottom
}

/// 卡片可点击热区。顺序即绘制/命中顺序（互不重叠，顺序仅用于确定性）。
enum class CardButton { favorite, previous, playPause, next, queue, cast }

/// 卡片布局档位：full = 三行完整卡片；compact = 单行紧凑卡片（横屏 / 可用高不足）。
internal enum class CardMode { full, compact }

/// 锁屏歌词卡片纯逻辑：几何 / 命中 / 时间格式 / 进度比 / 解锁手势 / 帧率闸门。
///
/// 抽成纯 JVM 对象的理由与 [ConceptWidgetColors] 相同：Canvas 与 View 没有本地
/// 测试钩子，把「尺寸口径 + 命中判定 + 停表条件」这类易错逻辑放进纯函数，
/// 用 `:app:testStandardDebugUnitTest` 直接验证，改参数时不必上真机看。
internal object LockScreenCardLogic {
    // ===== 卡片尺寸常量（dp）：绘制与命中必须共用同一份口径，改这里即改视觉 =====
    /// 卡片左右外边距。
    const val marginDp = 16f

    /// 卡片圆角半径。
    const val radiusDp = 28f

    /// 卡片内边距。
    const val paddingDp = 16f

    /// 行 1 封面边长。
    const val coverDp = 48f

    /// 行 1 与行 2 的间距。
    const val gap1Dp = 12f

    /// 行 2 播放圆钮直径（同时是它的热区）。
    const val transportDp = 56f

    /// 行 2 与行 3 的间距。
    const val gap2Dp = 10f

    /// 行 3 进度行高度。
    const val progressRowDp = 16f

    /// 卡片距屏幕底部的外边距。
    const val bottomMarginDp = 32f

    /// 上滑解锁的位移阈值。
    const val swipeUnlockDp = 72f

    /// 其余按钮热区边长（48dp，满足最小可点尺寸）。
    const val hitDp = 48f

    /// compact 档封面边长。
    const val compactCoverDp = 40f

    /// 投屏图标边长（热区仍按 [hitDp]）。
    const val castIconDp = 24f

    /// 可用高低于该值改用 compact 档（避免卡片把歌词可视带挤没）。
    const val minFullAvailableDp = 200f

    /// 卡片歌名字号（sp）与歌手字号（sp）：行高推导与渲染器必须共用。
    const val titleSp = 15f
    const val artistSp = 12f

    /// 文本行高系数（与渲染器 `textSize * 1.25f` 同一口径）。
    const val textLineFactor = 1.25f

    /// 上滑解锁的速度阈值（dp/s）。
    const val flingVelocityDpPerSec = 800f

    /// 进度条轨道高度。
    const val trackDp = 2f

    /// 毫秒 → `M:SS` / `H:MM:SS`；负数与非法值一律按 0 处理。
    fun formatTime(ms: Long): String {
        val totalSec = ms.coerceAtLeast(0L) / 1000L
        val hours = totalSec / 3600L
        val minutes = (totalSec % 3600L) / 60L
        val seconds = totalSec % 60L
        return if (hours > 0L) {
            "$hours:${pad2(minutes)}:${pad2(seconds)}"
        } else {
            "$minutes:${pad2(seconds)}"
        }
    }

    private fun pad2(v: Long): String = if (v < 10L) "0$v" else v.toString()

    /// 播放进度比，夹取到 [0,1]；时长未知返回 0。
    fun progressRatio(posMs: Long, durMs: Long): Float {
        if (durMs <= 0L) return 0f
        return (posMs.toDouble() / durMs.toDouble()).toFloat().coerceIn(0f, 1f)
    }

    /// 依据可用高度选择档位：不足 [minFullAvailableDp] 用 compact。
    fun resolveCardMode(availableHeightDp: Float): CardMode =
        if (availableHeightDp < minFullAvailableDp) CardMode.compact else CardMode.full

    /// 行 1 高度（dp）：封面与「歌名 + 歌手」文本块取大者。
    ///
    /// 字体放大到「文本块高于封面」时才真正长高（1.3 倍字体下 33.75×1.3≈43.9dp
    /// 仍小于 48dp 封面，故不虚高）；行高与绘制必须共用本函数，否则行 2/行 3
    /// 会与卡片底边错位。
    fun row1HeightDp(mode: CardMode, densityScale: Float): Float {
        val scale = densityScale.coerceIn(0.8f, 2.0f)
        val textBlock = (titleSp + artistSp) * textLineFactor * scale
        return when (mode) {
            CardMode.full -> maxOf(coverDp, textBlock)
            CardMode.compact -> maxOf(compactCoverDp, textBlock)
        }
    }

    /// 卡片高度（dp）：与渲染器的行距口径严格一致。
    ///
    /// [densityScale] 为字体缩放（configuration.fontScale）。只有行 1 的文本块会
    /// 随字体长高，其余行是固定 dp —— 旧实现把整个基准高度乘缩放比，导致大字号下
    /// 卡片虚高、进度行悬在中间。[showProgress] 为 false（时长未知）时整行隐藏。
    fun cardHeightDp(mode: CardMode, densityScale: Float, showProgress: Boolean = true): Float =
        paddingDp * 2f + row1HeightDp(mode, densityScale) +
            when (mode) {
                CardMode.full -> gap1Dp + transportDp +
                    (if (showProgress) gap2Dp + progressRowDp else 0f)
                // compact 的进度轨贴在卡片底，需要单独留一行高度，否则压在封面上
                CardMode.compact -> (if (showProgress) progressRowDp else 0f)
            }

    /// 卡片在屏幕坐标系中的矩形：左右留 [marginDp]，底边距屏幕底 [bottomMarginDp]。
    fun cardGeometry(viewW: Float, viewH: Float, density: Float, heightDp: Float): CardGeometry {
        val d = density.coerceAtLeast(0.1f)
        val left = marginDp * d
        val right = (viewW - marginDp * d).coerceAtLeast(left)
        val bottom = viewH - bottomMarginDp * d
        val top = bottom - heightDp * d
        return CardGeometry(left, top, right, bottom)
    }

    /// 六个热区矩形。
    ///
    /// - full：行 1 右侧投屏键；行 2 五键（收藏/上一首/播放暂停/下一首/队列）均分居中，
    ///   播放圆钮 56dp、其余 48dp，间距由剩余宽度均分（极窄屏夹到 0 不重叠为负）。
    /// - compact：只保留右侧播放暂停键。
    fun buttonRects(
        geo: CardGeometry,
        density: Float,
        mode: CardMode,
        densityScale: Float = 1f,
    ): Map<CardButton, CardGeometry> {
        val d = density.coerceAtLeast(0.1f)
        if (geo.width <= 0f || geo.height <= 0f) return emptyMap()
        val pad = paddingDp * d
        val row1Top = geo.top + pad
        val row1H = row1HeightDp(mode, densityScale) * d
        val innerLeft = geo.left + pad
        val innerRight = geo.right - pad
        val hit = hitDp * d
        if (mode == CardMode.compact) {
            val top = row1Top + (row1H - hit) / 2f
            return mapOf(CardButton.playPause to CardGeometry(innerRight - hit, top, innerRight, top + hit))
        }
        val rects = LinkedHashMap<CardButton, CardGeometry>()
        // 行 2：五键均分
        val row2Top = row1Top + row1H + gap1Dp * d
        val transport = transportDp * d
        val centerY = row2Top + transport / 2f
        val order = listOf(
            CardButton.favorite to hit,
            CardButton.previous to hit,
            CardButton.playPause to transport,
            CardButton.next to hit,
            CardButton.queue to hit,
        )
        var totalW = 0f
        for ((_, size) in order) totalW += size
        val innerW = (innerRight - innerLeft).coerceAtLeast(0f)
        val gap = ((innerW - totalW) / (order.size - 1)).coerceAtLeast(0f)
        var x = innerLeft + ((innerW - totalW - gap * (order.size - 1)) / 2f).coerceAtLeast(0f)
        for ((button, size) in order) {
            rects[button] = CardGeometry(x, centerY - size / 2f, x + size, centerY + size / 2f)
            x += size + gap
        }
        // 行 1 右侧投屏键（热区 48dp，图标 24dp 居中绘制）
        val castTop = row1Top + (row1H - hit) / 2f
        rects[CardButton.cast] = CardGeometry(innerRight - hit, castTop, innerRight, castTop + hit)
        return rects
    }

    /// 命中测试：返回命中的按钮，落在缝隙/卡片外返回 null。
    fun hitTest(x: Float, y: Float, rects: Map<CardButton, CardGeometry>): CardButton? {
        for ((button, rect) in rects) {
            if (rect.contains(x, y)) return button
        }
        return null
    }

    /// 上滑解锁判定：位移超过 [swipeUnlockDp] 或向上甩动速度超过
    /// [flingVelocityDpPerSec] 任一成立即解锁。[dyPx] 向上为负。
    fun shouldUnlockSwipe(dyPx: Float, vyPxPerSec: Float, density: Float): Boolean {
        val d = density.coerceAtLeast(0.1f)
        return -dyPx >= swipeUnlockDp * d || -vyPxPerSec >= flingVelocityDpPerSec * d
    }
}

/// 帧率闸门：120Hz 屏上 Choreographer 按 vsync（约 8.3ms）回调，只有距上次绘制
/// ≥ [minIntervalMs] 才允许 invalidate，把实际重绘封顶在 60fps，省掉一半合成功耗。
///
/// 位置推进仍按真实 dt 计算，闸门只决定「这一帧要不要重绘」，不改变速度。
internal class LockScreenFrameGate(private val minIntervalMs: Long = 16L) {
    private var lastDrawMs = 0L
    private var hasDrawn = false

    /// 是否允许本帧重绘；允许时记录时间戳。
    fun shouldDraw(nowMs: Long): Boolean {
        // 时钟回绕（理论上不会发生）时直接放行，避免闸门永久卡死
        if (hasDrawn && nowMs >= lastDrawMs && nowMs - lastDrawMs < minIntervalMs) return false
        lastDrawMs = nowMs
        hasDrawn = true
        return true
    }

    /// 帧循环重启时调用：保证重启后的第一帧立即绘制。
    fun reset() {
        hasDrawn = false
        lastDrawMs = 0L
    }
}
