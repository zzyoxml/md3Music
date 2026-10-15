package com.md3music.md3music.spectrum

import java.nio.ByteBuffer

/**
 * PCM 频谱分析的状态门面。**渲染线程只允许调 [append] 与 [copyRingInto]**，
 * 其余方法在 FFT 线程或控制线程调用。
 *
 * 状态构成：环形样本缓冲 + 已填充数 + 出帧节流时间戳 + 累计帧数。
 * 不含任何 Android 依赖（时钟由构造注入），因此可 JVM 单测。
 */
internal class SpectrumAnalyzer(
    private val fftSize: Int,
    val bandCount: Int,
    private val minEmitIntervalMs: Long,
    private val clock: () -> Long,
) {
    private val ring = FloatArray(fftSize)
    private val fft = SpectrumFft(fftSize, bandCount)
    private val features = SpectrumFeatures(fftSize, fft.outputBinCount)

    private var writePos = 0
    private var filled = 0
    private var lastEmitMs = -1L

    /**
     * 一帧的分析产物。
     *
     * **[bands] 与 [features] 每次都是新分配的数组** —— 它们会被 `mainHandler.post`
     * 异步投递给 MethodChannel，复用缓冲会被下一帧覆盖。这是既有 `bandsOf`
     * 每帧新分配的同一原因，不要"优化"成复用。
     */
    class Frame(val bands: DoubleArray, val features: FloatArray)

    /** 是否已产出至少一帧（由调用方标记；用于「首帧激活」事件）。 */
    @Volatile
    var isActive: Boolean = false
        private set

    /** 最近一次非零的采样率。 */
    @Volatile
    var sampleRateHz: Int = 44100
        private set

    /** 自上次 [reset] 以来写入的累计帧数（用于「100 帧后硬摘 Visualizer」这类判定）。 */
    @Volatile
    var totalFrames: Long = 0L
        private set

    /** 自上次 [reset] 以来**已产出**的频谱帧数（区别于 [totalFrames] 的采样帧数）。 */
    @Volatile
    var emitCount: Long = 0L
        private set

    fun markActive() {
        isActive = true
    }

    /**
     * 追加一块解码后的 PCM。
     *
     * @return true 表示本次应产出一帧（调用方随后必须立刻 [copyRingInto] 取快照并投递 FFT）。
     *         编码不受支持时返回 false 且不消费任何样本。
     */
    fun append(buffer: ByteBuffer, encoding: Int, sampleRate: Int, channelCount: Int): Boolean {
        if (PcmEncoding.bytesPerSample(encoding) == 0) return false
        if (sampleRate > 0) sampleRateHz = sampleRate

        val result = PcmDecoder.appendLeftChannel(buffer, encoding, channelCount, ring, writePos)
        if (result.frames == 0) return false
        writePos = result.nextWritePos
        // 循环外一次累加，替代旧的「循环内逐样本 ++ 加分支」
        filled = (filled + result.frames).coerceAtMost(fftSize)
        totalFrames += result.frames

        if (filled < fftSize) return false
        val now = clock()
        // lastEmitMs < 0 表示本代还没出过帧：首帧不受节流限制
        if (lastEmitMs >= 0 && now - lastEmitMs < minEmitIntervalMs) return false
        lastEmitMs = now
        emitCount++
        return true
    }

    /** 在渲染线程上把最近 [fftSize] 个样本拷进 [out]（微秒级，无分配）。 */
    fun copyRingInto(out: FloatArray) {
        fft.copyRingInto(ring, writePos, out)
    }

    /** 在 FFT 线程上执行。 */
    fun bandsOf(snapshot: FloatArray): DoubleArray = fft.bandsFrom(snapshot)

    /**
     * 在 FFT 线程上执行：**一次** FFT 同时产出视觉 40 段与节拍特征向量。
     *
     * 分成 `bandsOf` + 单独的特征提取会做两次 FFT —— 1024 点虽便宜，但没有任何理由付两遍。
     * [frame] 每次新分配，可安全跨线程投递。
     */
    fun analyzeOf(snapshot: FloatArray): Frame {
        val mags = fft.magnitudesFrom(snapshot)
        val bands = fft.bandsFromMagnitudes(mags)
        val featureOut = FloatArray(SpectrumFeatures.COUNT)
        features.extract(sampleRateHz, mags, snapshot, featureOut)
        return Frame(bands, featureOut)
    }

    fun reset() {
        writePos = 0
        filled = 0
        lastEmitMs = -1L
        totalFrames = 0L
        emitCount = 0L
        isActive = false
    }
}
