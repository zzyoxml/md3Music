import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// tv: 切 tab 时焦点丢失的复现与验证（2026-10-04 真机问题）。
///
/// 现象：① 首次进入某个 tab（如「我的收藏」双列网格）焦点丢失；
/// ② 从二级页（歌单详情）返回 tab 后焦点丢失。
///
/// 根因（实测）：`ExcludeFocus` 只**不转发事件**，被排除子树里的节点仍保持
/// `hasFocus == true`。tab 切换时旧 tab 被排除，焦点就**冻结在看不见的旧 tab
/// 节点上**——新 tab 表现为"丢失焦点"，且后续按键全打到旧 tab 上、毫无反应。
/// 首次进入更明显：新 tab 首帧还是 `SizedBox.shrink()`（`_visited` 未含该 id），
/// 其 region 从未记录焦点位（`_lastFocusedRect` 为 null，`region.dart:293`），
/// dpad 的 `DpadEnterBehavior.restore` 三级兜底全部落空。
///
/// 结论：切 tab 后必须**显式把焦点移交到新 tab**，不能指望 dpad 自动恢复。
void main() {
  testWidgets('首次进入 region（无记忆位）时 restore 会落空', (tester) async {
    final tabA = FocusNode(debugLabel: 'tabA');
    final tabB = FocusNode(debugLabel: 'tabB');
    addTearDown(tabA.dispose);
    addTearDown(tabB.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Column(
          children: [
            DpadRegion(
              memoryKey: 'tab-A',
              child: DpadFocusable(
                focusNode: tabA,
                onSelect: () {},
                child: const SizedBox(width: 60, height: 40),
              ),
            ),
            // 模拟 ExcludeFocus 隔离的旧 tab
            ExcludeFocus(
              excluding: true,
              child: DpadRegion(
                memoryKey: 'tab-B',
                child: DpadFocusable(
                  focusNode: tabB,
                  onSelect: () {},
                  child: const SizedBox(width: 60, height: 40),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 焦点在 tabA，tabB 从未获得过焦点 → 其 region 无记忆位
    tabA.requestFocus();
    await tester.pumpAndSettle();
    expect(tabA.hasFocus, isTrue);

    // 模拟「切到 tabB」：解除排除后，tabB 区域可被遍历到
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Column(
          children: [
            ExcludeFocus(
              excluding: true,
              child: DpadRegion(
                memoryKey: 'tab-A',
                child: DpadFocusable(
                  focusNode: tabA,
                  onSelect: () {},
                  child: const SizedBox(width: 60, height: 40),
                ),
              ),
            ),
            DpadRegion(
              memoryKey: 'tab-B',
              child: DpadFocusable(
                focusNode: tabB,
                onSelect: () {},
                child: const SizedBox(width: 60, height: 40),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    debugPrint('PROBE: tabAHasFocus=${tabA.hasFocus} tabBHasFocus=${tabB.hasFocus}');

    // 实测（2026-10-04）：Flutter 的 ExcludeFocus 只是**不转发事件**，
    // 节点仍保持 hasFocus=true。所以焦点不是"丢失"，而是**冻结在被排除的
    // 旧 tab 节点上**——新 tab 看起来没有焦点，且按键全部打到旧 tab 上（无效）。
    expect(
      tabA.hasFocus,
      isTrue,
      reason: '前提：焦点冻结在 ExcludeFocus 排除掉的旧 tab 节点上',
    );
    expect(tabB.hasFocus, isFalse, reason: '新 tab 未获得焦点');
  });

  testWidgets('切 tab 后显式移交焦点可恢复可用性', (tester) async {
    final tabB = FocusNode(debugLabel: 'tabB');
    addTearDown(tabB.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: DpadRegion(
          memoryKey: 'tab-B',
          child: DpadFocusable(
            focusNode: tabB,
            onSelect: () {},
            child: const SizedBox(width: 60, height: 40),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 模拟布局层在切 tab 后的显式移交
    tabB.requestFocus();
    await tester.pumpAndSettle();

    expect(tabB.hasFocus, isTrue, reason: '显式 requestFocus 后焦点应落位');
    // 移交后方向键应能继续在区域内移动
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.binding.focusManager.primaryFocus, isNotNull);
  });
}
