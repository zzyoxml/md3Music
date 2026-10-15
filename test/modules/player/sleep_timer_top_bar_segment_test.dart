// 顶栏尾部「定时关闭」项的可见性与文案。
//
// 回归点：未启用 / 倒计时还没落地时**整项不占位** —— 顶栏尾部是与一起听、⋯ 合成
// 一颗胶囊的（见 TopBarTrailingCapsule），凭空多出一格会把更多菜单推歪。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/player/sleep_timer_sheet.dart';
import 'package:md3music/providers/player_provider.dart' show SleepTimerMode;

void main() {
  group('sleepTimerTopBarSegment', () {
    test('未启用：整项不占位', () {
      expect(
        sleepTimerTopBarSegment(
          remaining: null,
          mode: SleepTimerMode.off,
          onTap: () {},
        ),
        isNull,
      );
    });

    test('倒计时已开启但剩余时间尚未落地：同样不占位', () {
      expect(
        sleepTimerTopBarSegment(
          remaining: null,
          mode: SleepTimerMode.countdown,
          onTap: () {},
        ),
        isNull,
      );
    });

    test('倒计时中：文案是逐秒剩余时间', () {
      final segment = sleepTimerTopBarSegment(
        remaining: const Duration(minutes: 12, seconds: 3),
        mode: SleepTimerMode.countdown,
        onTap: () {},
      );
      expect(segment, isNotNull);
      expect(segment!.label, '12:03');
      expect(segment.icon, Icons.timer_outlined);
    });

    test('到点等待态：静态文案「播完本曲」', () {
      final segment = sleepTimerTopBarSegment(
        remaining: null,
        mode: SleepTimerMode.endOfTrack,
        onTap: () {},
      );
      expect(segment!.label, '播完本曲');
    });

    test('点它就是打开定时面板（回调原样透传）', () {
      int taps = 0;
      final segment = sleepTimerTopBarSegment(
        remaining: const Duration(minutes: 1),
        mode: SleepTimerMode.countdown,
        onTap: () => taps++,
      );
      segment!.onTap!();
      expect(taps, 1);
    });
  });
}
