package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 锁屏歌词卡片纯逻辑单测。
 *
 * Canvas / View 没有本地测试钩子，故把几何、命中、时间格式、解锁手势与帧闸门
 * 抽到 [LockScreenCardLogic] / [LockScreenFrameGate] 后在此直接验证；
 * 覆盖两档屏幕尺寸、六个热区互不重叠、命中边界与缝隙、四组上滑判定。
 */
class LockScreenCardLogicTest {

    private val d = 3f // 常见 1080p 屏密度（xxhdpi）

    // ================= 时间格式 =================

    @Test
    fun formatTimeHandlesZero() {
        assertEquals("0:00", LockScreenCardLogic.formatTime(0L))
    }

    @Test
    fun formatTimeHandlesSubSecondAndSeconds() {
        // 59.9s 向下取整为 0:59
        assertEquals("0:59", LockScreenCardLogic.formatTime(59_900L))
        assertEquals("1:00", LockScreenCardLogic.formatTime(60_000L))
        assertEquals("3:07", LockScreenCardLogic.formatTime(187_000L))
    }

    @Test
    fun formatTimeHandlesHourAndNegative() {
        assertEquals("1:00:00", LockScreenCardLogic.formatTime(3_600_000L))
        assertEquals("2:03:04", LockScreenCardLogic.formatTime(7_384_000L))
        // 非法/负值按 0 处理，绝不显示负时间
        assertEquals("0:00", LockScreenCardLogic.formatTime(-1L))
    }

    // ================= 进度比 =================

    @Test
    fun progressRatioClampsAndHandlesUnknownDuration() {
        assertEquals(0f, LockScreenCardLogic.progressRatio(0L, 0L), 0f)
        assertEquals(0f, LockScreenCardLogic.progressRatio(1000L, 0L), 0f)
        assertEquals(0f, LockScreenCardLogic.progressRatio(-500L, 10_000L), 0f)
        assertEquals(1f, LockScreenCardLogic.progressRatio(20_000L, 10_000L), 0f)
        assertEquals(0.5f, LockScreenCardLogic.progressRatio(5_000L, 10_000L), 0f)
    }

    // ================= 档位 / 高度 =================

    @Test
    fun resolveCardModeSwitchesOnAvailableHeight() {
        assertEquals(CardMode.compact, LockScreenCardLogic.resolveCardMode(199f))
        assertEquals(CardMode.full, LockScreenCardLogic.resolveCardMode(200f))
        assertEquals(CardMode.full, LockScreenCardLogic.resolveCardMode(640f))
    }

