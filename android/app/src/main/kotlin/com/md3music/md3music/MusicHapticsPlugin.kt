package com.md3music.md3music

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.SystemClock
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.ryanheise.just_audio.OutputLatencyProbe
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * 音乐节奏震动的执行端：能力探测、[VibrationEffect] 预构建缓存、专用线程点火。
 *
 * **为什么不复用 `md3music/haptics` 那条通道**：
 * 它的语义是「交互触点」（六个类别），音乐节拍是 2~8 次/秒的连续事件，
 * 混进去会让总开关与类别开关的语义失焦。
 *
 * **但默认档的**效果**本身复用交互那套系统预定义触感**（`createPredefined`，
 * 见 [buildPredefined]）：真机实测自定义衰减波形会在马达上拖出"嗡嗡"的尾音、
 * 连鼓点会糊成一片，而预定义效果由 HAL 直接给出带起振-刹停包络的干净点击
 * （与开关/按钮反馈同款，清脆）。衰减波形保留为显式可选档。
 *
 * **总开关不在这里实现**：Dart 侧已读 [AppHaptics]-等价的闸门决定是否下发。
 * 原生只多一层「交互避让」。
 *
 * **线程**：`Vibrator.vibrate()` 是 Binder 调用，可能阻塞数毫秒。点火一律走
 * [fireExecutor] 单线程，绝不占用 ExoPlayer 渲染线程或主线程
 * （与 `SpectrumPlugin.releaseExecutor` 同一思路）。
 */
class MusicHapticsPlugin(context: Context) {

    companion object {
        private const val TAG = "MusicHaptics"
        private const val CHANNEL_NAME = "com.md3music.md3music/music_haptics"

        /**
         * 交互震动发生后这段时间内不发音乐震动。
         *
         * 两者共用同一个 [Vibrator]，是单通道：音乐震动会打断用户刚点的按钮反馈，
         * 反之亦然。交互是用户主动发起的即时反馈，优先；音乐震动让位 150ms
         * （在 130ms 冷却下最多丢一个鼓点）。
         */
        private const val INTERACTION_SUPPRESS_MS = 150L

        /** 每档强度的离散级数：强度按档位挑预构建效果，避免每拍重建波形。 */
        private const val LEVELS = 4

        @Volatile
        private var lastInteractionAtMs = 0L

        /**
         * 由交互震动路径（`MainActivity.handleHapticVibrate`）调用。
         * 静态而非实例方法：交互通道与音乐通道是两个独立注册的 handler，
         * 实例不互通，而避让窗口是进程级事实。
         */
        fun noteInteraction() {
            lastInteractionAtMs = SystemClock.elapsedRealtime()
        }
    }

    private val appContext = context.applicationContext

    private val vibrator: Vibrator? = resolveVibrator(appContext)
    private val hasVibrator = vibrator?.hasVibrator() == true
    private val hasAmplitudeControl = vibrator?.hasAmplitudeControl() == true

