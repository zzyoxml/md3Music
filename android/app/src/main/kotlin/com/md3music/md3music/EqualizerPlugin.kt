package com.md3music.md3music

import android.media.audiofx.Equalizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * 均衡器插件：通过 MethodChannel "com.md3music.md3music/equalizer" 暴露 Android 原生 Equalizer。
 *
 * 使用 android.media.audiofx.Equalizer，绑定到 just_audio 的 audio session ID。
 * 频段数和频率由设备硬件决定（通常 5 段：60Hz / 230Hz / 910Hz / 3600Hz / 14000Hz）。
 *
 * 关键设计：
 * - init 在子线程执行，4 秒超时保护（部分设备 Equalizer 构造函数会无限阻塞）
 * - 超时后安全释放，返回 error 让 Dart 端提示用户重试
 * - 频段增益单位为 millibel (mB)，范围由设备决定（通常 ±1500 mB = ±15 dB）
 */
class EqualizerPlugin {

    companion object {
        private const val TAG = "EqualizerPlugin"
        private const val CHANNEL_NAME = "com.md3music.md3music/equalizer"
        private const val INIT_TIMEOUT_MS = 4000L
    }

    private var equalizer: AtomicReference<Equalizer?> = AtomicReference(null)
    private var channel: MethodChannel? = null

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    val audioSessionId = call.argument<Int>("audioSessionId") ?: 0
                    initEqualizer(audioSessionId, result)
                }
                "release" -> {
                    releaseEqualizer()
                    result.success(true)
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        equalizer.get()?.enabled = enabled
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "setEnabled failed", e)
                        result.error("SET_ENABLED_FAILED", e.message, null)
                    }
                }
                "setBandLevel" -> {
                    val band = (call.argument<Number>("band")?.toInt() ?: 0).toShort()
                    val level = (call.argument<Number>("level")?.toInt() ?: 0).toShort()
                    try {
                        equalizer.get()?.setBandLevel(band, level)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "setBandLevel failed", e)
                        result.error("SET_BAND_LEVEL_FAILED", e.message, null)
                    }
                }
                "getBandInfo" -> {
                    result.success(getBandInfo())
                }
                "getPresets" -> {
                    result.success(getPresets())
                }
                "usePreset" -> {
                    val preset = (call.argument<Number>("preset")?.toInt() ?: 0).toShort()
                    try {
                        equalizer.get()?.usePreset(preset)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "usePreset failed", e)
                        result.error("USE_PRESET_FAILED", e.message, null)
                    }
                }
                "getCurrentPreset" -> {
                    try {
                        val preset = equalizer.get()?.currentPreset ?: (-1).toShort()
                        result.success(preset.toInt())
                    } catch (e: Exception) {
                        result.success(-1)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 在子线程初始化 Equalizer，异步回调结果，4 秒超时保护。
     * 部分设备 Equalizer 构造函数会无限阻塞，超时后安全返回 error。
     * P0: 不再在主线程 join 等待，避免阻塞 UI 导致 ANR。
     */
    private fun initEqualizer(audioSessionId: Int, result: MethodChannel.Result) {
        // 先释放旧的
        releaseEqualizer()

        val ref = AtomicReference<Equalizer?>(null)
        val errorRef = AtomicReference<Exception?>(null)
        val mainHandler = Handler(Looper.getMainLooper())
        // 保证 result 只回调一次（构造完成回调与超时回调存在竞态）
        val resultDone = AtomicBoolean(false)

        val initThread = Thread {
            try {
                val eq = Equalizer(0, audioSessionId)
                ref.set(eq)
            } catch (e: Exception) {
                errorRef.set(e)
            }
            // 构造完成（成功或失败）后回主线程回调 Flutter result
            mainHandler.post {
                if (resultDone.compareAndSet(false, true)) {
                    finishInit(ref.get(), errorRef.get(), result)
                } else {
                    // 超时回调已返回：释放迟到的 Equalizer，避免 native 资源泄漏
                    ref.get()?.let { eq ->
                        try { eq.release() } catch (_: Exception) {}
                    }
                }
            }
        }
        initThread.isDaemon = true
        initThread.start()

        // 超时保护：若构造函数永久阻塞，通知 Dart 超时（不阻塞主线程）
        mainHandler.postDelayed({
            if (initThread.isAlive && resultDone.compareAndSet(false, true)) {
                Log.e(TAG, "Equalizer init timed out after ${INIT_TIMEOUT_MS}ms")
                result.error("INIT_TIMEOUT", "均衡器初始化超时，请先播放一首歌曲后重试", null)
            }
        }, INIT_TIMEOUT_MS)
    }

    private fun finishInit(eq: Equalizer?, error: Exception?, result: MethodChannel.Result) {
        if (error != null) {
            Log.e(TAG, "Equalizer init failed", error)
            result.error("INIT_FAILED", error.message, null)
            return
        }
        if (eq == null) {
            result.error("INIT_FAILED", "均衡器创建返回 null", null)
            return
        }
        equalizer.set(eq)
        result.success(getBandInfo())
    }

    private fun releaseEqualizer() {
        try {
            equalizer.getAndSet(null)?.release()
        } catch (e: Exception) {
            Log.e(TAG, "release failed", e)
        }
    }

    /**
     * 返回频段信息：
     * - bandCount: Int
     * - minLevel: Int (mB)
     * - maxLevel: Int (mB)
     * - centerFreqs: List<Int> (milliHz)
     * - bandLevels: List<Int> (mB, 当前值)
     */
    private fun getBandInfo(): Map<String, Any> {
        val eq = equalizer.get() ?: return mapOf(
            "bandCount" to 0,
            "minLevel" to 0,
            "maxLevel" to 0,
            "centerFreqs" to emptyList<Int>(),
            "bandLevels" to emptyList<Int>()
        )
        return try {
            val bandCount = eq.numberOfBands.toInt()
            val range = eq.bandLevelRange
            val minLevel = range[0].toInt()
            val maxLevel = range[1].toInt()
            val centerFreqs = mutableListOf<Int>()
            val bandLevels = mutableListOf<Int>()
            for (i in 0 until bandCount) {
                val band = i.toShort()
                centerFreqs.add(eq.getCenterFreq(band))
                bandLevels.add(eq.getBandLevel(band).toInt())
            }
            mapOf(
                "bandCount" to bandCount,
                "minLevel" to minLevel,
                "maxLevel" to maxLevel,
                "centerFreqs" to centerFreqs,
                "bandLevels" to bandLevels
            )
        } catch (e: Exception) {
            Log.e(TAG, "getBandInfo failed", e)
            mapOf(
                "bandCount" to 0,
                "minLevel" to 0,
                "maxLevel" to 0,
                "centerFreqs" to emptyList<Int>(),
                "bandLevels" to emptyList<Int>()
            )
        }
    }

    /**
     * 返回预设列表：List<String>
     * 清理预设名中的不可见字符（Android Equalizer.getPresetName 返回的字符串
     * 可能包含尾部 null 字节 \u0000，Flutter 会渲染为 □ 豆腐块）。
     */
    private fun getPresets(): List<String> {
        val eq = equalizer.get() ?: return emptyList()
        return try {
            val count = eq.numberOfPresets.toInt()
            val presets = mutableListOf<String>()
            for (i in 0 until count) {
                val name = eq.getPresetName(i.toShort())
                // 去除 null 字节和其他控制字符
                val cleaned = name.trim().replace(Regex("[\\u0000-\\u001F]"), "")
                presets.add(cleaned)
            }
            presets
        } catch (e: Exception) {
            Log.e(TAG, "getPresets failed", e)
            emptyList()
        }
    }

    fun cleanup() {
        releaseEqualizer()
    }
}
