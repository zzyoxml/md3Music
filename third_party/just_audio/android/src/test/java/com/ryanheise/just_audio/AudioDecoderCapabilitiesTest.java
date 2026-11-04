package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * MD3Music fork：设备解码器能力探测的纯逻辑单测。
 *
 * <p>真正枚举 {@code MediaCodecList} / 试配 {@code MediaCodec} 的部分在
 * {@link AudioDecoderCapabilities.AndroidProbe}，只能在真机验证；这里用 fake backend
 * 钉住「聚合 / 去重 / 排序 / 位深基线门控 / notes / toMap 形状」。
 */
public class AudioDecoderCapabilitiesTest {

    private static final class FakeBackend implements AudioDecoderCapabilities.ProbeBackend {
        int sdkInt = 33;
        String deviceKey = "fake|device|unit-test|android-33";
        List<AudioDecoderCapabilities.Entry> entries = new ArrayList<>();
        List<String> notes = new ArrayList<>();

        @Override
        public int sdkInt() {
            return sdkInt;
        }

        @Override
        public String deviceKey() {
            return deviceKey;
        }

        @Override
        public List<AudioDecoderCapabilities.Entry> enumerate(List<String> notesOut) {
            notesOut.addAll(notes);
            return entries;
        }
    }

    private static AudioDecoderCapabilities.Entry entry(String codec, String mime, boolean hw,
            int[] rates, int maxChannels, Map<String, String> depths, boolean probed) {
        return new AudioDecoderCapabilities.Entry(codec, mime,
                AudioDecoderCapabilities.formatLabel(mime), hw, !hw, rates, maxChannels,
                depths, probed);
    }

    /** 全 supported 的位深表（便于构造用例）。 */
    private static Map<String, String> depths(String d16, String d24, String d32, String flt) {
        Map<String, String> m = new LinkedHashMap<>();
        m.put(AudioDecoderCapabilities.DEPTH_16, d16);
        m.put(AudioDecoderCapabilities.DEPTH_24, d24);
        m.put(AudioDecoderCapabilities.DEPTH_32, d32);
        m.put(AudioDecoderCapabilities.DEPTH_FLOAT, flt);
        return m;
    }

    private static Map<String, String> allUnknown() {
        return depths(AudioDecoderCapabilities.UNKNOWN, AudioDecoderCapabilities.UNKNOWN,
                AudioDecoderCapabilities.UNKNOWN, AudioDecoderCapabilities.UNKNOWN);
    }

    // ── 位深基线门控 ────────────────────────────────────────────────

    @Test
    public void 位深_16bit基线成功时逐项判定() {
        Map<String, Boolean> attempts = new LinkedHashMap<>();
        attempts.put(AudioDecoderCapabilities.DEPTH_16, true);
        attempts.put(AudioDecoderCapabilities.DEPTH_24, false);
        attempts.put(AudioDecoderCapabilities.DEPTH_FLOAT, true);

        Map<String, String> resolved = AudioDecoderCapabilities.resolveBitDepths(attempts);

        assertEquals(AudioDecoderCapabilities.SUPPORTED,
                resolved.get(AudioDecoderCapabilities.DEPTH_16));
        assertEquals(AudioDecoderCapabilities.UNSUPPORTED,
                resolved.get(AudioDecoderCapabilities.DEPTH_24));
        assertEquals(AudioDecoderCapabilities.SUPPORTED,
                resolved.get(AudioDecoderCapabilities.DEPTH_FLOAT));
        // 没尝试的位深不能当成不支持
        assertEquals(AudioDecoderCapabilities.UNKNOWN,
                resolved.get(AudioDecoderCapabilities.DEPTH_32));
        assertEquals(4, resolved.size());
    }

    @Test
    public void 位深_16bit基线失败时全部记未知() {
        Map<String, Boolean> attempts = new LinkedHashMap<>();
        attempts.put(AudioDecoderCapabilities.DEPTH_16, false);
        attempts.put(AudioDecoderCapabilities.DEPTH_24, true);
        attempts.put(AudioDecoderCapabilities.DEPTH_32, true);

        Map<String, String> resolved = AudioDecoderCapabilities.resolveBitDepths(attempts);

        for (String value : resolved.values()) {
            assertEquals("16bit 配不起来说明是 CSD/参数问题，不能据此判位深",
                    AudioDecoderCapabilities.UNKNOWN, value);
        }
    }

