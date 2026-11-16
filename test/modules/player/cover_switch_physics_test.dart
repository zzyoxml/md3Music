import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/cover_switch_physics.dart';

void main() {
  group('coverSlideOffset', () {
    test('进度 0 时当前页居中，相邻页各偏一页', () {
      expect(coverSlideOffset(offset: 0, progress: 0, pitch: 320), 0);
      expect(coverSlideOffset(offset: 1, progress: 0, pitch: 320), 320);
      expect(coverSlideOffset(offset: -1, progress: 0, pitch: 320), -320);
    });

    test('进度 +1 时下一首居中，当前页退到左侧一页', () {
      expect(coverSlideOffset(offset: 1, progress: 1, pitch: 320), 0);
      expect(coverSlideOffset(offset: 0, progress: 1, pitch: 320), -320);
    });
  });

  group('coverParallaxOffset', () {
    test('静止与落位时为 0：图像与卡片框完全重合（静止态外观零变化）', () {
      expect(coverParallaxOffset(offset: 0, progress: 0, pitch: 320), 0);
      expect(coverParallaxOffset(offset: 1, progress: 1, pitch: 320), 0);
      expect(coverParallaxOffset(offset: -1, progress: -1, pitch: 320), 0);
    });

    test('拖到半页：当前页图像朝右（视口中央方向）偏 lag×半页', () {
      // 卡片被拖到中央左侧 -160，图像要往右留 0.35×160 = 56
      expect(
        coverParallaxOffset(offset: 0, progress: 0.5, pitch: 320),
        closeTo(56, 1e-9),
      );
    });

    test('下一首从右侧进场时，其图像也朝左（视口中央方向）偏', () {
      expect(
        coverParallaxOffset(offset: 1, progress: 0.5, pitch: 320),
        closeTo(-56, 1e-9),
      );
    });

    test('恰好等于 -lag × 卡片框位移（同一条 x(o,p)，不做第二套坐标）', () {
      for (final int offset in [-1, 0, 1]) {
        for (double p = -1; p <= 1; p += 0.1) {
          final frame = coverSlideOffset(offset: offset, progress: p, pitch: 300);
          final parallax = coverParallaxOffset(
            offset: offset,
            progress: p,
            pitch: 300,
          );
          expect(parallax, closeTo(-kCoverParallaxLag * frame, 1e-9));
        }
      }
    });

    test('图像在屏幕上始终比卡片框更靠近视口中央，且不被推过中央', () {
      for (final int offset in [-1, 0, 1]) {
        for (double p = -1; p <= 1; p += 0.05) {
          final double frame = coverSlideOffset(
            offset: offset,
            progress: p,
            pitch: 320,
          );
          final double image =
              frame + coverParallaxOffset(offset: offset, progress: p, pitch: 320);
          expect(image.abs(), lessThanOrEqualTo(frame.abs() + 1e-9));
          if (frame.abs() > 1e-9) expect(image.sign, frame.sign);
        }
      }
    });
  });

  group('coverDragProgress', () {
    test('手指左移推进到下一首', () {
      expect(
        coverDragProgress(
          progress: 0,
          dx: -160,
          pitch: 320,
          minProgress: -1,
          maxProgress: 1,
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('手指右移退回上一首', () {
      expect(
        coverDragProgress(
          progress: 0,
          dx: 80,
          pitch: 320,
          minProgress: -1,
          maxProgress: 1,
        ),
        closeTo(-0.25, 1e-9),
      );
    });

    test('越过可翻页边界后按橡皮筋衰减，最多只多出 0.35 页', () {
      final overscrolled = coverDragProgress(
        progress: 0,
        dx: -3200,
        pitch: 320,
        minProgress: -1,
        maxProgress: 0,
      );
      expect(overscrolled, greaterThan(0));
      expect(overscrolled, lessThan(0.35));
    });

    test('pitch 为 0（尚未布局）时保持原值', () {
      expect(
        coverDragProgress(
          progress: 0.3,
          dx: -120,
          pitch: 0,
          minProgress: -1,
          maxProgress: 1,
        ),
        0.3,
      );
    });
  });

  group('coverSettleTarget', () {
    test('手指停住再松手（速度≈0）：位移过半落下一页', () {
      expect(
        coverSettleTarget(
          progress: 0.6,
          velocityPxPerSec: 0,
          minProgress: -1,
          maxProgress: 1,
        ),
        1,
      );
    });

    test('手指停住再松手：位移不过半回到当前页', () {
      expect(
        coverSettleTarget(
          progress: 0.3,
          velocityPxPerSec: 0,
          minProgress: -1,
          maxProgress: 1,
        ),
        0,
      );
    });

    test('甩动（50px/s 以上）不管拖了多远都推进整页 —— 惯性判定的核心', () {
      // 只拖了 0.08 页（约 30px）就快速甩出：必须翻页，而不是弹回。
      expect(
        coverSettleTarget(
          progress: 0.08,
          velocityPxPerSec: 1200,
          minProgress: -1,
          maxProgress: 1,
        ),
        1,
      );
      expect(
        coverSettleTarget(
          progress: 0.4,
          velocityPxPerSec: 900,
          minProgress: -1,
          maxProgress: 1,
        ),
        1,
      );
    });

    test('反向甩动同理：位移已过半也退回上一首', () {
      expect(
        coverSettleTarget(
          progress: -0.08,
          velocityPxPerSec: -1200,
          minProgress: -1,
          maxProgress: 1,
        ),
        -1,
      );
      expect(
        coverSettleTarget(
          progress: -0.6,
          velocityPxPerSec: -200,
          minProgress: -1,
          maxProgress: 1,
        ),
        -1,
      );
    });

    test('刚好在阈值上（50px/s）算甩动', () {
      expect(
        coverSettleTarget(
          progress: 0.1,
          velocityPxPerSec: kCoverFlingVelocityPxPerSec,
          minProgress: -1,
          maxProgress: 1,
        ),
        1,
      );
    });

    test('阈值以下的极慢速度不算甩动，仍按位移判定', () {
      expect(
        coverSettleTarget(
          progress: 0.1,
          velocityPxPerSec: kCoverFlingVelocityPxPerSec - 1,
          minProgress: -1,
          maxProgress: 1,
        ),
        0,
      );
    });

    test('没有下一首时目标被夹回 0（= 原地回弹），甩得再快也一样', () {
      expect(
        coverSettleTarget(
          progress: 0.9,
          velocityPxPerSec: 1500,
          minProgress: -1,
          maxProgress: 0,
        ),
        0,
      );
      expect(
        coverSettleTarget(
          progress: 0.2,
          velocityPxPerSec: 1500,
          minProgress: -1,
          maxProgress: 0,
        ),
        0,
      );
    });

    test('没有上一首时同理', () {
      expect(
        coverSettleTarget(
          progress: -0.9,
          velocityPxPerSec: -1500,
          minProgress: 0,
          maxProgress: 1,
        ),
        0,
      );
    });
  });

  group('coverSettleSimulation', () {
    /// 以 1ms 步长把仿真跑到 [milliseconds]，返回过程中出现过的极值。
    ({double min, double max, double end}) run(
      Simulation sim, {
      int milliseconds = 2000,
    }) {
      double lo = double.infinity;
      double hi = double.negativeInfinity;
      for (int t = 0; t <= milliseconds; t++) {
        final double x = sim.x(t / 1000);
        lo = x < lo ? x : lo;
        hi = x > hi ? x : hi;
      }
      return (min: lo, max: hi, end: sim.x(milliseconds / 1000));
    }

    test('从静止起步：落在目标上，且不过冲（页只有三张，过冲会露空白）', () {
      final result = run(
        coverSettleSimulation(from: 0.4, to: 1, velocity: 0),
      );
      expect(result.end, closeTo(1, 0.01));
      expect(result.max, lessThanOrEqualTo(1 + 0.001));
    });

    test('带甩动速度（6 页/秒）也不越过目标 —— 过阻尼弹簧的硬约束', () {
      final result = run(
        coverSettleSimulation(from: 0.1, to: 1, velocity: 6),
      );
      expect(result.end, closeTo(1, 0.01));
      expect(result.max, lessThanOrEqualTo(1 + 0.001));
    });

    test('反向甩动带速度回到 0，也不会越过 0', () {
      final result = run(
        coverSettleSimulation(from: 0.6, to: 0, velocity: -6),
      );
      expect(result.end, closeTo(0, 0.01));
      expect(result.min, greaterThanOrEqualTo(-0.001));
    });

    test('从越界位（橡皮筋区）回弹到边界内，且不越过边界', () {
      final result = run(
        coverSettleSimulation(from: 0.33, to: 0, velocity: 0),
      );
      expect(result.end, closeTo(0, 0.01));
      expect(result.max, lessThanOrEqualTo(0.33 + 0.001));
      expect(result.min, greaterThanOrEqualTo(-0.001));
    });

    test('带速度时不会「停一下再走」：开始阶段位移单调朝目标推', () {
      final sim = coverSettleSimulation(from: 0.2, to: 1, velocity: 4);
      // 头 50ms 内必须已经明显前进（若起始速度被丢弃，前 50ms 只走零头）
      expect(sim.x(0.05), greaterThan(0.35));
    });
  });

  group('coverSwitchIntentForTarget', () {
    test('落点是 ±1 才产生切歌意图', () {
      expect(coverSwitchIntentForTarget(1), CoverSwitchIntent.next);
      expect(coverSwitchIntentForTarget(-1), CoverSwitchIntent.previous);
      expect(coverSwitchIntentForTarget(0), isNull);
    });
  });

  group('coverSlideDirectionForIndexChange', () {
    test('相邻下标给出 ±1', () {
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 2,
          toIndex: 3,
          playlistLength: 5,
        ),
        1,
      );
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 3,
          toIndex: 2,
          playlistLength: 5,
        ),
        -1,
      );
    });

    test('首尾绕回也算相邻', () {
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 4,
          toIndex: 0,
          playlistLength: 5,
        ),
        1,
      );
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 0,
          toIndex: 4,
          playlistLength: 5,
        ),
        -1,
      );
    });

    test('任意跳转 / 下标未变 / 单曲队列都返回 0', () {
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 1,
          toIndex: 4,
          playlistLength: 5,
        ),
        0,
      );
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 2,
          toIndex: 2,
          playlistLength: 5,
        ),
        0,
      );
      expect(
        coverSlideDirectionForIndexChange(
          fromIndex: 0,
          toIndex: 0,
          playlistLength: 1,
        ),
        0,
      );
    });
  });
}
