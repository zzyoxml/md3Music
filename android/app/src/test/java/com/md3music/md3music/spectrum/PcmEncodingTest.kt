package com.md3music.md3music.spectrum

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 常量真值来自 android.media.AudioFormat，用以下命令核对过：
 *   unzip -o $SDK/platforms/android-34/android.jar android/media/AudioFormat.class -d /tmp
 *   javap -p -constants /tmp/android/media/AudioFormat.class | grep ENCODING_PCM
 */
class PcmEncodingTest {

    @Test
    fun constantsMatchAndroidAudioFormat() {
        assertEquals(3, PcmEncoding.PCM_8BIT)
        assertEquals(2, PcmEncoding.PCM_16BIT)
        assertEquals(4, PcmEncoding.PCM_FLOAT)
        assertEquals(21, PcmEncoding.PCM_24BIT_PACKED)
        assertEquals(22, PcmEncoding.PCM_32BIT)
    }

    @Test
    fun bytesPerSampleCoversEverySupportedEncoding() {
        assertEquals(1, PcmEncoding.bytesPerSample(PcmEncoding.PCM_8BIT))
        assertEquals(2, PcmEncoding.bytesPerSample(PcmEncoding.PCM_16BIT))
        assertEquals(3, PcmEncoding.bytesPerSample(PcmEncoding.PCM_24BIT_PACKED))
        assertEquals(4, PcmEncoding.bytesPerSample(PcmEncoding.PCM_FLOAT))
        assertEquals(4, PcmEncoding.bytesPerSample(PcmEncoding.PCM_32BIT))
    }

    @Test
    fun unsupportedEncodingReportsZeroInsteadOfGuessing() {
        assertEquals(0, PcmEncoding.bytesPerSample(0))
        assertEquals(0, PcmEncoding.bytesPerSample(-1))
        // 曾经的错值必须不再被当成合法编码
        assertEquals(0, PcmEncoding.bytesPerSample(0x40000000))
        assertEquals(0, PcmEncoding.bytesPerSample(Int.MIN_VALUE))
    }

    @Test
    fun nameOfIsHumanReadableAndMarksUnknownValues() {
        assertEquals("16BIT", PcmEncoding.nameOf(PcmEncoding.PCM_16BIT))
        assertEquals("24BIT_PACKED", PcmEncoding.nameOf(PcmEncoding.PCM_24BIT_PACKED))
        assertEquals("32BIT", PcmEncoding.nameOf(PcmEncoding.PCM_32BIT))
        assertEquals("FLOAT", PcmEncoding.nameOf(PcmEncoding.PCM_FLOAT))
        assertEquals("8BIT", PcmEncoding.nameOf(PcmEncoding.PCM_8BIT))
        assertEquals("UNSUPPORTED(99)", PcmEncoding.nameOf(99))
    }
}
