package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LatestMediaCommandQueueTest {
    @Test
    fun newerCommandReplacesPendingAndDoesNotGetErasedByFailedOlderCommand() {
        val queue = LatestMediaCommandQueue()
        assertTrue(queue.offer("play"))
        val first = queue.take()!!
        assertFalse(queue.offer("next"))
        queue.requeueIfEmpty(first)
        val latest = queue.take()!!
        assertEquals("next", latest.method)
        assertNotEquals(first.id, latest.id)
    }

    @Test
    fun retryKeepsOriginalIdUnlessNewerCommandArrives() {
        val queue = LatestMediaCommandQueue()
        assertTrue(queue.offer("pause"))
        val command = queue.take()!!
        queue.requeueIfEmpty(command)
        val retry = queue.take()!!
        assertEquals(command.id, retry.id)

        assertFalse(queue.offer("previous"))
        queue.requeueIfEmpty(retry)
        assertEquals("previous", queue.take()!!.method)
    }

    @Test
    fun finishDispatchAndOfferCannotLoseWakeup() {
        val queue = LatestMediaCommandQueue()
        assertTrue(queue.offer("play"))
        assertNotNull(queue.take())
        assertFalse(queue.finishDispatch())
        assertTrue(queue.offer("next"))
        assertNotNull(queue.take())
        assertNull(queue.take())
    }

    @Test
    fun boundedFailureCanDropOnlyItsOwnPendingCommand() {
        val queue = LatestMediaCommandQueue()
        assertTrue(queue.offer("play"))
        val failed = queue.take()!!
        assertFalse(queue.offer("next"))
        queue.dropIfPending(failed.id)
        assertEquals("next", queue.take()!!.method)
    }

    @Test
    fun commandIdsAreUniqueAcrossServiceQueueInstances() {
        val firstQueue = LatestMediaCommandQueue()
        val secondQueue = LatestMediaCommandQueue()
        assertTrue(firstQueue.offer("play"))
        assertTrue(secondQueue.offer("pause"))

        assertNotEquals(firstQueue.take()!!.id, secondQueue.take()!!.id)
    }
}
