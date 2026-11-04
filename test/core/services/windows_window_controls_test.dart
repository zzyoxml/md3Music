import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_window_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');
  final calls = <String>[];
  final captured = <MethodCall>[];

  setUp(() {
    calls.clear();
    captured.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    WindowsWindowControls.maxButtonOwner.value = '';
    WindowsWindowControls.maxButtonPointer.value =
        const WindowsCaptionPointerState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('四个窗口操作都走 window_tray 通道', () async {
    await WindowsWindowControls.startDrag();
    await WindowsWindowControls.minimize();
    await WindowsWindowControls.toggleMaximize();
    await WindowsWindowControls.closeWindow();
    expect(calls, ['startDrag', 'minimize', 'toggleMaximize', 'closeWindow']);
  });

  test('非 Windows 平台不发平台调用', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await WindowsWindowControls.startDrag();
    await WindowsWindowControls.closeWindow();
    expect(calls, isEmpty);
  });

  test('snap 登记：逻辑矩形按 dpr 换算成物理像素并带行 id', () async {
    captured.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      captured.add(call);
      return true;
    });
    final accepted = await WindowsWindowControls.reportMaxButtonRect(
        'row-1', const Rect.fromLTWH(10.4, 20.6, 46, 32), 1.5);
    expect(accepted, isTrue);
    final args = captured.single.arguments as Map;
    expect(args['id'], 'row-1');
    expect(args['left'], 16);   // (10.4*1.5).round()
    expect(args['top'], 31);    // (20.6*1.5).round()
    expect(args['right'], 85);  // (56.4*1.5).round()
    expect(args['bottom'], 79); // (52.6*1.5).round()

    await WindowsWindowControls.clearMaxButtonRect('row-1');
    expect(calls, ['setCaptionMaxButtonRect', 'clearCaptionMaxButtonRect']);
    expect((captured.last.arguments as Map)['id'], 'row-1');
  });

  test('非 Windows 不上报、不清理接管矩形', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      await WindowsWindowControls.reportMaxButtonRect(
          'row-1', const Rect.fromLTWH(0, 0, 46, 32), 1.0),
      isFalse,
    );
    await WindowsWindowControls.clearMaxButtonRect('row-1');
    expect(calls, isEmpty);
  });

  test('原生入站分发：指针状态与接管广播写进 Notifier', () async {
    expect(
      WindowsWindowControls.handleNativeCall(const MethodCall(
          'onCaptionMaxPointerState', {'hovered': true, 'pressed': true})),
      isTrue,
    );
    expect(WindowsWindowControls.maxButtonPointer.value.hovered, isTrue);
    expect(WindowsWindowControls.maxButtonPointer.value.pressed, isTrue);

    expect(
      WindowsWindowControls.handleNativeCall(
          const MethodCall('onCaptionMaxTakeover', 'row-2')),
      isTrue,
    );
    expect(WindowsWindowControls.maxButtonOwner.value, 'row-2');

    // 未知方法不属于本服务：返回 false 让调用方继续分发（requestQuit 等）。
    expect(
      WindowsWindowControls.handleNativeCall(
          const MethodCall('requestQuit')),
      isFalse,
    );
  });
}
