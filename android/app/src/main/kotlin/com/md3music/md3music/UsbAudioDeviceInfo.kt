package com.md3music.md3music

import android.hardware.usb.UsbDeviceConnection

/**
 * 已打开 USB 音频设备的信息，供原生 I/O 使用。
 * 移植自 decent-player libs/decent-usb-audio-driver 的 UsbAudioDeviceInfo.kt。
 */
@Suppress("ArrayInDataClass")
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
    val bestBitDepth: Int,
    /** USB Audio Class 版本：1=UAC1，2=UAC2（决定采样率下发方式与时序）。 */
    val uacVersion: Int = 2,
    /** 所选 alt 支持的采样率列表（UAC1 离散列表；UAC2/连续区间为空数组）。 */
    val supportedRates: IntArray = intArrayOf(),
    /** feedback 端点来源："same-iface"（同接口显式 feedback）/ "none"（无，implicit/自适应）。 */
    val feedbackSource: String = "none",
    /** USB 总线速度：true=full-speed（1ms 帧），false=high-speed（125µs microframe）。 */
    val fullSpeed: Boolean = false,
    /** 全部输出流 alt 的采样率并集（排序去重），供输出格式选择 UI。 */
    val allRates: IntArray = intArrayOf(),
    /** 全部输出流 alt 的位深并集。 */
    val allBits: IntArray = intArrayOf(),
    /** 全部输出流 alt 的声道数并集。 */
    val allChannels: IntArray = intArrayOf()
)

/**
 * 未打开设备（未开启独占）时的 DAC 能力探测结果。
 *
 * 仅解析 raw USB 描述符得到，不 claim 接口、不打断内核驱动与正在播放的音频，
 * 供 UI 在独占未开启时也能按 DAC 实际能力生成"采样率/位深/声道"可选项。
 */
@Suppress("ArrayInDataClass")
data class UsbAudioCapabilities(
    val deviceName: String,
    val manufacturer: String,
    val vid: Int,
    val pid: Int,
    /** 1=UAC1，2=UAC2（3 及以上按 2 处理）。 */
    val uacVersion: Int,
    /** true=full-speed（1ms 帧）。 */
    val fullSpeed: Boolean,
    /** 输出流 alt 数量（含零带宽 alt 0）。 */
    val altCount: Int,
    /** 支持的采样率并集（UAC2 连续区间时由 [min,max] 过滤标准速率阶梯得到）。 */
    val allRates: IntArray,
    /** 支持的位深并集。 */
    val allBits: IntArray,
    /** 支持的声道数并集。 */
    val allChannels: IntArray,
    /** UAC2 连续区间下限（0=未声明/离散）。 */
    val rateMin: Int,
    /** UAC2 连续区间上限（0=未声明/离散）。 */
    val rateMax: Int
)
