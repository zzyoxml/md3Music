package com.md3music.md3music.stem

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ryanheise.just_audio.StemSeparateProcessor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * 端侧人声/伴奏分离插件。
 *
 * 通道 `com.md3music.md3music/stem_separation`，方法：
 *
 * | 方法 | 返回 | 说明 |
 * |---|---|---|
 * | `isAvailable` | `Boolean` | 模型随包且 ABI/运行时可用 |
 * | `init` | `{available, latencyMs}` | 预热：建解释器（后台线程） |
 * | `setEnabled` | `Map` 状态快照 | 开关分离（内部调 [StemSeparateProcessor] 静态控制面） |
 * | `setMix` | `null` | 伴奏占比 0..1 |
 * | `getStats` | `Map` | `blocks/avgBlockMs/rtf/dryPercent/overloaded/latencyMs` |
 * | `reset` | `null` | 清流式状态（seek/换曲） |
 *
 * **模型缺失时一切方法都安全返回**（`available: false`），不抛异常、不崩：
 * 公开树不带 `stem/mss-model.tflite`，同一份 Dart 代码要靠这个判断隐藏入口。
 */
object StemSeparationPlugin {

    private const val TAG = "StemSep"
    private const val CHANNEL = "com.md3music.md3music/stem_separation"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val initExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "stem-init").also { it.isDaemon = true }
    }

    /** 会话（懒创建：第一次 init/enable 时建，注入引擎工厂）。 */
    @Volatile private var session: StemSeparateSession? = null

    /** TFLite 解释器（模型加载成功前为 null）。 */
    @Volatile private var interpreter: TfliteMssInterpreter? = null

    @Volatile private var loading = false
    @Volatile private var available = false

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        available = TfliteMssInterpreter.assetPresent(context.applicationContext)
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(available)
                "init" -> handleInit(result)
                "setEnabled" -> handleSetEnabled(call, result)
                "setMix" -> handleSetMix(call, result)
                "getStats" -> result.success(statsMap())
                "reset" -> {
                    session?.flush()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        Log.i(TAG, "插件已注册 available=$available")
    }

    /** 填充 Manifest/Activity 销毁时清理（避免 headless 引擎重建后残留 hook）。 */
    fun dispose() {
        StemSeparateProcessor.setGlobalEnabled(false)
        StemSeparateProcessor.setGlobalHook(null)
        session?.release()
        session = null
        interpreter?.close()
        interpreter = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ───────────────────────── handlers ─────────────────────────

    private fun handleInit(result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null || !available) {
            result.success(availMap(false))
            return
        }
        if (interpreter != null) {
            result.success(
                availMap(true),
            )
            return
        }
        if (loading) {
            // 正在加载：直接回「暂不可用」，Dart 侧会稍后重试；不排队等
            result.success(availMap(false))
            return
        }
        loading = true
        initExecutor.execute {
            val itp = try {
                TfliteMssInterpreter.create(ctx)
            } catch (t: Throwable) {
                Log.e(TAG, "模型加载失败: ${t.javaClass.simpleName} ${t.message}")
                null
            }
            interpreter = itp
            available = itp != null
            loading = false
            if (itp != null) attachSession(itp)
            main.post {
                result.success(
                    mapOf<String, Any?>(
                        "available" to (itp != null),
                        "latencyMs" to StemSeparateSession.LATENCY_MS,
                    ),
                )
            }
        }
    }

    private fun handleSetEnabled(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") == true
        val itp = interpreter
        if (enabled && itp == null) {
            result.success(enabledMap(false, "model-unavailable"))
            return
        }
        attachSession(itp)
        StemSeparateProcessor.setGlobalEnabled(enabled && session != null)
        session?.flush()
        result.success(statsMap())
    }

    private fun handleSetMix(call: MethodCall, result: MethodChannel.Result) {
        val mix = call.argument<Double>("mix") ?: 1.0
        val v = mix.toFloat().coerceIn(0f, 1f)
        StemSeparateProcessor.setGlobalMix(v)
        session?.setMix(v)
        result.success(null)
    }

    /** 建会话并注入 fork 的处理器。 */
    private fun attachSession(itp: TfliteMssInterpreter?) {
        val ctx = appContext ?: return
        if (itp == null) return
        val s =
            session
                ?: StemSeparateSession {
                    // 引擎工厂：解释器已经建好，这里只包一层（保持 worker 里懒创建语义）
                    MssEngine(itp)
                }.also { session = it }
        StemSeparateProcessor.setGlobalHook(s)
        StemSeparateProcessor.setGlobalMix(StemSeparateProcessor.getGlobalMix())
        Log.i(TAG, "会话就绪 latency=${StemSeparateSession.LATENCY_MS}ms")
    }

    private fun availMap(ok: Boolean): Map<String, Any?> =
        mapOf<String, Any?>(
            "available" to ok,
            "latencyMs" to StemSeparateSession.LATENCY_MS,
        )

    private fun enabledMap(ok: Boolean, reason: String?): Map<String, Any?> =
        mapOf<String, Any?>(
            "enabled" to ok,
            "reason" to reason,
        )

    private fun statsMap(): Map<String, Any?> {
        val s = session
        if (s == null) {
            return mapOf<String, Any?>(
                "ready" to false,
                "available" to available,
                "latencyMs" to StemSeparateSession.LATENCY_MS,
            )
        }
        val st = s.stats()
        return mapOf<String, Any?>(
            "ready" to st.ready,
            "available" to available,
            "blocks" to st.blocks,
            "avgBlockMs" to st.avgBlockMs,
            "rtf" to st.rtf,
            "dryPercent" to st.dryPercent,
            "overloaded" to st.overloaded,
            "sampleRate" to st.sampleRate,
            "channels" to st.channels,
            "droppedBlocks" to st.droppedBlocks,
            "latencyMs" to st.latencyMs,
            "resetCount" to st.resetCount,
            "skippedFrames" to st.skippedFrames,
        )
    }
}
