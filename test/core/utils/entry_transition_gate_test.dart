import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/entry_transition_gate.dart';

void main() {
  test('没有动画对象时立即放行', () async {
    expect(await waitUntilEntrySettled(null), 0);
  });

  testWidgets('转场未收敛前不放行，completed 后放行', (tester) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);

    var settled = false;
    // ignore: unawaited_futures
    waitUntilEntrySettled(controller, timeout: const Duration(seconds: 5)).then(
      (_) => settled = true,
    );

    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(settled, isFalse, reason: '转场还在跑，重活不许开始');

    await tester.pump(const Duration(milliseconds: 200));
    expect(settled, isTrue);
    // 收敛后必须摘掉状态监听，否则转场结束后还挂着已销毁动画的监听。
    expect(controller.status, AnimationStatus.completed);
  });

  testWidgets('已经收敛的路由（返回栈里已存在的页面）不等待', (tester) async {
    final controller = AnimationController(vsync: tester, value: 1.0);
    addTearDown(controller.dispose);
    expect(await waitUntilEntrySettled(controller), 0);
  });

  testWidgets('转场永不收敛时按超时放行', (tester) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(seconds: 10),
    );
    addTearDown(controller.dispose);

    var settled = false;
    // ignore: unawaited_futures
    waitUntilEntrySettled(controller, timeout: const Duration(milliseconds: 200))
        .then((_) => settled = true);

    controller.forward();
    await tester.pump(const Duration(milliseconds: 100));
    expect(settled, isFalse, reason: '超时之前不该提前放行');

    await tester.pump(const Duration(milliseconds: 200));
    expect(settled, isTrue, reason: '超时兜底：绝不让数据加载永远不开始');
    // 本用例的动画被故意留在进行中状态，不收尾会触发 flutter_test 的 Ticker 泄漏断言。
    controller.stop();
  });
}
