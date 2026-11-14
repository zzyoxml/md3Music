package com.md3music.md3music.stem

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 渲染线程热路径的**开销与正确性**护栏。
 *
 * 背景：端侧分离曾经出现「一卡一卡」的间歇性卡音。根因不是模型慢，而是
 * 音频渲染线程（ExoPlayer 的 `process`）里的逐帧循环：
 *
 * - 每帧 `blocks.iterator()` → 约 44,100 个短命对象/秒 → 年轻代 GC 压力，
 *   停顿正好砸在音频线程；
 * - 每帧 `Math.cos` + `Math.sin` → 约 88,200 次/秒；
 * - 每帧 `frame % DRY_RING` → 44,100 次取模；
 * - `emitCount` 无上限：某批迟到后，下一批要一次性补更多帧，形成
 *   「越卡 → 单批越重 → 更卡」的正反馈。
 *
 * 修法：按块批量填充（O(块数) 而非 O(帧数)）+ 单批限速。
 * 本测试锁死三点：批量填充结果正确、单批限速生效、稳态无爆音。
 */
class StemSeparateHotPathTest {

    /** 静音解释器：输出全零，便于只观察会话本身的搬运逻辑。 */
    private class SilentInterp : MssInterpreter {
        override fun stateShapes(): List<IntArray> = emptyList()
        override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
            output.fill(0f)
        }
        override fun close() {}
    }

    /** 恒定解释器：把输入频谱原样搬进人声 stem（等价于直通）。 */
    private class PassThroughInterp : MssInterpreter {
        override fun stateShapes(): List<IntArray> = emptyList()
        override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
            output.fill(0f)
            for (t in 0 until MssEngine.FRAMES) {
                for (c in 0 until 2) {
                    val srcBase = t * 4 * MssEngine.BINS + c * 2 * MssEngine.BINS
                    val dstBase = t * 16 * MssEngine.BINS + c * 2 * MssEngine.BINS
                    for (f in 0 until MssEngine.BINS) {
                        output[dstBase + f] = input[srcBase + f]
                        output[dstBase + MssEngine.BINS + f] =
                            input[srcBase + MssEngine.BINS + f]
                    }
                }
            }
        }
        override fun close() {}
    }

    @Test
    fun steadyStateProducesFiniteBoundedOutput() {
        // 稳态必须持续产出有限值，且不得出现 NaN/Inf（批量写段时最容易越界或
        // 读到未初始化区域，产生 NaN）。
        val session = StemSeparateSession { MssEngine(PassThroughInterp()) }
        session.configure(44100, 2)
        session.setMix(1.0f)

        val frames = 882 // ≈20ms
        val buf = FloatArray(frames * 2) { i -> if (i % 2 == 0) 0.25f else -0.25f }
        val out = FloatArray(frames * 2)

        var produced = 0
        repeat(40) {
            val written = session.process(buf, frames, out, 2)
            produced += written
            for (v in out) {
                assertTrue("输出必须是有限值（出现 NaN/Inf 说明段写越界）", v.isFinite())
                assertTrue("输出幅度不应离谱: $v", kotlin.math.abs(v) <= 1.5f)
            }
        }
        assertTrue("稳态应持续产出，实际 $produced 帧", produced > 0)
    }

    @Test
    fun singleBatchIsRateLimitedSoStutterCannotAmplify() {
        // 限速：单批处理量不得超过 2×frames。否则一次迟到会把音频线程拖得更久，
        // 形成正反馈（这正是「一卡一卡」的成因）。
        //
        // 构造方式：一次性喂入远超 2×frames 的量，让 consumed-emit 出现巨大欠账，
        // 然后在一次很小的 process 里观察它实际处理了多少。
        val session = StemSeparateSession { MssEngine(SilentInterp()) }
        session.configure(44100, 2)
        session.setMix(1.0f)

        val big = MssEngine.CHUNK * 8
        val bigBuf = FloatArray(big * 2) { 0.1f }
        val bigOut = FloatArray(big * 2)
        session.process(bigBuf, big, bigOut, 2)

        // 欠账巨大时，用一小批（frames=64）调用：写回量不得超过 2×64=128 帧
        val small = 64
        val smallBuf = FloatArray(small * 2) { 0.1f }
        val smallOut = FloatArray(small * 2)
        val written = session.process(smallBuf, small, smallOut, 2)
        assertTrue(
            "单批写回必须被限速到 ≤2×frames(=${2 * small})，实际 $written",
            written <= 2 * small,
        )
    }

    @Test
    fun skippedFramesCountsOnlyWhenOverloadedByStaleBatch() {
        val session = StemSeparateSession { MssEngine(SilentInterp()) }
        session.configure(44100, 2)
        session.setMix(1.0f)

        // 正常节奏（每批 ≈1 个 CHUNK）不应产生跳过
        val frames = MssEngine.CHUNK
        val buf = FloatArray(frames * 2) { 0.1f }
        val out = FloatArray(frames * 2)
        var last = 0L
        repeat(6) {
            session.process(buf, frames, out, 2)
            val st = session.stats()
            assertEquals("正常节奏不应跳过帧", 0L, st.skippedFrames)
            last = st.skippedFrames
        }
        assertEquals(0L, last)
    }

    @Test
    fun mixChangeIsSmoothWithoutJump() {
        // 比例从 1.0 拉到 0.0 时，批量写段沿用「每段推进 5%」，
        // 相邻输出块之间不应出现突变（爆音）。
        val session = StemSeparateSession { MssEngine(PassThroughInterp()) }
        session.configure(44100, 2)
        session.setMix(1.0f)

        val frames = 882
        val buf = FloatArray(frames * 2) { 0.5f }
        val out = FloatArray(frames * 2)
        repeat(20) { session.process(buf, frames, out, 2) }

        session.setMix(0.0f)
        var prev = Float.NaN
        var maxJump = 0f
        repeat(20) {
            session.process(buf, frames, out, 2)
            val cur = out[0]
            if (!prev.isNaN()) {
                val jump = kotlin.math.abs(cur - prev)
                if (jump > maxJump) maxJump = jump
            }
            prev = cur
        }
        // 每段 5% 的步长，单段增益变化远小于满幅跳变
        assertTrue("比例变化不应出现满幅突变，实际最大跳变 $maxJump", maxJump < 0.3f)
    }
}
