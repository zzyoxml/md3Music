import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/tv_nav_focus_bridge.dart';

/// tv: 焦点跨 FocusScope 的边界条件与桥接机制（回归测试）。
///
/// 2026-10-04 真机问题：tab 内容区包在自己的 Navigator（= FocusScope）里，
/// 主导航栏是它的兄弟节点；dpad 收集候选用
/// `currentNode.nearestScope.traversalDescendants`，**取不到 scope 外的兄弟**，
/// 于是焦点走到内容区左边缘后左键完全失效，永远跳不到导航栏。
///
/// 本测试把该现象固化成两条断言：
/// 1. 边界确实存在（有 FocusScope 时焦点出不去）——记录前提，防止再次误判为接线问题；
/// 2. [TvNavFocusBridge] 的显式移交有效（stop + onEdge 能把焦点送到导航栏）。
void main() {
  testWidgets('前提：焦点无法自动跨出 FocusScope（dpad 候选收集受限）', (
    tester,
  ) async {
    final inside = FocusNode(debugLabel: 'inside');
    final outside = FocusNode(debugLabel: 'outside');
    final scopeNode = FocusScopeNode(debugLabel: 'tab-scope');
    addTearDown(inside.dispose);
    addTearDown(outside.dispose);
    addTearDown(scopeNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Scaffold(
          body: Row(
            children: [
              DpadFocusable(
                focusNode: outside,
                debugLabel: 'nav-item',
                onSelect: () {},
                child: const SizedBox(width: 80, height: 80),
              ),
              FocusScope(
                node: scopeNode,
                child: DpadRegion(
                  memoryKey: 'probe-scope',
                  child: Center(
                    child: DpadFocusable(
                      focusNode: inside,
                      debugLabel: 'content-item',
                      onSelect: () {},
                      child: const SizedBox(width: 80, height: 80),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    inside.requestFocus();
    await tester.pumpAndSettle();
    expect(inside.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    // 焦点应仍留在 scope 内——这正是真机 bug 的成因。
    expect(
      outside.hasFocus,
      isFalse,
      reason: 'dpad 不跨 FocusScope 收集候选，导航栏不可自动到达',
    );
    expect(inside.hasFocus, isTrue);
  });

  testWidgets('桥接：stop + onEdge 经 TvNavFocusBridge 把焦点交给导航栏', (
    tester,
  ) async {
    final inside = FocusNode(debugLabel: 'inside');
    final navNode = FocusNode(debugLabel: 'nav-0');
    final scopeNode = FocusScopeNode(debugLabel: 'tab-scope');
    addTearDown(inside.dispose);
    addTearDown(navNode.dispose);
    addTearDown(scopeNode.dispose);

    var bridged = false;

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Scaffold(
          body: Row(
            children: [
              DpadFocusable(
                focusNode: navNode,
                debugLabel: 'nav-item',
                onSelect: () {},
                child: const SizedBox(width: 80, height: 80),
              ),
              FocusScope(
                node: scopeNode,
                child: DpadRegion(
                  memoryKey: 'probe-bridge',
                  horizontalEdge: DpadEdgeBehavior.stop,
                  onEdge: (direction) {
                    if (direction != TraversalDirection.left) return;
                    bridged = TvNavFocusBridge.instance.focusNavItem(0);
                  },
                  child: Center(
                    child: DpadFocusable(
                      focusNode: inside,
                      debugLabel: 'content-item',
                      onSelect: () {},
                      child: const SizedBox(width: 80, height: 80),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 模拟布局层行为：导航项构建时把节点登记到桥
    TvNavFocusBridge.instance.register(0, navNode);

    inside.requestFocus();
    await tester.pumpAndSettle();
    expect(inside.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    // requestFocus 在微任务里生效，再等一帧确认
    await tester.pump();
    await tester.pumpAndSettle();

    expect(bridged, isTrue, reason: '边缘事件应触发桥接移交');
    expect(navNode.hasFocus, isTrue, reason: '桥接后焦点应落在导航项上');
  });
}
