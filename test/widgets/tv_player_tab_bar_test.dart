// TvPlayerTabBar 行为契约测试：聚焦段即切页（左右键直切，免 OK）。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/tv_player_tab_bar.dart';

void main() {
  testWidgets('聚焦即 onSelected；左右键移动焦点即切页，无需 OK', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(MaterialApp(
      builder: Dpad.wrap(),
      home: TvPlayerTabBar(
        labels: const ['列表', '歌词', '评论'],
        currentIndex: 0,
        activeColor: Colors.white,
        inactiveColor: Colors.grey,
        // 测试用：首段 autofocus，保证按键前焦点在段上（生产不传，焦点
        // 由 dpad 首帧落位决定）。
        autofocus: true,
        onSelected: selected.add,
      ),
    ));
    await tester.pump();
    expect(selected, isEmpty, reason: '首段即当前页，聚焦不重复回调');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected, [1], reason: '右键移到第二段即切页');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected, [1, 2]);

    // OK 保留为兼容入口。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(selected, [1, 2, 2]);
  });
}
