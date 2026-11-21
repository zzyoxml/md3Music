// TvMenuKeyShortcuts 行为契约测试（AGENTS §12 惯例：可测组件不带 kTvBuild
// 门控，普通 flutter test 可钉住；调用侧的 kTvBuild 接线真机验收）。
//
// 传播机制依据：CallbackShortcuts 创建不可聚焦、不参与遍历的 Focus 节点，
// 只在按键传播路径上拦 contextMenu；独立路由（bottom sheet）的焦点不在
// 页面包装的子孙链上，不得触发。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_menu_key_shortcuts.dart';

void main() {
  testWidgets('焦点在子孙时按菜单键触发 onMenu', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvMenuKeyShortcuts(
          onMenu: () => menuCount++,
          child: Focus(autofocus: true, child: const SizedBox.expand()),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(menuCount, 1);
  });

  testWidgets('非菜单键不触发 onMenu（方向键穿透）', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvMenuKeyShortcuts(
          onMenu: () => menuCount++,
          child: Focus(autofocus: true, child: const SizedBox.expand()),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(menuCount, 0);
  });

  testWidgets('onMenu 为 null 时等价于裸 child，按键不抛异常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TvMenuKeyShortcuts(
          onMenu: null,
          child: Focus(autofocus: true, child: const SizedBox.expand()),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    // 无异常即通过：未注册 bindings，contextMenu 原样穿透。
  });

  testWidgets('弹层（独立路由）内的焦点不触发页面级 onMenu', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvMenuKeyShortcuts(
          onMenu: () => menuCount++,
          child: Builder(
            builder: (context) => Focus(
              autofocus: true,
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => Focus(
                    autofocus: true,
                    child: const SizedBox(height: 100),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(menuCount, 0, reason: 'sheet 焦点不在页面包装的子树，菜单键不得重复触发');
  });
}
