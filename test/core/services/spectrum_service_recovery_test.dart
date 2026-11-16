import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.md3music.md3music/spectrum');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SpectrumService service;
  late List<String> calls;
  late int savedVisualOffset;
  setUp(() {
    calls = [];
    // 本文件钉的是断流/恢复状态机，与显示对齐延后无关：把镜像钉回同步发布，
    // 「喂帧即上屏」的断言前提才成立（延后行为本身由 offset_test 覆盖）。
    savedVisualOffset = kSpectrumVisualOffsetMs;
    kSpectrumVisualOffsetMs = 0;
    service = SpectrumService.forTesting(isAndroid: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
  });
  tearDown(() async {
    kSpectrumVisualOffsetMs = savedVisualOffset;
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

  test('已收到真实频谱后断流也会恢复，并重新绑定原生采集', () async {
    final frames = <List<double>>[];
    final subscription = service.spectrumStream.listen(
      (frame) => frames.add(List.of(frame)),
    );
    await service.start();
    service.setPlaying(true);
    await fft(List.filled(40, 0.5));
    expect(service.isSimulated, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(service.isSimulated, isTrue);
    expect(calls.where((call) => call == 'start'), hasLength(2));
    expect(frames.last.any((value) => value > 0), isTrue);
    await fft(List.filled(40, 0.7));
    expect(service.isSimulated, isFalse);
    expect(frames.last, everyElement(0.7));
    await subscription.cancel();
  });

  test('重叠播放器中旧页面退出不能停止新页面的采集', () async {
    final oldPage = Object();
    final newPage = Object();
    await service.start(1, oldPage);
    await service.start(1, newPage);
    expect(calls, ['start']);
    await service.stop(oldPage);
    expect(service.isRunning, isTrue);
    expect(calls, ['start']);
    await service.stop(newPage);
    expect(service.isRunning, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('退出后旧启动结果与迟到FFT都不能重新开启频谱', () async {
    final nativeStart = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'start' ? nativeStart.future : true;
    });
    final frames = <List<double>>[];
    final subscription = service.spectrumStream.listen(
      (frame) => frames.add(List.of(frame)),
    );
    final starting = service.start();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    nativeStart.complete(true);
    expect(await starting, isFalse);
    await fft(List.filled(40, 1));
    expect(service.isRunning, isFalse);
    expect(service.isSimulated, isFalse);
    expect(frames, isEmpty);
    await subscription.cancel();
  });

  test('暂停不误触发断流重连，继续播放后检查恢复', () async {
    await service.start();
    service.setPlaying(false);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    expect(service.isSimulated, isFalse);
    expect(calls, ['start']);
    service.setPlaying(true);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(service.isSimulated, isTrue);
  });

  test('无原生插件时仍启动降级模式，停止后可重新启动', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await service.start(), isTrue);
    expect(service.isSimulated, isTrue);
    await service.stop();
    expect(service.isRunning, isFalse);
    expect(await service.start(), isTrue);
    expect(service.isSimulated, isTrue);
  });

  test('熄屏期间停掉原生采集，亮屏立即重绑并恢复真实数据', () async {
    await service.start(42);
    service.setPlaying(true);
    await fft(List.filled(40, 0.4));
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    // 退后台停掉原生采集：引擎不产帧、没有消费者，渲染线程上那套逐样本解码
    // 与跨线程投递是纯开销（前台高负载时正是欠载推手）。
    expect(calls, ['start', 'stop']);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop', 'start']);
    await fft(List.filled(40, 0.6));
    expect(service.isRunning, isTrue);
    expect(service.isSimulated, isFalse);
  });

  test('退后台停采集后 owner 仍保留，重新 start 不重复登记', () async {
    await service.start(42);
    service.setPlaying(true);
    await fft(List.filled(40, 0.4));
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop']);
    // 退后台只是暂停原生采集，会话本身没结束
    expect(service.isRunning, isTrue);
  });

  test('「始终震动」场景退后台不停采集，回前台也不重复重绑', () async {
    service.setBackgroundCaptureRequired(true);
    await service.start(42);
    service.setPlaying(true);
    await fft(List.filled(40, 0.4));
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(calls, ['start']);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'start']);
  });

  test('inactive 可见失焦期间仍监测断流并恢复频谱采集', () async {
    await service.start(42);
    service.setPlaying(true);
    await fft(List.filled(40, 0.4));
    service.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(service.isSimulated, isTrue);
    expect(calls.where((call) => call == 'start'), hasLength(2));
  });
}
