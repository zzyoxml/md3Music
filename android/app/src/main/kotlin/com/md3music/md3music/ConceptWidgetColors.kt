package com.md3music.md3music

/**
 * 概念版 4×1 小部件的纯色彩/模式逻辑。
 *
 * 抽成不依赖 android.graphics 的纯 Kotlin 对象，便于 JVM 单测直接验证
 * （AppWidget/RemoteViews 本身没有本地测试钩子）。Provider 只负责把这里的
 * 结果灌进 RemoteViews。
 *
 * 取色口径与 2×2 封面小部件一致：封面 Palette 主色 → 卡片渐变底 → 白字/圆环
 * 可读性护栏；差别是这里全部用 int 位运算 + sRGB 相对亮度实现，不引用
 * androidx.core 的 ColorUtils。
 */
internal object ConceptWidgetColors {

    /** 圆环/强调色与卡片底色之间的最小相对亮度差（沿用 2×2 小部件的 0.20 判据）。 */
    const val MIN_CONTRAST_LUMINANCE = 0.20

    /**
     * 卡片底端亮度上限。参考图实测卡片亮度约 0.07，白字对比约 8.6:1；
     * 0.45 那种「中等亮度」在 15sp 白字上只有 2:1，根本读不清。
     */
    const val MAX_CARD_BOTTOM_LUMINANCE = 0.10

    /** 卡片顶端亮度上限：顶端是渐变较亮的一端，仍需保证白字可读。 */
    const val MAX_CARD_TOP_LUMINANCE = 0.14

    /** 模式图标索引：0=顺序 1=列表循环 2=单曲循环 3=随机。 */
    const val MODE_OFF = 0
    const val MODE_ALL = 1
    const val MODE_ONE = 2
    const val MODE_SHUFFLE = 3

    /** sRGB 单通道线性化（WCAG 相对亮度口径）。 */
    private fun linear(channel: Int): Double {
        val s = channel / 255.0
        return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
    }

    /** ARGB 的相对亮度（0=黑，1=白）。忽略 alpha。 */
    fun luminance(argb: Int): Double {
        val r = linear((argb shr 16) and 0xFF)
        val g = linear((argb shr 8) and 0xFF)
        val b = linear(argb and 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /**
     * 按 [ratio]（0..1）把 [base] 向 [target] 线性混合，输出不透明色。
     * ratio=0 返回 base 的 RGB，ratio=1 返回 target 的 RGB。
     */
    fun blend(base: Int, target: Int, ratio: Float): Int {
        val r = ratio.coerceIn(0f, 1f)
        fun channel(shift: Int): Int {
            val b = (base shr shift) and 0xFF
            val t = (target shr shift) and 0xFF
            return Math.round(b + (t - b) * r).coerceIn(0, 255)
        }
        return (0xFF shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    /**
     * 由封面主色派生卡片渐变的两端：顶端略微提亮（保留封面色相），底端压暗。
     *
     * 压暗是**按需**的：只在亮度超过上限时才往黑里混，而不是固定压一个比例。
     * 固定压暗会把本来就不亮的封面（参考图红色卡片实测亮度约 0.074）压到
     * 0.024，卡片发黑、失去封面色感；按需压暗则让这类封面保持原色，只对
     * 浅色封面（浅黄、奶白）做足够的下压，保证白字可读。
     */
    fun cardColors(dominant: Int): Pair<Int, Int> {
        // 顶端：略提亮让渐变有层次，但不超过上限
        var top = blend(dominant, WHITE, 0.08f)
        var topGuard = 0
        while (luminance(top) > MAX_CARD_TOP_LUMINANCE && topGuard < 16) {
            top = blend(top, BLACK, 0.15f)
            topGuard++
        }
        // 底端：保持封面原色，只在过亮时下压
        var bottom = dominant
        var bottomGuard = 0
        while (luminance(bottom) > MAX_CARD_BOTTOM_LUMINANCE && bottomGuard < 16) {
            bottom = blend(bottom, BLACK, 0.15f)
            bottomGuard++
        }
        // 底端必须比顶端暗，否则渐变方向反了（浅色封面下压后可能出现）
        if (luminance(bottom) >= luminance(top)) {
            bottom = blend(bottom, BLACK, 0.15f)
        }
        return top to bottom
    }

    /**
     * 圆环/强调色可读性护栏：与卡片底色亮度差不足（暗上暗/亮上亮，圆环会
     * 隐身）时向白或黑混合拉开差距——只调明度不改色相，仍是封面色系；
     * 对比充足时原色直出。
     */
    fun readableAccent(accent: Int, cardTop: Int, cardBottom: Int): Int {
        val cardLuminance = (luminance(cardTop) + luminance(cardBottom)) / 2.0
        val accentLuminance = luminance(accent)
        if (Math.abs(accentLuminance - cardLuminance) >= MIN_CONTRAST_LUMINANCE) {
            return accent
        }
        val target = if (accentLuminance <= cardLuminance) WHITE else BLACK
        var ratio = 0.1f
        while (ratio <= 1.0f) {
            val candidate = blend(accent, target, ratio)
            if (Math.abs(luminance(candidate) - cardLuminance) >= MIN_CONTRAST_LUMINANCE) {
                return candidate
            }
            ratio += 0.1f
        }
        return blend(accent, target, 1f)
    }

    /**
     * 收藏爱心实心态的颜色：取封面主色提亮（参考图是浅粉爱心），再套一层
     * 可读性护栏，避免深色封面上爱心与卡片糊在一起。
     */
    fun favoriteColor(accent: Int, cardTop: Int, cardBottom: Int): Int =
        readableAccent(blend(accent, WHITE, 0.45f), cardTop, cardBottom)

    /** 播放模式 → 图标槽位下标（与布局里 4 个叠放 ImageView 的顺序一致）。 */
    fun modeIconIndex(loopMode: String, shuffle: Boolean): Int = when {
        shuffle -> MODE_SHUFFLE
        loopMode == "all" -> MODE_ALL
        loopMode == "one" -> MODE_ONE
        else -> MODE_OFF
    }

    /** 卡片标题：歌手为空时不拼「 - 」，只显示歌名。 */
    fun displayTitle(title: String, artist: String): String =
        if (artist.isBlank()) title else "$title - $artist"

    const val WHITE = 0xFFFFFFFF.toInt()
    const val BLACK = 0xFF000000.toInt()
}
