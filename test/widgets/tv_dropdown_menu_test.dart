// TvDropdownMenu 的两条分支契约。
//
// TV 侧缺陷根因（与 lib/widgets/m3e_sort_sheet.dart 的记录同源）：
// M3EDropdownMenu 的字段把 ↑/↓/Enter/Space 全部判为 handled，面板又渲染在
// OverlayPortal（另一个 FocusScope）里、条目是纯点击的 InkWell ——
// dpad 既走不进面板也选不中任何一项，所以 TV 下必须换成路由型底部弹层。
//
// TV 分支是 kTvBuild 常量门控，需单跑：
//   flutter test test/widgets/tv_dropdown_menu_test.dart --dart-define=MD3_TV=true

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart' as mu;
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/widgets/tv_dropdown_menu.dart';

/// TV 用例的应用根：必须用 **material_ui 的 MaterialApp**。
///
/// `showM3EModalBottomSheet` 内部走 material_ui 的 `showModalBottomSheet`，
/// 它会断言 material_ui 自己的 `MaterialLocalizations`（flutter 的
/// `MaterialApp` 提供的是另一个同名类型，取不到 → 「No MaterialLocalizations
/// found」）。本 App 的根正是 material_ui 的 MaterialApp，并在 builder 里用
/// material_ui 的 MaterialUiCompatibilityBridge 把 flutter 的 Theme/Localizations
/// 桥接给第三方依赖（`lib/app.dart` 同一手法），测试骨架照抄这个结构。
Widget _tvApp(Widget child) {
  return mu.MaterialApp(
    builder: (context, inner) {
      // ignore: deprecated_member_use
      final bridged = mu.MaterialUiCompatibilityBridge(
        child: inner ?? const SizedBox.shrink(),
      );
      return Dpad.wrap(theme: const DpadThemeData())(context, bridged);
    },
    home: Scaffold(body: Center(child: child)),
  );
}

List<M3EDropdownItem<int>> _items({int current = 10, int count = 4}) {
  return [
    for (final s in List.generate(count, (i) => (i + 1) * 5))
      M3EDropdownItem<int>(
        label: '$s 秒',
        value: s,
        selected: s == current,
      ),
  ];
}

void main() {
  testWidgets('非 TV 构建：渲染原生 M3EDropdownMenu（触屏路径零变化）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 220,
            child: TvDropdownMenu<int>(items: _items(), onSelectionChanged: (_) {}),
          ),
        ),
      ),
    );

    expect(find.byType(M3EDropdownMenu<int>), findsOneWidget);
    expect(find.byType(DpadFocusable), findsNothing);
  }, skip: kTvBuild);

  group('TV 构建（MD3_TV=true）', () {
    Future<void> pumpField(
      WidgetTester tester, {
      required ValueChanged<List<M3EDropdownItem<int>>> onChanged,
      int current = 10,
      int count = 4,
    }) async {
      await tester.pumpWidget(
        _tvApp(
          SizedBox(
            width: 220,
            child: TvDropdownMenu<int>(
              items: _items(current: current, count: count),
              fieldStyle: const M3EDropdownFieldStyle(
                hintText: '选择轮播间隔',
              ),
              onSelectionChanged: onChanged,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('不出现原生下拉；字段本身是一个可落焦停点', (tester) async {
      await pumpField(tester, onChanged: (_) {});

      expect(find.byType(M3EDropdownMenu<int>), findsNothing);
      expect(find.byType(DpadFocusable), findsOneWidget);
      expect(find.text('10 秒'), findsOneWidget, reason: '当前值要显示出来');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(focus!.debugLabel, isNot(contains('scope')),
          reason: '方向键应能落到字段而不是无处可去');
    });

    testWidgets('OK 开弹层，首行自动落焦；选非当前项回调 [item]', (tester) async {
      final calls = <List<M3EDropdownItem<int>>>[];
      await pumpField(tester, onChanged: calls.add);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('选择轮播间隔'), findsOneWidget, reason: '弹层标题');
      expect(find.text('15 秒'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single, hasLength(1));
      expect(calls.single.first.value, 5, reason: '首行是第一项');
    });

    testWidgets('再选当前项 → 回传空列表（M3E 单选的重复点击语义）',
        (tester) async {
      final calls = <List<M3EDropdownItem<int>>>[];
      await pumpField(tester, onChanged: calls.add, current: 5);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      // 焦点在首行，而首行正是当前项
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(calls.single, isEmpty,
          reason: '选中当前项必须回传空列表，否则依赖该语义的守卫会失效');
    });

    testWidgets('长列表可滚动且不顶满屏', (tester) async {
      await pumpField(tester, onChanged: (_) {}, current: 5, count: 40);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      final sheetList = find.byType(ListView).last;
      final sheetHeight = tester.getSize(sheetList).height;
      expect(sheetHeight, lessThanOrEqualTo(600 * 0.7 + 1),
          reason: '弹层内列表高度受 70% 屏高约束（测试表面 600dp）');
      // ListView 不公开 itemCount，用可滚动性证明长列表没被截断
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(
                of: sheetList,
                matching: find.byType(Scrollable),
              ),
            )
            .position
            .maxScrollExtent,
        greaterThan(0),
        reason: '40 条选项必须能在弹层内滚动，而不是顶破屏幕',
      );
      expect(find.text('5 秒'), findsNWidgets(2),
          reason: '字段显示当前值 + 弹层首行同名选项，两处都要在');
    });

    testWidgets('禁用项不产生停点、也不可选中', (tester) async {
      final calls = <List<M3EDropdownItem<int>>>[];
      await tester.pumpWidget(
        _tvApp(
          SizedBox(
            width: 220,
            child: TvDropdownMenu<int>(
              items: const [
                M3EDropdownItem<int>(label: '可用', value: 1),
                M3EDropdownItem<int>(
                    label: '需开启记忆播放', value: 2, disabled: true),
              ],
              onSelectionChanged: calls.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('需开启记忆播放'), findsOneWidget, reason: '信息要看得见');
      expect(find.byType(DpadFocusable), findsNWidgets(2),
          reason: '字段 + 唯一可用行各一个停点，禁用行不接焦点');
    });
  }, skip: !kTvBuild);
}
