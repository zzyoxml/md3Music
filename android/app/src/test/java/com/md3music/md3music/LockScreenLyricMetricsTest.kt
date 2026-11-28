package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 锁屏歌词行盒几何单测（对齐 AM 播放页口径）。
 *
 * 背景：AM 用 Flutter `TextStyle(height:)` 排版，行盒内多余 leading **上下各半**，
 * 字形在行盒里居中；锁屏是 Canvas 基线绘制，旧实现把 leading 全压在字形下方，
 * 因此换行视觉行之间、副行上下方的空白都比 AM 大一截。这里把「行盒几何」抽成
 * [LockScreenLyricMetrics] 后可逐项验证，不必每次上真机目测。
 *
 * 度量口径：用合成字体度量（ascent 0.85em、descent 0.25em → 字形高 1.1em），
 * 与常见双字重中文字体的比例接近，不依赖 `android.graphics.Paint`（JVM 单测可用）。
 */
class LockScreenLyricMetricsTest {

    private val fontSize = 22f
    private val lineMult = 1.5f
    private val mainH = LockScreenLyricMetrics.mainLineHeight(fontSize, lineMult) // 33px

    private val ascAbs = 0.85f * fontSize // 18.7px
    private val descent = 0.25f * fontSize // 5.5px
    private val glyphH = ascAbs + descent // 24.2px

    // ================= 主行行盒 =================

    @Test
    fun mainLineHeightMatchesAmFormula() {
        // AM: fontSize * LyricLayout.lineHeight
        assertEquals(33f, mainH, 0.001f)
        assertEquals(27f, LockScreenLyricMetrics.mainLineHeight(18f, 1.5f), 0.001f)
    }

    @Test
    fun rowBoxAndRowTopMatchAmWrapModel() {
        // 第 1 视觉行=完整主行盒；其余 0.8 倍；行顶 0 / mainH / 1.8mainH / 2.6mainH
        assertEquals(33f, LockScreenLyricMetrics.rowBoxHeight(mainH, 0), 0.001f)
        assertEquals(26.4f, LockScreenLyricMetrics.rowBoxHeight(mainH, 1), 0.001f)
        assertEquals(26.4f, LockScreenLyricMetrics.rowBoxHeight(mainH, 3), 0.001f)
        assertEquals(0f, LockScreenLyricMetrics.rowTop(mainH, 0), 0.001f)
        assertEquals(33f, LockScreenLyricMetrics.rowTop(mainH, 1), 0.001f)
        assertEquals(59.4f, LockScreenLyricMetrics.rowTop(mainH, 2), 0.001f)
        assertEquals(85.8f, LockScreenLyricMetrics.rowTop(mainH, 3), 0.001f)
    }

    @Test
    fun mainRowsHeightCompressesWrappedRows() {
        assertEquals(mainH, LockScreenLyricMetrics.mainRowsHeight(mainH, 1), 0.001f)
        assertEquals(1.8f * mainH, LockScreenLyricMetrics.mainRowsHeight(mainH, 2), 0.001f)
        assertEquals(2.6f * mainH, LockScreenLyricMetrics.mainRowsHeight(mainH, 3), 0.001f)
    }

    // ================= 半行距（本次修复的核心） =================

    @Test
    fun baselineCentersGlyphInsideBox() {
        // 行盒 33 / 字形 24.2 → 上下各留 4.4；baseline = 4.4 + 18.7
        val box = LockScreenLyricMetrics.rowBoxHeight(mainH, 0)
        val baseline = LockScreenLyricMetrics.baselineInBox(box, ascAbs, descent)
        assertEquals((box - glyphH) / 2f + ascAbs, baseline, 0.001f)
        val glyphTop = baseline - ascAbs
        val glyphBottom = baseline + descent
        assertEquals(glyphTop, box - glyphBottom, 0.001f) // 上下留白相等
    }

    @Test
    fun zeroLeadingWhenBoxEqualsGlyphHeight() {
        assertEquals(ascAbs, LockScreenLyricMetrics.baselineInBox(glyphH, ascAbs, descent), 0.001f)
    }

    @Test
    fun wrappedRowGlyphGapShrinksComparedWithOldModel() {
        // 新口径：第 1 行字形底 → 第 2 行字形顶 = 两个行盒各自的半行距之和
        //   行盒 33   → 半行距 (33-24.2)/2 = 4.4
        //   行盒 26.4 → 半行距 (26.4-24.2)/2 = 1.1
        val b0 = LockScreenLyricMetrics.mainRowBaseline(mainH, 0, ascAbs, descent)
        val b1 = LockScreenLyricMetrics.mainRowBaseline(mainH, 1, ascAbs, descent)
        val newGap = (b1 - ascAbs) - (b0 + descent)
        // 旧口径：行顶 - ascent（leading 全压在字形下方）→ 整行盒减字形高
        val oldGap = LockScreenLyricMetrics.rowTop(mainH, 1) - glyphH
        assertEquals(5.5f, newGap, 0.05f)
        assertEquals(8.8f, oldGap, 0.05f)
        assertTrue("换行行间空白必须明显小于旧口径", newGap < oldGap * 0.7f)
    }

    @Test
    fun baselinesAreMonotonic() {
        var prev = -1f
        for (ri in 0 until 5) {
            val b = LockScreenLyricMetrics.mainRowBaseline(mainH, ri, ascAbs, descent)
            assertTrue("第 $ri 行 baseline 必须递增", b > prev)
            prev = b
        }
    }

