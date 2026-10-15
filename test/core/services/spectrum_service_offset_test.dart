import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.md3music.md3music/spectrum');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SpectrumService service;
  late int savedOffset;
  setUp(() {
    savedOffset = kSpectrumVisualOffsetMs;
    service = SpectrumService.forTesting(isAndroid: true);
    messenger.setMockMethodCallHandler(channel, (call) async => true);
  });
  tearDown(() async {
    kSpectrumVisualOffsetMs = savedOffset;
    await service.stop();
    service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });
  Future<void> fft(List<double> bands) async {
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('onFft', bands)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  test('offset 0 时帧即时发布（保持现状行为）', () async {
    kSpectrumVisualOffsetMs = 0;
    final frames = <List<double>>[];
    final subscription =
        service.spectrumStream.listen((frame) => frames.add(List.of(frame)));
    await service.start();
    await fft(List.filled(40, 0.5));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(frames, hasLength(1));
    expect(frames.last, everyElement(0.5));
    await subscription.cancel();
  });

  test('offset 250 时帧延后发布且携带独立拷贝', () async {
    kSpectrumVisualOffsetMs = 250;
    final frames = <List<double>>[];
    final subscription =
        service.spectrumStream.listen((frame) => frames.add(List.of(frame)));
    await service.start();
    await fft(List.filled(40, 0.6));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(frames, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(frames, hasLength(1));
    expect(frames.last, everyElement(0.6));
    await subscription.cancel();
  });

  test('暂停取消在途延迟帧，只收到立即归零', () async {
    kSpectrumVisualOffsetMs = 250;
    final frames = <List<double>>[];
    final subscription =
        service.spectrumStream.listen((frame) => frames.add(List.of(frame)));
    await service.start();
    service.setPlaying(true);
    await fft(List.filled(40, 0.7));
    service.setPlaying(false);
    expect(frames, hasLength(1));
    expect(frames.last, everyElement(0.0));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // 迟到的 0.7 帧不允许穿透
    expect(frames.where((frame) => frame.any((v) => v > 0)), isEmpty);
    await subscription.cancel();
  });
}
