package com.md3music.md3music

/**
 * USB 音频驱动抛出的异常。
 * 移植自 decent-player libs/decent-usb-audio-driver 的 UsbAudioException.kt。
 */
sealed class UsbAudioException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class DeviceNotFoundException : UsbAudioException("No USB audio device found")
    class PermissionDeniedException : UsbAudioException("USB device permission denied")
    class DeviceOpenFailedException(reason: String) : UsbAudioException("Failed to open USB device: $reason")
    class StreamCreationFailedException(reason: String) : UsbAudioException("Failed to create audio stream: $reason")
    class InterfaceClaimFailedException(interfaceId: Int) : UsbAudioException("Failed to claim USB interface $interfaceId")
}
