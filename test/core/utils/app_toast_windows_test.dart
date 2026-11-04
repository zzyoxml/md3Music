import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/app_toast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows Toast 走非阻塞原生提示通道并传递时长', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('md3music/desktop_message');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    showToast('已保存');
    showToast('稍后重试', long: true);
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((call) => call.method), ['show', 'show']);
    expect(calls[0].arguments, {'message': '已保存', 'long': false});
    expect(calls[1].arguments, {'message': '稍后重试', 'long': true});
  });
}
