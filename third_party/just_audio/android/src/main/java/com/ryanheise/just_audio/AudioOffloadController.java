package com.ryanheise.just_audio;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.audio.AudioOffloadSupport;
import androidx.media3.exoplayer.audio.DefaultAudioOffloadSupportProvider;
import androidx.media3.exoplayer.audio.DefaultAudioSink;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * MD3Music fork：硬件解码播放（audio offload）的控制面。
 *
 * <p><b>职责</b>：
 * <ol>
 *   <li>进程级「是否请求硬解」标志 —— 由 {@code AudioPlayer.setGlobalAudioOffloadEnabled}
 *       写入，再由各播放器实例翻译成 {@code TrackSelectionParameters.AudioOffloadPreferences}；</li>
 *   <li>给 {@code DefaultAudioSink.Builder} 提供 policy provider（用
 *       {@link AudioOffloadCapabilities} 的探测快照收窄可硬解的格式，不按开关状态收窄，
 *       否则会出现「打开开关当首不生效、切歌才生效」的时序 bug）；</li>
 *   <li>把 {@code AudioOffloadListener} 的回调（实际是否 offload / 是否进入休眠调度）
 *       收敛成一份状态快照，供 Kotlin 插件推给 Dart 设置页。</li>
 * </ol>
 *
 * <p><b>为什么 policy provider 不能按开关过滤</b>：Media3 在渲染器 enable 时采集一次
 * {@code RendererCapabilities}（{@code getCapabilities → getFormatOffloadSupport}），
 * 之后轨道重选复用这份快照。若能力随开关变化，改开关后必须先等一次 enable 才生效，
 * 表现为「开关没反应」。所以：能力只由探测结果与机型黑名单决定；开关只决定
 * {@code AudioOffloadPreferences} 的 mode。
 *
 * <p>线程：所有 setter 都是 volatile 写，可在任意线程调用；{@link #status()} 是纯内存读，
 * 但只应在主线程/平台通道线程调用（与 {@code MethodChannel} 语义一致）。
 */
public final class AudioOffloadController {

    static final String TAG = "AudioOffload";

    /** 是否请求硬解（Dart 侧决策后的最终值，不是用户开关的原始意图）。 */
    private static volatile boolean sEffective = false;

    /** Media3 回报的实际状态：AudioTrack 是否真的在 offload 播放。 */
    private static volatile boolean sOffloaded = false;
    /** Media3 回报：是否进入 offload 休眠调度（熄屏省电的核心）。 */
    private static volatile boolean sSleeping = false;
    /** 是否出现过 offload 初始化/写入失败（Media3 会自动关 offload 重试）。 */
    private static volatile boolean sFailed = false;

    /** 当前 sink 输入格式描述（offload 时是压缩码流，否则是 PCM）。 */
    private static volatile String sTrackFormat = "";
    /** 当前 sink 输入的 mime，用于能力对照。 */
    private static volatile String sTrackMime = "";
    private static volatile String sTrackCodecs = "";
    private static volatile int sTrackSampleRate = 0;
    private static volatile int sTrackChannelCount = 0;
    /** 最近一次 {@code setOffloadMode} 的入参（供区分「没请求」与「请求了但被拒」）。 */
    private static volatile int sRequestedOffloadMode = 0;

    @Nullable private static volatile Runnable sStatusListener;

    private static final Handler sMainHandler = new Handler(Looper.getMainLooper());

    private AudioOffloadController() {}

    // ── 开关 ─────────────────────────────────────────────────────────

    public static boolean isEffective() {
        return sEffective;
    }

    static void setEffective(boolean effective) {
        if (sEffective != effective) {
            Log.i(TAG, "setEffective=" + effective);
        }
        sEffective = effective;
        if (!effective) {
            // 关掉后立即清掉「实际在硬解」的旧状态，避免设置页残留上一首的读数。
            sSleeping = false;
        }
        notifyChanged();
    }

    // ── Media3 回调（渲染线程） ───────────────────────────────────────

    /**
     * 供 {@code DefaultAudioSink.Builder.setExperimentalAudioOffloadListener} 使用。
     * 单例即可：状态是进程级的，而同一时刻只有一路音频在播。
     */
    public static ExoPlayer.AudioOffloadListener listener() {
        return sListener;
    }

    private static final ExoPlayer.AudioOffloadListener sListener =
            new ExoPlayer.AudioOffloadListener() {
                @Override
                public void onOffloadedPlayback(boolean isOffloadedPlayback) {
                    if (sOffloaded != isOffloadedPlayback) {
                        Log.i(TAG, "onOffloadedPlayback=" + isOffloadedPlayback
                                + " requested=" + sRequestedOffloadMode
                                + " effective=" + sEffective);
                    }
                    sOffloaded = isOffloadedPlayback;
                    if (!isOffloadedPlayback) {
                        sSleeping = false;
                    }
                    notifyChanged();
                }

                @Override
                public void onSleepingForOffloadChanged(boolean isSleepingForOffload) {
                    sSleeping = isSleepingForOffload;
                    notifyChanged();
                }
            };

    /** {@code DefaultAudioSink.setOffloadMode} 的旁路记录（跨包调用，必须 public）。 */
    public static void onModeRequested(int offloadMode) {
        sRequestedOffloadMode = offloadMode;
    }

    /** sink configure 时记录的输入格式（由 {@code DirectPcmSink.configure} 调用）。 */
    static void onFormat(@Nullable Format format) {
        if (format == null) return;
        sTrackMime = format.sampleMimeType == null ? "" : format.sampleMimeType;
        sTrackCodecs = format.codecs == null ? "" : format.codecs;
        sTrackSampleRate = format.sampleRate;
        sTrackChannelCount = format.channelCount;
        sTrackFormat = AudioOffloadCapabilities.describeFormat(format);
    }

    /** 播放错误里出现 offload 专属错误码时调用（Media3 已自动降级，这里只做记录）。 */
    static void onFailed() {
        sFailed = true;
        Log.w(TAG, "offload failed on platform, Media3 will retry with offload disabled");
        notifyChanged();
    }

    /** 播放器释放时清掉「正在硬解」的旧读数。 */
    static void onPlayerReleased() {
        sOffloaded = false;
        sSleeping = false;
    }

    // ── 状态快照 ─────────────────────────────────────────────────────

    /**
     * 状态 Map（键名与 Dart 侧契约一一对应）。
     *
     * <p>{@code trackSupported} 是三态：true/false/null（null = 尚未探测到该组合）。
     */
    public static Map<String, Object> status() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("effective", sEffective);
        m.put("offloaded", sOffloaded);
        m.put("sleeping", sSleeping);
        m.put("failed", sFailed);
        m.put("requestedMode", sRequestedOffloadMode);
        m.put("trackFormat", sTrackFormat);
        m.put("trackEncoding", AudioOffloadCapabilities.encodingDisplayName(sTrackMime));
        m.put("trackMime", sTrackMime);
        m.put("trackSampleRate", sTrackSampleRate);
        m.put("trackChannelCount", sTrackChannelCount);
        m.put("apiLevel", android.os.Build.VERSION.SDK_INT);
        m.put("blacklisted", AudioOffloadCapabilities.isBlacklisted());

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.snapshot();
        boolean ready = snapshot != null && !snapshot.isEmpty();
        m.put("capabilitySnapshotReady", ready);
        m.put("capabilityProbedAtMs", snapshot == null ? 0L : snapshot.probedAtMs);
        m.put("capabilityDeviceKey", snapshot == null ? "" : snapshot.deviceKey);
        m.put("capabilitySupportedCount", snapshot == null ? 0 : snapshot.supportedCount());
        m.put("capabilityProbedCount", snapshot == null ? 0 : snapshot.probedCount());
        m.put("trackSupported", ready
                ? AudioOffloadCapabilities.isFormatSupported(
                        sTrackMime, sTrackCodecs, sTrackSampleRate, sTrackChannelCount)
                : null);
        return m;
    }

    /** 由 Kotlin 插件注册状态推送回调（跨包调用，必须 public；传 null 即摘除）。 */
    public static void setStatusListener(@Nullable Runnable listener) {
        sStatusListener = listener;
    }

    private static void notifyChanged() {
        final Runnable listener = sStatusListener;
        if (listener == null) return;
        sMainHandler.post(listener);
    }

    // ── policy provider ─────────────────────────────────────────────

    /** 给 {@code DefaultAudioSink.Builder} 用：探测快照驱动的能力收窄。 */
    public static DefaultAudioSink.AudioOffloadSupportProvider policyProvider(Context context) {
        return new PolicyProvider(context);
    }

    private static final class PolicyProvider
            implements DefaultAudioSink.AudioOffloadSupportProvider {

        private final DefaultAudioOffloadSupportProvider fallback;

        PolicyProvider(Context context) {
            this.fallback = new DefaultAudioOffloadSupportProvider(context);
        }

        @Override
        public AudioOffloadSupport getAudioOffloadSupport(
                Format format, AudioAttributes audioAttributes) {
            try {
                if (AudioOffloadCapabilities.isBlacklisted()) {
                    return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
                }
                AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.snapshot();
                if (snapshot == null || snapshot.isEmpty()) {
                    // 快照未就绪：回退 Media3 默认协商（不窄化），避免「探测没跑完就不能硬解」。
                    return fallback.getAudioOffloadSupport(format, audioAttributes);
                }
                if (format.sampleRate == Format.NO_VALUE
                        || format.channelCount == Format.NO_VALUE) {
                    return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
                }
                int encoding = AudioOffloadCapabilities.encodingForMimeType(
                        format.sampleMimeType, format.codecs);
                if (encoding == C.ENCODING_INVALID) {
                    return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
                }
                AudioOffloadCapabilities.Entry entry =
                        AudioOffloadCapabilities.lookupWithFallback(
                                snapshot, encoding, format.sampleRate, format.channelCount);
                if (entry == null || !entry.supported) {
                    return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
                }
                return new AudioOffloadSupport.Builder()
                        .setIsFormatSupported(true)
                        .setIsGaplessSupported(entry.gapless)
                        .setIsSpeedChangeSupported(entry.speedChange)
                        .build();
            } catch (Throwable t) {
                Log.w(TAG, "policyProvider failed: " + t);
                try {
                    return fallback.getAudioOffloadSupport(format, audioAttributes);
                } catch (Throwable t2) {
                    return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
                }
            }
        }
    }
}
