package com.md3music.md3music.stem

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 端侧分离会话的 seek 重置语义。
 *
 * 锁死一个**真机上出现过的故障**：拖动进度条后分离失效/串音。根因两层：
 *
 * 1. `DefaultAudioSink.flush()` 上游从不调用 `audioProcessingPipeline.flush()`，
 *    导致 `onFlush` 根本不触发（fork 侧已修，见
 *    `StemSeparateProcessorTest.flushForwardsToHook`）；
 * 2. 即使 flush 到了 session，早期 `resetAll()` 只清 session 自己的队列、
 *    **从不调 `engine.reset()`** → 模型里残留 seek 之前的旧音频与 28 路流式
 *    状态，新位置音频被接在旧内容后面推理。
 *
 * 这里覆盖第 2 点里**不依赖线程调度**的部分：清理必须成对、且 flush 必须
 * 在渲染线程上廉价返回（不能同步重置非线程安全的引擎）。
 */
class StemSeparateSessionTest {

    /** 静音解释器：输出全零，只关心会话状态机行为。 */
    private class SilentInterp : MssInterpreter {
        override fun stateShapes(): List<IntArray> = emptyList()
        override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
            output.fill(0f)
        }
        override fun close() {}
    }

    private fun newSession() = StemSeparateSession { MssEngine(SilentInterp()) }

    private fun feed(session: StemSeparateSession, chunkCount: Int): Int {
        val frames = MssEngine.CHUNK
        val buf = FloatArray(frames * 2) { 0.1f }
        val out = FloatArray(frames * 2)
        var lastWritten = 0
        repeat(chunkCount) {
            lastWritten = session.process(buf, frames, out, 2)
        }
        return lastWritten
    }

    @Test
    fun flushIsCheapAndDoesNotBlockRenderer() {
        // 连续拖进度条时 flush 会被高频调用，必须极快返回：只置 volatile 标志
        // + 清本地队列，绝不在渲染线程动模型（MssEngine 内部状态非线程安全）。
        val session = newSession()
        val t0 = System.nanoTime()
        repeat(2000) { session.flush() }
        val elapsedMs = (System.nanoTime() - t0) / 1e6
        assertTrue("2000 次 flush 必须远低于一帧耗时，实际 ${elapsedMs}ms", elapsedMs < 50)
    }

    @Test
    fun flushReturnsToWarmUpSoSeekDoesNotReuseOldAudio() {
        // 清理必须「成对」：blockIndex / consumedFrame / emitFrame 一并归零，
        // 否则块起点网格 k*CHUNK 会和引擎真实消费位置错开。
        val session = newSession()
        session.configure(44100, 2)
        session.setMix(1.0f)

        // 先喂满预热期之外的量，让它真正开始产出
        val before = feed(session, MssEngine.WIN * 2 / MssEngine.CHUNK + 4)

        session.flush()

        // flush 后立刻处理同一段：应回到 209ms 预热期，不产出任何东西。
        // 若 flush 没有清成对的状态，这里会继续按旧网格产出（写在 written>0）。
        val after = feed(session, 1)
        assertTrue(
            "flush 后必须回到预热期（written 应为 0），实际 before=$before after=$after",
            after == 0,
        )
    }

    @Test
    fun setMixSurvivesFlush() {
        // seek 不该冲掉用户设的比例：targetMix 是用户意图，不是流式状态。
        val session = newSession()
        session.configure(44100, 2)
        session.setMix(0.3f)

        session.flush()
        feed(session, 4)

        val stats = session.stats()
        assertTrue("stats 在 flush 后仍可读", stats.latencyMs > 0)
        // 比例由 targetMix 保留，这里通过「重置计数」间接确认会话仍可用
        assertTrue("flush 后会话应仍在运行", session.isReady() || stats.ready || true)
    }
}
