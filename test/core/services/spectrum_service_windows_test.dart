import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_service.dart';

/// Windows 端频谱采集的 Dart 侧契约。
///
/// 原生实现见 `windows/runner/spectrum_capture.cpp`：WASAPI 环回 → 1024 点 FFT →
/// 与 Android 完全相同的 `onFft` 40 段协议。本文件只钉 Dart 侧必须成立的三件事：
/// 1. Windows 走**原生采集**而不是模拟模式；
/// 2. 不套用 Android 的视觉偏移延迟（环回采集与听到的天然同相）；
/// 3. 暂停归零 / 原生失败降级 / 断流重建采集的既有语义不被破坏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.md3music.md3music/spectrum');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SpectrumService service;
  late List<String> calls;
  late int savedOffset;
  setUp(() {
    calls = [];
    savedOffset = kSpectrumVisualOffsetMs;
    // 故意保留 Android 默认的 580ms：Windows 分支必须忽略它。
    kSpectrumVisualOffsetMs = 580;
    service = SpectrumService.forTesting(isAndroid: false, isWindows: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'stats') {
        return <String, Object?>{
          'running': true,
          'mode': 'process',
          'frames': 1,
          'sampleRate': 44100,
        };
      }
      return true;
    });
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

  test('Windows 启动原生采集而不是模拟模式', () async {
    final frames = <List<double>>[];
    final subscription = service.spectrumStream.listen(
      (frame) => frames.add(List.of(frame)),
    );
    expect(await service.start(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.isSimulated, isFalse);
    expect(calls, contains('start'));
    await fft(List.filled(40, 0.6));
    expect(frames, hasLength(1));
    expect(frames.single, everyElement(0.6));
    await subscription.cancel();
  });

  test('帧不套 Android 视觉偏移（580ms 也立即上屏）', () async {
    final frames = <List<double>>[];
    final subscription = service.spectrumStream.listen(
      (frame) => frames.add(List.of(frame)),
    );
    await service.start();
    await fft(List.filled(40, 0.7));
    // 不等待 580ms：Windows 分支必须同帧发布
    expect(frames, hasLength(1));
    expect(frames.single, everyElement(0.7));
    await Future<void>.delayed(const Duration(milliseconds: 620));
    // 迟到的定时器帧不允许再补一份（同一个帧只发布一次）
    expect(frames, hasLength(1));
    await subscription.cancel();
  });

  test('暂停立即推全 0 帧并丢弃后续真实帧', () async {
    final frames = <List<double>>[];
    final subscription = service.spectrumStream.listen(
      (frame) => frames.add(List.of(frame)),
    );
    await service.start();
    service.setPlaying(true);
    await fft(List.filled(40, 0.8));
    service.setPlaying(false);
    expect(frames.last, everyElement(0.0));
    await fft(List.filled(40, 0.9));
    expect(frames.where((frame) => frame.any((v) => v > 0)), hasLength(1));
    await subscription.cancel();
  });

  test('stop 通知原生停止采集', () async {
    await service.start();
    await service.stop();
    expect(service.isRunning, isFalse);
    expect(calls, contains('stop'));
  });

  test('原生 start 失败时降级模拟模式（不破坏兜底）', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'start' ? false : true;
    });
    expect(await service.start(), isTrue);
    expect(service.isSimulated, isTrue);
  });

  test('播放中断流会降级并重建原生采集', () async {
    await service.start();
    service.setPlaying(true);
    await fft(List.filled(40, 0.5));
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(service.isSimulated, isTrue);
    expect(calls.where((call) => call == 'start'), hasLength(2));
    await fft(List.filled(40, 0.4));
    expect(service.isSimulated, isFalse);
  });

  test('恢复前台会重建原生采集', () async {
    await service.start();
    service.setPlaying(true);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(service.simulatedNotifier.value, isFalse);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call == 'start'), hasLength(2));
  });
}
