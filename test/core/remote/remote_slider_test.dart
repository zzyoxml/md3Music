// RemoteSlider 按键行为测试（TV D-pad 契约）。
//
// 契约（见 lib/core/remote/remote_slider.dart 的类注释）：
//   遥控开启 → 子树覆盖为 NavigationMode.directional
//            → 左右键调值（Slider 内置映射消费），上下键**放行**给焦点遍历
//            → D-pad 能自然移出滑块（否则「返回不了」）。
//   遥控关闭（仅非 TV 构建语义）→ 原样返回 Slider（traditional 导航模式）
//            → 四个方向键全部调值，焦点锁在滑块上（触屏行为零变化）。
//   TV 构建（kTvBuild）→ **无视三态开关、恒走 directional**：Dpad.wrap 在
//            _tvContentScope 无条件安装，滑杆保护必须与遍历引擎同开关，
//            否则判非 TV/启动窗口/always_off 时上下键困死焦点
//            （2026-10-07 修复，与 TvFocusHighlight 同一教训）。
//
// 用法备注：Slider 的焦点节点由其内部创建，外部拿不到，故 RemoteSlider
// 增加了可选的 focusNode 透传，测试借此 requestFocus 后 sendKeyEvent。
//
// 上下键放行的断言需要一个「可去的邻居」，否则遍历无处可去、焦点会留在
// 滑块上（此时断言 hasFocus == false 断言的是遍历失败而非契约生效）。
// 因此测试骨架在滑块上下各放一个裸 Focus 节点作为遍历落点。
//
// kTvBuild 是编译期常量（普通 flutter test 里恒 false），TV 契约用例与
// 非 TV 契约用例用 skip 互斥：TV 契约需单跑
//   flutter test test/core/remote/remote_slider_test.dart --dart-define=MD3_TV=true

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/remote/remote_slider.dart';
import 'package:md3music/providers/remote_control_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _deviceFormChannel =
    MethodChannel('com.md3music.md3music/device_form');

