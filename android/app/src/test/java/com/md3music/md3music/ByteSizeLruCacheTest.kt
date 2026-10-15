package com.md3music.md3music

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ByteSizeLruCacheTest {
    private data class Value(val label: String, val bytes: Int)

    @Test
    fun accessMovesEntryToMostRecentlyUsedPosition() {
        val cache = ByteSizeLruCache<String, Value>(10) { it.bytes }
        val first = Value("first", 4)
        val second = Value("second", 4)
        val third = Value("third", 4)
        cache.put("first", first)
        cache.put("second", second)

        assertSame(first, cache.get("first"))
        cache.put("third", third)

        assertSame(first, cache.get("first"))
        assertNull(cache.get("second"))
        assertSame(third, cache.get("third"))
        assertEquals(8L, cache.sizeBytes)
    }

    @Test
    fun replacementUpdatesByteAccountingAndOversizedEntryIsNotCached() {
        val cache = ByteSizeLruCache<String, Value>(10) { it.bytes }
        val original = Value("original", 7)
        val replacement = Value("replacement", 3)
        cache.put("same", original)
        assertSame(original, cache.put("same", replacement))
        assertEquals(3L, cache.sizeBytes)

        cache.put("large", Value("large", 11))

        assertSame(replacement, cache.get("same"))
        assertNull(cache.get("large"))
        assertEquals(3L, cache.sizeBytes)
    }

    @Test
    fun concurrentReadsAndWritesKeepBudgetAndAccountingConsistent() {
        val cache = ByteSizeLruCache<Int, Value>(128) { it.bytes }
        val pool = Executors.newFixedThreadPool(8)
        try {
            val tasks = (0 until 8).map { worker ->
                pool.submit {
                    repeat(500) { index ->
                        val key = worker * 500 + index
                        cache.put(key, Value("$key", 8))
                        cache.get(key)
                        cache.remove(key - 4)
                    }
                }
            }
            tasks.forEach { it.get(10, TimeUnit.SECONDS) }

            assertTrue(cache.sizeBytes in 0L..128L)
            assertEquals(0L, cache.sizeBytes % 8L)
        } finally {
            pool.shutdownNow()
        }
    }
}
