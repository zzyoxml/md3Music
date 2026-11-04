package com.md3music.md3music

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.ryanheise.just_audio.AudioDecoderCapabilities
import com.ryanheise.just_audio.AudioOffloadCapabilities
import com.ryanheise.just_audio.AudioOffloadController
import com.ryanheise.just_audio.AudioPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统音频 Offload（硬件通路直通）控制插件：MethodChannel
 * `com.md3music.md3music/audio_offload`。
 *
 * 与 [DirectPcmPlugin] 的分工：
 * - `DirectPcmPlugin` 管「系统 Direct PCM 档」的行为开关（float / performanceMode / 缓冲）
 * - 本插件管「交给系统音频服务做 offload 解码输出」的开关与能力探测
 *
 * 状态同样放在 fork 的静态类里（`AudioOffloadController` / `AudioPlayer` 静态标志），
 * 因为 offload 决策发生在 `DefaultAudioSink` / `AudioTrack` 配置阶段，与插件实例生命
 * 周期无关；插件实例只负责通道转发、后台预热探测与「原生 → Dart」状态推送。
 *
 * 主引擎（MainActivity）与 headless 播放引擎（AudioPlaybackService）各注册一次，
 * UI isolate 与播放 isolate 都能调到。
 */
class AudioOffloadPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.md3music.md3music/audio_offload"
        private const val TAG = "AudioOffloadPlugin"
    }

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    /** 上一次推送原因：连续同一 reason 只打一行日志（限频，避免 sink 抖动刷屏）。 */
    @Volatile
    private var lastPushReason: String? = null

    fun register(flutterEngine: FlutterEngine) {
        // fork 侧在 AudioTrack 建轨 / 新流开始 / 通路切换时回调；
        // 可能在渲染线程，故 pushStatus 内部统一 post 回主线程再触碰 channel。
        AudioOffloadController.setStatusListener { pushStatus("sink-changed") }

        // 能力探测要 AudioManager：先注入 application context，否则「还没建过播放器就进
        // 设置页」时会 probe 出空快照（页面显示尚未探测，点重新探测也没用）。
        AudioOffloadCapabilities.attachContext(context)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }

        // 预热：能力探测要问解码器与 AudioTrack 平台信息，放主线程会拖慢首帧。
        // 只用后台线程跑一次并写入 fork 侧缓存，失败仅记日志（功能降级，不崩）。
        // 两个数据源各预热一次：offload 协商（AudioManager）+ 设备解码器（MediaCodecList）。
        Thread {
            runCatching { AudioOffloadCapabilities.probeOnBackgroundThread() }
                .onFailure { UsbLog.w(TAG, "预热 offload 协商探测失败: ${it.message}") }
            runCatching { AudioDecoderCapabilities.probeOnBackgroundThread() }
                .onFailure { UsbLog.w(TAG, "预热解码器能力探测失败: ${it.message}") }
        }.also {
            it.name = "audio-offload-warmup"
            it.isDaemon = true
        }.start()

        UsbLog.i(TAG, "registered, sdkInt=${Build.VERSION.SDK_INT}")
    }

    fun cleanup() {
        // 先摘 listener：否则旧实例仍会被 fork 侧回调，重复推 onStatusChanged。
        runCatching { AudioOffloadController.setStatusListener(null) }
        runCatching { channel?.setMethodCallHandler(null) }
        channel = null
        // 丢弃尚未执行的状态推送，避免引擎切换后打到已失效的 messenger 上。
        runCatching { main.removeCallbacksAndMessages(null) }
        lastPushReason = null
    }

    // ── 方法分发 ─────────────────────────────────────────────────────

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getStatus" -> result.success(AudioOffloadController.status())
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val status = AudioPlayer.setGlobalAudioOffloadEnabled(enabled)
                    UsbLog.i(TAG, "setEnabled=$enabled")
                    result.success(status)
                }
                "probeCapabilities" -> probeCapabilitiesAsync(result)
                // 只读缓存，不触发探测；从未探测过时为 null，由 Dart 侧决定是否 probe。
                "getCachedCapabilities" -> result.success(AudioOffloadCapabilities.snapshot()?.toMap())
                // 设备解码器能力（MediaCodecList）：与 offload 协商是两个独立数据源。
                "probeDecoderCapabilities" -> probeDecoderCapabilitiesAsync(result)
                "getCachedDecoderCapabilities" ->
                    result.success(AudioDecoderCapabilities.snapshot()?.toMap())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            UsbLog.e(TAG, "handle ${call.method} failed: ${t.message}", t)
            result.error("AUDIO_OFFLOAD_ERROR", t.message, null)
        }
    }

    /**
     * 后台探测后回主线程返回。
     *
     * 若 fork 侧已有探测进行中，`probeOnBackgroundThread()` 会直接返回缓存快照，
     * 这里照常回 Dart（不会阻塞、也不会重复跑探测）。探测抛异常时退回缓存快照，
     * 都没有才报错。
     */
    private fun probeCapabilitiesAsync(result: MethodChannel.Result) {
        Thread {
            val map = runCatching { AudioOffloadCapabilities.probeOnBackgroundThread()?.toMap() }
                .getOrElse { t ->
                    UsbLog.w(TAG, "probeCapabilities 失败: ${t.message}")
                    null
                } ?: AudioOffloadCapabilities.snapshot()?.toMap()

            main.post {
                // MethodChannel.Result 必须在平台线程回调，跨线程直接调会抛异常。
                if (map != null) {
                    result.success(map)
                } else {
                    result.error("AUDIO_OFFLOAD_ERROR", "能力探测失败且无缓存快照", null)
                }
            }
        }.also {
            it.name = "audio-offload-probe"
            it.isDaemon = true
        }.start()
    }

    /**
     * 设备解码器能力（MediaCodecList 枚举 + 位深试配）后台探测后回主线程返回。
     *
     * 与 [probeCapabilitiesAsync] 同一套约定：探测抛异常时退回缓存快照，都没有才报错。
     * 位深试配是「create → configure → release」短事务，必须在后台线程，且已由 fork 侧
     * 做了次数/耗时预算，这里不再额外限流。
     */
    private fun probeDecoderCapabilitiesAsync(result: MethodChannel.Result) {
        Thread {
            val map = runCatching { AudioDecoderCapabilities.probeOnBackgroundThread()?.toMap() }
                .getOrElse { t ->
                    UsbLog.w(TAG, "probeDecoderCapabilities 失败: ${t.message}")
                    null
                } ?: AudioDecoderCapabilities.snapshot()?.toMap()

            main.post {
                if (map != null) {
                    result.success(map)
                } else {
                    result.error("AUDIO_OFFLOAD_ERROR", "解码器能力探测失败且无缓存快照", null)
                }
            }
        }.also {
            it.name = "audio-decoder-probe"
            it.isDaemon = true
        }.start()
    }

    // ── 状态推送 ─────────────────────────────────────────────────────
    private fun pushStatus(reason: String) {
        if (reason != lastPushReason) {
            lastPushReason = reason
            UsbLog.i(TAG, "status push: $reason")
        }
        main.post {
            runCatching {
                channel?.invokeMethod("onStatusChanged", AudioOffloadController.status())
            }
        }
    }
}
