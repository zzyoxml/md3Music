// TvTabBarItem 行为契约测试：聚焦即选中（左右键直接切 tab，无需 OK）。
//
// 只测抽出来的 tab 项组件——TvMainShell 整体依赖 MiniPlayer/Provider 链，
// 按 AGENTS §12 惯例整体壳层走真机验收。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/tv_shell.dart';

void main() {
  testWidgets('聚焦即回调 onFocused（切 tab），OK 是兼容入口', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: DpadRegion(
        // 横向排布（与壳层里的横向 ListView 同几何），右键才移得到相邻项。
        child: Row(
          children: [
            TvTabBarItem(
              autofocus: true,
              selected: true,
              icon: const Icon(Icons.explore),
              label: '发现',
              onFocused: () => events.add('focused'),
              onSelect: () => events.add('select'),
            ),
            TvTabBarItem(
              selected: false,
              icon: const Icon(Icons.search),
              label: '搜索',
              onFocused: () => events.add('focused-2'),
              onSelect: () => events.add('select-2'),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // 首帧 autofocus 落在第一项（选中态）。
    expect(events, ['focused']);

    // 右键移到第二项：聚焦即选中（无需 OK）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(events, ['focused', 'focused-2']);
    expect(events.where((e) => e.startsWith('select')), isEmpty,
        reason: '切换 tab 不需要 OK');
  });

  testWidgets('名称仅当前 tab 显示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: DpadRegion(
        child: Row(
          children: [
            TvTabBarItem(
              autofocus: true,
              selected: true,
              icon: const Icon(Icons.explore),
              label: '发现',
              onFocused: () {},
              onSelect: () {},
            ),
            TvTabBarItem(
              selected: false,
              icon: const Icon(Icons.search),
              label: '搜索',
              onFocused: () {},
              onSelect: () {},
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('发现'), findsOneWidget);
    expect(find.text('搜索'), findsNothing);
  });
}
