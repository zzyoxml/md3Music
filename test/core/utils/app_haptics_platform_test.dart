// AppHaptics 平台闸门：没有震动马达的平台不得向原生通道发震动请求。
//
// **背景**：Windows 桌面端没有注册 `md3music/haptics` 通道（只有 Android 的
// `MainActivity.kt` 注册），也没实现 `HapticFeedback.vibrate`。修复前每次点击
// 都会先发一次注定 `MissingPluginException` 的原生调用、再回落一次同样未实现的
// `HapticFeedback`，外加一个 300ms 看门狗 `Timer` —— 这些开销正好压在
// 「点按钮 → 下一帧」上（Windows 鼠标点暂停比空格暂停多出整窗掉帧）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/utils/app_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('md3music/haptics');

  final List<MethodCall> calls = <MethodCall>[];

  void installHandler(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(calls.clear);

  tearDown(() {
    // `debugDefaultTargetPlatformOverride` 由各用例在本体内复位（框架在用例
    // 结束时就会校验 foundation 调试变量，tearDown 已经晚了）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('Windows：点击不发原生震动，也不留看门狗 Timer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    installHandler((MethodCall call) async {
      calls.add(call);
      return true;
    });

    // 闸门只跳过「平台没有马达」，设置页的类别判定照旧成立。
    expect(AppHaptics.allows(HapticCategory.transport), isTrue);

    AppHaptics.click(HapticCategory.transport);
    AppHaptics.tick(HapticCategory.control);
    AppHaptics.lightImpact(HapticCategory.navigation);
    // 超过 300ms 看门狗窗口：若仍有残留 Timer，用例结束时会报未清理。
    await tester.pump(const Duration(milliseconds: 400));

    debugDefaultTargetPlatformOverride = null;

    expect(calls, isEmpty);
  });

  testWidgets('Android：点击仍下发原生震动（原行为不变）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    installHandler((MethodCall call) async {
      calls.add(call);
      return true;
    });

    AppHaptics.click(HapticCategory.transport);
    await tester.pump();

    debugDefaultTargetPlatformOverride = null;

    expect(calls, hasLength(1));
    expect(calls.single.method, 'vibrate');
    expect((calls.single.arguments as Map<Object?, Object?>)['type'], 'click');
  });
}