    @Test
    fun cardHeightGrowsOnlyWhenTextBlockExceedsCover() {
        val base = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
        // 1.3 倍字体下文本块 (15+12)×1.25×1.3≈43.9dp，仍小于 48dp 封面 → 行 1 不变高。
        // 旧实现把整个基准高度乘缩放比，导致卡片虚高、进度行悬在中间（本次回归点）。
        assertEquals(base, LockScreenCardLogic.cardHeightDp(CardMode.full, 1.3f), 0.01f)
        // 2 倍字体文本块 (15+12)×1.25×2=67.5dp 超过封面 → 卡片必须长高
        assertTrue(LockScreenCardLogic.cardHeightDp(CardMode.full, 2f) > base)
        val noProgress = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f, showProgress = false)
        assertEquals(base - LockScreenCardLogic.progressRowDp - LockScreenCardLogic.gap2Dp, noProgress, 0.01f)
        // 字号缩放夹取在 [0.8, 2.0]，极端值不得把卡片撑爆
        assertEquals(
            LockScreenCardLogic.cardHeightDp(CardMode.full, 2f),
            LockScreenCardLogic.cardHeightDp(CardMode.full, 5f),
            0.01f
        )
    }

    @Test
    fun row1HeightIsMaxOfCoverAndTextBlock() {
        assertEquals(LockScreenCardLogic.coverDp, LockScreenCardLogic.row1HeightDp(CardMode.full, 1f), 0.01f)
        val textBlock = (LockScreenCardLogic.titleSp + LockScreenCardLogic.artistSp) *
            LockScreenCardLogic.textLineFactor * 2f
        assertEquals(textBlock, LockScreenCardLogic.row1HeightDp(CardMode.full, 2f), 0.01f)
    }

    @Test
    fun cardContentNeverOverflowsCardHeight() {
        // 绘制内容（padding + 行1 + 行2 + 行3）必须始终落在卡片高度内：
        // 这是「几何口径与渲染器共用同一份常量」的核心不变量。
        for (scale in listOf(0.8f, 1f, 1.3f, 2f)) {
            for (mode in CardMode.values()) {
                val cardH = LockScreenCardLogic.cardHeightDp(mode, scale)
                val row1 = LockScreenCardLogic.row1HeightDp(mode, scale)
                val contentBottom = when (mode) {
                    CardMode.full -> LockScreenCardLogic.paddingDp + row1 +
                        LockScreenCardLogic.gap1Dp + LockScreenCardLogic.transportDp +
                        LockScreenCardLogic.gap2Dp + LockScreenCardLogic.progressRowDp
                    CardMode.compact -> LockScreenCardLogic.paddingDp + row1 +
                        LockScreenCardLogic.progressRowDp
                }
                assertTrue(
                    "$mode @$scale 内容底 $contentBottom 溢出卡片高 $cardH",
                    contentBottom <= cardH + 0.01f
                )
            }
        }
    }

    // ================= 几何 =================

    @Test
    fun cardGeometryFitsInsideTwoCommonScreens() {
        // 360×800dp 与 411×891dp 两种常见手机屏
        for ((wDp, hDp) in listOf(360f to 800f, 411f to 891f)) {
            val w = wDp * d
            val h = hDp * d
            val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
            val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
            assertTrue("左边距不得为负", geo.left >= 0f)
            assertTrue("右边距不得越界", geo.right <= w)
            assertTrue("底边距不得越界", geo.bottom <= h)
            assertTrue("卡片高度应等于入参", abs(geo.height - heightDp * d) < 0.01f)
            assertTrue("卡片不得超出屏幕高", geo.top >= 0f)
            assertEquals(LockScreenCardLogic.marginDp * d, geo.left, 0.01f)
            assertEquals(w - LockScreenCardLogic.marginDp * d, geo.right, 0.01f)
            assertEquals(h - LockScreenCardLogic.bottomMarginDp * d, geo.bottom, 0.01f)
        }
    }

    private fun abs(v: Float): Float = if (v < 0f) -v else v

    // ================= 热区 =================

    @Test
    fun buttonRectsCoverSixButtonsAndStayInsideCard() {
        for ((wDp, hDp) in listOf(360f to 800f, 411f to 891f)) {
            val w = wDp * d
            val h = hDp * d
            val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
            val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
            val rects = LockScreenCardLogic.buttonRects(geo, d, CardMode.full)
            assertEquals(6, rects.size)
            for (button in CardButton.values()) {
                val r = rects[button] ?: error("缺少热区 $button")
                assertTrue("$button 不得越出卡片左边界", r.left >= geo.left - 0.01f)
                assertTrue("$button 不得越出卡片右边界", r.right <= geo.right + 0.01f)
                assertTrue("$button 不得越出卡片上边界", r.top >= geo.top - 0.01f)
                assertTrue("$button 不得越出卡片下边界", r.bottom <= geo.bottom + 0.01f)
                assertTrue("$button 热区不得小于 48dp", r.width >= LockScreenCardLogic.hitDp * d - 0.01f)
                assertTrue("$button 热区不得小于 48dp", r.height >= LockScreenCardLogic.hitDp * d - 0.01f)
            }
            // 播放圆钮 56dp
            val play = rects.getValue(CardButton.playPause)
            assertEquals(LockScreenCardLogic.transportDp * d, play.width, 0.01f)
        }
    }

    @Test
    fun buttonRectsDoNotOverlap() {
        val w = 360f * d
        val h = 800f * d
        val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
        val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
        val rects = LockScreenCardLogic.buttonRects(geo, d, CardMode.full).values.toList()
        for (i in rects.indices) {
            for (j in i + 1 until rects.size) {
                val a = rects[i]
                val b = rects[j]
                val overlapX = minOf(a.right, b.right) - maxOf(a.left, b.left)
                val overlapY = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
                assertFalse("热区 $i 与 $j 重叠", overlapX > 0.5f && overlapY > 0.5f)
            }
        }
    }

    @Test
    fun compactModeKeepsOnlyPlayPauseInsideCard() {
        val w = 800f * d
        val h = 360f * d
        val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.compact, 1f)
        val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
        val rects = LockScreenCardLogic.buttonRects(geo, d, CardMode.compact)
        assertEquals(setOf(CardButton.playPause), rects.keys)
        val r = rects.getValue(CardButton.playPause)
        assertTrue(r.right <= geo.right + 0.01f && r.left >= geo.left - 0.01f)
        assertTrue(r.bottom <= geo.bottom + 0.01f && r.top >= geo.top - 0.01f)
    }

    // ================= 命中 =================

    @Test
    fun hitTestMatchesCenterAndBoundary() {
        val w = 360f * d
        val h = 800f * d
        val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
        val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
        val rects = LockScreenCardLogic.buttonRects(geo, d, CardMode.full)
        val play = rects.getValue(CardButton.playPause)
        assertEquals(
            CardButton.playPause,
            LockScreenCardLogic.hitTest(
                (play.left + play.right) / 2f,
                (play.top + play.bottom) / 2f,
                rects
            )
        )
        // 边界（闭区间）也算命中
        assertEquals(CardButton.playPause, LockScreenCardLogic.hitTest(play.left, play.top, rects))
        // 卡片外 / 上方空白不命中
        assertNull(LockScreenCardLogic.hitTest(0f, 0f, rects))
        assertNull(LockScreenCardLogic.hitTest(geo.left + 1f, geo.top + 1f, rects))
    }

    @Test
    fun hitTestReturnsNullInGapBetweenButtons() {
        val w = 360f * d
        val h = 800f * d
        val heightDp = LockScreenCardLogic.cardHeightDp(CardMode.full, 1f)
        val geo = LockScreenCardLogic.cardGeometry(w, h, d, heightDp)
        val rects = LockScreenCardLogic.buttonRects(geo, d, CardMode.full)
        val fav = rects.getValue(CardButton.favorite)
        val prev = rects.getValue(CardButton.previous)
        val gapX = (fav.right + prev.left) / 2f
        // 若两键之间确实有缝隙，缝隙中心不命中任何按钮
        if (prev.left - fav.right > 1f) {
            assertNull(
                LockScreenCardLogic.hitTest(
                    gapX,
                    (fav.top + fav.bottom) / 2f,
                    rects
                )
            )
        } else {
            // 极窄屏下热区紧贴，缝隙为 0 属于预期；此处只要求命中其中一个
            assertNotNull(
                LockScreenCardLogic.hitTest(
                    gapX,
                    (fav.top + fav.bottom) / 2f,
                    rects
                )
            )
        }
    }

    // ================= 上滑解锁 =================

    @Test
    fun shouldUnlockSwipeFourCombinations() {
        // 位移够 / 速度不够
        assertTrue(LockScreenCardLogic.shouldUnlockSwipe(-80f * d, 0f, d))
        // 位移不够 / 速度够
        assertTrue(LockScreenCardLogic.shouldUnlockSwipe(-10f * d, -900f * d, d))
        // 两者都不够
        assertFalse(LockScreenCardLogic.shouldUnlockSwipe(-10f * d, -100f * d, d))
        // 向下滑（反向）不解锁
        assertFalse(LockScreenCardLogic.shouldUnlockSwipe(80f * d, 900f * d, d))
    }

    @Test
    fun shouldUnlockSwipeThresholdScalesWithDensity() {
        val dyPx = LockScreenCardLogic.swipeUnlockDp * d
        assertTrue(LockScreenCardLogic.shouldUnlockSwipe(-dyPx, 0f, d))
        assertFalse(LockScreenCardLogic.shouldUnlockSwipe(-dyPx * 0.99f, 0f, d))
    }

    // ================= 帧闸门 =================

    @Test
    fun frameGateBlocksSecondVsyncAt120Hz() {
        val gate = LockScreenFrameGate(16L)
        assertTrue(gate.shouldDraw(1000L))
        // 120Hz 屏下一帧约 +8.3ms：应被闸门拦掉
        assertFalse(gate.shouldDraw(1008L))
        // 累计到 16ms 才放行
        assertTrue(gate.shouldDraw(1016L))
        assertFalse(gate.shouldDraw(1020L))
    }

    @Test
    fun frameGateResetAllowsImmediateDraw() {
        val gate = LockScreenFrameGate(16L)
        assertTrue(gate.shouldDraw(5000L))
        assertFalse(gate.shouldDraw(5008L))
        gate.reset()
        assertTrue("重启帧循环后第一帧必须立即绘制", gate.shouldDraw(5009L))
    }

    @Test
    fun frameGateFirstDrawAlwaysAllowed() {
        val gate = LockScreenFrameGate(16L)
        assertTrue(gate.shouldDraw(0L))
        assertFalse(gate.shouldDraw(1L))
    }
}
