package com.ryanheise.just_audio;

import android.media.AudioManager;
import android.util.Log;
import java.util.HashMap;
import java.util.Map;

/**
 * 系统 Direct PCM 输出控制器（MD3Music fork）。
 *
 * 与 [UsbAudioSinkController] 是**互斥的两条出口**：两者共用同一个 AudioSink 链，
 * 不能同时生效，由本类的 {@link #isEnabled()} 与对方的存在性检查共同保证。
 *
 * 设计（沿用 USB 独占那套「无条件安装 + 运行期静态开关」的结构）：
 * - [DirectPcmSink] 在 ExoPlayer 构建时永久插入链上，未开启时**字节级完全透传**，
 *   因此运行时开关与各子开关都不需要重建播放器；只有「切档本身」需要重配 AudioTrack
 *   （float 强制 / performanceMode / 缓冲都在 {@code DefaultAudioSink.configure} 生效），
 *   由应用侧在切档后统一触发 pause→play。
 *
 * 相比 USB 独占，本档**不碰 usbdevfs**、不 force-claim、不改 USB 配置，
 * 因此对 DAC 的兼容性最好；代价是仍经 AudioFlinger，能否落到 fast 通道
 * 取决于厂商 audio HAL 是否把该输出标记为 fast device。
 */
public final class DirectPcmController {

    private static final String TAG = "DirectPcmCtrl";

    // ── 子开关的持久化 key（与 Dart 侧 DirectPcmFeature.specKey 一一对应） ──

    public static final String KEY_HIGH_PRECISION = "settings_direct_pcm_high_precision";
    public static final String KEY_DSP_BYPASS = "settings_direct_pcm_dsp_bypass";
    public static final String KEY_UNITY_VOLUME = "settings_direct_pcm_unity_volume";
    public static final String KEY_LOW_LATENCY = "settings_direct_pcm_low_latency";
    public static final String KEY_EXACT_ROUTE = "settings_direct_pcm_exact_route";
    public static final String KEY_NATIVE_RATE = "settings_direct_pcm_native_rate";
    public static final String KEY_RATE_ALIGNMENT = "settings_direct_pcm_rate_alignment";

    // ── 日志桥接（与应用侧 UsbLog 环形缓冲对齐，避免日志只进 logcat 无法随诊断导出） ──

    /** 应用侧日志桥接（由 app 模块的 DirectPcmPlugin 注入）。 */
    public interface DirectPcmLogForwarder {
        void forward(char level, String tag, String msg);
    }

    private static volatile DirectPcmLogForwarder logForwarder = null;

    public static void setLogForwarder(DirectPcmLogForwarder forwarder) {
        logForwarder = forwarder;
    }

    /**
     * 状态变化通知（由应用侧 DirectPcmPlugin 注入）。
     *
     * <p>为什么必需：AudioTrack 的实测值（率/缓冲/低延迟）只有在 sink configure
     * 之后才知道，而播放中 AudioFlinger 可能让 HAL 降级并触发 Media3 重建 track
     * （实测：192kHz → 48kHz，Port Id 也换）。若只在打开设置页时取一次状态，
     * 面板会一直显示**过期**的实测值，等于误导用户。
     */
    public interface DirectPcmStatusListener {
        void onStatusMayChanged();
    }

    private static volatile DirectPcmStatusListener statusListener = null;

    public static void setStatusListener(DirectPcmStatusListener listener) {
        statusListener = listener;
    }

    public static void notifyStatusMayChanged() {
        DirectPcmStatusListener l = statusListener;
        if (l != null) {
            l.onStatusMayChanged();
        }
    }

    private static void logI(String msg) {
        Log.i(TAG, msg);
        DirectPcmLogForwarder f = logForwarder;
        if (f != null) f.forward('I', TAG, msg);
    }

    private static void logW(String msg) {
        Log.w(TAG, msg);
        DirectPcmLogForwarder f = logForwarder;
        if (f != null) f.forward('W', TAG, msg);
    }

    // ── 全局状态 ─────────────────────────────────────────────────────

    private static volatile boolean enabled = false;

    /** 各子开关的**生效值**（应用侧已完成 SDK 门控后下发，这里只存最终值）。 */
    private static final Map<String, Boolean> features = new HashMap<>();

    static {
        for (String key : new String[] {
                KEY_HIGH_PRECISION, KEY_DSP_BYPASS, KEY_UNITY_VOLUME,
                KEY_LOW_LATENCY, KEY_EXACT_ROUTE, KEY_NATIVE_RATE, KEY_RATE_ALIGNMENT }) {
            features.put(key, Boolean.FALSE);
        }
    }

