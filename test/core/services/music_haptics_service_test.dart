import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/music_haptics_service.dart';
import 'package:md3music/core/services/spectrum_service.dart';
import 'package:md3music/core/utils/app_haptics.dart';

/// 音乐震动编排层的闸门行为。
///
/// 判据是**真实通道调用序列**（AGENTS.md 0.1）：每个闸门关掉时，
/// `music_haptics` 通道上的 `strike` 必须一次都收不到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const spectrumChannel = 'com.md3music.md3music/spectrum';
  const musicChannel = 'com.md3music.md3music/music_haptics';
  const codec = StandardMethodCodec();

  final strikeCalls = <MethodCall>[];
  final configureCalls = <MethodCall>[];

  /// 由各测试设置的原生 outputLatency 回报值（-1 = 不可用）。
  int probeResult = -1;

  Future<void> emitFeatures(List<double> features) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      spectrumChannel,
      codec.encodeMethodCall(MethodCall('onFeatures', features)),
      (_) {},
    );
  }

  /// 造一个低频能量高、高频能量低的"踢鼓"帧。
  List<double> kickFrame(double low) {
    final f = List<double>.filled(20, 0.0);
    f[SpectrumFeaturesIndices.low] = low;
    f[SpectrumFeaturesIndices.rms] = low;
    return f;
  }

  setUp(() {
    strikeCalls.clear();
    configureCalls.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(spectrumChannel), (call) async {
      return call.method == 'start' ? true : null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(musicChannel), (call) async {
      if (call.method == 'strike') strikeCalls.add(call);
      if (call.method == 'configure') configureCalls.add(call);
      if (call.method == 'outputLatency') return probeResult;
      if (call.method == 'capabilities') {
        return <String, Object?>{
          'hasVibrator': true,
          'hasAmplitudeControl': true,
          'sdkInt': 34,
        };
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(spectrumChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(musicChannel), null);
  });

  test('开关关闭时不下发任何 strike', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    expect(service.enabled, isFalse, reason: '默认必须是关闭');

    // 关着开关照样把特征喂进去：此时连订阅都不建立（省电闸门），
    // 断言的是「喂帧也不会打到马达」这一外部行为。
    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isEmpty);

    service.dispose();
    spectrum.dispose();
  });

  test('开着且特征新鲜时，低频阶跃会下发 kick strike', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setEnabled(true);
    strikeCalls.clear();

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }

    expect(strikeCalls, isNotEmpty, reason: '踢鼓阶跃必须能打到马达');
    final kinds = strikeCalls
        .map((c) => (c.arguments as Map<Object?, Object?>)['kind'])
        .toSet();
    expect(kinds, contains('kick'));

    service.dispose();
    spectrum.dispose();
  });

  test('全站震动总开关关闭时，音乐震动一并静默', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();
    await AppHaptics.setEnabled(false);

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setEnabled(true);
    strikeCalls.clear();

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isEmpty);

    service.dispose();
    spectrum.dispose();
  });

  test('高频开关关闭时不发 snare strike', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setEnabled(true);
    await service.setSnareEnabled(false);
    strikeCalls.clear();

    final snare = List<double>.filled(20, 0.0);
    for (var i = 0; i < 12; i++) {
      snare[SpectrumFeaturesIndices.high] = i.isEven ? 0.1 : 3.0;
      await emitFeatures(List<double>.from(snare));
    }

    final kinds = strikeCalls
        .map((c) => (c.arguments as Map<Object?, Object?>)['kind'])
        .toSet();
    expect(kinds, isNot(contains('snare')));

    service.dispose();
    spectrum.dispose();
  });

  test('setEnabled 会下发 configure，且 enabled=false 时停震', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    configureCalls.clear();

    await service.setEnabled(true);
    expect(configureCalls, isNotEmpty);
    expect(configureCalls.last.arguments['enabled'], isTrue);

    await service.setStrength(0.4);
    expect(configureCalls.last.arguments['kickStrength'], closeTo(0.4, 1e-9));

    await service.setEnabled(false);
    expect(configureCalls.last.arguments['enabled'], isFalse);

    service.dispose();
    spectrum.dispose();
  });

  test('偏好持久化：重新 load 后仍是开', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final first = MusicHapticsService.forTesting(spectrum: spectrum);
    await first.load();
    await first.setEnabled(true);
    await first.setSensitivity(2.5);
    first.dispose();

    final second = MusicHapticsService.forTesting(spectrum: spectrum);
    await second.load();
    expect(second.enabled, isTrue);
    expect(second.sensitivity, closeTo(2.5, 1e-9));

    second.dispose();
    spectrum.dispose();
  });

  test('高频带近无声时 snare 不触发（能量双门）', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setEnabled(true);
    strikeCalls.clear();

    // 低频正常起伏（20 上下），高频只有 0.2~1.4 的背景噪声抖动（恒低于绝对门 2.0）
    // —— 对应真机实测"3-8kHz 近无声"的混音，snare 必须全程静默
    for (var i = 0; i < 40; i++) {
      final f = List<double>.filled(20, 0.0);
      f[SpectrumFeaturesIndices.low] = 18.0 + (i.isEven ? 2.0 : -2.0);
      f[SpectrumFeaturesIndices.high] = 0.2 + (i % 5) * 0.3;
      await emitFeatures(List<double>.from(f));
    }

    final kinds = strikeCalls
        .map((c) => (c.arguments as Map<Object?, Object?>)['kind'])
        .toSet();
    expect(kinds, isNot(contains('snare')),
        reason: '高频能量低于双门时，噪声峰不得驱动马达');

    service.dispose();
    spectrum.dispose();
  });

  test('kick 触发后 60ms 内的 snare 被抑制（双发抑制）', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    await spectrum.start(null, 'test-owner', false);

    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setEnabled(true);

    // 预热 12 帧稳定背景，让两个检测器的 EMA / 掩码进入稳态
    for (var i = 0; i < 12; i++) {
      final f = List<double>.filled(20, 0.0);
      f[SpectrumFeaturesIndices.low] = 4.0;
      f[SpectrumFeaturesIndices.high] = 1.0;
      await emitFeatures(List<double>.from(f));
    }
    strikeCalls.clear();

    // 同一帧里 low 与 high 同时阶跃（真机上"kick 帧同时带镲片"的形状）：
    // high=6.0 > 绝对门 2.0 且 > 0.05×8.0，两路都过门 —— 必须只发 kick，
    // snare 被同一帧刚触发的 kick 抑制。
    // 注意：不能靠"连发多帧"制造场景 —— 检测器的 130ms 冷却按真实时钟算，
    // 背靠背发帧时第二段连 kick 都不会触发，前提根本无法成立（计划初稿的缺陷）。
    final joint = List<double>.filled(20, 0.0);
    joint[SpectrumFeaturesIndices.low] = 8.0;
    joint[SpectrumFeaturesIndices.high] = 6.0;
    await emitFeatures(List<double>.from(joint));

    final kinds = strikeCalls
        .map((c) => (c.arguments as Map<Object?, Object?>)['kind'])
        .toSet();
    expect(kinds, contains('kick'), reason: 'kick 本身应触发');
    expect(kinds, isNot(contains('snare')),
        reason: 'kick 触发后 60ms 内的 snare 必须被抑制（实际 kinds=$kinds）');

    service.dispose();
    spectrum.dispose();
  });

  test('节奏偏移下发 configure、持久化并在超界时夹紧', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    configureCalls.clear();

    await service.setOffset(320);
    expect(service.offsetMs, 320);
    expect(configureCalls.last.arguments['offsetMs'], 320,
        reason: '偏移必须随 configure 下发原生，否则原生不知道要等');

    // 超界自动夹紧（原生侧同样 coerceIn(0,600)，两边都要夹）
    await service.setOffset(9999);
    expect(service.offsetMs, MusicHapticsService.maxOffsetMs);
    expect(configureCalls.last.arguments['offsetMs'],
        MusicHapticsService.maxOffsetMs);
    await service.setOffset(-50);
    expect(service.offsetMs, 0);

    // 持久化：最后写一个已知正值，再新建实例读回（夹紧用例已经把 0 写进去了）
    await service.setOffset(250);
    final second = MusicHapticsService.forTesting(spectrum: spectrum);
    await second.load();
    expect(second.offsetMs, 250);

    second.dispose();
    service.dispose();
    spectrum.dispose();
  });

  test('自动校准：实测排队深度 + 上游预算，超界夹紧', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    probeResult = 320; // 原生回报的排队深度
    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();

    final ok = await service.applyAutoOffset();
    expect(ok, isTrue);
    expect(service.measuredLatencyMs, 320);
    expect(service.offsetMs, 320 + MusicHapticsService.upstreamLatencyBudgetMs);
    expect(service.offsetMs, lessThanOrEqualTo(MusicHapticsService.maxOffsetMs));

    service.dispose();
    spectrum.dispose();
  });

  test('自动校准：原生报不可用（-1）时保持手动值并返回 false', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    probeResult = -1;
    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    await service.setOffset(420);

    final ok = await service.applyAutoOffset();
    expect(ok, isFalse, reason: 'USB 独占/Direct PCM 等无 AudioTrack 路径必须保持手动值');
    expect(service.measuredLatencyMs, isNull);
    expect(service.offsetMs, 420, reason: '测量失败不得覆盖用户手调值');

    service.dispose();
    spectrum.dispose();
  });
}
