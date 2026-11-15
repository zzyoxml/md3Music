package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.Format;

import org.junit.Test;

import java.util.HashSet;
import java.util.Set;

/**
 * MD3Music fork：设备硬解能力探测的纯逻辑单测。
 *
 * <p>不依赖 Android 运行时：探测主逻辑只通过 {@link AudioOffloadCapabilities.ProbeBackend}
 * 访问能力，这里注入 fake 后端，把「矩阵覆盖 / API 门槛 / 单点异常隔离 / 三态判定」钉住。
 * 真正调用 {@code AudioManager} 的 {@code AndroidProbe} 只能在真机验证。
 */
public class AudioOffloadCapabilitiesTest {

    /** 可编程的 fake 后端：默认全部不支持，按需声明支持项。 */
    private static final class FakeBackend implements AudioOffloadCapabilities.ProbeBackend {
        /**
         * media3 1.4.1 的 {@code C} 里没有 FLAC 编码常量（FLAC offload 是更高版本才有），
         * 这里用一个任意值代表「后端认识 audio/flac」，只为验证矩阵逻辑本身。
         */
        static final int FAKE_FLAC_ENCODING = 0x0F1AC;

        int sdkInt = 33;
        boolean variableRate = false;
        int outputSampleRate = 48000;
        int outputFrames = 192;
        final Set<String> supported2 = new HashSet<>(); // gapless（返回值 2）
        final Set<String> supported1 = new HashSet<>(); // 支持但无 gapless（返回值 1）
        boolean throwOnProbe = false;

        private static String key(int encoding, int rate, int ch) {
            return encoding + "|" + rate + "|" + ch;
        }

        void support(int encoding, int rate, int ch, boolean gapless) {
            (gapless ? supported2 : supported1).add(key(encoding, rate, ch));
        }

        @Override
        public int sdkInt() {
            return sdkInt;
        }

        @Override
        public String deviceKey() {
            return "fake|device|unit-test|android-33";
        }

        @Override
        public int outputSampleRate() {
            return outputSampleRate;
        }

        @Override
        public int outputFramesPerBuffer() {
            return outputFrames;
        }

        @Override
        public boolean variableRateSupported() {
            return variableRate;
        }

        @Override
        public int probe(int encoding, int sampleRate, int channelCount) {
            if (throwOnProbe) throw new IllegalStateException("binder 挂了");
            if (supported2.contains(key(encoding, sampleRate, channelCount))) return 2;
            if (supported1.contains(key(encoding, sampleRate, channelCount))) return 1;
            return 0;
        }

        @Override
        public int encodingForMime(String mime) {
            switch (mime) {
                case "audio/mpeg":
                    return C.ENCODING_MP3;
                case "audio/mp4a-latm":
                    return C.ENCODING_AAC_LC;
                case "audio/flac":
                    return FAKE_FLAC_ENCODING;
                case "audio/opus":
                    return C.ENCODING_OPUS;
                default:
                    return C.ENCODING_INVALID;
            }
        }
    }

    @Test
    public void api29以下给出明确错误且矩阵为空() {
        FakeBackend backend = new FakeBackend();
        backend.sdkInt = 26;

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertEquals(26, snapshot.sdkInt);
        assertTrue(snapshot.isEmpty());
        assertNotNull(snapshot.probeError);
        assertTrue(snapshot.probeError.contains("29"));
        assertEquals(0, snapshot.supportedCount());
    }

    @Test
    public void 支持的组合被标记且gapless与变速能力正确() {
        FakeBackend backend = new FakeBackend();
        backend.variableRate = true;
        // MP3 44.1k 双声道：API31+ 报 gapless；AAC 48k 双声道：支持但无 gapless。
        backend.support(C.ENCODING_MP3, 44100, 2, true);
        backend.support(C.ENCODING_AAC_LC, 48000, 2, false);

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertNull(snapshot.probeError);
        AudioOffloadCapabilities.Entry mp3 =
                snapshot.lookup(C.ENCODING_MP3, 44100, 2);
        assertNotNull(mp3);
        assertTrue(mp3.supported);
        assertTrue(mp3.gapless);
        assertTrue("设备支持变速时，支持的组合应带上变速能力", mp3.speedChange);
        assertEquals("MP3", mp3.encodingName);

        AudioOffloadCapabilities.Entry aac =
                snapshot.lookup(C.ENCODING_AAC_LC, 48000, 2);
        assertNotNull(aac);
        assertTrue(aac.supported);
        assertFalse(aac.gapless);

        // 未声明的组合必须是不支持（不能"默认放行"）。
        AudioOffloadCapabilities.Entry unsupported =
                snapshot.lookup(C.ENCODING_MP3, 48000, 2);
        assertNotNull(unsupported);
        assertFalse(unsupported.supported);
        assertEquals(2, snapshot.supportedCount());
    }

