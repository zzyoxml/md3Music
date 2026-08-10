package com.md3music.premium

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ryanheise.just_audio.UsbAudioSink
import com.ryanheise.just_audio.UsbAudioSinkController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * USB 独占输出插件：MethodChannel "com.md3music.premium/usb_audio"。
 *
 * 编排层职责：
 * - listDevices / getStatus / getFormatInfo / isEnabled：查询
 * - enableExclusive / disableExclusive：开关（异步授权 + 打开设备 + 创建流 + xHCI 时序）
 * - 采样率变化（UsbAudioSinkController 回调）→ 重建流
 * - USB 拔插广播 → 热插拔处理
 *
 * 时序铁律（移植自 decent-player，缺一不可）：
 *   stop → drainUrbs → release → setAlt(0) → SET_CUR → setAlt(N) → start
 */
class UsbAudioPlugin(private val context: Context) {

    companion object {
        private const val TAG = "UsbAudioPlugin"
        private const val CHANNEL_NAME = "com.md3music.premium/usb_audio"
        private const val ACTION_USB_PERMISSION_SUFFIX = ".USB_AUDIO_PERMISSION"
        /** 默认采样率/声道（尚未捕获到播放格式时创建流的兜底）。 */
        private const val DEFAULT_SAMPLE_RATE = 44100
        private const val DEFAULT_CHANNELS = 2
    }

