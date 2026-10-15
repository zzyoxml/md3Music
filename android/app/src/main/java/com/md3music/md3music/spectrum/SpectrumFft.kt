package com.md3music.md3music.spectrum

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 基 2 迭代 FFT + Hann 窗 + 幅度分段归一化。
 *
 * 与 Visualizer 路径的 `computeBands` 视觉对齐：跳过 DC，从 bin1 开始取，
 * 以本帧最大幅度做归一化（自归一化，音量大小不影响柱高比例）。
 * FFT 前套 Hann 窗抑制频谱泄漏——否则强低频能量会糊满全频段。
 *
 * 旋转因子表与窗函数表都在构造时算好 —— 旧实现每个蝶形都做 4 次浮点乘加递推，
 * 既慢又累积误差。
 */
internal class SpectrumFft(
    private val fftSize: Int,
    private val bandCount: Int,
) {
    init {
        require(fftSize > 1 && (fftSize and (fftSize - 1)) == 0) {
            "fftSize must be a power of two, got $fftSize"
        }
        require(bandCount > 0) { "bandCount must be positive, got $bandCount" }
    }

    /** 可用的幅度 bin 数（跳过 DC）。 */
    val outputBinCount: Int = fftSize / 2

    private val real = FloatArray(fftSize)
    private val imag = FloatArray(fftSize)
    private val twiddleRe = FloatArray(fftSize / 2)
    private val twiddleIm = FloatArray(fftSize / 2)
    private val mags = DoubleArray(outputBinCount)

    init {
        for (i in 0 until fftSize / 2) {
            val angle = -2.0 * PI * i / fftSize
            twiddleRe[i] = cos(angle).toFloat()
            twiddleIm[i] = sin(angle).toFloat()
        }
    }

    /** 从环形缓冲读最近 [fftSize] 个样本到 [out]。必须在本线程完成（ring 会被后续块改写）。 */
    fun copyRingInto(ring: FloatArray, startPos: Int, out: FloatArray) {
        val size = ring.size
        var src = startPos
        for (i in 0 until fftSize) {
            out[i] = ring[src]
            src++
            if (src == size) src = 0
        }
    }

    /** Hann 窗系数表：`0.5 * (1 - cos(2πn/(N-1)))`。构造时算好，避免每帧重复三角函数。 */
    private val hann = FloatArray(fftSize) { i ->
        (0.5 * (1.0 - cos(2.0 * PI * i / (fftSize - 1)))).toFloat()
    }

    /** 加窗后的时域副本：避免就地修改调用方的快照（快照可能要被复用）。 */
    private val windowed = FloatArray(fftSize)

    /**
     * 加窗 + FFT，返回**未归一化**的原始幅度（长度 [outputBinCount]，跳过 DC）。
     *
     * 返回的是**内部复用缓冲**：只在下次调用本方法前有效，调用方必须先消费完
     * 或自行 `copyOf()`。这不是疏忽——渲染线程每帧拷贝 1024 个样本 + 20fps 的
     * 节奏下，每帧多分配一个 4KB 数组会持续制造 GC 压力。
     *
     * 加窗是本方法与 [bandsFrom] 的**唯一**行为差异来源：不加窗时强低频能量会
     * 泄漏到全频段，把瞬态抹平（对柱状图无所谓，对 onset 检测是致命的）。
     */
    fun magnitudesFrom(samples: FloatArray): DoubleArray {
        require(samples.size == fftSize) {
            "expected $fftSize samples, got ${samples.size}"
        }
        for (i in 0 until fftSize) windowed[i] = samples[i] * hann[i]
        System.arraycopy(windowed, 0, real, 0, fftSize)
        java.util.Arrays.fill(imag, 0f)
        transform()

        for (i in 0 until outputBinCount) {
            // bin i+1：跳过 DC
            val re = real[i + 1].toDouble()
            val im = imag[i + 1].toDouble()
            mags[i] = sqrt(re * re + im * im)
        }
        return mags
    }

    /**
     * 视觉用：从 [magnitudesFrom] 的原始幅度算出 [bandCount] 个归一化到 0..1 的段。
     *
     * 归一化公式与改造前**逐字一致**（分母 `max(1.0, 帧内最大值)`），以保持频谱
     * 柱状图的既有观感；变的只有「FFT 前多了一次加窗」。
     *
     * @param raw 必须是 [magnitudesFrom] 刚返回的那个数组
     */
    fun bandsFromMagnitudes(raw: DoubleArray): DoubleArray {
        var maxMag = 1.0
        for (i in 0 until outputBinCount) {
            if (raw[i] > maxMag) maxMag = raw[i]
        }
        val bands = DoubleArray(bandCount)
        for (i in 0 until bandCount) {
            bands[i] = if (i < outputBinCount) {
                (raw[i] / maxMag).coerceIn(0.0, 1.0)
            } else {
                0.0
            }
        }
        return bands
    }

    /** 输入长度必须是 [fftSize]。返回 [bandCount] 个归一化到 0..1 的幅度。 */
    fun bandsFrom(samples: FloatArray): DoubleArray =
        bandsFromMagnitudes(magnitudesFrom(samples))

    /** 原地基 2 迭代 FFT（位反转 + 蝶形）。 */
    private fun transform() {
        val n = fftSize
        var j = 0
        for (i in 0 until n - 1) {
            if (i < j) {
                var t = real[i]; real[i] = real[j]; real[j] = t
                t = imag[i]; imag[i] = imag[j]; imag[j] = t
            }
            var m = n shr 1
            while (j >= m) {
                j -= m
                m = m shr 1
            }
            j += m
        }

        var len = 2
        while (len <= n) {
            val half = len / 2
            val step = n / len
            var i = 0
            while (i < n) {
                var k = 0
                var tw = 0
                while (k < half) {
                    val wr = twiddleRe[tw]
                    val wi = twiddleIm[tw]
                    val lo = i + k
                    val hi = lo + half
                    val vr = real[hi] * wr - imag[hi] * wi
                    val vi = real[hi] * wi + imag[hi] * wr
                    real[hi] = real[lo] - vr
                    imag[hi] = imag[lo] - vi
                    real[lo] += vr
                    imag[lo] += vi
                    k++
                    tw += step
                }
                i += len
            }
            len = len shl 1
        }
    }
}
