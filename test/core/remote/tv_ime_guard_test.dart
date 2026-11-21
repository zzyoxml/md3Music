// TvImeGuard 行为契约测试。
//
// 背景（见 lib/core/remote/tv_ime_guard.dart 类注释）：dpad 3.1.1 的
// _directionAllowed 对「单行输入框」的 up/down 恒判「移出字段」，焦点离开
// TextField 会让 Flutter 隐藏文本输入会话、连带收起系统输入法 —— TV 上表现为
// 「一按方向键键盘就消失」。本层在输入框持焦时把四个方向键就地消费。
//
// 拓扑按线上接线搭：MaterialApp(builder: Dpad.wrap()) → TvImeGuard →
// TvKeyRepeatLayer → 内容（含一个 TextField 与若干可聚焦行）。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_ime_guard.dart';
import 'package:md3music/core/remote/tv_key_repeat.dart';

/// 内容：搜索框 + 两个可聚焦行（用于断言「未持焦时方向键照常导航」）。
class _Harness extends StatelessWidget {
  const _Harness({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const TextField(
          key: ValueKey('search-field'),
          decoration: InputDecoration(hintText: '搜索'),
        ),
        DpadFocusable(
          key: const ValueKey('row0'),
          autofocus: true,
          child: const SizedBox(height: 48, width: 200),
        ),
        DpadFocusable(
          key: const ValueKey('row1'),
          child: const SizedBox(height: 48, width: 200),
        ),
      ],
    );
  }
}

Widget _wrap({required Widget child}) {
  return MaterialApp(
    builder: Dpad.wrap(),
    home: Scaffold(
      body: TvImeGuard(child: TvKeyRepeatLayer(child: child)),
    ),
  );
}

void main() {
  testWidgets('输入框持焦时，方向键被就地消费且焦点不移出输入框', (tester) async {
    await tester.pumpWidget(_wrap(child: const _Harness()));
    await tester.pump();

    // 焦点移到搜索框（模拟遥控器把焦点送进输入框）。
    await tester.tap(find.byKey(const ValueKey('search-field')));
    await tester.pump();

    final EditableTextState editable = tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(const ValueKey('search-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.widget.focusNode.hasFocus, isTrue, reason: '输入框应已持焦');

    // 四个方向键都按一遍：焦点必须留在输入框内（这正是「键盘被顶掉」的触发点）。
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ]) {
      await tester.sendKeyDownEvent(key);
      await tester.pump();
      await tester.sendKeyUpEvent(key);
      await tester.pump();
      expect(
        editable.widget.focusNode.hasFocus,
        isTrue,
        reason: '$key 不应把焦点移出输入框（否则 IME 会话被隐藏、键盘收起）',
      );
    }
  });

  testWidgets('输入框未持焦时，方向键照常导航（守卫放行）', (tester) async {
    await tester.pumpWidget(_wrap(child: const _Harness()));
    await tester.pump();

    // 首焦点在 row0（autofocus）。按一次下键，焦点应离开 row0 继续导航。
    final FocusNode? before = FocusManager.instance.primaryFocus;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final FocusNode? after = FocusManager.instance.primaryFocus;
    expect(
      after,
      isNotNull,
      reason: '未持焦输入框时方向键应正常导航，守卫不得拦截',
    );
    expect(
      identical(after, before),
      isFalse,
      reason: '方向键应把焦点从 row0 移到其它节点（守卫只在输入框持焦时拦截）',
    );
  });
}
