import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/viper_master_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/viper_dsp');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('初始状态：关闭、10 段全 0', () async {
    final svc = ViperMasterService.instance;
    await svc.init();
    expect(svc.enabled, isFalse);
    expect(svc.gains, List.filled(10, 0.0));
  });

  test('setEnabled 推送原生并持久化', () async {
    final svc = ViperMasterService.instance;
    await svc.init();
    await svc.setEnabled(true);
    expect(svc.enabled, isTrue);
    expect(
      calls.any((c) =>
          c.method == 'setEnabled' &&
          (c.arguments as Map)['enabled'] == true),
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_viper_master_enabled'), isTrue);
  });

  test('applyPreset 推送 10 段曲线；setGains 钳制 ±12', () async {
    final svc = ViperMasterService.instance;
    await svc.init();
    await svc.applyPreset('重低音');
    final push1 = calls.lastWhere((c) => c.method == 'setEqGains');
    expect(
      (push1.arguments as Map)['gains'] as List,
      orderedEquals(ViperMasterService.viperCurves['重低音']!),
    );
    await svc.setGains(List.filled(10, 20.0));
    final push2 = calls.lastWhere((c) => c.method == 'setEqGains');
    expect((push2.arguments as Map)['gains'] as List, orderedEquals(List.filled(10, 12)));
  });

  test('curveFor 未知预设回退流行', () {
    expect(
      ViperMasterService.curveFor('不存在'),
      orderedEquals(ViperMasterService.viperCurves['流行']!),
    );
  });
}
