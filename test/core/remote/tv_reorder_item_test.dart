// TvReorderItem 行为契约测试：单停点 + 排序方向键接线。
//
// 组件自身不依赖 kTvBuild（AGENTS §12 惯例），调用方门控；测试按 Dpad 拓扑
// 搭建，OK 键用 LogicalKeyboardKey.select（dpad DpadKeySet.select 默认含它）。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_reorder.dart';

class _Log {
  final List<String> toasts = <String>[];
  final List<(int, int)> reorders = <(int, int)>[];
  int selects = 0;

  /// onReorder 出口（两参 → record，签名须与 TvReorderController.onReorder 一致）。
  void reorder(int oldIndex, int newIndex) => reorders.add((oldIndex, newIndex));

  /// onToast 出口（签名须与 TvReorderController.onToast 一致：带命名参数 long）。
  void toast(String msg, {bool long = false}) => toasts.add(msg);
}

void main() {
  testWidgets('左键拿起、上下键移动、OK 放下；未拿起时方向键放行', (tester) async {
    final _Log log = _Log();
    final controller = TvReorderController(
      itemCount: () => 3,
      onReorder: log.reorder,
      labelOf: (i) => '歌曲$i',
      onToast: log.toast,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: DpadRegion(
        child: Column(
          children: [
            TvReorderItem(
              index: 0,
              controller: controller,
              autofocus: true,
              onSelect: () => log.selects++,
              child: const SizedBox(key: Key('row'), height: 48, width: 200),
            ),
            // 第二行：验证未拿起时下键放行（焦点能离开本行）。
            DpadFocusable(
              key: const Key('below'),
              child: const SizedBox(height: 48, width: 200),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // 左键拿起（首帧 autofocus 已落在第一行）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.isCarrying, isTrue);
    expect(controller.carriedIndex, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    // 拿起后下键：移动一格（onReorder 下发），焦点不离开本行。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(log.reorders.single, (0, 2));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // 拿起态 OK = 放下（不触发行常规动作）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(controller.isCarrying, isFalse);
    expect(log.selects, 0, reason: '拿起态 OK 收口到放下，不触发 onSelect');

    // 未拿起态 OK = 行动作。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(log.selects, 1);

    // 放下后再按左键 = 重新拿起（而非放行）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.isCarrying, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    controller.drop();
  });

  testWidgets('未拿起时下键放行给焦点遍历（onDirection 返回 false）', (tester) async {
    final _Log log = _Log();
    final controller = TvReorderController(
      itemCount: () => 3,
      onReorder: log.reorder,
      labelOf: (i) => '歌曲$i',
      onToast: log.toast,
    );
    addTearDown(controller.dispose);

    int? focusedRow;
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: DpadRegion(
        child: Column(
          children: [
            TvReorderItem(
              index: 0,
              controller: controller,
              autofocus: true,
              child: const SizedBox(key: Key('row'), height: 48, width: 200),
            ),
            DpadFocusable(
              key: const Key('below'),
              onFocusChange: (f) {
                if (f) focusedRow = 1;
              },
              child: const SizedBox(height: 48, width: 200),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // 首帧焦点落在第一行（TvReorderItem 的 DpadFocusable）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedRow, 1, reason: '未拿起时下键放行，焦点移到下一行');
    expect(controller.isCarrying, isFalse);
  });
}
