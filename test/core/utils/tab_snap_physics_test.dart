import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/tab_snap_physics.dart';

void main() {
  group('TabSnapPhysics', () {
    test('弹簧为 stiffness 240 / 临界阻尼（ratio 1.0）', () {
      const physics = TabSnapPhysics();
      final spring = physics.spring;
      expect(spring.stiffness, 240);
      final ratio =
          spring.damping / (2.0 * math.sqrt(spring.mass * spring.stiffness));
      expect(ratio, closeTo(1.0, 1e-9));
      // 与框架默认弹簧（stiffness 100 / ratio 1.1）区分开，确认覆写生效
      final defaultSpring = const ClampingScrollPhysics().spring;
      expect(spring.stiffness, isNot(defaultSpring.stiffness));
    });

    test('PageScrollPhysics 挂链后取到本弹簧（material_ui TabBarView 传参路径）', () {
      final chained = PageScrollPhysics().applyTo(const TabSnapPhysics());
      final spring = chained.spring;
      expect(spring.stiffness, 240);
      expect(spring.damping, closeTo(2.0 * math.sqrt(0.5 * 240), 1e-9));
    });

    test('applyTo 保型并保留祖先链', () {
      const physics = TabSnapPhysics();
      final applied = physics.applyTo(const ClampingScrollPhysics());
      expect(applied, isA<TabSnapPhysics>());
      expect(applied.parent, isA<ClampingScrollPhysics>());
    });
  });
}
