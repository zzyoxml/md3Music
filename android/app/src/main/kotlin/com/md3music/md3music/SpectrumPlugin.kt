package com.md3music.md3music

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.ryanheise.just_audio.UsbAudioSinkController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicReference

/**
 * 频谱可视化插件：通过 MethodChannel "com.md3music.md3music/spectrum" 暴露音频频谱数据。
 *
 * **数据源（按优先级仲裁）**：
 * 1. **AudioSink PCM 截取（首选）**：从 fork 的 just_audio 拦截解码后的原始 PCM，
 *    自己算 FFT。数据在 AudioFlinger 混音之前，不受系统媒体音量影响 —— 静音播放
 *    时频谱依然真实跳动（[UsbAudioSinkController.PcmCaptureListener]）。
 * 2. **Visualizer（兜底）**：从 AudioFlinger 混音输出采集。静音时无数据，
 *    仅用于 PCM 截取不可用（如非 just_audio 播放路径）的场合。
 * 3. **模拟模式（最终兜底）**：Dart 侧 1.5s 无 FFT 回调自动降级。
 *
 * 仲裁规则：PCM 数据一旦到达（pcmActive=true），立即停掉 Visualizer 并丢弃其回调。
 *
 * 回调约 20fps：PCM 路径 HOP=1024、节流 45ms；Visualizer 路径 captureRate=20000Hz。
 */
class SpectrumPlugin {

    companion object {
        private const val TAG = "SpectrumPlugin"
        private const val CHANNEL_NAME = "com.md3music.md3music/spectrum"
        private const val CAPTURE_RATE = 20_000
        private const val BAND_COUNT = 40
        private const val INIT_TIMEOUT_MS = 4000L

        // ── PCM FFT 参数 ──
        private const val FFT_SIZE = 1024
        private const val MIN_EMIT_INTERVAL_MS = 45L

        // ── Media3 C 编码常量（app 模块无 media3 依赖，硬编码对齐） ──
        private const val PCM_16BIT = 2
        private const val PCM_24BIT = 0x40000000
        private const val PCM_32BIT = Int.MIN_VALUE // 0x80000000
        private const val PCM_FLOAT = 4
    }

    private val visualizerRef = AtomicReference<Visualizer?>(null)
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var fftCallbackCount = 0
    @Volatile private var waveCallbackCount = 0

    // ── PCM 频谱捕获状态 ──
    @Volatile private var pcmCaptureEnabled = false
    @Volatile private var pcmActive = false
    private val pcmSamples = FloatArray(FFT_SIZE)
    private var pcmWritePos = 0
    private var pcmFilled = 0
    private var pcmSampleRate = 44100
    private var lastPcmEmitMs = 0L
    // FFT 工作缓冲（复用，避免每帧分配）
    private val fftReal = FloatArray(FFT_SIZE)
    private val fftImag = FloatArray(FFT_SIZE)

