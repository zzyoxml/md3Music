// 「定时关闭」面板装配测试。
//
// 覆盖：旧滑杆已移除、表盘在场、手动输入分钟与表盘双向同步、输入超范围钳到
// 24 小时、点击中央形状开始计时并关闭面板、「关闭定时」仍在。
//
// dispose 必须放在 test body 里（try/finally），不能用 addTearDown：
// package:test 的 tearDown 在 flutter_test 的 _verifyInvariants **之后** 才跑，
// 而 setSleepTimer 会起一个 1s 的 periodic ticker，届时会被判为「Timer still
// pending」，即使 provider 已 dispose。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/sleep_timer_dial.dart';
import 'package:md3music/modules/player/sleep_timer_sheet.dart';
import 'package:md3music/providers/player_provider.dart';

void main() {
  /// 打开面板并返回一个 real PlayerProvider（构造方式同
  /// `test/providers/player_provider_sleep_timer_test.dart`）。
  Future<PlayerProvider> openSheet(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final hostContext = <BuildContext>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext.add(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    showSleepTimerSheet(context: hostContext.first, player: player);
    await tester.pumpAndSettle();
    return player;
  }

  /// setSleepTimer 会把写 notifier 的动作挂到 post-frame，回调若在 dispose
  /// 之后执行会命中 ChangeNotifier 的 "used after being disposed" 断言，
  /// 所以 dispose 前必须先 pump（同上面对齐）。
  Future<void> disposePlayer(WidgetTester tester, PlayerProvider player) async {
    await tester.pump();
    player.dispose();
    await tester.pump();
  }

  testWidgets('面板里有表盘，且旧的 1–90 分钟滑杆已移除', (tester) async {
    final player = await openSheet(tester);
    try {
      expect(find.text('定时关闭'), findsWidgets);
      expect(find.byType(SleepTimerDial), findsOneWidget);
      expect(find.byType(M3ESlider), findsNothing);
      expect(find.text('90 分钟'), findsNothing);
    } finally {
      await disposePlayer(tester, player);
    }
  });

  testWidgets('手动输入分钟数（最大 24h）会同步到表盘', (tester) async {
    final player = await openSheet(tester);
    try {
      await tester.enterText(find.byType(TextField), '90');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('1 小时'), findsOneWidget);
      expect(find.text('30 分钟'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player);
    }
  });

  testWidgets('手动输入超过 1440 会被钳到 24 小时', (tester) async {
    final player = await openSheet(tester);
    try {
      await tester.enterText(find.byType(TextField), '9999');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('24 小时'), findsOneWidget);
      expect(find.text('0 分钟'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player);
    }
  });

  testWidgets('点击中央形状开始计时并关闭面板', (tester) async {
    final player = await openSheet(tester);
    try {
      final dialRect = tester.getRect(find.byType(SleepTimerDial));
      await tester.tapAt(dialRect.center);
      await tester.pumpAndSettle();

      expect(player.sleepTimerMode, SleepTimerMode.countdown);
      expect(player.sleepTimerRemaining, isNotNull);
      expect(find.byType(SleepTimerDial), findsNothing, reason: '开始后面板应关闭');
    } finally {
      await disposePlayer(tester, player);
    }
  });

  testWidgets('「关闭定时」仍在，点击后取消定时', (tester) async {
    final player = await openSheet(tester);
    try {
      player.setSleepTimer(const Duration(minutes: 30));
      await tester.pumpAndSettle();

      expect(find.text('关闭定时'), findsOneWidget);
      await tester.tap(find.text('关闭定时'));
      await tester.pumpAndSettle();

      expect(player.sleepTimerMode, SleepTimerMode.off);
    } finally {
      await disposePlayer(tester, player);
    }
  });
}
