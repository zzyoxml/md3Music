import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 睡眠定时：倒计时与「定时结束后播完当前歌曲」两种模式的状态机。
///
/// 覆盖勾选偏好的读写、与倒计时的共存、取消的清理范围。
/// 依赖真实时间的行为（到点不打断、播完当前曲停止）见
/// `player_provider_sleep_timer_behavior_test.dart`。
void main() {
  group('睡眠定时模式状态机', () {
    testWidgets('默认未启用', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        expect(player.sleepTimerMode, SleepTimerMode.off);
        expect(player.isSleepTimerActive, isFalse);
        expect(player.sleepTimerRemaining, isNull);
        expect(player.stopAfterTimerEnds, isFalse);
      } finally {
        // 必须先 pump 再 dispose：setSleepTimer 会把写 notifier 的动作挂到
        // post-frame，若回调在 dispose 之后执行会命中 ChangeNotifier 的
        // "used after being disposed" 断言（见 _scheduleSleepNotifier 的注释）。
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });

    testWidgets('勾选「定时结束后播完当前歌曲」只记偏好，不激活定时', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        player.setStopAfterCurrentTrack(true);

        expect(player.stopAfterTimerEnds, isTrue);
        expect(
          player.sleepTimerMode,
          SleepTimerMode.off,
          reason: '还没设定时，不应处于激活态',
        );
        expect(player.isSleepTimerActive, isFalse);
      } finally {
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });

    testWidgets('倒计时保持原有语义', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        player.setSleepTimer(const Duration(minutes: 30));

        expect(player.sleepTimerMode, SleepTimerMode.countdown);
        expect(player.isSleepTimerActive, isTrue);
        // 用秒比对：inMinutes 会向下取整，wall clock 已流逝几毫秒时得到 29
        expect(
          player.sleepTimerRemaining?.inSeconds,
          anyOf(1799, 1800),
          reason: '剩余应为约 30 分钟',
        );
      } finally {
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });

    testWidgets('勾选与倒计时共存', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        player.setStopAfterCurrentTrack(true);
        player.setSleepTimer(const Duration(minutes: 10));

        expect(player.sleepTimerMode, SleepTimerMode.countdown);
        expect(
          player.stopAfterTimerEnds,
          isTrue,
          reason: '到点行为由到点时刻的勾选态决定，设定时不应清除它',
        );
      } finally {
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });

    testWidgets('取消定时同时清掉到点等待态与勾选偏好', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        player.setStopAfterCurrentTrack(true);
        player.setSleepTimer(const Duration(minutes: 10));

        player.setSleepTimer(null);

        expect(player.sleepTimerMode, SleepTimerMode.off);
        expect(player.isSleepTimerActive, isFalse);
        expect(player.sleepTimerRemaining, isNull);
        expect(player.stopAfterTimerEnds, isFalse);
      } finally {
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });

    testWidgets('取消勾选只清偏好，不影响进行中的倒计时', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final player = PlayerProvider();
      try {
        player.setStopAfterCurrentTrack(true);
        player.setSleepTimer(const Duration(minutes: 10));

        player.setStopAfterCurrentTrack(false);

        expect(player.stopAfterTimerEnds, isFalse);
        expect(player.sleepTimerMode, SleepTimerMode.countdown);
        expect(player.isSleepTimerActive, isTrue);
      } finally {
        await tester.pump();
        player.dispose();
        await tester.pump();
      }
    });
  });
}
