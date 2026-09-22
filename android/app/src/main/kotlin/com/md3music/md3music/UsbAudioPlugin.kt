package com.md3music.md3music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.AudioDeviceInfo
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

    /** 保存 channel 引用，供广播/开关路径向 Dart 推送最新状态（替代 Dart 每秒轮询）。 */
    private var channel: MethodChannel? = null

    /** 关闭独占后的延迟路由重试任务（重新 enable 时取消，防止与独占状态竞争）。 */
    private var rerouteRunnable: Runnable? = null

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
                UsbLog.i(TAG, "system media volume: $pct%")
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

    /** USB 独占独立音量系数（0..1，默认 1.0），由设置页/歌曲信息页的"USB 音量"slider
     * 控制，仅独占开启时参与 DAC 音量计算，与应用内/系统音量分开记忆（Dart 持久化）。
     */
    private var usbVolumePercent: Float = 100f

    /** 用户强制输出格式（0=自适应跟随源）。位深只影响流配置；率/声道还需数据路径转换。 */
    private var forceRate: Int = 0
    private var forceBits: Int = 0
    private var forceChannels: Int = 0

    /** 最近一次流创建的关键步骤摘要（诊断面板展示，覆盖式记录）。 */
    @Volatile
    private var lastSetupSummary: String = "-"

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
            UsbLog.i(TAG, "applyDacVolume: sys=$sysPct% usbVol=${usbVolumePercent}% → dac=$dacPct%")
        }
        if (!UsbAudioSinkController.isEnabled()) return
        if (hardwareVolumeUsable) {
            usbAudioDevice.setDacVolume(dacPct)
        } else if (!hardwareVolumeTried) {
            // 首次尝试：成功则锁定硬件音量；失败（DAC 不支持）则回退软件音量
            hardwareVolumeTried = true
            if (usbAudioDevice.hasHardwareVolume && usbAudioDevice.setDacVolume(dacPct)) {
                hardwareVolumeUsable = true
                UsbLog.i(TAG, "hardware volume usable — DAC 硬件音量接管")
            } else {
                UsbLog.w(TAG, "hardware volume unavailable — 使用软件音量 fallback")
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

    /**
     * 未开启独占时的 DAC 能力探测结果（只读描述符，不 claim 接口，不影响播放）。
     * key = "$vid:$pid"；同一设备只探测一次，拔插广播时失效。
     */
    private var capsKey: String? = null
    private var probedCaps: UsbAudioCapabilities? = null
    @Volatile
    private var capsProbeRunning = false

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
        capsKey = null
        probedCaps = null
    }

    /**
     * 必要时后台探测一次 DAC 能力（未开启独占且尚未探测过当前设备时）。
     *
     * 探测只 open→读描述符→close，不 claim 接口，不会打断内核驱动/正在播放的音频；
     * 为避免阻塞主线程（getStatus 每秒被调用），探测在后台线程执行，完成后推送状态。
     */
    private fun maybeProbeCaps(device: UsbDevice?) {
        if (device == null) return
        // 已打开设备：能力来自实际流配置，无需探测
        if (usbAudioDevice.getCachedInfo() != null) return
        // 独占开启中：设备已被 claim，二次 open 的控制传输会集体失败（实测 ret=-1），
        // 探测只会得到空结果并覆盖掉已有能力 —— 直接跳过
        if (UsbAudioSinkController.isEnabled()) return
        val key = "${device.vendorId}:${device.productId}"
        if (capsKey == key || capsProbeRunning) return
        // 无授权时无法打开设备；由用户点"读取 DAC 能力"走授权流程后探测
        if (!usbManager.hasPermission(device)) return
        capsProbeRunning = true
        Thread {
            val caps = usbAudioDevice.probeCapabilities(device)
            mainHandler.post {
                capsProbeRunning = false
                capsKey = key
                probedCaps = caps
                UsbLog.i(TAG, "auto probe caps: ${caps?.deviceName ?: "null"} " +
                        "uac=UAC${caps?.uacVersion} rates=${caps?.allRates?.contentToString()}")
                pushStatus()
            }
        }.apply { isDaemon = true; start() }
    }

    /** 用户手动触发的能力读取（无论是否已探测过都重新读），必要时先申请授权。 */
    private fun probeCapsInternal(result: MethodChannel.Result) {
        invalidateDeviceCache()
        val device = findCachedDevice()
        if (device == null) {
            result.error("NO_DEVICE", "未检测到 USB 音频设备", null)
            return
        }
        val done = {
            Thread {
                val caps = usbAudioDevice.probeCapabilities(device)
                mainHandler.post {
                    capsKey = "${device.vendorId}:${device.productId}"
                    // 探测失败（如独占中设备被 claim → 控制传输全部失败）时不要用空结果
                    // 覆盖已有的能力，否则下拉可选项会凭空消失
                    val worse = caps == null ||
                            (caps.allRates.isEmpty() && (probedCaps?.allRates?.isNotEmpty() == true))
                    if (!worse) probedCaps = caps
                    pushStatus()
                    result.success(getStatus())
                }
            }.apply { isDaemon = true; start() }
            Unit
        }
        if (usbManager.hasPermission(device)) {
            done()
        } else {
            UsbLog.i(TAG, "probeCaps: requesting permission for ${device.productName}")
            usbAudioDevice.requestPermission(device) { granted ->
                if (granted) done()
                else result.error("PERMISSION_DENIED", "USB 设备授权被拒绝", null)
            }
        }
    }

    /** 拔插广播：独占开启时拔线自动关闭（避免写坏 fd），重新插入自动恢复。 */
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    UsbLog.i(TAG, "USB_DEVICE_ATTACHED (exclusive=" + UsbAudioSinkController.isEnabled() + ")")
                    invalidateDeviceCache()
                    // 未开独占时 UI 也要刷新"设备已连接"（替代轮询发现）
                    pushStatus()
                    if (UsbAudioSinkController.isEnabled()) {
                        // 重插后设备需重新授权 + 重建流
                        requestEnableInternal(null)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    UsbLog.w(TAG, "USB_DEVICE_DETACHED — 自动关闭独占，避免写入失效 fd")
                    invalidateDeviceCache()
                    // 与 MethodChannel 的 disable 共用同一把锁，后台线程执行，
                    // 避免与手动关闭（RESET/config 切换）并发操作设备导致重复释放
                    Thread {
                        synchronized(exclusiveLock) {
                            if (UsbAudioSinkController.isEnabled()) disableExclusive()
                            // 拔线后 UI 即时刷新（含自动暂停逻辑），替代轮询兜底
                            pushStatus()
                        }
                    }.start()
                }
            }
        }
    }

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                handleMethod(call, result)
            } catch (e: Exception) {
                UsbLog.e(TAG, "handleMethod(" + call.method + ") threw: " + e.message, e)
                if (call.method != "enableExclusive") {
                    result.error("INTERNAL_ERROR", e.message, null)
                }
            }
        }

        // just_audio 模块链路日志桥接：只进应用侧环形缓冲（源头已写 logcat，避免重复）
        UsbAudioSinkController.setLogForwarder { level, tag, msg ->
            UsbLog.bridge(level, tag, msg)
        }

        // 采样率/声道变化 → 应用侧重建流（在 ExoPlayer 渲染线程回调）
        UsbAudioSinkController.setReconfigListener { rate, ch, enc ->
            UsbLog.i(TAG, "reconfig requested: $rate Hz / $ch ch / enc=$enc")
            val adapter = rebuildStream(rate, ch)
            // 重建后推送最新状态：切歌/采样率钳制后 Dart 侧格式链需实时刷新
            // （失败时控制器已 disable 回退普通输出，推送同样让 UI 同步）
            pushStatus()
            adapter
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
            UsbLog.e(TAG, "registerReceiver failed: ${e.message}")
        }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "getStatus" -> result.success(getStatus())
            "getFormatInfo" -> result.success(UsbAudioSinkController.getFormatInfo())
            "getUsbLogs" -> {
                // 三路合并：app 内存环形 + native（USB 传输层）环形 + logcat 自读（just_audio 模块）
                result.success(
                        UsbLog.exportAll() +
                        "\n── native 环形（USB 传输层） ──\n" + UsbAudioStream.recentNativeLogs())
            }
            "isEnabled" -> result.success(UsbAudioSinkController.isEnabled())
            "probeDacCapabilities" -> probeCapsInternal(result)
            "setFloatOutputEnabled" -> {
                // 32bit 播放支持开关（默认关闭）。开启后在 DefaultAudioSink 的 float 决策点生效，
                // 下一首歌 configure 即按新开关走 float 高解析；关闭则回退 16bit 保证正确播放。
                val enabled = call.argument<Boolean>("enabled") ?: false
                UsbAudioSinkController.setFloatOutputEnabled(enabled)
                UsbLog.i(TAG, "setFloatOutputEnabled: $enabled (float output ${if (enabled) "开启" else "关闭"})")
                result.success(true)
            }
            "setDitherEnabled" -> {
                // TPDF 抖动降位开关（默认关闭）。独占数据路径每次 writeRaw 都会读取，
                // 因此切换立即生效（无需重建流/切歌）。仅在源位深 > 端点位深时参与。
                val enabled = call.argument<Boolean>("enabled") ?: false
                UsbAudioStream.ditherEnabled = enabled
                UsbLog.i(TAG, "setDitherEnabled: $enabled (TPDF 抖动 ${if (enabled) "开启" else "关闭"})")
                result.success(true)
            }
            "enableExclusive" -> requestEnableInternal(result)
            "setOutputFormatOverride" -> {
                // 输出格式强制（0=自适应）：位深只影响流配置；率/声道另需数据路径转换。
                // 独占开启中时后台重建流使其立即生效。
                forceRate = (call.argument<Number>("sampleRate")?.toInt() ?: 0).coerceIn(0, 384000)
                forceBits = (call.argument<Number>("bitDepth")?.toInt() ?: 0).coerceIn(0, 32)
                forceChannels = (call.argument<Number>("channelCount")?.toInt() ?: 0).coerceIn(0, 8)
                UsbAudioSinkController.setOutputOverride(
                        if (forceRate > 0) forceRate else 0,
                        if (forceChannels > 0) forceChannels else 0)
                UsbLog.i(TAG, "setOutputFormatOverride: rate=$forceRate bits=$forceBits channels=$forceChannels")
                if (UsbAudioSinkController.isEnabled()) {
                    Thread {
                        synchronized(exclusiveLock) {
                            try {
                                UsbAudioSinkController.reconfigureActiveStream()
                            } catch (e: Exception) {
                                UsbLog.e(TAG, "override rebuild failed: ${e.message}")
                            }
                            pushStatus()
                        }
                    }.start()
                }
                result.success(getStatus())
            }
            "setUsbVolume" -> {
                // USB 独占独立音量（0..100），仅独占时参与 DAC 音量计算，实时生效
                val pct = (call.argument<Number>("percent")?.toFloat() ?: 100f)
                    .coerceIn(0f, 100f)
                usbVolumePercent = pct
                UsbLog.i(TAG, "setUsbVolume: $pct% (仅 USB 独占生效)")
                applyDacVolume()
                result.success(getStatus())
            }
            "disableExclusive" -> {
                // RESET 会阻塞约 3s（等待设备重新枚举），必须在后台线程执行避免 ANR；
                // 加锁防止与 enableExclusive / 拔插恢复路径并发操作设备
                Thread {
                    synchronized(exclusiveLock) {
                        disableExclusive()
                        // 推送最新状态（UI 即时刷新），替代轮询兜底
                        pushStatus()
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
        // UAC 版本/总线速度/能力：优先取已打开设备的实际配置，其次取未开启独占时的描述符探测结果
        val caps = probedCaps
        val uacVersion = cached?.uacVersion ?: caps?.uacVersion ?: 0
        val fullSpeed = cached?.fullSpeed ?: caps?.fullSpeed
        base["deviceConnected"] = device != null
        base["deviceName"] = cached?.deviceName ?: caps?.deviceName ?: device?.productName
        base["deviceManufacturer"] = caps?.manufacturer ?: device?.manufacturerName
        base["deviceVid"] = device?.vendorId ?: caps?.vid ?: 0
        base["devicePid"] = device?.productId ?: caps?.pid ?: 0
        base["uacVersion"] = uacVersion
        base["uacLabel"] = if (uacVersion > 0) "UAC$uacVersion" else ""
        base["usbSpeed"] = fullSpeed?.let { if (it) "full" else "high" } ?: ""
        base["capabilitiesSource"] = when {
            cached != null -> "active"
            caps != null -> "probed"
            else -> "none"
        }
        base["altSettingCount"] = cached?.altSettingCount ?: caps?.altCount ?: 0
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
        // 输出格式选择：DAC 能力并集 + 当前 override（UI 生成可选项用）。
        // 优先已打开设备的实际能力；其为空（如 openDevice 时 GET_RANGE 失败）时
        // 回落到未开启独占时探测到的能力，避免下拉可选项莫名消失。
        base["supportedRates"] = pickCaps(cached?.allRates, caps?.allRates).toList()
        base["supportedBits"] = pickCaps(cached?.allBits, caps?.allBits).toList()
        base["supportedChannels"] = pickCaps(cached?.allChannels, caps?.allChannels).toList()
        base["rateRangeMin"] = caps?.rateMin ?: 0
        base["rateRangeMax"] = caps?.rateMax ?: 0
        base["outputRateOverride"] = forceRate
        base["outputBitsOverride"] = forceBits
        base["outputChannelsOverride"] = forceChannels
        base["ditherEnabled"] = UsbAudioStream.ditherEnabled
        // 钳制后真正下发给 DAC 的率（override≠effective 说明被 DAC 能力降级，UI 需提示）
        base["outputRateEffective"] = UsbAudioSinkController.getTargetOutputRate()
        // Salt Player 式诊断（「调试信息」面板展示/复制，便于远程定位 DAC 兼容问题）：
        // 三段结构 = Playback（运行状态/有效格式/override）+ Stream Setup（最近一次流创建步骤链）+ Device（拓扑/端点/能力）
        val playback = UsbAudioSinkController.getStatus()
        val diag = StringBuilder()
        diag.appendLine("── Playback ──")
        diag.appendLine("Enabled: ${playback["enabled"]} / StreamAlive: ${playback["streamAlive"]}")
        diag.appendLine("Output: ${playback["sampleRate"]} Hz / ${playback["channelCount"]} ch / ${playback["dacBitDepth"]}-bit")
        diag.appendLine("Decoded: ${playback["lastSampleRate"]} Hz / ${playback["lastChannelCount"]} ch / enc=" +
                UsbAudioSinkController.encName((playback["lastEncoding"] as? Number)?.toInt() ?: 0))
        diag.appendLine("Override: rate=$forceRate bits=$forceBits channels=$forceChannels")
        diag.appendLine("FramesWritten: ${playback["framesWritten"]}")
        diag.appendLine("── Stream Setup (last) ──")
        diag.appendLine(lastSetupSummary)
        diag.appendLine("── Device ──")
        diag.append(usbAudioDevice.buildDiagnostics(device, cached))
        if (cached == null && caps != null) {
            // 未开启独占：能力来自描述符探测（不打开设备），单独列出便于对照
            diag.appendLine("── Probed Capabilities (未打开设备) ──")
            diag.appendLine("Source: ${caps.manufacturer.ifEmpty { "-" }} / ${caps.deviceName}")
            diag.appendLine("UAC Version: UAC${caps.uacVersion}")
            diag.appendLine("USB Speed: ${if (caps.fullSpeed) "full" else "high"}")
            diag.appendLine("Alt Settings: ${caps.altCount}")
            diag.appendLine("Rates: ${caps.allRates.joinToString(",")}" +
                    (if (caps.rateMin > 0) " (range ${caps.rateMin}-${caps.rateMax})" else ""))
            diag.appendLine("Bits: ${caps.allBits.joinToString(",")}")
            diag.appendLine("Channels: ${caps.allChannels.joinToString(",")}")
        }
        base["diagnostics"] = diag.toString()
        // 未开启独占时异步探测一次 DAC 能力（供 UI 生成可选项），不阻塞本次返回
        maybeProbeCaps(device)
        return base
    }

    /**
     * 查找当前连接的 USB 音频输出设备（AudioDeviceInfo，供非独占路由）。
     * AudioFlinger 不会自动把 USB 设为输出路由（重新插拔才触发），
     * 关闭独占后必须显式 setPreferredDevice 到 USB，声音才能继续走 DAC。
     */
    private fun findUsbAudioDeviceInfo(): AudioDeviceInfo? {
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull {
                it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
            }
    }

    /**
     * 状态变化 → 主动推送 Dart（替代 Dart 每秒轮询）。仅事件路径调用：
     * 拔插广播 / 广播触发的自动恢复（无 MethodChannel 调用方）会真正依赖它；
     * Dart 调用方（enable/disable）同时从返回值拿到同一份状态，幂等。
     */
    /** 能力数组择优：优先非空的活跃能力，其次探测能力，都空则空数组。 */
    private fun pickCaps(active: IntArray?, probed: IntArray?): IntArray {
        if (active != null && active.isNotEmpty()) return active
        if (probed != null && probed.isNotEmpty()) return probed
        return intArrayOf()
    }

    private fun pushStatus() {
        val ch = channel ?: return
        val status = getStatus()
        mainHandler.post { ch.invokeMethod("onStatusChanged", status) }
    }

    // ── 开关 ─────────────────────────────────────────────────────

    /** 开启独占（可带授权流程）。result 为空时表示由拔插广播触发。 */
    private fun requestEnableInternal(result: MethodChannel.Result?) {
        val device = findCachedDevice()
        if (device == null) {
            UsbLog.e(TAG, "enableExclusive: no USB audio device")
            if (result != null) result.error("NO_DEVICE", "未检测到 USB 音频设备", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            doEnable(device, result)
        } else {
            UsbLog.i(TAG, "enableExclusive: requesting permission for ${device.productName}")
            usbAudioDevice.requestPermission(device) { granted ->
                if (granted) {
                    doEnable(device, result)
                } else {
                    UsbLog.e(TAG, "enableExclusive: permission denied")
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
                    // enable 记录必须与实际建流的率/声道一致（同为 override+钳制统一出口），
                    // 否则 handleBuffer 的"源≠流"转换判断失效（如 192k 源错位后不降采样）
                    val rate = UsbAudioSinkController.getTargetOutputRate().takeIf { it > 0 }
                            ?: (UsbAudioSinkController.getLastSampleRate().takeIf { it > 0 } ?: DEFAULT_SAMPLE_RATE)
                    val ch = UsbAudioSinkController.getTargetOutputChannels().takeIf { it > 0 }
                            ?: (UsbAudioSinkController.getLastChannelCount().takeIf { it > 0 } ?: DEFAULT_CHANNELS)
                    val ok = UsbAudioSinkController.enable(adapter, currentDacBitDepth, rate, ch)
                    if (ok) {
                        // 应用初始 DAC 音量 + 启动系统媒体音量轮询（音量键 → DAC 硬件音量）
                        mainHandler.post {
                            // 取消未执行的关独占延迟路由任务（防止与独占状态竞争）
                            rerouteRunnable?.let { mainHandler.removeCallbacks(it) }
                            rerouteRunnable = null
                            // 独占直写 DAC 时 delegate 静音且不喂数据，路由回系统默认，
                            // 避免与 usb HAL 竞争（非独占路由在 disable 时再切回 USB）
                            UsbAudioSinkController.setDelegatePreferredDevice(null)
                            resetVolumeState()
                            applyDacVolume()
                            startVolumePolling()
                        }
                    }
                    mainHandler.post {
                        // 无论谁触发（Dart 调用 / 拔插广播自动恢复），都推送最新状态；
                        // Dart 调用方还会从 result 拿到同一份状态（幂等）。
                        pushStatus()
                        if (result != null) {
                            if (ok) result.success(getStatus())
                            else result.error("ENABLE_FAILED", "USB 独占开启失败", null)
                        }
                    }
                }
            } catch (e: Exception) {
                UsbLog.e(TAG, "doEnable threw: ${e.message}", e)
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
        // 目标格式：用户 override 优先（0=自适应）；自适应经 getTargetOutputRate 统一出口
        // （含 DAC 能力钳制：192k 等超出端点装包能力的采样率自动降级，如 → 96k）
        val targetRate = if (forceRate > 0) forceRate
        else UsbAudioSinkController.getTargetOutputRate().takeIf { it > 0 } ?: 0
        val ch = if (forceChannels > 0) forceChannels
        else UsbAudioSinkController.getTargetOutputChannels().takeIf { it > 0 } ?: DEFAULT_CHANNELS
        var info = usbAudioDevice.openDevice(device, targetRate, forceBits)
        if (info == null) {
            UsbLog.e(TAG, "openDevice failed")
            lastSetupSummary = "openDevice failed (target=$targetRate Hz/${forceBits}bit)"
            return null
        }
        // 首次建流时 DAC 能力尚未同步（clampToDacRate 会直通 192k 等超能力率）；
        // openDevice 已解析出全部能力，立即同步并重算目标率/声道——若被钳制
        // （如 192000→96000、24000→44100、声道≠端点声道）则用新格式重开
        // （openDevice 缓存命中，开销极低）。
        UsbAudioSinkController.setDacSupportedRates(info.allRates.toList().toIntArray())
        UsbAudioSinkController.setDacChannels(info.allChannels.maxOrNull() ?: 0)
        val finalRate = UsbAudioSinkController.getTargetOutputRate().takeIf { it > 0 } ?: targetRate
        val finalCh = UsbAudioSinkController.getTargetOutputChannels().takeIf { it > 0 } ?: ch
        if (finalRate != targetRate || finalCh != ch) {
            info = usbAudioDevice.openDevice(device, finalRate, forceBits)
            if (info == null) {
                UsbLog.e(TAG, "openDevice(clamped) failed")
                lastSetupSummary =
                        "openDevice failed (clamped $finalRate Hz/$finalCh ch/${forceBits}bit)"
                return null
            }
        }
        val rate = finalRate.takeIf { it > 0 } ?: DEFAULT_SAMPLE_RATE
        // 声道必须用钳制后的 finalCh：native 流声道若与控制器记录的 usbChannelCount
        // 不一致（如此前误用旧 ch），handleBuffer 会按错误声道数转换/装包导致数据错乱。
        val outCh = finalCh.takeIf { it > 0 } ?: DEFAULT_CHANNELS
        val bitDepth = info.bestBitDepth
        val altSetting = info.bestAltSetting

        val stream = UsbAudioStream(
            info.fd, info.interfaceId, info.endpointOutAddress, info.endpointFeedbackAddress,
            rate, outCh, bitDepth, info.maxPacketSize, info.fullSpeed
        )
        if (!stream.isReady) {
            stream.release()
            lastSetupSummary = "stream create failed (fd=${info.fd}, $rate Hz/$outCh ch/${bitDepth}bit)"
            return null
        }

        // Step 1: setAlt(0) — 原生 SETINTERFACE(interfaceId, 0)，按已 claim 的接口精确执行；
        // 失败仅记录继续（接口已正确 claim，不再整设备 close+reopen）
        val alt0Ok = stream.setAltSetting(0)
        if (!alt0Ok) {
            UsbLog.w(TAG, "Step 1: setAlt(0) failed (iface=${info.interfaceId}) — 继续")
        } else {
            UsbLog.i(TAG, "Step 1: setAlt(0) OK")
        }

        val altOk: Boolean
        if (info.uacVersion == 1) {
            // UAC1：先激活端点（setAlt(N) 分配带宽）再 SET_CUR —— 端点请求要求接口非零 alt，
            // 在 alt=0 状态下 SET_CUR 会被 STALL（噪声根因之一）
            stream.setAltSetting(0)
            altOk = stream.setAltSetting(altSetting)
            UsbLog.i(TAG, "Step 4-5(UAC1): setAlt(0)+setAlt($altSetting)=$altOk")
            usbAudioDevice.setSampleRate(rate)
            val clockValid = usbAudioDevice.readClockValid()
            UsbLog.i(TAG, "Step 2-3(UAC1, after alt): SET_CUR=$rate CLOCK_VALID=$clockValid")
            lastSetupSummary = "UAC1 alt(0)=$alt0Ok alt($altSetting)=$altOk SET_CUR=$rate Hz"
        } else {
            // UAC2：clock 实体请求走 AC 接口，与 alt 无关，保持原序
            usbAudioDevice.setSampleRate(rate)
            val clockValid = usbAudioDevice.readClockValid()
            UsbLog.i(TAG, "Step 2-3: SET_CUR=$rate CLOCK_VALID=$clockValid")

            // Step 4: 防御性 setAlt(0) + Step 5: setAlt(N) 分配新 ring
            stream.setAltSetting(0)
            altOk = stream.setAltSetting(altSetting)
            UsbLog.i(TAG, "Step 4-5: setAlt(0)+setAlt($altSetting)=$altOk")
            lastSetupSummary = "UAC2 SET_CUR=$rate Hz alt($altSetting)=$altOk"
        }

        // Step 6: DAC PLL 锁定时
        Thread.sleep(50)

        // Step 7: start
        if (!stream.start()) {
            UsbLog.e(TAG, "stream.start() failed")
            stream.release()
            lastSetupSummary = "$lastSetupSummary → start failed"
            return null
        }
        currentDacBitDepth = bitDepth
        lastSetupSummary = "$lastSetupSummary → ACTIVE $rate Hz/$ch ch/${bitDepth}bit " +
                "${if (info.fullSpeed) "full" else "high"}-speed alt=$altSetting"
        UsbLog.i(TAG, "USB stream ACTIVE: $rate Hz / $ch ch / ${bitDepth}bit @ ${info.deviceName} " +
                "(uac=UAC${info.uacVersion}, ${if (info.fullSpeed) "full-speed" else "high-speed"}, " +
                "rates=${info.supportedRates.contentToString()})")
        // 同步 DAC 能力给 Controller：输出采样率超出能力时自动降级（如 192k → 96k），
        // 避免 native 装包超过 maxPacket 导致 SUBMITURB 失败/堆溢出。
        UsbAudioSinkController.setDacSupportedRates(info.allRates.toList().toIntArray())
        return UsbAudioAdapter(stream)
    }

    /** 采样率/声道变化时重建流（UsbAudioSinkController 回调，渲染线程执行）。 */
    private fun rebuildStream(rate: Int, ch: Int): UsbAudioSink? {
        return try {
            val device = findCachedDevice()
                ?: run { UsbLog.e(TAG, "rebuild: no device"); currentAdapter = null; return null }
            if (!usbManager.hasPermission(device)) {
                UsbLog.e(TAG, "rebuild: no permission")
                currentAdapter = null
                return null
            }
            val adapter = createStartedStream(device) ?: run {
                UsbLog.e(TAG, "rebuild: createStartedStream failed")
                // 旧流已被控制器 stop/drain/release，必须清空引用防止二次 release
                currentAdapter = null
                return null
            }
            currentAdapter = adapter
            UsbLog.i(TAG, "rebuild OK: $rate Hz / $ch ch")
            adapter
        } catch (e: Exception) {
            UsbLog.e(TAG, "rebuild threw: ${e.message}", e)
            currentAdapter = null
            null
        }
    }

    private fun disableExclusive() {
        // 清空 DAC 能力缓存（防换 DAC/重插后旧能力残留钳制）
        UsbAudioSinkController.resetDacCapabilities()
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
                UsbLog.e(TAG, "disableExclusive release failed: ${e.message}")
            }
        }
        currentAdapter = null
        // 阶段二：释放接口 + USBDEVFS_CONNECT 重绑内核驱动 + close（见 closeDevice 内实现）
        usbAudioDevice.closeDevice()
        // 阶段三：设备释放完成后再恢复 delegate 音量/路由
        UsbAudioSinkController.onUsbReleased()
        // 关闭独占后把 delegate AudioTrack 显式路由到 USB DAC（系统非独占输出）。
        // AudioFlinger 不会因设备交还内核而自动重新路由 USB（需重新插拔才触发），
        // 必须显式 setPreferredDevice，否则声音会回扬声器/无声。
        // 注意：closeDevice 刚把 DAC 交还内核，usb HAL 打开需要时间（snd-usb-audio
        // probe + AudioFlinger 枚举）。立即迁移会让 AudioTrack 连到未就绪设备 →
        // 静默无声（进度条照走，暂停→重播才恢复）。故延迟 500ms 待 usb HAL 接管后
        // 重新设置路由，并强制 AudioTrack 重新 start（等效用户暂停→重播）。
        val usbDev = findUsbAudioDeviceInfo()
        UsbAudioSinkController.setDelegatePreferredDevice(usbDev)
        UsbLog.i(TAG, "disableExclusive done (delegate routed to USB: ${usbDev?.productName ?: "none"})")
        // 根因：开启独占时 force disconnect 杀死了 usb HAL 的旧输出流；关闭独占后
        // delegate AudioTrack 仍连在失效流上 → 数据照走但 DAC 无声。setPreferredDevice
        // / pause / play 都不会重建该流——只有 Media3 重建 AudioTrack（configure）才能让
        // usb HAL 重新创建输出流。重建由 Dart 侧在收到 enabled→false 后自动执行
        // "暂停→重播"触发；此处只负责延迟重设 preferredDevice（确保重建时字段为 USB）。
        val task = Runnable {
            val dev = findUsbAudioDeviceInfo()
            UsbAudioSinkController.setDelegatePreferredDevice(dev)
            UsbLog.i(TAG, "delegate USB re-route (delayed): ${dev?.productName ?: "none"}")
        }
        rerouteRunnable = task
        mainHandler.postDelayed(task, 500)
    }

    fun cleanup() {
        try { context.unregisterReceiver(usbReceiver) } catch (_: Exception) {}
        if (UsbAudioSinkController.isEnabled()) disableExclusive()
    }
}
