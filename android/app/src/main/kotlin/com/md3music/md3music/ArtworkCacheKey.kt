package com.md3music.md3music

import java.security.MessageDigest

/** 使用完整URL的SHA-256摘要命名封面文件，避免字符串哈希碰撞串用封面。 */
internal fun artworkCacheFileName(url: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(url.toByteArray(Charsets.UTF_8))
    val digits = "0123456789abcdef"
    return buildString(digest.size * 2 + 4) {
        for (byte in digest) {
            val value = byte.toInt() and 0xff
            append(digits[value ushr 4])
            append(digits[value and 0x0f])
        }
        append(".jpg")
    }
}