/// 新测试里不需要读回调值，给个空实现即可。
void _noop(double value) {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceFormChannel, null);
  });

  /// 构造一个已恢复完成的 RemoteControlProvider。
  ///
  /// [isTv] 为 true 时 mock `isTv` → true（auto 模式判定为 TV 设备 → enabled）；
  /// 为 false 时 mock 通道抛 MissingPluginException（等价于正常构建的未实现通道）
  /// → 判定非 TV → enabled == false。
  Future<RemoteControlProvider> makeProvider({required bool isTv}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceFormChannel, (MethodCall call) async {
      if (call.method == 'isTv') {
        if (!isTv) {
          throw MissingPluginException('未实现 device_form 通道');
        }
        return true;
      }
      return null;
    });
    final RemoteControlProvider provider = RemoteControlProvider();
    await provider.restored;
    return provider;
  }

  /// 挂起一棵 [RemoteSlider] + 上下两个遍历落点的最小树。
  Future<void> pumpHarness(
    WidgetTester tester, {
    required RemoteControlProvider provider,
    required FocusNode sliderNode,
    required FocusNode aboveNode,
    required FocusNode belowNode,
    required ValueChanged<double> onChanged,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<RemoteControlProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Focus(
                      focusNode: aboveNode,
                      child: const SizedBox(
                        height: 24,
                        width: double.infinity,
                      ),
                    ),
                    RemoteSlider(
                      value: 0.5,
                      onChanged: onChanged,
                      focusNode: sliderNode,
                    ),
                    Focus(
                      focusNode: belowNode,
                      child: const SizedBox(
                        height: 24,
                        width: double.infinity,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 回归：设置页所有滑杆整片显示「此处内容加载出错」。
  //
  // 根因是 Flutter 的 `Slider.build` 有 `assert(debugCheckHasMaterial(context))`
  // （slider.dart:807），而本仓 UI 走 material_ui —— 它的 `Scaffold` 包的是
  // **material_ui 自己的** `Material`，与 Flutter 的 `Material` 不是一个类型，
  // `findAncestorWidgetOfExactType<Material>` 取不到。调试包里断言直接抛
  // FlutterError，被全局 `_FallbackErrorWidget` 顶成错误占位。
  //
  // 这里刻意**不放 Scaffold**（Flutter 的 Scaffold 会补一层自家 Material，
  // 放了就复现不出来），用 `MaterialApp` + 裸子树还原真实挂载条件。
  testWidgets('无 Flutter Material 祖先时不抛 debugCheckHasMaterial', (tester) async {
    final RemoteControlProvider provider = await makeProvider(isTv: true);

    await tester.pumpWidget(
      ChangeNotifierProvider<RemoteControlProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 320,
              child: RemoteSlider(value: 0.3, onChanged: _noop),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.takeException(),
      isNull,
      reason: 'RemoteSlider 必须自带 Material 祖先，否则调试包整片渲染成错误占位',
    );
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('遥控开启（directional）：左右键调值、焦点保留', (tester) async {
    final RemoteControlProvider provider = await makeProvider(isTv: true);
    expect(provider.enabled, isTrue, reason: 'mock isTv=true 时应开启遥控模式');

    final FocusNode sliderNode = FocusNode(debugLabel: 'slider');
    final FocusNode aboveNode = FocusNode(debugLabel: 'above');
    final FocusNode belowNode = FocusNode(debugLabel: 'below');
    addTearDown(sliderNode.dispose);
    addTearDown(aboveNode.dispose);
    addTearDown(belowNode.dispose);

    double? changed;
    await pumpHarness(
      tester,
      provider: provider,
      sliderNode: sliderNode,
      aboveNode: aboveNode,
      belowNode: belowNode,
      onChanged: (double v) => changed = v,
    );

    sliderNode.requestFocus();
    await tester.pump();
    expect(sliderNode.hasFocus, isTrue, reason: '前置条件：焦点已落在滑块上');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(changed, isNotNull, reason: 'directional 下左右键仍应调值');
    expect(changed!, lessThan(0.5));
    expect(sliderNode.hasFocus, isTrue, reason: '左右键被滑块消费，焦点不外移');
  });

  testWidgets('遥控开启（directional）：上下键放行（不改值、焦点移出滑块）',
      (tester) async {
    final RemoteControlProvider provider = await makeProvider(isTv: true);
    expect(provider.enabled, isTrue);

    final FocusNode sliderNode = FocusNode(debugLabel: 'slider');
    final FocusNode aboveNode = FocusNode(debugLabel: 'above');
    final FocusNode belowNode = FocusNode(debugLabel: 'below');
    addTearDown(sliderNode.dispose);
    addTearDown(aboveNode.dispose);
    addTearDown(belowNode.dispose);

    double? changed;
    await pumpHarness(
      tester,
      provider: provider,
      sliderNode: sliderNode,
      aboveNode: aboveNode,
      belowNode: belowNode,
      onChanged: (double v) => changed = v,
    );

    sliderNode.requestFocus();
    await tester.pump();
    expect(sliderNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(changed, isNull, reason: 'directional 下上下键不得被滑块当调值消费');
    expect(sliderNode.hasFocus, isFalse, reason: '上下键应放行给焦点遍历，移出滑块');
    expect(
      aboveNode.hasFocus || belowNode.hasFocus,
      isTrue,
      reason: '焦点应落在遍历落点上（而非无处可去地留在滑块上）',
    );
  });

  // 本用例钉的是**非 TV**语义（traditional 退路）；TV 构建下滑杆恒走
  // directional，它必然失败，故按编译期旗标互斥跳过（skip 只收 bool，
  // 原因写在文件头契约注释里）。
  testWidgets('非 TV 构建遥控关闭：恢复原生 Slider（上下键也调值、焦点不外移）',
      (tester) async {
    final RemoteControlProvider provider = await makeProvider(isTv: false);
    expect(provider.enabled, isFalse,
        reason: '通道未实现（检测失败）时按非 TV 处理，不开遥控模式');

    final FocusNode sliderNode = FocusNode(debugLabel: 'slider');
    final FocusNode aboveNode = FocusNode(debugLabel: 'above');
    final FocusNode belowNode = FocusNode(debugLabel: 'below');
    addTearDown(sliderNode.dispose);
    addTearDown(aboveNode.dispose);
    addTearDown(belowNode.dispose);

    double? changed;
    await pumpHarness(
      tester,
      provider: provider,
      sliderNode: sliderNode,
      aboveNode: aboveNode,
      belowNode: belowNode,
      onChanged: (double v) => changed = v,
    );

    sliderNode.requestFocus();
    await tester.pump();
    expect(sliderNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(changed, isNotNull, reason: 'traditional 导航下四方向键全部调值');
    expect(changed!, greaterThan(0.5));
    expect(sliderNode.hasFocus, isTrue, reason: '原生行为：焦点锁在滑块上');
  }, skip: kTvBuild);

  // 回归：2026-10-07「TV 版滑杆按上下键变成调值、焦点无法逃逸」。
  //
  // 根因是 directional 覆盖被 RemoteControlProvider.enabled 门控，而 TV
  // 构建的 Dpad.wrap 无条件安装：设备形态判定失败（uiModeManager 不报
  // TELEVISION 的盒子/投影）、启动异步初始化窗口期、或用户选 always_off
  // 时，滑杆退回 traditional（四方向键全调值），上下键把焦点困死在滑块上。
  // 修复后 kTvBuild 下恒走 directional，provider 判什么都一样。
  //
  // 仅在 --dart-define=MD3_TV=true 单跑本文件时执行（kTvBuild 为编译期常量）。
  testWidgets('TV 构建：provider 判非 TV（enabled=false）时上下键仍放行',
      (tester) async {
    // 判非 TV：通道抛 MissingPluginException → enabled == false。
    // 修复前这会让滑杆退回 traditional、上下键困死焦点；修复后不受影响。
    final RemoteControlProvider provider = await makeProvider(isTv: false);
    expect(provider.enabled, isFalse,
        reason: '前置条件：provider 判非 TV（正是线上触发面之一）');

    final FocusNode sliderNode = FocusNode(debugLabel: 'slider');
    final FocusNode aboveNode = FocusNode(debugLabel: 'above');
    final FocusNode belowNode = FocusNode(debugLabel: 'below');
    addTearDown(sliderNode.dispose);
    addTearDown(aboveNode.dispose);
    addTearDown(belowNode.dispose);

    double? changed;
    await pumpHarness(
      tester,
      provider: provider,
      sliderNode: sliderNode,
      aboveNode: aboveNode,
      belowNode: belowNode,
      onChanged: (double v) => changed = v,
    );

    sliderNode.requestFocus();
    await tester.pump();
    expect(sliderNode.hasFocus, isTrue, reason: '前置条件：焦点已落在滑块上');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(changed, isNull,
        reason: 'TV 构建恒 directional：上下键不得被滑块当调值消费');
    expect(sliderNode.hasFocus, isFalse,
        reason: '上下键放行给焦点遍历，焦点必须能移出滑块');
    expect(
      aboveNode.hasFocus || belowNode.hasFocus,
      isTrue,
      reason: '焦点应落在遍历落点上（而非无处可去地留在滑块上）',
    );
  }, skip: !kTvBuild);
}