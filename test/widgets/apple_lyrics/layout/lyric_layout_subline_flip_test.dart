/// LyricLayout 副行（翻译/罗马音）日历式翻转动效的几何单元测试
///
/// 覆盖：入场/出场角度端点、单调性、越界钳制、就位态恒 0（画布变换短路依据）、
/// 锚线不动性（绕锚线旋转的不动点）、去透视后的纯压缩解析式。
/// 绘制像素由渲染器测试（RecordingCanvas 记录 transform）与真机验证负责。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart'; // Matrix4 / MatrixUtils / Offset
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

void main() {
  const double eps = 1e-9;

  group('LyricLayout.sublineFlipAngle', () {
    test('入场：expand=0 副行侧立（-90°），expand=1 就位（0°）', () {
      expect(LyricLayout.sublineFlipAngle(0, exiting: false),
          closeTo(-math.pi / 2, eps));
      expect(LyricLayout.sublineFlipAngle(1, exiting: false), closeTo(0, eps));
    });

    test('出场：expand=1 就位（0°），expand=0 向上转走（+90°）', () {
      expect(LyricLayout.sublineFlipAngle(1, exiting: true), closeTo(0, eps));
      expect(LyricLayout.sublineFlipAngle(0, exiting: true),
          closeTo(math.pi / 2, eps));
    });

    test('入场随 expand 递增、出场随 expand 递减（死区外全程无回折）', () {
      double prevIn = -math.pi / 2;
      double prevOut = math.pi / 2;
      // 只取 0.05~0.80：p ≥ 0.85 落在死区内，角度恒为 0，本就不是严格单调
      for (int i = 1; i <= 16; i++) {
        final double p = i * 0.05;
        final double a = LyricLayout.sublineFlipAngle(p, exiting: false);
        expect(a, greaterThan(prevIn));
        prevIn = a;
        final double b = LyricLayout.sublineFlipAngle(p, exiting: true);
        expect(b, lessThan(prevOut));
        prevOut = b;
      }
    });

    test('同进度下入场/出场转角大小相等、符号相反（交接帧高度连续）', () {
      for (final double p in <double>[0.2, 0.5, 0.8, 0.95]) {
        final double entering = LyricLayout.sublineFlipAngle(p, exiting: false);
        final double exiting = LyricLayout.sublineFlipAngle(p, exiting: true);
        expect(entering, closeTo(-exiting, eps),
            reason: '切行交接时 expand 连续 → 转角镜像，视觉高度不跳变');
      }
    });

    test('就位态恒等于 0（渲染器据此跳过画布变换）', () {
      expect(LyricLayout.sublineFlipAngle(1.0, exiting: false) == 0, isTrue);
      expect(LyricLayout.sublineFlipAngle(1.0, exiting: true) == 0, isTrue);
      expect(LyricLayout.sublineFlipAngle(1.5, exiting: false) == 0, isTrue);
    });

    test('越界输入钳制到 [0,1]', () {
      expect(LyricLayout.sublineFlipAngle(-0.5, exiting: false),
          closeTo(-math.pi / 2, eps));
      expect(LyricLayout.sublineFlipAngle(-0.5, exiting: true),
          closeTo(math.pi / 2, eps));
      expect(LyricLayout.sublineFlipAngle(9.9, exiting: true), closeTo(0, eps));
    });

    test('死区：离位量 ≤ 0.15 时角度归零（杜绝指数拖尾）', () {
      // 死区内部：恒为 0（渲染器据此跳过画布变换）
      expect(LyricLayout.sublineFlipAngle(0.9, exiting: false) == 0, isTrue);
      expect(LyricLayout.sublineFlipAngle(0.9, exiting: true) == 0, isTrue);
      // 边界 q≈0.15：只剩 1e-8 量级的浮点残角（0.85 无法精确表示），按量级断言
      expect(LyricLayout.sublineFlipAngle(0.85, exiting: false).abs(),
          lessThan(1e-6));
      expect(LyricLayout.sublineFlipAngle(0.85, exiting: true).abs(),
          lessThan(1e-6));
      // 死区之外必须仍有转角，否则翻转会被整体吃掉
      expect(LyricLayout.sublineFlipAngle(0.8, exiting: false).abs(),
          greaterThan(0.1));
    });

    test('过半进度时入场转角大于线性映射（翻转在半透明阶段仍可见）', () {
      final double half = LyricLayout.sublineFlipAngle(0.5, exiting: false);
      final double cut = LyricLayout.sublineFlipSettleCut;
      final double t = (0.5 - cut) / (1 - cut); // 去死区后的离位量
      expect(half, closeTo(-math.pi / 2 * math.sqrt(t), eps));
      expect(half, lessThan(-math.pi / 4),
          reason: '比线性 -45° 转得更多，副行不透明阶段才看得见翻转');
    });
  });

  group('LyricLayout.sublineFlipAnchor', () {
    test('入场锚在副行底边、出场锚在副行顶边，x 恒为副行水平中点', () {
      final Offset entering = LyricLayout.sublineFlipAnchor(
        transX: 22,
        sublineWidth: 100,
        transY: 100,
        sublineHeight: 21,
        exiting: false,
      );
      expect(entering.dy, closeTo(121, eps), reason: '入场锚线 = 副行底边');
      expect(entering.dx, closeTo(72, eps), reason: 'x = 副行水平中点（透视投影中心）');

      final Offset exiting = LyricLayout.sublineFlipAnchor(
        transX: 22,
        sublineWidth: 100,
        transY: 100,
        sublineHeight: 21,
        exiting: true,
      );
      expect(exiting.dy, closeTo(100, eps), reason: '出场锚线 = 副行顶边');
      expect(exiting.dx, closeTo(72, eps));
    });
  });

  group('LyricLayout.sublineFlipMatrix', () {
    test('perspective=0 时退化为绕锚线的纯 2D 压缩（x 不变、dy×cosθ）', () {
      const Offset anchor = Offset(0, 200);
      const double d = 10; // 离锚线距离
      const double angle = -math.pi / 3;
      final Matrix4 m = LyricLayout.sublineFlipMatrix(
          angle: angle, anchor: anchor, perspective: 0);
      final Offset p = MatrixUtils.transformPoint(
          m, Offset(50, anchor.dy - d));
      expect(p.dx, closeTo(50, eps), reason: '绕 x 轴旋转不改变 x（无透视时 w=1）');
      expect(p.dy, closeTo(anchor.dy - d * math.cos(angle), eps));
    });

    test('默认透视下锚线严格不动（锚线 z=0 → w=1，不受透视影响）', () {
      const Offset anchor = Offset(0, 137.5);
      for (final double angle in <double>[-1.2, -0.5, 0.0, 0.7, 1.4]) {
        final Matrix4 m = LyricLayout.sublineFlipMatrix(
            angle: angle, anchor: anchor);
        final Offset p = MatrixUtils.transformPoint(
            m, Offset(88, anchor.dy));
        expect(p.dx, closeTo(88, eps));
        expect(p.dy, closeTo(anchor.dy, eps));
      }
    });

    test('默认透视下离轴点仍向锚线压缩（透视只改幅度不改方向）', () {
      const Offset anchor = Offset(0, 300);
      const double d = 12;
      final Matrix4 m = LyricLayout.sublineFlipMatrix(
          angle: -math.pi / 3, anchor: anchor);
      final Offset p =
          MatrixUtils.transformPoint(m, Offset(0, anchor.dy - d));
      // 点位于锚线上方 d 处（y=288），变换后应**向锚线（下方）靠近**，
      // 即 p.dy 变大 —— 压缩量 = 终点 - 起点。
      // 容差按「压缩量」取相对值（12px 离轴 → 理论压缩 6px），
      // 不用绝对坐标做相对量纲，否则断言形同虚设。
      final double compression = p.dy - (anchor.dy - d);
      final double expected = d - d * math.cos(math.pi / 3); // 6.0
      expect(compression, closeTo(expected, expected * 0.15 + 0.05),
          reason: '透视让压缩量有 ±11% 偏差，给 15% 容差');
      expect(compression, greaterThan(0), reason: '必须向锚线压缩而非外扩');
    });

    test('投影中心随锚点 x 平移：左右对称点不再整体左漂', () {
      // 回归：透视除法若绕画布原点（左上角）进行，副行在 x=250 附近会被拉左
      // 约 25px（真机观感「偏左」）。锚点带上 x 后，左右应严格对称。
      const Offset anchor = Offset(250, 300);
      const double d = 12;
      const double halfW = 50;
      final Matrix4 m =
          LyricLayout.sublineFlipMatrix(angle: -math.pi / 3, anchor: anchor);
      final Offset left = MatrixUtils.transformPoint(
          m, Offset(anchor.dx - halfW, anchor.dy - d));
      final Offset right = MatrixUtils.transformPoint(
          m, Offset(anchor.dx + halfW, anchor.dy - d));
      expect(anchor.dx - left.dx, closeTo(right.dx - anchor.dx, 1e-6),
          reason: '左右到投影中心的水平距离必须相等（不能单向平移）');
      expect(left.dx, lessThan(anchor.dx), reason: '两点都向投影中心靠拢');
      expect(right.dx, greaterThan(anchor.dx));
    });
  });
}
