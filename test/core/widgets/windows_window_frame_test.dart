import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/services/windows_fullscreen.dart';
import 'package:md3music/core/widgets/windows_window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');
  final calls = <String>[];
  var maximized = false;
  Finder tooltip(String label) => find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == label,
  );

  setUp(() {
    calls.clear();
    maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'toggleMaximize') maximized = !maximized;
          return maximized;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester tester, Size size, {bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: const Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Color(0xff3276a0))),
            WindowsWindowFrame(
              child: ColoredBox(
                key: ValueKey('body'),
                color: Color(0xff123456),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets('顶部80%透明，三键可见且不覆盖正文 dark=$dark', (tester) async {
      await pump(tester, const Size(900, 600), dark: dark);
      final bar = find.byKey(const ValueKey('windows_title_bar'));
      expect(tester.widget<ColoredBox>(bar).color.a, closeTo(.2, .001));
      expect(tester.getRect(bar).height, 32);
      expect(tester.getTopLeft(find.byKey(const ValueKey('body'))).dy, 32);
      expect(find.byType(Opacity), findsNothing);
      // 左上角必须是应用图标（assets/images/app_icon.png），而不是通用
      // Material 音符字形——这是「Windows 端左上角没显示 app 图标」的回归守卫。
      final iconImage = find.descendant(
        of: bar,
        matching: find.byType(Image),
      );
      expect(iconImage, findsOneWidget);
      // cacheWidth 会把 AssetImage 包进 ResizeImage，断言时解包取内层。
      final provider = tester.widget<Image>(iconImage).image;
      final asset = provider is ResizeImage
          ? provider.imageProvider as AssetImage
          : provider as AssetImage;
      expect(asset.assetName, 'assets/images/app_icon.png');
      for (final action in ['minimize', 'toggleMaximize', 'closeWindow']) {
        final button = find.byKey(ValueKey('windows_$action'));
        expect(tester.getRect(button).size, const Size(46, 32));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(calls, contains(action));
      }
      expect(tooltip('还原'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('windows_toggleMaximize')));
      await tester.pumpAndSettle();
      expect(tooltip('最大化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, skip: !Platform.isWindows);
  }

  testWidgets('标题栏拖动与双击最大化都转给原生窗口', (tester) async {
    await pump(tester, const Size(900, 600));
    final drag = find.byKey(const ValueKey('windows_title_drag'));
    await tester.drag(drag, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(calls, contains('startDrag'));
    await tester.tap(drag);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(drag);
    await tester.pumpAndSettle();
    expect(calls, contains('toggleMaximize'));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('全屏时最大化键语义变为「退出全屏」', (tester) async {
    await pump(tester, const Size(900, 600));
    // 全屏（F11 / Zen）时原生侧去掉了窗口边框，标题栏里这枚键是鼠标用户
    // 唯一的退出入口，tooltip 必须点明。
    WindowsFullscreen.active.value = true;
    addTearDown(() => WindowsFullscreen.active.value = false);
    await tester.pumpAndSettle();
    expect(tooltip('退出全屏'), findsOneWidget);
    expect(tooltip('最大化'), findsNothing);
    expect(tooltip('还原'), findsNothing);
    // 标题栏仍在（它是全屏下的退出入口），三键也仍在。
    expect(find.byKey(const ValueKey('windows_title_bar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('windows_toggleMaximize')));
    await tester.pumpAndSettle();
    expect(calls, contains('toggleMaximize'));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('窄窗口三键保留且不溢出', (tester) async {
    await pump(tester, const Size(240, 160));
    expect(tooltip('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('窗口按钮保留键盘激活和按压反馈', (tester) async {
    await pump(tester, const Size(900, 600));
    final button = find.byKey(const ValueKey('windows_minimize'));
    final gesture = find.descendant(
      of: button,
      matching: find.byType(GestureDetector),
    );
    Focus.of(tester.element(gesture)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(calls.where((method) => method == 'minimize'), hasLength(2));
    final pointer = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 120));
    final feedback = find.descendant(
      of: button,
      matching: find.byType(ColoredBox),
    );
    expect(tester.widget<ColoredBox>(feedback).color.a, closeTo(.18, .005));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(calls.where((method) => method == 'minimize'), hasLength(3));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
