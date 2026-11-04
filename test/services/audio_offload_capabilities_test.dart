import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_capabilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 硬件解码能力快照模型 / 缓存 / 三态判定的纯逻辑测试。
///
/// 不涉及 MethodChannel：这里只钉住「JSON 往返不丢字段」、「设备指纹与 7 天
/// 时效决定缓存可信度」以及「supportsCodec 的三态语义（绝不能把不知道谎报成
/// 不支持）」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  AudioOffloadCapability cap({
    required String name,
    required int sampleRate,
    required int channelCount,
    required bool supported,
    bool gapless = false,
    bool speedChange = false,
    int encoding = 0,
  }) {
    return AudioOffloadCapability(
      encoding: encoding,
      encodingName: name,
      sampleRate: sampleRate,
      channelCount: channelCount,
      supported: supported,
      gapless: gapless,
      speedChange: speedChange,
    );
  }

  AudioOffloadCapabilitySnapshot makeSnapshot({
    String deviceKey = 'dev-1',
    DateTime? probedAt,
    List<AudioOffloadCapability>? entries,
    String? probeError,
    List<String> notes = const <String>[],
  }) {
    return AudioOffloadCapabilitySnapshot(
      deviceKey: deviceKey,
      probedAt: probedAt ?? DateTime.now(),
      sdkInt: 33,
      variableRateSupported: true,
      outputSampleRate: 48000,
      outputFramesPerBuffer: 192,
      probeError: probeError,
      notes: notes,
      entries:
          entries ??
          <AudioOffloadCapability>[
            cap(
              name: 'audio/flac',
              sampleRate: 44100,
              channelCount: 2,
              supported: true,
              gapless: true,
            ),
            cap(
              name: 'audio/mp4a-latm',
              sampleRate: 44100,
              channelCount: 2,
              supported: true,
              speedChange: true,
            ),
            cap(
              name: 'audio/mpeg',
              sampleRate: 44100,
              channelCount: 2,
              supported: false,
            ),
          ],
    );
  }

  group('JSON 往返', () {
    test('快照经 jsonEncode/jsonDecode 后字段不丢', () {
      final snapshot = makeSnapshot(
        probedAt: DateTime(2026, 10, 1, 12, 30, 15),
        probeError: null,
      );
      final decoded = jsonDecode(jsonEncode(snapshot.toMap()));
      final restored = AudioOffloadCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(decoded as Map),
      );

      expect(restored.deviceKey, 'dev-1');
      expect(restored.probedAt, DateTime(2026, 10, 1, 12, 30, 15));
      expect(restored.sdkInt, 33);
      expect(restored.variableRateSupported, isTrue);
      expect(restored.outputSampleRate, 48000);
      expect(restored.outputFramesPerBuffer, 192);
      expect(restored.probeError, isNull);
      expect(restored.entries.length, 3);
      expect(restored.entries.first.encodingName, 'audio/flac');
      expect(restored.entries.first.gapless, isTrue);
      expect(restored.entries[1].speedChange, isTrue);
      expect(restored.probedCount, 3);
      expect(restored.supportedCount, 2);
      expect(restored.isEmpty, isFalse);
    });

    test('notes（未能探测的编码及原因）随快照往返', () {
      final snapshot = makeSnapshot(
        notes: const <String>[
          'FLAC 无对应硬解编码通路（当前播放引擎不支持该格式的 offload），未探测',
          'OPUS 需要 Android API 30+（当前 29），未探测',
        ],
      );
      final decoded = jsonDecode(jsonEncode(snapshot.toMap()));
      final restored = AudioOffloadCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(restored.notes.length, 2);
      expect(restored.notes.first, contains('FLAC'));
      expect(restored.notes[1], contains('API 30'));
      // 缺省时为空列表，UI 据此不渲染「未进入矩阵」小节。
      expect(makeSnapshot().notes, isEmpty);
    });

    test('条目按可读短名分组，编码短名覆盖源编码取值', () {
      final snapshot = makeSnapshot(
        entries: <AudioOffloadCapability>[
          cap(
            name: 'audio/flac',
            sampleRate: 48000,
            channelCount: 2,
            supported: true,
          ),
          cap(
            name: 'c2.android.mp3.decoder',
            sampleRate: 44100,
            channelCount: 2,
            supported: true,
          ),
          cap(
            name: 'mp4a.40.5',
            sampleRate: 44100,
            channelCount: 2,
            supported: true,
          ),
          cap(
            name: 'audio/eac3',
            sampleRate: 48000,
            channelCount: 6,
            supported: true,
          ),
        ],
      );
      expect(snapshot.byEncoding.keys, containsAll(<String>['FLAC', 'MP3']));
      expect(snapshot.byEncoding['HE-AAC v1']!.length, 1);
      expect(snapshot.byEncoding['E-AC3']!.length, 1);
      expect(snapshot.byEncoding['FLAC']!.single.sampleRate, 48000);
    });

    test('probeError 与原生 epoch 毫秒两处都能解析', () {
      // 原生 Snapshot.toMap() 的真实形状：probedAtMs + mime + encoding 常量。
      final restored = AudioOffloadCapabilitySnapshot.fromMap(
        <String, dynamic>{
          'deviceKey': 'dev-2',
          'probedAtMs': 1759200000000,
          'sdkInt': 29,
          'probeError': 'decoder unavailable',
          'probeCostMs': 120,
          'entries': <dynamic>[
            <String, dynamic>{
              'mime': 'audio/mp4a-latm',
              'encoding': 10,
              'encodingName': '',
              'sampleRate': 48000,
              'channelCount': 2,
              'supported': true,
              'gapless': false,
              'speedChange': false,
            },
          ],
        },
      );
      expect(restored.probeError, 'decoder unavailable');
      expect(
        restored.probedAt,
        DateTime.fromMillisecondsSinceEpoch(1759200000000),
      );
      // encodingName 为空时回退到 AudioFormat 常量名
      expect(restored.entries.single.shortName, 'AAC-LC');
    });
  });

  group('缓存 store', () {
    test('设备指纹不一致：仍返回快照但 stale', () async {
      final store = AudioOffloadCapabilityStore(currentDeviceKey: 'dev-1');
      await store.save(makeSnapshot());
      expect(store.stale, isFalse);

      final other = AudioOffloadCapabilityStore(currentDeviceKey: 'dev-2');
      final loaded = await other.load();
      expect(loaded, isNotNull);
      expect(loaded!.deviceKey, 'dev-1');
      expect(other.stale, isTrue);
      // 未拿到当前设备指纹时不校验设备（避免启动首帧误判 stale）
      final unknown = AudioOffloadCapabilityStore();
      await unknown.load();
      expect(unknown.stale, isFalse);
    });

    test('超过 7 天过期，未满 7 天可信', () async {
      final expired = AudioOffloadCapabilityStore(currentDeviceKey: 'dev-1');
      await expired.save(
        makeSnapshot(
          probedAt: DateTime.now().subtract(const Duration(days: 8)),
        ),
      );
      final loadedExpired = await expired.load();
      expect(loadedExpired, isNotNull);
      expect(expired.stale, isTrue);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fresh = AudioOffloadCapabilityStore(currentDeviceKey: 'dev-1');
      await fresh.save(
        makeSnapshot(
          probedAt: DateTime.now().subtract(const Duration(days: 6)),
        ),
      );
      await fresh.load();
      expect(fresh.stale, isFalse);
    });

    test('无缓存返回 null 且 stale', () async {
      final store = AudioOffloadCapabilityStore(currentDeviceKey: 'dev-1');
      expect(await store.load(), isNull);
      expect(store.stale, isTrue);
    });
  });

  group('supportsCodec 三态', () {
    test('支持 / 不支持 / 未探测', () {
      final snapshot = makeSnapshot();
      // 探测到支持
      expect(snapshot.supportsCodec('FLAC', 44100, 2), isTrue);
      expect(snapshot.supportsCodec('AAC', 44100, 2), isTrue);
      // 探测到不支持
      expect(snapshot.supportsCodec('MP3', 44100, 2), isFalse);
      // 采样率没探测过 → 不知道
      expect(snapshot.supportsCodec('FLAC', 96000, 2), isNull);
      // 声道数没探测过 → 不知道
      expect(snapshot.supportsCodec('FLAC', 44100, 6), isNull);
      // 编码不认识 / 传空 → 不知道
      expect(snapshot.supportsCodec('XYZ', 44100, 2), isNull);
      expect(snapshot.supportsCodec(null, 44100, 2), isNull);
      // 平台没有硬解（APE / DSD）→ 不适用（null，不是 false）
      expect(snapshot.supportsCodec('APE', 44100, 2), isNull);
      expect(snapshot.supportsCodec('DSD', 2822400, 2), isNull);
      // OGG 走 VORBIS，快照里没有该解码器 → 不知道
      expect(snapshot.supportsCodec('OGG', 44100, 2), isNull);
    });

    test('HE-AAC 变体按解码器短名区分', () {
      final snapshot = makeSnapshot(
        entries: <AudioOffloadCapability>[
          cap(
            name: 'mp4a.40.5',
            sampleRate: 44100,
            channelCount: 2,
            supported: true,
          ),
        ],
      );
      expect(snapshot.supportsCodec('AAC', 44100, 2), isTrue);
      expect(snapshot.byEncoding['HE-AAC v1']!.length, 1);
    });
  });

  group('编码短名归一', () {
    test('源编码别名归一到候选表 key', () {
      expect(normalizeSourceCodec('MP3'), 'MP3');
      expect(normalizeSourceCodec('MPEG'), 'MP3');
      expect(normalizeSourceCodec('AAC-LC'), 'AAC');
      expect(normalizeSourceCodec('OGG'), 'OGG');
      expect(normalizeSourceCodec('VORBIS'), 'OGG');
      expect(normalizeSourceCodec('E-AC3'), 'EAC3');
      expect(normalizeSourceCodec('WAVE'), 'WAV');
      expect(normalizeSourceCodec('APE'), 'APE');
      expect(normalizeSourceCodec('DSD'), 'DSD');
      expect(normalizeSourceCodec(''), '');
      expect(normalizeSourceCodec(null), '');
    });

    test('原生编码名 / MIME / 组件名归一', () {
      expect(audioCodecShortName('audio/mpeg'), 'MP3');
      expect(audioCodecShortName('audio/flac'), 'FLAC');
      expect(audioCodecShortName('c2.android.mp3.decoder'), 'MP3');
      expect(audioCodecShortName('c2.android.opus.decoder'), 'OPUS');
      expect(audioCodecShortName('audio/mp4a-latm'), 'AAC-LC');
      expect(audioCodecShortName('mp4a.40.29'), 'HE-AAC v2');
      expect(audioCodecShortName('audio/eac3'), 'E-AC3');
      expect(audioCodecShortName('audio/ac3'), 'AC3');
      expect(audioCodecShortName('', 10), 'AAC-LC');
      expect(audioCodecShortName('', 20), 'OPUS');
      expect(audioCodecShortName('', 0), '');
    });
  });
}
