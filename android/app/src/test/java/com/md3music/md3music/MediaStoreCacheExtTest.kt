package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 本地音乐 content:// 兜底缓存的扩展名推断与完整性判定。
 *
 * 背景（issue #249 排查实证）：旧 `guessExt` 在 MIME 为 null 或
 * `application/octet-stream` 时一律返回 "mp3"，实测把 `.m4a` 源文件
 * 缓存成 `<hash>.mp3`（日志：`local_music_cache/-1307805213.mp3` 对应
 * `邓紫棋 - 11.m4a`）。字节流不受影响（Media3 靠嗅探选解复用器），
 * 但音质/编码显示会被误导。
 */
class MediaStoreCacheExtTest {

    @Test
    fun mimeWinsOverMisleadingFileName() {
        // MIME 来自系统解码器注册表，比扩展名可信
        assertEquals("m4a", MediaStoreScanner.extensionFor("audio/mp4", "song.mp3"))
        assertEquals("flac", MediaStoreScanner.extensionFor("audio/flac", "song.mp3"))
        assertEquals("ogg", MediaStoreScanner.extensionFor("audio/ogg", "song.mp3"))
        assertEquals("wav", MediaStoreScanner.extensionFor("audio/wav", "song.mp3"))
        assertEquals("mp3", MediaStoreScanner.extensionFor("audio/mpeg", "song.m4a"))
    }

    @Test
    fun m4aMimeKeepsRealExtensionInsteadOfFallingBackToMp3() {
        // 这是本次修复的核心：m4a 不再被命名成 .mp3
        assertEquals("m4a", MediaStoreScanner.extensionFor("audio/mp4", "邓紫棋 - 11.m4a"))
        assertEquals("m4a", MediaStoreScanner.extensionFor("audio/x-m4a", "a.m4a"))
        assertEquals("m4a", MediaStoreScanner.extensionFor("audio/aac", "a.aac"))
    }

    @Test
    fun missingOrUnknownMimeFallsBackToRealFileNameExtension() {
        // 旧实现在这里返回 "mp3"，是 m4a 被误命名的根因
        assertEquals("m4a", MediaStoreScanner.extensionFor(null, "邓紫棋 - 11.m4a"))
        assertEquals("m4a", MediaStoreScanner.extensionFor("application/octet-stream", "a.m4a"))
        assertEquals("flac", MediaStoreScanner.extensionFor(null, "x.flac"))
        assertEquals("opus", MediaStoreScanner.extensionFor(null, "x.opus"))
    }

    @Test
    fun keepsMp3FallbackWhenNothingUsable() {
        // 最后一级兜底保持旧行为，避免无 MIME 且无文件名时产生空扩展名
        assertEquals("mp3", MediaStoreScanner.extensionFor(null, null))
        assertEquals("mp3", MediaStoreScanner.extensionFor(null, "no-extension"))
        assertEquals("mp3", MediaStoreScanner.extensionFor("application/octet-stream", "x.txt"))
    }

    @Test
    fun cacheIsRejectedWhenTruncated() {
        // 旧实现只判 length>0，截断文件会被永久复用（m4a 的 moov 常在尾部）
        assertFalse(MediaStoreScanner.isCachedFileComplete(true, 1000L, 5000L))
    }

    @Test
    fun cacheIsAcceptedWhenCompleteOrLarger() {
        assertTrue(MediaStoreScanner.isCachedFileComplete(true, 5000L, 5000L))
        // SIZE 不可信偏高时，完整拷贝不能被误判（否则每次播放都重拷整首）
        assertTrue(MediaStoreScanner.isCachedFileComplete(true, 5000L, 3000L))
    }

    @Test
    fun cacheIsRejectedWhenEmptyOrMissing() {
        assertFalse(MediaStoreScanner.isCachedFileComplete(false, 0L, 5000L))
        assertFalse(MediaStoreScanner.isCachedFileComplete(true, 0L, 5000L))
    }

    @Test
    fun unknownExpectedSizeOnlyRequiresNonEmpty() {
        // 拿不到 SIZE 时退化为旧行为，不能因此放弃缓存
        assertTrue(MediaStoreScanner.isCachedFileComplete(true, 1L, null))
        assertTrue(MediaStoreScanner.isCachedFileComplete(true, 1L, 0L))
        assertFalse(MediaStoreScanner.isCachedFileComplete(true, 0L, null))
    }
}
