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
  late List<String> methods;
  late List<Map<Object?, Object?>> startArgs;
  setUp(() {
    methods = [];
    startArgs = [];
    service = SpectrumService.forTesting(isAndroid: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'start') {
        startArgs.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      if (call.method == 'stats') {
        return <String, Object>{
          'emitCount': 101, 'submitted': 0, 'pumpStopped': true,
        };
      }
      return true;
    });
  });
  tearDown(() async {
    await service.stop();
    service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('保险丝降级当场拉取原生 stats 归因', () async {
    await service.start();
    service.setPlaying(true);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(service.isSimulated, isTrue);
    expect(methods, contains('stats'));
  });

  test('被新一代次作废的 start 不得泄漏 owner', () async {
    final oldPage = Object();
    final newPage = Object();
    final gate1 = Completer<bool>();
    final gate2 = Completer<bool>();
    var startCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        startCount++;
        return startCount == 1 ? gate1.future : gate2.future;
      }
      return true;
    });
    final startingOld = service.start(1, oldPage);
    await Future<void>.delayed(Duration.zero);
    await service.stop(oldPage); // 旧页面秒退：作废在途的原生 start
    final startingNew = service.start(1, newPage);
    await Future<void>.delayed(Duration.zero);
    gate2.complete(true);
    gate1.complete(true);
    expect(await startingNew, isTrue);
    expect(await startingOld, isFalse);
    await service.stop(newPage);
    // 修复前：oldPage 残留在 _owners，此处 isRunning 恒为 true
    expect(service.isRunning, isFalse);
  });

  test('已运行时 start 刷新 sessionId，模拟模式下立即带新 session 重绑', () async {
    await service.start(100);
    service.setPlaying(true);
    // 不喂帧，等保险丝进模拟模式（此时已有一次带 100 的 rebind）
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(service.isSimulated, isTrue);
    final before = startArgs.length;
    await service.start(200);
    await Future<void>.delayed(Duration.zero);
    // 修复前：第二个 start 被 `if (_running) return true` 吞掉，无新调用
    expect(startArgs.length, greaterThan(before));
    expect(startArgs.last['audioSessionId'], 200);
  });
}
