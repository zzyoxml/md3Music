package com.md3music.md3music

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtworkDiskCacheTest {
    @Test
    fun trimRemovesOldestArtworkButPreservesConcurrentDownloadTemps() {
        val directory = Files.createTempDirectory("artwork-cache-test").toFile()
        try {
            val oldest = artworkFile(directory, "https://cdn.example/old.jpg", 1_000L)
            val recent = artworkFile(directory, "https://cdn.example/recent.jpg", 2_000L)
            val active = File(directory, "cover-in-progress.download").apply {
                writeText("partial bytes")
            }
            val stream = File(directory, "cover-in-progress.stream").apply {
                writeText("partial bytes")
            }
            val unrelated = File(directory, "metadata.json").apply {
                writeText("metadata")
            }

            ArtworkDiskCache.trim(directory, maxEntries = 1)

            assertFalse(oldest.exists())
            assertTrue(recent.exists())
            assertTrue(active.exists())
            assertTrue(stream.exists())
            assertTrue(unrelated.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun recentlyUsedArtworkIsRetainedWhenCapacityIsExceeded() {
        val directory = Files.createTempDirectory("artwork-cache-lru-test").toFile()
        try {
            val first = artworkFile(directory, "https://cdn.example/first.jpg", 1_000L)
            val second = artworkFile(directory, "https://cdn.example/second.jpg", 2_000L)

            assertTrue(ArtworkDiskCache.touch(first, timestamp = 3_000L))
            ArtworkDiskCache.trim(directory, maxEntries = 1)

            assertTrue(first.exists())
            assertFalse(second.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun artworkFile(directory: File, url: String, timestamp: Long): File =
        File(directory, artworkCacheFileName(url)).apply {
            writeText("jpeg")
            setLastModified(timestamp)
        }
}