    @Test
    fun negativeLeadingIsAllowedAndStillMonotonic() {
        // 行距 0.8 → 行盒 17.6 < 字形 24.2：halfLead 为负（行盒重叠，与 AM 行为一致）
        val tightH = LockScreenLyricMetrics.mainLineHeight(fontSize, 0.8f)
        val b0 = LockScreenLyricMetrics.mainRowBaseline(tightH, 0, ascAbs, descent)
        val b1 = LockScreenLyricMetrics.mainRowBaseline(tightH, 1, ascAbs, descent)
        assertTrue("紧行距下 baseline 仍须递增", b1 > b0)
        assertEquals(tightH + (tightH * 0.8f - glyphH) / 2f + ascAbs, b1, 0.01f)
    }

    // ================= 副行（翻译/罗马音） =================

    @Test
    fun auxFontSizeFloorsByWeight() {
        // 0.7em = 15.4 > 12 → 不触发下限
        assertEquals(15.4f, LockScreenLyricMetrics.auxFontSize(fontSize, 400), 0.001f)
        // 小字号 + 常规字重 → 12 下限
        assertEquals(12f, LockScreenLyricMetrics.auxFontSize(12f, 400), 0.001f)
        // 细体 → 13 下限（与 AM clampReadableFontSize 同口径）
        assertEquals(13f, LockScreenLyricMetrics.auxFontSize(12f, 300), 0.001f)
        assertEquals(13f, LockScreenLyricMetrics.readableFloor(350), 0.001f)
        assertEquals(12f, LockScreenLyricMetrics.readableFloor(700), 0.001f)
    }

    @Test
    fun auxReserveHeightGrowsWithRows() {
        val aux = LockScreenLyricMetrics.auxFontSize(fontSize, 400) // 15.4
        assertEquals(1.8f * aux, LockScreenLyricMetrics.auxReserveHeight(aux, 1), 0.01f)
        assertEquals(3.3f * aux, LockScreenLyricMetrics.auxReserveHeight(aux, 2), 0.01f)
        assertEquals(0f, LockScreenLyricMetrics.auxReserveHeight(aux, 0), 0.001f)
        // 旧实现恒按 1.3 倍单行预留，2 行时明显不足（本次修复点）
        assertTrue(
            "2 行副行预留必须显著大于旧的单行口径",
            LockScreenLyricMetrics.auxReserveHeight(aux, 2) > 1.3f * aux * 2f,
        )
    }

    @Test
    fun auxRowsAreSpacedExactlyOneLineBox() {
        val aux = LockScreenLyricMetrics.auxFontSize(fontSize, 400)
        val auxAsc = 0.85f * aux
        val auxDesc = 0.25f * aux
        val b0 = LockScreenLyricMetrics.auxRowBaseline(mainH, 1, aux, 0, auxAsc, auxDesc)
        val b1 = LockScreenLyricMetrics.auxRowBaseline(mainH, 1, aux, 1, auxAsc, auxDesc)
        assertEquals(1.5f * aux, b1 - b0, 0.01f)
    }

    @Test
    fun auxTopSitsAfterMainRowsPlusGap() {
        val aux = LockScreenLyricMetrics.auxFontSize(fontSize, 400)
        // 主行 1 行：副行顶 = 33 + 0.3*15.4
        assertEquals(
            mainH + 0.3f * aux,
            LockScreenLyricMetrics.auxRowTop(mainH, 1, aux, 0),
            0.01f,
        )
        // 主行换到 2 行：副行顶随之 = 59.4 + 0.3*15.4
        assertEquals(
            1.8f * mainH + 0.3f * aux,
            LockScreenLyricMetrics.auxRowTop(mainH, 2, aux, 0),
            0.01f,
        )
    }

    // ================= 块高 =================

    @Test
    fun lineBlockHeightEqualsMainPlusAuxReserve() {
        val aux = LockScreenLyricMetrics.auxFontSize(fontSize, 400)
        assertEquals(
            LockScreenLyricMetrics.mainRowsHeight(mainH, 2) +
                LockScreenLyricMetrics.auxReserveHeight(aux, 1),
            LockScreenLyricMetrics.lineBlockHeight(mainH, 2, aux, 1),
            0.01f,
        )
        // 无副行时等于纯主文本高度
        assertEquals(
            LockScreenLyricMetrics.mainRowsHeight(mainH, 1),
            LockScreenLyricMetrics.lineBlockHeight(mainH, 1, aux, 0),
            0.01f,
        )
    }

    @Test
    fun blockHeightCoversAuxBaselinePlusDescent() {
        // 副行最后一个 visual row 的字形底必须落在块高内（不越界压下一行）
        val aux = LockScreenLyricMetrics.auxFontSize(fontSize, 400)
        val auxDesc = 0.25f * aux
        val lastBaseline = LockScreenLyricMetrics.auxRowBaseline(mainH, 2, aux, 1, 0.85f * aux, auxDesc)
        val block = LockScreenLyricMetrics.lineBlockHeight(mainH, 2, aux, 2)
        assertTrue(
            "副行字形底 ${lastBaseline + auxDesc} 必须小于块高 $block",
            lastBaseline + auxDesc <= block + 0.01f,
        )
    }

    @Test
    fun halfLeadingSplitDefaultsToEvenSplit() {
        assertEquals(0.5f, LockScreenLyricMetrics.halfLeadingSplit, 0.0001f)
        val box = 30f
        val even = LockScreenLyricMetrics.baselineInBox(box, 10f, 2f, split = 0.5f)
        assertEquals((box - 12f) / 2f + 10f, even, 0.001f)
    }
}
