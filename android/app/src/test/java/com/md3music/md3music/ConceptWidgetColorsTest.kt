package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 概念版 4×1 小部件纯逻辑单测。
 *
 * AppWidget/RemoteViews 没有本地测试钩子，故把颜色派生与模式索引抽到
 * [ConceptWidgetColors]（不依赖 android.graphics）后在此直接验证。
 */
class ConceptWidgetColorsTest {

    private fun red(color: Int) = (color shr 16) and 0xFF
    private fun green(color: Int) = (color shr 8) and 0xFF
    private fun blue(color: Int) = color and 0xFF

    @Test
    fun blendAtEndpointsReturnsSourceAndTarget() {
        val base = 0xFF3366CC.toInt()
        val target = ConceptWidgetColors.WHITE
        assertEquals(base and 0xFFFFFF, ConceptWidgetColors.blend(base, target, 0f) and 0xFFFFFF)
        assertEquals(target, ConceptWidgetColors.blend(base, target, 1f))
    }

    @Test
    fun blendMovesChannelsMonotonicallyTowardsTarget() {
        val base = 0xFF204060.toInt()
        val target = ConceptWidgetColors.WHITE
        val quarter = ConceptWidgetColors.blend(base, target, 0.25f)
        val half = ConceptWidgetColors.blend(base, target, 0.5f)
        assertTrue(red(quarter) in red(base)..red(target))
        assertTrue(red(half) >= red(quarter))
        assertTrue(green(half) >= green(quarter))
        assertTrue(blue(half) >= blue(quarter))
    }

    @Test
    fun luminanceOrdersBlackGreyWhite() {
        val black = ConceptWidgetColors.luminance(ConceptWidgetColors.BLACK)
        val grey = ConceptWidgetColors.luminance(0xFF808080.toInt())
        val white = ConceptWidgetColors.luminance(ConceptWidgetColors.WHITE)
        assertTrue(black < grey)
        assertTrue(grey < white)
        assertEquals(0.0, black, 1e-6)
        assertEquals(1.0, white, 1e-6)
    }

    @Test
    fun cardColorsDarkenBottomForReadableWhiteText() {
        val (top, bottom) = ConceptWidgetColors.cardColors(0xFFB03A3A.toInt())
        assertTrue(ConceptWidgetColors.luminance(bottom) < ConceptWidgetColors.luminance(top))
    }

    @Test
    fun cardColorsKeepBrightDominantBottomBelowCap() {
        // 极亮封面（接近白）：底端仍要被压到上限以下，否则白字发灰
        val (_, bottom) = ConceptWidgetColors.cardColors(0xFFF0F0D8.toInt())
        assertTrue(
            ConceptWidgetColors.luminance(bottom) <=
                ConceptWidgetColors.MAX_CARD_BOTTOM_LUMINANCE + 1e-6
        )
    }

    @Test
    fun cardColorsKeepBrightDominantTopBelowCap() {
        // 顶端同样有上限：亮封面提亮过头时白字在上沿也会糊掉
        val (top, _) = ConceptWidgetColors.cardColors(0xFFF5F2E8.toInt())
        assertTrue(
            ConceptWidgetColors.luminance(top) <=
                ConceptWidgetColors.MAX_CARD_TOP_LUMINANCE + 1e-6
        )
    }

    @Test
    fun readableAccentKeepsAccentWhenContrastIsEnough() {
        val accent = 0xFFFFFFFF.toInt()
        val cardTop = 0xFF4A2020.toInt()
        val cardBottom = 0xFF301010.toInt()
        assertEquals(accent, ConceptWidgetColors.readableAccent(accent, cardTop, cardBottom))
    }

    @Test
    fun readableAccentPullsLowContrastAccentAwayFromCard() {
        // 暗红卡片 + 暗红强调色：原样输出会隐身，必须被拉开
        val accent = 0xFF3A1414.toInt()
        val cardTop = 0xFF4A2020.toInt()
        val cardBottom = 0xFF301010.toInt()
        val resolved = ConceptWidgetColors.readableAccent(accent, cardTop, cardBottom)
        val cardLuminance =
            (ConceptWidgetColors.luminance(cardTop) + ConceptWidgetColors.luminance(cardBottom)) / 2.0
        assertTrue(
            Math.abs(ConceptWidgetColors.luminance(resolved) - cardLuminance) >=
                ConceptWidgetColors.MIN_CONTRAST_LUMINANCE - 1e-6
        )
    }

    @Test
    fun favoriteColorStaysReadableAgainstCard() {
        val cardTop = 0xFF2A2A2A.toInt()
        val cardBottom = 0xFF141414.toInt()
        val resolved = ConceptWidgetColors.favoriteColor(0xFF2A2A2A.toInt(), cardTop, cardBottom)
        val cardLuminance =
            (ConceptWidgetColors.luminance(cardTop) + ConceptWidgetColors.luminance(cardBottom)) / 2.0
        assertTrue(
            Math.abs(ConceptWidgetColors.luminance(resolved) - cardLuminance) >=
                ConceptWidgetColors.MIN_CONTRAST_LUMINANCE - 1e-6
        )
    }

    @Test
    fun modeIconIndexMapsPlaybackModes() {
        assertEquals(ConceptWidgetColors.MODE_OFF, ConceptWidgetColors.modeIconIndex("off", false))
        assertEquals(ConceptWidgetColors.MODE_ALL, ConceptWidgetColors.modeIconIndex("all", false))
        assertEquals(ConceptWidgetColors.MODE_ONE, ConceptWidgetColors.modeIconIndex("one", false))
        // 随机优先于循环模式（与 PlayerProvider.cyclePlayMode 的合并语义一致）
        assertEquals(
            ConceptWidgetColors.MODE_SHUFFLE,
            ConceptWidgetColors.modeIconIndex("off", true)
        )
        assertEquals(
            ConceptWidgetColors.MODE_SHUFFLE,
            ConceptWidgetColors.modeIconIndex("one", true)
        )
        // 未知取值退回顺序态，不崩
        assertEquals(ConceptWidgetColors.MODE_OFF, ConceptWidgetColors.modeIconIndex("", false))
    }

    @Test
    fun displayTitleOmitsSeparatorWhenArtistBlank() {
        assertEquals("因为你 - 方大同", ConceptWidgetColors.displayTitle("因为你", "方大同"))
        assertEquals("因为你", ConceptWidgetColors.displayTitle("因为你", ""))
        assertEquals("因为你", ConceptWidgetColors.displayTitle("因为你", "   "))
    }
}