    @Test
    public void 设备不支持变速时组合不应带宽能力() {
        FakeBackend backend = new FakeBackend();
        backend.variableRate = false;
        backend.support(C.ENCODING_MP3, 48000, 2, false);

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        AudioOffloadCapabilities.Entry entry = snapshot.lookup(C.ENCODING_MP3, 48000, 2);
        assertNotNull(entry);
        assertTrue(entry.supported);
        assertFalse(entry.speedChange);
    }

    @Test
    public void 低于编码引入版本的候选被跳过() {
        FakeBackend backend = new FakeBackend();
        backend.sdkInt = 29; // OPUS 需要 API 30，ALAC 需要 API 31
        backend.support(C.ENCODING_OPUS, 48000, 2, false);

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertNull(snapshot.lookup(C.ENCODING_OPUS, 48000, 2));
        // MP3/AAC/FLAC（API21+）仍在矩阵里
        assertNotNull(snapshot.lookup(C.ENCODING_MP3, 48000, 2));
        assertNotNull(snapshot.lookup(FakeBackend.FAKE_FLAC_ENCODING, 48000, 2));
    }

    /**
     * 诊断用：打印 media3 1.4.1 对各候选 mime 的编码折算结果。
     *
     * <p>探测矩阵用 {@code MimeTypes.getEncoding} 折算编码，折算失败的 mime 会被跳过
     * （例如 media3 1.4.1 没有 FLAC/ALAC/VORBIS 的 offload 通路）。本用例只打印不断言，
     * 真机版本升级后可用它快速核对「哪些格式进入了探测矩阵」。
     */
    @Test
    public void 打印候选mime的编码折算结果() {
        String[] mimes = {
            "audio/mpeg", "audio/mp4a-latm", "audio/flac", "audio/opus",
            "audio/vorbis", "audio/alac", "audio/ac3", "audio/eac3",
        };
        for (String mime : mimes) {
            int encoding;
            try {
                encoding = androidx.media3.common.MimeTypes.getEncoding(mime, null);
            } catch (Throwable t) {
                encoding = C.ENCODING_INVALID;
            }
            System.out.println("[AudioOffload] mime=" + mime + " encoding=" + encoding);
        }
    }

