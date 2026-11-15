package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CancellableMainThreadTaskTest {
    @Test
    fun timeoutCancelsQueuedCallbackBeforeItCanCreateResources() {
        val task = CancellableMainThreadTask()
        var createCount = 0

        assertTrue(task.cancel())
        assertFalse(task.run { createCount++ })

        assertEquals(0, createCount)
        assertTrue(task.isCancelled)
        assertFalse(task.isCommitted)
    }

    @Test
    fun timeoutCancelsRunningRequestBeforeResourcePublication() {
        val task = CancellableMainThreadTask()
        var createCount = 0
        var published = false

        assertTrue(
            task.run {
                createCount++
                assertTrue(task.cancel())
                published = task.commit()
            },
        )

        assertEquals(1, createCount)
        assertFalse(published)
        assertTrue(task.isCancelled)
        assertFalse(task.isCommitted)
    }

    @Test
    fun concurrentTimeoutWinsBeforeCreationCommit() {
        val task = CancellableMainThreadTask()
        val creationStarted = CountDownLatch(1)
        val allowCommit = CountDownLatch(1)
        var committed = false
        val worker = Thread {
            task.run {
                creationStarted.countDown()
                allowCommit.await()
                committed = task.commit()
            }
        }

        worker.start()
        assertTrue(creationStarted.await(2, TimeUnit.SECONDS))
        assertTrue(task.cancel())
        allowCommit.countDown()
        worker.join(2_000)

        assertFalse(worker.isAlive)
        assertFalse(committed)
        assertTrue(task.isCancelled)
    }

    @Test
    fun committedRequestCannotBeCancelledAsATimeout() {
        val task = CancellableMainThreadTask()

        assertTrue(task.run { assertTrue(task.commit()) })

        assertTrue(task.isCommitted)
        assertFalse(task.cancel())
    }
}
