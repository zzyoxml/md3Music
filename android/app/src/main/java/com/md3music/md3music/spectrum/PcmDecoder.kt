package com.md3music.md3music.spectrum

import java.nio.ByteBuffer

/** 一次解码的结果：[nextWritePos] 是环形缓冲的下一个写位置，[frames] 是本次写入的帧数。 */
internal data class PcmDecodeResult(val nextWritePos: Int, val frames: Int)

/**
 * 把 ExoPlayer 解码后的 PCM ByteBuffer 拆成「左声道单声道 float」写进环形缓冲。
 *
 * 纯函数、无 Android 依赖、可 JVM 单测。
 *
 * 刻意**逐字节显式小端**读取，而不是 `buffer.getShort()`：
 *  1. 不依赖也不修改源 buffer 的 byteOrder（调用方传的是 `duplicate()`，但改 order
 *     仍是意料之外的副作用，历史代码就是这么写的）；
 *  2. 不移动 position/limit；
 *  3. 24bit / 8bit 本来就没有 ByteBuffer 原生访问器，只能逐字节。
 */
internal object PcmDecoder {

    fun appendLeftChannel(
        buffer: ByteBuffer,
        encoding: Int,
        channelCount: Int,
        ring: FloatArray,
        writePos: Int,
    ): PcmDecodeResult {
        val bytesPerSample = PcmEncoding.bytesPerSample(encoding)
        if (bytesPerSample == 0 || channelCount <= 0) {
            return PcmDecodeResult(writePos, 0)
        }
        val frameBytes = bytesPerSample * channelCount
        val pos = buffer.position()
        val frames = (buffer.limit() - pos) / frameBytes
        if (frames <= 0) return PcmDecodeResult(writePos, 0)

        val isFloat = encoding == PcmEncoding.PCM_FLOAT
        val size = ring.size
        var w = writePos
        for (f in 0 until frames) {
            val base = pos + f * frameBytes
            val b0 = buffer.get(base).toInt() and 0xFF
            val v = when {
                isFloat -> {
                    val b1 = buffer.get(base + 1).toInt() and 0xFF
                    val b2 = buffer.get(base + 2).toInt() and 0xFF
                    val b3 = buffer.get(base + 3).toInt() and 0xFF
                    val fv = Float.fromBits(b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24))
                    if (fv.isNaN() || fv.isInfinite()) 0f else fv
                }
                // 8bit 是无符号（0..255，零点是 128）
                bytesPerSample == 1 -> (b0 - 128).toFloat() / 128f
                bytesPerSample == 2 -> {
                    val b1 = buffer.get(base + 1).toInt() and 0xFF
                    (b0 or (b1 shl 8)).toShort().toFloat() / 32768f
                }
                bytesPerSample == 3 -> {
                    val b1 = buffer.get(base + 1).toInt() and 0xFF
                    val b2 = buffer.get(base + 2).toInt()
                    (b0 or (b1 shl 8) or (b2 shl 16)).toFloat() / 8388608f
                }
                else -> {
                    val b1 = buffer.get(base + 1).toInt() and 0xFF
                    val b2 = buffer.get(base + 2).toInt() and 0xFF
                    val b3 = buffer.get(base + 3).toInt() and 0xFF
                    val iv = b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
                    iv.toFloat() / 2147483648f
                }
            }
            ring[w] = v
            w++
            if (w == size) w = 0
        }
        return PcmDecodeResult(w, frames)
    }
}
