package com.md3music.md3music

import android.util.Log

/**
 * JNI handle for a direct USB audio output stream.
 *
 * 移植自 decent-player libs/decent-usb-audio-driver 的 UsbAudioStream.kt。
 * 通过 Linux usbdevfs 等时传输把 PCM 直写 USB Audio Class 2.0 DAC，绕过 Android 音频栈。
 * JNI 符号见 android/app/src/main/cpp/usb-audio-output.cpp（类名 com/md3music/md3music/UsbAudioStream）。
 */
class UsbAudioStream(
        fd: Int,
        interfaceId: Int,
        endpointOut: Int,
        endpointFeedback: Int,
        sampleRate: Int,
        channelCount: Int,
        /** DAC 端点位深（降位/抖动的目标位深）。 */
        private val bitDepth: Int,
        maxPacketSize: Int,
        /** USB 总线速度：true=full-speed（每 ISO packet 对应 1ms 帧），false=high-speed（125µs microframe）。 */
        fullSpeed: Boolean = false
) {

    /** Native UsbAudioContext 指针。 */
    var nativeHandle: Long = 0L
        private set

    init {
        nativeHandle = nativeUsbAudioCreate(
                fd, interfaceId, endpointOut, endpointFeedback,
                sampleRate, channelCount, bitDepth, maxPacketSize, fullSpeed
        )
        if (nativeHandle == 0L) {
            UsbLog.e(TAG, "nativeUsbAudioCreate returned 0 — check logcat for native errors")
        }
    }

    /** True when the native context was created successfully. */
    val isReady: Boolean
        get() = nativeHandle != 0L

    /** True when the stream is actively running. */
    val isAlive: Boolean
        get() = nativeHandle != 0L && nativeIsRunning(nativeHandle)

    /** Total frames written to USB since last start(). Used for position tracking. */
    val framesWritten: Long
        get() = if (nativeHandle != 0L) nativeGetFramesWritten(nativeHandle) else 0L

    fun setAltSetting(altSetting: Int): Boolean {
        if (nativeHandle == 0L) return false
        return nativeUsbAudioSetAltSetting(nativeHandle, altSetting)
    }

    fun setSampleRate(sampleRateHz: Int, clockSourceId: Int = 0): Boolean {
        if (nativeHandle == 0L) return false
        return nativeUsbAudioSetSampleRate(nativeHandle, sampleRateHz, clockSourceId)
    }

    fun start(): Boolean {
        if (nativeHandle == 0L) return false
        return nativeUsbAudioStart(nativeHandle)
    }

    /** 写入交错 float32 PCM。原生层转换为 DAC 位深并按 1ms URB 分包。 */
    fun write(pcmBuffer: FloatArray) {
        if (nativeHandle == 0L) return
        // 软件音量 fallback：DAC 无硬件音量控制时对 float 数据缩放
        // （bit-perfect 场景优先用 DAC 硬件音量，此处仅在硬件音量不可用时生效）
        val v = streamVolume
        if (v < 0.999f) {
            for (i in pcmBuffer.indices) pcmBuffer[i] *= v
        }
        nativeUsbAudioWrite(nativeHandle, pcmBuffer)
    }

    /** 直接写入整数 PCM 字节（不经过 float）。 */
    fun writeRaw(pcmBuffer: ByteArray, encoding: Int) {
        if (nativeHandle == 0L) return
        val inputBitDepth = when (encoding) {
            2 -> 16   // C.ENCODING_PCM_16BIT
            0x15 -> 24 // C.ENCODING_PCM_24BIT
            0x16 -> 32 // C.ENCODING_PCM_32BIT
            else -> {
                // 静默丢弃会表现为无声且无任何留痕 —— 至少留一条警告
                UsbLog.w(TAG, "writeRaw: unsupported pcm encoding $encoding, buffer dropped")
                return
            }
        }
        val dither = ditherEnabled && UsbDither.isReducing(inputBitDepth, bitDepth)
        // 软件音量 fallback 与抖动合并为一次遍历（音量缩放本身也是一次位深缩减，
        // 必须与抖动同遍历，否则其截断误差无法被抖动消除）
        UsbDither.applyVolumeAndDitherInPlace(pcmBuffer, inputBitDepth, bitDepth, streamVolume, dither, ditherRng)
        nativeUsbAudioWriteRaw(nativeHandle, pcmBuffer, inputBitDepth)
    }

    /** 本流的 TPDF 随机源（确定性；跨缓冲保持连续）。 */
    private val ditherRng = XorShift32(System.nanoTime().toUInt())

    fun stop() {
        if (nativeHandle == 0L) return
        nativeUsbAudioStop(nativeHandle)
    }

    /** 重置帧累加器与残余缓冲。seek/flush 时调用防止爆音。 */
    fun flush() {
        if (nativeHandle == 0L) return
        nativeFlush(nativeHandle)
    }

    /**
     * Drain all in-flight URBs. 必须在 stop 之后、setAlt(0) 之前调用，
     * 否则 xHCI 事件环残留会破坏后续流。
     */
    fun drainUrbs(): Int {
        if (nativeHandle == 0L) return 0
        return nativeDrainUrbs(nativeHandle)
    }

    fun release() {
        if (nativeHandle == 0L) return
        nativeUsbAudioDestroy(nativeHandle)
        nativeHandle = 0L
        UsbLog.i(TAG, "UsbAudioStream released")
    }

    // JNI declarations（与 usb-audio-output.cpp 导出符号一一对应）

    private external fun nativeUsbAudioCreate(
            fd: Int, interfaceId: Int, endpointOut: Int, endpointFeedback: Int,
            sampleRate: Int, channelCount: Int, bitDepth: Int, maxPacketSize: Int,
            fullSpeed: Boolean
    ): Long

    private external fun nativeUsbAudioSetAltSetting(handle: Long, altSetting: Int): Boolean
    private external fun nativeUsbAudioSetSampleRate(handle: Long, sampleRateHz: Int, clockSourceId: Int): Boolean
    private external fun nativeUsbAudioStart(handle: Long): Boolean
    private external fun nativeUsbAudioWrite(handle: Long, pcmBuffer: FloatArray)
    private external fun nativeUsbAudioWriteRaw(handle: Long, pcmBuffer: ByteArray, inputBitDepth: Int)
    private external fun nativeUsbAudioStop(handle: Long)
    private external fun nativeFlush(handle: Long)
    private external fun nativeDrainUrbs(handle: Long): Int
    private external fun nativeUsbAudioDestroy(handle: Long)
    private external fun nativeIsRunning(handle: Long): Boolean
    private external fun nativeGetFramesWritten(handle: Long): Long

    companion object {
        private const val TAG = "UsbAudioStream"
        /** 软件音量（0..1）。DAC 无硬件音量控制时的 fallback，write() 对 float 缩放。 */
        @Volatile
        var streamVolume: Float = 1f

        /**
         * TPDF 抖动降位开关（默认关闭）。仅当源位深 > DAC 端点位深时参与；
         * writeRaw 每块缓冲都会读取，因此切换**立即生效**，无需重建流。
         */
        @Volatile
        var ditherEnabled: Boolean = false

        init {
            System.loadLibrary("usb_audio_driver")
        }

        /**
         * USB 端口复位（USBDEVFS_RESET），复位 DAC 时钟状态。
         * @return 0 成功，负数为错误码
         */
        @JvmStatic
        external fun nativeUsbReset(fd: Int): Int

        /** 读取 native 环形日志（诊断导出用）；异常/为空时返回空串。 */
        @JvmStatic
        external fun nativeGetRecentLogs(): String?

        /** native 环形日志安全封装。 */
        fun recentNativeLogs(): String =
                try { nativeGetRecentLogs() ?: "" } catch (_: Throwable) { "" }

        /**
         * 释放路径专用：SETCONFIGURATION(0) → SETCONFIGURATION(current) 触发 USB core
         * 重新匹配接口驱动（snd-usb-audio 自动重绑），DAC 交还系统。
         * 实测：USBDEVFS_CONNECT 内核未实现（ENOTTY）；RESET 会让廉价 UAC1 设备
         * 从 host 栈消失（只能物理拔插恢复）。config 切换是唯一不丢设备的恢复路径。
         * @param fd usbdevfs 文件描述符
         * @return 0 成功，负数为错误码
         */
        @JvmStatic
        external fun nativeUsbReconfigure(fd: Int): Int
    }
}
