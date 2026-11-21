import 'dart:math' as math;

import 'package:flutter/animation.dart' show Curves;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/cover_flip_physics.dart';
import 'package:md3music/modules/player/cover_swipe_flip_physics.dart';

void main() {
  group('进度 → 角度', () {
    test('线性且 p=1 恰好侧立 90°', () {
      expect(coverSwipeOldAngle(0), 0);
      expect(coverSwipeOldAngle(kCoverFlipSwap * 0.5),
          closeTo(math.pi / 4, 1e-9));
      expect(coverSwipeOldAngle(kCoverFlipSwap),
          closeTo(math.pi / 2, 1e-9));
    });

    test('允许负向过冲但被钳住（回弹力度可见、不翻过头）', () {
      expect(coverSwipeOldAngle(-0.01), lessThan(0));
      expect(coverSwipeOldAngle(-10),
          closeTo(-0.12 * math.pi / 2, 1e-9));
      expect(coverSwipeOldAngle(1.0), closeTo(math.pi / 2, 1e-9));
    });
  });

  group('橡皮筋复用', () {
    test('左拖 / 右拖都推进进度（direction 换算正确）', () {
      const pitch = 240.0;
      final left = coverDragProgressForSwipe(
          progress: 0, dx: -24, pitch: pitch, direction: 1, canSwitch: true);
      final right = coverDragProgressForSwipe(
          progress: 0, dx: 24, pitch: pitch, direction: -1, canSwitch: true);
      expect(left, closeTo(0.1, 1e-9));
      expect(right, closeTo(0.1, 1e-9));
    });

    test('无邻居的一侧只出橡皮筋，永不超过上限', () {
      final p = coverDragProgressForSwipe(
          progress: 0, dx: -2400, pitch: 240, direction: 1, canSwitch: false);
      expect(p, greaterThan(0));
      expect(p, lessThanOrEqualTo(kCoverSwipeOverscrollPages));
    });
  });

  group('CoverSwipeKinematics', () {
    test('匀速样本给正速度、零加速度', () {
      final k = CoverSwipeKinematics();
      k.reset(const Duration(milliseconds: 0), 0);
      for (var i = 1; i <= 5; i++) {
        k.addSample(Duration(milliseconds: i * 16), -10.0 * i);
      }
      expect(k.velocity, lessThan(0)); // 左移为负（手指 x 坐标）
      expect(k.acceleration.abs(), lessThan(1.0));
    });

    test('右移加速样本给正加速度（x 坐标系：右为正）', () {
      final k = CoverSwipeKinematics();
      k.reset(const Duration(milliseconds: 0), 0);
      var x = 0.0;
      for (var i = 1; i <= 5; i++) {
        x += 4.0 * i; // 每拍位移递增 = 加速
        k.addSample(Duration(milliseconds: i * 16), x);
      }
      expect(k.velocity, greaterThan(0));
      expect(k.acceleration, greaterThan(0));
    });

    test('dt<1ms 样本被丢弃，不产生无穷速度', () {
      final k = CoverSwipeKinematics();
      k.reset(const Duration(milliseconds: 0), 0);
      k.addSample(const Duration(microseconds: 100), -100);
      expect(k.velocity.isFinite, isTrue);
      expect(k.acceleration.isFinite, isTrue);
      expect(k.acceleration.abs(), lessThanOrEqualTo(40000));
    });
  });

  group('coverSwipeShouldCommit', () {
    test('位移过半即提交', () {
      expect(
        coverSwipeShouldCommit(
            progress: 0.6, velocity: 0, acceleration: 0, canSwitch: true),
        isTrue,
      );
    });

    test('速度达标（未过半）也提交', () {
      expect(
        coverSwipeShouldCommit(
            progress: 0.2, velocity: 1200, acceleration: 0, canSwitch: true),
        isTrue,
      );
    });

    test('加速度达标（速度未达标）也提交，末端减速同样算强甩动', () {
      expect(
        coverSwipeShouldCommit(
            progress: 0.2, velocity: 400, acceleration: 9000, canSwitch: true),
        isTrue,
      );
      expect(
        coverSwipeShouldCommit(
            progress: 0.2, velocity: 400, acceleration: -9000, canSwitch: true),
        isTrue,
      );
    });

    test('回拉否决优先：距离/加速度都达标也不提交', () {
      expect(
        coverSwipeShouldCommit(
            progress: 0.9,
            velocity: -300,
            acceleration: 20000,
            canSwitch: true),
        isFalse,
      );
    });

    test('起手抖动（progress≈0）不提交；无邻居不提交', () {
      expect(
        coverSwipeShouldCommit(
            progress: 0.01,
            velocity: 2000,
            acceleration: 30000,
            canSwitch: true),
        isFalse,
      );
      expect(
        coverSwipeShouldCommit(
            progress: 0.9, velocity: 2000, acceleration: 0, canSwitch: false),
        isFalse,
      );
    });
  });

  group('回弹与过冲分档', () {
    test('强度随甩动能量单调分三档', () {
      expect(coverSwipeReboundStrength(velocity: 0, acceleration: 0),
          CoverSwipeReboundStrength.gentle);
      expect(coverSwipeReboundStrength(velocity: 800, acceleration: 0),
          CoverSwipeReboundStrength.medium);
      expect(coverSwipeReboundStrength(velocity: 2000, acceleration: 30000),
          CoverSwipeReboundStrength.hard);
    });

    test('三档弹簧刚度递增、阻尼比递减（力度确有区别）', () {
      final springs = CoverSwipeReboundStrength.values
          .map(coverSwipeReboundSpring)
          .toList();
      // SpringDescription 只留 damping，阻尼比按定义反算：ζ = c / (2√(mk))。
      final ratios = springs
          .map((s) => s.damping / (2 * math.sqrt(s.mass * s.stiffness)))
          .toList();
      for (var i = 1; i < springs.length; i++) {
        expect(springs[i].stiffness, greaterThan(springs[i - 1].stiffness));
        expect(ratios[i], lessThan(ratios[i - 1]));
      }
    });

    test('overshoot 分档递增；1.0 档与 Curves.easeOutBack 逐点等价', () {
      expect(coverSwipeOvershoot(CoverSwipeReboundStrength.gentle),
          lessThan(1.0));
      expect(coverSwipeOvershoot(CoverSwipeReboundStrength.medium), 1.0);
      expect(coverSwipeOvershoot(CoverSwipeReboundStrength.hard),
          greaterThan(1.0));
      for (var i = 0; i <= 20; i++) {
        final t = kCoverFlipSwap + (1 - kCoverFlipSwap) * i / 20;
        expect(coverFlipNewRotationProgress(t),
            closeTo(Curves.easeOutBack.transform(i / 20), 1e-12));
      }
    });
  });
}
