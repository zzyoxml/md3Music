package com.md3music.md3music

import java.io.File

/** 只淘汰完整 URL 摘要命名的封面，避免并发解码期间误删临时下载文件。 */
internal object ArtworkDiskCache {
    private val artworkFileName = Regex("[0-9a-f]{64}\\.jpg")

    fun touch(file: File, timestamp: Long = System.currentTimeMillis()): Boolean =
        file.setLastModified(timestamp)

    fun trim(directory: File, maxEntries: Int) {
        require(maxEntries >= 0) { "maxEntries must not be negative" }
        val files = directory.listFiles()
            ?.filter { it.isFile && artworkFileName.matches(it.name) }
            ?: return
        if (files.size <= maxEntries) return

        files.sortedWith(compareBy<File> { it.lastModified() }.thenBy { it.name })
            .take(files.size - maxEntries)
            .forEach { it.delete() }
    }
}
