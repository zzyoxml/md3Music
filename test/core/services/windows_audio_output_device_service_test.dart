import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/core/services/windows_audio_output_device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/windows_audio_output');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('lists render devices with their system-default marker', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listOutputDevices');
          return [
            {'id': 'speaker-1', 'name': 'Speakers', 'isSystemDefault': true},
            {
              'id': 'bt-1',
              'name': 'Bluetooth Headphones',
              'isSystemDefault': false,
            },
          ];
        });

    final devices = await WindowsAudioOutputDeviceService.listDevices();

    expect(devices.map((device) => device.name), [
      'Speakers',
      'Bluetooth Headphones',
    ]);
    expect(devices.first.isSystemDefault, isTrue);
  });

  test('persists the selected device after native routing succeeds', () async {
    String? selected;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'setOutputDevice');
          selected = (call.arguments as Map)['deviceId'] as String?;
          return null;
        });

    await WindowsAudioOutputDeviceService.selectDevice('bt-1');

    expect(selected, 'bt-1');
    expect(await WindowsAudioOutputDeviceService.selectedDeviceId(), 'bt-1');
  });

  test('keeps a missing device selection for automatic reconnection', () async {
    SharedPreferences.setMockInitialValues({
      'windows_audio_output_device_id': 'missing-device',
    });
    String? routedId = 'not-called';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listOutputDevices') return <Object?>[];
          routedId = (call.arguments as Map)['deviceId'] as String?;
          return null;
        });

    await WindowsAudioOutputDeviceService.restore();

    expect(routedId, 'missing-device');
    expect(
      await WindowsAudioOutputDeviceService.selectedDeviceId(),
      'missing-device',
    );
  });
}
