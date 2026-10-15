package com.md3music.md3music

import android.os.SystemClock
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * `Log.*` + 进程内环形缓冲的双写门面。
 *
 * 用法约束：**只给「排查问题必须看到」的日志用**（频谱通路、USB 独占、诊断本身）。
 * 高频逐帧日志不要走这里，否则 3000 行环形缓冲几秒就被刷掉。
 */
object RingLog {

    private val buffer = NativeLogBuffer()

    private val formatter = ThreadLocal.withInitial {
        SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    }

    internal val ring: NativeLogBuffer get() = buffer

    fun i(tag: String, message: String) {
        Log.i(tag, message)
        record("I", tag, message)
    }

    fun w(tag: String, message: String) {
        Log.w(tag, message)
        record("W", tag, message)
    }

    fun e(tag: String, message: String, tr: Throwable? = null) {
        if (tr == null) Log.e(tag, message) else Log.e(tag, message, tr)
        record("E", tag, if (tr == null) message else "$message: ${tr.message}")
    }

    fun clear() = buffer.clearWithNotice("[环形日志已清空 ${timestamp()}]")

    private fun record(level: String, tag: String, message: String) {
        buffer.append("${timestamp()} $level/$tag: $message")
    }

    private fun timestamp(): String =
        formatter.get()!!.format(Date(System.currentTimeMillis())) +
            " (+${SystemClock.elapsedRealtime()}ms)"
}