    /** `VibrationEffect` 自 API 26 起存在；低版本只能退到 `vibrate(long)`。 */
    private val supportsEffects = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    /** 预定义触感（交互开关同款 `createPredefined`）自 API 29 起存在。 */
    private val supportsPredefined = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /**
     * 点火调度器：单线程 + 定时。**延迟补偿必须走在原生侧**——Dart 的 Timer
     * 受 UI isolate 抖动影响，几十毫秒误差在这里足以毁掉节奏对齐。
     */
    private val fireExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "MusicHapticFire").apply { isDaemon = true }
        }

    /** 在途的延迟点火。暂停/关开关/seek 时必须取消，否则会在几百毫秒后
     *  为早已结束的段落补一下震动。 */
    private val pendingLock = Any()
    private val pendingStrikes = mutableListOf<Future<*>>()

    /**
     * 节奏偏移（毫秒）：点火前额外等待这么久。
     *
     * 存在的原因：PCM 是在**写入 AudioTrack 缓冲的那一刻**被截取分析的，而声音
     * 要等缓冲放完才从扬声器出来 —— 检测到的鼓点比"被听见的鼓点"早了整条输出
     * 链路的深度（真机实测可达数百毫秒）。把点火延后同样的量，震动才落在拍点上。
     */
    @Volatile private var offsetMs = 0

    @Volatile private var enabled = false
    @Volatile private var waveform = "auto"
    @Volatile private var pulseMs = 40
    @Volatile private var decayMs = 1500
    @Volatile private var gamma = 8.0

    /**
     * kind -> 档位 -> 预构建效果。
     * **绝不每拍调 `createWaveform`**：那是 154 个点的数组分配 + 一次 Binder 绑定，
     * 在 20fps 的节拍上会持续给音频链路制造压力。
     */
    private var kickEffects: Array<VibrationEffect?> = arrayOfNulls(LEVELS)
    private var snareEffects: Array<VibrationEffect?> = arrayOfNulls(LEVELS)

    /** 清脆档（waveform=auto）用的预定义效果；API<29 时为 null。 */
    private var kickPredefined: VibrationEffect? = null
    private var snarePredefined: VibrationEffect? = null

    fun register(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun resolveVibrator(ctx: Context): Vibrator? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    } catch (_: Throwable) {
        null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "hasVibrator" to hasVibrator,
                    "hasAmplitudeControl" to hasAmplitudeControl,
                    "sdkInt" to Build.VERSION.SDK_INT,
                )
            )

            // 输出链路排队深度（毫秒）：供 Dart 侧自动校准节奏偏移。
            // -1 = 不可用（无 AudioTrack：USB 独占/Direct PCM 路径；API<24；
            // 或时间戳取失败）—— Dart 侧据此保持手动值不动。
            "outputLatency" -> result.success(OutputLatencyProbe.queuedLatencyMs())

            "configure" -> {
                enabled = call.argument<Boolean>("enabled") ?: false
                waveform = call.argument<String>("waveform") ?: "auto"
                pulseMs = (call.argument<Number>("pulseMs")?.toInt() ?: 40).coerceIn(5, 200)
                decayMs = (call.argument<Number>("decayMs")?.toInt() ?: 1500).coerceIn(0, 3000)
                gamma = (call.argument<Number>("gamma")?.toDouble() ?: 8.0).coerceIn(1.0, 15.0)
                offsetMs = (call.argument<Number>("offsetMs")?.toInt() ?: 0).coerceIn(0, 600)
                val kick = (call.argument<Number>("kickStrength")?.toDouble() ?: 1.0)
                    .coerceIn(0.0, 1.0)
                val snare = (call.argument<Number>("snareStrength")?.toDouble() ?: 0.6)
                    .coerceIn(0.0, 1.0)

                kickEffects = buildLevels(kick)
                snareEffects = buildLevels(snare)
                kickPredefined = buildPredefined("kick", kick)
                snarePredefined = buildPredefined("snare", snare)
                // 关掉时立刻取消在途的长波形，否则会拖到衰减结束
                if (!enabled) cancelVibration()
                RingLog.i(
                    TAG,
                    "configure enabled=$enabled waveform=$waveform amp=$hasAmplitudeControl " +
                        "kick=$kick snare=$snare offsetMs=$offsetMs",
                )
                result.success(true)
            }

            "strike" -> {
                val kind = call.argument<String>("kind") ?: "kick"
                val intensity = (call.argument<Number>("intensity")?.toDouble() ?: 1.0)
                    .coerceIn(0.0, 1.0)
                strike(kind, intensity)
                result.success(true)
            }

            "stop" -> {
                cancelVibration()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun buildLevels(baseStrength: Double): Array<VibrationEffect?> {
        if (!supportsEffects) return arrayOfNulls(LEVELS)
        return Array(LEVELS) { level -> buildEffect(baseStrength, level) }
    }

    /** 强度按档位离散化：既能跟随歌曲动态，又不需要每拍新建波形。 */
    private fun levelOf(intensity: Double): Int =
        (intensity.coerceIn(0.0, 1.0) * (LEVELS - 1)).roundToInt().coerceIn(0, LEVELS - 1)

    /**
     * 清脆档（waveform=auto）：按强度挑**交互开关同款**的系统预定义触感。
     *
     * 强度滑块只在本频带内调档，kick 与 snare 的轻重对比是**结构性**的：
     * kick 永不轻于 CLICK、snare 永不重于 CLICK —— 否则强度拉到低位时两者
     * 塌成同一个 TICK，双频带语义分层就白做了（真机实测：用户把强度调到
     * 0.2 后日志里 kick/snare 全是 TICK，鼓点失去区分）。
     *
     * 默认强度 0.8 → kick=CLICK、snare=TICK，即开关点击的手感。
     */
    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun buildPredefined(kind: String, strength: Double): VibrationEffect? {
        if (!supportsPredefined) return null
        val id = if (kind == "snare") {
            if (strength >= 0.85) VibrationEffect.EFFECT_CLICK else VibrationEffect.EFFECT_TICK
        } else {
            if (strength >= 0.85) VibrationEffect.EFFECT_HEAVY_CLICK
            else VibrationEffect.EFFECT_CLICK
        }
        return VibrationEffect.createPredefined(id)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun buildEffect(baseStrength: Double, level: Int): VibrationEffect? {
        if (!hasVibrator) return null
        val tier = level.toDouble() / (LEVELS - 1).toDouble()
        val amp01 = (baseStrength * (0.25 + 0.75 * tier)).coerceIn(0.0, 1.0)
        // 显式选了平滑且设备支持振幅控制才用衰减波形；清脆档（auto）与非振幅
        // 控制设备一律短脉冲 —— 衰减尾音在马达上会拖成"嗡嗡"声（真机实测反馈）
        val useSmooth = hasAmplitudeControl && waveform == "smooth"
        return if (useSmooth) buildSmooth(amp01) else buildPulse(amp01)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun buildPulse(amp01: Double): VibrationEffect =
        VibrationEffect.createOneShot(pulseMs.toLong(), ampToLevel(amp01))

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun buildSmooth(amp01: Double): VibrationEffect {
        val stepMs = 10
        val decaySteps = (decayMs / stepMs).coerceAtLeast(1)
        val times = ArrayList<Long>(decaySteps + 1)
        val amps = ArrayList<Int>(decaySteps + 1)

        times.add(pulseMs.toLong())
        amps.add(ampToLevel(amp01))

        for (i in 1 until decaySteps) {
            val x = 1.0 - i.toDouble() / decaySteps.toDouble()
            val a = (255 * amp01 * x.pow(gamma)).toInt()
            // 振幅归零就截断：部分实现会忽略振幅为 0 的档位时长，导致整条波形被压缩
            if (a < 1) break
            times.add(stepMs.toLong())
            amps.add(a.coerceIn(1, 255))
        }

        if (times.size < 2) {
            // 衰减段全被截断（强度过低或 gamma 过大）→ 退化成短脉冲而不是空波形
            return VibrationEffect.createOneShot(pulseMs.toLong(), ampToLevel(amp01))
        }
        return VibrationEffect.createWaveform(times.toLongArray(), amps.toIntArray(), -1)
    }

    private fun ampToLevel(amp01: Double): Int =
        (255 * amp01).toInt().coerceIn(1, 255)

    private fun strike(kind: String, intensity: Double) {
        if (!enabled || !hasVibrator) return
        val v = vibrator ?: return

        // 交互避让：用户刚点过按钮，这一拍让位（入队前先判一次）
        if (suppressedByInteraction()) return

        if (!supportsEffects) {
            // API 26 以下没有 VibrationEffect，只能给固定时长的裸震动
            fire(v) {
                @Suppress("DEPRECATION")
                v.vibrate(pulseMs.toLong())
            }
            return
        }

        // 清脆档（auto）：优先走交互开关同款的预定义触感（API 29+）。
        // 不命中的（低版本 / 显式选了脉冲或平滑）落到下方波形路径。
        if (waveform != "pulse" && waveform != "smooth" && supportsPredefined) {
            val predefined = if (kind == "snare") snarePredefined else kickPredefined
            if (predefined != null) {
                fire(v) { vibrateCompat(v, predefined) }
                return
            }
        }

        val table = if (kind == "snare") snareEffects else kickEffects
        val effect = table.getOrNull(levelOf(intensity)) ?: return
        fire(v) { vibrateCompat(v, effect) }
    }

    private inline fun fire(v: Vibrator, crossinline action: () -> Unit) {
        val task = Runnable {
            try {
                // 出队时再避让一次：延迟窗口内可能又发生了交互震动，
                // 那时用户刚拿到按钮反馈，音乐震动再盖上去就本末倒置
                if (!suppressedByInteraction()) {
                    action()
                }
            } catch (t: Throwable) {
                RingLog.w(TAG, "strike failed: ${t.javaClass.simpleName}")
            }
        }
        try {
            val delay = offsetMs.toLong()
            val future = if (delay <= 0L) {
                fireExecutor.submit(task)
            } else {
                fireExecutor.schedule(task, delay, TimeUnit.MILLISECONDS)
            }
            synchronized(pendingLock) {
                pendingStrikes.removeAll { it.isDone }
                pendingStrikes.add(future)
            }
        } catch (_: RuntimeException) {
            // executor 已 shutdown（引擎重建后收到迟到的点火）→ 静默丢弃
        }
    }

    private fun suppressedByInteraction(): Boolean =
        SystemClock.elapsedRealtime() - lastInteractionAtMs < INTERACTION_SUPPRESS_MS

    /** 取消在途的延迟点火：暂停/关开关/seek 后它们本就不该再响。 */
    private fun cancelPendingStrikes() {
        synchronized(pendingLock) {
            for (f in pendingStrikes) {
                f.cancel(false)
            }
            pendingStrikes.clear()
        }
    }

    private fun vibrateCompat(v: Vibrator, effect: VibrationEffect) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                val attr = VibrationAttributes.Builder()
                    .setUsage(VibrationAttributes.USAGE_MEDIA)
                    .build()
                v.vibrate(effect, attr)
            }

            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                // API 26~32 没有 VibrationAttributes，用 AudioAttributes 表达"这是媒体"
                val attr = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                v.vibrate(effect, attr)
            }

            else -> {
                @Suppress("DEPRECATION")
                v.vibrate(pulseMs.toLong())
            }
        }
    }

    private fun cancelVibration() {
        // 在途的延迟点火一并取消：暂停后几百毫秒再补一下震动是最典型的"幽灵触感"
        cancelPendingStrikes()
        val v = vibrator ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                appContext.getSystemService(VibratorManager::class.java)?.cancel()
            } else {
                v.cancel()
            }
        } catch (_: Throwable) {
            // 设备/ROM 不支持取消：长波形会自然衰减完，不阻断
        }
    }

    /** 引擎重建时调用。 */
    fun cleanup() {
        cancelVibration()
        enabled = false
        fireExecutor.shutdown()
    }
}
