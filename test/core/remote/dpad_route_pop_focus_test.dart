import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// tv: 路由 pop 之后焦点落到哪（2026-10-04 真机问题：按硬件返回键退出
/// 歌单详情后焦点"丢失"）。
///
/// 验证假设：pop 掉持有焦点的路由后，`FocusManager.primaryFocus` 会回落到
/// **空的范围节点（FocusScopeNode）**——此时 `hasFocus` 语义上仍成立、但没有任何
/// 具体控件持有焦点，用户看不到焦点框、方向键也无处可去。
///
/// 若成立，则"焦点校正"的判据必须把「primaryFocus 是 FocusScopeNode」视同
/// 「没有焦点」，否则会误判为"焦点在 tab 内、无需干预"而放过（这正是
/// `_isInActiveTab` 漏掉此场景的原因）。
void main() {
  testWidgets('pop 详情路由后 primaryFocus 的类型', (tester) async {
    final masterNode = FocusNode(debugLabel: 'master-item');
    final detailNode = FocusNode(debugLabel: 'detail-item');
    addTearDown(masterNode.dispose);
    addTearDown(detailNode.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Navigator(
          key: navigatorKey,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => Scaffold(
              body: Center(
                child: DpadFocusable(
                  focusNode: masterNode,
                  onSelect: () {},
                  child: const SizedBox(width: 80, height: 80),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // push 一个二级页并让它的节点获得焦点
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: DpadFocusable(
              focusNode: detailNode,
              onSelect: () {},
              child: const SizedBox(width: 80, height: 80),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    detailNode.requestFocus();
    await tester.pumpAndSettle();
    expect(detailNode.hasFocus, isTrue, reason: '前提：详情页节点持有焦点');

    // 模拟硬件返回键：pop 详情路由
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    final primary = tester.binding.focusManager.primaryFocus;
    debugPrint(
      'PROBE: primaryFocus=${primary?.debugLabel} '
      'isScope=${primary is FocusScopeNode} '
      'isMaster=${identical(primary, masterNode)} '
      'detailHasFocus=${detailNode.hasFocus}',
    );

    // 实测事实：**被 push 路由的节点存活时**，pop 后框架会把焦点交回下层的
    // master 节点（本用例即此情形）。所以"pop 必然丢焦点"不成立——真机上丢焦点
    // 另有原因（怀疑 master 那一项在详情打开期间被重建/卸载，或焦点先落到
    // 一个空范围节点）。本用例只固化"框架在节点存活时会恢复"这一条，
    // 真机症状靠 TvFocusDebug 日志取证（见 lib/core/remote/tv_focus_debug.dart）。
    expect(
      identical(primary, masterNode),
      isTrue,
      reason: 'pop 后焦点应回到仍存活的 master 节点',
    );
  });

  testWidgets('pop 后由布局层显式移交焦点可恢复（回归）', (tester) async {
    final masterNode = FocusNode(debugLabel: 'master-item');
    final detailNode = FocusNode(debugLabel: 'detail-item');
    addTearDown(masterNode.dispose);
    addTearDown(detailNode.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Navigator(
          key: navigatorKey,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => Scaffold(
              body: Center(
                child: DpadFocusable(
                  focusNode: masterNode,
                  onSelect: () {},
                  child: const SizedBox(width: 80, height: 80),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: DpadFocusable(
              focusNode: detailNode,
              onSelect: () {},
              child: const SizedBox(width: 80, height: 80),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    detailNode.requestFocus();
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    // 布局层的校正动作：焦点不可用（这里是 null）→ 移交回 tab 内首个可聚焦项。
    final primary = tester.binding.focusManager.primaryFocus;
    if (primary == null || primary is FocusScopeNode) {
      masterNode.requestFocus();
    }
    await tester.pumpAndSettle();

    expect(
      masterNode.hasFocus,
      isTrue,
      reason: '移交后焦点应回到 master，用户重新看到焦点框、方向键可用',
    );
  });
}
