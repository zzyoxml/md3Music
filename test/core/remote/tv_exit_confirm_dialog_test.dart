import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_exit_confirm_dialog.dart';

void main() {
  /// 返回「点击 open 后」弹窗的结果 Future（不在此处 await，交由用例决定时机）。
  Future<Future<TvExitAction>> openDialog(WidgetTester tester) async {
    late Future<TvExitAction> resultFuture;
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

  testWidgets('三项动作齐全，默认焦点在「取消」，OK 键返回 cancel', (tester) async {
    final resultFuture = await openDialog(tester);
    expect(find.text('退出 MD3Music？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('后台播放'), findsOneWidget);
    expect(find.text('退出 App'), findsOneWidget);
    // DPAD_CENTER 在测试环境用 enter 等价激活（真机上由 dpad/系统映射）
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await resultFuture, TvExitAction.cancel);
  });

  testWidgets('右移一次 + OK 返回 background', (tester) async {
    final resultFuture = await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await resultFuture, TvExitAction.background);
  });

  testWidgets('右移两次 + OK 返回 exitApp', (tester) async {
    final resultFuture = await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await resultFuture, TvExitAction.exitApp);
  });

  testWidgets('对话框外返回（pop 关闭）按取消处理', (tester) async {
    final resultFuture = await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await resultFuture, TvExitAction.cancel);
  });
}
