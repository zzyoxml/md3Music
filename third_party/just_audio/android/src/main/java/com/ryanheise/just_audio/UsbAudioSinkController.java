package com.ryanheise.just_audio;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.os.Build;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * USB 独占输出控制器（MD3Music fork）。
 *
 * 设计（对齐 decent-player 的 UsbAudioSink.kt，裁剪掉 NativeAudioEngine 部分）：
 * - [wrap] 始终包装 AudioSink：未开启独占时完全透传，开启后拦截 handleBuffer 的
 *   PCM → UsbStreamingThread → 应用侧 UsbAudioSink（JNI usbdevfs 直写 DAC）。
 * - 包装器在 ExoPlayer 构建时注入，运行时开关（enable/disable）无需重建播放器。
 * - 委托 AudioTrack 保持存活但被静音并强制路由内置扬声器，仅用于 ExoPlayer 时钟/状态机。
 * - 采样率/声道变化（configure 回调）时经 [UsbAudioReconfigListener] 交给应用侧重建流。
 *
 * 线程模型：configure/handleBuffer 在 ExoPlayer 渲染线程执行；USB 写入在
 * UsbStreamingThread（MAX_PRIORITY）执行；enable/disable 由应用侧 MethodChannel 线程触发。
 */
public final class UsbAudioSinkController {

    private static final String TAG = "UsbAudioSinkCtrl";

    /** 队列接近满时返回 false，让 ExoPlayer 稍后重试（背压，匹配 DAC 时钟）。 */
    private static final int QUEUE_BACKPRESSURE_THRESHOLD = 16;

    // ── 日志桥接：链路日志进入应用侧环形缓冲（诊断导出），logcat 行为不变 ──

  /** 应用侧日志桥接（USB 链路环形日志，见 app 模块 UsbLog）。 */
  public interface UsbLogForwarder {
    void forward(char level, String tag, String msg);
  }

  private static volatile UsbLogForwarder logForwarder = null;

  public static void setLogForwarder(UsbLogForwarder forwarder) {
    logForwarder = forwarder;
  }

  static void logI(String tag, String msg) {
    Log.i(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('I', tag, msg);
  }

  static void logW(String tag, String msg) {
    Log.w(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('W', tag, msg);
  }

  static void logE(String tag, String msg) {
    Log.e(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('E', tag, msg);
  }

  static void logE(String tag, String msg, Throwable tr) {
    Log.e(tag, msg, tr);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('E', tag, tr != null ? msg + ": " + tr.getMessage() : msg);
  }

  // ── 全局开关与活动流（由应用侧 UsbAudioPlugin 管理） ──
    private static volatile boolean exclusiveEnabled = false;
    private static volatile UsbAudioSink activeStream = null;
    private static volatile int activeDacBitDepth = 0;
    private static volatile UsbAudioReconfigListener reconfigListener = null;

    // ── 32bit 播放支持开关（默认关闭） ─────────────────────────
    // 开启后让 ExoPlayer 恢复 float 输出（24/32bit 高规格走 float32 直通 AudioTrack）。
    // 注意：部分设备 stereo float 播放异常（速度加快/音高变高），故默认关闭，需用户主动开启。
    // DefaultAudioSink 每个 configure 都会读取该实时标志，因此切歌即生效，无需重建播放器。
    private static volatile boolean floatOutputEnabled = false;

    public static void setFloatOutputEnabled(boolean enabled) {
        floatOutputEnabled = enabled;
    }

    public static boolean isFloatOutputEnabled() {
        return floatOutputEnabled;
    }

    // ── 输出格式强制（0=自适应跟随源；由应用侧经 setOutputFormatOverride 下发） ──
    // 位深强制只影响流配置（插件侧），率/声道在 handleBuffer 拦截路径做转换。
    private static volatile int outputOverrideRate = 0;
    private static volatile int outputOverrideChannels = 0;

    public static void setOutputOverride(int sampleRate, int channelCount) {
        outputOverrideRate = sampleRate > 0 ? sampleRate : 0;
        outputOverrideChannels = channelCount > 0 ? channelCount : 0;
        logI(TAG, "setOutputOverride: rate=" + outputOverrideRate + " ch=" + outputOverrideChannels);
    }

    /** 有效输出采样率（override 优先，否则 0 由调用方兜底）；最后按 DAC 能力钳制。 */
    private static int effectiveRate(int sourceRate) {
        int rate = outputOverrideRate > 0 ? outputOverrideRate : sourceRate;
        return clampToDacRate(rate);
    }

    // ── DAC 能力（应用侧 rebuildStream 成功后同步；null/空=未知不限制） ──
    private static volatile int[] dacSupportedRates = null;
    /** 上次钳制日志记录的目标率（去重，避免 handleBuffer 每块刷屏）。 */
    private static int lastClampedRate = 0;

    public static void setDacSupportedRates(int[] rates) {
        dacSupportedRates = rates;
    }

    /**
     * 采样率钳制：超出 DAC 能力时自动降级 —— 选 ≤目标 的最大支持率；
     * 支持率全部高于目标时取最小。192kHz 等超出 full-speed 端点装包能力的
     * 采样率若不降级，native 装包会超过 maxPacket 导致 SUBMITURB 失败/堆溢出。
     */
    private static int clampToDacRate(int rate) {
        int[] rates = dacSupportedRates;
        if (rates == null || rates.length == 0 || rate <= 0) return rate;
        for (int r : rates) {
            if (r == rate) return rate;
        }
        int best = rates[0];
        for (int r : rates) {
            if (r <= rate && r > best) best = r;
        }
        if (best > rate) {
            best = rates[0];
            for (int r : rates) {
                if (r < best) best = r;
            }
        }
        if (best != lastClampedRate) {
            logI(TAG, "rate clamped to DAC capability: " + rate + " → " + best);
            lastClampedRate = best;
        }
        return best;
    }

    /** 有效输出声道数（override 优先，否则 0 由调用方兜底）；最后按 DAC 端点能力钳制。 */
    private static int effectiveChannels(int sourceChannels) {
        int ch = outputOverrideChannels > 0 ? outputOverrideChannels : sourceChannels;
        return clampToDacChannels(ch);
    }

    // ── DAC 端点声道数（应用侧建流成功后同步；0=未知不限制） ──
    private static volatile int dacChannels = 0;
    /** 上次钳制日志记录的目标声道（去重）。 */
    private static int lastClampedChannels = 0;
    /** 不支持编码的一次性警告标志。 */
    private static boolean convertUnsupportedWarned = false;
    /** handleBuffer 计数镜像（写线程快照用，区分 renderer 未喂 vs 喂了未转换）。 */
    private static volatile int lastHandleBufferCount = 0;

    public static void setDacChannels(int ch) {
        dacChannels = ch;
    }

    /** 设备关闭/更换时重置能力缓存与钳制日志去重（防旧设备能力残留）。 */
    public static void resetDacCapabilities() {
        dacSupportedRates = null;
        dacChannels = 0;
        lastClampedRate = 0;
        lastClampedChannels = 0;
    }

    /** 插件建流用：override 优先 + DAC 端点声道钳制后的最终声道数。 */
    public static int getTargetOutputChannels() {
        return clampToDacChannels(effectiveChannels(lastChannelCount));
    }

    /**
     * 声道钳制：流声道必须等于端点 bNrChannels，否则 DAC 按端点声道解释数据导致变调
     * （如 1ch 数据写 2ch 端点 → 速度 2 倍）。源声道不符由 handleBuffer 上/下混处理。
     */
    private static int clampToDacChannels(int ch) {
        int dac = dacChannels;
        if (dac <= 0 || ch <= 0 || ch == dac) return ch;
        if (dac != lastClampedChannels) {
            logI(TAG, "channels clamped to DAC endpoint: " + ch + " → " + dac);
            lastClampedChannels = dac;
        }
        return dac;
    }

    /** 供写线程在 Queue EMPTY 首次触发时输出状态快照（定位 renderer 停喂）。 */
    static void logStreamingState(String reason, boolean threadAlive, int queueSize) {
        logW(TAG, reason + " | usbRate=" + usbSampleRate + "Hz/" + usbChannelCount + "ch"
                + " enc=" + encName(lastEncoding) + " srcRate=" + lastSampleRate
                + " srcCh=" + lastChannelCount + " overrideRate=" + outputOverrideRate
                + " overrideCh=" + outputOverrideChannels
                + " hbCount=" + lastHandleBufferCount
                + " queue=" + queueSize + " threadAlive=" + threadAlive);
    }

    /** 插件建流用：override 优先 + DAC 能力钳制后的最终输出率（自适应场景自动降级 192k→96k）。 */
    public static int getTargetOutputRate() {
        return clampToDacRate(effectiveRate(lastSampleRate));
    }

    // ── 最近一次 ExoPlayer 解码输出格式（无论是否开启独占都会捕获，供歌曲信息页/初始化使用） ──
    private static volatile int lastSampleRate = 0;
    private static volatile int lastChannelCount = 0;
    private static volatile int lastEncoding = C.ENCODING_PCM_16BIT;

    // ── 当前 USB 流实际使用的采样率/声道（格式变更检测用） ──
    private static volatile int usbSampleRate = 0;
    private static volatile int usbChannelCount = 0;

    /** 最近一次播放器音量（0..1）。DAC 音量 = 系统媒体音量 × 该值。 */
    private static volatile float lastPlayerVolume = 1f;

    /**
     * 应用侧指定的 delegate 偏好输出设备（如 USB DAC）。
     * 关闭独占后显式路由到 USB，实现"非独占仍走 DAC"；开启独占时置 null 回到系统默认。
     * 保存在静态字段：关闭独占时若没有活跃 sink，后续新建的 sink 也会在 configure 时应用。
     */
    private static volatile AudioDeviceInfo preferredDevice = null;

    /**
     * 设置 delegate AudioTrack 的偏好输出设备（ForwardingAudioSink 已转发给 DefaultAudioSink）。
     * 设备已存在时 DefaultAudioSink 即时调用 AudioTrack.setPreferredDevice 切换；不存在时
     * 缓存在 DefaultAudioSink.preferredDevice，下次 configure 创建 AudioTrack 时应用。
     */
    public static void setDelegatePreferredDevice(@Nullable AudioDeviceInfo device) {
        preferredDevice = device;
        if (Build.VERSION.SDK_INT < 23) return;
        for (UsbInterceptAudioSink s : liveSinks) s.setPreferredDevice(device);
    }

    /** 新 sink 在 configure 时应用静态偏好路由（关闭独占后创建的 sink 也要走 USB）。 */
    private static void applyPreferredDeviceIfNeeded(UsbInterceptAudioSink sink) {
        AudioDeviceInfo device = preferredDevice;
        if (device != null && Build.VERSION.SDK_INT >= 23) {
            sink.setPreferredDevice(device);
        }
    }

    /**
     * 延迟重试用：强制所有 delegate AudioTrack 重新 start（等效用户暂停→重播）。
     * AudioTrack 迁移到未就绪的 USB 设备会静默失败（无声但数据照走），
     * pause+play 让 AudioFlinger 基于当前已就绪的设备重新路由。
     */
    public static void restartDelegateRouting() {
        for (UsbInterceptAudioSink s : liveSinks) s.restartRouting();
    }

    /** 播放器音量变化回调（应用侧用它更新 DAC 硬件音量）。 */
    public interface UsbVolumeListener {
        void onPlayerVolumeChanged(float volume);
    }

    private static volatile UsbVolumeListener volumeListener = null;

    public static void setVolumeListener(UsbVolumeListener listener) {
        volumeListener = listener;
    }

    public static float getLastPlayerVolume() {
        return lastPlayerVolume;
    }

    // ── 渲染器停喂自愈（Queue EMPTY 兜底） ─────────────────────────
    // ExoPlayer 渲染循环一旦停喂（configure 竞态/渲染器内因），USB 队列持续空转
    // 且无错误抛出（实测 hbCount 冻结 2.5s+）。从 sink 侧唯一能唤醒渲染器的
    // 手段是 seek：触发 onPositionReset → flushOrReinitializeCodec → 重新预滚。
    // 由应用侧 AudioPlayer 注册 listener，经主线程执行 seekTo(当前进度)。

    /** 渲染器停喂回调（应用侧实现：主线程 seek 当前位置）。 */
    public interface StallRecoveryListener {
        void onRendererStalled();
    }

    private static volatile StallRecoveryListener stallRecoveryListener = null;

    public static void setStallRecoveryListener(@Nullable StallRecoveryListener l) {
        stallRecoveryListener = l;
    }

    /** 停喂判定阈值（ms）：最后一次入队后静默超过该值视为停喂。 */
    private static final long STALL_THRESHOLD_MS = 2500L;
    /** 自愈冷却（ms），防止 seek 风暴。 */
    private static final long STALL_COOLDOWN_MS = 8000L;
    /** 单轮停喂自愈次数上限，超过则放弃等待用户操作。 */
    private static final int STALL_MAX_ATTEMPTS = 3;

    /**
     * USB 流重建窗口（reconfigStream 内 activeStream 被临时置空的区间）。
     * 窗口内不得判定「无在途数据」：那会让渲染器被判 not-ready → ExoPlayer 掉
     * BUFFERING + stopRenderers()，而恢复又依赖渲染器 → 同类死锁。见 hasPendingDataExclusive。
     */
    private static volatile boolean reconfigInProgress = false;

    private static volatile long lastDataEnqueueMs = 0L;
    private static volatile long lastRecoveryMs = 0L;
    private static volatile int recoveryAttempts = 0;

    static long nowMs() {
        return android.os.SystemClock.elapsedRealtime();
    }

    /** handleBuffer 成功入队时调用：刷新最后数据时间并重置自愈计数。 */
    static void onDataEnqueued() {
        lastDataEnqueueMs = nowMs();
        recoveryAttempts = 0;
    }

    /** 写线程空转探测回调（每 100ms 一次）。仅播放中才判定停喂。 */
    static void onStallProbe(boolean sinkPlaying) {
        if (!sinkPlaying) return;
        if (lastDataEnqueueMs <= 0 || nowMs() - lastDataEnqueueMs < STALL_THRESHOLD_MS) return;
        tryConsumeRecoveryBudget("renderer stalled");
    }

    // ── 起播无数据看门狗（P0-3，勿删） ─────────────────────────────
    // onStallProbe 依赖写线程（首个 handleBuffer 才创建）与 lastDataEnqueueMs（首个入队才
    // 置位），因此「play() 之后从未收到任何数据」的场景（configure 迟到、渲染器不被调度）
    // 完全探测不到，也无任何自愈 —— 实测表现为开独占后点播放 13 秒无声，直到用户手动
    // 暂停→播放才打破（2026-09-11 诊断包 20260911_164255，16:42:01.309–16:42:14.449）。
    // 这里用独立调度线程做兜底探测：超时未收到数据就复用 auto-seek 自愈
    // （seek → onPositionReset → 渲染器重走 format/configure/handleBuffer，等效用户暂停→播放）。
    /** 起播后多久仍无任何 handleBuffer 即触发自愈（ms）。需大于正常起播耗时（<1s）。 */
    private static final long FIRST_DATA_WATCHDOG_MS = 3000L;
    /** 看门狗探测周期（ms）。 */
    private static final long FIRST_DATA_WATCHDOG_PERIOD_MS = 500L;
    private static final ScheduledExecutorService FIRST_DATA_WATCHDOG_EXEC =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "UsbSinkFirstDataWatchdog");
                t.setDaemon(true);
                return t;
            });
    private static volatile ScheduledFuture<?> firstDataWatchdogFuture;