    @Test
    public void 位深_全未尝试时全部未知() {
        Map<String, String> resolved = AudioDecoderCapabilities.resolveBitDepths(
                new LinkedHashMap<String, Boolean>());
        assertEquals(4, resolved.size());
        for (String value : resolved.values()) {
            assertEquals(AudioDecoderCapabilities.UNKNOWN, value);
        }
    }

    // ── 聚合 / 排序 / notes ────────────────────────────────────────

    @Test
    public void 聚合_按硬件优先排序且去重() {
        FakeBackend backend = new FakeBackend();
        backend.entries.add(entry("c2.android.mp3.decoder", "audio/mpeg", false,
                new int[]{44100}, 2, allUnknown(), false));
        backend.entries.add(entry("c2.qti.mp3.decoder", "audio/mpeg", true,
                new int[]{44100, 48000}, 2,
                depths(AudioDecoderCapabilities.SUPPORTED, AudioDecoderCapabilities.UNSUPPORTED,
                        AudioDecoderCapabilities.UNKNOWN, AudioDecoderCapabilities.UNKNOWN),
                true));
        // 重复上报（个别 ROM）只留一条
        backend.entries.add(entry("c2.qti.mp3.decoder", "audio/mpeg", true,
                new int[]{44100, 48000}, 2, allUnknown(), true));

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        assertEquals(2, snapshot.entries.size());
        assertTrue("硬件解码器排在最前", snapshot.entries.get(0).isHardware());
        assertEquals("c2.qti.mp3.decoder", snapshot.entries.get(0).codecName);
        assertEquals(1, snapshot.hardwareCodecCount());
        assertEquals(1, snapshot.supportedFormatCount());
        assertNull(snapshot.probeError);
    }

    @Test
    public void 聚合_只有软解解码器的编码写入notes() {
        FakeBackend backend = new FakeBackend();
        backend.entries.add(entry("c2.android.mp3.decoder", "audio/mpeg", false,
                new int[]{44100}, 2, allUnknown(), false));

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        boolean hasSoftOnlyNote = false;
        for (String note : snapshot.notes) {
            if (note.contains("MP3") && note.contains("只有软件解码器")) hasSoftOnlyNote = true;
        }
        assertTrue("应提示该编码只有软解: " + snapshot.notes, hasSoftOnlyNote);
        assertEquals(0, snapshot.hardwareCodecCount());
    }

    @Test
    public void 聚合_位深被跳过时追加未实测说明() {
        FakeBackend backend = new FakeBackend();
        backend.entries.add(entry("c2.qti.flac.decoder", "audio/flac", true,
                new int[]{44100, 96000}, 2, allUnknown(), false));

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        boolean hasSkipNote = false;
        for (String note : snapshot.notes) {
            if (note.contains("位深未实测")) hasSkipNote = true;
        }
        assertTrue("应提示位深未实测: " + snapshot.notes, hasSkipNote);
    }

    @Test
    public void 聚合_后端notes原样保留() {
        FakeBackend backend = new FakeBackend();
        backend.notes.add("APE 无系统解码器，只能软解");
        backend.entries.add(entry("c2.qti.mp3.decoder", "audio/mpeg", true,
                new int[]{44100}, 2, allUnknown(), true));

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        assertTrue(snapshot.notes.contains("APE 无系统解码器，只能软解"));
    }

    @Test
    public void 聚合_空结果给出明确错误() {
        FakeBackend backend = new FakeBackend();

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        assertTrue(snapshot.isEmpty());
        assertNotNull(snapshot.probeError);
        assertTrue(snapshot.probeError.contains("解码器"));
    }

    @Test
    public void 聚合_后端异常不抛出而是转成probeError() {
        AudioDecoderCapabilities.ProbeBackend broken = new AudioDecoderCapabilities.ProbeBackend() {
            @Override
            public int sdkInt() {
                return 33;
            }

            @Override
            public String deviceKey() {
                return "fake";
            }

            @Override
            public List<AudioDecoderCapabilities.Entry> enumerate(List<String> notesOut) {
                throw new IllegalStateException("MediaCodecList 被 ROM 拒绝");
            }
        };

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(broken);

        assertTrue(snapshot.isEmpty());
        assertNotNull(snapshot.probeError);
        assertTrue(snapshot.probeError.contains("枚举失败"));
    }

