package com.md3music.md3music

/**
 * 进程内内存环形日志。
 *
 * 动机：Android 10+ 对 `READ_LOGS` 收紧后，`DiagnosticLogPlugin` 靠
 * `logcat -d --pid=<own>` 抓日志在部分 ROM/时机下拿不到任何输出，
 * 诊断包里的 `android.log` 直接缺失，出问题时无据可依。
 *
 * 这里做一份**零 IO、零权限依赖**的进程内副本：关键路径写日志时同时进这个环，
 * 导出诊断报告时优先读它，logcat 退化为「尽力而为」的补充。
 */
internal class NativeLogBuffer(val capacity: Int = DEFAULT_CAPACITY) {

    companion object {
        const val DEFAULT_CAPACITY = 3000
    }

    private val lock = Any()
    private val lines = ArrayDeque<String>(capacity)

    val size: Int
        get() = synchronized(lock) { lines.size }

    fun append(line: String) {
        synchronized(lock) {
            if (lines.size >= capacity) lines.removeFirst()
            lines.addLast(line)
        }
    }

    fun clear() {
        synchronized(lock) { lines.clear() }
    }

    /** 清空后把 [notice] 作为第一行留下，便于在诊断包里看出「这里被清过」。 */
    fun clearWithNotice(notice: String) {
        synchronized(lock) {
            lines.clear()
            lines.addLast(notice)
        }
    }

    fun snapshot(): List<String> = synchronized(lock) { lines.toList() }

    fun render(maxChars: Int = 0): String {
        val text = snapshot().joinToString("\n")
        if (maxChars <= 0 || text.length <= maxChars) return text
        return "[日志过长，仅保留最后 $maxChars 个字符]\n" + text.takeLast(maxChars)
    }
}
