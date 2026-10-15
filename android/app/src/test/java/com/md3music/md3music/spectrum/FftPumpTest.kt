package com.md3music.md3music.spectrum

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FftPumpTest {

    @Test
    fun runsSubmittedTaskOnWorkerThread() {
        val pump = FftPump("SpectrumFFT-Test")
        try {
            val done = CountDownLatch(1)
            var workerName = ""
            val accepted = pump.submit(1L, { 1L }) {
                workerName = Thread.currentThread().name
                done.countDown()
            }
            assertTrue(accepted)
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals("SpectrumFFT-Test", workerName)
        } finally {
            pump.shutdown()
        }
    }

    @Test
    fun dropsFrameWhilePreviousOneIsStillRunning() {
        val pump = FftPump()
        try {
            val release = CountDownLatch(1)
            val started = CountDownLatch(1)
            val firstDone = CountDownLatch(1)
            val executed = AtomicInteger(0)

            assertTrue(pump.submit(1L, { 1L }) {
                started.countDown()
                release.await(2, TimeUnit.SECONDS)
                executed.incrementAndGet()
                firstDone.countDown()
            })
            assertTrue(started.await(2, TimeUnit.SECONDS))

            // 第一帧仍在跑 → 后续提交必须被丢弃，而不是排队积压
            assertFalse(pump.submit(1L, { 1L }) { executed.incrementAndGet() })
            assertFalse(pump.submit(1L, { 1L }) { executed.incrementAndGet() })

            release.countDown()
            assertTrue(firstDone.await(2, TimeUnit.SECONDS))
            assertEquals(1, executed.get())

            // 上一帧结束后又能接活
            val second = CountDownLatch(1)
            assertTrue(pump.submit(1L, { 1L }) { executed.incrementAndGet(); second.countDown() })
            assertTrue(second.await(2, TimeUnit.SECONDS))
            assertEquals(2, executed.get())
        } finally {
            pump.shutdown()
        }
    }

    @Test
    fun rejectsStaleGenerationWithoutExecuting() {
        val pump = FftPump()
        try {
            val executed = AtomicInteger(0)
            val accepted = pump.submit(7L, { 8L }) { executed.incrementAndGet() }
            assertFalse(accepted)
            Thread.sleep(100)
            assertEquals(0, executed.get())
        } finally {
            pump.shutdown()
        }
    }

    @Test
    fun skipsExecutionIfGenerationAdvancesBeforeWorkerStarts() {
        // 真实竞态：submit 已置 inFlight 且任务入队，但 worker 还没开跑；
        // 此刻主线程 stopAll() 推进了代际 → 这一帧必须被跳过而不是发布出去。
        // 用「第一次调用返回 1（过 submit 检查）、第二次返回 2（过不了 execute 检查）」
        // 的假代际源把这个窗口钉死。
        val pump = FftPump()
        try {
            val calls = AtomicInteger(0)
            val executed = AtomicInteger(0)
            val generationSource = { if (calls.getAndIncrement() == 0) 1L else 2L }

            val accepted = pump.submit(1L, generationSource) { executed.incrementAndGet() }
            assertTrue(accepted)

            // 等 worker 真的跑过一遍（无论是否执行 task 体）
            val deadline = System.currentTimeMillis() + 2000
            while (calls.get() < 2 && System.currentTimeMillis() < deadline) {
                Thread.sleep(10)
            }
            assertEquals(2, calls.get())
            assertEquals(0, executed.get())
        } finally {
            pump.shutdown()
        }
    }

    @Test
    fun shutdownMakesLaterSubmissionsFailInsteadOfThrowing() {
        val pump = FftPump()
        pump.shutdown()
        assertFalse(pump.submit(1L, { 1L }) { })
        assertFalse(pump.submit(2L, { 2L }) { })
    }

    @Test
    fun workerThreadIsDaemonSoItNeverBlocksProcessExit() {
        val pump = FftPump()
        try {
            val done = CountDownLatch(1)
            var daemon = false
            pump.submit(1L, { 1L }) {
                daemon = Thread.currentThread().isDaemon
                done.countDown()
            }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertTrue(daemon)
        } finally {
            pump.shutdown()
        }
    }

    @Test
    fun ensureAliveRevivesShutdownPumpSoSubmissionsFlowAgain() {
        val pump = FftPump()
        try {
            pump.shutdown()
            assertTrue(pump.isShutdown)
            assertFalse(pump.submit(1L, { 1L }) { })

            // 僵尸实例被重新 start 时必须自我复活：复活（重建执行器）返回 true，之后再调为 no-op 返回 false
            assertTrue(pump.ensureAlive())
            assertFalse(pump.ensureAlive())
            assertFalse(pump.isShutdown)

            val done = CountDownLatch(1)
            assertTrue(pump.submit(2L, { 2L }) { done.countDown() })
            assertTrue(done.await(2, TimeUnit.SECONDS))
        } finally {
            pump.shutdown()
        }
    }
}
