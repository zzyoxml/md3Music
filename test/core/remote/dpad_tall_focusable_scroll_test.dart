// 机制级回归钉：一个「比视口还高」的 DpadFocusable 停点会把列表整页滚走。
//
// 本文件**不依赖 kTvBuild**（直接手搓 dpad 控件），因为要钉的是 dpad 自己的
// 几何滚动行为，普通构建同样能跑（对照 test/core/remote/dpad_first_enter_focus_test.dart
// 的 harness 口径：MaterialApp(builder: Dpad.wrap(theme: DpadThemeData()))）。
//
// 背景（楼中楼展开跳底）：dpad 的 `DpadFocusable` 默认 autoScroll=true，聚焦时在
// post-frame 调 `DpadScroll.ensureVisible`，它会遍历**所有**祖先 Scrollable 并把
// 焦点项滚进视野。一条展开后超过视口的评论被做成**单个**停点时，dpad 走的是
// 「比视口高 → 居中」分支：整屏内容被推动，用户看到的就是"焦点一动就跳底"。
// 结论：超视口的东西不该做成一个停点，要拆成「小头部停点 + 逐条小条目停点」。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试默认 surface 是 800×600 逻辑像素，视口高即 600。
const double _viewportHeight = 600;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('焦点落在超视口的停点上 → dpad 把它居中，列表被整页滚走', (tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FocusNode tall = FocusNode(debugLabel: 'tall-item');
    addTearDown(tall.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: ListView(
          controller: controller,
          children: <Widget>[
            DpadFocusable(
              focusNode: tall,
              onSelect: () {},
              // 3 倍视口高：单个停点装下整条展开的楼中楼
              child: Container(
                height: _viewportHeight * 3,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // dpad 的根在首帧就把焦点给了第一个停点 —— 真机上「展开楼中楼后焦点仍留在
    // 这条评论上」走的是同一条 ensureVisible 路径，不需要用户额外按键。
    expect(tall.hasFocus, isTrue, reason: '前置：dpad 首帧就把焦点给了第一个停点');
    // 「比视口高 → 居中」分支：offset = 项中心 - 视口中心
    //   = (1800 / 2) - (600 / 2) = 600 —— 整整一屏被推走。
    expect(
      controller.offset,
      _viewportHeight,
      reason: '聚焦一个超视口停点会把列表整页滚走（楼中楼展开跳底的根因）',
    );
    expect(
      controller.offset,
      lessThan(controller.position.maxScrollExtent),
      reason: '居中之后仍有内容在视口外：这个停点永远看不全',
    );

    // 焦点重入（等价于收起再展开、或从别的停点走回来）会把整页再推走一次。
    controller.jumpTo(0);
    await tester.pump();
    expect(controller.offset, 0.0);
    tall.unfocus();
    await tester.pumpAndSettle();
    tall.requestFocus();
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      _viewportHeight,
      reason: '焦点重入同样触发居中分支：只要停点比视口高，列表就不可能停在原位',
    );
  });

  testWidgets('拆成小停点：方向键逐条推进，列表只按边缘距离小幅跟随', (tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FocusNode header = FocusNode(debugLabel: 'header');
    final List<FocusNode> items = <FocusNode>[
      FocusNode(debugLabel: 'item-0'),
      FocusNode(debugLabel: 'item-1'),
      FocusNode(debugLabel: 'item-2'),
      FocusNode(debugLabel: 'item-3'),
    ];
    addTearDown(header.dispose);
    for (final FocusNode node in items) {
      addTearDown(node.dispose);
    }

    Widget stop(FocusNode node) => DpadFocusable(
      focusNode: node,
      onSelect: () {},
      // 每个停点 250 高（小于视口），头部 + 4 条目共 1250 → maxScrollExtent 650
      child: Container(height: 250, color: Colors.blueGrey),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: ListView(
          controller: controller,
          children: <Widget>[stop(header), ...items.map(stop)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    header.requestFocus();
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      0.0,
      reason: '小停点在视野内时 dpad 不该推动列表（对比上一条的整页跳走）',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(items[0].hasFocus, isTrue, reason: '下键把焦点推进到第一个条目');
    expect(
      controller.offset,
      lessThan(controller.position.maxScrollExtent),
      reason: '跟随只到边缘为止，不会一路冲到底',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(items[1].hasFocus, isTrue, reason: '再按一次继续推进（逐项而非跳页）');
    expect(
      controller.offset,
      greaterThan(0.0),
      reason: '焦点项贴近视口底缘时才小幅滚动',
    );
    expect(
      controller.offset,
      lessThan(controller.position.maxScrollExtent),
    );
  });
}
