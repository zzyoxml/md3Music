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
