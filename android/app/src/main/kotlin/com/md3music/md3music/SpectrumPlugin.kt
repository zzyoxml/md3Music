package com.md3music.md3music

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.md3music.md3music.spectrum.FftPump
import com.md3music.md3music.spectrum.PcmEncoding
import com.md3music.md3music.spectrum.SpectrumAnalyzer
import com.md3music.md3music.spectrum.SpectrumFeatures
import com.ryanheise.just_audio.UsbAudioSinkController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
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
 *
 * **线程纪律**：解码 / 环形缓冲 / 节流由 `spectrum` 包下的 [SpectrumAnalyzer] 承担，
 * FFT 走 [FftPump] 专用线程（忙时丢帧），`Visualizer.release()` 一律丢到
 * `releaseExecutor`。渲染线程（[handlePcm]）只做样本拷贝。
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

        // stride = 窗长（23ms @44.1kHz）：相邻帧连续覆盖无空隙，发射量化 ±11ms。
        // 旧值 45 会让窗口间 22ms 的样本从未被分析，且真峰/上升沿延迟多抖一倍。
        private const val MIN_EMIT_INTERVAL_MS = 23L

        /** PCM 通路连续产出这么多帧后，再无条件摘一次 Visualizer（防首次摘除漏网）。 */
        private const val HARD_RELEASE_AFTER_FRAMES = 100L
    }

    private val visualizerRef = AtomicReference<Visualizer?>(null)
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var fftCallbackCount = 0
    @Volatile private var waveCallbackCount = 0

    // ── PCM 频谱捕获状态 ──
    @Volatile private var pcmCaptureEnabled = false
    @Volatile private var captureGeneration = 0
    @Volatile private var pcmActive = false
    @Volatile private var hardReleased = false

    // ── 投递链路计数（渲染线程/FFT线程/主线程各只有一个写入方，@Volatile 即可）──
    @Volatile private var submittedFrames = 0L   // 成功入队 FftPump 的帧数
    @Volatile private var analyzedFrames = 0L    // FFT worker 实际算完的帧数
    @Volatile private var deliveredFrames = 0L   // 在主线程通过代际门控、发往 Dart 的帧数
    @Volatile private var cleanedUp = false      // 本实例是否已被 cleanup（僵尸检测用）

    private val analyzer = SpectrumAnalyzer(
        fftSize = FFT_SIZE,
        bandCount = BAND_COUNT,
        minEmitIntervalMs = MIN_EMIT_INTERVAL_MS,
        clock = { SystemClock.elapsedRealtime() },
    )

    /** FFT 专用线程：渲染线程只投递，忙时丢帧。 */
    private val fftPump = FftPump()

    /**
     * Visualizer 释放专用线程。
     * `Visualizer.release()` 是同步 Binder，可能阻塞数十毫秒。历史实现在两处调用它：
     * 一处是渲染线程（PCM 首帧停采集），一处是主线程（dispose → stopAll）。
     * 两处都会直接造成音频欠载 / UI 卡顿，所以统一丢到这个线程。
     */
    private val releaseExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "SpectrumVizRelease").apply { isDaemon = true }
    }

    /** 渲染线程每帧复用的快照缓冲（只有 FFT 任务空闲时才会被重写）。 */
    private val fftSnapshot = FloatArray(FFT_SIZE)

    private val pcmCaptureListener = UsbAudioSinkController.PcmCaptureListener { buffer, encoding, sampleRate, channelCount ->
        handlePcm(buffer, encoding, sampleRate, channelCount)
    }

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("audioSessionId") ?: 0
                    // 缺省 true：老 Dart 端不传该参数时行为与改动前一致
                    val visualizerFallback = call.argument<Boolean>("visualizerFallback") ?: true
                    startVisualizer(sessionId, visualizerFallback, result)
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
                        "totalFrames" to analyzer.totalFrames,
                        "emitCount" to analyzer.emitCount,
                        "submitted" to submittedFrames,
                        "analyzed" to analyzedFrames,
                        "delivered" to deliveredFrames,
                        "pumpStopped" to fftPump.isShutdown,
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
        result: MethodChannel.Result,
    ) {
        val generation = ++captureGeneration
        stopVisualizer()
        if (fftPump.ensureAlive()) {
            RingLog.w(TAG, "FFT pump revived (stale instance re-started; check engine re-registration)")
        }
        fftCallbackCount = 0
        waveCallbackCount = 0

        // 首选数据源：注册 PCM 截取监听（无论 Visualizer 成败都会激活）
        pcmCaptureEnabled = true
        pcmActive = false
        hardReleased = false
        analyzer.reset()
        UsbAudioSinkController.setPcmCaptureListener(pcmCaptureListener)

        Thread {
            if (!visualizerFallback) {
                // 兜底被关：只留 AudioSink PCM 通路，绝不挂 Visualizer
                //（挂载动作本身就会让 AudioFlinger 把这条轨道从 fast track 降级）。
                // 返回 true：PCM 监听已注册，Dart 不应立刻转模拟，
                // 交给 1.5s 保险丝判断即可，避免每次开频谱都闪一下模拟律动。
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
                        // PCM 数据已接管时不处理 Visualizer 数据
                        if (pcmActive) return
                        if (fftCallbackCount < 3) {
                            val bands = computeBandsFromWaveform(waveform)
                            mainHandler.post {
                                if (generation == captureGeneration && pcmCaptureEnabled && !pcmActive) {
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
                        // PCM 数据已接管时不处理 Visualizer 数据
                        if (pcmActive) return
                        val bands = computeBands(fft)
                        mainHandler.post {
                            if (generation == captureGeneration && pcmCaptureEnabled && !pcmActive) {
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
                // 初始化可能晚于 stop/下一次 start，旧实例不得接管新会话。
                if (generation != captureGeneration || !pcmCaptureEnabled) {
                    finalViz?.let { releaseVisualizerAsync(it) }
                    result.success(false)
                    return@post
                }
                if (finalError != null) {
                    Log.e(TAG, "Visualizer start failed", finalError)
                    // Visualizer 失败不阻断：PCM 截取已注册，可能仍有数据
                    result.success(pcmActive)
                } else if (finalViz == null) {
                    result.error("START_FAILED", "Visualizer 创建返回 null", null)
                } else {
                    // PCM 可能在 Visualizer 初始化期间已经接管。
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

    // ── PCM 截取 → FFT ──────────────────────────────────────────────

    /**
     * 跑在 ExoPlayer 渲染线程（由 [UsbAudioSinkController.handleBuffer] 调用）。
     *
     * **这里只允许做样本拷贝**：任何 Binder 调用、任何 FFT 都会直接造成
     * AudioTrack 欠载 → 用户听到「一声爆音/刺啦」。
     */
    private fun handlePcm(buffer: ByteBuffer, encoding: Int, sampleRate: Int, channelCount: Int) {
        if (!pcmCaptureEnabled || channel == null) return
        if (PcmEncoding.bytesPerSample(encoding) == 0) {
            // 宁可刷日志，也不要静默丢弃 —— 静默 else 曾让整个问题毫无线索
            RingLog.w(TAG, "unsupported PCM encoding ${PcmEncoding.nameOf(encoding)} — frame dropped")
            return
        }

        val generation = captureGeneration
        if (!analyzer.append(buffer, encoding, sampleRate, channelCount)) return

        // 首帧激活：摘掉 Visualizer。释放走后台线程，绝不在渲染线程做 Binder。
        if (!pcmActive) {
            pcmActive = true
            analyzer.markActive()
            RingLog.i(TAG, "PCM capture active (rate=${analyzer.sampleRateHz}Hz) — disabling Visualizer data")
            stopVisualizer()
        }
        // 双保险：PCM 连续产出 HARD_RELEASE_AFTER_FRAMES 帧后再无条件摘一次，
        // 防止首次摘除因时序问题（Visualizer 实例晚于 PCM 激活才存入 visualizerRef）漏网。
        if (!hardReleased && analyzer.emitCount >= HARD_RELEASE_AFTER_FRAMES) {
            hardReleased = true
            val frames = analyzer.emitCount
            stopVisualizer()
            RingLog.i(TAG, "VIZ hard-release after $frames PCM frames")
        }

        // 快照必须在渲染线程取（ring 随后会被下一块改写），FFT 交出去
        analyzer.copyRingInto(fftSnapshot)
        val accepted = fftPump.submit(generation.toLong(), { captureGeneration.toLong() }) {
            // 一次 FFT 同时产出视觉 40 段与节拍特征向量（见 SpectrumAnalyzer.analyzeOf）
            val frame = analyzer.analyzeOf(fftSnapshot)
            analyzedFrames++
            // 特征向量的第一个对数频带能量：既能确认"有数据"，又能一眼看出是否有低频内容
            val lowFeature = frame.features.getOrElse(SpectrumFeatures.INDEX_LOW) { 0f }
            // invokeMethod 被标记 @UiThread，必须切回主线程
            mainHandler.post {
                if (generation == captureGeneration && pcmCaptureEnabled) {
                    deliveredFrames++
                    channel?.invokeMethod("onFft", frame.bands)
                    // 音乐节奏震动的数据源：只有 PCM 路径有原始时域样本，Visualizer
                    // 兜底路径拿不到，故那里不发 onFeatures。
                    channel?.invokeMethod("onFeatures", frame.features)
                    if (analyzer.emitCount % 100L == 1L) {
                        RingLog.i(TAG, "onFeatures #${analyzer.emitCount} low=$lowFeature")
                    }
                }
            }
        }
        if (accepted) submittedFrames++
    }

    private fun stopAll() {
        ++captureGeneration
        pcmCaptureEnabled = false
        pcmActive = false
        hardReleased = false
        analyzer.reset()
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

    /**
     * 摘掉 Visualizer。**永不阻塞调用线程**：`release()` 是同步 Binder，可能几十毫秒，
     * 而调用点分别是渲染线程与主线程，两处都卡不起。
     */
    private fun stopVisualizer() {
        val v = visualizerRef.getAndSet(null) ?: return
        releaseVisualizerAsync(v)
    }

    private fun releaseVisualizerAsync(v: Visualizer) {
        try {
            releaseExecutor.execute { releaseVisualizer(v) }
        } catch (_: RuntimeException) {
            // executor 已 shutdown（cleanup 之后又收到 stop）→ 就地释放兜底
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
        fftPump.shutdown()
        releaseExecutor.shutdown()
    }
}
