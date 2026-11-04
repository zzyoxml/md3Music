package com.md3music.md3music

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log


/**
 * Manages the lifecycle of a USB Audio Class device for bit-perfect output.
 *
 * Responsibilities:
 * - Discover connected USB audio devices
 * - Request user permission via [UsbManager.requestPermission]
 * - Open the device and extract endpoint/interface info
 * - Provide the file descriptor and endpoint addresses to [UsbAudioStream]
 *
 * This class does NOT perform audio I/O — that's handled by the native layer
 * via [UsbAudioStream].
 *
 * @author DecentPlayer project
 */
class UsbAudioDevice private constructor(private val context: Context) {

    private var usbManager: UsbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var connection: UsbDeviceConnection? = null
    private var currentDevice: UsbDevice? = null
    /** 所有已 claim 的音频接口（AudioControl + AudioStreaming），close 时必须全部 release，
     *  否则内核驱动无法重新绑定 → 其他 App（及本 App 的 AudioTrack）都无法使用 DAC。 */
    private val claimedInterfaces: MutableList<UsbInterface> = mutableListOf()

    /** AudioControl 描述符中 Feature Unit（音量控制）的 bUnitID；<=0 表示 DAC 无硬件音量。 */
    @Volatile
    private var featureUnitId: Int = -1

    /** Feature Unit master 声道的 bmaControls（小端），bit1=Volume 支持。 */
    @Volatile
    private var featureUnitMasterControls: Int = 0

    /** GET_CUR 探测确定的可用音量声道；-1=未探测（-1 也可能是探测失败）。 */
    @Volatile
    private var volumeChannel: Int = -1

    /** 最近一次 setSampleRate 结果（诊断展示用）；null=本次打开后未执行。 */
    @Volatile
    private var lastRateSetOk: Boolean? = null

    /** 最近一次 UAC1 GET_CUR 回读的 DAC 端点采样率；-1=未回读/不支持/失败。 */
    @Volatile
    private var lastRateReadback: Int = -1

    /** DAC 是否支持硬件音量控制（存在 Feature Unit 且带 Volume 控制位）。 */
    val hasHardwareVolume: Boolean
        get() = featureUnitId > 0 && (featureUnitMasterControls and 0x02) != 0

    companion object {
        private const val TAG = "UsbAudioDevice"
        private const val ACTION_USB_PERMISSION_SUFFIX = ".USB_AUDIO_PERMISSION"

        @Volatile
        private var instance: UsbAudioDevice? = null

        /**
         * Get the singleton instance. All callers share the same connection
         * share the same connection and fd, preventing ENODEV from competing opens.
         */
        fun getInstance(context: Context): UsbAudioDevice {
            return instance ?: synchronized(this) {
                instance ?: UsbAudioDevice(context.applicationContext).also { instance = it }
            }
        }
    }


