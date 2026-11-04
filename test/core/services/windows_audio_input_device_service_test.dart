import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_audio_input_device_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(
      WindowsAudioInputDeviceService.channel,
      handler,
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(
      WindowsAudioInputDeviceService.channel,
      null,
    );
  });

  test('listDevices 解析 id/name/isSystemDefault', () async {
    mockChannel((call) async {
      expect(call.method, 'listInputDevices');
      return <Object?>[
        <Object?, Object?>{
          'id': '{0.0.1.00000000}.{AAA}',
          'name': '麦克风阵列 (Senary Audio)',
          'isSystemDefault': true,
        },
        <Object?, Object?>{
          'id': '{0.0.1.00000000}.{BBB}',
          'name': '麦克风 (Steam Streaming Microphone)',
          'isSystemDefault': false,
        },
      ];
    });

    final devices = await WindowsAudioInputDeviceService.listDevices();
    expect(devices, hasLength(2));
    expect(devices.first.id, '{0.0.1.00000000}.{AAA}');
    expect(devices.first.name, '麦克风阵列 (Senary Audio)');
    expect(devices.first.isSystemDefault, isTrue);
    expect(devices.last.isSystemDefault, isFalse);
  });

  test('原生通道未注册时 listDevices 返回空列表而不是抛异常', () async {
    mockChannel((call) async => throw MissingPluginException());
    expect(await WindowsAudioInputDeviceService.listDevices(), isEmpty);
  });

  test('selectDevice 写入/清除持久化键', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    mockChannel((call) async => null);

    await WindowsAudioInputDeviceService.selectDevice('{id-1}');
    expect(await WindowsAudioInputDeviceService.selectedDeviceId(), '{id-1}');

    await WindowsAudioInputDeviceService.selectDevice(null);
    expect(await WindowsAudioInputDeviceService.selectedDeviceId(), isNull);
  });

  test('resolveInputDevice：命中返回设备，失效 id 回落系统默认（null）', () {
    const devices = <WindowsAudioInputDevice>[
      WindowsAudioInputDevice(id: 'a', name: 'A', isSystemDefault: true),
      WindowsAudioInputDevice(id: 'b', name: 'B', isSystemDefault: false),
    ];
    expect(resolveInputDevice(devices, 'b')?.name, 'B');
    expect(resolveInputDevice(devices, 'gone'), isNull);
    expect(resolveInputDevice(devices, null), isNull);
  });
}
