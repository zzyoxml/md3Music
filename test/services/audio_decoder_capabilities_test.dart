import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_decoder_capabilities.dart';
import 'package:md3music/core/services/audio_offload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备解码器能力（MediaCodec 枚举）模型 / 缓存 / 服务接线的纯逻辑测试。
///
/// 钉住四类最容易回归的事：
/// 1. 原生快照 map ↔ 模型往返不丢字段（`probedAtMs` 与 `probedAt` 都认）；
/// 2. 位深三态（`supported` / `unsupported` / `unknown`）绝不塌成两态；
/// 3. 按 `formatLabel` 聚合的「硬件优先并集 + 无硬件退回 + 位深取优 + 固定排序」；
/// 4. 缓存可信度（设备指纹 / 7 天）与 `predictDecoderSupported` 的三态语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // ── 测试夹具 ───────────────────────────────────────────────────

  AudioDecoderCapability cap({
    String codecName = 'c2.qti.mp3.decoder',
    String mime = 'audio/mpeg',
    String formatLabel = 'MP3',
    bool hardware = true,
    bool softwareOnly = false,
    List<int> sampleRates = const <int>[44100, 48000],
    int maxChannels = 2,
    Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths =
        const <DecoderBitDepth, DecoderBitDepthSupport>{
          DecoderBitDepth.bit16: DecoderBitDepthSupport.supported,
          DecoderBitDepth.bit24: DecoderBitDepthSupport.unknown,
        },
    bool bitDepthProbed = true,
  }) {
    return AudioDecoderCapability(
      codecName: codecName,
      mime: mime,
      formatLabel: formatLabel,
      hardware: hardware,
      softwareOnly: softwareOnly,
      sampleRates: sampleRates,
      maxChannels: maxChannels,
      bitDepths: bitDepths,
      bitDepthProbed: bitDepthProbed,
    );
  }

  AudioDecoderCapabilitySnapshot makeSnapshot({
    String deviceKey = 'dev-1',
    DateTime? probedAt,
    List<AudioDecoderCapability>? entries,
    String? probeError,
    List<String> notes = const <String>[],
  }) {
    return AudioDecoderCapabilitySnapshot(
      deviceKey: deviceKey,
      probedAt: probedAt ?? DateTime.now(),
      sdkInt: 34,
      probeCostMs: 12,
      probeError: probeError,
      notes: notes,
      entries:
          entries ??
          <AudioDecoderCapability>[
            cap(codecName: 'c2.android.mp3.decoder', formatLabel: 'MP3'),
            cap(
              codecName: 'c2.android.flac.decoder',
              mime: 'audio/flac',
              formatLabel: 'FLAC',
              sampleRates: const <int>[96000],
            ),
          ],
    );
  }

  /// 契约里的原生快照形状（键名固定，见需求文档）。
  Map<String, dynamic> nativeSnapshotMap() {
    return <String, dynamic>{
      'deviceKey': 'xiaomi|23127PN0CC|fuxi|android-34',
      'probedAtMs': 1759200000000,
      'sdkInt': 34,
      'probeCostMs': 18,
      'probeError': null,
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'codecName': 'c2.qti.mp3.decoder',
          'mime': 'audio/mpeg',
          'formatLabel': 'MP3',
          'hardware': true,
          'softwareOnly': false,
          'sampleRates': <int>[48000, 44100, 44100],
          'maxChannels': 2,
          'bitDepths': <String, String>{
            '16': 'supported',
            '24': 'unsupported',
            '32': 'unknown',
            'float': 'unknown',
          },
          'bitDepthProbed': true,
        },
      ],
      'notes': <String>['APE 无系统解码器，只能软解'],
    };
  }

  // ── 模型与 JSON 往返 ───────────────────────────────────────────

  group('原生快照解析与 JSON 往返', () {
    test('字段不丢：deviceKey / probedAtMs / sdkInt / probeCostMs / notes', () {
      final snap = AudioDecoderCapabilitySnapshot.fromMap(nativeSnapshotMap());

      expect(snap.deviceKey, 'xiaomi|23127PN0CC|fuxi|android-34');
      expect(snap.probedAt, DateTime.fromMillisecondsSinceEpoch(1759200000000));
      expect(snap.sdkInt, 34);
      expect(snap.probeCostMs, 18);
      expect(snap.probeError, isNull);
      expect(snap.notes, <String>['APE 无系统解码器，只能软解']);
      expect(snap.isEmpty, isFalse);

      final entry = snap.entries.single;
      expect(entry.codecName, 'c2.qti.mp3.decoder');
      expect(entry.mime, 'audio/mpeg');
      expect(entry.formatLabel, 'MP3');
      expect(entry.isHardware, isTrue);
      expect(entry.bitDepthProbed, isTrue);
      // 采样率升序 + 去重
      expect(entry.sampleRates, <int>[44100, 48000]);
      expect(entry.maxChannels, 2);
      expect(entry.bitDepth(DecoderBitDepth.bit16), DecoderBitDepthSupport.supported);
      expect(
        entry.bitDepth(DecoderBitDepth.bit24),
        DecoderBitDepthSupport.unsupported,
      );
    });

    test('缓存往返：toMap 写 ISO8601，jsonEncode 后复读等价', () {
      final snap = AudioDecoderCapabilitySnapshot.fromMap(nativeSnapshotMap());
      final map = snap.toMap();

      // 缓存契约：probedAt 是 ISO 8601 字符串（不是 epoch 数字）
      expect(map['probedAt'], isA<String>());
      expect(map['probedAt'], snap.probedAt.toIso8601String());
      expect(map['probeCostMs'], 18);

      final decoded = jsonDecode(jsonEncode(map));
      final restored = AudioDecoderCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(restored.deviceKey, snap.deviceKey);
      expect(restored.probedAt, snap.probedAt);
      expect(restored.sdkInt, snap.sdkInt);
      expect(restored.probeCostMs, snap.probeCostMs);
      expect(restored.notes, snap.notes);
      expect(restored.entries.single.toMap(), snap.entries.single.toMap());
      expect(
        restored.entries.single.bitDepths,
        snap.entries.single.bitDepths,
      );
    });

    test('probeError 与 notes：空白项剔除，错误文案保留', () {
      final raw = nativeSnapshotMap()
        ..['probeError'] = 'MediaCodec 列表为空'
        ..['notes'] = <String>['  ', '定点探测超时', ''];
      final snap = AudioDecoderCapabilitySnapshot.fromMap(raw);
      expect(snap.probeError, 'MediaCodec 列表为空');
      expect(snap.notes, <String>['定点探测超时']);
      expect(snap.toMap()['probeError'], 'MediaCodec 列表为空');
      // 空串 error 视同没有错误
      expect(
        AudioDecoderCapabilitySnapshot.fromMap(
          nativeSnapshotMap()..['probeError'] = '',
        ).probeError,
        isNull,
      );
    });
  });

  group('位深三态解析', () {
    test('缺失键与未知键都归 unknown，不谎报不支持', () {
      final entry = AudioDecoderCapability.fromMap(<String, dynamic>{
        'codecName': 'c2.android.mp3.decoder',
        'formatLabel': 'MP3',
        'sampleRates': <int>[44100],
        'bitDepths': <String, dynamic>{
          '16': 'supported',
          '24': 'unsupported',
          // 32 缺失；"20" 是原生将来可能新增的档位 → 忽略
          '20': 'supported',
        },
      });

      expect(entry.bitDepth(DecoderBitDepth.bit16), DecoderBitDepthSupport.supported);
      expect(
        entry.bitDepth(DecoderBitDepth.bit24),
        DecoderBitDepthSupport.unsupported,
      );
      expect(entry.bitDepth(DecoderBitDepth.bit32), DecoderBitDepthSupport.unknown);
      expect(entry.bitDepth(DecoderBitDepth.float), DecoderBitDepthSupport.unknown);
      expect(entry.bitDepths.containsKey(DecoderBitDepth.bit32), isFalse);
      expect(entry.bitDepths.length, 2);

      // 写回时四个档位补齐（缺项 unknown），未知键不落盘
      final depths = Map<String, String>.from(
        entry.toMap()['bitDepths'] as Map,
      );
      expect(depths, <String, String>{
        '16': 'supported',
        '24': 'unsupported',
        '32': 'unknown',
        'float': 'unknown',
      });
    });

    test('缺省字段与非法值容错：负声道归 0、非正采样率剔除', () {
      final empty = AudioDecoderCapability.fromMap(<String, dynamic>{});
      expect(empty.codecName, isEmpty);
      expect(empty.sampleRates, isEmpty);
      expect(empty.maxChannels, 0);
      expect(empty.isHardware, isFalse);
      expect(empty.bitDepthProbed, isFalse);

      final messy = AudioDecoderCapability.fromMap(<String, dynamic>{
        'sampleRates': <dynamic>[0, -1, 44100, '48000', 44100],
        'maxChannels': -3,
        // hardware + softwareOnly 同时为真 → 按软解处理
        'hardware': true,
        'softwareOnly': true,
      });
      expect(messy.sampleRates, <int>[44100, 48000]);
      expect(messy.maxChannels, 0);
      expect(messy.isHardware, isFalse);
    });
  });

  group('按 formatLabel 聚合', () {
    test('硬件优先：采样率 / 声道 / 位深只取硬件解码器的并集', () {
      final snap = makeSnapshot(
        entries: <AudioDecoderCapability>[
          cap(
            codecName: 'c2.qti.mp3.decoder',
            sampleRates: const <int>[44100],
            maxChannels: 2,
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.unknown,
            },
          ),
          cap(
            codecName: 'c2.android.mp3.decoder',
            hardware: false,
            softwareOnly: true,
            sampleRates: const <int>[48000, 96000],
            maxChannels: 8,
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit32: DecoderBitDepthSupport.supported,
            },
          ),
        ],
      );

      final format = snap.byFormat['MP3']!;
      expect(format.hasHardware, isTrue);
      expect(format.codecNames, <String>['c2.qti.mp3.decoder']);
      expect(format.sampleRates, <int>[44100]);
      expect(format.maxChannels, 2);
      expect(
        format.bitDepths[DecoderBitDepth.bit24],
        DecoderBitDepthSupport.unknown,
        reason: '软解条目的 24bit 支持不能算进硬件并集',
      );
      expect(
        format.bitDepths[DecoderBitDepth.bit32],
        DecoderBitDepthSupport.unknown,
      );
      expect(snap.hardwareCodecCount, 1);
      expect(snap.supportedFormatCount, 1);
    });

    test('无硬件解码器：退回全部条目并置 hasHardware=false', () {
      final snap = makeSnapshot(
        entries: <AudioDecoderCapability>[
          cap(
            codecName: 'c2.android.flac.decoder',
            mime: 'audio/flac',
            formatLabel: 'FLAC',
            hardware: false,
            softwareOnly: true,
            sampleRates: const <int>[44100],
            maxChannels: 2,
          ),
          cap(
            codecName: 'c2.android.flac.decoder.alt',
            mime: 'audio/flac',
            formatLabel: 'FLAC',
            hardware: false,
            softwareOnly: true,
            sampleRates: const <int>[96000],
            maxChannels: 6,
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.supported,
            },
          ),
        ],
      );

      final format = snap.byFormat['FLAC']!;
      expect(format.hasHardware, isFalse, reason: '只有软解时不能假装有硬件');
      expect(format.codecNames.length, 2, reason: '退回全部条目，UI 才能显示软解来源');
      expect(format.sampleRates, <int>[44100, 96000]);
      expect(format.maxChannels, 6);
      expect(
        format.bitDepths[DecoderBitDepth.bit24],
        DecoderBitDepthSupport.supported,
      );
      expect(format.mime, 'audio/flac');
      expect(snap.hardwareCodecCount, 0);
      expect(snap.supportedFormatCount, 0);
    });

    test('位深逐档取优：supported > unknown > unsupported', () {
      final snap = makeSnapshot(
        entries: <AudioDecoderCapability>[
          cap(
            codecName: 'a',
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.unknown,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.unsupported,
              DecoderBitDepth.bit32: DecoderBitDepthSupport.unsupported,
              DecoderBitDepth.float: DecoderBitDepthSupport.unsupported,
            },
          ),
          cap(
            codecName: 'b',
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.unknown,
              DecoderBitDepth.bit32: DecoderBitDepthSupport.unknown,
              DecoderBitDepth.float: DecoderBitDepthSupport.unsupported,
            },
          ),
          cap(
            codecName: 'c',
            bitDepths: const <DecoderBitDepth, DecoderBitDepthSupport>{
              DecoderBitDepth.bit16: DecoderBitDepthSupport.unsupported,
              DecoderBitDepth.bit24: DecoderBitDepthSupport.supported,
              DecoderBitDepth.bit32: DecoderBitDepthSupport.unsupported,
              DecoderBitDepth.float: DecoderBitDepthSupport.unsupported,
            },
          ),
        ],
      );

      final depths = snap.byFormat['MP3']!.bitDepths;
      expect(depths[DecoderBitDepth.bit16], DecoderBitDepthSupport.supported);
      expect(depths[DecoderBitDepth.bit24], DecoderBitDepthSupport.supported);
      expect(
        depths[DecoderBitDepth.bit32],
        DecoderBitDepthSupport.unknown,
        reason: 'unknown 优于 unsupported',
      );
      expect(
        depths[DecoderBitDepth.float],
        DecoderBitDepthSupport.unsupported,
      );
    });

    test('空白 formatLabel 归到「未知」，空快照各项计数为 0', () {
      final snap = makeSnapshot(
        entries: <AudioDecoderCapability>[cap(codecName: 'x', formatLabel: '  ')],
      );
      expect(snap.byFormat.keys.single, '未知');
      expect(snap.supportedFormatCount, 1);

      final empty = AudioDecoderCapabilitySnapshot(
        deviceKey: '',
        probedAt: DateTime.fromMillisecondsSinceEpoch(0),
        sdkInt: 0,
        entries: const <AudioDecoderCapability>[],
      );
      expect(empty.isEmpty, isTrue);
      expect(empty.byFormat, isEmpty);
      expect(empty.hardwareCodecCount, 0);
      expect(empty.supportedFormatCount, 0);
    });
  });

  group('byFormat 排序与编码归一', () {
    /// 固定顺序：MP3 → AAC → HE-AAC → FLAC → ALAC → OPUS → VORBIS → AC3 →
    /// E-AC3 → 其它（按字母）。
    test('已知编码按固定顺序，其它按字母序排在最后', () {
      final snap = makeSnapshot(
        entries: List<AudioDecoderCapability>.generate(12, (int i) {
          const labels = <String>[
            'VORBIS',
            'AC3',
            'E-AC3',
            'MP3',
            'AAC',
            'HE-AAC',
            'FLAC',
            'ALAC',
            'OPUS',
            'WAV',
            'DTS',
            'OGG',
          ];
          return cap(codecName: 'codec-$i', formatLabel: labels[i]);
        }),
      );

      expect(
        snap.byFormat.keys.toList(),
        <String>[
          'MP3',
          'AAC',
          'HE-AAC',
          'FLAC',
          'ALAC',
          'OPUS',
          'OGG',
          'VORBIS',
          'AC3',
          'E-AC3',
          'DTS',
          'WAV',
        ],
      );
    });

    test('编码短名归一命中聚合结果，命中不了返回 null', () {
      final snap = makeSnapshot(
        entries: <AudioDecoderCapability>[
          cap(codecName: 'mp3', formatLabel: 'MP3'),
          cap(codecName: 'aac', mime: 'audio/mp4a-latm', formatLabel: 'AAC'),
          cap(codecName: 'he', formatLabel: 'HE-AAC'),
          cap(codecName: 'vorbis', mime: 'audio/vorbis', formatLabel: 'VORBIS'),
        ],
      );

      // 细分写法归一到家族
      expect(snap.formatFor('AAC-LC')?.formatLabel, 'AAC');
      expect(snap.formatFor('HE-AAC v1')?.formatLabel, 'HE-AAC');
      expect(snap.formatFor('c2.qti.mp3.decoder')?.formatLabel, 'MP3');
      // OGG 是容器：VORBIS / OPUS 都算候选
      expect(snap.formatFor('OGG')?.formatLabel, 'VORBIS');
      // 没探测到的格式 → null（不知道，不是不支持）
      expect(snap.formatFor('APE'), isNull);
      expect(snap.formatFor(null), isNull);
      expect(snap.formatFor('  '), isNull);

      // 原生按 mime 打标成容器名 OGG 时，VORBIS / OPUS 源编码都要能命中
      final oggSnap = makeSnapshot(
        entries: <AudioDecoderCapability>[
          cap(codecName: 'ogg', mime: 'audio/ogg', formatLabel: 'OGG'),
        ],
      );
      expect(oggSnap.formatFor('VORBIS')?.formatLabel, 'OGG');
      expect(oggSnap.formatFor('OPUS')?.formatLabel, 'OGG');
    });
  });

  group('AudioDecoderCapabilityStore 缓存可信度', () {
    test('无缓存 → null 且 stale；save 后可读且可信；clear 回到 null', () async {
      final store = AudioDecoderCapabilityStore(currentDeviceKey: 'dev-A');
      expect(await store.load(), isNull);
      expect(store.stale, isTrue);

      await store.save(makeSnapshot(deviceKey: 'dev-A'));
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.entries.length, 2);
      expect(store.stale, isFalse);

      await store.clear();
      expect(await store.load(), isNull);
      expect(store.stale, isTrue);
    });

    test('设备指纹不一致 → 仍返回旧快照但 stale', () async {
      final storeA = AudioDecoderCapabilityStore(currentDeviceKey: 'dev-A');
      await storeA.save(makeSnapshot(deviceKey: 'dev-A'));

      final storeB = AudioDecoderCapabilityStore(currentDeviceKey: 'dev-B');
      final loaded = await storeB.load();
      expect(loaded, isNotNull, reason: '先给旧数据让 UI 有内容');
      expect(loaded!.deviceKey, 'dev-A');
      expect(storeB.stale, isTrue);

      // 同一设备重新读：可信
      final storeA2 = AudioDecoderCapabilityStore(currentDeviceKey: 'dev-A');
      await storeA2.load();
      expect(storeA2.stale, isFalse);
    });

    test('超过 7 天过期，7 天内可信', () async {
      final store = AudioDecoderCapabilityStore(currentDeviceKey: 'dev-A');
      await store.save(
        makeSnapshot(
          deviceKey: 'dev-A',
          probedAt: DateTime.now().subtract(const Duration(days: 6)),
        ),
      );
      await store.load();
      expect(store.stale, isFalse);

      await store.save(
        makeSnapshot(
          deviceKey: 'dev-A',
          probedAt: DateTime.now().subtract(const Duration(days: 8)),
        ),
      );
      final stale = await store.load();
      expect(stale, isNotNull);
      expect(store.stale, isTrue);
      expect(AudioDecoderCapabilityStore.keyJson, 'audio_decoder_caps_v1');
      expect(AudioDecoderCapabilityStore.maxAge, const Duration(days: 7));
    });
  });

  // ── 服务接线（MethodChannel 打桩）──────────────────────────────

  group('AudioOffloadService 解码器能力接线', () {
    final AudioOffloadService svc = AudioOffloadService.instance;
    const MethodChannel channel = MethodChannel(AudioOffloadService.channelName);

    int decoderProbeCalls = 0;
    int decoderCachedCalls = 0;
    int decoderProbeCallsAtInit = 0;
    bool decoderProbeThrows = false;
    Map<String, dynamic>? decoderResponse;
    Map<String, dynamic>? offloadResponse;

    Map<String, dynamic> serviceDecoderSnapshotMap() {
      return <String, dynamic>{
        'deviceKey': 'dev-svc',
        'probedAtMs': DateTime.now().millisecondsSinceEpoch,
        'sdkInt': 34,
        'probeCostMs': 12,
        'probeError': null,
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'codecName': 'c2.qti.mp3.decoder',
            'mime': 'audio/mpeg',
            'formatLabel': 'MP3',
            'hardware': true,
            'softwareOnly': false,
            'sampleRates': <int>[44100, 48000],
            'maxChannels': 2,
            'bitDepths': <String, String>{
              '16': 'supported',
              '24': 'unknown',
              '32': 'unknown',
              'float': 'unknown',
            },
            'bitDepthProbed': true,
          },
          <String, dynamic>{
            'codecName': 'c2.android.flac.decoder',
            'mime': 'audio/flac',
            'formatLabel': 'FLAC',
            'hardware': false,
            'softwareOnly': true,
            'sampleRates': <int>[96000],
            'maxChannels': 2,
            'bitDepths': <String, String>{
              '16': 'supported',
              '24': 'supported',
            },
            'bitDepthProbed': true,
          },
          <String, dynamic>{
            'codecName': 'c2.android.aac.decoder',
            'mime': 'audio/mp4a-latm',
            'formatLabel': 'AAC',
            'hardware': true,
            'softwareOnly': false,
            // 采样率 / 声道都没探到 → 该维度未知
            'sampleRates': <int>[],
            'maxChannels': 0,
            'bitDepths': <String, String>{},
            'bitDepthProbed': false,
          },
        ],
        'notes': <String>['APE 无系统解码器，只能软解'],
      };
    }

    Map<String, dynamic> offloadSnapshotMap() {
      return <String, dynamic>{
        'deviceKey': 'dev-svc',
        'probedAtMs': DateTime.now().millisecondsSinceEpoch,
        'sdkInt': 34,
        'variableRateSupported': true,
        'outputSampleRate': 48000,
        'outputFramesPerBuffer': 192,
        'probeError': null,
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'encoding': 9,
            'encodingName': 'audio/mpeg',
            'sampleRate': 44100,
            'channelCount': 2,
            'supported': true,
            'gapless': true,
            'speedChange': true,
          },
        ],
        'notes': <String>[],
      };
    }

    Map<String, dynamic> statusMap() => <String, dynamic>{
      'effective': false,
      'offloaded': false,
      'sleeping': false,
      'failed': false,
      'apiLevel': 34,
    };

    setUpAll(() async {
      // 先埋一份「本机刚探过」的解码器缓存：init 应该直接读它，
      // 不额外触发探测（后台探测只留给无缓存 / 失效的情况）。
      final cached = makeSnapshot(
        deviceKey: 'dev-test',
        probedAt: DateTime.now(),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        AudioDecoderCapabilityStore.keyJson: jsonEncode(cached.toMap()),
        AudioDecoderCapabilityStore.keyDevice: 'dev-test',
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            switch (call.method) {
              case 'getStatus':
              case 'setEnabled':
                return statusMap();
              case 'probeCapabilities':
              case 'getCachedCapabilities':
                return offloadResponse;
              case 'probeDecoderCapabilities':
                decoderProbeCalls++;
                if (decoderProbeThrows) {
                  throw PlatformException(code: 'boom', message: '探测崩溃');
                }
                return decoderResponse;
              case 'getCachedDecoderCapabilities':
                decoderCachedCalls++;
                return decoderResponse;
            }
            return null;
          });

      await svc.init();
      decoderProbeCallsAtInit = decoderProbeCalls;
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    setUp(() {
      decoderProbeCalls = 0;
      decoderCachedCalls = 0;
      decoderProbeThrows = false;
      decoderResponse = serviceDecoderSnapshotMap();
      offloadResponse = null;
    });

    test('init 有新鲜缓存：直接采用，不触发解码器探测（不拖慢启动）', () {
      expect(decoderProbeCallsAtInit, 0);
      final caps = svc.decoderCapabilities;
      expect(caps, isNotNull);
      expect(caps!.deviceKey, 'dev-test');
      expect(caps.entries.length, 2);
    });

    test('reprobe=true 走 probeDecoderCapabilities 并写缓存', () async {
      await svc.reloadDecoderCapabilities(reprobe: true);

      expect(decoderProbeCalls, 1);
      expect(decoderCachedCalls, 0);
      expect(svc.decoderCapabilities?.deviceKey, 'dev-svc');
      expect(svc.decoderCapabilities?.entries.length, 3);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AudioDecoderCapabilityStore.keyJson),
        isNotNull,
      );
      expect(
        prefs.getString(AudioDecoderCapabilityStore.keyDevice),
        'dev-svc',
      );
    });

    test('reprobe=false 只读原生存量缓存', () async {
      await svc.reloadDecoderCapabilities();
      expect(decoderCachedCalls, 1);
      expect(decoderProbeCalls, 0);
      expect(svc.decoderCapabilities?.deviceKey, 'dev-svc');
    });

    test('predictDecoderSupported 三态：支持 / 不支持 / 未知', () async {
      await svc.reloadDecoderCapabilities(reprobe: true);

      // 支持：格式命中且在采样率 / 声道并集里
      expect(svc.predictDecoderSupported('MP3', 44100, 2), isTrue);
      expect(svc.predictDecoderSupported('mp3', 48000, 2), isTrue);
      // 不支持：采样率 / 声道不在并集里
      expect(svc.predictDecoderSupported('MP3', 96000, 2), isFalse);
      expect(svc.predictDecoderSupported('MP3', 44100, 6), isFalse);
      // 不支持：该格式只有软解
      expect(svc.predictDecoderSupported('FLAC', 96000, 2), isFalse);
      // 未知：没探测到这个格式 / 编码为空
      expect(svc.predictDecoderSupported('APE', 44100, 2), isNull);
      expect(svc.predictDecoderSupported(null, 44100, 2), isNull);
      // 该格式的采样率 / 声道都没探到 → 维度未知不判否
      expect(svc.predictDecoderSupported('AAC', 44100, 8), isTrue);
    });

    test('reloadAllCapabilities：任一边失败不影响另一边', () async {
      final before = svc.decoderCapabilities?.deviceKey;
      offloadResponse = offloadSnapshotMap();
      decoderProbeThrows = true;
      await svc.reloadAllCapabilities(reprobe: true);

      expect(svc.capabilities, isNotNull, reason: '解码器探测崩溃不能拖累 offload 能力');
      expect(decoderProbeCalls, 1, reason: '解码器确实尝试过');
      expect(
        svc.decoderCapabilities?.deviceKey,
        before,
        reason: '失败时保持旧快照，不清空',
      );

      // 反向：offload 返回空，解码器正常更新
      offloadResponse = null;
      decoderProbeThrows = false;
      decoderResponse = <String, dynamic>{
        ...serviceDecoderSnapshotMap(),
        'deviceKey': 'dev-svc-2',
      };
      await svc.reloadAllCapabilities(reprobe: true);
      expect(svc.decoderCapabilities?.deviceKey, 'dev-svc-2');
    });
  });
}
