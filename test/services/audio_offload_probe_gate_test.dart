import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('硬解关闭时禁止真实探测，开启后补探测，关闭后缓存仍可读', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel(AudioOffloadService.channelName);
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getStatus' || call.method == 'setEnabled') {
        return {'apiLevel': 30, 'deviceKey': 'gate-test'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final svc = AudioOffloadService.instance;
    await svc.init();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isNot(contains('probeCapabilities')));
    expect(calls, isNot(contains('probeDecoderCapabilities')));
    await svc.reloadAllCapabilities(reprobe: true);
    expect(calls.where((m) => m.startsWith('probe')), isEmpty);

    await svc.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((m) => m == 'probeCapabilities').length, 1);
    expect(calls.where((m) => m == 'probeDecoderCapabilities').length, 1);
    await svc.reloadAllCapabilities(reprobe: true);
    expect(calls.where((m) => m == 'probeDecoderCapabilities').length, 2);

    await svc.setEnabled(false);
    calls.clear();
    await svc.reloadAllCapabilities(reprobe: true);
    expect(calls, isEmpty);
    await svc.reloadAllCapabilities();
    expect(
      calls,
      containsAll(['getCachedCapabilities', 'getCachedDecoderCapabilities']),
    );
  });
}
