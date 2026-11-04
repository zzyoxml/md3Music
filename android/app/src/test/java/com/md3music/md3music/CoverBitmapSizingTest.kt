package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Test

class CoverBitmapSizingTest {
    @Test
    fun oversizedCoverUsesPowerOfTwoSamplingToStayWithinTarget() {
        assertEquals(8, coverBitmapSampleSize(4000, 3000, 512))
        assertEquals(2, coverBitmapSampleSize(1024, 1024, 512))
        assertEquals(1, coverBitmapSampleSize(512, 400, 512))
    }

    @Test
    fun invalidDimensionsFallBackToNoSampling() {
        assertEquals(1, coverBitmapSampleSize(0, 500, 512))
        assertEquals(1, coverBitmapSampleSize(500, 500, 0))
    }
}
