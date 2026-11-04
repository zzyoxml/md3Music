import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/services/windows_fullscreen.dart';
import 'package:md3music/core/services/windows_window_controls.dart';
import 'package:md3music/core/widgets/windows_caption_buttons.dart';

/// Windows 窗口三键组（标题栏与播放页顶栏共用）的行为契约。
///
/// 播放页右上角的三键与 `windows/window_tray` 通道直连，视觉与命中区必须与
/// 32dp 系统标题栏完全一致（46×32、悬停/按压反馈、键盘激活、全屏语义），
/// 外加 Win11 snap layouts 的接管契约（矩形上报 / 接管广播 / 原生指针回传）。
///
/// 服务层（[WindowsWindowControls]）按 `defaultTargetPlatform` 门控（AGENTS
/// W3 口径），测试里默认 android 会把上报短路；每个用例带
/// `TargetPlatformVariant.only(windows)`（`pump` 助手已统一施加）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');
  final calls = <MethodCall>[];
  var maximized = false;
  // true = 模拟原生接受登记（非全屏、id 有效）。默认 false：接管类用例
  // 不依赖登记成功，既有三键契约保持原语义。
  var acceptRectRegistration = false;

  final TargetPlatformVariant windowsVariant =
      TargetPlatformVariant.only(TargetPlatform.windows);

  Finder tooltip(String label) => find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == label,
  );

  MethodCall callFor(String method) =>
      calls.lastWhere((call) => call.method == method);

  setUp(() {
    calls.clear();
    maximized = false;
    acceptRectRegistration = false;
    WindowsFullscreen.active.value = false;
    WindowsWindowControls.maxButtonOwner.value = '';
    WindowsWindowControls.maxButtonPointer.value =
        const WindowsCaptionPointerState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setCaptionMaxButtonRect') {
            // 模拟原生「单槽 + 广播」：接受后把活动行 id 广播回 Dart。
            if (!acceptRectRegistration) return false;
            final id = (call.arguments as Map)['id'] as String;
            WindowsWindowControls.handleNativeCall(
                MethodCall('onCaptionMaxTakeover', id));
            return true;
          }
          if (call.method == 'clearCaptionMaxButtonRect') {
            WindowsWindowControls.handleNativeCall(
                const MethodCall('onCaptionMaxTakeover', ''));
            return true;
          }
          if (call.method == 'toggleMaximize') maximized = !maximized;
          return maximized;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    WindowsFullscreen.active.value = false;
    // 展开进度是进程级单例，不复位会污染后续用例的几何真值。
    PlayerPanelSignal.expansion.value = 0.0;
    WindowsWindowControls.maxButtonOwner.value = '';
    WindowsWindowControls.maxButtonPointer.value =
        const WindowsCaptionPointerState();
  });

  Future<void> pump(WidgetTester tester, {String prefix = 'player_window'}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: WindowsCaptionButtonRow(keyPrefix: prefix),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三键几何与标题栏一致，且按前缀区分挂载点', (tester) async {
    await pump(tester);
    for (final action in ['minimize', 'toggleMaximize', 'closeWindow']) {
      final button = find.byKey(ValueKey('player_window_$action'));
      expect(button, findsOneWidget, reason: '缺少 $action');
      expect(tester.getRect(button).size, const Size(46, 32));
    }
    expect(tooltip('最小化'), findsOneWidget);
    expect(tooltip('关闭'), findsOneWidget);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('点击三键分别发通道调用，最大化后形态切为「还原」', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('player_window_minimize')));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('minimize'));

    expect(tooltip('最大化'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player_window_toggleMaximize')));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('toggleMaximize'));
    expect(tooltip('还原'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player_window_closeWindow')));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('closeWindow'));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('全屏时最大化键语义变为「退出全屏」', (tester) async {
    await pump(tester);
    WindowsFullscreen.active.value = true;
    await tester.pumpAndSettle();
    expect(tooltip('退出全屏'), findsOneWidget);
    expect(tooltip('最大化'), findsNothing);
    expect(tooltip('还原'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player_window_toggleMaximize')));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('toggleMaximize'));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('播放页顶栏形态：48 高三键贴住右上角', (tester) async {
    const height = 48.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Center(
          child: SizedBox(
            key: const ValueKey('flush_box'),
            width: 300,
            height: height,
            child: Align(
              alignment: Alignment.centerRight,
              child: WindowsCaptionButtonRow(
                keyPrefix: 'flush',
                height: height,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byKey(const ValueKey('flush_box')));
    for (final action in ['minimize', 'toggleMaximize', 'closeWindow']) {
      final rect = tester.getRect(find.byKey(ValueKey('flush_$action')));
      expect(rect.height, height, reason: '$action 未填满顶栏行高');
      expect(rect.top, box.top, reason: '$action 未贴住上沿');
    }
    final close = tester.getRect(find.byKey(const ValueKey('flush_closeWindow')));
    expect(close.right, box.right, reason: '关闭键未贴住右缘');
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  // ---- Win11 snap layouts 接管契约 ----

  testWidgets('登记被接受时上报最大化键矩形，坐标按 dpr 换成物理像素', (tester) async {
    acceptRectRegistration = true;
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester);
    await tester.pumpAndSettle();

    final call = callFor('setCaptionMaxButtonRect');
    final args = call.arguments as Map;
    expect(args['id'], isA<String>());
    // widget 测试里 getRect 的全局坐标就是窗口坐标（客户区原点=窗口原点）；
    // 断言上报值 = 逻辑矩形 × dpr，且宽高还原为 46×32 命中区。
    final button =
        tester.getRect(find.byKey(const ValueKey('player_window_toggleMaximize')));
    expect(args['left'], (button.left * 1.5).round());
    expect(args['top'], (button.top * 1.5).round());
    expect(args['right'] - args['left'], (46 * 1.5).round());
    expect(args['bottom'] - args['top'], (32 * 1.5).round());
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('接管态：最大化键撤下 Tooltip，最小化 / 关闭保留', (tester) async {
    acceptRectRegistration = true;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(tooltip('最大化'), findsNothing, reason: '接管点是非客户区，Tooltip 永不触发');
    expect(tooltip('最小化'), findsOneWidget);
    expect(tooltip('关闭'), findsOneWidget);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('未接管（原生拒绝登记）时最大化键保留 Tooltip', (tester) async {
    acceptRectRegistration = false;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(tooltip('最大化'), findsOneWidget);
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('原生回传 hovered 驱动最大化键高亮', (tester) async {
    acceptRectRegistration = true;
    await pump(tester);
    await tester.pumpAndSettle();

    Color? fill() {
      final box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(const ValueKey('player_window_toggleMaximize')),
          matching: find.byType(ColoredBox),
        ),
      );
      return box.color;
    }

    expect(fill()!.a, 0, reason: '默认无底色');
    WindowsWindowControls.handleNativeCall(const MethodCall(
        'onCaptionMaxPointerState', {'hovered': true, 'pressed': false}));
    await tester.pump();
    expect(fill()!.a, greaterThan(0), reason: '原生悬停必须点亮高亮');

    WindowsWindowControls.handleNativeCall(const MethodCall(
        'onCaptionMaxPointerState', {'hovered': false, 'pressed': false}));
    await tester.pump();
    expect(fill()!.a, 0, reason: '离开后高亮收回');
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('全屏时不登记：进全屏撤销、退全屏重新登记', (tester) async {
    acceptRectRegistration = true;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('setCaptionMaxButtonRect'));

    calls.clear();
    WindowsFullscreen.active.value = true;
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('clearCaptionMaxButtonRect'));
    expect(tooltip('退出全屏'), findsOneWidget);

    calls.clear();
    WindowsFullscreen.active.value = false;
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('setCaptionMaxButtonRect'),
        reason: '退出全屏必须重新接管，否则鼠标用户失去 snap 入口');
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('行销毁时撤销登记（迟到的撤销按 id 只撤自己）', (tester) async {
    acceptRectRegistration = true;
    await pump(tester);
    await tester.pumpAndSettle();
    final registeredId =
        (callFor('setCaptionMaxButtonRect').arguments as Map)['id'] as String;

    calls.clear();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await tester.pumpAndSettle();
    final clear = callFor('clearCaptionMaxButtonRect');
    expect((clear.arguments as Map)['id'], registeredId);
    expect(WindowsWindowControls.maxButtonOwner.value, '');
  }, skip: !Platform.isWindows, variant: windowsVariant);

  // ---- 播放页展开动画期间的几何真值（回归「上半部无反应」）----

  /// 宿主：用帧驱动的 `Transform.translate` 把三键行整体下移（`0` = 落点、
  /// `1` = 展开途中偏下），**模拟真实播放页的 `AnimatedBuilder` 场景**——
  /// 几何逐帧变化但本行不被重建，因此只能靠帧驱动校验纠正登记。
  Widget animatedHost(ValueNotifier<double> progress) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, value, child) => Transform.translate(
                offset: Offset(0, 40 * value),
                child: child,
              ),
              child: const WindowsCaptionButtonRow(keyPrefix: 'player_window'),
            ),
          ),
        ),
      );

  testWidgets('展开进度变化后重报矩形，且 top 与按钮真值一致', (tester) async {
    acceptRectRegistration = true;
    final progress = ValueNotifier<double>(1.0);
    addTearDown(progress.dispose);
    // 首帧按「动画途中」的偏下坐标登记。
    await tester.pumpWidget(animatedHost(progress));
    await tester.pumpAndSettle();
    expect(callFor('setCaptionMaxButtonRect'), isNotNull);

    calls.clear();
    // 落点：偏移归零（帧驱动，不重建本行）+ 展开进度写 1.0。
    progress.value = 0.0;
    PlayerPanelSignal.expansion.value = 1.0;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final args = callFor('setCaptionMaxButtonRect').arguments as Map;
    final button =
        tester.getRect(find.byKey(const ValueKey('player_window_toggleMaximize')));
    final dpr = tester.view.devicePixelRatio;
    expect(args['top'], (button.top * dpr).round(),
        reason: '重报必须用落点真值，不能停留在动画中途的偏下坐标');
    expect(args['left'], (button.left * dpr).round());
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('几何没变就不重复上报（去重生效）', (tester) async {
    acceptRectRegistration = true;
    final progress = ValueNotifier<double>(0.0);
    addTearDown(progress.dispose);
    await tester.pumpWidget(animatedHost(progress));
    await tester.pumpAndSettle();
    calls.clear();

    PlayerPanelSignal.expansion.value = 0.5;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 几何完全没动（偏移恒 0），进度抖动不应产生新上报。
    expect(calls.where((c) => c.method == 'setCaptionMaxButtonRect').length, 0,
        reason: '几何未变时重复上报会白白打通道、并可能引起 build 循环');
  }, skip: !Platform.isWindows, variant: windowsVariant);

  testWidgets('动画中途的错位不会被固化（哨兵：删掉帧驱动必失败）', (tester) async {
    acceptRectRegistration = true;
    final progress = ValueNotifier<double>(1.0);
    addTearDown(progress.dispose);
    // 首帧按偏下中途坐标登记 —— 正是真机被固化的那个错值。
    await tester.pumpWidget(animatedHost(progress));
    await tester.pumpAndSettle();
    final midTop =
        (callFor('setCaptionMaxButtonRect').arguments as Map)['top'] as int;

    calls.clear();
    // 落点：只改动画值，不重建本行。没有帧驱动校验的话登记会永远停在偏下值，
    // 真机表现即「按钮上半部落在登记区外 → 悬停无反应」。
    progress.value = 0.0;
    PlayerPanelSignal.expansion.value = 1.0;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final fixedTop =
        (callFor('setCaptionMaxButtonRect').arguments as Map)['top'] as int;
    expect(fixedTop, lessThan(midTop), reason: '落点真值比中途坐标更靠上，必须被纠正');
    final button =
        tester.getRect(find.byKey(const ValueKey('player_window_toggleMaximize')));
    expect(fixedTop, (button.top * tester.view.devicePixelRatio).round());
  }, skip: !Platform.isWindows, variant: windowsVariant);
}
