package com.ryanheise.just_audio;

import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.util.Log;
import androidx.annotation.Nullable;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 系统 Direct PCM 输出能力探测（MD3Music fork）。
 *
 * 职责：为「系统 Direct PCM」档提供**可验证**的 bit-perfect 判据，而不是口头宣称。
 *
 * 关键 API 与其最低版本（minSdk 24 下逐项核对过）：
 * <ul>
 *   <li>{@code AudioTrack.getNativeOutputSampleRate(int)} —— @hide，API 17+，
 *       静态方法，反映射。返回该 audio session 所在输出的**原生**采样率；它是
 *       「AudioFlinger 有没有在重采样」的唯一直接证据。</li>
 *   <li>{@code AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE} —— API 1，反射失败时的回退。</li>
 *   <li>{@code AudioManager.getDevice(int)} / {@code AudioDeviceInfo.getSampleRates()} 等
 *       —— API 23+。</li>
 *   <li>{@code AudioTrack.getRoutedDevice()} —— API 31+；低版本用
 *       {@code getDeviceId()}（API 23）回退，功能不缺失，只多一次查询。</li>
 * </ul>
 *
 * <p>取不到实际输出率时**不猜**：状态里标 {@code nativeRateKnown=false}，由 UI 显示
 * 「无法确认」，绝不用 AudioTrack 自己的率冒充原生率。
 */
public final class DirectPcmCapabilities {

    private static final String TAG = "DirectPcmCaps";

    private DirectPcmCapabilities() {}

    // ── 实际输出率探测 ───────────────────────────────────────────────

    /** 反射句柄缓存（首次失败后置空，后续直接走回退）。 */
    @Nullable private static Method nativeOutputSampleRateMethod;
    private static boolean nativeRateReflectionResolved = false;

    /**
     * 取该 audio session 所在输出的原生采样率。
     *
     * @return 采样率（Hz）；无法确认时返回 {@link #UNKNOWN_RATE}
     */
    public static int getNativeOutputSampleRate(int audioSessionId) {
        if (audioSessionId == 0) {
            return fallbackOutputSampleRate();
        }
        int viaReflection = getNativeOutputSampleRateViaReflection(audioSessionId);
        if (viaReflection > 0) {
            return viaReflection;
        }
        return fallbackOutputSampleRate();
    }

    private static int getNativeOutputSampleRateViaReflection(int audioSessionId) {
        if (!nativeRateReflectionResolved) {
            nativeRateReflectionResolved = true;
            try {
                nativeOutputSampleRateMethod =
                        Class.forName("android.media.AudioTrack")
                                .getMethod("getNativeOutputSampleRate", int.class);
            } catch (Throwable t) {
                Log.w(TAG, "getNativeOutputSampleRate 反射不可用: " + t);
                nativeOutputSampleRateMethod = null;
            }
        }
        Method m = nativeOutputSampleRateMethod;
        if (m == null) {
            return UNKNOWN_RATE;
        }
        try {
            Object v = m.invoke(null, audioSessionId);
            if (v instanceof Integer) {
                int rate = (Integer) v;
                return rate > 0 ? rate : UNKNOWN_RATE;
            }
        } catch (Throwable t) {
            Log.w(TAG, "getNativeOutputSampleRate 调用失败: " + t);
        }
        return UNKNOWN_RATE;
    }

