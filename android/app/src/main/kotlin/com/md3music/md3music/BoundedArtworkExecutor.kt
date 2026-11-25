package com.md3music.md3music

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** 有界封面任务队列；关键封面注入可让位于尚未开始的低优先级预取。 */
internal class BoundedArtworkExecutor(
    workerCount: Int,
    queueCapacity: Int,
    threadFactory: ThreadFactory,
) : AutoCloseable {
    private val admissionLock = Any()
    private val pendingPrefetches = ConcurrentHashMap.newKeySet<String>()
    private val executor = ThreadPoolExecutor(
        workerCount,
        workerCount,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(queueCapacity),
        threadFactory,
        ThreadPoolExecutor.AbortPolicy(),
    )

    init {
        require(workerCount > 0) { "workerCount must be positive" }
        require(queueCapacity > 0) { "queueCapacity must be positive" }
    }

    /** 相同URL只允许一个排队或执行中的低优先级预取。 */
    fun executePrefetch(key: String, action: () -> Unit): Boolean =
        synchronized(admissionLock) {
            if (!pendingPrefetches.add(key)) return false
            val task = PrefetchTask(key, action, pendingPrefetches)
            try {
                executor.execute(task)
                true
            } catch (_: RejectedExecutionException) {
                task.discard()
                false
            }
        }

    /** 队列满时先丢弃一项尚未开始的预取，再接纳当前封面注入。 */
    fun executePriority(action: () -> Unit): Boolean = synchronized(admissionLock) {
        val task = Runnable(action)
        try {
            executor.execute(task)
            true
        } catch (_: RejectedExecutionException) {
            val queuedPrefetch = executor.queue.firstOrNull { it is PrefetchTask }
            if (queuedPrefetch != null && executor.remove(queuedPrefetch)) {
                (queuedPrefetch as PrefetchTask).discard()
            }
            try {
                // 工作者可能刚好取走了预取任务，让队列腾出了空间；此时仍重试关键任务。
                executor.execute(task)
                true
            } catch (_: RejectedExecutionException) {
                false
            }
        }
    }

    internal fun hasPendingPrefetch(key: String): Boolean =
        pendingPrefetches.contains(key)

    internal val queuedTaskCount: Int
        get() = executor.queue.size

    override fun close() {
        executor.shutdownNow().forEach { task ->
            if (task is PrefetchTask) task.discard()
        }
    }

    private class PrefetchTask(
        private val key: String,
        private val action: () -> Unit,
        private val pendingKeys: MutableSet<String>,
    ) : Runnable {
        private val claimed = AtomicBoolean(false)

        override fun run() {
            if (!claimed.compareAndSet(false, true)) return
            try {
                action()
            } finally {
                pendingKeys.remove(key)
            }
        }

        fun discard() {
            if (claimed.compareAndSet(false, true)) pendingKeys.remove(key)
        }
    }
}
