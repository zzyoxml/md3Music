package com.ryanheise.just_audio;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.os.Build;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * MD3Music fork：设备「硬件解码播放（audio offload）」能力探测与快照。
 *
 * <p><b>为什么需要它</b>：Media3 的 offload 支持是逐 format 与系统协商出来的
 * （{@code AudioManager.isOffloadedPlaybackSupported} / API31+ 的
 * {@code getPlaybackOffloadSupport}）。协商结果既决定「能不能硬解」，也是设置页
 * 「设备解码能力」页要展示的内容。本类把协商结果一次性探测成**不可变快照**：
 *
 * <ul>
 *   <li>{@link AudioOffloadController} 的 policy provider 在渲染线程 O(1) 查表 —
 *       绝不在渲染线程调用 AudioManager（binder 往返会拖慢音频喂数据）；</li>
 *   <li>App 侧（Kotlin 插件 → Dart）拿同一份快照渲染能力矩阵，UI 与行为同源。</li>
 * </ul>
 *
 * <p><b>探测维度</b>：编码 × 采样率 × 声道。编码用 mime 表达（不直接引
 * {@code C.ENCODING_*} 常量，避免不同 media3 版本常量差异导致编译失败），
 * 统一经 {@link MimeTypes#getEncoding} 折算成平台编码值，provider 侧用同一函数折算，
 * 保证 key 对齐。
 *
 * <p><b>线程</b>：{@link #probe(ProbeBackend)} 会做数十次 binder 调用，只允许在后台线程
 * 执行；{@link #snapshot()} 是 volatile 读，任意线程可用。
 *
 * <p><b>可测性</b>：真正触碰 Android API 的部分全部收敛在 {@link AndroidProbe}，
 * 探测主逻辑只依赖 {@link ProbeBackend}，可在纯 JVM 单测里注入 fake。
 */
public final class AudioOffloadCapabilities {

    static final String TAG = "AudioOffloadCaps";

    /** 候选编码：mime → 展示名 → 该编码在平台上出现的 API（低于它不探测）。 */
    private static final String[][] CANDIDATE_MIMES = {
        // mime, 展示名, 最低 API
        {"audio/mpeg", "MP3", "23"},
        {"audio/mp4a-latm", "AAC-LC", "21"},
        {"audio/flac", "FLAC", "21"},
        {"audio/opus", "OPUS", "30"},
        {"audio/vorbis", "VORBIS", "30"},
        {"audio/alac", "ALAC", "31"},
        {"audio/ac3", "AC3", "21"},
        {"audio/eac3", "E-AC3", "21"},
    };

    /** 候选采样率：44.1k/48k 是绝大多数媒体场景，向上覆盖 Hi-Res；额外并入设备原生率。 */
    private static final int[] CANDIDATE_RATES = {44100, 48000, 88200, 96000, 176400, 192000};

    /** 候选声道：音乐场景只需单/双声道。 */
    private static final int[] CANDIDATE_CHANNELS = {1, 2};

    /**
     * 机型黑名单：命中即**永不**硬解（协商假支持 / 实测爆音时用，形如
     * {@code "xiaomi/redmi k60"}，小写比较 {@code manufacturer/model}）。
     *
     * <p>默认空：把「哪些机型有问题」交给真机矩阵验证后再填，避免先验地误杀。
     */
    private static final String[] DEVICE_BLACKLIST = {};

    // ── 快照 ─────────────────────────────────────────────────────────

    /** 一个（编码 × 采样率 × 声道）探测结果。 */
    public static final class Entry {
        /** 探测用的 mime（用于展示与回溯）。 */
        public final String mime;
        /** 展示名（MP3 / AAC-LC / FLAC …）。 */
        public final String encodingName;
        /** 平台编码值（{@code C.ENCODING_*} / {@code Format.NO_VALUE}）。 */
        public final int encoding;
        public final int sampleRate;
        public final int channelCount;
        /** 该组合能否硬解。 */
        public final boolean supported;
        /** 硬解时能否无缝（仅 API31+ 才可能为 true）。 */
        public final boolean gapless;
        /** 硬解时能否变速（设备级 {@code offloadVariableRateSupported}）。 */
        public final boolean speedChange;

        Entry(String mime, String encodingName, int encoding, int sampleRate, int channelCount,
                boolean supported, boolean gapless, boolean speedChange) {
            this.mime = mime;
            this.encodingName = encodingName;
            this.encoding = encoding;
            this.sampleRate = sampleRate;
            this.channelCount = channelCount;
            this.supported = supported;
            this.gapless = gapless;
            this.speedChange = speedChange;
        }

        String key() {
            return Snapshot.key(encoding, sampleRate, channelCount);
        }

        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("mime", mime);
            m.put("encoding", encoding);
            m.put("encodingName", encodingName);
            m.put("sampleRate", sampleRate);
            m.put("channelCount", channelCount);
            m.put("supported", supported);
            m.put("gapless", gapless);
            m.put("speedChange", speedChange);
            return m;
        }
    }

    /** 一次探测的完整结果（不可变）。 */
    public static final class Snapshot {
        public final String deviceKey;
        public final long probedAtMs;
        public final int sdkInt;
        public final boolean variableRateSupported;
        public final int outputSampleRate;
        public final int outputFramesPerBuffer;
        /** 探测过程中的致命错误（部分项失败不算，只有整体不可用才填这里）。 */
        @Nullable public final String probeError;
        /** 单次探测耗时（毫秒），给 UI 显示，顺带判断 ROM 是否异常慢。 */
        public final long probeCostMs;
        /**
         * 「没能进入探测矩阵」的编码与原因（如 FLAC/ALAC/VORBIS 在 media3 1.4.1 里
         * 没有 offload 编码映射、OPUS 需要更高系统版本）。UI 需要如实展示 —— 静默消失
         * 会让用户以为「本机不支持」，而实际是「当前播放引擎无法表达」。
         */
        public final List<String> notes;

        private final Map<String, Entry> matrix;

        Snapshot(String deviceKey, long probedAtMs, int sdkInt, boolean variableRateSupported,
                int outputSampleRate, int outputFramesPerBuffer, @Nullable String probeError,
                long probeCostMs, Map<String, Entry> matrix, List<String> notes) {
            this.deviceKey = deviceKey;
            this.probedAtMs = probedAtMs;
            this.sdkInt = sdkInt;
            this.variableRateSupported = variableRateSupported;
            this.outputSampleRate = outputSampleRate;
            this.outputFramesPerBuffer = outputFramesPerBuffer;
            this.probeError = probeError;
            this.probeCostMs = probeCostMs;
            this.matrix = Collections.unmodifiableMap(matrix);
            this.notes = Collections.unmodifiableList(notes);
        }

        public static String key(int encoding, int sampleRate, int channelCount) {
            return encoding + "|" + sampleRate + "|" + channelCount;
        }

        /** 查表；未探测到该组合返回 null。 */
        @Nullable
        public Entry lookup(int encoding, int sampleRate, int channelCount) {
            return matrix.get(key(encoding, sampleRate, channelCount));
        }

        public boolean isEmpty() {
            return matrix.isEmpty();
        }

        public int probedCount() {
            return matrix.size();
        }

        public int supportedCount() {
            int n = 0;
            for (Entry e : matrix.values()) {
                if (e.supported) n++;
            }
            return n;
        }

        /** 转成 MethodChannel 可直传的 Map（键名与 Dart 侧契约一一对应）。 */
        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("deviceKey", deviceKey);
            m.put("probedAtMs", probedAtMs);
            m.put("sdkInt", sdkInt);
            m.put("variableRateSupported", variableRateSupported);
            m.put("outputSampleRate", outputSampleRate);
            m.put("outputFramesPerBuffer", outputFramesPerBuffer);
            m.put("probeError", probeError);
            m.put("probeCostMs", probeCostMs);
            List<Object> entries = new ArrayList<>(matrix.size());
            for (Entry e : matrix.values()) {
                entries.add(e.toMap());
            }
            m.put("entries", entries);
            m.put("notes", new ArrayList<Object>(notes));
            return m;
        }
    }

    // ── 探测后端（Android 实现在下，JVM 单测注入 fake） ────────────────

    /** 探测只依赖这几个原语，便于纯 JVM 单测。 */
    public interface ProbeBackend {
        int sdkInt();

        String deviceKey();

        int outputSampleRate();

        int outputFramesPerBuffer();

        boolean variableRateSupported();

        /**
         * 单点协商。
         *
         * @return 0=不支持；1=支持；2=支持且支持无缝（仅 API31+ 可能出现 2）
         */
        int probe(int encoding, int sampleRate, int channelCount);

        /** mime → 平台编码值；无法识别返回 {@link C#ENCODING_INVALID}。 */
        int encodingForMime(String mime);
    }

    private static volatile Snapshot sSnapshot;
    private static volatile Context sAppContext;
    private static final AtomicBoolean sProbing = new AtomicBoolean(false);

    private AudioOffloadCapabilities() {}

    /** 由 {@code AudioPlayer.buildAudioSink} / Kotlin 插件注入 application context（幂等）。 */
    public static void attachContext(Context context) {
        if (context == null) return;
        Context app = context.getApplicationContext();
        sAppContext = app != null ? app : context;
    }

    @Nullable
    public static Snapshot snapshot() {
        return sSnapshot;
    }

    /** 直接写入快照（仅供诊断/测试预置使用）。 */
    static void setSnapshot(@Nullable Snapshot snapshot) {
        sSnapshot = snapshot;
    }

    /** 机型是否在黑名单里。 */
    public static boolean isBlacklisted() {
        String key = (Build.MANUFACTURER + "/" + Build.MODEL).toLowerCase();
        for (String blocked : DEVICE_BLACKLIST) {
            if (blocked != null && !blocked.isEmpty() && key.contains(blocked)) return true;
        }
        return false;
    }

    /** mime(+codecs) → 平台编码值；无法识别返回 {@link C#ENCODING_INVALID}。 */
    public static int encodingForMimeType(@Nullable String mime, @Nullable String codecs) {
        if (mime == null || mime.isEmpty()) return C.ENCODING_INVALID;
        try {
            int encoding = MimeTypes.getEncoding(mime, codecs);
            if (encoding != C.ENCODING_INVALID) return encoding;
        } catch (Throwable t) {
            // 落到下面的兜底
        }
        // 兜底：media3 的 MimeTypes.getEncoding 对 AAC 依赖 codecs 串，裸 ADTS/AAC
        // （codecs 为 null）会折算失败。AAC-LC 是这里最需要的默认值，否则 AAC 曲目
        // 会被判成「不可硬解」而静默回落软解。
        if (MimeTypes.AUDIO_AAC.equals(mime)) {
            try {
                int encoding = MimeTypes.getEncoding(mime, "mp4a.40.2");
                if (encoding != C.ENCODING_INVALID) return encoding;
            } catch (Throwable ignored) {
                // ignore
            }
        }
        return C.ENCODING_INVALID;
    }

    /**
     * 后台探测一次并写入快照。
     *
     * <p>单飞：已在探测时直接返回当前快照（可能为 null），调用方按「未就绪」处理。
     * 探测失败不抛异常，而是返回带 {@code probeError} 的空快照 —— 此时 policy provider
     * 会回退 Media3 默认协商（不窄化），保证「探测坏了也不影响播放」。
     */
    @Nullable
    public static Snapshot probeOnBackgroundThread() {
        if (!sProbing.compareAndSet(false, true)) {
            return sSnapshot;
        }
        try {
            final Context ctx = sAppContext;
            if (ctx == null) {
                return sSnapshot;
            }
            AudioManager am = null;
            try {
                am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            } catch (Throwable t) {
                Log.w(TAG, "getSystemService(AUDIO_SERVICE) failed: " + t);
            }
            Snapshot snapshot = probe(new AndroidProbe(am));
            sSnapshot = snapshot;
            Log.i(TAG, "probe done: probed=" + snapshot.probedCount()
                    + " supported=" + snapshot.supportedCount()
                    + " variableRate=" + snapshot.variableRateSupported
                    + " costMs=" + snapshot.probeCostMs
                    + (snapshot.probeError != null ? " error=" + snapshot.probeError : ""));
            return snapshot;
        } catch (Throwable t) {
            Log.w(TAG, "probeOnBackgroundThread failed: " + t);
            return sSnapshot;
        } finally {
            sProbing.set(false);
        }
    }

    /** 纯逻辑探测：逐（编码 × 采样率 × 声道）问后端，单项异常只记不支持。 */
    public static Snapshot probe(ProbeBackend backend) {
        long startMs = System.currentTimeMillis();
        Map<String, Entry> matrix = new LinkedHashMap<>();
        List<String> notes = new ArrayList<>();
        String fatal = null;
        int sdkInt = 0;
        String deviceKey = "";
        boolean variableRate = false;
        int outputRate = 0;
        int outputFrames = 0;
        try {
            sdkInt = backend.sdkInt();
            deviceKey = backend.deviceKey();
            variableRate = backend.variableRateSupported();
            outputRate = backend.outputSampleRate();
            outputFrames = backend.outputFramesPerBuffer();
        } catch (Throwable t) {
            fatal = "读取设备音频参数失败：" + t;
        }

        // API < 29 平台没有 offload 协商接口：只给出空矩阵 + 明确错误，供 UI 如实显示。
        if (fatal == null && sdkInt < 29) {
            fatal = "系统版本过低（需 Android 10 / API 29 及以上）";
        }

        if (fatal == null) {
            List<Integer> rates = new ArrayList<>();
            for (int r : CANDIDATE_RATES) rates.add(r);
            if (outputRate > 0 && !rates.contains(outputRate)) rates.add(outputRate);

            for (String[] spec : CANDIDATE_MIMES) {
                String mime = spec[0];
                String name = spec[1];
                int minApi;
                try {
                    minApi = Integer.parseInt(spec[2]);
                } catch (Throwable t) {
                    minApi = 21;
                }
                if (sdkInt < minApi) {
                    notes.add(name + " 需要 Android API " + minApi + "+（当前 " + sdkInt + "），未探测");
                    continue;
                }
                int encoding;
                try {
                    encoding = backend.encodingForMime(mime);
                } catch (Throwable t) {
                    encoding = C.ENCODING_INVALID;
                }
                if (encoding == C.ENCODING_INVALID) {
                    // 当前播放引擎（media3 1.4.1）无法把该 mime 折算成平台编码，
                    // 也就无法向系统发起 offload 协商 —— 如实记录，别让用户以为
                    // 「本机不支持」，实际是「这条通路本版本不存在」。
                    notes.add(name + " 无对应硬解编码通路（当前播放引擎不支持该格式的 offload），未探测");
                    continue;
                }
                for (int rate : rates) {
                    for (int channels : CANDIDATE_CHANNELS) {
                        int result;
                        try {
                            result = backend.probe(encoding, rate, channels);
                        } catch (Throwable t) {
                            result = 0;
                        }
                        boolean supported = result > 0;
                        boolean gapless = result >= 2;
                        Entry entry = new Entry(mime, name, encoding, rate, channels,
                                supported, gapless, supported && variableRate);
                        matrix.put(entry.key(), entry);
                    }
                }
            }
        }

        long costMs = System.currentTimeMillis() - startMs;
        return new Snapshot(deviceKey, System.currentTimeMillis(), sdkInt, variableRate,
                outputRate, outputFrames, fatal, costMs, matrix, notes);
    }

    // ── Android 后端 ─────────────────────────────────────────────────

    /** 真正触碰 Android API 的实现；所有异常都在这里兜住，绝不外抛。 */
    static final class AndroidProbe implements ProbeBackend {
        @Nullable private final AudioManager audioManager;

        AndroidProbe(@Nullable AudioManager audioManager) {
            this.audioManager = audioManager;
        }

        @Override
        public int sdkInt() {
            return Build.VERSION.SDK_INT;
        }

        @Override
        public String deviceKey() {
            return (Build.MANUFACTURER == null ? "" : Build.MANUFACTURER) + "|"
                    + (Build.MODEL == null ? "" : Build.MODEL) + "|"
                    + (Build.DEVICE == null ? "" : Build.DEVICE) + "|android-"
                    + Build.VERSION.SDK_INT;
        }

        @Override
        public int outputSampleRate() {
            return getIntProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE);
        }

        @Override
        public int outputFramesPerBuffer() {
            return getIntProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER);
        }

        @Override
        public boolean variableRateSupported() {
            if (audioManager == null || Build.VERSION.SDK_INT < 29) return false;
            try {
                String kv = audioManager.getParameters("offloadVariableRateSupported");
                return kv != null && kv.equals("offloadVariableRateSupported=1");
            } catch (Throwable t) {
                return false;
            }
        }

        @Override
        public int probe(int encoding, int sampleRate, int channelCount) {
            if (audioManager == null || Build.VERSION.SDK_INT < 29) return 0;
            AudioFormat format;
            try {
                int channelMask = channelCount <= 1
                        ? AudioFormat.CHANNEL_OUT_MONO
                        : AudioFormat.CHANNEL_OUT_STEREO;
                format = new AudioFormat.Builder()
                        .setEncoding(encoding)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelMask)
                        .build();
            } catch (Throwable t) {
                return 0;
            }
            AudioAttributes attributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build();
            try {
                if (Build.VERSION.SDK_INT >= 31) {
                    // 0=NOT_SUPPORTED / 1=SUPPORTED / 2=GAPLESS_SUPPORTED
                    return audioManager.getPlaybackOffloadSupport(format, attributes);
                }
                return audioManager.isOffloadedPlaybackSupported(format, attributes) ? 1 : 0;
            } catch (Throwable t) {
                return 0;
            }
        }

        @Override
        public int encodingForMime(String mime) {
            int encoding = encodingForMimeType(mime, null);
            if (encoding != C.ENCODING_INVALID) return encoding;
            // media3 对部分 mime 需要 codecs 才能折算（如 audio/opus 的 "opus"）。
            switch (mime) {
                case "audio/opus":
                    return encodingForMimeType(mime, "opus");
                case "audio/mp4a-latm":
                    return encodingForMimeType(mime, "mp4a.40.2");
                default:
                    return C.ENCODING_INVALID;
            }
        }

        private int getIntProperty(String key) {
            if (audioManager == null) return 0;
            try {
                String value = audioManager.getProperty(key);
                if (value == null) return 0;
                return Integer.parseInt(value);
            } catch (Throwable t) {
                return 0;
            }
        }
    }

    /** 供诊断：当前曲目格式是否在快照里被判为支持（null = 未知）。 */
    @Nullable
    public static Boolean isFormatSupported(@Nullable String mime, @Nullable String codecs,
            int sampleRate, int channelCount) {
        Snapshot snapshot = sSnapshot;
        if (snapshot == null || snapshot.isEmpty()) return null;
        int encoding = encodingForMimeType(mime, codecs);
        if (encoding == C.ENCODING_INVALID) return false;
        Entry entry = lookupWithFallback(snapshot, encoding, sampleRate, channelCount);
        return entry == null ? null : entry.supported;
    }

    /**
     * 查表（含 AAC 家族回退）。
     *
     * <p>探测只覆盖 {@code ENCODING_AAC_LC}：设备的 AAC offload 支持是**按编码家族**
     * 协商的，HE-AAC v1/v2（酷狗低码率常见）与 LC 共用同一硬件通路。若严格按精确编码
     * 查表，HE-AAC 曲目会因为「没探测过 11/12」而永远回落软解 —— 那是漏支持而不是保守。
     */
    @Nullable
    public static Entry lookupWithFallback(Snapshot snapshot, int encoding, int sampleRate,
            int channelCount) {
        Entry entry = snapshot.lookup(encoding, sampleRate, channelCount);
        if (entry != null) return entry;
        if (isAacFamily(encoding)) {
            return snapshot.lookup(C.ENCODING_AAC_LC, sampleRate, channelCount);
        }
        return null;
    }

    private static boolean isAacFamily(int encoding) {
        return encoding == C.ENCODING_AAC_LC
                || encoding == C.ENCODING_AAC_HE_V1
                || encoding == C.ENCODING_AAC_HE_V2
                || encoding == C.ENCODING_AAC_XHE;
    }

    /** 供状态字符串展示：把 mime 折成短名。 */
    public static String encodingDisplayName(@Nullable String mime) {
        if (mime == null) return "";
        switch (mime) {
            case MimeTypes.AUDIO_RAW:
                return "PCM";
            case MimeTypes.AUDIO_MPEG:
                return "MP3";
            case MimeTypes.AUDIO_AAC:
                return "AAC";
            case MimeTypes.AUDIO_FLAC:
                return "FLAC";
            case MimeTypes.AUDIO_OPUS:
                return "OPUS";
            case MimeTypes.AUDIO_VORBIS:
                return "VORBIS";
            case MimeTypes.AUDIO_ALAC:
                return "ALAC";
            default:
                return mime;
        }
    }

    /** 供 {@link AudioOffloadController} 拼状态：把 format 折成「短名 采样率/声道」。 */
    static String describeFormat(@Nullable Format format) {
        if (format == null) return "";
        String name = encodingDisplayName(format.sampleMimeType);
        StringBuilder sb = new StringBuilder();
        if (!name.isEmpty()) sb.append(name);
        if (format.sampleRate != Format.NO_VALUE) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(format.sampleRate).append("Hz");
        }
        if (format.channelCount != Format.NO_VALUE) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(format.channelCount).append("ch");
        }
        return sb.toString();
    }
}
