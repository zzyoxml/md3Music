package com.md3music.md3music

import android.hardware.usb.UsbDeviceConnection

/**
 * 已打开 USB 音频设备的信息，供原生 I/O 使用。
 * 移植自 decent-player libs/decent-usb-audio-driver 的 UsbAudioDeviceInfo.kt。
 */
data class UsbAudioDeviceInfo(
    val connection: UsbDeviceConnection,
    val fd: Int,
    val deviceName: String,
    val interfaceId: Int,
    val endpointOutAddress: Int,
    val endpointFeedbackAddress: Int,
    val maxPacketSize: Int,
    val altSettingCount: Int,
    val clockSourceId: Int,
    val bestAltSetting: Int,
    val bestBitDepth: Int
)
