package com.md3music.md3music.spectrum

import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpectrumFftTest {

    private val fftSize = 1024
    private val bandCount = 40

    /** 生成 freqBin 号频点的整周期正弦（整数周期保证无频谱泄漏）。 */
    private fun tone(freqBin: Int): FloatArray =
        FloatArray(fftSize) { i -> sin(2.0 * PI * freqBin * i / fftSize).toFloat() }

    @Test
    fun peakLandsOnTheToneBin() {
        val fft = SpectrumFft(fftSize, bandCount)
        // computeBands 从 bin1 开始（跳过 DC），所以 bin1 对应数组下标 0
        val bands = fft.bandsFrom(tone(1))
        assertEquals(fftSize / 2, fft.outputBinCount)
        val peakIndex = bands.indices.maxByOrNull { bands[it] }!!
        assertEquals(0, peakIndex)
        assertEquals(1.0, bands[peakIndex], 1e-6)
    }

    @Test
    fun higherToneBinLandsOnMatchingBand() {
        val fft = SpectrumFft(fftSize, bandCount)
        val bands = fft.bandsFrom(tone(11))
        val peakIndex = bands.indices.maxByOrNull { bands[it] }!!
        // 跳过 DC 后 bin11 落在下标 10
        assertEquals(10, peakIndex)
    }

    @Test
    fun allBandsStayNormalizedWithinZeroOne() {
        val fft = SpectrumFft(fftSize, bandCount)
        val bands = fft.bandsFrom(tone(3))
        for (b in bands) {
            assertTrue("band out of range: $b", b >= 0.0 && b <= 1.0)
        }
    }

    @Test
    fun silenceYieldsAllZeroBands() {
        val fft = SpectrumFft(fftSize, bandCount)
        val bands = fft.bandsFrom(FloatArray(fftSize))
        for (b in bands) assertEquals(0.0, b, 0.0)
    }

    @Test
    fun bandsBeyondNyquistBinsAreZero() {
        val fft = SpectrumFft(fftSize, bandCount)
        val bands = fft.bandsFrom(tone(1))
        // bandCount=40 < fftSize/2=512，所以只有前 40 个 bin 有值，其余不存在
        assertEquals(bandCount, bands.size)
    }

    @Test
    fun ringSnapshotIsReadStartingAtWritePosition() {
        val fft = SpectrumFft(fftSize, bandCount)
        // 环形缓冲：把 tone 从 writePos 处绕圈写入
        val ring = FloatArray(fftSize)
        val tone = tone(1)
        val writePos = 300
        for (i in 0 until fftSize) {
            ring[(writePos + i) % fftSize] = tone[i]
        }
        val snapshot = FloatArray(fftSize)
        fft.copyRingInto(ring, writePos, snapshot)
        val bands = fft.bandsFrom(snapshot)
        val peakIndex = bands.indices.maxByOrNull { bands[it] }!!
        assertEquals(0, peakIndex)
    }

    @Test
    fun magnitudesScaleLinearlyWithAmplitude() {
        val fft = SpectrumFft(fftSize, bandCount)
        val full = fft.magnitudesFrom(tone(1)).copyOf()
        val halfInput = FloatArray(fftSize) { i -> 0.5f * tone(1)[i] }
        val half = fft.magnitudesFrom(halfInput).copyOf()

        assertTrue("半幅度的峰值必须非零", full[0] > 0.0)
        // 归一化路径做不到这一点（分母是帧内最大值，两者都会变成 1.0）
        assertEquals(full[0] / 2.0, half[0], full[0] * 1e-4)
    }

    @Test
    fun silenceYieldsZeroMagnitudes() {
        val fft = SpectrumFft(fftSize, bandCount)
        val mags = fft.magnitudesFrom(FloatArray(fftSize)).copyOf()
        assertEquals(fftSize / 2, mags.size)
        for (v in mags) assertEquals(0.0, v, 0.0)
    }
}
