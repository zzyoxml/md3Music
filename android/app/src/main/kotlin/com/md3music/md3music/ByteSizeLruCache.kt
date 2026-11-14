package com.md3music.md3music

import java.util.LinkedHashMap

/** 按值的实际字节数限额，并在所有读写入口统一加锁的LRU缓存。 */
internal class ByteSizeLruCache<K : Any, V : Any>(
    private val maxSizeBytes: Int,
    private val sizeOf: (V) -> Int,
) {
    private data class Entry<V>(val value: V, val sizeBytes: Int)

    private val entries = LinkedHashMap<K, Entry<V>>(0, 0.75f, true)
    private var currentSizeBytes = 0L

    init {
        require(maxSizeBytes > 0) { "maxSizeBytes must be positive" }
    }

    @Synchronized
    fun get(key: K): V? = entries[key]?.value

    /** 返回被替换的旧值；超过预算的新值不常驻缓存。 */
    @Synchronized
    fun put(key: K, value: V): V? {
        val previous = entries.remove(key)
        if (previous != null) currentSizeBytes -= previous.sizeBytes

        val valueSize = sizeOf(value).coerceAtLeast(1)
        if (valueSize <= maxSizeBytes) {
            entries[key] = Entry(value, valueSize)
            currentSizeBytes += valueSize
            trimToBudget()
        }
        return previous?.value
    }

    @Synchronized
    fun remove(key: K): V? {
        val removed = entries.remove(key) ?: return null
        currentSizeBytes -= removed.sizeBytes
        return removed.value
    }

    @Synchronized
    fun clear() {
        entries.clear()
        currentSizeBytes = 0
    }

    @get:Synchronized
    val sizeBytes: Long
        get() = currentSizeBytes

    private fun trimToBudget() {
        val iterator = entries.entries.iterator()
        while (currentSizeBytes > maxSizeBytes && iterator.hasNext()) {
            val eldest = iterator.next()
            currentSizeBytes -= eldest.value.sizeBytes
            iterator.remove()
        }
    }
}