    // ── 当前流格式（由 DirectPcmSink.configure 记录） ────────────────

    private static volatile int lastSampleRate = 0;
    private static volatile int lastChannelCount = 0;
    private static volatile int lastEncoding = 0;
    private static volatile int audioSessionId = 0;
    private static volatile int deviceId = 0;
    private static volatile float lastVolume = 1f;
    private static volatile boolean hasData = false;

    // ── AudioTrack 实测值（由 DefaultAudioSink 建轨后回填） ──
    // 计划要求「不得凭 API 等级声称低延迟已生效，须实测」——这些字段就是实测证据：
    // performanceMode 用**公开**的 AudioTrack.getPerformanceMode()，
    // latency 用 @hide getLatency() 反射（取不到为 -1）。
    private static volatile int audioTrackSampleRate = 0;
    private static volatile int audioTrackBufferFrames = 0;
    private static volatile int audioTrackLatencyMs = -1;
    private static volatile boolean audioTrackLowLatencyMode = false;
    private static volatile int lowLatencyRequestApplied = 0; // 0=未请求 1=成功 -1=失败

    private DirectPcmController() {}

    public static boolean isEnabled() {
        return enabled;
    }

    public static void setEnabled(boolean value) {
        if (enabled == value) {
            return;
        }
        enabled = value;
        // 关闭时清空流信息，避免 UI 展示上一条流的数据
        if (!value) {
            hasData = false;
            lastSampleRate = 0;
            lastChannelCount = 0;
            lastEncoding = 0;
        }
        logI("setEnabled: " + value);
    }

    // ── 子开关 ───────────────────────────────────────────────────────

    public static void setFeature(String key, boolean value) {
        if (key == null) {
            return;
        }
        if (!features.containsKey(key)) {
            logW("未知子开关: " + key);
            return;
        }
        features.put(key, value);
        logI("setFeature " + key + " = " + value);
    }

    public static void setFeatures(Map<String, Boolean> values) {
        if (values == null) {
            return;
        }
        for (Map.Entry<String, Boolean> e : values.entrySet()) {
            setFeature(e.getKey(), Boolean.TRUE.equals(e.getValue()));
        }
    }

    public static boolean isFeatureEnabled(String key) {
        Boolean v = features.get(key);
        return v != null && v;
    }

    /**
     * 是否强制高规格输出（float32 / PCM_32bit）。
     *
     * 由 {@code DefaultAudioSink.floatOutputRequested()} 读取，是「不被降 16bit」的前提。
     */
    public static boolean isHighPrecisionOutputEnabled() {
        return enabled && isFeatureEnabled(KEY_HIGH_PRECISION);
    }

    /** 是否请求低延迟（fast 通道）。{@code DefaultAudioSink} 侧还会再判一次 SDK_INT >= 26。 */
    public static boolean isLowLatencyEnabled() {
        return enabled && isFeatureEnabled(KEY_LOW_LATENCY);
    }

    public static boolean isDspBypassEnabled() {
        return enabled && isFeatureEnabled(KEY_DSP_BYPASS);
    }

    public static boolean isUnityVolumeEnabled() {
        return enabled && isFeatureEnabled(KEY_UNITY_VOLUME);
    }

    public static Map<String, Boolean> featuresMap() {
        return new HashMap<>(features);
    }

    // ── 流信息记录（供状态上报） ─────────────────────────────────────

    static void onFormatConfigured(int sampleRate, int channelCount, int encoding) {
        if (sampleRate > 0) {
            lastSampleRate = sampleRate;
        }
        if (channelCount > 0) {
            lastChannelCount = channelCount;
        }
        if (encoding > 0) {
            lastEncoding = encoding;
        }
        hasData = true;
        // 新流开始即作废旧 track 的实测值，否则状态面板会把上一首的率/缓冲
        // 当成当前流显示（实测踩过：切歌后仍显示 192kHz）。
        audioTrackSampleRate = 0;
        audioTrackBufferFrames = 0;
        audioTrackLatencyMs = -1;
        audioTrackLowLatencyMode = false;
        lowLatencyRequestApplied = 0;
        notifyStatusMayChanged();
    }

    static void onAudioSessionId(int sessionId) {
        audioSessionId = sessionId;
    }

