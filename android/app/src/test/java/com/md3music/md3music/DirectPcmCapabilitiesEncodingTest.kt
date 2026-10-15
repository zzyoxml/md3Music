package com.md3music.md3music

import com.ryanheise.just_audio.DirectPcmCapabilities
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 编码名映射必须对齐 android.media.AudioFormat 真值（javap 核对）：
 *   2=16BIT / 3=8BIT / 4=FLOAT / 21=24BIT_PACKED / 22=32BIT
 */
class DirectPcmCapabilitiesEncodingTest {

    @Test
    fun namesEveryEncodingWithItsRealAudioFormatValue() {
        assertEquals("PCM 16bit", DirectPcmCapabilities.encodingName(2))
        assertEquals("PCM 8bit", DirectPcmCapabilities.encodingName(3))
        assertEquals("PCM float32（24bit 有效）", DirectPcmCapabilities.encodingName(4))
        assertEquals("PCM 24bit packed", DirectPcmCapabilities.encodingName(21))
        assertEquals("PCM 32bit", DirectPcmCapabilities.encodingName(22))
    }

    @Test
    fun doesNotClaimTheWrongValueIs24BitPacked() {
        // 0x12=18 是 ENCODING_E_AC3_JOC，绝不是 24BIT_PACKED
        assertEquals("编码 18", DirectPcmCapabilities.encodingName(18))
    }
}
