import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/remote_control_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.md3music.md3music/device_form'),
      null,
    );
  });

  test('默认 auto：检测失败（非 TV 环境）时不开遥控模式', () async {
    SharedPreferences.setMockInitialValues({});
    final p = RemoteControlProvider();
    await p.restored;
    expect(p.mode, 'auto');
    expect(p.enabled, isFalse);
  });

  test('auto：检测为 TV 设备时开启', () async {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.md3music.md3music/device_form'),
      (call) async => call.method == 'isTv' ? true : null,
    );
    final p = RemoteControlProvider();
    await p.restored;
    expect(p.enabled, isTrue);
  });

  test('always_on 强制开启并持久化；always_off 关闭', () async {
    SharedPreferences.setMockInitialValues({});
    final p = RemoteControlProvider();
    await p.restored;

    await p.setMode('always_on');
    expect(p.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings_remote_control_mode'), 'always_on');

    await p.setMode('always_off');
    expect(p.enabled, isFalse);
  });

  test('持久化的模式在重建 Provider 后恢复', () async {
    SharedPreferences.setMockInitialValues(
        {'settings_remote_control_mode': 'always_off'});
    final p = RemoteControlProvider();
    await p.restored;
    expect(p.mode, 'always_off');
    expect(p.enabled, isFalse);
  });
}