    static void onVolume(float volume) {
        lastVolume = volume;
        // 音量变了会改变 unity 判定 → bit-perfect 结论可能翻转（如用户拖回非 1.0）
        notifyStatusMayChanged();
    }

    static void setDeviceId(int id) {
        deviceId = id;
    }

    /**
     * AudioTrack 建好后回填实测值。
     *
     * @param lowLatencyRequested 「低延迟」子开关当时是否生效（用于区分「没请求」与「请求失败」）
     */
    public static void onAudioTrackCreated(
            android.media.AudioTrack audioTrack, boolean lowLatencyRequested) {
        if (!enabled) {
            return;
        }
        try {
            audioTrackSampleRate = audioTrack.getSampleRate();
            audioTrackBufferFrames = audioTrack.getBufferSizeInFrames();
            audioTrackLatencyMs = DirectPcmCapabilities.getAudioTrackLatencyMs(audioTrack);
            audioTrackLowLatencyMode = DirectPcmCapabilities.isLowLatencyActive(audioTrack);
            logI("AudioTrack measured: rate=" + audioTrackSampleRate
                    + "Hz buffer=" + audioTrackBufferFrames + "fr ("
                    + (audioTrackSampleRate > 0
                            ? (audioTrackBufferFrames * 1000L / audioTrackSampleRate) : 0)
                    + "ms)"
                    + " latency=" + audioTrackLatencyMs + "ms"
                    + " lowLatencyMode=" + audioTrackLowLatencyMode
                    + " (requested=" + lowLatencyRequested + ")");
            notifyStatusMayChanged();
        } catch (Throwable t) {
            logW("onAudioTrackCreated failed: " + t);
        }
    }

    public static void setLowLatencyRequestApplied(int value) {
        lowLatencyRequestApplied = value;
    }

    public static int getAudioTrackSampleRate() {
        return audioTrackSampleRate;
    }

    public static int getAudioTrackBufferFrames() {
        return audioTrackBufferFrames;
    }

    /**
     * AudioTrack 实际缓冲对应的毫秒数。
     *
     * <p>注意换算基准：HAL 强制降级时（实测 192kHz 请求 → HAL 只开 48kHz），
     * {@code AudioTrack.getSampleRate()} 仍返回**请求值**，而帧数是按**实际率**分配的。
     * 直接用 getSampleRate() 换算会把 640ms 的真实缓冲显示成 160ms（误导）。
     * 故传入 native 率（已知时优先）来换算。
     */
    public static int getAudioTrackBufferMs(int effectiveRate) {
        if (audioTrackBufferFrames <= 0) {
            return 0;
        }
        final int rate = effectiveRate > 0 ? effectiveRate : audioTrackSampleRate;
        return rate > 0 ? (int) (audioTrackBufferFrames * 1000L / rate) : 0;
    }

    public static int getAudioTrackBufferMs() {
        return getAudioTrackBufferMs(0);
    }

    public static int getAudioTrackLatencyMs() {
        return audioTrackLatencyMs;
    }

    public static boolean isAudioTrackLowLatencyMode() {
        return audioTrackLowLatencyMode;
    }

    public static boolean isLowLatencyRequestApplied() {
        return lowLatencyRequestApplied > 0;
    }

    public static int getLastSampleRate() {
        return lastSampleRate;
    }

    public static int getLastChannelCount() {
        return lastChannelCount;
    }

    public static int getLastEncoding() {
        return lastEncoding;
    }

    public static boolean hasData() {
        return hasData;
    }

    // ── AudioManager 注入（供实际输出率 / 设备能力探测） ─────────────

    public static void attachContext(android.content.Context context) {
        try {
            DirectPcmCapabilities.setAudioManager(
                    (AudioManager) context.getApplicationContext()
                            .getSystemService(android.content.Context.AUDIO_SERVICE));
        } catch (Throwable t) {
            Log.w(TAG, "attachContext 失败: " + t);
        }
    }

    /** 状态快照（供应用侧 MethodChannel 返回给 Dart）。 */
    public static Map<String, Object> getStatus() {
        boolean unity = isUnityVolumeEnabled();
        return DirectPcmCapabilities.buildStatus(
                audioSessionId,
                deviceId,
                lastSampleRate,
                lastChannelCount,
                lastEncoding,
                unity,
                isDspBypassEnabled());
    }

    /** 当前 AudioTrack 是否处于 unity 音量（状态里已含，供 UI 显示）。 */
    public static boolean isCurrentlyUnityVolume() {
        return isUnityVolumeEnabled() && lastVolume >= 0.999f;
    }
}
