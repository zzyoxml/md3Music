import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/widgets/keyboard_expand_sheet.dart';

/// 键盘自适应托盘：键盘弹出时增高到 maxChildSize（否则打字时列表只剩一条缝），
/// 收起后回到键盘弹出前的高度比例。
void main() {
  test('评论托盘初始高度：Windows 近全屏，其它平台半屏', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(commentSheetInitialChildSize(), 0.9);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(commentSheetInitialChildSize(), 0.5);
  });

  testWidgets('键盘弹出时托盘增高到 maxChildSize，收起后回原高度', (tester) async {
    Widget build(double inset) => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: EdgeInsets.only(bottom: inset),
              ),
              child: Scaffold(
                // 关掉 Scaffold 自己的键盘避让，只观察托盘自身的高度变化
                resizeToAvoidBottomInset: false,
                body: KeyboardExpandScrollableSheet(
                  initialChildSize: 0.5,
                  minChildSize: 0.3,
                  maxChildSize: 0.9,
                  builder: (context, scrollController) => ListView.builder(
                    controller: scrollController,
                    itemCount: 50,
                    itemBuilder: (_, i) => SizedBox(height: 40, child: Text('item $i')),
                  ),
                ),
              ),
            ),
          ),
        );

    double sheetHeight() =>
        tester.getSize(find.byType(DraggableScrollableSheet)).height;

    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    final collapsed = sheetHeight();
    expect(collapsed, greaterThan(0));

    // 键盘弹出 → 展开到 maxChildSize
    await tester.pumpWidget(build(300));
    await tester.pumpAndSettle();
    final expanded = sheetHeight();
    expect(expanded, greaterThan(collapsed));

    // 键盘收起 → 回到 0.5
    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    expect(sheetHeight(), closeTo(collapsed, 1.0));
  });

  testWidgets('键盘弹出期间用户拖过的高度不会覆盖收起后的恢复目标', (tester) async {
    // 仅验证：连续两次「键盘弹出」不会把恢复目标记成 maxChildSize
    Widget build(double inset) => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: EdgeInsets.only(bottom: inset),
              ),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: KeyboardExpandScrollableSheet(
                  initialChildSize: 0.4,
                  minChildSize: 0.3,
                  maxChildSize: 0.9,
                  builder: (context, scrollController) => ListView.builder(
                    controller: scrollController,
                    itemCount: 50,
                    itemBuilder: (_, i) => SizedBox(height: 40, child: Text('item $i')),
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    final base = tester.getSize(find.byType(DraggableScrollableSheet)).height;

    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(build(300));
      await tester.pumpAndSettle();
      await tester.pumpWidget(build(0));
      await tester.pumpAndSettle();
    }

    expect(
      tester.getSize(find.byType(DraggableScrollableSheet)).height,
      closeTo(base, 1.0),
    );
  });

  testWidgets('顶部拖动区支持鼠标调整高度（桌面端没有触摸拖拽）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (context) => KeyboardExpandScrollableSheet(
                  initialChildSize: 0.5,
                  minChildSize: 0.3,
                  maxChildSize: 1.0,
                  builderWithController:
                      (context, scrollController, sheetController) => Column(
                        children: [
                          DraggableSheetHeader(
                            controller: sheetController,
                            minChildSize: 0.3,
                            maxChildSize: 1.0,
                            child: const SizedBox(
                              height: 72,
                              child: Center(child: Text('header')),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              controller: scrollController,
                              itemCount: 30,
                              itemBuilder: (_, i) => SizedBox(
                                height: 40,
                                child: Text('item $i'),
                              ),
                            ),
                          ),
                        ],
                      ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    double sheetHeight() =>
        tester.getSize(find.byType(DraggableScrollableSheet)).height;
    final before = sheetHeight();

    // Windows 桌面用户的典型操作：按住顶部手柄用鼠标往上拖。
    // 第一段位移用于被拖拽识别器判定为「开始拖动」，之后才产生高度更新。
    final drag = await tester.startGesture(
      tester.getCenter(find.text('header')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    await drag.moveBy(const Offset(0, -160));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(sheetHeight(), greaterThan(before));

    Navigator.of(tester.element(find.text('header'))).pop();
    await tester.pumpAndSettle();
  });
}
