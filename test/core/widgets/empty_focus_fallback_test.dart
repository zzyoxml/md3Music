// 空焦点兜底（`core/widgets/empty_focus_fallback.dart`）的契约测试。
//
// ## 为什么必须钉在 widget 层
//
// 这条修复的全部价值在于「焦点链上有没有 widget」这个**运行时状态**：框架
// `FocusManager.handleKeyMessage` 在 `primaryFocus == null` 时直接丢事件，
// 在 `primaryFocus.context == null`（焦点停在 `rootScope`）时只走 rootScope 本身，
// 两种情况下挂在 `Focus` 上的键位层都收不到按键，而且不会自愈。
// 静态审查只能看出「兜底挂在哪」，看不出「它到底抢没抢」—— 抢错的表现是
// 后台回来输入框失焦、路由 scope 被顶掉这类**副作用**，只能靠用例守。
//
// ## 怎么复现「空焦点」
//
// 不是所有卸载都会留下空焦点：`FocusScopeNode._doRequestFocus` 在子节点被移除后
// 会让**父 scope 自己**请求焦点，于是 `primaryFocus` 退回路由的 `FocusScope`
// （它有真实 context，按键照样冒得出去）。真正留下空焦点的条件是
// **父 scope 也不可聚焦**（`canRequestFocus == false`）—— 对应真机上
// 「路由转场 / 拖拽手势进行中（`_ModalScopeState` 把 scope 的 canRequestFocus
// 置 false）时，持焦控件恰好被卸载」，此时框架 `applyFocusChangesIfNeeded` 会把
// 焦点退回 `rootScope` 并停在那里。下面用 `FocusScope(canRequestFocus: false)`
// 精确复现这条路径。
//
// 断言口径：
// - 「对照组」证明缺陷真实存在：**不挂**兜底时按键到不了任何 widget；
// - 「补位」：`primaryFocus.debugLabel == EmptyFocusFallback.debugLabel`，
//   并且随后按键能冒泡到最外层探针；
// - 「不抢」：`primaryFocus` 仍是原来的节点 / 路由 scope；
// - 「后台不抢」：`inactive` 期间焦点停在 rootScope（框架的挂起），`resumed` 后
//   必须还原到原节点 —— 兜底若在后台抢到焦点，框架的 `_suspendedNode` 还原会被吞。
//
// 平台口径：本组件与键位层同一门控（`isWindowsDesktop`），所以涉及生效的用例都挂
// `TargetPlatformVariant.only(TargetPlatform.windows)`；「非 Windows 不装」那条
// 故意**不加** variant（默认 android），断言的正是「不装」。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/widgets/empty_focus_fallback.dart';

final TargetPlatformVariant _windows =
    TargetPlatformVariant.only(TargetPlatform.windows);

/// 可摘的持焦控件页面。
///
/// 注意**不要**指望「前台卸载持焦控件」能复现空焦点：框架
/// （`FocusScopeNode._doRequestFocus`）会让父 scope 自己接手，`primaryFocus`
/// 退回路由的 `FocusScope`（有 context，按键照样冒得出去）。真正会留下空焦点的
/// 是「原焦点在 app 退到后台期间被销毁」——见 `emptyFocusThroughBackground()`
/// 那条路径，它与真机上「切窗口期间焦点控件被卸载，回窗口后键盘全哑」同构。
class _RemovableFocusPage extends StatefulWidget {
  const _RemovableFocusPage({super.key, required this.node});

  final FocusNode node;

  @override
  State<_RemovableFocusPage> createState() => _RemovableFocusPageState();
}

class _RemovableFocusPageState extends State<_RemovableFocusPage> {
  bool _mountedFocusable = true;

  void remove() => setState(() => _mountedFocusable = false);

  void restore() => setState(() => _mountedFocusable = true);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _mountedFocusable
        ? Focus(
            focusNode: widget.node,
            onKeyEvent: (_, _) => KeyEventResult.ignored,
            child: const SizedBox.expand(),
          )
        : const SizedBox.expand(),
  );
}

