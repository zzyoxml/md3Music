package com.md3music.md3music

import android.media.audiofx.Equalizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
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
 * - **每个 audio session 各挂一个 Equalizer 实例**（[equalizers]）：crossfade 的
 *   主 / 辅播放器各有独立会话（见 fork 内 AudioPlayer.ensurePlayerInitialized 注释
 *   —— 共用一个会话时 MIUI 会让两路的音量斜坡串台）。用户设置在 [userEnabled] /
 *   [bandLevels] / [presetInUse] 里镜像一份，新会话的实例一创建就照它初始化，
 *   于是淡化全程两路都走音效，也不需要在淡化期间开关音效（开关本身会爆音）。
 */
class EqualizerPlugin {

    companion object {
        private const val TAG = "EqualizerPlugin"
        private const val CHANNEL_NAME = "com.md3music.md3music/equalizer"
        private const val INIT_TIMEOUT_MS = 4000L
    }

    /** audioSessionId → 该会话上的 Equalizer 实例。 */
    private val equalizers = ConcurrentHashMap<Int, Equalizer>()
    private var channel: MethodChannel? = null

    /** 只读查询（频段信息 / 预设列表）走第一个绑定的会话。 */
    @Volatile
    private var primarySessionId: Int? = null

    // —— 用户设置的镜像：用于初始化后来加入的会话 ——
    private var userEnabled: Boolean = false
    private val bandLevels = ConcurrentHashMap<Short, Short>()
    /** 最后一次通过 usePreset 应用的系统预设；用滑块调过频段后失效。 */
    @Volatile
    private var presetInUse: Short? = null

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    val audioSessionId = call.argument<Int>("audioSessionId") ?: 0
                    initEqualizer(audioSessionId, result)
                }
                "release" -> {
                    // 带 audioSessionId 只释放该会话（某个播放器换了会话），否则全部释放
                    val audioSessionId = call.argument<Int>("audioSessionId")
                    if (audioSessionId != null) {
                        releaseSession(audioSessionId)
                    } else {
                        releaseAll()
                    }
                    result.success(true)
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    userEnabled = enabled
                    val failure = forEachEqualizer { it.enabled = enabled }
                    if (failure == null) {
                        result.success(true)
                    } else {
                        Log.e(TAG, "setEnabled failed", failure)
                        result.error("SET_ENABLED_FAILED", failure.message, null)
                    }
                }
                "setBandLevel" -> {
                    val band = (call.argument<Number>("band")?.toInt() ?: 0).toShort()
                    val level = (call.argument<Number>("level")?.toInt() ?: 0).toShort()
                    bandLevels[band] = level
                    presetInUse = null
                    val failure = forEachEqualizer { it.setBandLevel(band, level) }
                    if (failure == null) {
                        result.success(true)
                    } else {
                        Log.e(TAG, "setBandLevel failed", failure)
                        result.error("SET_BAND_LEVEL_FAILED", failure.message, null)
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
                    val failure = forEachEqualizer { it.usePreset(preset) }
                    if (failure == null) {
                        presetInUse = preset
                        // 预设改写了所有频段，重新采样镜像，供后来加入的会话使用
                        captureBandLevels()
                        result.success(true)
                    } else {
                        Log.e(TAG, "usePreset failed", failure)
                        result.error("USE_PRESET_FAILED", failure.message, null)
                    }
                }
                "getCurrentPreset" -> {
                    try {
                        val preset = primaryEqualizer()?.currentPreset ?: (-1).toShort()
                        result.success(preset.toInt())
                    } catch (e: Exception) {
                        result.success(-1)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 只读查询用的实例：优先 primary，它已释放时退化为任意一个。 */
    private fun primaryEqualizer(): Equalizer? {
        primarySessionId?.let { id -> equalizers[id]?.let { return it } }
        return equalizers.values.firstOrNull()
    }

    /**
     * 对所有会话上的实例执行 [action]，返回第一个异常（全部成功则返回 null）。
     * 单个实例失败不影响其余实例 —— 淡化中一个会话失效不该让另一路也没音效。
     */
    private fun forEachEqualizer(action: (Equalizer) -> Unit): Exception? {
        var firstError: Exception? = null
        for ((sessionId, eq) in equalizers) {
            try {
                action(eq)
            } catch (e: Exception) {
                Log.e(TAG, "equalizer op failed on session $sessionId", e)
                if (firstError == null) firstError = e
            }
        }
        return firstError
    }

    /** 把设备当前频段增益采样进 [bandLevels] 镜像。 */
    private fun captureBandLevels() {
        val eq = primaryEqualizer() ?: return
        try {
            for (i in 0 until eq.numberOfBands.toInt()) {
                val band = i.toShort()
                bandLevels[band] = eq.getBandLevel(band)
            }
        } catch (e: Exception) {
            Log.e(TAG, "captureBandLevels failed", e)
        }
    }

    /**
     * 把镜像的用户设置写进新建的实例，让它与已有会话完全一致。
     *
     * 先频段、后开关：反过来会让这一路在开关打开后短暂走平坦频响。
     * 这一步发生在该会话对应的播放器尚未出声时（辅播放器在 prepareCrossfade 里
     * 以 0 音量预加载），所以启用音效的那一下听不到。
     */
    private fun applyMirroredState(eq: Equalizer) {
        try {
            val preset = presetInUse
            if (preset != null) {
                eq.usePreset(preset)
            } else {
                for ((band, level) in bandLevels) {
                    eq.setBandLevel(band, level)
                }
            }
            eq.enabled = userEnabled
        } catch (e: Exception) {
            Log.e(TAG, "applyMirroredState failed", e)
        }
    }

    /**
     * 为 [audioSessionId] 建立 Equalizer，在子线程执行，4 秒超时保护。
     * 部分设备 Equalizer 构造函数会无限阻塞，超时后安全返回 error。
     * 不在主线程 join 等待，避免阻塞 UI 导致 ANR。
     *
     * 该会话已有实例时直接返回频段信息：重复 init 若先释放再重建，
     * 正在出声的那一路会听到音效摘挂的爆音。
     */
    private fun initEqualizer(audioSessionId: Int, result: MethodChannel.Result) {
        if (equalizers.containsKey(audioSessionId)) {
            result.success(getBandInfo())
            return
        }

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
                    finishInit(audioSessionId, ref.get(), errorRef.get(), result)
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

    private fun finishInit(
        audioSessionId: Int,
        eq: Equalizer?,
        error: Exception?,
        result: MethodChannel.Result,
    ) {
        if (error != null) {
            Log.e(TAG, "Equalizer init failed on session $audioSessionId", error)
            result.error("INIT_FAILED", error.message, null)
            return
        }
        if (eq == null) {
            result.error("INIT_FAILED", "均衡器创建返回 null", null)
            return
        }
        val previous = equalizers.put(audioSessionId, eq)
        if (previous != null) {
            // 竞态：同一会话并发 init。留下后到的那个，释放先前的
            try { previous.release() } catch (_: Exception) {}
        }
        val isFirst = primarySessionId == null
        if (isFirst) primarySessionId = audioSessionId
        // 第一个会话的频段值就是设备默认（全 0），此时镜像为空；
        // 后续会话则要立刻追上已有设置，否则淡化时只有一路走音效。
        if (isFirst) captureBandLevels() else applyMirroredState(eq)
        Log.d(TAG, "equalizer bound: session=$audioSessionId total=${equalizers.size}")
        result.success(getBandInfo())
    }

    /** 释放单个会话上的实例（该播放器换了会话 / 被回收）。 */
    private fun releaseSession(audioSessionId: Int) {
        val eq = equalizers.remove(audioSessionId) ?: return
        try {
            eq.release()
        } catch (e: Exception) {
            Log.e(TAG, "release failed on session $audioSessionId", e)
        }
        if (primarySessionId == audioSessionId) {
            primarySessionId = equalizers.keys.firstOrNull()
        }
        Log.d(TAG, "equalizer released: session=$audioSessionId total=${equalizers.size}")
    }

    private fun releaseAll() {
        userEnabled = false
        bandLevels.clear()
        presetInUse = null
        primarySessionId = null
        val iterator = equalizers.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            iterator.remove()
            try {
                entry.value.release()
            } catch (e: Exception) {
                Log.e(TAG, "release failed on session ${entry.key}", e)
            }
        }
    }

    /**
     * 返回频段信息（取 primary 会话，各会话的硬件参数一致）：
     * - bandCount: Int
     * - minLevel: Int (mB)
     * - maxLevel: Int (mB)
     * - centerFreqs: List<Int> (milliHz)
     * - bandLevels: List<Int> (mB, 当前值)
     */
    private fun getBandInfo(): Map<String, Any> {
        val eq = primaryEqualizer() ?: return mapOf(
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
     * 可能包含尾部 null 字节，Flutter 会渲染为 □ 豆腐块）。
     */
    private fun getPresets(): List<String> {
        val eq = primaryEqualizer() ?: return emptyList()
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
        releaseAll()
    }
}
