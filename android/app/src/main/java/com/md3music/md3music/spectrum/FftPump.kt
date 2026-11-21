package com.md3music.md3music.spectrum

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 把 FFT 从 ExoPlayer 渲染线程搬到专用线程。
 *
 * 丢帧策略：上一帧还没算完就丢弃本帧（`compareAndSet` 失败即丢）。
 * 频谱少一帧肉眼无感，但渲染线程被阻塞会直接造成 AudioTrack 欠载（爆音）。
 *
 * 代际门控：`currentGeneration` 由调用方注入（通常是 plugin 的 `@Volatile` 计数器）。
 * 停止/重启频谱后旧帧不得再发布 —— 检查发生在**入队前**与**执行前**两处。
 *
 * 可复活：引擎换注册会 cleanup 旧 plugin（shutdown 本泵），但旧引擎 MethodChannel 上的
 * handler 不会解绑，僵尸实例仍会响应 Dart 的 `start` 并重新注册 PCM 监听——此时若不复活
 * 泵，帧投递静默死亡且永不自愈（2026-10-04 真机复现根因）。`ensureAlive()` 由 plugin 在
 * 每次 `start` 时调用。
 */
internal class FftPump(private val workerName: String = "SpectrumFFT") {

    private fun newExecutor(): ExecutorService = Executors.newSingleThreadExecutor(
        ThreadFactory { r ->
            Thread(r, workerName).apply {
                priority = Thread.NORM_PRIORITY
                isDaemon = true
            }
        }
    )

    @Volatile
    private var executor: ExecutorService = newExecutor()

    private val inFlight = AtomicBoolean(false)

    @Volatile
    private var stopped = false

    /** 当前是否处于已关闭状态（供 stats 诊断）。 */
    val isShutdown: Boolean get() = stopped

    /**
     * 复活已 shutdown 的泵。真正发生重建时返回 true（调用方据此打告警日志），
     * 未关闭时是 no-op 返回 false。
     */
    fun ensureAlive(): Boolean {
        synchronized(this) {
            if (!stopped) return false
            executor = newExecutor()
            stopped = false
            return true
        }
    }

    /**
     * @return true 表示任务已入队；false 表示已关闭 / 代际过期 / 上一帧仍在跑（丢帧）。
     */
    fun submit(generation: Long, currentGeneration: () -> Long, task: () -> Unit): Boolean {
        if (stopped) return false
        if (generation != currentGeneration()) return false
        if (!inFlight.compareAndSet(false, true)) return false
        // 快照执行器：与 shutdown()/ensureAlive() 的重建解耦，被拒时走 catch 丢帧。
        val sink = executor
        try {
            sink.execute {
                try {
                    if (generation == currentGeneration()) task()
                } finally {
                    inFlight.set(false)
                }
            }
        } catch (_: RuntimeException) {
            // executor 恰在此刻被 shutdownNow → RejectedExecutionException，静默降级为丢帧
            inFlight.set(false)
            return false
        }
        return true
    }

    fun shutdown() {
        val pool = synchronized(this) {
            if (stopped) return
            stopped = true
            executor
        }
        pool.shutdownNow()
    }
}