    // ── toMap 形状（Dart 侧契约） ───────────────────────────────────

    @Test
    public void toMap字段齐备且可被消息通道直传() {
        FakeBackend backend = new FakeBackend();
        backend.entries.add(entry("c2.qti.mp3.decoder", "audio/mpeg", true,
                new int[]{44100, 48000}, 2,
                depths(AudioDecoderCapabilities.SUPPORTED, AudioDecoderCapabilities.UNSUPPORTED,
                        AudioDecoderCapabilities.UNKNOWN, AudioDecoderCapabilities.UNKNOWN),
                true));

        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);
        Map<String, Object> map = snapshot.toMap();

        assertEquals("fake|device|unit-test|android-33", map.get("deviceKey"));
        assertEquals(33, map.get("sdkInt"));
        assertNotNull(map.get("probedAtMs"));
        assertNotNull(map.get("probeCostMs"));
        assertNull(map.get("probeError"));
        assertTrue(map.get("entries") instanceof List);
        assertTrue(map.get("notes") instanceof List);

        @SuppressWarnings("unchecked")
        Map<String, Object> e = (Map<String, Object>)
                ((List<?>) map.get("entries")).get(0);
        assertEquals("c2.qti.mp3.decoder", e.get("codecName"));
        assertEquals("audio/mpeg", e.get("mime"));
        assertEquals("MP3", e.get("formatLabel"));
        assertEquals(Boolean.TRUE, e.get("hardware"));
        assertEquals(Boolean.FALSE, e.get("softwareOnly"));
        assertEquals(Boolean.TRUE, e.get("bitDepthProbed"));
        assertEquals(2, e.get("maxChannels"));
        assertEquals(Arrays.asList(44100, 48000), e.get("sampleRates"));
        @SuppressWarnings("unchecked")
        Map<String, Object> depths = (Map<String, Object>) e.get("bitDepths");
        assertEquals("supported", depths.get("16"));
        assertEquals("unsupported", depths.get("24"));
        assertEquals("unknown", depths.get("32"));
        assertEquals("unknown", depths.get("float"));
    }

    // ── mime → 展示名 ──────────────────────────────────────────────

    @Test
    public void 格式短名覆盖常见音频mime() {
        assertEquals("MP3", AudioDecoderCapabilities.formatLabel("audio/mpeg"));
        assertEquals("AAC", AudioDecoderCapabilities.formatLabel("audio/mp4a-latm"));
        assertEquals("FLAC", AudioDecoderCapabilities.formatLabel("audio/flac"));
        assertEquals("OPUS", AudioDecoderCapabilities.formatLabel("audio/opus"));
        assertEquals("AC3", AudioDecoderCapabilities.formatLabel("audio/ac3"));
        assertEquals("E-AC3", AudioDecoderCapabilities.formatLabel("audio/eac3"));
        assertEquals("APE", AudioDecoderCapabilities.formatLabel("audio/x-ape"));
        assertEquals("DSD", AudioDecoderCapabilities.formatLabel("audio/dsd"));
        // 未知 mime 原样返回，便于排查
        assertEquals("audio/unknown-thing",
                AudioDecoderCapabilities.formatLabel("audio/unknown-thing"));
    }

    @Test
    public void 快照存取幂等() {
        FakeBackend backend = new FakeBackend();
        backend.entries.add(entry("c2.qti.mp3.decoder", "audio/mpeg", true,
                new int[]{44100}, 2, allUnknown(), true));
        AudioDecoderCapabilities.Snapshot snapshot = AudioDecoderCapabilities.probe(backend);

        AudioDecoderCapabilities.setSnapshot(snapshot);
        assertEquals(snapshot, AudioDecoderCapabilities.snapshot());

        AudioDecoderCapabilities.setSnapshot(null);
        assertNull(AudioDecoderCapabilities.snapshot());

        // 软硬件标记：hardware=true 但 softwareOnly=true（个别 ROM 的灰色地带）不算硬解
        AudioDecoderCapabilities.Entry both = new AudioDecoderCapabilities.Entry(
                "x", "audio/mpeg", "MP3", true, true, new int[]{44100}, 2, allUnknown(), false);
        assertEquals("x", both.codecName);
        assertFalse("softwareOnly 时不应计入硬解", both.isHardware());
    }
}
