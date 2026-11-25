import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.md3music.md3music/viper_dsp');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  test('setEnabled pushes enabled flag', () async {
    await channel.invokeMethod('setEnabled', {'enabled': true});
    expect(calls.single.method, 'setEnabled');
    expect(calls.single.arguments['enabled'], true);
  });

  test('setEqGains sends exactly 10 doubles', () async {
    await channel.invokeMethod('setEqGains', {'gains': List.filled(10, 1.5)});
    expect(calls.single.method, 'setEqGains');
    expect((calls.single.arguments as Map)['gains'], hasLength(10));
  });
}
