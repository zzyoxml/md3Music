package com.md3music.md3music

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.ryanheise.just_audio.DirectPcmCapabilities
import com.ryanheise.just_audio.DirectPcmController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统 Direct PCM 输出插件：MethodChannel `com.md3music.md3music/direct_pcm`。
 *
 * 与 [UsbAudioPlugin] 的分工：
 * - `UsbAudioPlugin` 持有 **USB 独占**（usbdevfs 直写）状态
 * - 本插件持有 **系统 Direct PCM** 状态（走系统 AudioTrack，不碰 usbdevfs）
 *
 * 两者互斥，由 Dart 侧 `OutputModeCoordinator` 仲裁；本插件只负责与
 * `DirectPcmController`（fork 内静态状态）对话、探测设备能力、推送状态变化。
 *
 * 为什么状态放在 fork 的静态类里而不是插件实例字段：Direct PCM 的三个行为开关
 * （float 强制 / performanceMode / 缓冲）都发生在 `DefaultAudioSink.configure`
 * 与 AudioTrack 创建时，与插件实例生命周期无关；静态标志也让「切档无需重建播放器」
 * 成为可能（只有切档本身需要重配 AudioTrack，由应用侧 pause→play 触发）。
 */
class DirectPcmPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.md3music.md3music/direct_pcm"
        private const val TAG = "DirectPcmPlugin"
    }

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    /** 输出设备插拔监听。API 23+，比广播更准，且不受 API 33 的 registerReceiver flag 约束。 */
    private var deviceCallback: AudioDeviceCallback? = null

    fun register(flutterEngine: FlutterEngine) {
        // 供 DirectPcmCapabilities 反射/属性探测实际输出率与设备原生能力
        DirectPcmController.attachContext(context)
        // fork 侧日志（开关变更）也进应用侧环形缓冲，随诊断导出
        DirectPcmController.setLogForwarder { level, tag, msg ->
            UsbLog.bridge(level, tag, msg)
        }
        // AudioTrack 建轨 / 新流开始 / 音量变化时主动推状态：
        // 否则设置页的「实测状态」会停留在打开那一刻的旧值（实测踩过：
        // AudioFlinger 让 HAL 从 192kHz 降到 48kHz 并重建 track，面板仍显示 192kHz）。
        DirectPcmController.setStatusListener { pushStatus("sink-changed") }

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
        registerDeviceCallback()
        UsbLog.i(TAG, "registered, sdkInt=${Build.VERSION.SDK_INT}")
    }

    fun cleanup() {
        runCatching { unregisterDeviceCallback() }
        runCatching { DirectPcmController.setStatusListener(null) }
        runCatching { DirectPcmController.setLogForwarder(null) }
        runCatching { channel?.setMethodCallHandler(null) }
        channel = null
    }

    // ── 方法分发 ─────────────────────────────────────────────────────

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getStatus" -> result.success(DirectPcmController.getStatus())
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    DirectPcmController.setEnabled(enabled)
                    UsbLog.i(TAG, "setEnabled=$enabled")
                    // 切档需要重跑 DefaultAudioSink.configure 才生效：先停再放，
                    // 应用侧随后还会做一次 pause→play 重建。
                    result.success(DirectPcmController.getStatus())
                }
                "setFeature" -> {
                    val key = call.argument<String>("feature")
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    DirectPcmController.setFeature(key, enabled)
                    result.success(DirectPcmController.getStatus())
                }
                "setFeatures" -> {
                    @Suppress("UNCHECKED_CAST")
                    val raw = call.argument<Map<String, Boolean>>("features") ?: emptyMap()
                    raw.forEach { (k, v) -> DirectPcmController.setFeature(k, v == true) }
                    result.success(DirectPcmController.getStatus())
                }
                "getDeviceInfo" -> result.success(buildDeviceInfo())
                "getLogs" -> result.success(UsbLog.exportAll())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            UsbLog.e(TAG, "handle ${call.method} failed: ${t.message}", t)
            result.error("DIRECT_PCM_ERROR", t.message, null)
        }
    }

    // ── 设备能力 ─────────────────────────────────────────────────────

    private fun buildDeviceInfo(): Map<String, Any?> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val info = mutableMapOf<String, Any?>(
            "sdkInt" to Build.VERSION.SDK_INT,
            "exactRouteProbeSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S),
            "lowLatencySupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
            "supportsUnprocessed" to supportsUnprocessed(am),
        )
        if (am == null) {
            info["audioManagerAvailable"] = false
            return info
        }
        info["audioManagerAvailable"] = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            info["outputDevices"] = outs.map { d ->
                mapOf(
                    "id" to d.id,
                    "name" to d.productName.toString(),
                    "type" to d.type,
                    "isExternalDac" to DirectPcmCapabilities.isExternalDacType(d.type),
                    "sampleRates" to d.sampleRates.toList(),
                    "channelCounts" to d.channelCounts.toList(),
                )
            }
            // 当前 Primary 输出设备的原生能力（best-effort：没有 sessionId 时按主输出取）
            val primary = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
                DirectPcmCapabilities.isExternalDacType(it.type)
            } ?: am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull()
            if (primary != null) {
                info["primaryDeviceSampleRates"] = primary.sampleRates.toList()
                info["primaryDeviceChannelCounts"] = primary.channelCounts.toList()
            }
        }
        return info
    }

    /**
     * `AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED`（API 24+）。
     * 该属性为 true 表示系统承认存在「不处理」的音源路径，是 bit-perfect 的有利信号，
     * 但**不保证**实际走的是该路径，故只作为状态展示，不参与 bit-perfect 判定。
     */
    private fun supportsUnprocessed(am: AudioManager?): Boolean {
        if (am == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        } catch (t: Throwable) {
            false
        }
    }

    // ── 输出设备变化监听 ─────────────────────────────────────────────

    private fun registerDeviceCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (deviceCallback != null) return
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                pushStatus("devices-added")
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                // 拔掉 DAC 会让 AudioTrack 的 device id / 原生输出率失效，
                // 通知 Dart 刷新状态（DirectPcmSink 侧会在 handleSetOutputDeviceUs 重置 id）。
                pushStatus("devices-removed")
            }
        }
        runCatching { am.registerAudioDeviceCallback(cb, main) }
            .onSuccess { deviceCallback = cb }
            .onFailure { UsbLog.w(TAG, "registerAudioDeviceCallback 失败: ${it.message}") }
    }

    private fun unregisterDeviceCallback() {
        val cb = deviceCallback ?: return
        deviceCallback = null
        runCatching {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.unregisterAudioDeviceCallback(cb)
        }
    }

    private fun pushStatus(reason: String) {
        UsbLog.i(TAG, "status push: $reason")
        main.post {
            runCatching {
                channel?.invokeMethod("onStatusChanged", DirectPcmController.getStatus())
            }
        }
    }
}
