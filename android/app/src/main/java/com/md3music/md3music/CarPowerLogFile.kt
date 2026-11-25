package com.md3music.md3music

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 车机下电取证专用落盘日志（`files/diagnostic_logs/car_power.log`）。
 *
 * 动机：CarPower 信号到达 / 派发结果此前只写 [RingLog] 的**进程内存环形**，
 * 而本功能最需要留痕的时刻（熄火断电）恰好是内存缓冲必然灭失的时刻——
 * 用户"下车没暂停"后再导诊断包，环形里只有新进程的记录，断电瞬间永远无据可查
 * （2026-11-05 诊断包实证，见 docs 报告结论 #3）。
 *
 * 所以单独开一条**逐行 append + flush + fd.sync** 的文件通道：
 * - 目录取 `filesDir/diagnostic_logs`：path_provider 的 getApplicationSupportDirectory
 *   在 Android 即 filesDir，与 Dart 侧 DiagnosticLogger 同目录；
 *   「导出诊断日志」本来就打包该目录全部文件，无需改导出侧。
 * - 每次写入立即 sync 到闪存：ACTION_SHUTDOWN 后进程随时可能被杀，
 *   页缓存里的内容可能随掉电丢失，sync 是证据能留下的前提。
 * - 事件频度极低（熄火一次 ≤5 行），sync 的毫秒级开销可接受；
 *   禁止把高频日志接进来。
 * - 任何失败静默吞掉：取证通道不得影响播放主流程。
 */
object CarPowerLogFile {

    private const val FILE_NAME = "car_power.log"

    /** 单文件上限：超限截断重写（保留尾部），防止极端情况无限增长。 */
    private const val MAX_FILE_BYTES = 64L * 1024

    private val formatter = ThreadLocal.withInitial {
        SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    }

    /**
     * 纯函数：拼一行 `[时间] 消息`。与 Android 无关，JVM 单测覆盖。
     */
    fun renderLine(timestamp: String, message: String): String =
        "[$timestamp] $message\n"

    /**
     * 纯函数核心：往 [dir]/car_power.log 追加 [text]，超限先截半。
     * 与 Android 无关，JVM 单测直接注入临时目录。
     */
    fun appendToFile(dir: File, text: String) {
        try {
            if (!dir.exists() && !dir.mkdirs()) return
            val file = File(dir, FILE_NAME)
            if (file.length() > MAX_FILE_BYTES) {
                // 保留后半段，滚动成本最低且不丢最近的熄火证据
                val keep = file.readBytes()
                val tail = keep.copyOfRange(
                    (keep.size / 2).coerceAtMost(keep.size), keep.size
                )
                file.writeBytes(tail)
            }
            FileOutputStream(file, true).use { fos ->
                fos.write(text.toByteArray(Charsets.UTF_8))
                fos.flush()
                try {
                    fos.fd.sync()
                } catch (_: Exception) {
                    // 部分 ROM 上 sync 可能抛 ENOSYS/IO：数据已在页缓存，尽力而为
                }
            }
        } catch (_: Exception) {
            // 取证失败绝不影响主流程
        }
    }

    /**
     * 服务侧入口：写一行并带上进程启动以来秒数（可与 RingLog 的
     * elapsedRealtime 对时）。在广播接收线程同步执行——断电抢时效，
     * 不切线程、不排队。
     */
    fun write(context: Context, message: String) {
        val line = renderLine(formatter.get()!!.format(Date()), message)
        appendToFile(File(context.filesDir, "diagnostic_logs"), line)
    }
}
