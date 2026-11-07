package com.md3music.md3music.stem

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 4 点 Hermite 重采样器：跨块连续性 + 不变调。
 *
 * 关键判据是**跨块不断裂**：每块单独重采样会在 93ms 接缝处产生相位断裂，
 * 参考实现靠 `prev`/`frac` 把末三帧与小数相位带到下一块。
 */
class CubicResamplerTest {

    private fun sine(frames: Int, freq: Double, srcRate: Int): FloatArray {
        val out = FloatArray(frames * 2)
        for (i in 0 until frames) {
            val s = Math.sin(2.0 * Math.PI * freq * i / srcRate).toFloat()
            out[2 * i] = s
            out[2 * i + 1] = s * 0.5f
        }
        return out
    }

    /** 过零点计数换算主频（简单可靠，不引入 FFT）。 */
    private fun dominantFreqByZeroCross(
        data: FloatArray,
        from: Int,
        to: Int,
        sampleRate: Int,
    ): Double {
        var cross = 0
        var prev = data[from]
        for (i in from + 1 until to) {
            val v = data[i]
            if (prev <= 0f && v > 0f) cross++
            prev = v
        }
        val seconds = (to - from).toDouble() / 2.0 / sampleRate
        return if (seconds > 0) cross / seconds else 0.0
    }

    @Test
    fun sameRateIsIdentityish() {
        val r = CubicResampler(48000, 48000, 2)
        assertTrue("同率不需要重采样", !r.needed())
        val x = sine(480, 1000.0, 48000)
        val y = r.process(x, 480)
        val n = r.lastOutSamples()
        assertEquals("同率输出样本数应约等于输入", 960, n)
        // 同率时 Hermite 在整数相位上取值 = y1，基本等价于原信号
        for (i in 1 until minOf(n, 900) - 1) {
            assertTrue(
                "同率重采样不应放大信号: i=$i y=${y[i]} x=${x[i]}",
                Math.abs(y[i]) < Math.abs(x[i]) * 2.0f + 1e-3f,
            )
        }
    }

    @Test
    fun upsampleKeepsFrequency() {
        // 44.1k → 48k，1 kHz 正弦，主频不应改变（不是变调）
        val r = CubicResampler(44100, 48000, 2)
        val frames = 44100 / 10 // 0.1s
        val x = sine(frames, 1000.0, 44100)
        val y = r.process(x, frames)
        val n = r.lastOutSamples()
        assertTrue("升采样输出应多于输入", n > frames * 2)
        val f = dominantFreqByZeroCross(y, 200, n, 48000)
        assertTrue("升采样后主频应仍在 1kHz 附近，实际=$f", f > 900.0 && f < 1100.0)
    }

    @Test
    fun downSampleKeepsFrequency() {
        // 48k → 44.1k
        val r = CubicResampler(48000, 44100, 2)
        val frames = 4800
        val x = sine(frames, 1000.0, 48000)
        val y = r.process(x, frames)
        val n = r.lastOutSamples()
        assertTrue("降采样输出应少于输入", n < frames * 2)
        val f = dominantFreqByZeroCross(y, 200, n, 44100)
        assertTrue("降采样后主频应仍在 1kHz 附近，实际=$f", f > 900.0 && f < 1100.0)
    }

    @Test
    fun continuousAcrossChunkBoundary() {
        // 关键护栏：跨块不能有相位断裂。
        //
        // 判据只看**块接缝处**的跳变，并以同一拼接信号的「块内」跳变最大值
        // 作对照 —— 不能拿全曲线最大跳变当阈值：1000Hz 正弦在 44.1k 下相邻
        // 样本本来就能跳约 0.14，首块尾部用截断样本还会更大，那些都与跨块
        // 连续性无关（实测全曲线 max≈0.51 出现在块内，不是接缝）。
        val sr = 48000
        val dst = 44100
        val r = CubicResampler(sr, dst, 2)
        val frames = 4096
        val total = frames * 3
        val full = sine(total, 1000.0, sr)

        val joined = ArrayList<Float>()
        val seams = ArrayList<Int>()
        var off = 0
        while (off < total) {
            val take = minOf(frames, total - off)
            val seg = FloatArray(take * 2)
            System.arraycopy(full, off * 2, seg, 0, take * 2)
            val y = r.process(seg, take)
            val n = r.lastOutSamples()
            for (i in 0 until n) joined.add(y[i])
            if (off + take < total) seams.add(joined.size)
            off += take
        }

        fun isSeam(i: Int): Boolean {
            for (s in seams) {
                if (i == s) return true
            }
            return false
        }

        var interiorMax = 0.0f
        for (i in 1 until joined.size) {
            if (isSeam(i)) continue
            val d = Math.abs(joined[i] - joined[i - 1])
            if (d > interiorMax) interiorMax = d
        }

        var seamMax = 0.0f
        for (s in seams) {
            if (s <= 0 || s >= joined.size) continue
            val d = Math.abs(joined[s] - joined[s - 1])
            if (d > seamMax) seamMax = d
        }

        assertTrue(
            "块接缝跳变 $seamMax 不应显著大于块内最大跳变 $interiorMax",
            seamMax <= interiorMax * 1.5f + 1e-4f,
        )
    }

    @Test
    fun resetClearsPhaseAndHistory() {
        val r = CubicResampler(44100, 48000, 2)
        val x = sine(480, 1000.0, 44100)
        r.process(x, 480)
        r.reset()
        // reset 后再喂同样的块，输出应当可重复（相位已归零）
        val y1 = r.process(x, 480)
        val n1 = r.lastOutSamples()
        val first = y1[10]
        r.reset()
        val y2 = r.process(x, 480)
        assertEquals("reset 后相位应归零（输出可重复）", first, y2[10], 1e-6f)
        assertEquals(n1, r.lastOutSamples())
    }
}
