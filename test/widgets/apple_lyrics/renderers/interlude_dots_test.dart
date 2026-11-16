import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/interlude_dots.dart';

void main() {
  group('InterludeDots', () {
    test('初始状态：无间奏，isInterlude 返回 false，shouldRender=false', () {
      final dots = InterludeDots();
      expect(dots.startTime, isNull);
      expect(dots.endTime, isNull);
      expect(dots.isInterlude(0), isFalse);
      expect(dots.isInterlude(5000), isFalse);
      expect(dots.shouldRender, isFalse);
      // tick 不抛异常即可（返回 void）
      dots.tick(0.016);
      dots.tick(0.1);
    });

    group('设置间奏后 (start=1000, end=7000)', () {
      // 注意：按 API 约定，endTime 是调用方已减去 interludeEarlyEndMs(250ms) 的值。
      // 这里模拟"下一行 startTime=7250ms"的场景，传入 endTime=7250-250=7000。
      const start = 1000;
      const end = 7000;
      late InterludeDots dots;

      setUp(() {
        dots = InterludeDots();
        dots.setInterlude(start, end);
        // 推进 1 帧（16ms）使动画时钟启动
        dots.tick(0.016);
      });

      test('setInterlude 后 shouldRender=true', () {
        expect(dots.shouldRender, isTrue);
      });

      test('间奏时段内 isInterlude 返回 true（基于 currentTimeMs 判定）', () {
        expect(dots.isInterlude(1000), isTrue);
        expect(dots.isInterlude(3000), isTrue);
        expect(dots.isInterlude(6999), isTrue);
      });

      test('间奏边界：startTime 处 isInterlude=true，endTime 处 isInterlude=false', () {
        expect(dots.isInterlude(start), isTrue);
        expect(dots.isInterlude(end), isFalse);
      });

      test('间奏外时刻 isInterlude 返回 false', () {
        expect(dots.isInterlude(start - 1), isFalse);
        expect(dots.isInterlude(end), isFalse);
        expect(dots.isInterlude(end + 1000), isFalse);
      });
    });

    group('clear()', () {
      test('clear 后 isInterlude 返回 false，shouldRender=false', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        expect(dots.isInterlude(3000), isTrue);
        expect(dots.shouldRender, isTrue);

        dots.clear();
        expect(dots.startTime, isNull);
        expect(dots.endTime, isNull);
        expect(dots.isInterlude(3000), isFalse);
        expect(dots.isInterlude(1000), isFalse);
        expect(dots.shouldRender, isFalse);
      });
    });

    group('setInterlude 重新设置', () {
      test('重新设置后旧时段失效，新时段生效', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        expect(dots.isInterlude(3000), isTrue);

        dots.setInterlude(10000, 20000);
        dots.tick(0.016);
        expect(dots.isInterlude(3000), isFalse);
        expect(dots.isInterlude(15000), isTrue);
      });

      test('相同间奏重复调用 setInterlude 不重置（幂等）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        // 推进一段时间
        dots.tick(0.5);
        // 再次设置相同间奏，shouldRender 仍为 true，且动画时钟不重置
        dots.setInterlude(1000, 7000);
        expect(dots.shouldRender, isTrue);
        expect(dots.isInterlude(3000), isTrue);
      });

      test('forceReset=true 时相同间奏也重置动画时钟（seek 回跳场景）', () {
        final dots = InterludeDots();
        // 间奏时长 6000ms（end - start）
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        // 推进动画时钟超过间奏总时长：此时动画已结束
        dots.tick(7.0);
        // 普通重复调用：幂等保护不重置，动画时钟仍超时（paintAtLineY 会隐藏圆点）
        dots.setInterlude(1000, 7000);
        expect(dots.shouldRender, isTrue);
        // forceReset：强制重置动画时钟，重新从 0 开始入场
        dots.setInterlude(1000, 7000, forceReset: true);
        expect(dots.shouldRender, isTrue);
        expect(dots.isInterlude(3000), isTrue);
      });

      test('setInterlude(null, null) 清除间奏', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        expect(dots.shouldRender, isTrue);

        dots.setInterlude(null, null);
        expect(dots.shouldRender, isFalse);
        expect(dots.startTime, isNull);
      });
    });

    group('alignToRealTime（Ticker mute 恢复对齐）', () {
      test('对齐到窗口内真实偏移', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000); // 间奏时长 6000ms
        dots.tick(0.016);
        // 帧时钟推进 2s（模拟 mute 前）
        dots.tick(2.0);
        expect(dots.animationTimeMs, closeTo(2016, 0.1));

        // 真实播放位置 5000ms → 窗口内偏移 = 5000-1000 = 4000
        dots.alignToRealTime(5000);
        expect(dots.animationTimeMs, closeTo(4000, 0.1));
      });

      test('超出窗口时 clamp 到 [0, 间奏时长]', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000); // 时长 6000ms
        dots.tick(0.016);
        // 窗口前（早于 gapStart）
        dots.alignToRealTime(500);
        expect(dots.animationTimeMs, closeTo(0, 0.1));
        // 窗口后（晚于 gapEnd）
        dots.alignToRealTime(10000);
        expect(dots.animationTimeMs, closeTo(6000, 0.1));
      });

      test('未激活间奏时调用无副作用', () {
        final dots = InterludeDots();
        dots.alignToRealTime(5000);
        expect(dots.shouldRender, isFalse);
        expect(dots.animationTimeMs, closeTo(0, 0.1));
      });
    });

    group('shouldRealignTo（时钟漂移检测）', () {
      test('正常播放（偏差小于阈值）不触发对齐', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000); // 时长 6000ms
        dots.tick(0.016);
        dots.tick(1.0); // 帧时钟 ≈ 1016ms
        // 真实位置 2000ms → 窗口偏移 1000ms，与帧时钟几乎同步
        expect(dots.shouldRealignTo(2000), isFalse);
      });

      test('帧时钟滞后（页面重建 / mute）时触发对齐', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 7000);
        dots.tick(0.016);
        dots.tick(1.0); // 帧时钟 ≈ 1016ms
        // 真实位置 5000ms → 窗口偏移 4000ms，偏差 ≈ 3000ms > 阈值
        expect(dots.shouldRealignTo(5000), isTrue);
        // 对齐后偏差归零，不再触发
        dots.alignToRealTime(5000);
        expect(dots.shouldRealignTo(5000), isFalse);
      });

      test('未激活间奏时不触发', () {
        final dots = InterludeDots();
        expect(dots.shouldRealignTo(5000), isFalse);
      });
    });

    group('isInExitPhase（区分自然结束与跳转离开）', () {
      test('未激活时返回 false', () {
        final dots = InterludeDots();
        expect(dots.isInExitPhase, isFalse);
      });

      test('间奏早期返回 false，末 750ms 返回 true', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 11000); // 时长 10000ms，距消失起点还有 9250ms
        expect(dots.isInExitPhase, isFalse);

        dots.tick(8.0); // 时钟 8000ms < 9250ms
        expect(dots.animationTimeMs, closeTo(8000, 0.1));
        expect(dots.isInExitPhase, isFalse);

        dots.tick(1.5); // 时钟 9500ms ≥ 9250ms
        expect(dots.animationTimeMs, closeTo(9500, 0.1));
        expect(dots.isInExitPhase, isTrue);
      });

      test('对齐到窗口末端后进入消失阶段（自然结束路径）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 11000);
        dots.alignToRealTime(11000); // clamp 到 时长 10000
        expect(dots.isInExitPhase, isTrue);
      });

      test('clear 后返回 false', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 11000);
        dots.tick(10.0);
        expect(dots.isInExitPhase, isTrue);
        dots.clear();
        expect(dots.isInExitPhase, isFalse);
      });
    });

    // 回归：省电模式（eco）下节奏点「最后收起」卡顿。
    //
    // 两条根因，各对应一组断言：
    //  1. 帧时钟被驱动的名义步长（16ms）拖慢，播放进度自然跨过间奏窗口终点时
    //     isInExitPhase 仍为 false → 旧实现误判"跳转离开"直接 clear，圆点没有
    //     缩小过程直接消失（"啪一下没了"）。
    //  2. 旧实现落后满 1000ms 才一次性 alignToRealTime 硬对齐 → 收起前段 scale
    //     突跳一档；现改为按比例单向小步追平。
    group('snapToExitPhase（自然结束补帧，不瞬灭）', () {
      test('时钟还停在间奏早期也能补到消失段起点（不后退）', () {
        final dots = InterludeDots();
        // 间奏时长 10000ms，消失段起点 = 10000 - 750 = 9250ms
        dots.setInterlude(1000, 11000);
        dots.tick(2.0); // 帧时钟仅 2000ms（模拟被名义步长拖慢）
        expect(dots.isInExitPhase, isFalse);

        dots.snapToExitPhase();
        expect(dots.animationTimeMs, closeTo(9250, 0.1));
        expect(dots.isInExitPhase, isTrue);
        expect(dots.shouldRender, isTrue,
            reason: '补帧后仍应保持激活，让消失动画继续播完而非直接清除');
      });

      test('已在消失段时不后退（保持连续）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 11000);
        dots.tick(9.5); // 时钟 9500ms，已进消失段
        final before = dots.animationTimeMs;

        dots.snapToExitPhase();
        expect(dots.animationTimeMs, before,
            reason: '只前进不后退：已在消失段内时不得回拨时钟');
      });

      test('未激活时调用无副作用', () {
        final dots = InterludeDots();
        dots.snapToExitPhase();
        expect(dots.shouldRender, isFalse);
        expect(dots.animationTimeMs, closeTo(0, 0.1));
      });
    });

    group('correctDriftGently（单向比例追平，替代硬跳）', () {
      test('先按上限限幅、残差变小后按比例减半，最终收敛到真实进度', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 41000); // 时长 40000ms（长间奏）
        // 人为制造 500ms 滞后：帧时钟 0，真实偏移 = 1500 - 1000 = 500
        expect(dots.animationTimeMs, closeTo(0, 0.1));

        final steps = <double>[];
        double prev = dots.animationTimeMs;
        for (int i = 0; i < 8; i++) {
          dots.correctDriftGently(1500);
          steps.add(dots.animationTimeMs - prev);
          prev = dots.animationTimeMs;
        }
        // 默认 maxStepMs=100、ratio=0.5：残差 >200ms 时被上限钳住（每次 100ms），
        // 之后按残差比例减半 → 台阶单调不增，不存在"一次性跳完"的可见突跳。
        for (int i = 1; i < steps.length; i++) {
          expect(steps[i], lessThanOrEqualTo(steps[i - 1]));
        }
        expect(steps.every((s) => s <= 100), isTrue);
        expect(prev, closeTo(493.75, 0.1),
            reason: '持续小步追平后应几乎贴合真实偏移，而非靠一次硬跳拽回');
        expect(dots.shouldRealignTo(1500, driftMs: 1000), isFalse);
      });

      test('单次修正不超过 maxStepMs（杜绝可见跳变）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 41000);
        // 巨大残差（模拟长时间落后）
        final advanced = dots.correctDriftGently(5000, maxStepMs: 100);
        expect(advanced, isTrue);
        expect(dots.animationTimeMs, closeTo(100, 0.1));
      });

      test('时钟超前真实值时不回拽（避免锯齿抽搐）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 41000);
        dots.tick(5.0); // 帧时钟 5000ms
        final before = dots.animationTimeMs;
        // 真实偏移仅 1000ms（时钟超前）
        final changed = dots.correctDriftGently(2000);
        expect(changed, isFalse);
        expect(dots.animationTimeMs, before);
      });

      test('已进入消失段不再修正（收起动画时长归时钟自己推进）', () {
        final dots = InterludeDots();
        dots.setInterlude(1000, 6000); // 时长 5000ms，消失段起点 4250ms
        dots.alignToRealTime(5900); // 进入消失段
        expect(dots.isInExitPhase, isTrue);
        final before = dots.animationTimeMs;
        expect(dots.correctDriftGently(1000), isFalse);
        expect(dots.animationTimeMs, before);
      });

      test('未激活时不修正', () {
        final dots = InterludeDots();
        expect(dots.correctDriftGently(3000), isFalse);
      });
    });

    group('间奏检测规则集成（参照 spec.md）', () {
      test('相邻行间隔 >= 4000ms 应触发间奏（由调用方判定，本类只接收时段）', () {
        final dots = InterludeDots();
        const currentEnd = 1000;
        const nextStart = 6000;
        const gap = nextStart - currentEnd;
        expect(gap, greaterThanOrEqualTo(LyricLayout.interludeThresholdMs));

        dots.setInterlude(currentEnd, nextStart - LyricLayout.interludeEarlyEndMs);
        dots.tick(0.016);
        expect(dots.isInterlude(currentEnd), isTrue);
        expect(dots.isInterlude(nextStart - LyricLayout.interludeEarlyEndMs - 1), isTrue);
        expect(dots.isInterlude(nextStart - LyricLayout.interludeEarlyEndMs), isFalse);
      });

      test('相邻行间隔 < 4000ms 不应触发间奏（调用方不调用 setInterlude）', () {
        final dots = InterludeDots();
        const currentEnd = 1000;
        const nextStart = 4000;
        const gap = nextStart - currentEnd;
        expect(gap, lessThan(LyricLayout.interludeThresholdMs));

        expect(dots.isInterlude(currentEnd), isFalse);
        expect(dots.shouldRender, isFalse);
      });
    });
  });
}
