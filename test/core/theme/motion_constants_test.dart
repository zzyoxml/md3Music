import 'dart:math' as math;
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/motion_constants.dart';

void main() {
  group('M3ExpressiveMotion', () {
    test('defaultSpring 是 SpringDescription 且阻尼比 0.825', () {
      expect(M3ExpressiveMotion.defaultSpring, isA<SpringDescription>());
      // SpringDescription 没有 .dampingRatio getter，通过 damping / (2*sqrt(mass*stiffness)) 反算
      final s = M3ExpressiveMotion.defaultSpring;
      final ratio = s.damping / (2 * math.sqrt(s.mass * s.stiffness));
      // M3 Expressive 推荐临界阻尼比 0.825（略低于 1.0 产生轻微过冲）
      expect(ratio, closeTo(0.825, 0.001));
    });

    test('defaultDuration 是 400ms', () {
      expect(M3ExpressiveMotion.defaultDuration.inMilliseconds, 400);
    });

    test('emphasisDuration 是 600ms（强调动画）', () {
      expect(M3ExpressiveMotion.emphasisDuration.inMilliseconds, 600);
    });

    test('expressiveEasing 是非空 Curves', () {
      expect(M3ExpressiveMotion.expressiveEasing, isNotNull);
    });

    test('emphasizedEasing 是非空 Curves', () {
      expect(M3ExpressiveMotion.emphasizedEasing, isNotNull);
    });
  });
}
