package com.md3music.md3music

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 导出当前应用进程的 Android 原生日志，供诊断报告收集。 */
class DiagnosticLogPlugin(private val context: Context) {
    companion object {
        private const val TAG = "DiagnosticLog"
        private const val CHANNEL = "com.md3music.md3music/diagnostic_log"
        private const val MAX_OUTPUT_CHARS = 2 * 1024 * 1024
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "getAndroidLogs") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val mainHandler = Handler(Looper.getMainLooper())
                Thread {
                    // MD3Music fork（稳定性修复）：整个线程体 runCatching 兜底——裸线程
                    // 的未捕获异常会走默认 handler 杀掉整个进程。
                    val merged = runCatching {
                        // 环形缓冲优先：零 IO、零权限依赖，任何 ROM/时机都有内容。
                        // logcat 退化为「尽力而为」的补充（Android 10+ READ_LOGS 收紧后
                        // 曾多次整份缺失，导致诊断包无据可查）。
                        val ringText = RingLog.ring.render(maxChars = MAX_OUTPUT_CHARS)
                        val logcatText = runCatching { readLogcat() }.getOrElse { error ->
                            Log.w(TAG, "读取 Android 日志失败", error)
                            ""
                        }
                        buildString {
                            append("===== 进程内环形日志（cap=")
                            append(NativeLogBuffer.DEFAULT_CAPACITY)
                            append("） =====\n")
                            append(ringText)
                            append("\n\n===== 历史进程退出记录 =====\n")
                            append(readProcessExitHistory())
                            append("\n\n===== UID 可见的 crash 缓冲（不按当前 PID 过滤） =====\n")
                            append(runCatching { readLogcat(crashBuffer = true) }.getOrElse { "crash 日志不可用: ${it.javaClass.simpleName}" })
                            if (logcatText.isNotEmpty()) {
                                append("\n\n===== logcat（尽力而为） =====\n")
                                append(logcatText)
                            }
                        }
                    }.getOrElse { error ->
                        Log.e(TAG, "收集 Android 原生日志失败", error)
                        null
                    }
                    // MD3Music fork（稳定性修复）：MethodChannel.Result 必须回主线程调用
                    // （debug/profile 下 FlutterJNI 的 @UiThread 断言会抛 IllegalStateException），
                    // 与同仓库其他插件的 mainHandler.post 惯例一致。
                    mainHandler.post {
                        if (merged != null) result.success(merged)
                        else result.error("COLLECT_FAILED", "收集 Android 原生日志失败", null)
                    }
                }.start()
            }
    }

    private fun readProcessExitHistory(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "系统低于 Android 11，无历史退出 API"
        return runCatching {
            val manager = context.getSystemService(ActivityManager::class.java)
                ?: return@runCatching "ActivityManager 不可用"
            val records = manager.getHistoricalProcessExitReasons(context.packageName, 0, 8)
            if (records.isEmpty()) return@runCatching "系统未返回本应用的历史退出记录"
            records.joinToString("\n") { record ->
                "timestamp=${record.timestamp} pid=${record.pid} process=${record.processName} " +
                    "reason=${record.reason} status=${record.status} importance=${record.importance} " +
                    "pssKb=${record.pss} rssKb=${record.rss} description=${record.description}"
            }
        }.getOrElse { "历史退出记录不可用: ${it.javaClass.simpleName}: ${it.message}" }
    }

    private fun readLogcat(crashBuffer: Boolean = false): String {
        val command = mutableListOf("logcat", "-d", "-v", "threadtime", "-t", "4000")
        if (crashBuffer) {
            command.addAll(listOf("-b", "crash"))
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            command.add("--pid=${Process.myPid()}")
        }
        val process = ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        return if (output.length > MAX_OUTPUT_CHARS) {
            "[日志过长，仅保留最后 $MAX_OUTPUT_CHARS 个字符]\n" +
                output.takeLast(MAX_OUTPUT_CHARS)
        } else {
            output
        }
    }
}