    private val usbManager: UsbManager =
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val usbAudioDevice: UsbAudioDevice = UsbAudioDevice.getInstance(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 当前活动流的适配器（disable 时 stop→drain→release）。 */
    private var currentAdapter: UsbAudioAdapter? = null

    /** 当前 DAC 位深（enable 时上报给控制器做状态展示）。 */
    private var currentDacBitDepth: Int = 0

    /**
     * 设备扫描缓存：Dart 端每秒轮询 getStatus，若每次都调 UsbManager.getDeviceList()
     * 会对部分 USB DAC（如廉价 UAC1 设备）造成反复枚举 → 每秒"滋"一声。
     * 因此扫描结果缓存 5 秒；拔插广播会立即失效缓存。
     */
    private var deviceCacheTime: Long = 0L
    private var deviceCacheResult: UsbDevice? = null

    private fun findCachedDevice(): UsbDevice? {
        val now = android.os.SystemClock.elapsedRealtime()
        if (deviceCacheResult == null || now - deviceCacheTime > 5000) {
            deviceCacheTime = now
            deviceCacheResult = usbAudioDevice.findUsbAudioDevice()
        }
        return deviceCacheResult
    }

    private fun invalidateDeviceCache() {
        deviceCacheResult = null
        deviceCacheTime = 0L
    }

    /** 拔插广播：独占开启时拔线自动关闭（避免写坏 fd），重新插入自动恢复。 */
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    Log.i(TAG, "USB_DEVICE_ATTACHED (exclusive=" + UsbAudioSinkController.isEnabled() + ")")
                    invalidateDeviceCache()
                    if (UsbAudioSinkController.isEnabled()) {
                        // 重插后设备需重新授权 + 重建流
                        requestEnableInternal(null)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    Log.w(TAG, "USB_DEVICE_DETACHED — 自动关闭独占，避免写入失效 fd")
                    invalidateDeviceCache()
                    disableExclusive()
                }
            }
        }
    }

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            try {
                handleMethod(call, result)
            } catch (e: Exception) {
                Log.e(TAG, "handleMethod(" + call.method + ") threw: " + e.message, e)
                if (call.method != "enableExclusive") {
                    result.error("INTERNAL_ERROR", e.message, null)
                }
            }
        }

        // 采样率/声道变化 → 应用侧重建流（在 ExoPlayer 渲染线程回调）
        UsbAudioSinkController.setReconfigListener { rate, ch, enc ->
            Log.i(TAG, "reconfig requested: $rate Hz / $ch ch / enc=$enc")
            rebuildStream(rate, ch)
        }

        // 动态注册拔插广播（不抢占 MainActivity 的 USB intent-filter，
        // App 运行时即可 claim；未运行时无需处理）
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        try {
            context.applicationContext.registerReceiver(usbReceiver, filter)
        } catch (e: Exception) {
            Log.e(TAG, "registerReceiver failed: ${e.message}")
        }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "getStatus" -> result.success(getStatus())
            "getFormatInfo" -> result.success(UsbAudioSinkController.getFormatInfo())
            "isEnabled" -> result.success(UsbAudioSinkController.isEnabled())
            "enableExclusive" -> requestEnableInternal(result)
            "disableExclusive" -> {
                disableExclusive()
                result.success(getStatus())
            }
            else -> result.notImplemented()
        }
    }

    // ── 查询 ─────────────────────────────────────────────────────

    private fun listDevices(): List<Map<String, Any?>> {
        return usbManager.deviceList.values.mapNotNull { device ->
            val isAudio = (0 until device.interfaceCount).any { i ->
                val iface = device.getInterface(i)
                iface.interfaceClass == android.hardware.usb.UsbConstants.USB_CLASS_AUDIO
            }
            if (!isAudio) return@mapNotNull null
            mapOf(
                "name" to (device.productName ?: "USB Audio Device"),
                "manufacturer" to (device.manufacturerName ?: ""),
                "vid" to device.vendorId,
                "pid" to device.productId,
                "hasPermission" to usbManager.hasPermission(device)
            )
        }
    }

    private fun getStatus(): Map<String, Any?> {
        val base = HashMap<String, Any?>()
        base.putAll(UsbAudioSinkController.getStatus())
        val device = findCachedDevice()
        val cached = usbAudioDevice.getCachedInfo()
        base["deviceConnected"] = device != null
        base["deviceName"] = cached?.deviceName ?: device?.productName
        base["hasPermission"] = device != null && usbAudioDevice.hasPermission(device)
        return base
    }

    // ── 开关 ─────────────────────────────────────────────────────

    /** 开启独占（可带授权流程）。result 为空时表示由拔插广播触发。 */
    private fun requestEnableInternal(result: MethodChannel.Result?) {
        val device = findCachedDevice()
        if (device == null) {
            Log.e(TAG, "enableExclusive: no USB audio device")
            if (result != null) result.error("NO_DEVICE", "未检测到 USB 音频设备", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            doEnable(device, result)
        } else {
            Log.i(TAG, "enableExclusive: requesting permission for ${device.productName}")
            usbAudioDevice.requestPermission(device) { granted ->
                if (granted) {
                    doEnable(device, result)
                } else {
                    Log.e(TAG, "enableExclusive: permission denied")
                    if (result != null) {
                        result.error("PERMISSION_DENIED", "USB 设备授权被拒绝", null)
                    }
                }
            }
        }
    }

    /**
     * 在后台线程执行 USB 设备打开 + 流创建（含 50ms PLL 锁定时），完成后回主线程回调。
     */
    private fun doEnable(device: UsbDevice, result: MethodChannel.Result?) {
        Thread {
            try {
                val adapter = createStartedStream(device) ?: run {
                    mainHandler.post {
                        if (result != null) result.error("STREAM_CREATE_FAILED", "USB 流创建失败，详见 logcat", null)
                    }
                    return@Thread
                }
                currentAdapter = adapter
                val rate = UsbAudioSinkController.getLastSampleRate().takeIf { it > 0 } ?: DEFAULT_SAMPLE_RATE
                val ch = UsbAudioSinkController.getLastChannelCount().takeIf { it > 0 } ?: DEFAULT_CHANNELS
                val ok = UsbAudioSinkController.enable(adapter, currentDacBitDepth, rate, ch)
                mainHandler.post {
                    if (result != null) {
                        if (ok) result.success(getStatus())
                        else result.error("ENABLE_FAILED", "USB 独占开启失败", null)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "doEnable threw: ${e.message}", e)
                mainHandler.post {
                    if (result != null) result.error("ENABLE_FAILED", e.message, null)
                }
            }
        }.apply { isDaemon = true; start() }
    }

    /**
     * 打开设备（复用已有连接）→ 按 xHCI 时序创建并启动流。
     * @return 已 start 的适配器；失败返回 null
     */
    private fun createStartedStream(device: UsbDevice): UsbAudioAdapter? {
        var info = usbAudioDevice.openDevice(device)
        if (info == null) {
            Log.e(TAG, "openDevice failed")
            return null
        }
        val rate = UsbAudioSinkController.getLastSampleRate().takeIf { it > 0 } ?: DEFAULT_SAMPLE_RATE
        val ch = UsbAudioSinkController.getLastChannelCount().takeIf { it > 0 } ?: DEFAULT_CHANNELS
        val bitDepth = info.bestBitDepth
        val altSetting = info.bestAltSetting

        var stream = UsbAudioStream(
            info.fd, info.interfaceId, info.endpointOutAddress, info.endpointFeedbackAddress,
            rate, ch, bitDepth, info.maxPacketSize
        )
        if (!stream.isReady) {
            stream.release()
            return null
        }

        // Step 1: setAlt(0) — 释放旧的 ISO ring；失败说明 fd 失效，重开设备
        if (!usbAudioDevice.setAltSetting(0)) {
            Log.w(TAG, "setAlt(0) failed — reopening device")
            usbAudioDevice.closeDevice()
            stream.release()
            info = usbAudioDevice.openDevice(device) ?: return null
            stream = UsbAudioStream(
                info.fd, info.interfaceId, info.endpointOutAddress, info.endpointFeedbackAddress,
                rate, ch, bitDepth, info.maxPacketSize
            )
            if (!stream.isReady) { stream.release(); return null }
        }
        Log.i(TAG, "Step 1: setAlt(0) OK")

        // Step 2: SET_CUR 采样率 + Step 3: CLOCK_VALID 校验
        usbAudioDevice.setSampleRate(rate)
        val clockValid = usbAudioDevice.readClockValid()
        Log.i(TAG, "Step 2-3: SET_CUR=$rate CLOCK_VALID=$clockValid")

        // Step 4: 防御性 setAlt(0) + Step 5: setAlt(N) 分配新 ring
        usbAudioDevice.setAltSetting(0)
        val altOk = usbAudioDevice.setAltSetting(altSetting)
        Log.i(TAG, "Step 4-5: setAlt(0)+setAlt($altSetting)=$altOk")

        // Step 6: DAC PLL 锁定时
        Thread.sleep(50)

        // Step 7: start
        if (!stream.start()) {
            Log.e(TAG, "stream.start() failed")
            stream.release()
            return null
        }
        currentDacBitDepth = bitDepth
        Log.i(TAG, "USB stream ACTIVE: $rate Hz / $ch ch / ${bitDepth}bit @ ${info.deviceName}")
        return UsbAudioAdapter(stream)
    }

    /** 采样率/声道变化时重建流（UsbAudioSinkController 回调，渲染线程执行）。 */
    private fun rebuildStream(rate: Int, ch: Int): UsbAudioSink? {
        return try {
            val device = findCachedDevice()
                ?: run { Log.e(TAG, "rebuild: no device"); currentAdapter = null; return null }
            if (!usbManager.hasPermission(device)) {
                Log.e(TAG, "rebuild: no permission")
                currentAdapter = null
                return null
            }
            val adapter = createStartedStream(device) ?: run {
                Log.e(TAG, "rebuild: createStartedStream failed")
                // 旧流已被控制器 stop/drain/release，必须清空引用防止二次 release
                currentAdapter = null
                return null
            }
            currentAdapter = adapter
            Log.i(TAG, "rebuild OK: $rate Hz / $ch ch")
            adapter
        } catch (e: Exception) {
            Log.e(TAG, "rebuild threw: ${e.message}", e)
            currentAdapter = null
            null
        }
    }

    private fun disableExclusive() {
        // 阶段一：停写线程 + 清活动流（不恢复 delegate，见控制器 disable() 注释）
        UsbAudioSinkController.disable()
        currentAdapter?.let { adapter ->
            try {
                // 顺序不可颠倒：stop → drain（排空事件环）→ release
                adapter.stop()
                adapter.drainUrbs()
                adapter.release()
            } catch (e: Exception) {
                Log.e(TAG, "disableExclusive release failed: ${e.message}")
            }
        }
        currentAdapter = null
        // 阶段二：USBDEVFS_RESET 触发设备重新枚举 → 内核驱动（snd-usb-audio）自动重新绑定。
        // 必须做这一步：Android force-claim 是 USBDEVFS_DISCONNECT 永久断开内核驱动，
        // 仅 releaseInterface/close 驱动不会重绑，DAC 会一直"被占用"（只能插拔恢复）。
        try {
            val fd = usbAudioDevice.getCurrentFd()
            if (fd != null) {
                val ret = UsbAudioStream.nativeUsbResetAndRelease(fd)
                Log.i(TAG, "nativeUsbResetAndRelease ret=$ret")
            }
        } catch (e: Exception) {
            Log.e(TAG, "nativeUsbResetAndRelease failed: ${e.message}")
        }
        // 阶段三：释放接口 + close（RESET 已清 claims，这里兜底清理）
        usbAudioDevice.closeDevice()
        // 阶段四：设备释放完成后再恢复 delegate 音量/路由
        UsbAudioSinkController.onUsbReleased()
        Log.i(TAG, "disableExclusive done")
    }

    fun cleanup() {
        try { context.unregisterReceiver(usbReceiver) } catch (_: Exception) {}
        if (UsbAudioSinkController.isEnabled()) disableExclusive()
    }
}
