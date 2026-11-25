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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * 频谱可视化插件：通过 MethodChannel "com.md3music.md3music/spectrum" 控制采集。
 *
 * **数据源（按优先级仲裁）**：
 * 1. **AudioSink PCM 截取（首选）**：从 fork 的 just_audio 拦截解码后的原始 PCM，
 *    直接送入 Rust 频谱分析器（[nativeSpectrumFeedPCM]），Rust 内部完成 Hann 加窗
 *    FFT + 视觉带提取 + 节拍特征提取。帧结果留在 Rust 共享缓冲，Dart 侧通过 FFI
 *    [spectrum_poll_frame] 轮询读取，无需逐帧跨方法通道。
 * 2. **Visualizer（兜底）**：从 AudioFlinger 混音输出采集。仅在前 3 帧做 FFT，
 *    PCM 激活后不再处理。仍走 MethodChannel `onFft` 回调（低频低帧率，开销可忽略）。
 * 3. **模拟模式（最终兜底）**：Dart 侧 1.5s 无 FFT 回调自动降级。
 *
 * **线程纪律**：渲染线程（[handlePcm]）只做 PCM→JNI 投递；FFT 在 Rust 内部分配
 * 专用线程，`Visualizer.release()` 一律丢到 `releaseExecutor`。
 */
class SpectrumPlugin {

    companion object {
        private const val TAG = "SpectrumPlugin"
        private const val CHANNEL_NAME = "com.md3music.md3music/spectrum"
        private const val CAPTURE_RATE = 20_000
        private const val BAND_COUNT = 40
        private const val INIT_TIMEOUT_MS = 4000L

        /** PCM 通路连续产出这么多帧后，再无条件摘一次 Visualizer（防首次摘除漏网）。 */
        private const val HARD_RELEASE_AFTER_FRAMES = 100L

        // ── 延迟加载 libkugou_server.so（与 KugouApiService 共用同一 .so）──
        @Volatile private var spectrumLibLoaded = false

        private fun ensureLibLoaded(): Boolean {
            if (spectrumLibLoaded) return true
            return try {
                System.loadLibrary("kugou_server")
                spectrumLibLoaded = true
                true
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load kugou_server: ${e.message}")
                false
            }
        }
    }

    // ── JNI external 函数声明（符号在 libkugou_server.so 内导出）──

    /**
     * 把一块 PCM 数据追加到 Rust 频谱环形缓冲。节流满足时自动触发 FFT。
     *
     * [state] 是 Dart 侧 `spectrum_init()` 返回的不透明指针，通过 MethodChannel
     * "start" 方法传入。Dart 拥有该状态的生命周期，本方法只引用。
     * Kotlin 侧传入完整 PCM 字节数组（无需 offset/length）。
     */
    private external fun nativeSpectrumFeedPCM(
        state: Long,
        pcm: ByteArray,
        encoding: Int,
        sampleRate: Int,
        channels: Int,
    )

    // ── 状态 ──────────────────────────────────────────────────────

    private val visualizerRef = AtomicReference<Visualizer?>(null)
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var fftCallbackCount = 0
    @Volatile private var waveCallbackCount = 0

    // ── PCM 频谱捕获状态 ────────────────────────────────────────

    @Volatile private var pcmCaptureEnabled = false
    @Volatile private var captureGeneration = 0
    @Volatile private var pcmActive = false
    @Volatile private var hardReleased = false

    // Dart 侧通过 spectrum_init() 创建并通过 MethodChannel 传入的 opaque 指针。
    @Volatile private var spectrumState: Long = 0L

    // ── 投递链路计数 ──────────────────────────────────────────

    @Volatile private var fedFrames = 0L      // 成功投递到 Rust 的 PCM 块数
    @Volatile private var deliveredFrames = 0L // Visualizer 路径发往 Dart 的帧数（旧路径统计）
    @Volatile private var cleanedUp = false

