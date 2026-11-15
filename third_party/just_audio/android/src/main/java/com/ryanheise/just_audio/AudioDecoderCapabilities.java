package com.ryanheise.just_audio;

import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.media3.common.MimeTypes;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * MD3Music fork：设备**解码器能力**探测（MediaCodec 枚举）。
 *
 * <p><b>与 {@link AudioOffloadCapabilities} 的分工</b>（两者是 AND 关系，别混用）：
 * <ul>
 *   <li>{@code AudioOffloadCapabilities} 问的是「系统愿不愿意把这段编码码流直接交给
 *       HAL/DSP 播」（{@code AudioManager.isOffloadedPlaybackSupported} 协商）；</li>
 *   <li>本类问的是「这颗 SoC 到底有没有这个格式的（硬件）解码器、支持哪些采样率/声道/
 *       位深」。用户看到的「设备解码能力」页应以本类为准，offload 协商作为附加条件展示。</li>
 * </ul>
 *
 * <p><b>位深为什么要试配</b>：{@code MediaCodecInfo.CodecCapabilities} 不暴露「输出
 * PCM 位深」清单，唯一可靠判据是拿目标 {@code KEY_PCM_ENCODING} 真正 configure 一次
 * （不 start），成功即支持。为了不拖慢页面也不占满解码器实例：
 * <ul>
 *   <li>只对前 {@link #MAX_CODECS_FOR_BITDEPTH} 个解码器试配；</li>
 *   <li>总尝试次数与耗时都有预算，超预算余项记 {@code unknown}；</li>
 *   <li>每次 configure 后立即 release；异常只降级、不外抛。</li>
 * </ul>
 *
 * <p><b>16bit 基线门控</b>：若 16bit 都配不起来（常见于必须带 CSD 的 codec，例如裸 AAC），
 * 说明失败原因不是位深，其余位深一律记 {@code unknown} —— 绝不能据此宣称「不支持」。
 *
 * <p>可测性：真正触碰 Android API 的部分在 {@link AndroidProbe}，聚合/排序/位深门控
 * 都在本类的静态方法里，可用 {@link ProbeBackend} 注入 fake 做纯 JVM 单测。
 */
public final class AudioDecoderCapabilities {

    static final String TAG = "AudioDecoderCaps";

    /** 位深键（与 Dart 侧 DecoderBitDepth 一一对应）。 */
    public static final String DEPTH_16 = "16";
    public static final String DEPTH_24 = "24";
    public static final String DEPTH_32 = "32";
    public static final String DEPTH_FLOAT = "float";

    /** 位深三态值。 */
    public static final String SUPPORTED = "supported";
    public static final String UNSUPPORTED = "unsupported";
    public static final String UNKNOWN = "unknown";

    /** 候选采样率（44.1k/48k 是音频主流，向上覆盖 Hi-Res）。 */
    private static final int[] CANDIDATE_RATES = {44100, 48000, 88200, 96000, 176400, 192000};

    /** 位深试配预算：最多这么多个解码器参与位深探测。 */
    private static final int MAX_CODECS_FOR_BITDEPTH = 16;
    /** 位深试配预算：最多这么多次 configure。 */
    private static final int MAX_CONFIGURE_ATTEMPTS = 48;
    /** 位深试配预算：总耗时上限（毫秒）。 */
    private static final long MAX_BITDEPTH_MS = 600L;

    private AudioDecoderCapabilities() {}

    // ── 数据模型 ───────────────────────────────────────────────────

    /** 一个「解码器 × 格式」的能力条目。 */
    public static final class Entry {
        public final String codecName;
        public final String mime;
        public final String formatLabel;
        public final boolean hardware;
        public final boolean softwareOnly;
        /** 是否真的试配过位深；false 表示整行位深都来自「跳过」而非实测。 */
        public final boolean bitDepthProbed;
        /** 该解码器上报支持的采样率（升序）。 */
        public final int[] sampleRates;
        /** 最大输入声道数；0 = 未知。 */
        public final int maxChannels;
        /** 位深键 → {@link #SUPPORTED}/{@link #UNSUPPORTED}/{@link #UNKNOWN}。 */
        public final Map<String, String> bitDepths;

        public Entry(String codecName, String mime, String formatLabel, boolean hardware,
                boolean softwareOnly, int[] sampleRates, int maxChannels,
                Map<String, String> bitDepths, boolean bitDepthProbed) {
            this.codecName = codecName;
            this.mime = mime;
            this.formatLabel = formatLabel;
            this.hardware = hardware;
            this.softwareOnly = softwareOnly;
            this.sampleRates = sampleRates;
            this.maxChannels = maxChannels;
            this.bitDepths = bitDepths;
            this.bitDepthProbed = bitDepthProbed;
        }

        public boolean isHardware() {
            return hardware && !softwareOnly;
        }

        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("codecName", codecName);
            m.put("mime", mime);
            m.put("formatLabel", formatLabel);
            m.put("hardware", hardware);
            m.put("softwareOnly", softwareOnly);
            m.put("bitDepthProbed", bitDepthProbed);
            List<Object> rates = new ArrayList<>(sampleRates.length);
            for (int r : sampleRates) rates.add(r);
            m.put("sampleRates", rates);
            m.put("maxChannels", maxChannels);
            m.put("bitDepths", new LinkedHashMap<String, Object>(bitDepths));
            return m;
        }
    }

    /** 一次解码器能力探测的完整结果（不可变）。 */
    public static final class Snapshot {
        public final String deviceKey;
        public final long probedAtMs;
        public final int sdkInt;
        public final long probeCostMs;
        @Nullable public final String probeError;
        public final List<Entry> entries;
        public final List<String> notes;

        Snapshot(String deviceKey, long probedAtMs, int sdkInt, long probeCostMs,
                @Nullable String probeError, List<Entry> entries, List<String> notes) {
            this.deviceKey = deviceKey;
            this.probedAtMs = probedAtMs;
            this.sdkInt = sdkInt;
            this.probeCostMs = probeCostMs;
            this.probeError = probeError;
            this.entries = Collections.unmodifiableList(entries);
            this.notes = Collections.unmodifiableList(notes);
        }

        public boolean isEmpty() {
            return entries.isEmpty();
        }

        public int hardwareCodecCount() {
            Set<String> names = new LinkedHashSet<>();
            for (Entry e : entries) {
                if (e.isHardware()) names.add(e.codecName);
            }
            return names.size();
        }

        public int supportedFormatCount() {
            Set<String> labels = new LinkedHashSet<>();
            for (Entry e : entries) {
                labels.add(e.formatLabel);
            }
            return labels.size();
        }

        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("deviceKey", deviceKey);
            m.put("probedAtMs", probedAtMs);
            m.put("sdkInt", sdkInt);
            m.put("probeCostMs", probeCostMs);
            m.put("probeError", probeError);
            List<Object> list = new ArrayList<>(entries.size());
            for (Entry e : entries) list.add(e.toMap());
            m.put("entries", list);
            m.put("notes", new ArrayList<Object>(notes));
            return m;
        }
    }

    /** 平台枚举后端（JVM 单测注入 fake）。 */
    public interface ProbeBackend {
        int sdkInt();

        String deviceKey();

        /**
         * 枚举音频解码器能力。
         *
         * @param notesOut 后端可追加「无法探测」的说明（例如 APE/DSD 无系统解码器）
         */
        List<Entry> enumerate(List<String> notesOut);
    }

    // ── 纯逻辑：聚合 / 排序 / 位深门控 ───────────────────────────────

    /**
     * 位深基线门控：16bit 配不起来时，其余位深一律 {@code unknown}。
     *
     * @param attempts 位深 → tryConfigure 结果（true 支持 / false 不支持 / 缺键=未尝试）
     */
    public static Map<String, String> resolveBitDepths(Map<String, Boolean> attempts) {
        Map<String, String> out = new LinkedHashMap<>();
        final boolean baselineOk = Boolean.TRUE.equals(attempts.get(DEPTH_16));
        final String[] order = {DEPTH_16, DEPTH_24, DEPTH_32, DEPTH_FLOAT};
        for (String depth : order) {
            if (!baselineOk) {
                // 连 16bit 都配不起来：更可能是缺 CSD/参数不接受，不能据此判位深。
                out.put(depth, UNKNOWN);
                continue;
            }
            Boolean value = attempts.get(depth);
            if (value == null) {
                out.put(depth, UNKNOWN);
            } else {
                out.put(depth, value ? SUPPORTED : UNSUPPORTED);
            }
        }
        return out;
    }

    /** 聚合入口：去重 → 排序（硬件优先）→ 补 notes。 */
    public static Snapshot probe(ProbeBackend backend) {
        long startMs = System.currentTimeMillis();
        int sdkInt = 0;
        String deviceKey = "";
        String fatal = null;
        List<Entry> raw = new ArrayList<>();
        List<String> notes = new ArrayList<>();
        try {
            sdkInt = backend.sdkInt();
            deviceKey = backend.deviceKey();
            List<Entry> enumerated = backend.enumerate(notes);
            if (enumerated != null) raw.addAll(enumerated);
        } catch (Throwable t) {
            fatal = "解码器枚举失败：" + t;
        }

        // 去重：同一 codec 的同一 mime 只留一条（个别 ROM 会重复上报）。
        Map<String, Entry> dedup = new LinkedHashMap<>();
        for (Entry e : raw) {
            if (e == null || e.codecName == null || e.mime == null) continue;
            dedup.put(e.codecName + "|" + e.mime, e);
        }
        List<Entry> entries = new ArrayList<>(dedup.values());

        // 排序：硬件解码器优先，其次按格式名/解码器名，保证页面顺序稳定。
        Collections.sort(entries, (a, b) -> {
            if (a.isHardware() != b.isHardware()) return a.isHardware() ? -1 : 1;
            int byLabel = a.formatLabel.compareTo(b.formatLabel);
            if (byLabel != 0) return byLabel;
            int byMime = a.mime.compareTo(b.mime);
            if (byMime != 0) return byMime;
            return a.codecName.compareTo(b.codecName);
        });

        if (fatal == null && entries.isEmpty()) {
            fatal = "未枚举到任何音频解码器";
        }

        // 派生 notes：只有软解解码器的格式、位深被跳过的条目。
        if (fatal == null) {
            Map<String, Boolean> hardwareByLabel = new LinkedHashMap<>();
            boolean anySkipped = false;
            for (Entry e : entries) {
                boolean prev = Boolean.TRUE.equals(hardwareByLabel.get(e.formatLabel));
                hardwareByLabel.put(e.formatLabel, prev || e.isHardware());
                if (!e.bitDepthProbed) anySkipped = true;
            }
            for (Map.Entry<String, Boolean> kv : hardwareByLabel.entrySet()) {
                if (!Boolean.TRUE.equals(kv.getValue())) {
                    notes.add(kv.getKey() + " 只有软件解码器，无硬件解码通路");
                }
            }
            if (anySkipped) {
                notes.add("位深未实测：部分解码器超出试配预算或系统版本不支持该位深（显示为未确认）");
            }
        }

        long costMs = System.currentTimeMillis() - startMs;
        return new Snapshot(deviceKey, System.currentTimeMillis(), sdkInt, costMs, fatal,
                entries, notes);
    }

    // ── 快照存取 ───────────────────────────────────────────────────

    private static volatile Snapshot sSnapshot;
    private static final AtomicBoolean sProbing = new AtomicBoolean(false);

    @Nullable
    public static Snapshot snapshot() {
        return sSnapshot;
    }

    static void setSnapshot(@Nullable Snapshot snapshot) {
        sSnapshot = snapshot;
    }

    /**
     * 后台探测一次并写入快照（单飞；正在探测时直接返回旧快照）。
     *
     * <p>不需要 Context：{@code MediaCodecList} 是静态系统服务。
     */
    @Nullable
    public static Snapshot probeOnBackgroundThread() {
        if (!sProbing.compareAndSet(false, true)) {
            return sSnapshot;
        }
        try {
            Snapshot snapshot = probe(new AndroidProbe());
            sSnapshot = snapshot;
            Log.i(TAG, "probe done: codecs=" + snapshot.entries.size()
                    + " hardware=" + snapshot.hardwareCodecCount()
                    + " formats=" + snapshot.supportedFormatCount()
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

    // ── Android 后端 ───────────────────────────────────────────────

    /** 真正触碰 Android API 的实现；所有异常都在这里兜住。 */
    static final class AndroidProbe implements ProbeBackend {

        /** 位深试配预算（跨解码器共享）。 */
        private int configureAttempts;
        private long bitDepthDeadlineMs;
        private int bitDepthCodecs;

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
        public List<Entry> enumerate(List<String> notesOut) {
            List<Entry> out = new ArrayList<>();
            bitDepthDeadlineMs = System.currentTimeMillis() + MAX_BITDEPTH_MS;
            MediaCodecInfo[] infos;
            try {
                infos = new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos();
            } catch (Throwable t) {
                throw new IllegalStateException("MediaCodecList 不可用：" + t, t);
            }
            for (MediaCodecInfo info : infos) {
                // 平台 MediaCodecInfo 只有 isEncoder()（isDecoder 是 media3 包装类的 API）。
                if (info == null || info.isEncoder()) continue;
                final boolean hardware = Build.VERSION.SDK_INT >= 29
                        ? info.isHardwareAccelerated()
                        : !info.isSoftwareOnly();
                final boolean softwareOnly = Build.VERSION.SDK_INT >= 29
                        ? info.isSoftwareOnly()
                        : !hardware;
                String[] types;
                try {
                    types = info.getSupportedTypes();
                } catch (Throwable t) {
                    continue;
                }
                if (types == null) continue;
                for (String mime : types) {
                    if (mime == null || !mime.startsWith("audio/")) continue;
                    MediaCodecInfo.CodecCapabilities caps;
                    try {
                        caps = info.getCapabilitiesForType(mime);
                    } catch (Throwable t) {
                        continue;
                    }
                    if (caps == null) continue;

                    int maxChannels = 0;
                    List<Integer> rates = new ArrayList<>();
                    MediaCodecInfo.AudioCapabilities audioCaps = null;
                    try {
                        audioCaps = caps.getAudioCapabilities();
                    } catch (Throwable t) {
                        audioCaps = null;
                    }
                    if (audioCaps != null) {
                        try {
                            maxChannels = audioCaps.getMaxInputChannelCount();
                        } catch (Throwable ignored) {
                            maxChannels = 0;
                        }
                        for (int rate : CANDIDATE_RATES) {
                            boolean ok;
                            try {
                                ok = audioCaps.isSampleRateSupported(rate);
                            } catch (Throwable t) {
                                ok = false;
                            }
                            if (ok) rates.add(rate);
                        }
                    }
                    if (rates.isEmpty()) {
                        // 部分 ROM 的 codec 不实现 AudioCapabilities：不猜采样率，留给 UI 显示
                        // 「未上报采样率」，位深试配也因缺少可信采样率而跳过（记未确认）。
                        rates.clear();
                    }

                    boolean probed = false;
                    Map<String, String> depths;
                    if (hardware) {
                        boolean[] probedFlag = new boolean[1];
                        Map<String, String> resolved = probeBitDepths(
                                info.getName(), mime, rates, maxChannels, probedFlag);
                        depths = resolved;
                        probed = probedFlag[0];
                    } else {
                        // 软件解码器不做位深试配：页面上它本来就不是硬解候选，试配只会白烧预算。
                        depths = resolveBitDepths(new LinkedHashMap<String, Boolean>());
                    }

                    int[] rateArray = new int[rates.size()];
                    for (int i = 0; i < rates.size(); i++) rateArray[i] = rates.get(i);
                    out.add(new Entry(info.getName(), mime, formatLabel(mime), hardware,
                            softwareOnly, rateArray, maxChannels, depths, probed));
                }
            }
            if (out.isEmpty()) {
                notesOut.add("系统未报告任何音频解码器（ROM 限制或查询被拒）");
            }
            return out;
        }

        /** 位深试配；预算耗尽后返回的条目位深全为 unknown（probedFlag=false）。 */
        private Map<String, String> probeBitDepths(String codecName, String mime,
                List<Integer> rates, int maxChannels, boolean[] probedFlag) {
            Map<String, Boolean> attempts = new LinkedHashMap<>();
            probedFlag[0] = false;
            if (Build.VERSION.SDK_INT < 21) {
                return resolveBitDepths(attempts);
            }
            if (bitDepthCodecs >= MAX_CODECS_FOR_BITDEPTH
                    || System.currentTimeMillis() > bitDepthDeadlineMs
                    || rates.isEmpty()) {
                return resolveBitDepths(attempts);
            }
            bitDepthCodecs++;
            final int rate = rates.get(0);
            final int channels = maxChannels <= 0 ? 2 : Math.min(maxChannels, 2);
            final String[] depths = {DEPTH_16, DEPTH_24, DEPTH_32, DEPTH_FLOAT};
            for (String depth : depths) {
                if (configureAttempts >= MAX_CONFIGURE_ATTEMPTS
                        || System.currentTimeMillis() > bitDepthDeadlineMs) {
                    break;
                }
                int encoding = encodingForDepth(depth);
                if (encoding < 0) {
                    // 该位深在本系统版本上没有平台编码（如 API<31 的 24/32bit）→ 不尝试。
                    continue;
                }
                configureAttempts++;
                Boolean ok = tryConfigure(codecName, mime, rate, channels, encoding);
                attempts.put(depth, ok);
            }
            probedFlag[0] = !attempts.isEmpty();
            return resolveBitDepths(attempts);
        }

        @Nullable
        private Boolean tryConfigure(String codecName, String mime, int rate, int channels,
                int pcmEncoding) {
            MediaCodec codec = null;
            try {
                codec = MediaCodec.createByCodecName(codecName);
                MediaFormat format = MediaFormat.createAudioFormat(mime, rate, channels);
                format.setInteger(MediaFormat.KEY_PCM_ENCODING, pcmEncoding);
                codec.configure(format, null, null, 0);
                return Boolean.TRUE;
            } catch (MediaCodec.CodecException | IllegalArgumentException e) {
                // 参数不被接受 → 该位深不支持
                return Boolean.FALSE;
            } catch (Throwable t) {
                // 其它异常（如缺 CSD、codec 实例耗尽）：判定不了，记未确认
                return null;
            } finally {
                if (codec != null) {
                    try {
                        codec.release();
                    } catch (Throwable ignored) {
                        // ignore
                    }
                }
            }
        }

        private static int encodingForDepth(String depth) {
            switch (depth) {
                case DEPTH_16:
                    return AudioFormat.ENCODING_PCM_16BIT;
                case DEPTH_FLOAT:
                    return Build.VERSION.SDK_INT >= 21 ? AudioFormat.ENCODING_PCM_FLOAT : -1;
                case DEPTH_24:
                    // 平台只提供「24bit packed」这一种 24bit 编码（API 31+）。
                    return Build.VERSION.SDK_INT >= 31
                            ? AudioFormat.ENCODING_PCM_24BIT_PACKED : -1;
                case DEPTH_32:
                    return Build.VERSION.SDK_INT >= 31 ? AudioFormat.ENCODING_PCM_32BIT : -1;
                default:
                    return -1;
            }
        }
    }

    // ── mime → 展示名 ──────────────────────────────────────────────

    /** mime（+codecs 可空）→ UI 短名；无法识别时回退 mime 原值。 */
    public static String formatLabel(@Nullable String mime) {
        if (mime == null || mime.isEmpty()) return "未知";
        String shared = AudioOffloadCapabilities.encodingDisplayName(mime);
        if (shared != null && !shared.isEmpty() && !shared.equals(mime)) return shared;
        switch (mime) {
            case MimeTypes.AUDIO_AC3:
                return "AC3";
            case MimeTypes.AUDIO_E_AC3:
            case MimeTypes.AUDIO_E_AC3_JOC:
                return "E-AC3";
            case MimeTypes.AUDIO_AMR:
            case MimeTypes.AUDIO_AMR_NB:
            case MimeTypes.AUDIO_AMR_WB:
                return "AMR";
            case MimeTypes.AUDIO_MP4:
                return "AAC";
            case "audio/x-ape":
            case "audio/ape":
                return "APE";
            case "audio/x-dsd":
            case "audio/dsd":
                return "DSD";
            case "audio/ogg":
                return "OGG";
            default:
                return mime;
        }
    }
}
