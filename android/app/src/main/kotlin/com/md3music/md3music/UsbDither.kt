package com.md3music.md3music

import kotlin.math.floor

/**
 * xorshift32：确定性 32 位 PRNG（Marsaglia, 2003）。
 * 状态 0 视为非法，初始化时替换为黄金比例常数；可注入种子以便单元测试复现。
 */
internal class XorShift32(seed: UInt) {
    private var state: UInt = if (seed == 0u) 0x9E3779B9u else seed

    fun nextUInt(): UInt {
        var x = state
        x = x xor (x shl 13)
        x = x xor (x shr 17)
        x = x xor (x shl 5)
        state = x
        return x
    }

    /** [0,1) 均匀分布（24bit 精度；抖动分辨率 1 LSB=2^8，足够）。 */
    fun nextUniform(): Double = (nextUInt() shr 8).toDouble() / 16777216.0
}

/**
 * USB 独占降位路径的「音量缩放 + TPDF 抖动 + 量化」。
 *
 * 采样模型（Lipshitz / Vanderkooy）：
 *   y    = s × v + d + 0.5·LSB(target)
 *   out  = floor(y)                （写在源位深；native 侧随后的截断即完成 floor(y / LSB)）
 *   d    = (u1 + u2 − 1) × LSB(target)   —— 两个独立均匀分布相减 ⇒ 三角分布，峰峰值 2 LSB
 *
 * 仅在 inputBitDepth > dacBitDepth（真的在丢位）时加抖动；补位（16→24/24→32）是数学无损的，
 * 加抖动只会白白抬高噪底，因此明确不加。
 */
internal object UsbDither {

    /** 是否存在位深缩减。 */
    fun isReducing(inputBitDepth: Int, dacBitDepth: Int): Boolean = inputBitDepth > dacBitDepth

    /** 目标域 1 LSB 在源域中的宽度（如 32→24 = 256）。 */
    fun sourceLsb(inputBitDepth: Int, dacBitDepth: Int): Long =
        1L shl (inputBitDepth - dacBitDepth).coerceAtLeast(0)

    /** TPDF 偏移：三角分布，峰峰值 = 2×lsb，均值 0。 */
    fun tpdfOffset(lsb: Long, rng: XorShift32): Double =
        (rng.nextUniform() + rng.nextUniform() - 1.0) * lsb.toDouble()

    /**
     * 单样本：音量缩放 +（可选）TPDF 抖动 + 取整回源位深。
     * 抖动关闭时保持历史行为（向零截断），与旧 scalePcmInPlace 逐字节一致。
     */
    fun scaleAndQuantize(
        sample: Long,
        inputBitDepth: Int,
        dacBitDepth: Int,
        volume: Double,
        dither: Boolean,
        rng: XorShift32,
    ): Long {
        var y: Double = sample * volume
        val shift = (inputBitDepth - dacBitDepth).coerceAtLeast(0)
        if (dither && shift > 0) {
            val lsb = 1L shl shift
            y += tpdfOffset(lsb, rng) + (lsb / 2.0)
            return clampSigned(floor(y).toLong(), inputBitDepth)
        }
        return clampSigned(y.toLong(), inputBitDepth)
    }

    /**
     * 原地遍历：音量缩放 +（可选）TPDF 抖动。
     * 抖动关闭且音量 ≥0.999 时直接返回 —— 零开销，保护 bit-perfect 直写契约。
     * 按「样本」而非「帧」遍历，与声道数无关（与旧 scalePcmInPlace 相同）。
     */
    fun applyVolumeAndDitherInPlace(
        buffer: ByteArray,
        inputBitDepth: Int,
        dacBitDepth: Int,
        volume: Float,
        dither: Boolean,
        rng: XorShift32,
    ) {
        val needScale = volume < 0.999f
        if (!needScale && !(dither && isReducing(inputBitDepth, dacBitDepth))) return
        val v = volume.toDouble()
        val bytesPerSample = inputBitDepth / 8
        var i = 0
        while (i + bytesPerSample <= buffer.size) {
            writeSample(buffer, i, inputBitDepth,
                scaleAndQuantize(readSample(buffer, i, inputBitDepth).toLong(),
                    inputBitDepth, dacBitDepth, v, dither, rng))
            i += bytesPerSample
        }
    }

    // ── 采样读写（小端、按位深符号扩展） ─────────────────────────────

    internal fun readSample(b: ByteArray, o: Int, bits: Int): Int = when (bits) {
        16 -> {
            val u = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
            if (u and 0x8000 != 0) u - 0x10000 else u
        }
        24 -> {
            val u = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8) or
                    ((b[o + 2].toInt() and 0xFF) shl 16)
            if (u and 0x800000 != 0) u - 0x1000000 else u
        }
        else -> (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8) or
                ((b[o + 2].toInt() and 0xFF) shl 16) or (b[o + 3].toInt() shl 24)
    }

    internal fun writeSample(b: ByteArray, o: Int, bits: Int, v: Long) {
        val x = v.toInt()
        b[o] = (x and 0xFF).toByte()
        if (bits >= 16) b[o + 1] = ((x shr 8) and 0xFF).toByte()
        if (bits >= 24) b[o + 2] = ((x shr 16) and 0xFF).toByte()
        if (bits >= 32) b[o + 3] = ((x shr 24) and 0xFF).toByte()
    }

    /** 夹到带符号 N 位范围（32bit 全幅 + 抖动可能越界，必须夹取而不是回绕）。 */
    private fun clampSigned(v: Long, bitDepth: Int): Long {
        val lo = -(1L shl (bitDepth - 1))
        val hi = (1L shl (bitDepth - 1)) - 1
        return v.coerceIn(lo, hi)
    }
}