    /** Visualizer 释放专用线程。 */
    private val releaseExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "SpectrumVizRelease").apply { isDaemon = true }
    }

    private val pcmCaptureListener = UsbAudioSinkController.PcmCaptureListener { buffer, encoding, sampleRate, channelCount ->
        handlePcm(buffer, encoding, sampleRate, channelCount)
    }

    fun register(flutterEngine: FlutterEngine) {
        ensureLibLoaded()
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("audioSessionId") ?: 0
                    val visualizerFallback = call.argument<Boolean>("visualizerFallback") ?: true
                    // Dart 侧已通过 FFI 创建 spectrum_state 并通过 start 参数传入
                    val statePtr = call.argument<Long>("statePtr") ?: 0L
                    startVisualizer(sessionId, visualizerFallback, statePtr, result)
                }
                "stop" -> {
                    stopAll()
                    result.success(true)
                }
                "stats" -> result.success(
                    mapOf(
                        "generation" to captureGeneration,
                        "pcmCaptureEnabled" to pcmCaptureEnabled,
                        "pcmActive" to pcmActive,
                        "fedFrames" to fedFrames,
                        "delivered" to deliveredFrames,
                        "fftCallbacks" to fftCallbackCount,
                        "cleanedUp" to cleanedUp,
                    )
                )
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

    private fun startVisualizer(
        audioSessionId: Int,
        visualizerFallback: Boolean,
        statePtr: Long,
        result: MethodChannel.Result,
    ) {
        val generation = ++captureGeneration
        stopVisualizer()

        // 更新状态指针（Dart 侧在每次 start 时可能重建 state）
        spectrumState = statePtr

        fftCallbackCount = 0
        waveCallbackCount = 0

        // 首选数据源：注册 PCM 截取监听（无论 Visualizer 成败都会激活）
        pcmCaptureEnabled = true
        pcmActive = false
        hardReleased = false
        fedFrames = 0L
        deliveredFrames = 0L
        UsbAudioSinkController.setPcmCaptureListener(pcmCaptureListener)

        Thread {
            if (!visualizerFallback) {
                // 兜底被关：只留 AudioSink PCM 通路，绝不挂 Visualizer
                mainHandler.post {
                    val ok = generation == captureGeneration && pcmCaptureEnabled
                    if (ok) RingLog.i(TAG, "Visualizer mount requested: enabled=false (PCM only)")
                    result.success(ok)
                }
                return@Thread
            }
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
                        if (waveform == null || generation != captureGeneration || !pcmCaptureEnabled) return
                        waveCallbackCount++
                        if (waveCallbackCount % 100 == 1) {
                            Log.i(TAG, "Waveform callback #$waveCallbackCount, size=${waveform.size}")
                        }
                        if (pcmActive) return
                        if (fftCallbackCount < 3) {
                            val bands = computeBandsFromWaveform(waveform)
                            mainHandler.post {
                                if (generation == captureGeneration && pcmCaptureEnabled && !pcmActive) {
                                    deliveredFrames++
                                    channel?.invokeMethod("onFft", bands)
                                }
                            }
                        }
                    }

                    override fun onFftDataCapture(
                        visualizer: Visualizer?,
                        fft: ByteArray?,
                        samplingRate: Int,
                    ) {
                        if (fft == null || generation != captureGeneration || !pcmCaptureEnabled) return
                        fftCallbackCount++
                        if (fftCallbackCount % 100 == 1) {
                            Log.i(TAG, "FFT callback #$fftCallbackCount, fft.size=${fft.size}")
                        }
                        if (pcmActive) return
                        val bands = computeBands(fft)
                        mainHandler.post {
                            if (generation == captureGeneration && pcmCaptureEnabled && !pcmActive) {
                                deliveredFrames++
                                channel?.invokeMethod("onFft", bands)
                            }
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
                if (generation != captureGeneration || !pcmCaptureEnabled) {
                    finalViz?.let { releaseVisualizerAsync(it) }
                    result.success(false)
                    return@post
                }
                if (finalError != null) {
                    Log.e(TAG, "Visualizer start failed", finalError)
                    result.success(pcmActive)
                } else if (finalViz == null) {
                    result.error("START_FAILED", "Visualizer 创建返回 null", null)
                } else {
                    if (pcmActive) {
                        releaseVisualizerAsync(finalViz)
                    } else {
                        visualizerRef.set(finalViz)
                    }
                    result.success(true)
                }
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    // ── PCM 截取 → Rust FFT ────────────────────────────────────

    /**
     * 跑在 ExoPlayer 渲染线程（由 [UsbAudioSinkController.handleBuffer] 调用）。
     *
     * 把原始 PCM 字节通过 JNI 投递给 Rust，Rust 内部完成解码 + FFT。
     * **渲染线程只做一次 JNI 字节拷贝**：绝不做 Binder 调用、绝不做 FFT。
     */
    private fun handlePcm(buffer: ByteBuffer, encoding: Int, sampleRate: Int, channelCount: Int) {
        if (!pcmCaptureEnabled || channel == null) return
        if (spectrumState == 0L) return

        // 从 ByteBuffer 提取字节数组（heap 或 direct 均安全，拷贝后不持有引用）
        val length = buffer.remaining()
        if (length <= 0) return
        val bytes = ByteArray(length)
        buffer.get(bytes)

        // JNI 投递给 Rust 频谱分析器（渲染线程安全：JNI 仅做字节拷贝，FFT 在 Rust 内部分配）
        try {
            nativeSpectrumFeedPCM(spectrumState, bytes, encoding, sampleRate, channelCount)
        } catch (_: Throwable) {
            return
        }
        fedFrames++

        // 首帧激活：摘掉 Visualizer。释放走后台线程，绝不在渲染线程做 Binder。
        if (!pcmActive) {
            pcmActive = true
            RingLog.i(TAG, "PCM capture active (rate=${sampleRate}Hz) — disabling Visualizer data")
            stopVisualizer()
        }
        // 双保险：PCM 连续产出 HARD_RELEASE_AFTER_FRAMES 次后再无条件摘一次
        if (!hardReleased && fedFrames >= HARD_RELEASE_AFTER_FRAMES) {
            hardReleased = true
            RingLog.i(TAG, "VIZ hard-release after $fedFrames PCM feeds")
            stopVisualizer()
        }
    }

    private fun stopAll() {
        ++captureGeneration
        pcmCaptureEnabled = false
        pcmActive = false
        hardReleased = false
        fedFrames = 0L
        deliveredFrames = 0L
        UsbAudioSinkController.setPcmCaptureListener(null)
        stopVisualizer()
    }

    /// 从 FFT 字节数组计算前 [BAND_COUNT] 段幅值（归一化到 0..1）。仅 Visualizer 路径使用。
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
    /// 仅 Visualizer 路径使用。
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
        for (i in 0 until BAND_COUNT) {
            bands[i] = (mags[i] / maxMag).coerceIn(0.0, 1.0)
        }
        return bands
    }

    /**
     * 摘掉 Visualizer。**永不阻塞调用线程**。
     */
    private fun stopVisualizer() {
        val v = visualizerRef.getAndSet(null) ?: return
        releaseVisualizerAsync(v)
    }

    private fun releaseVisualizerAsync(v: Visualizer) {
        try {
            releaseExecutor.execute { releaseVisualizer(v) }
        } catch (_: RuntimeException) {
            releaseVisualizer(v)
        }
    }

    private fun releaseVisualizer(v: Visualizer) {
        try {
            v.enabled = false
            v.release()
            RingLog.i(TAG, "Visualizer released, FFT callbacks: $fftCallbackCount, waveform callbacks: $waveCallbackCount")
        } catch (e: Exception) {
            Log.e(TAG, "stop failed", e)
        }
    }

    /** 引擎重建 / Activity 销毁时调用（MainActivity.registerPlaybackPlugins 已接线）。 */
    fun cleanup() {
        cleanedUp = true
        stopAll()
        releaseExecutor.shutdown()
    }
}