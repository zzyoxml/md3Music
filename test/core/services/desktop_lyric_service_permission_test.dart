import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无悬浮窗权限时 enable() 不点亮开关且仍尝试拉起授权页', () async {
    var startCalled = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.md3music.md3music/floating_lyric'),
      (call) async {
        if (call.method == 'startFloatingLyric') {
          startCalled++;
          // 模拟权限缺失：原生 MainActivity 跳授权页并返回 false
          return false;
        }
        return null;
      },
    );
    final service = DesktopLyricService.instance;
    await service.enable();
    expect(startCalled, 1, reason: '无权限也应调用 startFloatingLyric 触发授权页');
    expect(service.enabled, isFalse);
  });
}
