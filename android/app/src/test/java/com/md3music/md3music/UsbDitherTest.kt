package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbDitherTest {

    /** 固定种子，保证统计断言可复现。 */
    private fun rng(seed: Long = 0x5EEDL) = XorShift32(seed.toUInt())

    // ── 1. TPDF 偏移的分布性质 ──────────────────────────────────────────

    @Test
    fun tpdf_meanIsZero_andPeakWithinOneLsb() {
        val r = rng()
        val lsb = 256L                      // 32→24：目标域 1 LSB = 2^8
        var sum = 0.0
        var min = Double.MAX_VALUE
        var max = -Double.MAX_VALUE
        val n = 200_000
        repeat(n) {
            val d = UsbDither.tpdfOffset(lsb, r)
            sum += d
            if (d < min) min = d
            if (d > max) max = d
        }
        assertEquals(0.0, sum / n, lsb * 0.02)    // 均值 ≈ 0（无 DC）；容差 ≈ 22σ，避免统计抖动误报
        assertTrue("min=$min", min >= -lsb)       // 峰峰值 ≤ 2 LSB
        assertTrue("max=$max", max <= lsb)
    }

    @Test
    fun tpdf_isDeterministic_forSameSeed() {
        val a = UsbDither.tpdfOffset(256L, rng(7L))
        val b = UsbDither.tpdfOffset(256L, rng(7L))
        assertEquals(a, b, 0.0)
    }

    // ── 2. 单样本量化 ──────────────────────────────────────────────────

    @Test
    fun quantize_32to24_ditherOn_isUnbiasedAtHalfLsb() {
        // 输入 = -128（32bit 域），即目标域的 -0.5 LSB：截断会系统性偏向 -1，
        // 加抖动后期望回到 -0.5（量化误差均值为 0）。
        val r = rng()
        val n = 200_000
        var sum = 0.0
        repeat(n) {
            val q = UsbDither.scaleAndQuantize(
                sample = -128L, inputBitDepth = 32, dacBitDepth = 24,
                volume = 1.0, dither = true, rng = r)
            // native 侧随后 >>8（取高 3 字节）＝ floor(q / 256)
            sum += Math.floorDiv(q, 256L).toDouble()
        }
        assertEquals(-0.5, sum / n, 0.02)
    }

    @Test
    fun quantize_32to24_ditherOff_keepsLegacyTruncationBias() {
        // 抖动关闭：必须与旧行为一致（向零截断），-128 → floor(-128/256) = -1
        val r = rng()
        val q = UsbDither.scaleAndQuantize(
            sample = -128L, inputBitDepth = 32, dacBitDepth = 24,
            volume = 1.0, dither = false, rng = r)
        assertEquals(-1L, Math.floorDiv(q, 256L))
    }

    @Test
    fun quantize_noReduction_neverAddsNoise() {
        // 24bit 源 → 24bit 端点：无位深缩减，抖动必须不介入
        val r = rng()
        val q1 = UsbDither.scaleAndQuantize(
            sample = 123456L, inputBitDepth = 24, dacBitDepth = 24,
            volume = 1.0, dither = true, rng = r)
        assertEquals(123456L, q1)
    }

    @Test
    fun quantize_clampsAtFullScale() {
        // 32bit 正满幅 + 抖动可能越过 int32 上界：必须夹取而不是回绕
        val r = rng()
        repeat(1000) {
            val q = UsbDither.scaleAndQuantize(
                sample = Int.MAX_VALUE.toLong(), inputBitDepth = 32, dacBitDepth = 24,
                volume = 1.0, dither = true, rng = r)
            assertTrue(q in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong())
        }
    }

    // ── 3. 缓冲级遍历 ──────────────────────────────────────────────────

    @Test
    fun buffer_ditherOff_volumeAtFull_isNoop() {
        // bit-perfect 契约：默认状态（关抖动 + 满音量）必须零改动
        val buf = byteArrayOf(0x01, 0x02, 0x03, 0x7F, -0x01, -0x02, 0x10, 0x20)
        val before = buf.copyOf()
        UsbDither.applyVolumeAndDitherInPlace(
            buf, inputBitDepth = 32, dacBitDepth = 24,
            volume = 1.0f, dither = false, rng = rng())
        assertTrue(before.contentEquals(buf))
    }

    @Test
    fun buffer_volumeOnly_matchesLegacyTruncation() {
        // 抖动关闭 + 音量 <1：必须与旧 scalePcmInPlace 一致（向零截断）
        // 旧实现（24bit）：s = LE24(signed)；s = (s * v).toInt()；写回低 3 字节
        val v = 0.5f
        val raw = intArrayOf(0x123456, -0x123456, 0x000001, -0x000001, 0x7FFFFF, -0x800000)
        val buf = ByteArray(raw.size * 3)
        raw.forEachIndexed { idx, s ->
            val u = if (s < 0) s + 0x1000000 else s
            buf[idx * 3] = (u and 0xFF).toByte()
            buf[idx * 3 + 1] = ((u shr 8) and 0xFF).toByte()
            buf[idx * 3 + 2] = ((u shr 16) and 0xFF).toByte()
        }
        UsbDither.applyVolumeAndDitherInPlace(
            buf, inputBitDepth = 24, dacBitDepth = 24,
            volume = v, dither = false, rng = rng())
        raw.forEachIndexed { idx, s ->
            val o = idx * 3
            val got = (buf[o].toInt() and 0xFF) or
                    ((buf[o + 1].toInt() and 0xFF) shl 8) or
                    ((buf[o + 2].toInt() and 0xFF) shl 16)
            val signed = if (got and 0x800000 != 0) got - 0x1000000 else got
            val expected = (s * v).toInt()
            assertEquals("sample#$idx", expected, signed)
        }
    }

    @Test
    fun buffer_roundTrip_16_24_32() {
        // 读/写助手对 16/24/32 的往返一致性
        for (bits in listOf(16, 24, 32)) {
            val bytes = bits / 8
            // 取三种位深都合法的值，保证三种宽度下都能精确往返
            val samples = intArrayOf(0, 1, -1, 0x7F, -0x7F, 0x7FFF, -0x8000)
            val buf = ByteArray(samples.size * bytes)
            samples.forEachIndexed { idx, s ->
                UsbDither.writeSample(buf, idx * bytes, bits, s.toLong())
            }
            samples.forEachIndexed { idx, s ->
                val back = UsbDither.readSample(buf, idx * bytes, bits)
                assertEquals(s.toLong(), back.toLong())   // 三种位深下均为合法值 ⇒ 精确往返
            }
        }
    }

    // ── 4. 数据路径级守卫（接入 writeRaw 后行为不变的验收） ─────────────

    @Test
    fun streamPath_32to24_ditherOn_isUnbiasedAcrossLevels() {
        // 数据路径级验收：覆盖「量化边界附近」的多个电平，验证抖动后期望值 = x/LSB（无偏）。
        // 逐样本断言差异不可用（抖动本来就允许 ±1 LSB 的合法偏移），必须看统计均值。
        val r = rng()
        val levels = listOf(-300L, -128L, -64L, 0L, 64L, 128L, 300L)
        for (x in levels) {
            var sum = 0.0
            val n = 60_000
            repeat(n) {
                val q = UsbDither.scaleAndQuantize(x, 32, 24, 1.0, true, r)
                // native 侧截断 = floor(q / 256)（取高 3 字节）
                sum += Math.floorDiv(q, 256L).toDouble()
            }
            assertEquals("x=$x", x / 256.0, sum / n, 0.05)
        }
    }
}