    private static synchronized void ensureFirstDataWatchdog() {
        if (firstDataWatchdogFuture != null) return;
        firstDataWatchdogFuture = FIRST_DATA_WATCHDOG_EXEC.scheduleAtFixedRate(
                () -> {
                    for (UsbInterceptAudioSink s : liveSinks) s.probeNoDataStall();
                },
                FIRST_DATA_WATCHDOG_PERIOD_MS, FIRST_DATA_WATCHDOG_PERIOD_MS, TimeUnit.MILLISECONDS);
    }

    // ── 异步 USB 流重建（P0-4 修复，2026-09-12） ─────────────────────────────
    // 背景：configure() 在 ExoPlayer 播放线程上被调用，且与 codec 格式变更
    // （MediaCodec flush/reinit）处在同一调用栈。此前在 configure() 内同步执行整条
    // native 重建（停写线程 → release 旧流 → openDevice → setAlt/SET_CUR → start），
    // 阻塞播放线程 100~400ms；实测该窗口与「解码器不再提供输入缓冲
    // （dequeueInputBufferIndex=-1）、也不再吐输出」的停喂强相关。
    // 现在：configure() 只登记目标格式并立即返回，重建由独立线程串行执行；
    // 重建窗口内 handleBuffer 返回 false（不消费、不丢弃），ExoPlayer 稍后重试同一 buffer。
    private static final ExecutorService RECONFIG_EXEC =
            Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, "UsbSinkReconfig");
                t.setDaemon(true);
                return t;
            });
    /** 待重建请求（latest-wins）。null = 无待处理请求；复合状态一律在 reconfigLock 内读写。 */
    private static UsbInterceptAudioSink pendingReconfigSink;
    private static int pendingReconfigRate;
    private static int pendingReconfigChannels;
    private static int pendingReconfigEncoding;
    /** 重建窗口标记：从「登记请求」持续到「worker 处理完队列为空」，供 handleBuffer 门控。 */
    private static volatile boolean rebuildPending;
    private static boolean reconfigWorkerScheduled;
    /**
     * 登记簿专用锁：**不得**与 UsbAudioSinkController.class 锁混用。
     * worker 在原生重建期间持有 class 锁 100~400ms，而本方法由播放线程调用
     * （configure 内），共用 class 锁会把这段阻塞搬回播放线程，修复即失效。
     */
    private static final Object reconfigLock = new Object();

    /** 登记一次异步重建（在 configure() 内调用，不阻塞播放线程）。 */
    private static void requestReconfig(UsbInterceptAudioSink sink, int rate, int channels,
            int encoding) {
        boolean needStartWorker;
        synchronized (reconfigLock) {
            pendingReconfigSink = sink;
            pendingReconfigRate = rate;
            pendingReconfigChannels = channels;
            pendingReconfigEncoding = encoding;
            rebuildPending = true;
            needStartWorker = !reconfigWorkerScheduled;
            if (needStartWorker) reconfigWorkerScheduled = true;
        }
        if (needStartWorker) {
            RECONFIG_EXEC.execute(UsbAudioSinkController::runReconfigWorker);
        }
    }

    /** 串行执行登记的重建请求（latest-wins）；队列空则退出并把窗口标记归零。 */
    private static void runReconfigWorker() {
        while (true) {
            UsbInterceptAudioSink sink;
            int rate;
            int channels;
            int encoding;
            synchronized (reconfigLock) {
                sink = pendingReconfigSink;
                rate = pendingReconfigRate;
                channels = pendingReconfigChannels;
                encoding = pendingReconfigEncoding;
                if (sink == null) {
                    rebuildPending = false;
                    reconfigWorkerScheduled = false;
                    return;
                }
                pendingReconfigSink = null;
            }
            if (!exclusiveEnabled || !liveSinks.contains(sink)) {
                // 期间已关独占或 sink 已释放：跳过（下轮循环会把窗口标记归零）
                logW(TAG, "async reconfig skipped (enabled=" + exclusiveEnabled
                        + " live=" + liveSinks.contains(sink) + ")");
                continue;
            }
            try {
                // 不持 reconfigLock：内部自带 class 锁与 enable/disable 互斥
                sink.reconfigStream(rate, channels, encoding);
            } catch (Throwable t) {
                logE(TAG, "async reconfig threw: " + t.getMessage(), t);
            }
        }
    }

    /** 是否有 USB 流重建未完成（handleBuffer 的重建窗口门控）。 */
    static boolean isRebuildPending() {
        return rebuildPending || reconfigInProgress;
    }

    /** 共享自愈预算（与 onStallProbe 同用冷却与上限，防双看门狗 seek 风暴）。 */
    private static boolean tryConsumeRecoveryBudget(String reason) {
        StallRecoveryListener l = stallRecoveryListener;
        if (l == null) return false;
        long now = nowMs();
        if (now - lastRecoveryMs < STALL_COOLDOWN_MS) return false;
        if (recoveryAttempts >= STALL_MAX_ATTEMPTS) return false;
        lastRecoveryMs = now;
        recoveryAttempts++;
        logE(TAG, reason + " — auto-seek recovery fired (attempt "
                + recoveryAttempts + "/" + STALL_MAX_ATTEMPTS + ")");
        try {
            l.onRendererStalled();
        } catch (Exception e) {
            logE(TAG, "stall recovery listener threw: " + e.getMessage());
        }
        return true;
    }

    // ── PCM 频谱捕获（MD3Music 频谱功能用） ────────────────────────
    // 无论是否 USB 独占，都在 handleBuffer 截取解码后的原始 PCM 快照。
    // 该数据在 AudioFlinger 混音之前，不受系统媒体音量影响 —— 静音播放时
    // 频谱依然有真实数据（Visualizer 做不到这点）。
    public interface PcmCaptureListener {
        /**
         * @param buffer      当前块 PCM（position 指向读取起点，调用方勿改动原始 buffer）
         * @param encoding    C.ENCODING_PCM_16BIT / PCM_24BIT / PCM_32BIT / PCM_FLOAT
         * @param sampleRate  解码采样率（Hz）
         * @param channelCount 声道数
         */
        void onPcm(java.nio.ByteBuffer buffer, int encoding, int sampleRate, int channelCount);
    }

    private static volatile PcmCaptureListener pcmCaptureListener = null;

    public static void setPcmCaptureListener(PcmCaptureListener listener) {
        pcmCaptureListener = listener;
    }

    /** 所有存活包装器（应用可能创建多个播放器实例）。 */
    private static final List<UsbInterceptAudioSink> liveSinks = new CopyOnWriteArrayList<>();

    /** 采样率/声道变化时由控制器回调应用侧重建 USB 流。 */
    public interface UsbAudioReconfigListener {
        /**
         * @return 已按新格式创建并 start 的流；失败返回 null（控制器将回退普通输出）。
         */
        UsbAudioSink onFormatChanged(int sampleRate, int channelCount, int pcmEncoding);
    }

    private UsbAudioSinkController() {}

    // ── 静态 API（供应用侧插件调用） ──────────────────────────────

    /** 包装 AudioSink。未开启独占时行为与不包装完全一致。 */
    public static AudioSink wrap(AudioSink delegate, Context context) {
        UsbInterceptAudioSink sink = new UsbInterceptAudioSink(delegate, context);
        liveSinks.add(sink);
        android.util.Log.i("NormGainTest", "WrapUsbMarker"); // 唯一标记，验证构建是否保留
        // MD3Music fork: 音量均衡——增益装饰器包在 USB 拦截层之外，先缩放再交给下层。
        return NormalizationGainAudioSink.wrap(sink);
    }

    /** 开启独占。应用侧须先完成：打开设备 → 创建流 → 按 xHCI 时序 setAlt/SET_CUR/start。 */
    public static synchronized boolean enable(UsbAudioSink stream, int dacBitDepth,
                                              int sampleRate, int channelCount) {
        if (stream == null || !stream.isReady()) {
            logE(TAG, "enable: stream not ready");
            return false;
        }
        if (sampleRate <= 0) sampleRate = lastSampleRate;
        if (channelCount <= 0) channelCount = lastChannelCount;
        // 双保险：enable 记录必须与实际建流的率/声道（override+钳制出口）一致
        sampleRate = clampToDacRate(sampleRate);
        channelCount = clampToDacChannels(channelCount);
        activeStream = stream;
        activeDacBitDepth = dacBitDepth;
        usbSampleRate = sampleRate;
        usbChannelCount = channelCount;
        exclusiveEnabled = true;
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(true);
        logI(TAG, "exclusive ENABLED: " + usbSampleRate + "Hz/" + usbChannelCount
                + "ch dac=" + dacBitDepth + "bit");
        return true;
    }

    /**
     * 关闭独占（阶段一）：停写线程、清活动流。
     * 注意：不在此处恢复 delegate 音量/路由 —— 必须先由调用方释放 USB 设备
     * （stop→drain→release→closeDevice，否则 DAC 仍被占用，delegate 路由回去会无声），
     * 再调用 [onUsbReleased] 恢复。顺序见 UsbAudioPlugin.disableExclusive。
     */
    public static synchronized UsbAudioSink disable() {
        UsbAudioSink old = activeStream;
        exclusiveEnabled = false;
        for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
        activeStream = null;
        activeDacBitDepth = 0;
        logI(TAG, "exclusive DISABLED (delegate restore deferred to onUsbReleased)");
        return old;
    }

    /** 关闭独占（阶段二）：USB 设备完全释放后调用，恢复 delegate 音量/路由。 */
    public static synchronized void onUsbReleased() {
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(false);
    }

    public static boolean isEnabled() { return exclusiveEnabled; }

    public static void setReconfigListener(UsbAudioReconfigListener listener) {
        reconfigListener = listener;
    }

    /**
     * 按当前有效格式（override 优先）立即重建活动流。供应用侧在"输出格式选择"
     * 变更后调用（须在后台线程；内部与 reconfigStream 相同的互斥与释放顺序）。
     */
    public static void reconfigureActiveStream() {
        UsbAudioReconfigListener listener = reconfigListener;
        if (!exclusiveEnabled || listener == null) return;
        synchronized (UsbAudioSinkController.class) {
            for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
            UsbAudioSink old = activeStream;
            activeStream = null;
            if (old != null) {
                try { old.stop(); old.drainUrbs(); old.release(); } catch (Exception e) {
                    logE(TAG, "reconfigureActiveStream: old release failed: " + e.getMessage());
                }
            }
            int rate = effectiveRate(lastSampleRate);
            int ch = effectiveChannels(lastChannelCount);
            UsbAudioSink fresh = null;
            try {
                fresh = listener.onFormatChanged(rate, ch, lastEncoding);
            } catch (Exception e) {
                logE(TAG, "reconfigureActiveStream: listener threw: " + e.getMessage(), e);
            }
            if (fresh != null && fresh.isReady()) {
                activeStream = fresh;
                usbSampleRate = rate;
                usbChannelCount = ch;
                logI(TAG, "reconfigureActiveStream OK → " + rate + "Hz/" + ch + "ch");
            } else {
                logE(TAG, "reconfigureActiveStream FAILED — falling back to normal output");
                if (fresh != null) { try { fresh.release(); } catch (Exception ignored) {} }
                disable();
                onUsbReleased();
            }
        }
    }

    public static int getLastSampleRate() { return lastSampleRate; }
    public static int getLastChannelCount() { return lastChannelCount; }
    public static int getLastEncoding() { return lastEncoding; }

    /** 歌曲信息页用：当前解码输出格式。 */
    public static Map<String, Object> getFormatInfo() {
        Map<String, Object> m = new HashMap<>();
        m.put("sampleRate", lastSampleRate);
        m.put("channelCount", lastChannelCount);
        m.put("encoding", lastEncoding);
        m.put("hasData", lastSampleRate > 0);
        return m;
    }

    /** 实时状态（设置页/歌曲信息页轮询）。 */
    public static Map<String, Object> getStatus() {
        Map<String, Object> m = new HashMap<>();
        m.put("enabled", exclusiveEnabled);
        m.put("streamReady", activeStream != null && activeStream.isReady());
        m.put("streamAlive", activeStream != null && activeStream.isAlive());
        m.put("framesWritten", activeStream != null ? activeStream.getFramesWritten() : 0L);
        m.put("sampleRate", usbSampleRate);
        m.put("channelCount", usbChannelCount);
        m.put("dacBitDepth", activeDacBitDepth);
        // 最近一次解码输出格式（未开启独占时也能展示歌曲信息）
        m.put("lastSampleRate", lastSampleRate);
        m.put("lastChannelCount", lastChannelCount);
        m.put("lastEncoding", lastEncoding);
        return m;
    }

    public static String encName(int encoding) {
        if (encoding == C.ENCODING_PCM_FLOAT) return "FLOAT";
        if (encoding == C.ENCODING_PCM_16BIT) return "16BIT";
        if (encoding == C.ENCODING_PCM_24BIT) return "24BIT";
        if (encoding == C.ENCODING_PCM_32BIT) return "32BIT";
        return "UNKNOWN(" + encoding + ")";
    }

    // ── 拦截型 AudioSink ─────────────────────────────────────────

    static final class UsbInterceptAudioSink extends ForwardingAudioSink {

        private final Context context;
        private UsbStreamingThread streamingThread = null;
        private final UsbPcmResampler usbResampler = new UsbPcmResampler();
        private boolean delegateMuted = false;
        private float pendingVolume = 1f;
        private int currentEncoding = C.ENCODING_PCM_16BIT;
        private int currentSampleRate = 0;
        private int currentChannelCount = 0;
        private boolean isPlaying = false;
        private long handleBufferCallCount = 0;
        private long posLogCount = 0;
        private long lastPosLogMs = 0L;
        private long lastBackpressureLogMs = 0L;
        private long lastDiscardLogMs = 0L;
        /** CONVERT 路径心跳：已记录的转换参数键与累计次数（参数变化或每 500 块打一条）。 */
        private String lastConvertKey = "";
        private long convertCallCount = 0;
        /** [UsbDiag] 无数据看门狗判据快照限频。 */
        private long lastNoDataProbeLogMs = 0L;
        /** 本 sink 是否已实际写入过数据（同率切歌时 ring 可能残留上一首 URB，用于判定是否 drain）。 */
        private boolean hasPlayedData = false;
        /**
         * 上次 handleBuffer 是否走了「独占拦截」分支。用于在「独占 → 非独占」的交接点
         * 清一次 delegate 的粘滞输入状态（详见 handleBuffer 转发分支的注释）。
         */
        private boolean interceptedSinceLastForward = false;
        /** EOS 等待期 playToEndOfStream 的调用计数（探针限频用；EOS 等待期会以 ~200Hz 驱动）。 */
        private long eosProbeCount = 0;
        private long usbStartMediaTimeUs = 0L;
        private boolean usbStartMediaTimeNeedsInit = true;
        private boolean handledEndOfStream = false;
        /** hasPendingData() 上次返回值（诊断：仅在翻转时留痕，定位 load/BUFFERING 死锁）。 */
        private boolean lastHasPendingData = false;

        // ── 提交量活性窗口（P0-1 精细判据，勿删） ─────────────────────
        // 上一版 `!handledEndOfStream → true` 粒度太粗：它让 hasPendingData() 恒 true →
        // MediaCodecAudioRenderer.isReady() 恒 true（`hasPendingData() || super.isReady()`），
        // 把「inputFormat 是否就绪」彻底旁路，代价是 ExoPlayer 认为渲染器随时就绪 →
        // 掉 BUFFERING 自愈路径与 getDurationToProgressUs 重试调度双双失效（实测 192k
        // 跨率重建后 submitted 冻结 10.9s 无任何错误）。
        // 现在改为有依据地报 true：只有在「最近 STALL 窗口内提交量确实在增长」或
        // 「刚起播还没机会增长」时才报 true；一旦提交量长期停滞，就如实报 false，
        // 把判断权交回 ExoPlayer（它会掉 BUFFERING 并重新调度 → 自愈）。
        /** 提交量停滞多久后不再声称「有在途数据」（ms）。需 > 正常喂入间隔（单块 ~85ms）。 */
        private static final long SUBMIT_LIVENESS_WINDOW_MS = 1500L;
        /** 最近一次观察到 framesWritten 增长的时刻与数值。 */
        private long lastSubmitGrowMs = 0L;
        private long lastSubmitFrames = -1L;
        /** 本流是否曾有过提交量增长（区分「尚未起播」与「起播后停滞」）。 */
        private boolean submitEverGrew = false;
        /** 本次 play() 的起播时刻（P0-3 无数据看门狗用；flush 时播放中同样重置为新窗口）。 */
        private long playStartedMs = 0L;

        // ── 墙钟位置时钟（对齐系统 AudioTrack 的硬件播放头语义） ──
        // framesWritten 是「已 submit 给 USB」的帧数，数据提交后仍停在 native ring
        // （16 URB×8pkt≈1.36s）里等 DAC 播放，直接用它算位置会超前硬件最多一个 ring。
        // 改为：播放中按墙钟 + DAC 速率估位置，并用 framesWritten 做上限钳制
        // （不允许超过已提交量，欠载/停喂时停在最后 submit 帧）。
        /** 本次播放段起点的墙钟（elapsedRealtime）。 */
        private long playStartWallMs = 0L;
        /** 本次播放段起点时已 submit 的帧数。 */
        private long startFramesAtPlay = 0L;
        /** 暂停时冻结的「已播放帧数」（相对本次流起点）。 */
        private long frozenPlayedFrames = 0L;
        /** hasPendingData 在途判定下限：约 100ms 帧数（小于 ring 1.36s、大于单块 85ms 抖动）。 */
        private static final long PENDING_MIN_MEDIA_US = 100_000L;

        UsbInterceptAudioSink(AudioSink delegate, Context ctx) {
            super(delegate);
            this.context = ctx.getApplicationContext();
        }

        /**
         * USB 独占下声明「可直接吃 32bit 表示」，让上游把解码精度推到位深上限。
         *
         * <p>独占直写层自带「任意线性 PCM → 端点位深」的转换（native
         * convertFloatToInt16/24/32），所以独占期间 FLOAT / PCM_32BIT 都视为
         * {@link AudioSink#SINK_FORMAT_SUPPORTED_DIRECTLY}。这一步是「独占默认 32bit」
         * 的<strong>唯一生效点</strong>：{@code MediaCodecAudioRenderer.getMediaFormatForPlayback}
         * 正是用本方法对 FLOAT 的返回值决定是否给解码器下发
         * {@code KEY_PCM_ENCODING=ENCODING_PCM_FLOAT}（见其 1037-1043 行）。
         *
         * <p>为什么不能再依赖「32bit 播放支持」开关：{@code DefaultAudioSink.floatOutputRequested()}
         * 在独占开启时硬编码返回 false，开关能否生效只取决于「解码器创建时刻独占是否已开」，
         * 实测同一首歌会因顺序不同而得到 FLOAT / 24BIT 两种结果。此处按「独占状态本身」
         * 决定，语义与顺序无关，开关不再参与独占路径。
         *
         * <p>降位由 native 完成：32bit DAC 走 convertFloatToInt32、24bit 走 convertFloatToInt24、
         * 16bit 走 convertFloatToInt16 —— 即「DAC 不支持则自动降位」。float32 尾数 24bit，
         * 对 16/24bit 源为数学无损。
         *
         * <p>门控 {@code activeStream.isAlive()} 是必要的：流未就绪时数据会走 delegate
         * 兜底（AudioTrack），而 delegate 的 float 输出在部分设备上有变速/变调历史问题，
         * 不允许在那种窗口期宣称支持 float。
         */
        @Override
        public @AudioSink.SinkFormatSupport int getFormatSupport(Format format) {
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()
                    && MimeTypes.AUDIO_RAW.equals(format.sampleMimeType)
                    && (format.pcmEncoding == C.ENCODING_PCM_FLOAT
                            || format.pcmEncoding == C.ENCODING_PCM_32BIT)) {
                return AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY;
            }
            return super.getFormatSupport(format);
        }

        @Override
        public void configure(Format inputFormat, int specifiedBufferSize, int[] outputChannels)
                throws ConfigurationException {
            // 应用静态偏好路由（关闭独占后新建/重配的 sink 也要显式走 USB DAC）
            applyPreferredDeviceIfNeeded(this);
            int enc = inputFormat.pcmEncoding;
            if (enc != Format.NO_VALUE) currentEncoding = enc;
            int sr = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 0;
            int ch = inputFormat.channelCount > 0 ? inputFormat.channelCount : 0;
            if (sr > 0 && ch > 0) {
                lastSampleRate = sr;
                lastChannelCount = ch;
            }
            lastEncoding = currentEncoding;
            currentSampleRate = sr;
            currentChannelCount = ch;
            // [UsbDiag] mime 是本路径的关键判据：audio/raw = extractor 层已解出 PCM（FLAC 扩展
            // /WAV 走 bypass，无解码器，enc=源位深）；audio/flac|mpeg 等 = 走 MediaCodec 解码器。
            logI(TAG, "configure: enc=" + encName(currentEncoding) + " rate=" + sr + " ch=" + ch
                    + " mime=" + inputFormat.sampleMimeType);

            if (exclusiveEnabled && activeStream != null) {
                // 格式纪元边界复位：每次 configure 都从干净状态开始。
                // 1) super.flush() 清掉 delegate 的粘滞 pendingConfiguration —— 独占期间
                //    super.handleBuffer 永不执行，DefaultAudioSink.configure 的延迟配置
                //    只有 handleBuffer/flush 才会解析；"播放中 configure"会让 delegate
                //    长期处于 pending 状态（"暂停中 configure"因先有 pause/flush 幸免）。
                // 2) 清空旧格式队列 + 复位重采样器与 usbStartMediaTimeUs 基线，
                //    消除 FLOAT→16BIT 等格式切换后位置/数据错位。
                // 这统一了"播放中 configure"与"暂停中 configure"的行为（停喂根因）。
                flush();
                // 切歌/采样率切换/死流自愈：重建 USB 流（先停旧流，再让应用侧按新格式重建）。
                // 不要求 isAlive()：流死亡（如 SUBMITURB 失败）后若跳过重建，
                // 写线程会静默丢弃数据导致持续无声。
                // 采样率先按 DAC 能力钳制（如 192k → 96k），声道同样钳制到端点声道数
                // （如 1ch → 2ch），避免重建出与端点不符的流或 Controller 记录错位。
                sr = clampToDacRate(sr);
                ch = clampToDacChannels(ch);
                boolean needReconfig = sr > 0 && ch > 0
                        && (sr != usbSampleRate || ch != usbChannelCount || !activeStream.isAlive());
                if (needReconfig) {
                    // 异步重建：不阻塞播放线程（P0-4：详见 requestReconfig 注释）。
                    // 重建完成前 handleBuffer 返回 false（未消费），格式转换在
                    // usbSampleRate 更新后的下一次 handleBuffer 才会按新格式进行。
                    requestReconfig(this, sr, ch, currentEncoding);
                    // 重建后的新流 ring 为空，重新起算
                    hasPlayedData = false;
                } else if (hasPlayedData) {
                    // 同率/同声道切歌不重建流，native ring 里可能还压着上一首的在途 URB
                    // （flush 只清 Java 队列与帧计数，不 drain ring）→ 新歌 framesWritten
                    // 从 0 计但 DAC 实际还播旧数据，位置语义失真、开头串音。
                    // stop/drain/start 清 ring（不重新 setAlt/SET_CUR，毫秒级）。
                    UsbAudioSink s = activeStream;
                    if (s != null && s.isAlive()) {
                        try {
                            s.stop();
                            s.drainUrbs();
                            s.start();
                            logI(TAG, "ring drained on same-rate reconfigure");
                        } catch (Exception e) {
                            logE(TAG, "ring drain failed: " + e.getMessage());
                        }
                    }
                    hasPlayedData = false;
                }
                // delegate 静音轨也必须用钳制后的格式：原始 192k 会让系统 AudioTrack
                // 初始化失败（多数输出设备不支持 192k）→ ExoPlayer error → renderer 停喂。
                Format delegateFormat =
                        (sr != inputFormat.sampleRate || ch != inputFormat.channelCount)
                                ? inputFormat.buildUpon().setSampleRate(sr).setChannelCount(ch).build()
                                : inputFormat;
                super.configure(delegateFormat, specifiedBufferSize, outputChannels);
                muteDelegateIfNeeded();
                return;
            }

            super.configure(inputFormat, specifiedBufferSize, outputChannels);
        }

        private void reconfigStream(int sampleRate, int channelCount, int encoding) {
            logI(TAG, "reconfigStream: " + sampleRate + "Hz/" + channelCount + "ch (was "
                    + usbSampleRate + "/" + usbChannelCount + ")");
            UsbAudioReconfigListener listener = reconfigListener;
            if (listener == null) {
                logW(TAG, "reconfigStream: no listener — keeping old stream");
                return;
            }
            // 与 enable/disable 互斥，避免并发切换时 double-release
            synchronized (UsbAudioSinkController.class) {
            // 重建窗口标记：窗口内 hasPendingData() 不得报「已抽干」（见 hasPendingDataExclusive）
            reconfigInProgress = true;
            try {
            // 1) 停掉所有写线程（线程持有旧流引用）
            for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
            // 2) 停旧流并释放原生上下文（drain 必须在 setAlt(0) 前完成）。
            //    先置空 activeStream，防止重建窗口内 handleBuffer 触碰已释放的上下文
            UsbAudioSink old = activeStream;
            activeStream = null;
            if (old != null) {
                try { old.stop(); old.drainUrbs(); old.release(); } catch (Exception e) {
                    logE(TAG, "old stream release failed: " + e.getMessage());
                }
            }
            // 3) 应用侧重建（打开设备→创建流→setAlt(0)→SET_CUR→setAlt(N)→start）
            UsbAudioSink fresh = null;
            try {
                fresh = listener.onFormatChanged(sampleRate, channelCount, encoding);
            } catch (Exception e) {
                logE(TAG, "reconfig listener threw: " + e.getMessage(), e);
            }
            if (fresh != null && fresh.isReady()) {
                activeStream = fresh;
                usbSampleRate = sampleRate;
                usbChannelCount = channelCount;
                logI(TAG, "reconfigStream OK → " + sampleRate + "Hz/" + channelCount + "ch");
            } else {
                // 重建失败：回退普通输出。disable() 已停线程/清流；恢复 delegate 音量。
                // 设备连接保留（插件侧 currentAdapter 已清空，下次 enable 复用）。
                logE(TAG, "reconfigStream FAILED — falling back to normal output");
                if (fresh != null) { try { fresh.release(); } catch (Exception ignored) {} }
                disable();
                onUsbReleased();
            }
            } finally {
                reconfigInProgress = false;
            }
            }
        }

        @Override
        public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
                throws InitializationException, WriteException {
            // ── 频谱 PCM 捕获：无论是否 USB 独占都截取（解码后、混音前，静音也有数据） ──
            PcmCaptureListener pcmListener = pcmCaptureListener;
            if (pcmListener != null && currentSampleRate > 0 && buffer != null && buffer.remaining() > 0) {
                try {
                    pcmListener.onPcm(
                            buffer.duplicate().order(buffer.order()),
                            currentEncoding, currentSampleRate, currentChannelCount);
                } catch (Exception e) {
                    logW(TAG, "pcm capture listener threw: " + e.getMessage());
                }
            }
            if (exclusiveEnabled) {
                interceptedSinceLastForward = true;
                if (isRebuildPending()) {
                    // 重建窗口（含「已登记未开工」）：既不能按旧格式继续喂（会变调/装包错），
                    // 也不能像死流那样吞掉（会丢音频）。返回 false = 未消费，
                    // ExoPlayer 稍后重试同一条 buffer；等待由 getDurationToProgressUs 节流。
                    return false;
                }
                // 注：必须在门控之后再取 activeStream —— 重建由独立线程执行，
                // 门控前取的引用可能已被 worker 释放（use-after-free）。
                UsbAudioSink stream = activeStream;
                if (stream == null || !stream.isAlive()) {
                    // 独占开启但流不可用（重建窗口/死流）：吞掉数据保持静音。
                    // 不能送 delegate —— 会从手机扬声器漏音，且 delegate 可能按源
                    // 格式（如 192k）初始化失败抛 InitializationException 导致停播。
                    // reconfigStream 失败路径已自行 disable() 回普通输出，不受影响。
                    // P0-4 观测：此分支此前完全静默——区分「handleBuffer 被调用但
                    // 吞掉」与「handleBuffer 根本未被调度」的关键证据点（限频 1s）。
                    if (nowMs() - lastDiscardLogMs >= 1000L) {
                        lastDiscardLogMs = nowMs();
                        logW(TAG, "handleBuffer DISCARDED (stream " + (stream == null ? "null" : "dead")
                                + ") pts=" + presentationTimeUs + " hbCount=" + handleBufferCallCount
                                + " reconfigInProgress=" + reconfigInProgress);
                    }
                    buffer.position(buffer.limit());
                    return true;
                }
                muteDelegateIfNeeded();
                if (streamingThread == null) {
                    streamingThread = new UsbStreamingThread(stream);
                    // 暂停状态接管 → 线程创建即暂停（不消费队列 → 不写 DAC）
                    if (!isPlaying) streamingThread.pauseStreaming();
                    streamingThread.start();
                    logI(TAG, "USB streaming thread created (isPlaying=" + isPlaying + ")");
                }
                // 捕获媒体时间线偏移，用于 framesWritten → 播放进度换算
                if (usbStartMediaTimeNeedsInit) {
                    usbStartMediaTimeUs = Math.max(0L, presentationTimeUs);
                    usbStartMediaTimeNeedsInit = false;
                    // 对齐墙钟播放基线：以当前已 submit 帧为起点。新流/flush 后
                    // framesWritten 已归零；起播时墙钟从现在起算。
                    alignPlaybackBaseline(stream.getFramesWritten());
                    logI(TAG, "usbStartMediaTimeUs=" + usbStartMediaTimeUs);
                }
                handleBufferCallCount++;
                lastHandleBufferCount = (int) handleBufferCallCount;
                // 诊断：前 5 次 + 每 10 次打印。P0-4 观测：旧 %500 在总喂 <500 块的
                // 停喂会话里完全不可见，%10 才能看出停喂窗口内 handleBuffer 是否仍被调度
                if (handleBufferCallCount <= 5 || handleBufferCallCount % 10 == 0) {
                    logI(TAG, "handleBuffer #" + handleBufferCallCount + " pts=" + presentationTimeUs
                            + " isPlaying=" + isPlaying + " queue=" + streamingThread.queueSize()
                            + " enc=" + encName(currentEncoding));
                }
                // 阻塞式背压（对齐系统 AudioTrack.write 语义）：队列达水线时在渲染线程
                // 有界阻塞等空位，而不是返回 false 让 ExoPlayer 按「(pts−clock位置)/2」
                // 调度睡眠。我们的 clock 位置依赖持续喂入（framesWritten），睡眠会与
                // 位置冻结形成死锁（实测 192k 首曲 hbCount 永久冻结、无声）。
                // awaitSpace 内部带超时 + pause/stop/flush 退出，边界不会挂死。
                // [P1 修复 v2 2026-09-13]：超时 1s→120ms→15ms —— 暂停消息排在渲染线程
                // 队列里，阻塞中的 doSomeWork 必须返回后才能处理 pause；实测 120ms 时暂停
                // 消息仍被 render 循环（每 ~213ms 一次 handleBuffer+awaitSpace）饿 4.1s。
                // 15ms 让渲染循环快速自旋重试，暂停消息 ≤ ~40ms 内被处理。
                if (streamingThread.queueSize() >= QUEUE_BACKPRESSURE_THRESHOLD) {
                    if (!streamingThread.awaitSpace(15L)) {
                        // 被打断/超时：回退旧契约（同一 buffer 稍后重试），行为不劣化
                        if (nowMs() - lastBackpressureLogMs >= 2000L) {
                            lastBackpressureLogMs = nowMs();
                            logI(TAG, "backpressure: return false pts=" + presentationTimeUs
                                    + " queue=" + streamingThread.queueSize()
                                    + " hbCount=" + handleBufferCallCount);
                        }
                        return false;
                    }
                }
                ByteBuffer snapshot = buffer.slice().order(buffer.order());
                // 统一转换出口：源格式 ≠ 流配置(usbSampleRate/usbChannelCount) 时触发转换
                // （float → 声道 → 重采样），一致时走 RAW 直写保持 bit-perfect。
                // 目标就是流配置本身（流由 createStartedStream 按 override+钳制统一出口建立）。
                boolean needCh = usbChannelCount > 0 && currentChannelCount > 0
                        && currentChannelCount != usbChannelCount;
                boolean needResample = usbSampleRate > 0 && currentSampleRate > 0
                        && currentSampleRate != usbSampleRate;
                if (needCh || needResample) {
                    // 输出格式转换路径：统一转 float → 声道转换 → 线性插值重采样。
                    float[] f = toFloatInterleaved(snapshot, currentEncoding);
                    if (f == null && !convertUnsupportedWarned) {
                        // 罕见编码（8BIT/INVALID）无法转 float：数据将被丢弃，至少可见
                        convertUnsupportedWarned = true;
                        logW(TAG, "CONVERT skipped: unsupported encoding "
                                + encName(currentEncoding));
                    }
                    if (f != null && f.length > 0) {
                        final int inFrames = currentChannelCount > 0
                                ? f.length / currentChannelCount : f.length;
                        if (needCh) f = UsbPcmResampler.convertChannels(f, currentChannelCount, usbChannelCount);
                        if (needResample) {
                            // 必须先设置重采样格式（srcRate/声道/目标率），否则 process 恒直通
                            usbResampler.setFormat(currentSampleRate, usbChannelCount, usbSampleRate);
                            f = usbResampler.process(f);
                        }
                        // 诊断：重采样/声道转换的可见性。参数变化打一条（含 in/out 帧数，
                        // 可据此确认 192k→96k 这类降采样真的执行），此后每 500 块一条心跳。
                        // 旧实现只用全局 handleBufferCallCount<=3 打点，会话首个流之后完全不可见。
                        convertCallCount++;
                        String ckey = currentSampleRate + "/" + currentChannelCount + "→"
                                + usbSampleRate + "/" + usbChannelCount;
                        if (!ckey.equals(lastConvertKey) || convertCallCount % 500 == 0) {
                            lastConvertKey = ckey;
                            logI(TAG, "CONVERT " + ckey
                                    + (needResample ? " resample" : "")
                                    + (needCh ? " chmap" : "")
                                    + " in=" + inFrames + "frames out="
                                    + (usbChannelCount > 0 ? f.length / usbChannelCount : f.length)
                                    + "frames #" + convertCallCount);
                        }
                        if (f.length > 0) {
                            streamingThread.enqueue(f);
                            hasPlayedData = true;
                        }
                    }
                    buffer.position(buffer.limit());
                    return true;
                }
                if (currentEncoding == C.ENCODING_PCM_FLOAT) {
                    int totalSamples = snapshot.remaining() / 4;
                    if (totalSamples > 0) {
                        float[] floatBuf = new float[totalSamples];
                        snapshot.asFloatBuffer().get(floatBuf);
                        if (handleBufferCallCount <= 3) {
                            logI(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": FLOAT samples=" + totalSamples);
                        }
                        streamingThread.enqueue(floatBuf);
                        hasPlayedData = true;
                    }
                } else {
                    int remaining = snapshot.remaining();
                    if (remaining > 0) {
                        byte[] rawBytes = new byte[remaining];
                        snapshot.get(rawBytes);
                        if (handleBufferCallCount <= 3) {
                            logI(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": RAW " + encName(currentEncoding) + " bytes=" + remaining);
                        }
                        streamingThread.enqueueRaw(rawBytes, currentEncoding);
                        hasPlayedData = true;
                    }
                }
                buffer.position(buffer.limit());
                return true;
            }
            // ── 独占 → 非独占的交接：清一次 delegate 的粘滞输入状态 ──
            // 独占期间 delegate 收不到 handleBuffer（数据被本层拦走），它的 inputBuffer
            // 可能仍指向上一次未消费完的缓冲；而「关独占」是分两步的（disable() 先置
            // exclusiveEnabled=false，真正恢复 delegate 的 onExclusiveChanged(false) 要等
            // USB 设备释放完才执行），所以这个窗口内 renderer 会先把数据转发给 delegate。
            // 若此时 AudioTrack 已被释放，DefaultAudioSink.flush() 原本不会清 inputBuffer
            // （清理被 isAudioTrackInitialized() 守卫挡住）→ 新缓冲撞
            // checkArgument(inputBuffer == null || buffer == inputBuffer)
            // → IllegalArgumentException → ExoPlaybackException errorCode=1004（实测 2026-09-12）。
            // 与其依赖外部在"正确时刻"恰好 flush，不如在转入转发的那一次调用里、同线程清一次：
            // 依赖 DefaultAudioSink.flush() 的无条件清理补丁（fork）。
            if (interceptedSinceLastForward) {
                interceptedSinceLastForward = false;
                logI(TAG, "exclusive→delegate handover: clearing stale delegate input state");
                // 只清 delegate（super = ForwardingAudioSink → DefaultAudioSink）：
                // 本层的 streamingThread 已被 stopStreamingThread() 置空、重采样器会在
                // 下次 configure/flush 时重设，无需在此重复处理。
                super.flush();
            }
            unmuteDelegateIfNeeded();
            return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
        }

        /**
         * 对齐墙钟播放基线（起播/首个 buffer/flush 后）。
         * @param submittedFrames 当前活动流已 submit 帧数
         */
        private void alignPlaybackBaseline(long submittedFrames) {
            playStartWallMs = nowMs();
            startFramesAtPlay = submittedFrames;
            frozenPlayedFrames = 0L;
        }

        /**
         * 估计「已播放帧数」（相对当前流 framesWritten 零点）：
         * 播放中按墙钟+DAC 速率推进，暂停时冻结；并用 submitted 上限钳制，
         * 保证不超前已提交数据（欠载时停在最后 submit 帧）。
         */
        private long estimatedPlayedFrames(long submittedFrames) {
            if (usbSampleRate <= 0) return submittedFrames;
            long played;
            if (isPlaying) {
                long elapsedMs = nowMs() - playStartWallMs;
                if (elapsedMs < 0) elapsedMs = 0;
                played = frozenPlayedFrames + elapsedMs * (long) usbSampleRate / 1000L;
            } else {
                played = frozenPlayedFrames;
            }
            // 新流/flush 后 framesWritten 归零，基线可能大于当前 submitted：重对齐防负值
            if (startFramesAtPlay > submittedFrames) {
                startFramesAtPlay = submittedFrames;
                playStartWallMs = nowMs();
                frozenPlayedFrames = 0L;
                played = isPlaying ? 0L : frozenPlayedFrames;
            }
            long rel = startFramesAtPlay + played;
            // 不允许超过已提交量（submit≠播放，位置不得跑到 ring 前端之前）
            if (rel > submittedFrames) rel = submittedFrames;
            return rel;
        }

        @Override
        public long getCurrentPositionUs(boolean sourceEnded) {
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                if (usbStartMediaTimeNeedsInit) {
                    // 节流留痕：needsInit 期间渲染器拿到 NOT_SET（保留其内部旧位置钳位）
                    if (nowMs() - lastPosLogMs >= 1000L) {
                        lastPosLogMs = nowMs();
                        logI(TAG, "getCurrentPositionUs: NOT_SET (needsInit, ended=" + sourceEnded + ")");
                    }
                    return AudioSink.CURRENT_POSITION_NOT_SET;
                }
                // 分母用有效输出采样率（usbSampleRate）：自适应时等于源率；
                // 强制采样率时 framesWritten 为重采样后的输出率帧数，用源率会漂移。
                if (usbSampleRate > 0) {
                    long submittedFrames = activeStream.getFramesWritten();
                    long playFrames = estimatedPlayedFrames(submittedFrames);
                    long posUs = usbStartMediaTimeUs + playFrames * C.MICROS_PER_SECOND / usbSampleRate;
                    // 节流快照（≥1s）：定位 position 停滞（停喂根因观测点）
                    if (nowMs() - lastPosLogMs >= 1000L) {
                        lastPosLogMs = nowMs();
                        logI(TAG, "posUs=" + posUs + " played=" + playFrames + " submitted=" + submittedFrames
                                + " usbRate=" + usbSampleRate + " base=" + usbStartMediaTimeUs
                                + " ended=" + sourceEnded);
                    }
                    return posUs;
                }
                return AudioSink.CURRENT_POSITION_NOT_SET;
            }
            return super.getCurrentPositionUs(sourceEnded);
        }

        /** 整数/浮点 PCM 统一转 interleaved float（声道转换/重采样前的中间表示）。 */
        private static float[] toFloatInterleaved(ByteBuffer b, int encoding) {
            final int rem = b.remaining();
            switch (encoding) {
                case C.ENCODING_PCM_FLOAT: {
                    final int n = rem / 4;
                    final float[] out = new float[n];
                    b.asFloatBuffer().get(out);
                    return out;
                }
                case C.ENCODING_PCM_16BIT: {
                    final ShortBuffer sb = b.asShortBuffer();
                    final int n = sb.remaining();
                    final float[] out = new float[n];
                    for (int i = 0; i < n; i++) out[i] = sb.get(i) / 32768f;
                    return out;
                }
                case C.ENCODING_PCM_24BIT: {
                    // 3 字节小端有符号，统一走字节展开（asShortBuffer 不适用 3 字节对齐）
                    final int n = rem / 3;
                    final float[] out = new float[n];
                    final int start = b.position();
                    for (int i = 0; i < n; i++) {
                        final int o = start + i * 3;
                        int v = (b.get(o) & 0xFF) | ((b.get(o + 1) & 0xFF) << 8)
                                | ((b.get(o + 2) & 0xFF) << 16);
                        if (b.get(o + 2) < 0) v |= 0xFF000000;
                        out[i] = v / 8388608f;
                    }
                    return out;
                }
                case C.ENCODING_PCM_32BIT: {
                    final IntBuffer ib = b.asIntBuffer();
                    final int n = ib.remaining();
                    final float[] out = new float[n];
                    for (int i = 0; i < n; i++) {
                        out[i] = (float) ((double) ib.get(i) / 2147483648.0);
                    }
                    return out;
                }
                default:
                    return null;
            }
        }

        @Override public void play() {
            super.play();
            if (!isPlaying) {
                // 从暂停恢复：墙钟基线平移到「冻结帧 + 当前已 submit 量」，位置从冻结点继续
                UsbAudioSink s = activeStream;
                long submitted = (s != null) ? s.getFramesWritten() : 0L;
                long frozen = (s != null && usbSampleRate > 0) ? estimatedPlayedFrames(submitted) : 0L;
                frozenPlayedFrames = frozen;
                startFramesAtPlay = 0L;
                playStartWallMs = nowMs();
            }
            isPlaying = true;
            if (exclusiveEnabled) {
                // P0-3 无数据看门狗基准 = **数据纪元起点**，只由 flush()（切歌/seek）与
                // 开启独占时设置；**play() 不再刷新**（2026-09-12 修）：
                // v2 活性窗口的停滞振荡会以 ~1.5s 周期反复 pause→play，若这里刷新基准，
                // playingForMs 永远攒不到 FIRST_DATA_WATCHDOG_MS → 看门狗永远不触发
                // （实测 19:30 窗口 3.1s 无喂数、看门狗静默）。
                // 只重启提交量活性窗口（那是防「恢复瞬间误报停滞」用的，必须刷新）。
                lastSubmitGrowMs = nowMs();
                ensureFirstDataWatchdog();
            }
            if (streamingThread != null) streamingThread.resumeStreaming();
            logI(TAG, "sink.play() → isPlaying=true (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void pause() {
            if (isPlaying) {
                // 进入暂停：把当前估计已播帧冻结，墙钟停走
                UsbAudioSink s = activeStream;
                long submitted = (s != null) ? s.getFramesWritten() : 0L;
                frozenPlayedFrames = (s != null && usbSampleRate > 0) ? estimatedPlayedFrames(submitted) : 0L;
            }
            isPlaying = false;
            if (streamingThread != null) streamingThread.pauseStreaming();
            super.pause();
            logI(TAG, "sink.pause() → isPlaying=false (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void flush() {
            // 诊断：切歌/seek/prepare 的边界（载入新曲卡死排查的起点，此前无任何留痕）
            logI(TAG, "sink.flush() exclusive=" + exclusiveEnabled + " hasPending(before)="
                    + lastHasPendingData);
            super.flush();
            if (streamingThread != null) streamingThread.flush();
            usbResampler.reset();
            UsbAudioSink stream = activeStream;
            if (exclusiveEnabled && stream != null) {
                try { stream.flush(); } catch (Exception e) {
                    logE(TAG, "stream.flush failed: " + e.getMessage());
                }
            }
            usbStartMediaTimeNeedsInit = true;
            handledEndOfStream = false;
            // 提交量活性窗口复位：flush 后 framesWritten 归零（native 侧同样清零），
            // 旧的 lastSubmitFrames 会比新值大 → 若不复位会误判「停滞」（见 hasPendingDataExclusive）。
            lastSubmitFrames = -1L;
            lastSubmitGrowMs = 0L;
            submitEverGrew = false;
            // 转换参数键复位：每首歌（新数据纪元）至少重新留一条 CONVERT 痕迹
            lastConvertKey = "";
            // flush = 新的数据纪元（切歌/seek）：**无条件**重置无数据看门狗基准，
            // 给渲染器重新走 configure→handleBuffer 的正常耗时预算（正常切歌装载实测 ~1.3s，
            // < FIRST_DATA_WATCHDOG_MS=3s，故不会误触发）。play() 不再刷新该基准（见 play()）。
            playStartedMs = nowMs();
            if (streamingThread != null) streamingThread.resetEmptySnapshot();
        }

        /** 诊断：渲染器报告流内断点（gap/skip），此前无留痕。 */
        @Override public void handleDiscontinuity() {
            logI(TAG, "sink.handleDiscontinuity() exclusive=" + exclusiveEnabled);
            super.handleDiscontinuity();
        }

        @Override public void reset() {
            // USB 流跨 reset 存活，configure() 管理其生命周期（与 dec 一致）
            logI(TAG, "sink.reset() exclusive=" + exclusiveEnabled);
            super.reset();
        }

        @Override public void release() {
            logI(TAG, "sink.release() exclusive=" + exclusiveEnabled);
            stopStreamingThread();
            super.release();
            liveSinks.remove(this);
        }

        @Override public void setVolume(float volume) {
            // 节流：音量值没变时不通知应用侧（ExoPlayer 初始化可能多次 setVolume 同值）
            boolean changed = volume != lastPlayerVolume;
            pendingVolume = volume;
            lastPlayerVolume = volume;
            if (changed) {
                // 通知应用侧更新 DAC 硬件音量（独占时有效；未独占时应用侧会忽略）
                UsbVolumeListener l = volumeListener;
                if (l != null) l.onPlayerVolumeChanged(volume);
            }
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                // 独占：委托静音（真实音量走 USB 流，原生按位深直写不受音量影响）
                if (!delegateMuted) {
                    super.setVolume(0f);
                    delegateMuted = true;
                }
            } else {
                // 透传：始终把音量传给委托（dec 是条件包装无此路径，本设计始终包装必须处理）
                super.setVolume(volume);
                delegateMuted = false;
            }
        }

        @Override public void playToEndOfStream() throws WriteException {
            // EOS 留痕（限频）：EOS 等待期渲染器会以 ~200Hz 反复驱动本方法，不限频会把
            // 诊断环形缓冲/导出全部灌满（实测一次会话 4716 行、占导出体积 81%）。
            if (++eosProbeCount % 200 == 1L) {
                logI(TAG, "playToEndOfStream (EOS) probe#" + eosProbeCount);
            }
            handledEndOfStream = true;
            super.playToEndOfStream();
        }

        @Override public boolean isEnded() {
            boolean r = super.isEnded();
            if (exclusiveEnabled && (++posLogCount % 500 == 1L)) {
                logI(TAG, "isEnded=" + r + " hasPending(super)=" + super.hasPendingData()
                        + " hasPending(thread)=" + (streamingThread != null && streamingThread.hasPendingData()));
            }
            return r;
        }

        @Override public boolean hasPendingData() {
            if (!exclusiveEnabled) return super.hasPendingData();
            boolean r = hasPendingDataExclusive();
            if (r != lastHasPendingData) {
                lastHasPendingData = r;
                logI(TAG, "hasPendingData=" + r + " | " + pendingSnapshot());
            }
            return r;
        }

        /**
         * 独占态的「还有在途数据」判定（P0-1）。
         *
         * 历史：旧实现用在途量 = framesWritten − played，played 是按墙钟从 play() 起算的
         * DAC 播放头估计并钳到 framesWritten。起播瞬间 native ring（16 URB≈1.36s）是满的，
         * 估计值会**先于真播放头追上 framesWritten**，于是在 ring 尚未播完时就报 pending=0；
         * 一旦 Java 队列也抽干，hasPendingData() 立刻变 false →
         * MediaCodecAudioRenderer.isReady()=false → ExoPlayerImplInternal 判定
         * renderersAllowPlayback=false → 掉 BUFFERING + stopRenderers()；而渲染器不再被调度
         * 就永远不会再喂入数据 → position/在途量同时冻结 → 只能靠 seek 打破。
         *
         * 上一版修复改成 `!handledEndOfStream → true`（无条件真）——治好了误判，但破坏了
         * isReady() 语义（见字段区注释与 SUBMIT_LIVENESS_WINDOW_MS）。现在改为三层：
         *
         * 1. 流不可用（重建窗口）→ 报 true，但**必须流真的在**；否则如实报 false
         *    （退化到 isReady()=false → ExoPlayer 掉 BUFFERING 并重新调度，是正路而非死锁，
         *    因为此时没有「已提交未播」的数据可被误解）。
         * 2. 队列还有待 submit 的数据 → 报 true（无需估算，客观事实）。
         * 3. 否则看**提交量活性**：最近 SUBMIT_LIVENESS_WINDOW_MS 内 framesWritten 有增长 →
         *    报 true（ring 里确实压着已提交未播完的 URB）；从未增长过（刚起播、首个 buffer
         *    还没喂进来）→ 也报 true（不能把「还没开始」误判成「已播完」，这正是旧死锁入口）；
         *    曾经增长但已停滞超过窗口 → 报 false，把控制权交回 ExoPlayer。
         *
         * isEnded()/EOS 判定不受影响（走 delegate，与本方法无关）。
         */
        private boolean hasPendingDataExclusive() {
            UsbAudioSink stream = activeStream;
            // 异步重建窗口（含「已登记未开工」到「重建结束」）：与下面流暂空同理，
            // 窗口内 handleBuffer 返回 false 不喂数、位置不会推进；若此时报 false
            // 会让 ExoPlayer 掉 BUFFERING + stopRenderers() 形成抖动，故窗口内报 true。
            if (isRebuildPending()) return true;
            if (stream == null || !stream.isAlive()) {
                // 重建窗口内 activeStream 暂空：数据只是没地方放、并非「已播完」，
                // 此时报 false 会让 ExoPlayer 掉 BUFFERING + stopRenderers()，而恢复又要
                // 依赖渲染器 → 同类死锁。窗口内报 true。窗口外（真死流）如实报 false。
                return reconfigInProgress;
            }
            // 1) Java 队列还有待 submit 的数据（客观事实，无需估算）
            if (streamingThread != null && streamingThread.hasPendingData()) return true;
            // 2) 提交量活性判定（核心：替代上一版的无条件 true）
            long submitted = stream.getFramesWritten();
            if (submitted > lastSubmitFrames) {
                lastSubmitFrames = submitted;
                lastSubmitGrowMs = nowMs();
                submitEverGrew = true;
            }
            // 3) EOS 之后：按帧差判断 ring 尾巴是否播完（收尾路径，保持原语义）
            if (handledEndOfStream) {
                if (usbSampleRate > 0) {
                    long played = estimatedPlayedFrames(submitted);
                    long pendingUs = (submitted - played) * C.MICROS_PER_SECOND / usbSampleRate;
                    if (pendingUs >= PENDING_MIN_MEDIA_US) return true;
                }
                return false;
            }
            // 4) 未到 EOS：按活性窗口判定
            if (!submitEverGrew) {
                // 本流还没喂进第一块数据（起播前/刚 enable）——这是旧死锁的入口，
                // 必须报 true，否则渲染器被判 not-ready 后就再没人喂数据了。
                // （该场景若长期持续由「起播无数据看门狗」兜底自愈，见 probeNoDataStall。）
                return true;
            }
            if (!isPlaying) {
                // 暂停中提交量天然不增长，ring/队列里客观还压着已提交未播的数据，
                // 不参与「停滞」衰减；恢复播放由 play() 重启活性窗口。
                return true;
            }
            return nowMs() - lastSubmitGrowMs < SUBMIT_LIVENESS_WINDOW_MS;
        }

        /** hasPendingData() 翻转时的状态快照（无副作用，勿调用有重对齐副作用的估计函数）。 */
        private String pendingSnapshot() {
            UsbAudioSink s = activeStream;
            long growAgoMs = submitEverGrew ? (nowMs() - lastSubmitGrowMs) : -1L;
            return "queue=" + (streamingThread != null ? streamingThread.queueSize() : -1)
                    + " submitted=" + (s != null ? s.getFramesWritten() : -1L)
                    + " grewAgoMs=" + growAgoMs
                    + " needsInit=" + usbStartMediaTimeNeedsInit
                    + " playing=" + isPlaying + " eos=" + handledEndOfStream
                    + " alive=" + (s != null && s.isAlive())
                    + " rate=" + usbSampleRate + " ch=" + usbChannelCount;
        }

        /**
         * 起播无数据看门狗探测（P0-3，独立调度线程每 500ms 调用一次）。
         * 仅处理「独占播放中、流健康、但从 play()/flush() 起从未有任何 handleBuffer」的场景：
         * onStallProbe 依赖写线程（首个 handleBuffer 才创建）与入队时间戳（首个入队才置位），
         * 该场景完全探测不到 —— 实测表现为开独占后点播放 13 秒无声，直到用户手动暂停→播放。
         * 触发后复用 auto-seek 自愈（seek → onPositionReset → 渲染器重走
         * format/configure/handleBuffer，等效用户暂停→播放）。与 onStallProbe 共享
         * 自愈冷却与次数上限（tryConsumeRecoveryBudget），防止 seek 风暴。
         * 写线程已存在的情况不走本方法（由 onStallProbe 的队列侧停喂探测兜底）。
         */
        private void probeNoDataStall() {
            if (!exclusiveEnabled || !isPlaying) return;
            if (reconfigInProgress) return;
            UsbAudioSink stream = activeStream;
            if (stream == null || !stream.isAlive()) return;
            if (streamingThread != null) return;
            if (playStartedMs <= 0) return;
            long playingForMs = nowMs() - playStartedMs;
            // [UsbDiag] 判据快照（限频 1s）：进入「播放中且无写线程」的疑似停喂态时留痕，
            // 用于区分「看门狗条件不满足所以没触发」与「触发了但恢复无效」。
            if (nowMs() - lastNoDataProbeLogMs >= 1000L) {
                lastNoDataProbeLogMs = nowMs();
                logW(TAG, "first-data watchdog: playingFor=" + (playingForMs / 1000L)
                        + "s (threshold=" + (FIRST_DATA_WATCHDOG_MS / 1000L) + "s)"
                        + " submitted=" + stream.getFramesWritten()
                        + " needsInit=" + usbStartMediaTimeNeedsInit
                        + " reconfig=" + reconfigInProgress);
            }
            if (playingForMs < FIRST_DATA_WATCHDOG_MS) return;
            tryConsumeRecoveryBudget("no data since play (" + (playingForMs / 1000L) + "s)");
        }

        /** 开关状态变化时由控制器调用。 */
        void onExclusiveChanged(boolean enabled) {
            if (enabled) {
                // 注意：不做 setPreferredDevice 强制路由 —— 那会重启 delegate AudioTrack，
                // 导致 ExoPlayer renderer 误判为播放中（暂停状态也会被喂数据 → 每秒滴答播放）。
                // DAC 已被我们 claim（force=true 断开内核驱动），AudioFlinger 的 usb HAL
                // 打开必然失败并自动 fallback，无需显式路由即可防抢占。
                muteDelegateIfNeeded();
                usbStartMediaTimeNeedsInit = true;
                if (isPlaying) {
                    // 播放中开启独占：与 play() 相同的看门狗/活性窗口基准
                    // （覆盖「先播放后开独占」路径，play() 不会再被调用一次）。
                    playStartedMs = nowMs();
                    lastSubmitGrowMs = nowMs();
                    ensureFirstDataWatchdog();
                }
            } else {
                stopStreamingThread();
                unmuteDelegateIfNeeded();
            }
        }

        private void stopStreamingThread() {
            if (streamingThread != null) {
                streamingThread.stop();
                streamingThread = null;
            }
        }

        /**
         * 强制 AudioTrack 重新 start（直接转发，不走本类的 play/pause 状态逻辑）。
         * 关闭独占后 AudioTrack 曾迁移到未就绪 USB 设备 → 静默无声；重新 start
         * 让 AudioFlinger 重新路由到当前已就绪的设备。
         */
        void restartRouting() {
            try {
                super.pause();
                super.play();
                logI(TAG, "delegate AudioTrack restarted (re-route to USB)");
            } catch (Exception e) {
                logW(TAG, "restartRouting failed: " + e.getMessage());
            }
        }

        private void muteDelegateIfNeeded() {
            if (!delegateMuted) {
                super.setVolume(0f);
                delegateMuted = true;
            }
        }

        private void unmuteDelegateIfNeeded() {
            if (delegateMuted) {
                super.setVolume(pendingVolume);
                delegateMuted = false;
            }
        }
    }
}
