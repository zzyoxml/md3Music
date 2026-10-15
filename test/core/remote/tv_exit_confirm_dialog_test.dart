import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_exit_confirm_dialog.dart';

void main() {
  /// 返回「点击 open 后」弹窗的结果 Future（不在此处 await，交由用例决定时机）。
Future<Future<bool>> openDialog(WidgetTester tester) async {
    late Future<bool> resultFuture;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => resultFuture = showTvExitConfirmDialog(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return resultFuture;
  }

  testWidgets('默认焦点在「取消」，OK 键返回 false', (tester) async {
    final resultFuture = await openDialog(tester);
    expect(find.text('退出 MD3Music？'), findsOneWidget);
    // DPAD_CENTER 在测试环境用 enter 等价激活（真机上由 dpad/系统映射）
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await resultFuture, isFalse);
  });

  testWidgets('右移焦点到「退出」再 OK 返回 true', (tester) async {
    final resultFuture = await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await resultFuture, isTrue);
  });

  testWidgets('对话框外返回（pop 关闭）按取消处理', (tester) async {
    final resultFuture = await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await resultFuture, isFalse);
  });
}
