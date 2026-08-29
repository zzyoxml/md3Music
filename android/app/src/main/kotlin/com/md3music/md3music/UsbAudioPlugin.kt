package com.md3music.md3music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ryanheise.just_audio.UsbAudioSink
import com.ryanheise.just_audio.UsbAudioSinkController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * USB 独占输出插件：MethodChannel "com.md3music.md3music/usb_audio"。
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
        private const val CHANNEL_NAME = "com.md3music.md3music/usb_audio"
        private const val ACTION_USB_PERMISSION_SUFFIX = ".USB_AUDIO_PERMISSION"
        /** 默认采样率/声道（尚未捕获到播放格式时创建流的兜底）。 */
        private const val DEFAULT_SAMPLE_RATE = 44100
        private const val DEFAULT_CHANNELS = 2
    }

    private val usbManager: UsbManager =
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val usbAudioDevice: UsbAudioDevice = UsbAudioDevice.getInstance(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 当前活动流的适配器（disable 时 stop→drain→release）。 */
    private var currentAdapter: UsbAudioAdapter? = null

    /** 当前 DAC 位深（enable 时上报给控制器做状态展示）。 */
    private var currentDacBitDepth: Int = 0

    /** 独占开关互斥锁：防止 enable / disable / 拔插恢复并发操作同一 USB 设备。 */
    private val exclusiveLock = Any()

    /** 上一次系统媒体音量百分比（检测变化后更新 DAC 音量）。 */
    private var lastSystemVolumePct: Int = -1

    /**
     * 系统媒体音量轮询：独占时音量键走 AudioFlinger，不会作用于直写 USB 的数据，
     * 必须由应用侧监听 STREAM_MUSIC 并同步到 DAC 硬件音量（或软件音量 fallback）。
     * 500ms 轮询足够跟手且开销可忽略。
     */
    private val volumePollRunnable = object : Runnable {
        override fun run() {
            if (!UsbAudioSinkController.isEnabled()) return
            val pct = systemVolumePercent()
            if (pct != lastSystemVolumePct) {
                lastSystemVolumePct = pct
                Log.i(TAG, "system media volume: $pct%")
                applyDacVolume()
            }
            mainHandler.postDelayed(this, 500)
        }
    }

    private fun systemVolumePercent(): Int {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 100
        val cur = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (cur * 100 / max).coerceIn(0, 100)
    }

    /** 硬件音量是否已被确认可用（首次尝试成功后置 true；失败则永久走软件 fallback）。 */
    private var hardwareVolumeUsable: Boolean = false
    private var hardwareVolumeTried: Boolean = false
    private var lastAppliedDacPct: Int = -1

    /**
     * USB 独占独立音量系数（0..1，默认 1.0），由设置页/歌曲信息页的"USB 音量"slider
     * 控制，仅独占开启时参与 DAC 音量计算，与应用内/系统音量分开记忆（Dart 持久化）。
     */
    private var usbVolumePercent: Float = 100f

    /**
     * 计算并应用 DAC 音量（硬件音量优先，无硬件音量/设置失败时回退软件缩放）：
     *   DAC 音量% = 系统媒体音量% × USB 音量系数(0..1)
     * 独占时不再乘播放器音量——应用内音量已由「USB 音量」面板取代，避免三层控制。
     */
    private fun applyDacVolume() {
        val sysPct = systemVolumePercent()
        val dacPct = (sysPct * (usbVolumePercent / 100f)).toInt().coerceIn(0, 100)
        if (dacPct != lastAppliedDacPct) {
            lastAppliedDacPct = dacPct
            Log.i(TAG, "applyDacVolume: sys=$sysPct% usbVol=${usbVolumePercent}% → dac=$dacPct%")
        }
        if (!UsbAudioSinkController.isEnabled()) return
        if (hardwareVolumeUsable) {
            usbAudioDevice.setDacVolume(dacPct)
        } else if (!hardwareVolumeTried) {
            // 首次尝试：成功则锁定硬件音量；失败（DAC 不支持）则回退软件音量
            hardwareVolumeTried = true
            if (usbAudioDevice.hasHardwareVolume && usbAudioDevice.setDacVolume(dacPct)) {
                hardwareVolumeUsable = true
                Log.i(TAG, "hardware volume usable — DAC 硬件音量接管")
            } else {
                Log.w(TAG, "hardware volume unavailable — 使用软件音量 fallback")
                UsbAudioStream.streamVolume = dacPct / 100f
            }
        } else {
            UsbAudioStream.streamVolume = dacPct / 100f
        }
    }

    /** enable 时重置硬件音量探测状态。 */
    private fun resetVolumeState() {
        hardwareVolumeUsable = false
        hardwareVolumeTried = false
        lastAppliedDacPct = -1
        UsbAudioStream.streamVolume = 1f
    }

    private fun startVolumePolling() {
        lastSystemVolumePct = -1
        mainHandler.removeCallbacks(volumePollRunnable)
        mainHandler.post(volumePollRunnable)
    }

    private fun stopVolumePolling() {
        mainHandler.removeCallbacks(volumePollRunnable)
    }

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
                    // 与 MethodChannel 的 disable 共用同一把锁，后台线程执行，
                    // 避免与手动关闭（RESET/config 切换）并发操作设备导致重复释放
                    Thread {
                        synchronized(exclusiveLock) {
                            if (UsbAudioSinkController.isEnabled()) disableExclusive()
                        }
                    }.start()
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

        // 播放器音量变化 → 更新 DAC 硬件音量（渲染线程回调，controlTransfer 很短可接受）
        UsbAudioSinkController.setVolumeListener { volume ->
            if (UsbAudioSinkController.isEnabled()) applyDacVolume()
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
            "setFloatOutputEnabled" -> {
                // 32bit 播放支持开关（默认关闭）。开启后在 DefaultAudioSink 的 float 决策点生效，
                // 下一首歌 configure 即按新开关走 float 高解析；关闭则回退 16bit 保证正确播放。
                val enabled = call.argument<Boolean>("enabled") ?: false
                UsbAudioSinkController.setFloatOutputEnabled(enabled)
                Log.i(TAG, "setFloatOutputEnabled: $enabled (float output ${if (enabled) "开启" else "关闭"})")
                result.success(true)
            }
            "enableExclusive" -> requestEnableInternal(result)
            "setUsbVolume" -> {
                // USB 独占独立音量（0..100），仅独占时参与 DAC 音量计算，实时生效
                val pct = (call.argument<Number>("percent")?.toFloat() ?: 100f)
                    .coerceIn(0f, 100f)
                usbVolumePercent = pct
                Log.i(TAG, "setUsbVolume: $pct% (仅 USB 独占生效)")
                applyDacVolume()
                result.success(getStatus())
            }
            "disableExclusive" -> {
                // RESET 会阻塞约 3s（等待设备重新枚举），必须在后台线程执行避免 ANR；
                // 加锁防止与 enableExclusive / 拔插恢复路径并发操作设备
                Thread {
                    synchronized(exclusiveLock) {
                        disableExclusive()
                        result.success(getStatus())
                    }
                }.start()
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
        base["hasHardwareVolume"] = usbAudioDevice.hasHardwareVolume && hardwareVolumeUsable
        base["usbVolumePercent"] = usbVolumePercent
        base["dacVolumePercent"] = if (UsbAudioSinkController.isEnabled()) {
            if (hardwareVolumeUsable) {
                // 硬件音量：DAC 音量% = 系统媒体音量% × USB 音量系数（独占时无播放器音量层）
                systemVolumePercent() * usbVolumePercent / 100f
            } else {
                UsbAudioStream.streamVolume * 100f
            }
        } else 0f
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
                // 与 disable 共用互斥锁，防止开关并发操作同一设备
                synchronized(exclusiveLock) {
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
                    if (ok) {
                        // 应用初始 DAC 音量 + 启动系统媒体音量轮询（音量键 → DAC 硬件音量）
                        mainHandler.post {
                            resetVolumeState()
                            applyDacVolume()
                            startVolumePolling()
                        }
                    }
                    mainHandler.post {
                        if (result != null) {
                            if (ok) result.success(getStatus())
                            else result.error("ENABLE_FAILED", "USB 独占开启失败", null)
                        }
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
        // 停止系统音量轮询（独占关闭后音量回到 AudioFlinger 管）
        stopVolumePolling()
        resetVolumeState()
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
        // 阶段二：释放接口 + USBDEVFS_CONNECT 重绑内核驱动 + close（见 closeDevice 内实现）
        usbAudioDevice.closeDevice()
        // 阶段三：设备释放完成后再恢复 delegate 音量/路由
        UsbAudioSinkController.onUsbReleased()
        Log.i(TAG, "disableExclusive done")
    }

    fun cleanup() {
        try { context.unregisterReceiver(usbReceiver) } catch (_: Exception) {}
        if (UsbAudioSinkController.isEnabled()) disableExclusive()
    }
}
