package com.md3music.md3music

import java.util.concurrent.atomic.AtomicInteger

/**
 * 主线程任务在调用方超时后可能仍排在消息队列中。
 * 该状态门控阻止尚未执行的迟到任务，并让正在创建的任务在发布资源前可取消。
 */
internal class CancellableMainThreadTask {
    private val state = AtomicInteger(QUEUED)

    val isCancelled: Boolean
        get() = state.get() == CANCELLED

    fun run(block: () -> Unit): Boolean {
        if (!state.compareAndSet(QUEUED, RUNNING)) return false
        try {
            block()
        } finally {
            state.compareAndSet(RUNNING, FINISHED)
            state.compareAndSet(COMMITTED, COMMITTED_FINISHED)
        }
        return true
    }

    /** 取消尚未提交的排队/执行任务；已经提交的操作不能回滚。 */
    fun cancel(): Boolean {
        while (true) {
            when (val current = state.get()) {
                QUEUED, RUNNING -> if (state.compareAndSet(current, CANCELLED)) {
                    return true
                }
                else -> return false
            }
        }
    }

    /** 原子确认任务在截止时间内完成资源创建，可以继续启动入口。 */
    fun commit(): Boolean = state.compareAndSet(RUNNING, COMMITTED)

    val isCommitted: Boolean
        get() = state.get() == COMMITTED || state.get() == COMMITTED_FINISHED

    private companion object {
        const val QUEUED = 0
        const val RUNNING = 1
        const val COMMITTED = 2
        const val CANCELLED = 3
        const val FINISHED = 4
        const val COMMITTED_FINISHED = 5
    }
}