    /**
     * Find the first connected USB audio output device.
     *
     * Scans all USB devices for one with an AudioStreaming interface
     * (class=1, subclass=2) that has an isochronous OUT endpoint.
     *
     * @return The USB device, or null if none found.
     */
    fun findUsbAudioDevice(): UsbDevice? {
        for (device in usbManager.deviceList.values) {
            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                // USB Audio Class: class=1 (Audio), subclass=2 (AudioStreaming)
                if (iface.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                    iface.interfaceSubclass == 2) {
                    UsbLog.i(TAG, "Found USB audio device: ${device.productName} " +
                            "(vendor=0x${device.vendorId.toString(16)}, " +
                            "product=0x${device.productId.toString(16)})")
                    return device
                }
            }
        }
        Log.d(TAG, "No USB audio device found")
        return null
    }

    /**
     * Check if we already have permission to access the device.
     */
    fun hasPermission(device: UsbDevice): Boolean {
        return usbManager.hasPermission(device)
    }

    /**
     * Request permission from the user to access the USB device.
     *
     * @param device   The USB device to request access for.
     * @param callback Called with true if permission granted, false otherwise.
     */
    fun requestPermission(device: UsbDevice, callback: (Boolean) -> Unit) {
        if (usbManager.hasPermission(device)) {
            UsbLog.i(TAG, "Permission already granted for ${device.productName}")
            callback(true)
            return
        }

        val intent = Intent(context.packageName + ACTION_USB_PERMISSION_SUFFIX)
        intent.setPackage(context.packageName)
        val permissionIntent = PendingIntent.getBroadcast(
                context, 0,
                intent,
                PendingIntent.FLAG_MUTABLE
        )

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == context.packageName + ACTION_USB_PERMISSION_SUFFIX) {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    UsbLog.i(TAG, "USB permission result: granted=$granted for ${device.productName}")
                    context.unregisterReceiver(this)
                    callback(granted)
                }
            }
        }

        val filter = IntentFilter(context.packageName + ACTION_USB_PERMISSION_SUFFIX)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }

        usbManager.requestPermission(device, permissionIntent)
        UsbLog.i(TAG, "Permission requested for ${device.productName}")
    }

    /**
     * Open the USB device and extract all information needed for audio I/O.
     *
     * 接口/端点发现完全由 raw USB 描述符驱动（多接口 UAC1/UAC2 DAC 通吃）：
     * 解析 UAC 版本 → 收集全部 AudioStreaming alt → 按目标采样率选择
     * 输出流接口组的最佳 alt，并 claim 对应接口。
     *
     * @param device     The USB audio device to open.
     * @param targetRate 目标采样率（当前播放格式；0=未知，按最高位深选择）。
     * @return Device info with fd and endpoint addresses, or null on failure.
     */
    /** Cached device info from the last successful openDevice() call. */
    private var cachedDeviceInfo: UsbAudioDeviceInfo? = null

    /** 最近一次成功 openDevice 的设备信息（供插件 getStatus 上报）。 */
    fun getCachedInfo(): UsbAudioDeviceInfo? = cachedDeviceInfo

    fun openDevice(device: UsbDevice, targetRate: Int = 0, targetBits: Int = 0): UsbAudioDeviceInfo? {
        // 缓存命中时仍需按目标格式重新选择 alt：targetRate/targetBits（位深/采样率强制）
        // 变化必须反映到流配置，否则 override 不生效（修复：缓存短路吞掉参数）。
        val cached = cachedDeviceInfo
        val openConn = connection
        if (cached != null && openConn != null) {
            val asAlts = parseAudioStreaming(openConn, cached.uacVersion)
            val chosen = pickBestAlt(asAlts, targetRate, targetBits)
            if (chosen == null) {
                // 描述符重解析异常：保守复用缓存（与旧行为一致）
                UsbLog.w(TAG, "openDevice: cached re-parse failed — reusing fd=${cached.fd}")
                return cached
            }
            if (chosen.interfaceNumber == cached.interfaceId && chosen.alt == cached.bestAltSetting) {
                // 目标格式对应同一 alt：零开销复用
                UsbLog.i(TAG, "Device already open, reusing fd=${cached.fd} " +
                        "(iface=${cached.interfaceId} alt=${cached.bestAltSetting} bits=${cached.bestBitDepth})")
                return cached
            }
            if (chosen.interfaceNumber != cached.interfaceId) {
                // 新选择在不同 AS 接口：需要重新 claim，走完整重开（落到下方主流程）
                UsbLog.i(TAG, "Target format needs iface=${chosen.interfaceNumber} " +
                        "(cached iface=${cached.interfaceId}) — reopening device")
            } else {
                // 同接口换 alt：免重开设备（claim 仍有效），仅更新选择。
                // 后续 setAlt(0)/setAlt(N) 由 createStartedStream 在同接口执行。
                UsbLog.i(TAG, "Cached switch: iface=${chosen.interfaceNumber} " +
                        "alt=${cached.bestAltSetting}→${chosen.alt}, " +
                        "bits=${cached.bestBitDepth}→${chosen.bitResolution}, " +
                        "maxPacket=${cached.maxPacketSize}→${chosen.outMaxPacket}")
                val info = cached.copy(
                        maxPacketSize = chosen.outMaxPacket,
                        altSettingCount = asAlts.size,
                        bestAltSetting = chosen.alt,
                        bestBitDepth = chosen.bitResolution,
                        supportedRates = chosen.rates,
                        feedbackSource = if (chosen.fbEp > 0) "same-iface" else "none"
                )
                cachedDeviceInfo = info
                return info
            }
        }
        // Close any stale connection before opening new（缓存分支决定重开时此调用幂等）
        closeDevice()
        val conn = usbManager.openDevice(device)
        if (conn == null) {
            UsbLog.e(TAG, "Failed to open device ${device.productName}")
            return null
        }

        // 由描述符驱动：UAC 版本 + USB 速度 + 全部 AudioStreaming alt + 最佳输出流 alt
        val uacVersion = parseUacVersion(conn)
        val fullSpeed = parseUsbSpeed(conn, uacVersion)
        val asAlts = parseAudioStreaming(conn, uacVersion)
        val chosen = pickBestAlt(asAlts, targetRate, targetBits)
        if (chosen == null) {
            UsbLog.e(TAG, "No suitable AudioStreaming interface/endpoint found " +
                    "(uac=UAC$uacVersion, asAlts=${asAlts.size})")
            conn.close()
            return null
        }
        UsbLog.i(TAG, "Selected AudioStreaming: iface=${chosen.interfaceNumber} alt=${chosen.alt} " +
                "epOut=0x${chosen.outEp.toString(16)} maxPacket=${chosen.outMaxPacket} " +
                "bits=${chosen.bitResolution} ch=${chosen.channels} rates=${chosen.rates.contentToString()}")

        // UAC2 才有 Clock Source 实体；UAC1 采样率走端点请求（见 setSampleRate）。
        // 提到能力解析之前：UAC2 描述符常不声明速率，需向 Clock Source 发 GET_RANGE。
        val clockSourceId = if (uacVersion == 2) parseClockSourceId(conn) else -1

        // 能力并集（仅含 OUT 端点的输出流 alt），供输出格式选择 UI 生成可选项。
        // UAC2 描述符常不声明任何速率（Type I bLength=6）→ 退而向 Clock Source 发 GET_RANGE。
        // [P1 修复 2026-09-13]：类请求（UAC2 GET_RANGE/GET_CUR）必须在 claim AC 接口
        // （force=true 断开内核 snd-usb-audio）之后发起 —— 内核驱动占用时钟控制时
        // controlTransfer 全部以 -1 失败（Truesound UAC2 实测 18 实体全 -1 →
        // supportedRates=[] → 采样率无法读取/钳制）。
        val controlInterface = (0 until device.interfaceCount)
                .map { device.getInterface(it) }
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_AUDIO && it.interfaceSubclass == 1 }

        if (controlInterface != null) {
            val claimed = conn.claimInterface(controlInterface, true)
            if (claimed) claimedInterfaces.add(controlInterface)
            UsbLog.i(TAG, "Claimed AudioControl interface ${controlInterface.id} force=true: $claimed")
        }

        var queried: QueriedRates? = null
        var caps = capsFromAlts(asAlts)
        if (caps.rates.isEmpty()) {
            queried = queryRateRange(conn, uacVersion, clockSourceId, chosen.outEp)
            if (queried != null) caps = capsFromAlts(asAlts, queried)
        }
        val allRates = caps.rates
        val allBits = caps.bits
        val allChannels = caps.channels

        // Claim 所选输出流接口：按 bInterfaceNumber + bAlternateSetting 精确匹配，
        // 避免在多 AS 组设备（录音/播放两组接口）上命中错误接口
        val streamingInterface = (0 until device.interfaceCount)
                .map { device.getInterface(it) }
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                        it.interfaceSubclass == 2 &&
                        it.id == chosen.interfaceNumber &&
                        it.alternateSetting == chosen.alt }
        if (streamingInterface == null) {
            UsbLog.e(TAG, "Streaming UsbInterface not found: " +
                    "number=${chosen.interfaceNumber}, alt=${chosen.alt}")
            conn.close()
            return null
        }
        val claimedStreaming = conn.claimInterface(streamingInterface, true)
        UsbLog.i(TAG, "Claimed AudioStreaming interface ${streamingInterface.id} " +
                "(alt=${streamingInterface.alternateSetting}, " +
                "endpoints=${streamingInterface.endpointCount}) force=true: $claimedStreaming")
        if (!claimedStreaming) {
            UsbLog.e(TAG, "Failed to claim streaming interface — kernel driver may still be active")
            conn.close()
            return null
        }
        claimedInterfaces.add(streamingInterface)

        // Force alt=0（同一 interfaceNumber 的零带宽设置）以停止内核驱动残留的流。
        // 实际流式 alt 将由原生 SETINTERFACE(interfaceId, N) 激活。
        val zeroAlt = (0 until device.interfaceCount)
                .map { device.getInterface(it) }
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                        it.interfaceSubclass == 2 &&
                        it.id == chosen.interfaceNumber &&
                        it.alternateSetting == 0 }
        if (zeroAlt != null) {
            conn.setInterface(zeroAlt)
            UsbLog.i(TAG, "Reset streaming iface=${chosen.interfaceNumber} to alt=0 (zero-bandwidth)")
        }
        Thread.sleep(100)

        val fd = conn.fileDescriptor

        // clockSourceId 已在上方能力解析处计算（避免重复解析描述符）
        featureUnitId = parseFeatureUnitId(conn)
        val feedbackSource = if (chosen.fbEp > 0) "same-iface" else "none"

        connection = conn
        currentDevice = device

        UsbLog.i(TAG, "Device opened: ${device.productName}, fd=$fd, uac=UAC$uacVersion, " +
                "${if (fullSpeed) "full-speed" else "high-speed"}, " +
                "iface=${chosen.interfaceNumber}, epOut=0x${chosen.outEp.toString(16)}, " +
                "epFb=${if (chosen.fbEp > 0) "0x${chosen.fbEp.toString(16)}" else "none($feedbackSource)"}, " +
                "maxPacket=${chosen.outMaxPacket}, " +
                "clockSourceId=${if (clockSourceId > 0) "0x${clockSourceId.toString(16)}" else "-"}, " +
                "featureUnitId=${if (featureUnitId > 0) "0x${featureUnitId.toString(16)}" else "-"} " +
                "masterControls=0x${featureUnitMasterControls.toString(16)}" +
                if (hasHardwareVolume) " (硬件音量可用)" else " (无硬件音量，用软件音量 fallback)")

        val info = UsbAudioDeviceInfo(
                connection = conn,
                fd = fd,
                deviceName = device.productName ?: "USB Audio Device",
                interfaceId = chosen.interfaceNumber,
                endpointOutAddress = chosen.outEp,
                endpointFeedbackAddress = chosen.fbEp,
                maxPacketSize = chosen.outMaxPacket,
                altSettingCount = asAlts.size,
                clockSourceId = clockSourceId,
                bestAltSetting = chosen.alt,
                bestBitDepth = chosen.bitResolution,
                uacVersion = uacVersion,
                supportedRates = chosen.rates,
                feedbackSource = feedbackSource,
                fullSpeed = fullSpeed,
                allRates = allRates,
                allBits = allBits,
                allChannels = allChannels
        )
        cachedDeviceInfo = info
        return info
    }

    /**
     * Perform a USB device reset via native ioctl, then close and reopen.
     * This clears any stale clock/endpoint state left by the kernel driver.
     * After reset, the DAC reinitializes and will accept our SET_CUR.
     */
    fun resetAndReopen() {
        val conn = connection ?: return
        val fd = conn.fileDescriptor

        UsbLog.i(TAG, "Performing REAL USBDEVFS_RESET on fd=$fd...")

        // Real USB port reset via native ioctl — resets DAC clock state
        val ret = UsbAudioStream.nativeUsbReset(fd)
        UsbLog.i(TAG, "USBDEVFS_RESET result: $ret")

        // Reset releases all interface claims. The fd remains valid.
        // Clear cache so openDevice re-claims, but KEEP the connection
        // so the same fd is reused (native claims are on this fd).
        cachedDeviceInfo = null
        claimedInterfaces.clear()
        // DO NOT close connection — the fd from reset+native claim must be reused
        // The next openDevice() will see connection != null and skip re-opening
    }

    /**
     * Parse raw USB descriptors to find the UAC2 Clock Source entity ID.
     * This is the entity that controls the DAC's sample rate.
     *
     * Scans the AudioControl interface descriptors for a CLOCK_SOURCE
     * descriptor (bDescriptorSubtype = 0x0A) and returns its bClockID.
     *
     * @return Clock Source entity ID, or -1 if not found.
     */
    private fun parseClockSourceId(conn: UsbDeviceConnection): Int {
        val raw = conn.rawDescriptors ?: return -1

        var i = 0
        var inAudioControl = false

        while (i + 1 < raw.size) {
            val bLength = raw[i].toInt() and 0xFF
            if (bLength < 2) break
            if (i + bLength > raw.size) break

            val bDescriptorType = raw[i + 1].toInt() and 0xFF

            // Interface descriptor (0x04)
            if (bDescriptorType == 0x04 && bLength >= 9) {
                val bInterfaceClass = raw[i + 5].toInt() and 0xFF
                val bInterfaceSubClass = raw[i + 6].toInt() and 0xFF
                // AudioControl = class 1, subclass 1
                inAudioControl = (bInterfaceClass == 1 && bInterfaceSubClass == 1)
            }

            // CS_INTERFACE descriptor (0x24) inside AudioControl
            if (inAudioControl && bDescriptorType == 0x24 && bLength >= 3) {
                val bDescriptorSubtype = raw[i + 2].toInt() and 0xFF
                // CLOCK_SOURCE = 0x0A
                if (bDescriptorSubtype == 0x0A && bLength >= 5) {
                    val bClockID = raw[i + 3].toInt() and 0xFF
                    UsbLog.i(TAG, "parseClockSourceId: found CLOCK_SOURCE bClockID=0x${bClockID.toString(16)}")
                    return bClockID
                }
            }

            i += bLength
        }

        UsbLog.w(TAG, "parseClockSourceId: no CLOCK_SOURCE descriptor found")
        return -1
    }

    // ── 描述符驱动的 AudioStreaming 解析 ─────────────────────────

    /** 一个 AudioStreaming alt 设置的解析结果（来自 raw USB 描述符）。 */
    @Suppress("ArrayInDataClass")
    private data class AsAlt(
        val interfaceNumber: Int,   // bInterfaceNumber
        val alt: Int,               // bAlternateSetting
        val outEp: Int,             // ISO OUT 数据端点地址；无则 -1
        val outMaxPacket: Int,      // 该 OUT 端点 wMaxPacketSize
        val fbEp: Int,              // 同接口内显式 feedback ISO IN 端点；无则 -1
        val channels: Int,
        val bitResolution: Int,
        val subslotSize: Int,       // 每样本字节数
        val rates: IntArray,        // UAC1 离散采样率列表；UAC2/连续区间为空
        val rateMin: Int = 0,       // UAC2 连续区间下限（bSamFreqType=0）；0=无
        val rateMax: Int = 0        // UAC2 连续区间上限；0=无
    )

    /**
     * UAC2 连续采样率区间设备（bSamFreqType=0）没有离散列表，
     * 只能用其声明的 [min,max] 过滤标准速率阶梯生成可选项。
     */
    private val STANDARD_RATE_LADDER = intArrayOf(
            8000, 11025, 16000, 22050, 24000, 32000,
            44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
    )

    private fun le24(raw: ByteArray, offset: Int): Int {
        if (offset + 2 >= raw.size) return 0
        return (raw[offset].toInt() and 0xFF) or
                ((raw[offset + 1].toInt() and 0xFF) shl 8) or
                ((raw[offset + 2].toInt() and 0xFF) shl 16)
    }

    private fun le32(raw: ByteArray, offset: Int): Int {
        if (offset + 3 >= raw.size) return 0
        return (raw[offset].toInt() and 0xFF) or
                ((raw[offset + 1].toInt() and 0xFF) shl 8) or
                ((raw[offset + 2].toInt() and 0xFF) shl 16) or
                ((raw[offset + 3].toInt() and 0xFF) shl 24)
    }

    /** 通过标准请求问到的采样率能力（UAC2 GET_RANGE 子区间 / UAC1 GET_MIN·MAX）。 */
    private data class QueriedRates(
        val rates: IntArray,   // 子区间端点 + 阶梯命中值（已排序去重）
        val min: Int,
        val max: Int
    )

    /**
     * 描述符未声明采样率时（典型：UAC2 Type I 描述符 bLength=6，连 bSamFreqType 都没有，
     * 速率全部由可编程 Clock Source 声明），用标准请求向 DAC 询问可用范围：
     * - UAC2：Clock Source 实体 GET_RANGE（bRequest=0x02，wValue=CS_SAM_FREQ_CONTROL）
     *   响应布局（UAC2 5.2.2.1）：wNumSubRanges(2) + N×(dwMin/dwMax/dwRes，各 4 字节 LE)。
     *   常见 8 个子区间（44.1k–48k / 88.2k–96k / 176.4k–192k / 352.8k–384k …）。
     * - UAC1：端点 GET_MIN(0x02) / GET_MAX(0x03)，各 3 字节 LE
     * @return 能力；任一环节失败返回 null
     */
    private fun queryRateRange(conn: UsbDeviceConnection, uacVersion: Int,
                               clockSourceId: Int, outEndpoint: Int): QueriedRates? {
        return try {
            if (uacVersion >= 2) {
                val ids = buildList {
                    if (clockSourceId > 0) add(clockSourceId)
                    add(0x09); add(0x0C)
                    for (id in intArrayOf(0x05, 0x0A, 0x0B, 0x0D,
                                    0x28, 0x29, 0x2A, 0x06, 0x07, 0x08,
                                    0x10, 0x11, 0x12, 0x20, 0x21, 0x22)) add(id)
                }.distinct().toIntArray()
                for (csId in ids) {
                    // 2 + 最多 8 个子区间 × 12 字节
                    val buf = ByteArray(2 + 8 * 12)
                    val ret = conn.controlTransfer(
                            0xA1,           // Device-to-Host, Class, Interface
                            0x02,           // GET_RANGE
                            0x0100,         // CS_SAM_FREQ_CONTROL
                            csId shl 8,     // entityId << 8 | interface(0)
                            buf, buf.size, 1000)
                    if (ret < 14) {
                        UsbLog.w(TAG, "GET_RANGE(0x${csId.toString(16)}): ret=$ret")
                        continue
                    }
                    val n = (buf[0].toInt() and 0xFF) or ((buf[1].toInt() and 0xFF) shl 8)
                    if (n !in 1..8) {
                        UsbLog.w(TAG, "GET_RANGE(0x${csId.toString(16)}): subRanges=$n (忽略)")
                        continue
                    }
                    val rates = sortedSetOf<Int>()
                    var lo = Int.MAX_VALUE
                    var hi = 0
                    var valid = 0
                    val subranges = StringBuilder()
                    for (i in 0 until n) {
                        val o = 2 + i * 12
                        if (o + 12 > ret) break
                        val mn = le32(buf, o)
                        val mx = le32(buf, o + 4)
                        val res = le32(buf, o + 8)
                        // 合理性校验：4k..768k，防止把非采样率实体/乱码当真
                        if (mn < 4000 || mx < mn || mx > 768000) continue
                        valid++
                        lo = minOf(lo, mn)
                        hi = maxOf(hi, mx)
                        rates.add(mn)
                        rates.add(mx)
                        if (subranges.isNotEmpty()) subranges.append(", ")
                        subranges.append("$mn-$mx(res=$res)")
                        for (r in STANDARD_RATE_LADDER) if (r in mn..mx) rates.add(r)
                    }
                    if (valid > 0) {
                        UsbLog.i(TAG, "GET_RANGE(UAC2 clock 0x${csId.toString(16)}): $n subranges, " +
                                "$lo–$hi Hz → rates=${rates.toIntArray().contentToString()}")
                        UsbLog.i(TAG, "GET_RANGE subranges(DAC 原始声明): $subranges")
                        return QueriedRates(rates.toIntArray(), lo, hi)
                    }
                    UsbLog.w(TAG, "GET_RANGE(0x${csId.toString(16)}): no valid subrange (n=$n)")
                }
                // GET_RANGE 全灭：回退 GET_CUR 读取 DAC 当前采样率（至少给出一个真实可用值）
                for (csId in ids) {
                    val cur = ByteArray(4)
                    val ret = conn.controlTransfer(0xA1, 0x01, 0x0100, csId shl 8, cur, 4, 1000)
                    val rate = if (ret >= 4) le32(cur, 0) else 0
                    if (rate in 8000..768000) {
                        UsbLog.i(TAG, "GET_CUR fallback(0x${csId.toString(16)}): current=$rate Hz")
                        return QueriedRates(intArrayOf(rate), rate, rate)
                    }
                }
                UsbLog.w(TAG, "GET_RANGE: no clock source answered (ids=${ids.size})")
                null
            } else {
                if (outEndpoint < 0) return null
                val ep = outEndpoint and 0xFF
                val minB = ByteArray(3)
                val maxB = ByteArray(3)
                val rMin = conn.controlTransfer(0xA2, 0x02, 0x0100, ep, minB, 3, 1000)
                val rMax = conn.controlTransfer(0xA2, 0x03, 0x0100, ep, maxB, 3, 1000)
                if (rMin >= 3 && rMax >= 3) {
                    val min = le24(minB, 0)
                    val max = le24(maxB, 0)
                    if (min in 4000..768000 && max >= min) {
                        UsbLog.i(TAG, "GET_MIN/MAX(UAC1 ep=0x${ep.toString(16)}): $min–$max Hz")
                        return QueriedRates(intArrayOf(), min, max)
                    }
                }
                UsbLog.w(TAG, "GET_MIN/MAX(UAC1) failed (ret=$rMin/$rMax)")
                null
            }
        } catch (e: Exception) {
            UsbLog.w(TAG, "queryRateRange threw: ${e.message}")
            null
        }
    }

    /**
     * 解析 UAC 版本：在 AudioControl 接口（class=1, subclass=1）内找
     * CS_INTERFACE HEADER（subtype 0x01），读 bcdADC 高字节：
     * 0x0100→UAC1，0x0200→UAC2，其余按 UAC2 兜底（保持既有行为）。
     */
    private fun parseUacVersion(conn: UsbDeviceConnection): Int {
        val raw = conn.rawDescriptors ?: return 2
        var i = 0
        var inAudioControl = false
        while (i + 1 < raw.size) {
            val bLength = raw[i].toInt() and 0xFF
            if (bLength < 2) break
            if (i + bLength > raw.size) break
            val bDescriptorType = raw[i + 1].toInt() and 0xFF

            if (bDescriptorType == 0x04 && bLength >= 9) {
                val cls = raw[i + 5].toInt() and 0xFF
                val sub = raw[i + 6].toInt() and 0xFF
                inAudioControl = (cls == 1 && sub == 1)
            }

            // CS_INTERFACE HEADER：bcdADC 位于 payload 偏移 0-1（小端）
            if (inAudioControl && bDescriptorType == 0x24 && bLength >= 5 &&
                (raw[i + 2].toInt() and 0xFF) == 0x01) {
                val bcdAdc = (raw[i + 3].toInt() and 0xFF) or
                        ((raw[i + 4].toInt() and 0xFF) shl 8)
                val version = bcdAdc shr 8
                UsbLog.i(TAG, "parseUacVersion: bcdADC=0x${bcdAdc.toString(16)} → UAC$version")
                return if (version == 1) 1 else 2
            }

            i += bLength
        }
        UsbLog.w(TAG, "parseUacVersion: no AUDIO header found — 默认按 UAC2")
        return 2
    }

    /**
     * 判定 USB 总线速度（决定 native 每 ISO packet 装载的时长）。
     * 规则：
     * - UAC1 → 强制 full-speed：UAC1 设备均为 1ms 帧。bcdUSB 不可靠——
     *   它只是"声明的规范版本"（如 KTMicro 标 0x0200 仅表示 USB2.0 兼容），
     *   不代表以 high-speed 运行；误判会让 native 按 microframe 装包，
     *   数据供给率只有需求的 1/8（噪音/进度极慢的根因）。
     * - UAC2+ → bcdUSB ≥ 0x0200 按 high-speed（绝大多数 UAC2 为 high-speed）；
     *   raw 描述符无 device descriptor 时按默认 high-speed。
     */
    private fun parseUsbSpeed(conn: UsbDeviceConnection, uacVersion: Int): Boolean {
        if (uacVersion == 1) {
            UsbLog.i(TAG, "parseUsbSpeed: UAC1 → full-speed (bcdUSB 不可靠，忽略)")
            return true
        }
        val raw = conn.rawDescriptors ?: return false
        var i = 0
        while (i + 1 < raw.size) {
            val bLength = raw[i].toInt() and 0xFF
            if (bLength < 2) break
            if (i + bLength > raw.size) break
            if ((raw[i + 1].toInt() and 0xFF) == 0x01 && bLength >= 4) {
                val bcdUsb = (raw[i + 2].toInt() and 0xFF) or
                        ((raw[i + 3].toInt() and 0xFF) shl 8)
                val full = bcdUsb < 0x0200
                UsbLog.i(TAG, "parseUsbSpeed: bcdUSB=0x${bcdUsb.toString(16)} → " +
                        if (full) "full-speed" else "high-speed")
                return full
            }
            i += bLength
        }
        UsbLog.w(TAG, "parseUsbSpeed: 无 device descriptor → 默认 high-speed")
        return false
    }

    /**
     * 线性扫描 raw 描述符，收集全部 AudioStreaming alt 设置（含录音接口）。
     * - 端点：ISO OUT → outEp/outMaxPacket；ISO IN 且 usage=feedback(0x01) → fbEp
     *   （implicit-feedback 的 IN 数据端点不作为 feedback，避免把音频数据当时钟读）。
     * - 格式：FORMAT_TYPE_I(subtype 0x02, bFormatType=1)。
     *   UAC1 布局：bNrChannels/bSubframeSize/bBitResolution/bSamFreqType[+3字节频率×N]。
     *   UAC2 布局：bSubslotSize/bBitResolution（声道取 AS_GENERAL 的 bNrChannels）。
     */
    private fun parseAudioStreaming(conn: UsbDeviceConnection, uacVersion: Int): List<AsAlt> {
        val raw = conn.rawDescriptors ?: return emptyList()
        val result = mutableListOf<AsAlt>()

        var curNumber = -1
        var curAlt = -1
        var inAS = false
        var outEp = -1
        var outMaxPacket = 0
        var fbEp = -1
        var channels = 0
        var bitRes = 0
        var subslot = 0
        var rates = mutableListOf<Int>()
        var rateMin = 0
        var rateMax = 0

        fun flush() {
            if (inAS && curAlt > 0) {
                result.add(AsAlt(curNumber, curAlt, outEp, outMaxPacket, fbEp,
                        channels, bitRes, subslot, rates.toIntArray(), rateMin, rateMax))
            }
            outEp = -1; outMaxPacket = 0; fbEp = -1
            // 注意：channels 不在此重置——bNrChannels 是流级属性（AS_GENERAL 通常
            // 只挂在 alt0，跨全部 alt 共享）。sticky 保留最近一次 AS_GENERAL 的值，
            // 标准布局设备的 alt1+ 也能拿到正确声道数；bitRes/subslot/rates/端点
            // 是每个 alt 各自的属性，仍按 alt 重置。
            bitRes = 0; subslot = 0
            rates = mutableListOf()
            rateMin = 0; rateMax = 0
        }

        var i = 0
        while (i + 1 < raw.size) {
            val bLength = raw[i].toInt() and 0xFF
            if (bLength < 2) break
            if (i + bLength > raw.size) break
            when (raw[i + 1].toInt() and 0xFF) {
                0x04 -> {  // INTERFACE
                    val newNumber = if (bLength >= 9) raw[i + 2].toInt() and 0xFF else curNumber
                    flush()
                    // 切换到另一个接口（如输出流→录音流）：声道数改由新接口自己的
                    // AS_GENERAL 决定，缺失则保持 0（未知→不钳制），避免跨接口串值。
                    if (newNumber != curNumber) channels = 0
                    if (bLength >= 9) {
                        curNumber = raw[i + 2].toInt() and 0xFF
                        curAlt = raw[i + 3].toInt() and 0xFF
                        val cls = raw[i + 5].toInt() and 0xFF
                        val sub = raw[i + 6].toInt() and 0xFF
                        inAS = (cls == 1 && sub == 2)
                    } else {
                        inAS = false
                    }
                }
                0x05 -> {  // ENDPOINT
                    if (inAS && bLength >= 7) {
                        val addr = raw[i + 2].toInt() and 0xFF
                        val attr = raw[i + 3].toInt() and 0xFF
                        val maxPkt = (raw[i + 4].toInt() and 0xFF) or
                                ((raw[i + 5].toInt() and 0xFF) shl 8)
                        if ((attr and 0x03) == 0x01) {  // isochronous
                            if (addr and 0x80 == 0) {   // OUT 数据端点
                                outEp = addr
                                outMaxPacket = maxPkt
                            } else if (((attr shr 4) and 0x03) == 0x01) {
                                fbEp = addr  // IN + usage=feedback（显式异步反馈）
                            }
                        }
                    }
                }
                0x24 -> {  // CS_INTERFACE
                    if (inAS && bLength >= 6) {
                        when (raw[i + 2].toInt() and 0xFF) {
                            0x01 -> {  // AS_GENERAL：UAC2 的声道数（诊断用，尽力而为）
                                // UAC2 AS_GENERAL 标准布局：bTerminalLink(3)、bmControls(4)、
                                // bFormatType(5)、bmFormats(6..9)、bNrChannels(10)、
                                // bmChannelConfig(11..14)。
                                // 注意：声道数在偏移 10，不是 11——偏移 11 是声道位置位图
                                // （bmChannelConfig）低字节，立体声 FL|FR=0x03 会被误读成 3 声道。
                                if (uacVersion >= 2 && bLength >= 11) {
                                    val nrChannels = raw[i + 10].toInt() and 0xFF
                                    val chCfg = if (bLength >= 15) {
                                        (raw[i + 11].toInt() and 0xFF) or
                                                ((raw[i + 12].toInt() and 0xFF) shl 8) or
                                                ((raw[i + 13].toInt() and 0xFF) shl 16) or
                                                ((raw[i + 14].toInt() and 0xFF) shl 24)
                                    } else 0
                                    // 合理性校验：USB 音频声道数 1..8，越界视为描述符无效 → 0（不钳制）
                                    channels = if (nrChannels in 1..8) nrChannels else 0
                                    UsbLog.i(TAG, "AS_GENERAL: bNrChannels=$nrChannels" +
                                            " bmChannelConfig=0x${chCfg.toString(16)}" +
                                            " (iface=$curNumber alt=$curAlt)")
                                }
                            }
                            0x02 -> {  // FORMAT_TYPE
                                if ((raw[i + 3].toInt() and 0xFF) == 1) {  // Type I（PCM）
                                    if (uacVersion == 1 && bLength >= 8) {
                                        val nrChannels = raw[i + 4].toInt() and 0xFF
                                        channels = if (nrChannels in 1..8) nrChannels else 0
                                        subslot = raw[i + 5].toInt() and 0xFF
                                        bitRes = raw[i + 6].toInt() and 0xFF
                                        val n = raw[i + 7].toInt() and 0xFF
                                        if (n > 0 && bLength >= 8 + 3 * n) {
                                            for (k in 0 until n) {
                                                val o = i + 8 + k * 3
                                                rates.add((raw[o].toInt() and 0xFF) or
                                                        ((raw[o + 1].toInt() and 0xFF) shl 8) or
                                                        ((raw[o + 2].toInt() and 0xFF) shl 16))
                                            }
                                        }
                                    } else if (uacVersion >= 2) {
                                        subslot = raw[i + 4].toInt() and 0xFF
                                        bitRes = raw[i + 5].toInt() and 0xFF
                                        // UAC2 Type I 固定头 7 字节（UAC1 为 8），离散速率从 i+7 起；
                                        // bLength = 7 + 3n。注意 UAC2 常见 bLength=6（连 bSamFreqType
                                        // 都没有，采样率完全由 Clock Source 的 GET_RANGE 声明）。
                                        val n = if (bLength >= 7) raw[i + 6].toInt() and 0xFF else 0
                                        if (n > 0 && bLength >= 7 + 3 * n) {
                                            for (k in 0 until n) rates.add(le24(raw, i + 7 + 3 * k))
                                        } else if (bLength >= 13 && n == 0) {
                                            // 连续区间（bSamFreqType=0）：tLower/tUpperSamFreq 各 3 字节 LE
                                            val lo = le24(raw, i + 7)
                                            val hi = le24(raw, i + 10)
                                            if (lo > 0 && hi >= lo) {
                                                rateMin = lo
                                                rateMax = hi
                                                UsbLog.i(TAG, "FORMAT_TYPE(UAC2): " +
                                                        "continuous $lo–$hi Hz (iface=$curNumber alt=$curAlt)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            i += bLength
        }
        flush()

        UsbLog.i(TAG, "parseAudioStreaming: uac=UAC$uacVersion, ${result.size} alts: " +
                result.joinToString { a ->
                    "iface${a.interfaceNumber}/alt${a.alt}" +
                            "(ep=0x${a.outEp.toString(16)},maxPkt=${a.outMaxPacket}," +
                            "ch=${a.channels},bits=${a.bitResolution}," +
                            "fb=${if (a.fbEp > 0) "0x${a.fbEp.toString(16)}" else "-"})"
                })
        return result
    }

    /** 输出流 alt 的能力并集（供 UI 生成可选项 / 能力探测共用）。 */
    private data class AltCaps(
        val rates: IntArray,
        val bits: IntArray,
        val channels: IntArray,
        val rateMin: Int,
        val rateMax: Int
    )

    /**
     * 汇总全部含 OUT 端点的输出流 alt 的能力：
     * - 采样率：UAC1 取离散列表并集；UAC2 连续区间（无离散列表）用声明的
     *   [rateMin, rateMax] 过滤标准速率阶梯（仍由 DAC 声明的区间决定，非硬编码）。
     * - 位深 / 声道：全部 alt 的去重并集。
     */
    private fun capsFromAlts(asAlts: List<AsAlt>, queried: QueriedRates? = null): AltCaps {
        val outs = asAlts.filter { it.outEp >= 0 }
        val discrete = outs.flatMap { it.rates.asIterable() }.distinct().sorted()
        val lo = outs.map { it.rateMin }.filter { it > 0 }.minOrNull() ?: queried?.min ?: 0
        val hi = outs.map { it.rateMax }.filter { it > 0 }.maxOrNull() ?: queried?.max ?: 0
        val rates = when {
            discrete.isNotEmpty() -> discrete.toIntArray()
            queried != null && queried.rates.isNotEmpty() -> queried.rates
            lo > 0 && hi >= lo -> STANDARD_RATE_LADDER.filter { it in lo..hi }.toIntArray()
            else -> intArrayOf()
        }
        return AltCaps(
            rates,
            outs.map { it.bitResolution }.filter { it > 0 }.distinct().sorted().toIntArray(),
            outs.map { it.channels }.filter { it > 0 }.distinct().sorted().toIntArray(),
            lo, hi
        )
    }

    /**
     * 能力探测：只打开设备读描述符，随后立即关闭（**不 claim 任何接口**）。
     *
     * 与 [openDevice] 的区别：不断开内核驱动、不影响正在播放的音频，
     * 因此可以在"独占未开启、DAC 正被系统使用"时安全调用，
     * 让 UI 在开启独占前就拿到 UAC 版本/总线速度/支持的采样率、位深、声道。
     */
    fun probeCapabilities(device: UsbDevice): UsbAudioCapabilities? {
        val conn = usbManager.openDevice(device)
        if (conn == null) {
            UsbLog.w(TAG, "probeCapabilities: openDevice failed (${device.productName})")
            return null
        }
        return try {
            val uacVersion = parseUacVersion(conn)
            val fullSpeed = parseUsbSpeed(conn, uacVersion)
            val asAlts = parseAudioStreaming(conn, uacVersion)
            val outs = asAlts.filter { it.outEp >= 0 }
            // 描述符未声明速率（UAC2 Type I bLength=6 常见）→ 向 Clock Source 发 GET_RANGE
            var caps = capsFromAlts(asAlts)
            if (caps.rates.isEmpty() && outs.isNotEmpty()) {
                val csId = if (uacVersion == 2) parseClockSourceId(conn) else -1
                val q = queryRateRange(conn, uacVersion, csId, outs.first().outEp)
                if (q != null) caps = capsFromAlts(asAlts, q)
            }
            if (caps.rates.isEmpty() && caps.bits.isEmpty() && caps.channels.isEmpty()) {
                UsbLog.w(TAG, "probeCapabilities: no output alt parsed (${device.productName})")
                null
            } else {
                UsbLog.i(TAG, "probeCapabilities: ${device.productName} uac=UAC$uacVersion " +
                        "${if (fullSpeed) "full" else "high"}-speed " +
                        "rates=${caps.rates.contentToString()} bits=${caps.bits.contentToString()} " +
                        "ch=${caps.channels.contentToString()}" +
                        (if (caps.rateMin > 0) " range=${caps.rateMin}-${caps.rateMax}" else ""))
                UsbAudioCapabilities(
                    deviceName = device.productName ?: "USB Audio Device",
                    manufacturer = device.manufacturerName ?: "",
                    vid = device.vendorId,
                    pid = device.productId,
                    uacVersion = uacVersion,
                    fullSpeed = fullSpeed,
                    altCount = asAlts.size,
                    allRates = caps.rates,
                    allBits = caps.bits,
                    allChannels = caps.channels,
                    rateMin = caps.rateMin,
                    rateMax = caps.rateMax
                )
            }
        } catch (e: Exception) {
            UsbLog.e(TAG, "probeCapabilities threw: ${e.message}", e)
            null
        } finally {
            try { conn.close() } catch (_: Exception) {}
        }
    }

    /**
     * 选择最佳输出流 alt：仅在含 ISO OUT 端点的 alt 中挑选。
     * 采样率：targetRate>0 时优先支持该率（含 UAC2 连续区间）。
     * 位深：targetBits>0 时优先精确匹配，其次 ≥targetBits 的最小位深，再回退最高位深。
     * 最终在池内取最高位深、最大包长。
     */
    private fun pickBestAlt(asAlts: List<AsAlt>, targetRate: Int, targetBits: Int = 0): AsAlt? {
        val outs = asAlts.filter { it.outEp >= 0 }
        if (outs.isEmpty()) return null
        val matched = if (targetRate > 0) {
            outs.filter { it.rates.isEmpty() || it.rates.contains(targetRate) }
        } else {
            emptyList()
        }
        val ratePool = matched.ifEmpty { outs }
        val pool = if (targetBits > 0) {
            val exact = ratePool.filter { it.bitResolution == targetBits }
            when {
                exact.isNotEmpty() -> exact
                else -> ratePool.filter { it.bitResolution > targetBits }
                        .minByOrNull { it.bitResolution }?.let { listOf(it) } ?: ratePool
            }
        } else {
            ratePool
        }
        return pool.maxWithOrNull(compareBy({ it.bitResolution }, { it.outMaxPacket }))
    }

    /**
     * 解析 AudioControl 接口描述符，查找 Feature Unit（音量控制实体）。
     *
     * CS_INTERFACE(0x24) 的 FEATURE_UNIT subtype = 0x06（UAC1/UAC2 相同）。
     * 返回 bUnitID；没有 Feature Unit 或不在 AudioControl 接口内则返回 -1
     * （表示 DAC 无硬件音量控制，上层应回退软件音量）。
     */
    private fun parseFeatureUnitId(conn: UsbDeviceConnection): Int {
        val raw = conn.rawDescriptors ?: return -1
        var i = 0
        var inAudioControl = false
        while (i + 1 < raw.size) {
            val bLength = raw[i].toInt() and 0xFF
            if (bLength < 2) break
            if (i + bLength > raw.size) break
            val bDescriptorType = raw[i + 1].toInt() and 0xFF

            // Interface descriptor (0x04)：进入/离开 AudioControl 接口（class=1, subclass=1）
            if (bDescriptorType == 0x04 && bLength >= 9) {
                val cls = raw[i + 5].toInt() and 0xFF
                val sub = raw[i + 6].toInt() and 0xFF
                inAudioControl = (cls == 1 && sub == 1)
            }

            // CS_INTERFACE descriptor (0x24)：Feature Unit
            if (inAudioControl && bDescriptorType == 0x24 && bLength >= 6) {
                val bDescriptorSubtype = raw[i + 2].toInt() and 0xFF
                if (bDescriptorSubtype == 0x06) {  // FEATURE_UNIT
                    val bUnitID = raw[i + 3].toInt() and 0xFF
                    // 解析 master 声道 bmaControls（小端）：UAC1 bControlSize=1，UAC2=2
                    val bControlSize = raw[i + 5].toInt() and 0xFF
                    if (bControlSize in 1..2 && i + 5 + bControlSize <= raw.size) {
                        var mc = 0
                        for (k in 0 until bControlSize) {
                            mc = mc or ((raw[i + 6 + k].toInt() and 0xFF) shl (8 * k))
                        }
                        featureUnitMasterControls = mc
                        UsbLog.i(TAG, "parseFeatureUnitId: bUnitID=0x${bUnitID.toString(16)} " +
                                "bControlSize=$bControlSize masterControls=0x${mc.toString(16)} " +
                                "mute=${(mc and 0x01) != 0} volume=${(mc and 0x02) != 0}")
                    }
                    return bUnitID
                }
            }

            i += bLength
        }
        UsbLog.w(TAG, "parseFeatureUnitId: no Feature Unit found — DAC 无硬件音量控制")
        return -1
    }

    /**
     * 通过 UAC 控制传输设置 DAC 硬件主音量。
     *
     * 传输格式与本设备可用的 setSampleRate 一致（UAC2 风格 wIndex=entityId<<8|iface）：
     *   bmRequestType = 0x22 (Host→Device, Class, Interface)
     *   bRequest      = 0x01 (SET_CUR)
     *   wValue        = 0x0200 (CS=FU_VOLUME_CONTROL<<8 | channel 0=master)
     *   wIndex        = (featureUnitId << 8) | audioControlInterfaceNumber
     *   data          = 2 字节有符号 dB/256：0=0dB（最大），-0x8000=-128dB（静音）
     *
     * @param percent 0..100（0=静音，100=0dB）
     * @return 是否成功写入
     */
    fun setDacVolume(percent: Int): Boolean {
        val conn = connection ?: return false
        val fuId = featureUnitId
        if (fuId <= 0) return false

        // 先探测音量声道：master(0)/左(1)/右(2)，GET_CUR 成功即该声道支持音量控制。
        // 注意：部分 DAC 的 FU 存在但 master 无 Volume 控制位（STALL），需要逐声道探测。
        if (volumeChannel < 0) {
            for (ch in 0..2) {
                val probe = ByteArray(2)
                val gr = conn.controlTransfer(
                        0xA2,  // bmRequestType: Device-to-Host, Class, Interface
                        0x01,  // bRequest: GET_CUR
                        (0x02 shl 8) or ch,  // FU_VOLUME_CONTROL | channel
                        (fuId shl 8) or 0,   // entityId << 8 | AudioControl iface(0)
                        probe,
                        probe.size,
                        500
                )
                if (gr >= 2) {
                    val cur = (probe[0].toInt() and 0xFF) or ((probe[1].toInt() and 0xFF) shl 8)
                    val signed = if (cur >= 0x8000) cur - 0x10000 else cur
                    volumeChannel = ch
                    UsbLog.i(TAG, "setDacVolume: probe channel $ch OK (cur=${signed / 256.0}dB)")
                    break
                }
            }
            if (volumeChannel < 0) {
                UsbLog.w(TAG, "setDacVolume: FU 0x${fuId.toString(16)} all channels no volume — DAC 不支持硬件音量")
                return false
            }
        }

        val p = percent.coerceIn(0, 100)
        val volume = if (p <= 0) {
            -0x8000  // 完全静音
        } else {
            // 线性映射：100% → 0dB(0)，1% → -128dB(-0x8000)。保持 16bit 精度。
            -((100 - p) * 32768) / 100
        }

        val data = ByteArray(2)
        data[0] = (volume and 0xFF).toByte()
        data[1] = ((volume shr 8) and 0xFF).toByte()

        val wValue = (0x02 shl 8) or volumeChannel
        val ret = conn.controlTransfer(0x22, 0x01, wValue, (fuId shl 8) or 0, data, data.size, 1000)
        if (ret >= 0) {
            UsbLog.i(TAG, "setDacVolume($p%) ch=$volumeChannel vol=$volume (${volume / 256.0}dB) OK")
            return true
        }
        UsbLog.w(TAG, "setDacVolume($p%): SET_CUR failed ret=$ret")
        return false
    }

    /**
     * Close the USB device and release all resources.
     */
    fun closeDevice() {
        // 先取已选输出流接口号，供 alt=0 恢复精确匹配（多 AS 组设备不能取"第一个 alt=0"）
        val openedIfaceNumber = cachedDeviceInfo?.interfaceId
        cachedDeviceInfo = null
        featureUnitId = -1
        featureUnitMasterControls = 0
        volumeChannel = -1
        lastRateSetOk = null
        lastRateReadback = -1
        val conn = connection
        val device = currentDevice
        if (conn != null && device != null) {
            // 1) AudioStreaming 接口恢复 alt=0（释放 xHCI 等时带宽）
            try {
                (0 until device.interfaceCount).map { device.getInterface(it) }
                    .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                            it.interfaceSubclass == 2 && it.alternateSetting == 0 &&
                            (openedIfaceNumber == null || it.id == openedIfaceNumber) }
                    ?.let { conn.setInterface(it) }
            } catch (_: Exception) {}
            // 2) 释放所有已 claim 的接口（AudioControl + AudioStreaming）
            for (iface in claimedInterfaces) {
                try { conn.releaseInterface(iface) } catch (_: Exception) {}
            }
            // 3) SETCONFIGURATION(0→current) 触发 USB core 重新匹配接口驱动
            //    （snd-usb-audio 自动重绑），DAC 交还系统。
            //    实测：USBDEVFS_CONNECT 内核未实现（ENOTTY）；RESET 会让廉价 UAC1 设备
            //    从 host 栈消失（只能物理拔插恢复）。config 切换不丢设备，可再次开启独占。
            val fd = conn.fileDescriptor
            try {
                val ret = UsbAudioStream.nativeUsbReconfigure(fd)
                UsbLog.i(TAG, "nativeUsbReconfigure ret=$ret")
            } catch (e: Exception) {
                UsbLog.e(TAG, "nativeUsbReconfigure failed: ${e.message}")
            }
        }
        val releasedCount = claimedInterfaces.size
        claimedInterfaces.clear()
        connection?.close()
        connection = null
        currentDevice = null
        UsbLog.i(TAG, "USB device closed ($releasedCount interfaces released + reconnect)")
    }

    /**
     * Set the sample rate on the DAC via SET_CUR control transfer.
     *
     * UAC1（多接口廉价 DAC 常见）：SAMPLING_FREQ_CONTROL 端点请求
     *   bmRequestType = 0x22 (Host-to-Device, Class, Endpoint)
     *   bRequest = 0x01 (SET_CUR)
     *   wValue = 0x0100 (CS_SAM_FREQ_CONTROL << 8 | channel 0)
     *   wIndex = OUT 端点地址
     *   data = 3-byte LE sample rate
     *
     * UAC2：Clock Source 实体请求（沿用既有路径）
     *   bmRequestType = 0x21 (Host-to-Device, Class, Interface)
     *   wIndex = (clockSourceEntityId << 8) | audioControlInterfaceNumber
     *   data = 4-byte LE sample rate
     */
    fun setSampleRate(sampleRateHz: Int): Boolean {
        val conn = connection ?: return false
        val info = cachedDeviceInfo

        // UAC1：端点请求，3 字节 LE
        if (info != null && info.uacVersion == 1) {
            val data3 = byteArrayOf(
                    (sampleRateHz and 0xFF).toByte(),
                    ((sampleRateHz shr 8) and 0xFF).toByte(),
                    ((sampleRateHz shr 16) and 0xFF).toByte())
            val ret = conn.controlTransfer(
                    0x22,    // bmRequestType: Host-to-Device, Class, Endpoint
                    0x01,    // bRequest: SET_CUR
                    0x0100,  // wValue: CS_SAM_FREQ_CONTROL
                    info.endpointOutAddress and 0xFF,  // wIndex: OUT 端点地址
                    data3,
                    data3.size,
                    1000
            )
            if (ret >= 0) {
                UsbLog.i(TAG, "UAC1 setSampleRate($sampleRateHz Hz): OK " +
                        "ep=0x${info.endpointOutAddress.toString(16)} ret=$ret")
                lastRateSetOk = true
                // GET_CUR 回读 DAC 端点当前采样率（bmRequestType 0xA2, wIndex=OUT 端点, 3 字节 LE）
                // 用于暴露"DAC 实际率 ≠ 发送率"；部分 UAC1 不支持端点 GET_CUR → FAIL 仅记录
                val rb = ByteArray(3)
                val rr = conn.controlTransfer(0xA2, 0x01, 0x0100,
                        info.endpointOutAddress and 0xFF, rb, rb.size, 1000)
                lastRateReadback = if (rr >= 3) {
                    (rb[0].toInt() and 0xFF) or ((rb[1].toInt() and 0xFF) shl 8) or
                            ((rb[2].toInt() and 0xFF) shl 16)
                } else 0  // 0 = 回读失败（DAC 不支持端点 GET_CUR），与"未执行"(-1) 区分
                UsbLog.i(TAG, "UAC1 rate readback: $lastRateReadback Hz (ret=$rr)")
                return true
            }
            UsbLog.w(TAG, "UAC1 setSampleRate($sampleRateHz Hz): failed ret=$ret " +
                    "(rates=${info.supportedRates.contentToString()}，DAC 可能自适应采样率)")
            lastRateSetOk = false
            return false
        }

        // UAC2：Clock Source 实体 SET_CUR
        val data = ByteArray(4)
        data[0] = (sampleRateHz and 0xFF).toByte()
        data[1] = ((sampleRateHz shr 8) and 0xFF).toByte()
        data[2] = ((sampleRateHz shr 16) and 0xFF).toByte()
        data[3] = ((sampleRateHz shr 24) and 0xFF).toByte()

        // Use auto-detected clock source ID from USB descriptors.
        // If not available, fall back to brute-force trying common IDs.
        val detectedId = cachedDeviceInfo?.clockSourceId ?: -1
        val clockSourceIds = if (detectedId > 0) {
            intArrayOf(detectedId)  // use the one we parsed from descriptors
        } else {
            intArrayOf(0x05, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
                    0x28, 0x29, 0x2A, 0x06, 0x07, 0x08,
                    0x10, 0x11, 0x12, 0x20, 0x21, 0x22)
        }

        for (csId in clockSourceIds) {
            val wIndex = (csId shl 8) or 0  // entityId << 8 | audioControlInterface(0)
            val ret = conn.controlTransfer(
                    0x21,    // bmRequestType: Host-to-Device, Class, Interface
                    0x01,    // bRequest: SET_CUR
                    0x0100,  // wValue: CS_SAM_FREQ_CONTROL
                    wIndex,
                    data,
                    data.size,
                    1000     // timeout ms
            )
            if (ret >= 0) {
                UsbLog.i(TAG, "setSampleRate($sampleRateHz Hz): SUCCESS with clockSourceId=0x${csId.toString(16)} (wIndex=0x${wIndex.toString(16)}, ret=$ret)")
                lastRateSetOk = true
                return true
            }
        }

        UsbLog.w(TAG, "setSampleRate($sampleRateHz Hz): all clock source IDs failed, DAC may auto-detect")
        lastRateSetOk = false
        return false
    }

    /**
     * Read the CLOCK_VALID control from the DAC via UAC2 GET_CUR.
     * This checks whether the Clock Source entity's clock is locked and stable
     * after a sample rate change. Standard practice per UAC2 spec: verify clock after SET_CUR before proceeding.
     *
     * UAC2 spec: Clock Source descriptor, CS = 0x02 (CUR_CLOCK_VALID_CONTROL)
     * Returns: true if clock is valid, false if not or on error.
     */
    fun readClockValid(): Boolean {
        val conn = connection ?: return false
        // UAC1 无 CLOCK_VALID 概念，直接视为有效（实际结果由 setSampleRate 返回值体现）
        val info = cachedDeviceInfo
        if (info != null && info.uacVersion == 1) return true
        val data = ByteArray(1)

        val detectedId = cachedDeviceInfo?.clockSourceId ?: -1
        val clockSourceIds = if (detectedId > 0) intArrayOf(detectedId)
                else intArrayOf(0x05, 0x09, 0x0A, 0x0B, 0x0C, 0x28, 0x29)
        for (csId in clockSourceIds) {
            val wIndex = (csId shl 8) or 0
            val ret = conn.controlTransfer(
                    0xA1,    // bmRequestType: Device-to-Host, Class, Interface
                    0x01,    // bRequest: GET_CUR
                    0x0200,  // wValue: CS=0x02 (CLOCK_VALID_CONTROL), CN=0x00
                    wIndex,
                    data,
                    data.size,
                    1000
            )
            if (ret >= 1) {
                val valid = data[0].toInt() and 0x01
                UsbLog.i(TAG, "readClockValid: clockSourceId=0x${csId.toString(16)} valid=$valid")
                return valid == 1
            }
        }
        UsbLog.w(TAG, "readClockValid: all GET_CUR attempts failed")
        return false
    }

    /**
     * Set the alternate setting on the streaming interface via Java API.
     * This may properly allocate USB bandwidth, which the native ioctl might not.
     */
    fun setAltSetting(altSetting: Int): Boolean {
        val conn = connection ?: return false
        val device = currentDevice ?: return false
        // 收敛为按已选输出流接口号匹配（多 AS 组设备不能按裸 alt 号猜接口）
        val openedIfaceNumber = cachedDeviceInfo?.interfaceId

        // Find the UsbInterface with the matching alt setting
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                iface.interfaceSubclass == 2 &&
                iface.alternateSetting == altSetting &&
                (openedIfaceNumber == null || iface.id == openedIfaceNumber)) {
                val result = conn.setInterface(iface)
                UsbLog.i(TAG, "setAltSetting($altSetting) via Java API: $result " +
                        "(iface id=${iface.id}, endpoints=${iface.endpointCount})")
                return result
            }
        }

        UsbLog.w(TAG, "setAltSetting($altSetting): no matching UsbInterface found, " +
                "trying all AudioStreaming interfaces...")

        // Fallback: try any AudioStreaming interface with matching alt
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_AUDIO &&
                iface.interfaceSubclass == 2) {
                Log.d(TAG, "  interface $i: id=${iface.id} alt=${iface.alternateSetting} " +
                        "endpoints=${iface.endpointCount}")
            }
        }

        return false
    }

    /**
     * Salt Player 式诊断导出：设备拓扑 + 所选端点 + UAC 版本 + 采样率能力，
     * 经 getStatus()["diagnostics"] 透出至「调试信息」面板，供用户复制回传定位。
     */
    fun buildDiagnostics(device: UsbDevice?, info: UsbAudioDeviceInfo?): String {
        val sb = StringBuilder()
        sb.appendLine("USB Exclusive Diagnostics")
        sb.appendLine("Package: com.md3music.md3music")
        if (device == null) {
            sb.appendLine("Device: none")
            return sb.toString()
        }
        sb.appendLine("Device: ${device.productName}")
        sb.appendLine("VID:PID: ${device.vendorId.toString(16).uppercase().padStart(4, '0')}" +
                ":${device.productId.toString(16).uppercase().padStart(4, '0')}")
        sb.appendLine("Manufacturer: ${device.manufacturerName ?: "-"}")
        sb.appendLine("USB Permission: ${usbManager.hasPermission(device)}")
        sb.appendLine("Interface Count: ${device.interfaceCount}")
        for (i in 0 until device.interfaceCount) {
            val f = device.getInterface(i)
            sb.appendLine("Interface #$i: id=${f.id} alt=${f.alternateSetting} " +
                    "class=${f.interfaceClass} subclass=${f.interfaceSubclass} " +
                    "endpoints=${f.endpointCount}")
            for (e in 0 until f.endpointCount) {
                val ep = f.getEndpoint(e)
                sb.appendLine("  EP 0x${ep.address.toString(16).uppercase()} " +
                        "dir=${if (ep.direction == UsbConstants.USB_DIR_IN) "IN" else "OUT"} " +
                        "type=${ep.type} interval=${ep.interval} " +
                        "maxPacket=${ep.maxPacketSize} attributes=0x${ep.attributes.toString(16)}")
            }
        }
        if (info != null) {
            sb.appendLine("Opened: true / fd=${info.fd}")
            sb.appendLine("UAC Version: ${info.uacVersion}")
            sb.appendLine("USB Speed: ${if (info.fullSpeed) "full" else "high"}")
            sb.appendLine("Selected Endpoint: iface=${info.interfaceId} alt=${info.bestAltSetting} " +
                    "ep=0x${info.endpointOutAddress.toString(16).uppercase()} " +
                    "maxPacket=${info.maxPacketSize} bits=${info.bestBitDepth}")
            sb.appendLine("Supported Rates: ${info.supportedRates.joinToString(",")}")
            sb.appendLine("All Rates: ${info.allRates.joinToString(",")}")
            sb.appendLine("All Bits: ${info.allBits.joinToString(",")}")
            sb.appendLine("All Channels: ${info.allChannels.joinToString(",")}")
            sb.appendLine("Rate Set: ${when (lastRateSetOk) { true -> "OK"; false -> "FAIL"; null -> "未执行" }}")
            sb.appendLine("Rate Readback: ${if (lastRateReadback > 0) "$lastRateReadback Hz" else if (lastRateReadback == 0) "FAIL" else "未回读"}")
            sb.appendLine("Feedback: ${info.feedbackSource} " +
                    "ep=${if (info.endpointFeedbackAddress > 0) "0x${info.endpointFeedbackAddress.toString(16).uppercase()}" else "none"}")
            sb.appendLine("Clock Source: ${if (info.clockSourceId > 0) "0x${info.clockSourceId.toString(16).uppercase()}" else "none"}")
            sb.appendLine("Hardware Volume: ${hasHardwareVolume} " +
                    "(featureUnitId=${if (featureUnitId > 0) "0x${featureUnitId.toString(16)}" else "-"})")
            sb.appendLine("Claimed Interfaces: ${claimedInterfaces.joinToString { "${it.id}/alt${it.alternateSetting}" }}")
        } else {
            sb.appendLine("Opened: false（设备未成功打开，无已选端点信息）")
        }
        return sb.toString()
    }

}

