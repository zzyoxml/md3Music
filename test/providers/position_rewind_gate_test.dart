/// 位置回退闸门单元测试（方案 A：换源装载期间不发布"位置从 0 重新计数"的假回退）。
///
/// 背景：just_audio 的 setUrl 会让位置从 0 重新开始，直到随后的 seek 落地。
/// 该窗口内的采样若被发布，进度条会闪回 0:00，歌词会滚回开头
/// （见 docs/2026-09-11-pause-lyric-scroll-from-top-analysis.md）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/position_rewind_gate.dart';

void main() {
  group('PositionRewindGate', () {
    test('未开启时不抑制任何采样', () {
      final gate = PositionRewindGate();
      expect(gate.armed, isFalse);
      expect(gate.shouldSuppress(Duration.zero), isFalse);
      expect(gate.shouldSuppress(const Duration(seconds: 30)), isFalse);
    });

    test('目标 <= 0 不开启（换源后确实要从 0 开始播）', () {
      final gate = PositionRewindGate();
      gate.arm(Duration.zero);
      expect(gate.armed, isFalse);
      expect(gate.floor, Duration.zero);
      expect(gate.shouldSuppress(Duration.zero), isFalse);
    });

    test('开启后丢弃小于目标的回退采样，到达/超过目标放行', () {
      final gate = PositionRewindGate();
      final now = DateTime(2026, 9, 11, 12);
      gate.arm(const Duration(seconds: 60), now: now);
      expect(gate.armed, isTrue);
      expect(gate.floor, const Duration(seconds: 60));

      // 换源副作用：位置从 0 重新计数 / 中间的旧采样
      expect(gate.shouldSuppress(Duration.zero, now: now), isTrue);
      expect(gate.shouldSuppress(const Duration(seconds: 5), now: now), isTrue);
      expect(
        gate.shouldSuppress(const Duration(milliseconds: 59999), now: now),
        isTrue,
      );

      // 到达/超过目标 = 真实进度，放行
      expect(gate.shouldSuppress(const Duration(seconds: 60), now: now),
          isFalse);
      expect(gate.shouldSuppress(const Duration(seconds: 61), now: now),
          isFalse);
      // 放行不自动关闭闸门（仍需装载结束时显式 disarm，避免窗口后段再被污染）
      expect(gate.armed, isTrue);
    });

    test('超时后自动放行并关闭闸门（装载卡死兜底）', () {
      final gate = PositionRewindGate();
      final now = DateTime(2026, 9, 11, 12);
      gate.arm(const Duration(seconds: 60), now: now);
      final later =
          now.add(PositionRewindGate.timeout + const Duration(seconds: 1));
      expect(gate.shouldSuppress(Duration.zero, now: later), isFalse,
          reason: '超时后不得继续抑制，否则位置永久冻结');
      expect(gate.armed, isFalse);
    });

    test('disarm 后回退采样放行（装载结束后的合法 seek 回退）', () {
      final gate = PositionRewindGate();
      gate.arm(const Duration(seconds: 60));
      expect(gate.shouldSuppress(const Duration(seconds: 10)), isTrue);

      gate.disarm();
      expect(gate.armed, isFalse);
      expect(gate.shouldSuppress(const Duration(seconds: 10)), isFalse);
    });

    test('重复 arm 以最后一次目标为准', () {
      final gate = PositionRewindGate();
      gate.arm(const Duration(seconds: 60));
      gate.arm(const Duration(seconds: 120));
      expect(gate.floor, const Duration(seconds: 120));
      expect(gate.shouldSuppress(const Duration(seconds: 90)), isTrue);
      expect(gate.shouldSuppress(const Duration(seconds: 120)), isFalse);
    });
  });
}
