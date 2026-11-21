package com.md3music.md3music.spectrum

import kotlin.math.pow
import kotlin.math.sqrt

/**
 * 从一帧原始 FFT 幅度 + 时域样本提取**紧凑特征向量**，供 Dart 侧做节拍（onset）判定。
 *
 * **为什么不复用 [SpectrumFft.bandsFrom] 的 40 段**：那是「逐帧自归一化 + 线性分箱」，
 * 分母是 `max(1.0, 帧内最大值)` —— 一种非线性、且音量相关的缩放。谱流量依赖帧间幅度的
 * **绝对关系**，被这样处理后动态范围已失真；且它只覆盖前 40 个线性 bin
 * （44.1kHz/1024 下 ≈0–1.7kHz），军鼓与镲的高频瞬态全部丢失。故必须走未归一化的原始幅度。
 *
 * **为什么只送 20 个浮点而不是 512 个原始幅度**：特征在下发前先压成对数频带，
 * 通道流量从 ≈40 KB/s 降到 ≈0.8 KB/s，且不必把大数组搬上主线程。
 *
 * **无状态**：本类不保留任何跨帧状态（不做差分、不维护阈值），因此可在 FFT 线程
 * 上被反复调用而不引入时序耦合。所有时序逻辑（谱流量、自适应阈值、冷却）在 Dart 侧。
 *
 * 纯 Kotlin、零 Android 依赖，可 JVM 单测。
 */
internal class SpectrumFeatures(
    private val fftSize: Int,
    private val binCount: Int,
) {
    companion object {
        /** 对数频带数量，占据特征向量的 [0, LOG_BAND_COUNT)。 */
        const val LOG_BAND_COUNT = 16

        /** 全带 RMS（时域）下标。 */
        const val INDEX_RMS = 16

        /** 低频带（30–300Hz）能量下标 —— kick 判据。 */
        const val INDEX_LOW = 17

        /** 高频带（3k–8kHz）能量下标 —— snare 判据。 */
        const val INDEX_HIGH = 18

        /** 中频带（300Hz–3kHz）能量下标 —— 人声/旋律，本版未参与判定，预留。 */
        const val INDEX_MID = 19

        /** 特征向量总长度。 */
        const val COUNT = 20

        private const val F_MIN = 30.0
        private const val F_MAX = 16000.0
        private const val LOW_LO = 30.0
        private const val LOW_HI = 300.0
        private const val MID_LO = 300.0
        private const val MID_HI = 3000.0
        private const val HIGH_LO = 3000.0
        private const val HIGH_HI = 8000.0

        /** 把频率映射到 [SpectrumFft.magnitudesFrom] 的下标。 */
        internal fun magIndex(hz: Double, hzPerBin: Double, binCount: Int): Int =
            // mags[i] 对应 FFT bin (i+1)，故频率 f 的下标是 f/hzPerBin - 1
            ((hz / hzPerBin).toInt() - 1).coerceIn(0, binCount - 1)
    }

    private var sampleRateHz = 0
    private var hzPerBin = 0.0

    private val logLo = IntArray(LOG_BAND_COUNT)
    private val logHi = IntArray(LOG_BAND_COUNT)
    private var lowLo = 0
    private var lowHi = 1
    private var midLo = 0
    private var midHi = 1
    private var highLo = 0
    private var highHi = 1

    init {
        require(fftSize > 1) { "fftSize must be > 1, got $fftSize" }
        require(binCount > 1) { "binCount must be > 1, got $binCount" }
    }

    /** bin 表只在采样率真的变化时重建（一首歌内通常只发生一次）。 */
    private fun ensureRate(rate: Int) {
        val effective = if (rate > 0) rate else 44100
        if (effective == sampleRateHz) return
        sampleRateHz = effective
        hzPerBin = effective.toDouble() / fftSize

        for (i in 0 until LOG_BAND_COUNT) {
            val lo = F_MIN * (F_MAX / F_MIN).pow(i.toDouble() / LOG_BAND_COUNT)
            val hi = F_MIN * (F_MAX / F_MIN).pow((i + 1).toDouble() / LOG_BAND_COUNT)
            logLo[i] = magIndex(lo, hzPerBin, binCount)
            logHi[i] = maxOf(logLo[i] + 1, magIndex(hi, hzPerBin, binCount))
        }
        // 顶带必须把 F_MAX 边界 bin 收进来：mean 是 [lo, hi) 左闭右开，内部频带的
        // 边界 bin 归上一带/下一带接住，而顶带之上没有频带，magIndex(F_MAX) 那一格
        // 会整体漏掉（44.1kHz/1024 下即 mags[370] ≈ 15978Hz，明明落在 16kHz 以内）。
        logHi[LOG_BAND_COUNT - 1] =
            maxOf(logHi[LOG_BAND_COUNT - 1], magIndex(F_MAX, hzPerBin, binCount) + 1)
        lowLo = magIndex(LOW_LO, hzPerBin, binCount)
        lowHi = maxOf(lowLo + 1, magIndex(LOW_HI, hzPerBin, binCount))
        midLo = magIndex(MID_LO, hzPerBin, binCount)
        midHi = maxOf(midLo + 1, magIndex(MID_HI, hzPerBin, binCount))
        highLo = magIndex(HIGH_LO, hzPerBin, binCount)
        highHi = maxOf(highLo + 1, magIndex(HIGH_HI, hzPerBin, binCount))
    }

    /**
     * 就地写入 [out] 并返回它（长度必须为 [COUNT]）。
     *
     * @param sampleRateHz 本帧的采样率；与上次不同时会重建频带表
     * @param mags [SpectrumFft.magnitudesFrom] 的返回值（未归一化，长度 >= [binCount]）
     * @param samples 同一帧的**未加窗**时域样本 —— RMS 用它算。
     *        加窗会给能量引入一个常数偏置，而 Dart 侧做的是**帧间差分**，
     *        常数偏置会被抵消，故这里直接用原始样本更省一次遍历。
     */
    fun extract(
        sampleRateHz: Int,
        mags: DoubleArray,
        samples: FloatArray,
        out: FloatArray,
    ): FloatArray {
        require(out.size == COUNT) { "out must be $COUNT long, got ${out.size}" }
        ensureRate(sampleRateHz)

        for (i in 0 until LOG_BAND_COUNT) {
            out[i] = mean(mags, logLo[i], logHi[i])
        }

        var sq = 0.0
        for (s in samples) sq += s.toDouble() * s
        out[INDEX_RMS] = sqrt(sq / samples.size).toFloat()

        out[INDEX_LOW] = mean(mags, lowLo, lowHi)
        out[INDEX_MID] = mean(mags, midLo, midHi)
        out[INDEX_HIGH] = mean(mags, highLo, highHi)
        return out
    }

    private fun mean(mags: DoubleArray, lo: Int, hi: Int): Float {
        val start = lo.coerceIn(0, mags.size - 1)
        val end = hi.coerceIn(start + 1, mags.size)
        var sum = 0.0
        for (b in start until end) sum += mags[b]
        return (sum / (end - start)).toFloat()
    }
}
