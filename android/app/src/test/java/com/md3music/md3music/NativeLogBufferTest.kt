package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeLogBufferTest {

    @Test
    fun keepsInsertionOrderBelowCapacity() {
        val buffer = NativeLogBuffer(capacity = 8)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")
        assertEquals(3, buffer.size)
        assertEquals(listOf("a", "b", "c"), buffer.snapshot())
    }

    @Test
    fun dropsOldestEntriesWhenOverCapacity() {
        val buffer = NativeLogBuffer(capacity = 3)
        for (i in 1..5) buffer.append("line$i")
        assertEquals(3, buffer.size)
        assertEquals(listOf("line3", "line4", "line5"), buffer.snapshot())
    }

    @Test
    fun clearEmptiesTheBuffer() {
        val buffer = NativeLogBuffer(capacity = 4)
        buffer.append("a")
        buffer.clear()
        assertEquals(0, buffer.size)
        assertTrue(buffer.snapshot().isEmpty())
    }

    @Test
    fun clearWithNoticeKeepsTheNoticeAsFirstLine() {
        val buffer = NativeLogBuffer(capacity = 4)
        buffer.append("old")
        buffer.clearWithNotice("[日志已清空]")
        buffer.append("new")
        assertEquals(listOf("[日志已清空]", "new"), buffer.snapshot())
    }

    @Test
    fun rendersAsNewlineJoinedText() {
        val buffer = NativeLogBuffer(capacity = 4)
        buffer.append("first")
        buffer.append("second")
        assertEquals("first\nsecond", buffer.render())
    }

    @Test
    fun renderOnEmptyBufferReturnsEmptyString() {
        assertEquals("", NativeLogBuffer(capacity = 4).render())
    }

    @Test
    fun trimLimitsRenderedCharactersKeepingTheTail() {
        val buffer = NativeLogBuffer(capacity = 10)
        buffer.append("0123456789")
        val trimmed = buffer.render(maxChars = 4)
        assertTrue(trimmed.endsWith("6789"))
        assertTrue(trimmed.startsWith("[日志过长"))
    }

    @Test
    fun concurrentAppendsDoNotLoseOrCorruptEntries() {
        val buffer = NativeLogBuffer(capacity = 10_000)
        val threads = (1..4).map { t ->
            Thread {
                for (i in 1..250) buffer.append("t$t-$i")
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertEquals(1_000, buffer.size)
    }

    @Test
    fun defaultCapacityMatchesTheDocumentedValue() {
        assertEquals(3000, NativeLogBuffer.DEFAULT_CAPACITY)
    }
}