    private val pcmCaptureListener = UsbAudioSinkController.PcmCaptureListener { buffer, encoding, sampleRate, channelCount ->
        handlePcm(buffer, encoding, sampleRate, channelCount)
    }

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("audioSessionId") ?: 0
                    startVisualizer(sessionId, result)
                }
                "stop" -> {
                    stopAll()
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

    private fun startVisualizer(audioSessionId: Int, result: MethodChannel.Result) {
        stopVisualizer()
        fftCallbackCount = 0
        waveCallbackCount = 0

        // 首选数据源：注册 PCM 截取监听（无论 Visualizer 成败都会激活）
        pcmActive = false
        pcmFilled = 0
        pcmCaptureEnabled = true
        UsbAudioSinkController.setPcmCaptureListener(pcmCaptureListener)

        Thread {
            var error: Exception? = null
            var viz: Visualizer? = null

            try {
                val v = try {
                    Log.i(TAG, "Trying Visualizer(sessionId=$audioSessionId)")
                    Visualizer(audioSessionId)
                } catch (e: Exception) {
                    Log.w(TAG, "Visualizer($audioSessionId) failed: ${e.message}, trying Visualizer(0)")
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
                        // PCM 数据已接管时不处理 Visualizer 数据
                        if (pcmActive) return
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
                        // PCM 数据已接管时不处理 Visualizer 数据
                        if (pcmActive) return
                        val bands = computeBands(fft)
                        mainHandler.post {
                            channel?.invokeMethod("onFft", bands)
                        }
                    }
                }, CAPTURE_RATE, true, true)
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
                    // Visualizer 失败不阻断：PCM 截取已注册，可能仍有数据
                    result.success(pcmActive)
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

    // ── PCM 截取 → FFT ──────────────────────────────────────────────

    private fun handlePcm(buffer: ByteBuffer, encoding: Int, sampleRate: Int, channelCount: Int) {
        if (!pcmCaptureEnabled || channel == null) return
        if (sampleRate > 0) pcmSampleRate = sampleRate
        val bytesPerSample = when (encoding) {
            PCM_16BIT -> 2
            PCM_24BIT -> 3
            PCM_32BIT -> 4
            PCM_FLOAT -> 4
            else -> return
        }
        val frameBytes = bytesPerSample * (if (channelCount > 0) channelCount else 1)
        if (frameBytes <= 0) return

        val pos = buffer.position()
        val limit = buffer.limit()
        val frames = (limit - pos) / frameBytes
        val isFloat = encoding == PCM_FLOAT
        buffer.order(ByteOrder.LITTLE_ENDIAN)

        // 只取左声道样本写入环形缓冲
        for (f in 0 until frames) {
            val base = pos + f * frameBytes
            val v = when {
                isFloat -> {
                    val fv = buffer.getFloat(base)
                    if (fv.isNaN() || fv.isInfinite()) 0f else fv
                }
                bytesPerSample == 2 -> (buffer.getShort(base).toFloat()) / 32768f
                bytesPerSample == 3 -> {
                    // 24bit 有符号 LE
                    val b0 = buffer.get(base).toInt() and 0xFF
                    val b1 = buffer.get(base + 1).toInt() and 0xFF
                    val b2 = buffer.get(base + 2).toInt()
                    val v = (b0 or (b1 shl 8) or (b2 shl 16))
                    (v.toFloat()) / 8388608f
                }
                else -> (buffer.getInt(base).toFloat()) / 2147483648f
            }
            pcmSamples[pcmWritePos] = v
            pcmWritePos = (pcmWritePos + 1) % FFT_SIZE
            if (pcmFilled < FFT_SIZE) pcmFilled++
        }

        // 攒够一帧且距上次发送超过节流间隔 → 做 FFT 并发送
        val now = SystemClock.elapsedRealtime()
        if (pcmFilled >= FFT_SIZE && now - lastPcmEmitMs >= MIN_EMIT_INTERVAL_MS) {
            lastPcmEmitMs = now
            if (!pcmActive) {
                pcmActive = true
                Log.i(TAG, "PCM capture active (rate=${pcmSampleRate}Hz) — disabling Visualizer data")
                stopVisualizer()
            }
            val bands = computeBandsFromPcm()
            // invokeMethod 被标记 @UiThread，必须切到主线程（handlePcm 跑在 ExoPlayer 渲染线程）
            mainHandler.post {
                channel?.invokeMethod("onFft", bands)
            }
            pcmFilled -= FFT_SIZE
        }
    }

    /// 从最近 FFT_SIZE 个 PCM 样本做 FFT，取前 BAND_COUNT 个 bin 归一化到 0..1。
    /// 与 Visualizer 的 computeBands 视觉对齐（跳过 DC，从 bin1 开始）。
    private fun computeBandsFromPcm(): DoubleArray {
        val bands = DoubleArray(BAND_COUNT)
        // 从环形缓冲读最近 FFT_SIZE 个样本（窗口起点 = 当前写位置，因写满一圈）
        val start = pcmWritePos
        val real = fftReal
        val imag = fftImag
        for (i in 0 until FFT_SIZE) {
            real[i] = pcmSamples[(start + i) % FFT_SIZE]
            imag[i] = 0f
        }
        fftRadix2(real, imag)

        val usable = minOf(FFT_SIZE / 2, BAND_COUNT)
        var maxMag = 1.0
        val mags = DoubleArray(usable)
        for (i in 0 until usable) {
            // bin i+1（跳过 DC）
            val re = real[i + 1].toDouble()
            val im = imag[i + 1].toDouble()
            val mag = Math.sqrt(re * re + im * im)
            mags[i] = mag
            if (mag > maxMag) maxMag = mag
        }
        for (i in 0 until BAND_COUNT) {
            bands[i] = if (i < usable) (mags[i] / maxMag).coerceIn(0.0, 1.0) else 0.0
        }
        return bands
    }

    /// 原地基 2 迭代 FFT（长度必须为 2 的幂）。
    private fun fftRadix2(re: FloatArray, im: FloatArray) {
        val n = re.size
        // 位反转
        var j = 0
        for (i in 0 until n - 1) {
            if (i < j) {
                var t = re[i]; re[i] = re[j]; re[j] = t
                t = im[i]; im[i] = im[j]; im[j] = t
            }
            var m = n shr 1
            while (j >= m) { j -= m; m = m shr 1 }
            j += m
        }
        // 蝶形运算
        var len = 2
        while (len <= n) {
            val ang = -2.0 * Math.PI / len
            val wRe = Math.cos(ang).toFloat()
            val wIm = Math.sin(ang).toFloat()
            var i = 0
            while (i < n) {
                var curRe = 1f
                var curIm = 0f
                val half = len / 2
                for (k in 0 until half) {
                    val uRe = re[i + k]
                    val uIm = im[i + k]
                    val vRe = re[i + k + half] * curRe - im[i + k + half] * curIm
                    val vIm = re[i + k + half] * curIm + im[i + k + half] * curRe
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + half] = uRe - vRe
                    im[i + k + half] = uIm - vIm
                    // 更新旋转因子
                    val nRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nRe
                }
                i += len
            }
            len = len shl 1
        }
    }

    private fun stopAll() {
        pcmCaptureEnabled = false
        pcmActive = false
        pcmFilled = 0
        UsbAudioSinkController.setPcmCaptureListener(null)
        stopVisualizer()
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
        stopAll()
    }
}
