import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/sleep_timer_polygon.dart';

/// 取形状上所有 cubic 端点到中心的半径，用来判断有没有内凹（齿轮感）。
Iterable<double> _radii(int hours) sync* {
  for (final cubic in sleepTimerPolygon(hours).cubics) {
    yield math.sqrt(
      cubic.anchor0X * cubic.anchor0X + cubic.anchor0Y * cubic.anchor0Y,
    );
    yield math.sqrt(
      cubic.anchor1X * cubic.anchor1X + cubic.anchor1Y * cubic.anchor1Y,
    );
  }
}

void main() {
  group('sleepTimerShapeIndexForHour', () {
    test('确定性：同一小时每次都得到同一种形状', () {
      // 非确定性会让表盘每帧重建都换形状 → 看起来像闪烁
      for (var h = 0; h <= kSleepTimerMaxHours; h++) {
        expect(sleepTimerShapeIndexForHour(h), sleepTimerShapeIndexForHour(h));
      }
    });

    test('下标始终落在形状池内', () {
      for (var h = 0; h <= 40; h++) {
        expect(
          sleepTimerShapeIndexForHour(h),
          inInclusiveRange(0, kSleepTimerShapes.length - 1),
        );
      }
    });

    test('相邻小时一定换形状（小时数一变就看得出区别）', () {
      for (var h = 1; h <= kSleepTimerMaxHours; h++) {
        expect(
          sleepTimerShapeIndexForHour(h),
          isNot(sleepTimerShapeIndexForHour(h - 1)),
          reason: '$h 小时与 ${h - 1} 小时撞到了同一种形状',
        );
      }
    });

    test('形状池的尖角数有区分度，不是清一色', () {
      final vertices = kSleepTimerShapes.map((s) => s.vertices).toSet();
      expect(vertices.length, greaterThanOrEqualTo(5), reason: '尖角数要有区分度');
    });
  });

  group('sleepTimerShapeScale', () {
    test('0 小时是圆，额外缩小以补偿视觉面积', () {
      expect(sleepTimerShapeScale(0), lessThan(1));
      expect(sleepTimerShapeScale(0), closeTo(0.86, 1e-9));
    });

    test('有小时数时不缩放', () {
      for (var h = 1; h <= kSleepTimerMaxHours; h++) {
        expect(sleepTimerShapeScale(h), 1.0);
      }
    });
  });

  group('sleepTimerPolygon', () {
    test('0 小时是圆：所有采样点半径都在 1 上（没有内凹）', () {
      final radii = _radii(0).toList();
      expect(radii, isNotEmpty);
      for (final r in radii) {
        expect(r, closeTo(1, 0.01));
      }
    });

    test('每个小时都是齿轮形：存在明显内凹的谷底', () {
      for (var h = 1; h <= kSleepTimerMaxHours; h++) {
        final min = _radii(h).reduce(math.min);
        expect(
          min,
          lessThan(0.95),
          reason: '$h 小时的形状没有内凹（最小半径 $min）——正多边形不会有谷底',
        );
      }
    });

    test('归一化后每个形状都居中，且外接框统一为 2×2', () {
      // 回归点：`RoundedPolygon.star` 的包围盒不关于原点对称（5 角星是
      // x∈[-0.7, 1]），不归一化会画得偏心、且各小时大小不一。
      for (var h = 0; h <= kSleepTimerMaxHours; h++) {
        final t = sleepTimerShapeTransform(h);
        final b = sleepTimerPolygonPath(h).getBounds();
        expect((b.center.dx + t.dx) * t.scale, closeTo(0, 1e-9), reason: '$h 小时横向未居中');
        expect((b.center.dy + t.dy) * t.scale, closeTo(0, 1e-9), reason: '$h 小时纵向未居中');
        expect(math.max(b.width, b.height) * t.scale, closeTo(2, 1e-9), reason: '$h 小时尺寸不一致');
      }
    });

    test('0 小时的圆是恒等变换', () {
      final t = sleepTimerShapeTransform(0);
      expect(t.scale, closeTo(1, 1e-2));
      expect(t.dx, closeTo(0, 1e-2));
      expect(t.dy, closeTo(0, 1e-2));
    });

    test('谷底半径不小于文字安全区下限 0.66', () {
      for (final s in kSleepTimerShapes) {
        expect(s.innerRadius, greaterThanOrEqualTo(0.66));
        expect(s.innerRadius, lessThan(1));
      }
    });

    test('同一小时复用缓存，不同小时不共享 Path', () {
      expect(identical(sleepTimerPolygonPath(3), sleepTimerPolygonPath(3)), isTrue);
      expect(
        identical(sleepTimerPolygonPath(3), sleepTimerPolygonPath(4)),
        isFalse,
      );
    });
  });
}
