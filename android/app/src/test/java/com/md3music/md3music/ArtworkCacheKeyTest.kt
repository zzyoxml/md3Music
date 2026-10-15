package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtworkCacheKeyTest {
    @Test
    fun javaStringHashCollisionsProduceDifferentArtworkFiles() {
        val firstUrl = "https://cdn.example/cover/Ea.jpg"
        val secondUrl = "https://cdn.example/cover/FB.jpg"

        assertEquals(firstUrl.hashCode(), secondUrl.hashCode())
        assertNotEquals(artworkCacheFileName(firstUrl), artworkCacheFileName(secondUrl))
    }

    @Test
    fun filenameIsDeterministicAndKeepsJpegExtension() {
        val url = "https://cdn.example/cover/track.jpg"
        val name = artworkCacheFileName(url)

        assertEquals(name, artworkCacheFileName(url))
        assertTrue(name.endsWith(".jpg"))
        assertEquals(68, name.length)
    }
}
