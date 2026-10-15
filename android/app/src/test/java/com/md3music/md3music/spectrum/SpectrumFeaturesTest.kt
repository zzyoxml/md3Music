package com.md3music.md3music.spectrum

import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpectrumFeaturesTest {

    private val fftSize = 1024
    private val binCount = fftSize / 2
    private val sampleRate = 44100
    private val hzPerBin = sampleRate.toDouble() / fftSize

    private fun features() = SpectrumFeatures(fftSize, binCount)
    private fun out() = FloatArray(SpectrumFeatures.COUNT)

    /** 造一个只在下标 [bin] 有能量的幅度谱（下标即 mags 下标，对应 FFT bin+1）。 */
    private fun spike(bin: Int): DoubleArray =
        DoubleArray(binCount).also { it[bin] = 1.0 }

    private fun silence(): FloatArray = FloatArray(fftSize)

    @Test
    fun countMatchesDocumentedLayout() {
        assertEquals(20, SpectrumFeatures.COUNT)
        assertEquals(16, SpectrumFeatures.LOG_BAND_COUNT)
        assertEquals(16, SpectrumFeatures.INDEX_RMS)
        assertEquals(17, SpectrumFeatures.INDEX_LOW)
        assertEquals(18, SpectrumFeatures.INDEX_HIGH)
        assertEquals(19, SpectrumFeatures.INDEX_MID)
    }

    @Test
    fun lowBandSpikeOnlyRaisesLowIndex() {
        val f = features()
        val o = out()
        // 100Hz 落在低频带 (30..300Hz)
        val bin = (100.0 / hzPerBin).toInt() - 1
        f.extract(sampleRate, spike(bin), silence(), o)

        assertTrue("低频频带能量应大于 0", o[SpectrumFeatures.INDEX_LOW] > 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_HIGH], 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_MID], 0f)
    }

    @Test
    fun highBandSpikeOnlyRaisesHighIndex() {
        val f = features()
        val o = out()
        // 5000Hz 落在高频带 (3k..8kHz)
        val bin = (5000.0 / hzPerBin).toInt() - 1
        f.extract(sampleRate, spike(bin), silence(), o)

        assertTrue("高频频带能量应大于 0", o[SpectrumFeatures.INDEX_HIGH] > 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_LOW], 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_MID], 0f)
    }

    @Test
    fun midBandSpikeOnlyRaisesMidIndex() {
        val f = features()
        val o = out()
        // 1000Hz 落在中频带 (300Hz..3kHz)
        val bin = (1000.0 / hzPerBin).toInt() - 1
        f.extract(sampleRate, spike(bin), silence(), o)

        assertTrue("中频频带能量应大于 0", o[SpectrumFeatures.INDEX_MID] > 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_LOW], 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_HIGH], 0f)
    }

    @Test
    fun rmsMatchesSineAmplitudeOverSqrtTwo() {
        val f = features()
        val o = out()
        val amp = 0.5f
        val samples = FloatArray(fftSize) { i ->
            (amp * sin(2.0 * PI * 128 * i / fftSize)).toFloat()
        }
        f.extract(sampleRate, DoubleArray(binCount), samples, o)

        // 整周期正弦的 RMS = 幅值 / √2
        val expected = (amp / sqrt(2.0)).toDouble()
        assertEquals(expected, o[SpectrumFeatures.INDEX_RMS].toDouble(), 1e-3)
    }

    @Test
    fun silenceYieldsAllZero() {
        val f = features()
        val o = out()
        f.extract(sampleRate, DoubleArray(binCount), silence(), o)
        for (v in o) assertEquals(0f, v, 0f)
    }

    @Test
    fun logBandsAreMonotonicInFrequency() {
        val f = features()
        // 把一个单 bin 尖峰从低到高扫过去，命中的对数频带下标必须单调不减
        var lastBand = -1
        for (bin in intArrayOf(1, 3, 6, 12, 25, 50, 100, 200, 300, 370)) {
            val o = out()
            f.extract(sampleRate, spike(bin), silence(), o)
            val hit = (0 until SpectrumFeatures.LOG_BAND_COUNT)
                .filter { o[it] > 0f }
            assertTrue("bin=$bin 应至少命中一个对数频带", hit.isNotEmpty())
            assertTrue("bin=$bin 命中的频带下标不得回退", hit.min() >= lastBand)
            lastBand = hit.min()
        }
    }

    @Test
    fun sampleRateChangeRebuildsBandTable() {
        val f = features()
        val o = out()
        // 48000Hz 下 100Hz 仍应落在低频带（bin 表必须随采样率重建，不能停在 44100 那份）
        val bin48 = (100.0 / (48000.0 / fftSize)).toInt() - 1
        f.extract(48000, spike(bin48), silence(), o)

        assertTrue("采样率变化后低频带仍应命中", o[SpectrumFeatures.INDEX_LOW] > 0f)
        assertEquals(0f, o[SpectrumFeatures.INDEX_HIGH], 0f)
    }
}
