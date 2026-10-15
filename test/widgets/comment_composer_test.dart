import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../lib/widgets/comment_composer.dart';

/// 评论输入框：空内容不可发送、成功后清空、发送中禁用（防连点重复发布）。
///
/// 发送按钮是 m3e_core 的 [M3EFilledButton]，用 ValueKey 定位。
void main() {
  const sendKey = ValueKey('comment_composer_send');

  testWidgets('空内容时发送按钮不可用', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentComposer(onSubmit: (_) async => true),
        ),
      ),
    );

    expect(tester.widget<M3EFilledButton>(find.byKey(sendKey)).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    expect(tester.widget<M3EFilledButton>(find.byKey(sendKey)).onPressed, isNotNull);
  });

  testWidgets('提交成功后清空输入框', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentComposer(
            onSubmit: (text) async {
              submitted = text;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '第一条评论');
    await tester.pump();
    await tester.tap(find.byKey(sendKey));
    await tester.pumpAndSettle();

    expect(submitted, '第一条评论');
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, '');
  });

  testWidgets('提交失败保留内容，便于用户手动重试', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentComposer(onSubmit: (_) async => false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '失败也要留住');
    await tester.pump();
    await tester.tap(find.byKey(sendKey));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '失败也要留住',
    );
  });

  testWidgets('sending=true 时禁用输入与发送', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentComposer(sending: true, onSubmit: (_) async => true),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(tester.widget<M3EFilledButton>(find.byKey(sendKey)).onPressed, isNull);
  });

  testWidgets('回复模式显示被回复用户名并可取消', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentComposer(
            replyToName: '小明',
            onCancelReply: () => cancelled = true,
            onSubmit: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.textContaining('小明'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(cancelled, isTrue);
  });

  testWidgets('avoidKeyboard=true 时按键盘高度预留底部空间', (tester) async {
    const keyboardHeight = 300.0;

    // 用 copyWith 继承真实 MediaQuery（自造 MediaQueryData 会让 size 归零、整树高度为 0）；
    // Scaffold 关掉 resizeToAvoidBottomInset，避免它自己先吃掉键盘高度、掩盖组件的避让
    Widget build({required bool avoidKeyboard}) => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
              ),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: CommentComposer(
                  avoidKeyboard: avoidKeyboard,
                  onSubmit: (_) async => true,
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(build(avoidKeyboard: true));
    final withInset = tester.getSize(find.byType(CommentComposer)).height;

    await tester.pumpWidget(build(avoidKeyboard: false));
    final withoutInset = tester.getSize(find.byType(CommentComposer)).height;

    expect(withoutInset, greaterThan(0));
    expect(withInset - withoutInset, keyboardHeight);
  });
}