/// 树上是否挂着兜底 `Focus`（靠 debugLabel 认，不额外暴露测试专用字段）。
bool _isFallbackFocus(Widget widget) =>
    widget is Focus && widget.debugLabel == EmptyFocusFallback.debugLabel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 冒泡穿过兜底、到达最外层探针的按键（探针位置模拟 `DesktopInputLayer`）。
  late List<LogicalKeyboardKey> escaped;

  setUp(() {
    escaped = <LogicalKeyboardKey>[];
  });

  /// 宿主：外层探针（模拟 DesktopInputLayer）→ MaterialApp → 兜底 → 页面。
  /// 兜底挂在 builder 里，与 `DesktopPlaybackKeys` 内的真实位置同构。
  /// [withFallback] 为 false 时是「修复前」的对照组。
  Widget host(Widget home, {bool withFallback = true}) => Focus(
    canRequestFocus: false,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent) escaped.add(event.logicalKey);
      return KeyEventResult.ignored;
    },
    child: MaterialApp(
      builder: (context, child) =>
          withFallback ? EmptyFocusFallback(child: child!) : child!,
      home: home,
    ),
  );

  String? primaryLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  bool fallbackHoldsFocus() =>
      primaryLabel() == EmptyFocusFallback.debugLabel;

  /// 焦点链上已无 widget（`rootScope` 或 null）。
  bool noWidgetHasFocus() =>
      FocusManager.instance.primaryFocus?.context == null;

  /// 装一个「持焦控件可摘」的页面，返回页面 State（用于 remove / restore）。
  Future<_RemovableFocusPageState> pumpRemovable(
    WidgetTester tester,
    FocusNode node, {
    bool withFallback = true,
  }) async {
    final GlobalKey<_RemovableFocusPageState> key =
        GlobalKey<_RemovableFocusPageState>();
    await tester.pumpWidget(
      host(
        _RemovableFocusPage(key: key, node: node),
        withFallback: withFallback,
      ),
    );
    node.requestFocus();
    await tester.pump();
    return key.currentState!;
  }

  /// 把焦点「弄空」：先聚焦 → 退后台（框架挂起原焦点）→ 后台期间销毁该控件
  /// （`_markDetached` 顺手清掉挂起项）→ 回前台（无人可还原）。
  ///
  /// 这条路径是 `EmptyFocusFallback` 的 `didChangeAppLifecycleState` 钩子存在的
  /// 唯一理由：若只靠 `FocusManager` 监听，回前台后不再产生焦点变化事件，
  /// 焦点会永远停在 rootScope 上。
  Future<void> emptyFocusThroughBackground(
    WidgetTester tester,
    _RemovableFocusPageState page,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    page.remove();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  testWidgets('对照组：不挂兜底时，空焦点会让按键整层哑掉（缺陷本身）', (tester) async {
    final node = FocusNode(debugLabel: 'page/button');
    addTearDown(node.dispose);
    final page = await pumpRemovable(tester, node, withFallback: false);
    expect(FocusManager.instance.primaryFocus, same(node));

    await emptyFocusThroughBackground(tester, page);

    expect(
      noWidgetHasFocus(),
      isTrue,
      reason: '后台期间原焦点被销毁 → 回前台无人可还原，焦点停在 rootScope',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      escaped,
      isEmpty,
      reason: '空焦点时框架直接丢事件 —— 这就是「键位全哑」的现场',
    );
  }, variant: _windows);

  testWidgets('路由 scope 持焦时不抢（它不是空焦点）', (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: SizedBox.expand())));
    await tester.pumpAndSettle();

    // 推路由后 `_ModalScopeState.setFirstFocus` 让路由的 FocusScope 持焦：
    // 它有真实 context，按键本来冒得出去，兜底插进来只会顶掉用户焦点。
    expect(primaryLabel(), isNot(EmptyFocusFallback.debugLabel));
    expect(
      FocusManager.instance.primaryFocus?.context,
      isNotNull,
      reason: '路由 FocusScope 是挂在 _ModalScopeState 上的真实 widget',
    );
    // Windows 上兜底节点确实在树里（只是没抢焦点）。
    expect(find.byWidgetPredicate(_isFallbackFocus), findsOneWidget);
  }, variant: _windows);

  testWidgets('文本输入持焦时不抢', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(Scaffold(body: Center(child: TextField(controller: controller)))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(
      primaryLabel(),
      isNot(EmptyFocusFallback.debugLabel),
      reason: '输入框聚焦时兜底不得介入（否则光标、输入全废）',
    );
  }, variant: _windows);

  testWidgets('空焦点时补位，键位链恢复；有控件持焦时自动让位', (tester) async {
    final node = FocusNode(debugLabel: 'page/button');
    addTearDown(node.dispose);
    final page = await pumpRemovable(tester, node);
    expect(FocusManager.instance.primaryFocus, same(node));

    await emptyFocusThroughBackground(tester, page);
    expect(
      fallbackHoldsFocus(),
      isTrue,
      reason: '空焦点必须被兜底接管，否则按键连 widget 树都进不来',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      escaped,
      contains(LogicalKeyboardKey.space),
      reason: '补位后按键必须重新穿过 widget 链',
    );

    // 再次有控件持焦：兜底自动让位，不做常驻占位。
    page.restore();
    await tester.pumpAndSettle();
    node.requestFocus();
    await tester.pump();
    expect(primaryLabel(), 'page/button');
    expect(fallbackHoldsFocus(), isFalse);
  }, variant: _windows);

  testWidgets('后台（inactive）不抢，回前台还原原焦点', (tester) async {
    final node = FocusNode(debugLabel: 'page/search-field');
    addTearDown(node.dispose);

    await tester.pumpWidget(
      host(
        Scaffold(
          body: Focus(
            focusNode: node,
            onKeyEvent: (_, _) => KeyEventResult.ignored,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(node));

    // 退到后台：框架把原焦点挂起（primaryFocus 临时挪到 rootScope）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      fallbackHoldsFocus(),
      isFalse,
      reason: '后台期间一抢，框架的 _suspendedNode 还原就会被吞掉',
    );

    // 回前台：必须还原到原来的控件，而不是停在兜底上。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      same(node),
      reason: '回前台焦点要回到原控件（搜索框 / 按钮），兜底不得占位',
    );
  }, variant: _windows);

  testWidgets('非 Windows 不装兜底（Android / TV 焦点语义零变化）', (tester) async {
    final node = FocusNode(debugLabel: 'page/button');
    addTearDown(node.dispose);
    final page = await pumpRemovable(tester, node);
    expect(FocusManager.instance.primaryFocus, same(node));

    page.remove();
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(_isFallbackFocus),
      findsNothing,
      reason: '非 Windows 连节点都不该挂（多一个可聚焦节点会改 dpad 遍历与返回键行为）',
    );
    expect(fallbackHoldsFocus(), isFalse);
  });

  group('挂载位置（源码结构断言）', () {
    test('空焦点兜底必须挂在方向键层之内', () {
      // 兜底节点持焦时，冒泡链只经过它的**祖先**：兜底若挂在方向键层外面，
      // 方向键就永远到不了那一层（←/→ 变回焦点遍历），而外层空格 / Esc 却正常
      // —— 这种「只坏一半」的现象最容易查错方向。编译期与普通用例都不会报错。
      final String source = File(
        'lib/core/widgets/desktop_playback_keys.dart',
      ).readAsStringSync();
      final int layerIndex = source.indexOf(
        "debugLabel: 'desktop/playback-keys'",
      );
      final int fallbackIndex = source.indexOf('EmptyFocusFallback(');

      expect(layerIndex, greaterThanOrEqualTo(0));
      expect(fallbackIndex, greaterThan(layerIndex), reason: '兜底必须在方向键层之内');
      expect(
        source.contains('child: EmptyFocusFallback(child: child)'),
        isTrue,
        reason: '兜底必须包住 child（放在兄弟位置不进入焦点链）',
      );
    });
  });
}
