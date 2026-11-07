package com.md3music.md3music

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundedArtworkExecutorTest {
    @Test
    fun priorityCoverEvictsQueuedPrefetchWhenQueueIsFull() {
        val executor = BoundedArtworkExecutor(1, 1, threadFactory())
        val workerStarted = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        val priorityFinished = CountDownLatch(1)
        val prefetchRuns = AtomicInteger()

        try {
            assertTrue(
                executor.executePriority {
                    workerStarted.countDown()
                    releaseWorker.await(2, TimeUnit.SECONDS)
                },
            )
            assertTrue(workerStarted.await(2, TimeUnit.SECONDS))
            assertTrue(executor.executePrefetch("cover-a") { prefetchRuns.incrementAndGet() })
            assertTrue(executor.hasPendingPrefetch("cover-a"))
            assertTrue(executor.executePriority { priorityFinished.countDown() })

            assertFalse(executor.hasPendingPrefetch("cover-a"))
            assertEquals(1, executor.queuedTaskCount)
            releaseWorker.countDown()
            assertTrue(priorityFinished.await(2, TimeUnit.SECONDS))
            assertEquals(0, prefetchRuns.get())
        } finally {
            releaseWorker.countDown()
            executor.close()
        }
    }

    @Test
    fun prefetchQueueRemainsBoundedAndDuplicateKeysAreCoalesced() {
        val executor = BoundedArtworkExecutor(1, 1, threadFactory())
        val workerStarted = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        val queuedPrefetchFinished = CountDownLatch(1)

        try {
            assertTrue(
                executor.executePriority {
                    workerStarted.countDown()
                    releaseWorker.await(2, TimeUnit.SECONDS)
                },
            )
            assertTrue(workerStarted.await(2, TimeUnit.SECONDS))
            assertTrue(executor.executePrefetch("cover-a") { queuedPrefetchFinished.countDown() })
            assertFalse(executor.executePrefetch("cover-a") {})
            assertFalse(executor.executePrefetch("cover-b") {})
            assertEquals(1, executor.queuedTaskCount)

            releaseWorker.countDown()
            assertTrue(queuedPrefetchFinished.await(2, TimeUnit.SECONDS))
            assertTrue(
                awaitCondition(2, TimeUnit.SECONDS) {
                    !executor.hasPendingPrefetch("cover-a")
                },
            )
            assertFalse(executor.hasPendingPrefetch("cover-a"))
        } finally {
            releaseWorker.countDown()
            executor.close()
        }
    }

    private fun threadFactory() = java.util.concurrent.ThreadFactory { runnable ->
        Thread(runnable, "artwork-executor-test").apply { isDaemon = true }
    }

    private fun awaitCondition(
        timeout: Long,
        unit: TimeUnit,
        condition: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + unit.toNanos(timeout)
        while (!condition() && System.nanoTime() < deadline) {
            Thread.sleep(1)
        }
        return condition()
    }
}
