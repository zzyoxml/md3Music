package com.md3music.md3music.spectrum

import java.nio.ByteBuffer
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SpectrumAnalyzerTest {

    private val fftSize = 8
    private val bandCount = 4

    /** 假时钟：手动推进，避免测试依赖真实时间。 */
    private class FakeClock {
        var now = 0L
        fun advance(ms: Long) { now += ms }
    }

    private fun analyzer(clock: FakeClock, intervalMs: Long = 45L) = SpectrumAnalyzer(
        fftSize = fftSize,
        bandCount = bandCount,
        minEmitIntervalMs = intervalMs,
        clock = { clock.now },
    )

    /** 频率相关断言专用：8 点 FFT 的 bin 宽是 5512Hz，分不出低/高频带。 */
    private fun bigAnalyzer() = SpectrumAnalyzer(
        fftSize = 1024,
        bandCount = 40,
        minEmitIntervalMs = 0L,
        clock = { 0L },
    )

    /** 产生 frames 帧 16bit 单声道满幅样本。 */
    private fun pcm(frames: Int, amplitude: Short = 16384): ByteBuffer {
        val buf = ByteBuffer.allocate(frames * 2)
        repeat(frames) { buf.putShort(amplitude) }
        buf.flip()
        return buf
    }

    @Test
    fun doesNotEmitUntilRingIsFull() {
        val clock = FakeClock()
        val a = analyzer(clock)
        assertFalse(a.append(pcm(fftSize - 1), PcmEncoding.PCM_16BIT, 44100, 1))
        assertEquals((fftSize - 1).toLong(), a.totalFrames)
        clock.advance(100)
        assertTrue(a.append(pcm(1), PcmEncoding.PCM_16BIT, 44100, 1))
        assertEquals(fftSize.toLong(), a.totalFrames)
    }

    @Test
    fun emitCountCountsProducedFramesNotSamples() {
        val clock = FakeClock()
        val a = analyzer(clock, intervalMs = 0L)
        // 一次 append 写入 3*fftSize 个采样帧，只产出 1 帧
        assertTrue(a.append(pcm(fftSize * 3), PcmEncoding.PCM_16BIT, 44100, 1))
        assertEquals(fftSize * 3L, a.totalFrames)
        assertEquals(1L, a.emitCount)
        // 再产出一帧
        assertTrue(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
        assertEquals(2L, a.emitCount)
        // reset 后归零
        a.reset()
        assertEquals(0L, a.emitCount)
    }

    @Test
    fun throttlesEmitsToMinInterval() {
        val clock = FakeClock()
        val a = analyzer(clock, intervalMs = 45L)
        assertTrue(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
        // 未到节流间隔 → 不出帧
        clock.advance(10)
        assertFalse(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
        // 跨过间隔 → 出帧
        clock.advance(40)
        assertTrue(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
    }

    @Test
    fun emitsOnTheVeryFirstFullRingRegardlessOfInterval() {
        val clock = FakeClock()
        clock.now = 123_456L // 非零起点，验证首次不被节流误杀
        val a = analyzer(clock)
        assertTrue(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
    }

    @Test
    fun recordsLatestNonZeroSampleRate() {
        val clock = FakeClock()
        val a = analyzer(clock)
        a.append(pcm(2), PcmEncoding.PCM_16BIT, 48000, 1)
        assertEquals(48000, a.sampleRateHz)
        // 后续块报 0 时不覆盖已知的有效值
        a.append(pcm(2), PcmEncoding.PCM_16BIT, 0, 1)
        assertEquals(48000, a.sampleRateHz)
    }

    @Test
    fun unsupportedEncodingConsumesNothingAndDoesNotEmit() {
        val clock = FakeClock()
        val a = analyzer(clock)
        assertFalse(a.append(pcm(fftSize), 0x40000000, 44100, 1))
        assertEquals(0L, a.totalFrames)
    }

    @Test
    fun resetClearsRingAndCounters() {
        val clock = FakeClock()
        val a = analyzer(clock)
        assertTrue(a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 44100, 1))
        a.reset()
        assertEquals(0L, a.totalFrames)
        // 重置后必须重新攒满 fftSize 才出帧
        assertFalse(a.append(pcm(fftSize - 1), PcmEncoding.PCM_16BIT, 44100, 1))
        clock.advance(100)
        assertTrue(a.append(pcm(1), PcmEncoding.PCM_16BIT, 44100, 1))
    }

    @Test
    fun copyRingIntoProducesSnapshotUsableByFft() {
        val clock = FakeClock()
        val a = analyzer(clock, intervalMs = 0L)
        val fft = SpectrumFft(fftSize, bandCount)
        val snapshot = FloatArray(fftSize)
        a.append(pcm(fftSize, amplitude = 32767), PcmEncoding.PCM_16BIT, 44100, 1)
        a.copyRingInto(snapshot)
        val bands = fft.bandsFrom(snapshot)
        assertEquals(bandCount, bands.size)
        for (b in bands) {
            assertTrue("band out of range: $b", b >= 0.0 && b <= 1.0)
        }
    }

    @Test
    fun bandsOfDelegatesToFftWithoutTouchingRing() {
        val clock = FakeClock()
        val a = analyzer(clock, intervalMs = 0L)
        val snapshot = FloatArray(fftSize) { 1000f }
        val bands = a.bandsOf(snapshot)
        assertEquals(bandCount, bands.size)
    }

    @Test
    fun activeFlagStartsFalseAndIsSetByCaller() {
        val a = analyzer(FakeClock())
        assertFalse(a.isActive)
        a.markActive()
        assertTrue(a.isActive)
        a.reset()
        assertFalse(a.isActive)
    }

    @Test
    fun analyzeOfReturnsFreshFrameEachCall() {
        val a = bigAnalyzer()
        val snapshot = FloatArray(1024) { i -> (0.5 * sin(2.0 * PI * 1 * i / 1024)).toFloat() }

        val first = a.analyzeOf(snapshot)
        val second = a.analyzeOf(snapshot)

        // 两个 Frame 的数组必须是不同实例：它们会被 mainHandler.post 异步投递给
        // MethodChannel，复用缓冲会被下一帧覆盖（这是 bandsOf 每帧新分配的同一原因）
        assertNotSame(first.bands, second.bands)
        assertNotSame(first.features, second.features)
        assertEquals(40, first.bands.size)
        assertEquals(SpectrumFeatures.COUNT, first.features.size)
    }

    @Test
    fun analyzeOfBandsMatchBandsOf() {
        val a = bigAnalyzer()
        val snapshot = FloatArray(1024) { i -> (0.7 * sin(2.0 * PI * 11 * i / 1024)).toFloat() }

        val viaAnalyze = a.analyzeOf(snapshot).bands
        val viaBandsOf = a.bandsOf(snapshot)

        assertEquals(viaBandsOf.size, viaAnalyze.size)
        for (i in viaBandsOf.indices) {
            assertEquals(viaBandsOf[i], viaAnalyze[i], 1e-9)
        }
    }

    @Test
    fun analyzeOfFeaturesFollowTheToneBand() {
        val a = bigAnalyzer()
        // bin2 ≈ 86Hz，落在低频带（30–300Hz）
        val low = a.analyzeOf(
            FloatArray(1024) { i -> (0.8 * sin(2.0 * PI * 2 * i / 1024)).toFloat() },
        )
        assertTrue(
            "低频带能量应高于高频带，实际 low=${low.features[SpectrumFeatures.INDEX_LOW]} " +
                "high=${low.features[SpectrumFeatures.INDEX_HIGH]}",
            low.features[SpectrumFeatures.INDEX_LOW] >
                low.features[SpectrumFeatures.INDEX_HIGH],
        )
    }

    @Test
    fun analyzeOfReportsSampleRateToFeatureExtractor() {
        val clock = FakeClock()
        val a = analyzer(clock, intervalMs = 0L)
        // append 会记录采样率，analyzeOf 必须把它传进 SpectrumFeatures
        // ——否则频带表停在默认 44100，48kHz 流的低/高频带会整体偏移
        a.append(pcm(fftSize), PcmEncoding.PCM_16BIT, 48000, 1)
        assertEquals(48000, a.sampleRateHz)

        val frame = a.analyzeOf(FloatArray(fftSize) { 1000f })
        assertEquals(SpectrumFeatures.COUNT, frame.features.size)
        assertTrue("有限帧不得产出 NaN", frame.features.none { it.isNaN() })
    }
}
