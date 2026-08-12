package com.md3music.premium

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicReference

/**
 * 频谱可视化插件：通过 MethodChannel "com.md3music.premium/spectrum" 暴露 Android 原生 Visualizer。
 *
 * **HyperOS/MIUI 兼容策略**：
 * 1. 绑定到 just_audio 的实际 audioSessionId（非 0），因为 Visualizer(0) 在 HyperOS 上返回 error -3
 * 2. 同时启用 waveform + FFT 捕获：某些 ROM 不回调 FFT 但回调 waveform
 * 3. 如果 FFT 有数据则用 FFT，否则用 waveform 振幅做频谱可视化
 *
 * 回调约 20fps（captureRate=20000Hz, captureSize=1024 → 20000/1024≈19.5 次/秒）。
 */
class SpectrumPlugin {

    companion object {
        private const val TAG = "SpectrumPlugin"
        private const val CHANNEL_NAME = "com.md3music.premium/spectrum"
        private const val CAPTURE_RATE = 20_000
        private const val BAND_COUNT = 40
        private const val INIT_TIMEOUT_MS = 4000L
    }

    private val visualizerRef = AtomicReference<Visualizer?>(null)
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var fftCallbackCount = 0
    @Volatile private var waveCallbackCount = 0

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("audioSessionId") ?: 0
                    startVisualizer(sessionId, result)
                }
                "stop" -> {
                    stopVisualizer()
                    result.success(true)
                }
                "isSupported" -> {
                    result.success(checkSupported())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun checkSupported(): Boolean {
        return try {
            val v = Visualizer(0)
            v.release()
            true
        } catch (_: Throwable) {
            false
        }
    }

    /// 在子线程创建 Visualizer 并注册回调。
    /// 先尝试 sessionId=0（全局 mix），失败则回退到传入的 sessionId。
    private fun startVisualizer(audioSessionId: Int, result: MethodChannel.Result) {
        stopVisualizer()
        fftCallbackCount = 0
        waveCallbackCount = 0

        Thread {
            var error: Exception? = null
            var viz: Visualizer? = null

            try {
                // 先尝试绑定到传入的 sessionId（just_audio 的实际会话）
                // HyperOS 上 Visualizer(0) 返回 error -3，但特定 session 可能成功
                val v = try {
                    Log.i(TAG, "Trying Visualizer(sessionId=$audioSessionId)")
                    Visualizer(audioSessionId)
                } catch (e: Exception) {
                    Log.w(TAG, "Visualizer($audioSessionId) failed: ${e.message}, trying Visualizer(0)")
                    // 回退到全局 mix
                    Visualizer(0)
                }

                val range = Visualizer.getCaptureSizeRange()
                val captureSize = if (range != null && range.size >= 2) {
                    range[1].coerceAtMost(1024)
                } else {
                    1024
                }
                v.captureSize = captureSize
                Log.i(TAG, "Visualizer created: captureSize=$captureSize, rate=$CAPTURE_RATE")

                // 同时启用 waveform 和 FFT 捕获（参数：rate, waveform=true, fft=true）
                // 某些 ROM 只回调其中一种，两种都启用提高兼容性
                v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        visualizer: Visualizer?,
                        waveform: ByteArray?,
                        samplingRate: Int,
                    ) {
                        if (waveform == null) return
                        waveCallbackCount++
                        if (waveCallbackCount % 100 == 1) {
                            Log.i(TAG, "Waveform callback #$waveCallbackCount, size=${waveform.size}")
                        }
                        // 如果 FFT 回调很少（<3 次），用 waveform 做振幅可视化
                        if (fftCallbackCount < 3) {
                            val bands = computeBandsFromWaveform(waveform)
                            mainHandler.post {
                                channel?.invokeMethod("onFft", bands)
                            }
                        }
                    }

                    override fun onFftDataCapture(
                        visualizer: Visualizer?,
                        fft: ByteArray?,
                        samplingRate: Int,
                    ) {
                        if (fft == null) return
                        fftCallbackCount++
                        if (fftCallbackCount % 100 == 1) {
                            Log.i(TAG, "FFT callback #$fftCallbackCount, fft.size=${fft.size}")
                        }
                        val bands = computeBands(fft)
                        mainHandler.post {
                            channel?.invokeMethod("onFft", bands)
                        }
                    }
                }, CAPTURE_RATE, true, true) // waveform=true, fft=true
                v.enabled = true
                Log.i(TAG, "Visualizer enabled successfully")
                viz = v
            } catch (e: Exception) {
                error = e
            }

            val finalViz = viz
            val finalError = error
            mainHandler.post {
                if (finalError != null) {
                    Log.e(TAG, "Visualizer start failed", finalError)
                    result.error("START_FAILED", finalError.message, null)
                } else if (finalViz == null) {
                    result.error("START_FAILED", "Visualizer 创建返回 null", null)
                } else {
                    visualizerRef.set(finalViz)
                    result.success(true)
                }
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    /// 从 FFT 字节数组计算前 [BAND_COUNT] 段幅值（归一化到 0..1）。
    private fun computeBands(fft: ByteArray): DoubleArray {
        val bands = DoubleArray(BAND_COUNT)
        val pairCount = (fft.size - 2) / 2
        val usablePairs = if (pairCount < BAND_COUNT) pairCount else BAND_COUNT
        var maxMag = 1.0
        val mags = DoubleArray(BAND_COUNT)
        for (i in 0 until usablePairs) {
            val re = fft[2 + i * 2].toDouble()
            val im = fft[2 + i * 2 + 1].toDouble()
            val mag = Math.sqrt(re * re + im * im)
            mags[i] = mag
            if (mag > maxMag) maxMag = mag
        }
        for (i in 0 until BAND_COUNT) {
            bands[i] = if (i < usablePairs) (mags[i] / maxMag) else 0.0
        }
        return bands
    }

    /// 从 waveform（时域 PCM 采样）计算 [BAND_COUNT] 段振幅（归一化到 0..1）。
    /// waveform 是 8-bit signed PCM（-128..127），分桶取每段最大绝对值。
    /// 视觉效果不如 FFT 频谱准确，但能反映音频电平变化。
    private fun computeBandsFromWaveform(waveform: ByteArray): DoubleArray {
        val bands = DoubleArray(BAND_COUNT)
        val samplesPerBand = waveform.size / BAND_COUNT
        if (samplesPerBand <= 0) return bands
        var maxMag = 1.0
        val mags = DoubleArray(BAND_COUNT)
        for (i in 0 until BAND_COUNT) {
            val start = i * samplesPerBand
            val end = if (i == BAND_COUNT - 1) waveform.size else start + samplesPerBand
            var max = 0.0
            for (j in start until end) {
                val v = Math.abs(waveform[j].toDouble())
                if (v > max) max = v
            }
            mags[i] = max
            if (max > maxMag) maxMag = max
        }
        // 归一化到 0..1（128 为 8-bit 最大幅值）
        for (i in 0 until BAND_COUNT) {
            bands[i] = (mags[i] / maxMag).coerceIn(0.0, 1.0)
        }
        return bands
    }

    private fun stopVisualizer() {
        try {
            visualizerRef.getAndSet(null)?.let { v ->
                v.enabled = false
                v.release()
                Log.i(TAG, "Visualizer released, FFT callbacks: $fftCallbackCount, waveform callbacks: $waveCallbackCount")
            }
        } catch (e: Exception) {
            Log.e(TAG, "stop failed", e)
        }
    }

    fun cleanup() {
        stopVisualizer()
    }
}
