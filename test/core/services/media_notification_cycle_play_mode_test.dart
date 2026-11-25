import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/media_notification_service.dart';

/// 概念版 4×1 小组件的播放模式键：原生 `cyclePlayMode` 命令要能落到回调上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/floating_lyric');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    MediaNotificationService.onCyclePlayMode = null;
  });

  Future<void> sendCommand(String method) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  test('收到 cyclePlayMode 时触发已装配的回调', () async {
    var calls = 0;
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onCyclePlayMode = () => calls++;

    await sendCommand('cyclePlayMode');

    expect(calls, 1);
  });

  test('未装配回调时收到 cyclePlayMode 不崩溃', () async {
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onCyclePlayMode = null;

    await expectLater(sendCommand('cyclePlayMode'), completes);
  });

  test('重复下发时每次都会回调（模式键语义是循环切换，不做去重）', () async {
    var calls = 0;
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onCyclePlayMode = () => calls++;

    await sendCommand('cyclePlayMode');
    await sendCommand('cyclePlayMode');
    await sendCommand('cyclePlayMode');

    expect(calls, 3);
  });
}
