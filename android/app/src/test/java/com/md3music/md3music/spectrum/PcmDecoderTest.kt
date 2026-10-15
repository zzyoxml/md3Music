package com.md3music.md3music.spectrum

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PcmDecoderTest {

    private fun le(vararg bytes: Int): ByteBuffer =
        ByteBuffer.wrap(ByteArray(bytes.size) { bytes[it].toByte() })

    @Test
    fun decodes16BitLittleEndianToNormalizedFloat() {
        // 0x4000 = 16384 → 0.5 ; 0xC000 = -16384 → -0.5
        val buf = le(0x00, 0x40, 0x00, 0xC0)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_16BIT, 1, ring, 0)
        assertEquals(2, result.frames)
        assertEquals(2, result.nextWritePos)
        assertEquals(0.5f, ring[0], 1e-6f)
        assertEquals(-0.5f, ring[1], 1e-6f)
    }

    @Test
    fun decodes24BitPackedAsSignedLittleEndian() {
        // 0x400000 = 4194304 → 0.5 ; 0xC00000 → -0.5
        val buf = le(0x00, 0x00, 0x40, 0x00, 0x00, 0xC0)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_24BIT_PACKED, 1, ring, 0)
        assertEquals(2, result.frames)
        assertEquals(0.5f, ring[0], 1e-6f)
        assertEquals(-0.5f, ring[1], 1e-6f)
    }

    @Test
    fun decodes32BitLittleEndian() {
        // 0x40000000 → 0.5 ; 0xC0000000 → -0.5
        val buf = le(0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0xC0)
        val ring = FloatArray(8)
        PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_32BIT, 1, ring, 0)
        assertEquals(0.5f, ring[0], 1e-6f)
        assertEquals(-0.5f, ring[1], 1e-6f)
    }

    @Test
    fun decodesFloatLittleEndian() {
        val buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buf.putFloat(0.5f)
        buf.putFloat(-0.25f)
        buf.flip()
        val ring = FloatArray(8)
        PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_FLOAT, 1, ring, 0)
        assertEquals(0.5f, ring[0], 1e-6f)
        assertEquals(-0.25f, ring[1], 1e-6f)
    }

    @Test
    fun decodes8BitAsUnsignedCenteredOn128() {
        // 8bit 是无符号：0xFF→+1.0（满幅正向，127/128）, 0x00→-1.0, 0x80→0.0
        val buf = le(0xFF, 0x00, 0x80)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_8BIT, 1, ring, 0)
        assertEquals(3, result.frames)
        assertEquals(0.9921875f, ring[0], 1e-6f)
        assertEquals(-1.0f, ring[1], 1e-6f)
        assertEquals(0.0f, ring[2], 1e-6f)
    }

    @Test
    fun readsOnlyLeftChannelOfInterleavedStereo() {
        // 立体声 L,R 交错：只有 L 进 ring
        val buf = le(0x00, 0x40, 0x11, 0x11, 0x00, 0xC0, 0x22, 0x22)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_16BIT, 2, ring, 0)
        assertEquals(2, result.frames)
        assertEquals(0.5f, ring[0], 1e-6f)
        assertEquals(-0.5f, ring[1], 1e-6f)
    }

    @Test
    fun wrapsAroundRingBufferAndOverwritesOldestSamples() {
        val ring = FloatArray(3)
        val first = le(0x00, 0x40, 0x00, 0x40, 0x00, 0x40) // 3 帧 0.5
        var result = PcmDecoder.appendLeftChannel(first, PcmEncoding.PCM_16BIT, 1, ring, 0)
        assertEquals(0, result.nextWritePos) // 绕回起点
        val second = le(0x00, 0xC0) // 1 帧 -0.5，覆盖 ring[0]
        result = PcmDecoder.appendLeftChannel(second, PcmEncoding.PCM_16BIT, 1, ring, 0)
        assertEquals(1, result.nextWritePos)
        assertEquals(-0.5f, ring[0], 1e-6f)
        assertEquals(0.5f, ring[1], 1e-6f)
    }

    @Test
    fun unsupportedEncodingConsumesNothing() {
        val buf = le(0x01, 0x02, 0x03, 0x04)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, 0x40000000, 1, ring, 0)
        assertEquals(0, result.frames)
        assertEquals(0, result.nextWritePos)
    }

    @Test
    fun zeroChannelCountConsumesNothing() {
        val buf = le(0x01, 0x02)
        val ring = FloatArray(8)
        val result = PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_16BIT, 0, ring, 0)
        assertEquals(0, result.frames)
    }

    @Test
    fun doesNotMutateSourceBufferByteOrderOrPosition() {
        val buf = le(0x00, 0x40)
        val orderBefore = buf.order()
        val posBefore = buf.position()
        PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_16BIT, 1, FloatArray(4), 0)
        assertEquals(orderBefore, buf.order())
        assertEquals(posBefore, buf.position())
    }

    @Test
    fun nonFiniteFloatSamplesBecomeSilence() {
        val buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buf.putFloat(Float.NaN)
        buf.putFloat(Float.POSITIVE_INFINITY)
        buf.flip()
        val ring = FloatArray(4)
        PcmDecoder.appendLeftChannel(buf, PcmEncoding.PCM_FLOAT, 1, ring, 0)
        assertFalse(ring[0].isNaN())
        assertEquals(0.0f, ring[0], 0f)
        assertEquals(0.0f, ring[1], 0f)
    }
}