    /** 回退：AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE（字符串，可能为空/非法）。 */
    private static int fallbackOutputSampleRate() {
        try {
            Object am = getAudioManager();
            if (!(am instanceof AudioManager)) {
                return UNKNOWN_RATE;
            }
            String v = ((AudioManager) am).getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE);
            if (v == null) {
                return UNKNOWN_RATE;
            }
            int rate = Integer.parseInt(v.trim());
            return rate > 0 ? rate : UNKNOWN_RATE;
        } catch (Throwable t) {
            return UNKNOWN_RATE;
        }
    }

    /** 探测用的 AudioManager。由应用侧插件在注册时注入（避免本模块持有 Context）。 */
    @Nullable private static volatile AudioManager audioManager;

    public static void setAudioManager(@Nullable AudioManager manager) {
        audioManager = manager;
    }

    @Nullable
    private static Object getAudioManager() {
        return audioManager;
    }

    /** 实际输出率无法确认。 */
    public static final int UNKNOWN_RATE = -1;

    // ── @hide API 反射（公开 android.jar 里没有，只能反射；失败即降级） ──
    //
    // 逐一核实（android-35 的公开 android.jar 里确实没有这些方法）：
    //   AudioTrack.setPerformanceMode(int)   @hide —— 低延迟请求的唯一入口
    //   AudioTrack.getPerformanceMode()      **公开**，可用于验证设置是否生效
    //   AudioTrack.getLatency()              @hide —— 仅用于状态展示/诊断
    //   AudioManager.getDevice(int)          @hide —— 故改用 getDevices() + getId() 匹配
    //   AudioDeviceInfo.getChannelMaskConfigs() @hide —— 直接放弃，不做能力上报
    //   AudioDeviceInfo.TYPE_BUILTIN_BLUETOOTH  非公开枚举值 —— 放弃
    //
    // Android 9+ 对非 SDK 接口有灰名单限制：这些方法属灰名单（可反射、带警告），
    // 仍失败时按「拿不到低延迟」降级，不影响播放。

    @Nullable private static Method setPerformanceModeMethod;
    @Nullable private static Method getLatencyMethod;
    private static boolean hiddenApiResolved = false;

    private static void resolveHiddenApi() {
        if (hiddenApiResolved) {
            return;
        }
        hiddenApiResolved = true;
        try {
            setPerformanceModeMethod =
                    Class.forName("android.media.AudioTrack")
                            .getMethod("setPerformanceMode", int.class);
        } catch (Throwable t) {
            setPerformanceModeMethod = null;
        }
        try {
            getLatencyMethod =
                    Class.forName("android.media.AudioTrack").getMethod("getLatency");
        } catch (Throwable t) {
            getLatencyMethod = null;
        }
    }

    /**
     * 请求 AudioTrack 低延迟（fast 通道的必要条件之一）。
     *
     * @return 是否成功（失败只意味着拿不到低延迟，播放不受影响）
     */
    public static boolean requestLowLatency(android.media.AudioTrack audioTrack) {
        resolveHiddenApi();
        Method m = setPerformanceModeMethod;
        if (m == null) {
            return false;
        }
        try {
            m.invoke(audioTrack, android.media.AudioTrack.PERFORMANCE_MODE_LOW_LATENCY);
            return true;
        } catch (Throwable t) {
            // 非 fast 设备可能抛 IllegalStateException；灰名单被拦也可能抛
            Log.w(TAG, "setPerformanceMode 反射调用失败: " + t);
            return false;
        }
    }

    /** AudioTrack 当前是否真的处于低延迟模式（[getPerformanceMode] 是公开 API，可直接调）。 */
    public static boolean isLowLatencyActive(android.media.AudioTrack audioTrack) {
        try {
            return audioTrack.getPerformanceMode()
                    == android.media.AudioTrack.PERFORMANCE_MODE_LOW_LATENCY;
        } catch (Throwable t) {
            return false;
        }
    }

    /** AudioTrack 报告的输出延迟（ms，@hide 反射）；取不到返回 -1。 */
    public static int getAudioTrackLatencyMs(android.media.AudioTrack audioTrack) {
        resolveHiddenApi();
        Method m = getLatencyMethod;
        if (m == null) {
            return -1;
        }
        try {
            Object v = m.invoke(audioTrack);
            if (v instanceof Integer) {
                return (Integer) v;
            }
        } catch (Throwable t) {
            // 忽略：诊断用，取不到不影响功能
        }
        return -1;
    }

    // ── 路由设备探测 ─────────────────────────────────────────────────

    /**
     * 取当前路由输出的设备信息。
     *
     * <p>注意 {@code AudioManager.getDevice(int)} 是 @hide（公开 android.jar 里没有），
     * 因此这里用公开的 {@code getDevices(GET_DEVICES_OUTPUTS)} + {@code getId()} 匹配。
     *
     * @param deviceId 目标设备 id（0 或匹配不到时退化为「挑一个外置 DAC」）
     * @return 设备信息；拿不到时返回 null
     */
    @Nullable
    public static AudioDeviceInfo resolveDevice(int deviceId) {
        AudioManager am = audioManager;
        if (am == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null;
        }
        try {
            AudioDeviceInfo[] outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            if (deviceId > 0) {
                for (AudioDeviceInfo d : outs) {
                    if (d.getId() == deviceId) {
                        return d;
                    }
                }
            }
            return pickExternalOutput(outs);
        } catch (Throwable t) {
            Log.w(TAG, "resolveDevice 失败: " + t);
            return null;
        }
    }

    /** 优先选 USB / 3.5mm / line-in 这类「外置 DAC」类别的输出设备。 */
    @Nullable
    private static AudioDeviceInfo pickExternalOutput(AudioDeviceInfo[] outs) {
        AudioDeviceInfo fallback = null;
        if (outs == null) {
            return null;
        }
        for (AudioDeviceInfo d : outs) {
            if (isExternalDacType(d.getType())) {
                return d;
            }
            if (fallback == null) {
                fallback = d;
            }
        }
        return fallback;
    }

    /** 是否「外置 DAC」类设备（USB DAC / 有线 DAC / line-in）。枚举值全部为公开常量。 */
    public static boolean isExternalDacType(int type) {
        return type == AudioDeviceInfo.TYPE_USB_DEVICE
                || type == AudioDeviceInfo.TYPE_USB_HEADSET
                || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                || type == AudioDeviceInfo.TYPE_LINE_ANALOG
                || type == AudioDeviceInfo.TYPE_LINE_DIGITAL
                || type == AudioDeviceInfo.TYPE_AUX_LINE
                || type == AudioDeviceInfo.TYPE_DOCK_ANALOG
                || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                || type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES;
    }

    // ── 状态快照 ─────────────────────────────────────────────────────

    /**
     * 汇总当前 Direct PCM 的能力与实测数据，供 UI 渲染状态链路与 bit-perfect 判据。
     *
     * @param sessionId  当前 AudioTrack 的 audio session（0 表示尚无）
     * @param deviceId   当前 AudioTrack 的 device id
     * @param sourceRate 解码流采样率（0 = 未知）
     * @param sourceChannels 解码流声道数
     * @param sourceEncoding 解码流 PCM 编码（{@link androidx.media3.common.C} 常量）
     * @param unityVolume 是否处于 unity 音量（track volume 固定 1.0）
     * @param dspBypassed 效果链是否已全部旁路
     */
    public static Map<String, Object> buildStatus(
            int sessionId,
            int deviceId,
            int sourceRate,
            int sourceChannels,
            int sourceEncoding,
            boolean unityVolume,
            boolean dspBypassed) {

        Map<String, Object> map = new HashMap<>();
        map.put("enabled", DirectPcmController.isEnabled());
        map.put("features", DirectPcmController.featuresMap());
        map.put("sourceSampleRate", sourceRate);
        map.put("sourceChannelCount", sourceChannels);
        map.put("sourceEncoding", sourceEncoding);
        map.put("sourceEncodingName", encodingName(sourceEncoding));
        map.put("audioSessionId", sessionId);
        map.put("unityVolume", unityVolume);
        map.put("dspBypassed", dspBypassed);
        map.put("sdkInt", Build.VERSION.SDK_INT);

        int nativeRate = getNativeOutputSampleRate(sessionId);
        map.put("nativeOutputSampleRate", nativeRate);
        map.put("nativeRateKnown", nativeRate > 0);

        AudioDeviceInfo device = resolveDevice(deviceId);
        if (device != null) {
            map.put("deviceName", String.valueOf(device.getProductName()));
            map.put("deviceType", device.getType());
            map.put("deviceTypeName", deviceTypeName(device.getType()));
            map.put("deviceId", device.getId());
            map.put("deviceIsExternalDac", isExternalDacType(device.getType()));
            map.put("deviceSampleRates", toIntArray(device.getSampleRates()));
            map.put("deviceChannelCounts", toIntArray(device.getChannelCounts()));
            // 注：AudioDeviceInfo.getChannelMaskConfigs() 是 @hide，公开 android.jar 里
            // 没有，故不做能力上报（声道数已足够判 bit-perfect）。
        } else {
            map.put("deviceKnown", false);
        }
        map.put("exactRouteProbeSupported", Build.VERSION.SDK_INT >= Build.VERSION_CODES.S);
        map.put("lowLatencySupported", Build.VERSION.SDK_INT >= Build.VERSION_CODES.O);

        // ── AudioTrack 实测值（不是「请求了什么」，而是「实际是什么」） ──
        // 计划要求「不得凭 API 等级声称低延迟已生效，须实测」——这些字段就是证据。
        // performanceMode 用**公开**的 AudioTrack.getPerformanceMode()；
        // latency 用 @hide getLatency() 反射（取不到为 -1）。
        int trackRate = DirectPcmController.getAudioTrackSampleRate();
        map.put("audioTrackSampleRate", trackRate);
        map.put("audioTrackBufferFrames", DirectPcmController.getAudioTrackBufferFrames());
        // 换算基准用 native 率：HAL 强制降级时 getSampleRate() 仍报请求值，
        // 用它换算会把 640ms 的真实缓冲显示成 160ms。
        map.put("audioTrackBufferMs", DirectPcmController.getAudioTrackBufferMs(nativeRate));
        // HAL 是否把我们的请求率降了（track=请求值，actual=按 native 率推算的真实值）
        map.put("halDowngradedRate", nativeRate > 0 && trackRate > 0 && nativeRate != trackRate);
        map.put("audioTrackLatencyMs", DirectPcmController.getAudioTrackLatencyMs());
        map.put("audioTrackLowLatencyMode",
                DirectPcmController.isAudioTrackLowLatencyMode());
        map.put("lowLatencyRequestApplied",
                DirectPcmController.isLowLatencyRequestApplied());
        // AudioTrack 率与 native 率是否一致（不一致 = AudioFlinger 正在重采样）
        map.put("trackMatchesNativeRate", nativeRate > 0 && trackRate > 0 && nativeRate == trackRate);

        boolean rateAligned = nativeRate > 0 && sourceRate > 0 && nativeRate == sourceRate;
        map.put("sampleRateAligned", rateAligned);
        map.put("bitPerfect", rateAligned && unityVolume && dspBypassed);
        map.put("bitPerfectReason", bitPerfectReason(nativeRate, sourceRate, unityVolume, dspBypassed));

        // 一行摘要，便于 logcat 直接 grep（`adb logcat -s DirectPcmCaps:I`），
        // 不必 dump 整个 status map 也不用猜 AudioTrack 到底建在多少 Hz。
        Log.i(TAG, "status: enabled=" + DirectPcmController.isEnabled()
                + " src=" + sourceRate + "Hz/" + sourceChannels + "ch/" + encodingName(sourceEncoding)
                + " track=" + trackRate + "Hz"
                + " native=" + (nativeRate > 0 ? nativeRate + "Hz" : "unknown")
                + " unity=" + unityVolume
                + " dspBypassed=" + dspBypassed
                + " lowLatencyMode=" + DirectPcmController.isAudioTrackLowLatencyMode()
                + " buffer=" + DirectPcmController.getAudioTrackBufferMs() + "ms"
                + " latency=" + DirectPcmController.getAudioTrackLatencyMs() + "ms"
                + " bitPerfect=" + map.get("bitPerfect"));
        return map;
    }

    private static String bitPerfectReason(
            int nativeRate, int sourceRate, boolean unityVolume, boolean dspBypassed) {
        if (nativeRate <= 0) {
            return "无法确认实际输出率（当前 ROM 不提供查询接口），不做判定";
        }
        if (sourceRate > 0 && nativeRate != sourceRate) {
            return "源率 " + sourceRate + " ≠ 输出原生率 " + nativeRate
                    + "（AudioFlinger 会重采样，非 bit-perfect）";
        }
        if (!unityVolume) {
            return "应用音量非 unity（AudioTrack 会施加增益，非 bit-perfect）";
        }
        if (!dspBypassed) {
            return "效果链未全部旁路（均衡器/母带/响度归一会改动样本）";
        }
        return null;
    }

    // ── 小工具 ───────────────────────────────────────────────────────

    private static int[] toIntArray(int[] src) {
        return src == null ? new int[0] : src;
    }

    private static String deviceTypeName(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_USB_DEVICE:
                return "USB 音频设备";
            case AudioDeviceInfo.TYPE_USB_HEADSET:
                return "USB 耳机";
            case AudioDeviceInfo.TYPE_USB_ACCESSORY:
                return "USB 配件";
            case AudioDeviceInfo.TYPE_LINE_ANALOG:
                return "3.5mm 模拟输出";
            case AudioDeviceInfo.TYPE_LINE_DIGITAL:
                return "数字输出";
            case AudioDeviceInfo.TYPE_AUX_LINE:
                return "AUX 输入";
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return "内置扬声器";
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return "听筒";
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
                return "蓝牙 A2DP";
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
                return "蓝牙通话";
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
                return "有线耳机";
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
                return "有线耳机（高阻抗）";
            case AudioDeviceInfo.TYPE_DOCK_ANALOG:
                return "底座模拟输出";
            case AudioDeviceInfo.TYPE_HDMI:
                return "HDMI";
            default:
                return "类型 " + type;
        }
    }

    /** Media3 {@code C.PcmEncoding} 常量 → 中文名（不引 media3 依赖，避免包间耦合）。 */
    public static String encodingName(int encoding) {
        switch (encoding) {
            case 2:  // C.ENCODING_PCM_16BIT
                return "PCM 16bit";
            case 4:  // C.ENCODING_PCM_FLOAT
                return "PCM float32（24bit 有效）";
            case 0x16: // C.ENCODING_PCM_32BIT
                return "PCM 32bit";
            case 3:  // C.ENCODING_PCM_8BIT
                return "PCM 8bit";
            case 0x11: // C.ENCODING_PCM_16BIT_BIG_ENDIAN
                return "PCM 16bit 大端";
            case 0x15: // C.ENCODING_PCM_24BIT_PACKED = 21（API 31）
                return "PCM 24bit packed";
            default:
                return "编码 " + encoding;
        }
    }

    /** 把 int[] 转成便于通道传递的 List（MethodChannel 支持 List 而非 int[]）。 */
    public static List<Integer> toList(int[] src) {
        List<Integer> out = new ArrayList<>();
        if (src != null) {
            for (int v : src) {
                out.add(v);
            }
        }
        return out;
    }
}
