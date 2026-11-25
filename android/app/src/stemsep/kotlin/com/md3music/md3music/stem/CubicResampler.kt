package com.md3music.md3music.stem

/**
 * 带状态的 4 点三次（Hermite）重采样器。
 *
 * 用于 44.1 kHz（模型域）↔ 设备原生输出率（常见 48 kHz）。
 *
 * **必须跨块延续状态**：每条 4096 样本的块单独做重采样会在接缝处产生相位
 * 断裂（听感是每 93 ms 一次轻响），参考实现就是用 `prev`/`frac` 把末三个样本
 * 与小数相位带到下一块。纯 Kotlin，可 JVM 单测。
 */
internal class CubicResampler(
    private var srcRate: Int,
    private var dstRate: Int,
    private var channels: Int,
) {
    /** 每产出一个输出帧，源相位前进多少帧。 */
    private var step: Double = if (dstRate > 0) srcRate.toDouble() / dstRate else 1.0

    /** 小数相位（跨块延续）。 */
    private var frac = 0.0

    /** 上一块的末三个输入帧，按声道。 */
    private val prev = Array(3) { FloatArray(2) }

    private val blk = FloatArray(2 * (CUBIC_OUT_CAP + 8))
    private var outLen = 0

    /** 是否需要重采样（源率与目标率不同且两者都合法）。 */
    fun needed(): Boolean = srcRate >= 8000 && dstRate >= 8000 && srcRate != dstRate

    fun reconfigure(srcRate: Int, dstRate: Int, channels: Int) {
        if (srcRate >= 8000) this.srcRate = srcRate
        if (dstRate >= 8000) this.dstRate = dstRate
        step = if (this.dstRate > 0) this.srcRate.toDouble() / this.dstRate else 1.0
        this.channels = maxOf(1, channels)
        reset()
    }

    /** 清空相位与历史（seek / 格式切换 / 重新开启）。 */
    fun reset() {
        frac = 0.0
        for (p in prev) p.fill(0f)
        outLen = 0
    }

    companion object {
        /** 单块输入最多 CHUNK 帧，输出不会超过它（升采样时约 1.11×，留足余量）。 */
        private const val CUBIC_OUT_CAP = MssEngine.CHUNK * 2

        private fun cubic(y0: Float, y1: Float, y2: Float, y3: Float, t: Float): Float {
            return 0.5f * (
                (2f * y1) +
                    (-y0 + y2) * t +
                    (2f * y0 - 5f * y1 + 4f * y2 - y3) * t * t +
                    (-y0 + 3f * y1 - 3f * y2 + y3) * t * t * t
                )
        }
    }

    /**
     * 重采样一段交错 PCM。
     *
     * @param inter 交错输入，长度 = frames × channels
     * @param frames 输入帧数
     * @return 交错输出；长度由 [outLen] 给出，缓冲复用（调用方必须立刻消费）
     */
    fun process(inter: FloatArray, frames: Int): FloatArray {
        outLen = 0
        if (frames <= 0) return blk
        val ch = channels
        var out = 0
        var p = frac
        while (p < frames) {
            val i = p.toInt()
            val t = (p - i).toFloat()
            for (c in 0 until minOf(2, ch)) {
                val y0 = at(inter, frames, c, i - 1)
                val y1 = at(inter, frames, c, i)
                val y2 = at(inter, frames, c, i + 1)
                val y3 = at(inter, frames, c, i + 2)
                val v = cubic(y0, y1, y2, y3, t)
                if (out + c < blk.size) blk[out + c] = v
            }
            // 单声道时另一路镜像，保持交错立体声的消费口径一致
            if (ch == 1 && out + 1 < blk.size) blk[out + 1] = blk[out]
            out += 2
            p += step
        }
        outLen = out
        frac = p - frames
        // 留末三帧做下一块的左邻
        for (k in 0 until 3) {
            val idx = frames - 3 + k
            if (idx >= 0) {
                prev[k][0] = inter[idx * ch]
                prev[k][1] = if (ch > 1) inter[idx * ch + 1] else prev[k][0]
            }
        }
        return blk
    }

    /** 上一次 [process] 产出的样本数（交错计数，不是帧数）。 */
    fun lastOutSamples(): Int = outLen

    fun channels(): Int = channels

    private fun at(inter: FloatArray, frames: Int, c: Int, idx: Int): Float {
        val ch = channels
        if (idx < 0) {
            val k = idx + 3
            return if (k < 0) 0f else prev[k][if (c < 2) c else 0]
        }
        if (idx >= frames) return inter[(frames - 1) * ch + minOf(c, ch - 1)]
        return inter[idx * ch + minOf(c, ch - 1)]
    }
}
