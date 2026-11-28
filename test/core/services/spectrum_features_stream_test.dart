import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/spectrum_service.dart';

/// 原生 `onFeatures` → Dart `featuresStream` 的通路与暂停门控。
///
/// 判据是流上真实收到的帧（AGENTS.md 0.1），不是"服务跑起来了"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.md3music.md3music/spectrum';
  const codec = StandardMethodCodec();

  /// 模拟原生主动调 Dart：把一次 MethodCall 塞进二进制信使。
  Future<void> emitFromNative(String method, Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channelName,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  setUp(() {
    // 原生 start 一律成功；PCM 通路的 visualizerFallback=false
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      return call.method == 'start' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  test('onFeatures 写入 featuresStream', () async {
    final service = SpectrumService.forTesting(isAndroid: true);
    final frames = <List<double>>[];
    final sub = service.featuresStream.listen(
      (f) => frames.add(List<double>.from(f)),
    );

    await service.start(null, 'test-owner', false);
    await emitFromNative('onFeatures', List<double>.filled(20, 0.25));

    expect(frames, hasLength(1));
    expect(frames.single, hasLength(20));
    expect(frames.single[17], 0.25);

    await sub.cancel();
    service.dispose();
  });

  test('暂停时丢弃特征帧（PCM 尾音不得驱动马达）', () async {
    final service = SpectrumService.forTesting(isAndroid: true);
    final frames = <List<double>>[];
    final sub = service.featuresStream.listen(
      (f) => frames.add(List<double>.from(f)),
    );

    await service.start(null, 'test-owner', false);
    service.setPlaying(false);
    await emitFromNative('onFeatures', List<double>.filled(20, 0.9));

    expect(frames, isEmpty, reason: '暂停期间的原生帧必须被门控丢弃');

    await sub.cancel();
    service.dispose();
  });

  test('未 start 时 onFeatures 不产生帧', () async {
    final service = SpectrumService.forTesting(isAndroid: true);
    final frames = <List<double>>[];
    final sub = service.featuresStream.listen(
      (f) => frames.add(List<double>.from(f)),
    );

    await emitFromNative('onFeatures', List<double>.filled(20, 0.5));

    expect(frames, isEmpty);

    await sub.cancel();
    service.dispose();
  });
}