    @Test
    public void 无法折算编码的候选被跳过() {
        FakeBackend backend = new FakeBackend();
        // audio/vorbis / audio/ac3 / audio/eac3 在 fake 里返回 INVALID → 不进行探测
        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);
        assertEquals(0, snapshot.supportedCount());
        assertTrue(snapshot.probedCount() > 0);
    }

    @Test
    public void AAC家族回退到AAC_LC条目() {
        FakeBackend backend = new FakeBackend();
        // 只探测 AAC_LC（探测矩阵口径）：HE-AAC 曲目应回退到 LC 的协商结果，
        // 否则低码率 AAC（酷狗常见 HE-AAC）会因「没探测过该编码」永久回落软解。
        backend.support(C.ENCODING_AAC_LC, 44100, 2, false);
        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);
        AudioOffloadCapabilities.setSnapshot(snapshot);

        assertNull("精确编码确实没有条目",
                snapshot.lookup(C.ENCODING_AAC_HE_V1, 44100, 2));
        assertNotNull("回退后应命中 LC 条目",
                AudioOffloadCapabilities.lookupWithFallback(
                        snapshot, C.ENCODING_AAC_HE_V1, 44100, 2));

        // 端到端：HE-AAC 格式（mp4a.40.5）也应判定为可硬解。
        assertEquals(Boolean.TRUE, AudioOffloadCapabilities.isFormatSupported(
                "audio/mp4a-latm", "mp4a.40.5", 44100, 2));

        AudioOffloadCapabilities.setSnapshot(null);
    }

    @Test
    public void 单点探测抛异常只算不支持不影响整体() {
        FakeBackend backend = new FakeBackend();
        backend.throwOnProbe = true;

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertNull(snapshot.probeError);
        assertTrue(snapshot.probedCount() > 0);
        assertEquals(0, snapshot.supportedCount());
    }

    @Test
    public void 快照toMap包含UI需要的全部字段() {
        FakeBackend backend = new FakeBackend();
        backend.support(C.ENCODING_MP3, 44100, 2, false);

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);
        java.util.Map<String, Object> map = snapshot.toMap();

        assertEquals("fake|device|unit-test|android-33", map.get("deviceKey"));
        assertEquals(33, map.get("sdkInt"));
        assertEquals(48000, map.get("outputSampleRate"));
        assertEquals(192, map.get("outputFramesPerBuffer"));
        assertNotNull(map.get("entries"));
        assertTrue(map.get("entries") instanceof java.util.List);
        // 矩阵包含「探测过但不支持」的组合，所以条数远大于支持数；逐个找支持项断言。
        java.util.List<?> entries = (java.util.List<?>) map.get("entries");
        assertTrue(entries.size() > 1);
        java.util.Map<String, Object> supportedEntry = null;
        for (Object raw : entries) {
            @SuppressWarnings("unchecked")
            java.util.Map<String, Object> e = (java.util.Map<String, Object>) raw;
            if (Boolean.TRUE.equals(e.get("supported"))) {
                supportedEntry = e;
                break;
            }
        }
        assertNotNull("应存在一条支持项", supportedEntry);
        assertEquals("audio/mpeg", supportedEntry.get("mime"));
        assertEquals(C.ENCODING_MP3, supportedEntry.get("encoding"));
        assertEquals(44100, supportedEntry.get("sampleRate"));
        assertEquals(2, supportedEntry.get("channelCount"));
        assertEquals(Boolean.TRUE, supportedEntry.get("supported"));
        // notes 必须存在（UI 用它展示「哪些编码没进矩阵」）
        assertNotNull(map.get("notes"));
        assertTrue(map.get("notes") instanceof java.util.List);
    }

    @Test
    public void 未能折算编码的候选记入notes() {
        FakeBackend backend = new FakeBackend();
        // fake 只认 mpeg / mp4a / flac / opus；vorbis 与 alac、ac3、eac3 折算失败
        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertFalse(snapshot.notes.isEmpty());
        boolean hasUnavailable = false;
        for (String note : snapshot.notes) {
            if (note.contains("VORBIS") && note.contains("硬解编码通路")) {
                hasUnavailable = true;
            }
        }
        assertTrue("应记录 VORBIS 无硬解编码通路: " + snapshot.notes, hasUnavailable);
    }

    @Test
    public void 原生输出率被并入候选采样率() {
        FakeBackend backend = new FakeBackend();
        backend.outputSampleRate = 32000; // 非默认候选集合内的率

        AudioOffloadCapabilities.Snapshot snapshot = AudioOffloadCapabilities.probe(backend);

        assertNotNull("设备原生 32k 也应被探测", snapshot.lookup(C.ENCODING_MP3, 32000, 2));
    }

    @Test
    public void 未就绪时格式判定返回未知() {
        AudioOffloadCapabilities.setSnapshot(null);
        assertNull(AudioOffloadCapabilities.isFormatSupported(
                "audio/mpeg", null, 44100, 2));
    }

    @Test
    public void 就绪后格式判定给出三态() {
        FakeBackend backend = new FakeBackend();
        backend.support(C.ENCODING_MP3, 44100, 2, false);
        AudioOffloadCapabilities.setSnapshot(AudioOffloadCapabilities.probe(backend));

        assertEquals(Boolean.TRUE, AudioOffloadCapabilities.isFormatSupported(
                "audio/mpeg", null, 44100, 2));
        assertEquals(Boolean.FALSE, AudioOffloadCapabilities.isFormatSupported(
                "audio/mpeg", null, 96000, 2));
        // 折算不出平台编码的格式 = 明确不可硬解（false，而不是「未知」）：
        // media3 1.4.1 没有 ALAC 的 offload 编码映射，这种格式永远进不了 offload。
        assertEquals(Boolean.FALSE, AudioOffloadCapabilities.isFormatSupported(
                "audio/alac", null, 44100, 2));

        AudioOffloadCapabilities.setSnapshot(null);
    }

    @Test
    public void 格式描述用于状态展示() {
        Format mp3 = new Format.Builder()
                .setSampleMimeType("audio/mpeg")
                .setSampleRate(44100)
                .setChannelCount(2)
                .build();
        assertEquals("MP3 44100Hz 2ch", AudioOffloadCapabilities.describeFormat(mp3));

        Format pcm = new Format.Builder()
                .setSampleMimeType("audio/raw")
                .setSampleRate(48000)
                .setChannelCount(2)
                .build();
        assertEquals("PCM 48000Hz 2ch", AudioOffloadCapabilities.describeFormat(pcm));
    }
}
