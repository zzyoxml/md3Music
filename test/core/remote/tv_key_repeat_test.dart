// TvKeyRepeatLayer 行为契约测试。
//
// 接线依据（见 lib/core/remote/tv_key_repeat.dart 类注释）：本层包在 Dpad
// 之内、Navigator 之外，测试按同一拓扑搭建——MaterialApp(builder: Dpad.wrap(),
// home: 本层 + 焦点探针)。全部用 testWidgets + tester.pump(Duration) 推进
// fake time：连发是普通 Timer，需要 fake 时钟才能确定性触发。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_key_repeat.dart';

/// 焦点探针：5 个等宽行，onFocusChange 记录焦点行号。
class _Probe extends StatelessWidget {
  const _Probe({required this.onFocused});

  final ValueChanged<int> onFocused;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 5; i++)
          DpadFocusable(
            key: ValueKey('row$i'),
            autofocus: i == 0,
            onFocusChange: (focused) {
              if (focused) onFocused(i);
            },
            child: const SizedBox(height: 48, width: 200),
          ),
      ],
    );
  }
}

void main() {
  testWidgets('方向键按下：立即移动一次并消费按键', (tester) async {
    final focused = <int>[];
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: TvKeyRepeatLayer(child: _Probe(onFocused: focused.add)),
    ));
    await tester.pump();
    expect(focused, [0], reason: '首帧 autofocus 落在 row0');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused, [0, 1], reason: 'KeyDown 立即移动一次');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
  });

  testWidgets('按住不放：超过 repeatDelay 后按 repeatPeriod 连发，松键即停', (
    tester,
  ) async {
    final focused = <int>[];
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: TvKeyRepeatLayer(child: _Probe(onFocused: focused.add)),
    ));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final afterFirst = focused.length;

    await tester.pump(
      TvKeyRepeatLayer.repeatDelay - const Duration(milliseconds: 20),
    );
    expect(focused.length, afterFirst, reason: '延迟内不连发');

    // +20ms 余量避开定时器边界（delay 到点起 periodic，首个周期步在
    // delay+period 处）。
    await tester.pump(
      const Duration(milliseconds: 20) +
          TvKeyRepeatLayer.repeatPeriod +
          const Duration(milliseconds: 20),
    );
    expect(focused.length, afterFirst + 1, reason: '过延迟后第一个连发步');

    await tester.pump(
      TvKeyRepeatLayer.repeatPeriod + const Duration(milliseconds: 20),
    );
    expect(focused.length, afterFirst + 2);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(TvKeyRepeatLayer.repeatPeriod * 3);
    expect(focused.length, afterFirst + 2, reason: '松键后不再连发');
  });

  testWidgets('平台重复事件被吞：不与定时器双速', (tester) async {
    final focused = <int>[];
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: TvKeyRepeatLayer(child: _Probe(onFocused: focused.add)),
    ));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final afterFirst = focused.length;

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused.length, afterFirst, reason: '重复事件不额外移动焦点');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
  });

  testWidgets('输入框内左右键归光标编辑，本层不接手、不起连发', (tester) async {
    final controller = TextEditingController(text: 'abcd');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: TvKeyRepeatLayer(
        child: Scaffold(
          body: TextField(controller: controller, autofocus: true),
        ),
      ),
    ));
    await tester.pump();
    expect(controller.selection.baseOffset, 4);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 3, reason: '左键移光标');

    await tester.pump(
      TvKeyRepeatLayer.repeatDelay + TvKeyRepeatLayer.repeatPeriod * 3,
    );
    expect(
      controller.selection.baseOffset,
      3,
      reason: '输入框内方向键被本层放行，不起连发',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
  });
}
