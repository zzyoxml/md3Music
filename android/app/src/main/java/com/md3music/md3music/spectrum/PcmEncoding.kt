package com.md3music.md3music.spectrum

/**
 * PCM 编码常量的单一权威来源。
 *
 * 值全部对齐 android.media.AudioFormat，已用 javap 从 android.jar 反编译核对：
 *   ENCODING_PCM_16BIT        = 2
 *   ENCODING_PCM_8BIT         = 3   （无符号，0..255，零点是 128）
 *   ENCODING_PCM_FLOAT        = 4
 *   ENCODING_PCM_24BIT_PACKED = 21
 *   ENCODING_PCM_32BIT        = 22
 *
 * 历史 bug：这里曾是 PCM_24BIT = 0x40000000 / PCM_32BIT = Int.MIN_VALUE（两个凭空值），
 * MediaCodec 报 enc=21（24bit FLAC 走解码器时的常见输出编码）就落进 when 的 else 分支
 * 被整帧静默丢弃 —— 表现为「频谱永远不激活，1.5s 后降级模拟律动」。
 *
 * ⚠️ 任何硬编码的系统常量，写之前必须反编译核对，不得凭记忆填。
 */
internal object PcmEncoding {
    const val PCM_8BIT = 3
    const val PCM_16BIT = 2
    const val PCM_FLOAT = 4
    const val PCM_24BIT_PACKED = 21
    const val PCM_32BIT = 22

    /** 每样本字节数；返回 0 表示该编码不受支持（调用方必须打日志，不得静默丢弃）。 */
    fun bytesPerSample(encoding: Int): Int = when (encoding) {
        PCM_8BIT -> 1
        PCM_16BIT -> 2
        PCM_24BIT_PACKED -> 3
        PCM_FLOAT, PCM_32BIT -> 4
        else -> 0
    }

    fun nameOf(encoding: Int): String = when (encoding) {
        PCM_8BIT -> "8BIT"
        PCM_16BIT -> "16BIT"
        PCM_FLOAT -> "FLOAT"
        PCM_24BIT_PACKED -> "24BIT_PACKED"
        PCM_32BIT -> "32BIT"
        else -> "UNSUPPORTED($encoding)"
    }
}
