import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/flowing_background_palette.dart';
import 'package:md3music/widgets/flowing_palette_transition.dart';

/// 调色板交叉淡化的纯函数语义（不依赖 GPU / widget / 图片解码）。
///
/// 覆盖：
/// - 构造与收敛：稳态 `current` 就是目标实例，过渡结束逐值相等；
/// - 混合：4 pigment + base + 32 运动色都参与，取值严格落在起终点之间；
/// - 可中断：过渡中 retarget 以「当前混合值」为新起点，`advance(0)` 不跳变；
/// - 边界：`duration == 0` 立即生效、目标未变不重启、色域与 NaN 安全。
void main() {
  FlowingPalette paletteOf(Color seed) => buildFlowingPalette(<Color>[seed]);

  final paletteA = paletteOf(const Color(0xFF3366CC));
  final paletteB = paletteOf(const Color(0xFFCC5533));

  /// 亮度近似（与 palette 测试同款口径，避免引入 HSV 依赖）。
  double lightness(Color c) {
    final values = <double>[c.r, c.g, c.b]..sort();
    return (values.first + values.last) / 2;
  }

  /// 断言 [mid] 落在 [from]→[to] 之间（含端点，容差覆盖浮点往返）。
  void expectBetween(double mid, double from, double to, {String? reason}) {
    final lo = math.min(from, to) - 1e-9;
    final hi = math.max(from, to) + 1e-9;
    expect(mid >= lo && mid <= hi, isTrue,
        reason: '${reason ?? ''} mid=$mid 不在 [$lo, $hi]');
  }

  group('构造与收敛', () {
    test('构造时 current 就是 initial，且不处于过渡', () {
      final transition = FlowingPaletteTransition(initial: paletteA);
      expect(identical(transition.current, paletteA), isTrue);
      expect(transition.isAnimating, isFalse);
      expect(transition.advance(const Duration(milliseconds: 16)), isFalse,
          reason: '没在过渡时推进必须返回 false');
    });

    test('推进满时长后收敛到目标实例，逐值相等且不再动画', () {
      final transition = FlowingPaletteTransition(initial: paletteA);
      expect(transition.retarget(paletteB), isTrue, reason: '换了目标就要过渡');
      expect(transition.isAnimating, isTrue);

      expect(transition.advance(const Duration(milliseconds: 450)), isTrue,
          reason: '半程仍在过渡');
      expect(transition.advance(const Duration(milliseconds: 450)), isFalse,
          reason: '满 900ms 必须收敛');

      expect(identical(transition.current, paletteB), isTrue,
          reason: '收敛后直接指向目标实例（保证最终帧与目标逐值相等）');
      expect(transition.current.pigments, equals(paletteB.pigments));
      expect(transition.current.motionColors, equals(paletteB.motionColors));
      expect(transition.current.baseColor, equals(paletteB.baseColor));
    });

    test('settle 立即生效且清空过渡', () {
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB);
      transition.advance(const Duration(milliseconds: 300));
      transition.settle(paletteA);
      expect(identical(transition.current, paletteA), isTrue);
      expect(transition.isAnimating, isFalse);
    });
  });

  group('混合取值', () {
    test('中点：4 个 pigment 逐通道落在 from→to 之间，且不等于两端', () {
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB)
        ..advance(const Duration(milliseconds: 450));
      final mid = transition.current;

      for (var i = 0; i < 4; i++) {
        expectBetween(mid.pigments[i].r, paletteA.pigments[i].r,
            paletteB.pigments[i].r,
            reason: 'pigment[$i].r');
        expectBetween(mid.pigments[i].g, paletteA.pigments[i].g,
            paletteB.pigments[i].g,
            reason: 'pigment[$i].g');
        expectBetween(mid.pigments[i].b, paletteA.pigments[i].b,
            paletteB.pigments[i].b,
            reason: 'pigment[$i].b');
      }
      expect(mid.pigments, isNot(equals(paletteA.pigments)),
          reason: '中点不得停在起点');
      expect(mid.pigments, isNot(equals(paletteB.pigments)),
          reason: '中点不得提前到终点');
    });

    test('base 与 32 个运动色同样参与混合', () {
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB)
        ..advance(const Duration(milliseconds: 450));
      final mid = transition.current;

      expectBetween(mid.baseColor.r, paletteA.baseColor.r, paletteB.baseColor.r,
          reason: 'base.r');
      expectBetween(mid.baseColor.g, paletteA.baseColor.g, paletteB.baseColor.g,
          reason: 'base.g');
      expectBetween(mid.baseColor.b, paletteA.baseColor.b, paletteB.baseColor.b,
          reason: 'base.b');

      expect(mid.motionColors.length, paletteA.motionColors.length);
      for (var i = 0; i < mid.motionColors.length; i++) {
        expectBetween(mid.motionColors[i].g, paletteA.motionColors[i].g,
            paletteB.motionColors[i].g,
            reason: 'motionColors[$i].g');
      }
      expect(mid.motionColors, isNot(equals(paletteA.motionColors)));
    });

    test('不同进度的取值单调逼近目标（quintic 缓动不越界）', () {
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB);
      double distanceToTarget() {
        final current = transition.current;
        var sum = 0.0;
        for (var i = 0; i < 4; i++) {
          sum += (current.pigments[i].r - paletteB.pigments[i].r).abs();
        }
        return sum;
      }

      transition.advance(const Duration(milliseconds: 225));
      final early = distanceToTarget();
      transition.advance(const Duration(milliseconds: 225));
      final middle = distanceToTarget();
      transition.advance(const Duration(milliseconds: 450));
      final late = distanceToTarget();

      expect(middle, lessThan(early), reason: '越走越接近目标');
      expect(late, lessThan(middle));
      expect(late, lessThan(1e-6), reason: '满 900ms 后距离归零');
    });
  });

  group('可中断（快速连切）', () {
    test('过渡中再次 retarget：起点是当前混合值，advance(0) 不跳变', () {
      final paletteC = paletteOf(const Color(0xFF33AA66));
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB)
        ..advance(const Duration(milliseconds: 400));
      final snapshot = transition.current;
      final before = List<Color>.of(snapshot.pigments);

      expect(transition.retarget(paletteC), isTrue);
      // 还没有推进 → 颜色必须还是中断那一刻的那一份
      expect(transition.advance(Duration.zero), isTrue);
      expect(transition.current.pigments, equals(before),
          reason: '中断续新目标时不得回跳或突进');

      // 继续推进后靠近 paletteC，而不是回到 paletteA
      transition.advance(const Duration(milliseconds: 900));
      expect(identical(transition.current, paletteC), isTrue);
    });

    test('连续 retarget 多个目标后仍收敛到最后一个', () {
      final paletteC = paletteOf(const Color(0xFF33AA66));
      final transition = FlowingPaletteTransition(initial: paletteA);
      transition.retarget(paletteB);
      transition.advance(const Duration(milliseconds: 120));
      transition.retarget(paletteC);
      transition.advance(const Duration(milliseconds: 120));
      transition.retarget(paletteB);
      expect(transition.advance(const Duration(milliseconds: 900)), isFalse);
      expect(identical(transition.current, paletteB), isTrue);
    });
  });

  group('边界', () {
    test('duration == 0：retarget 立即生效且返回 false', () {
      final transition = FlowingPaletteTransition(
        initial: paletteA,
        duration: Duration.zero,
      );
      expect(transition.retarget(paletteB), isFalse);
      expect(identical(transition.current, paletteB), isTrue);
      expect(transition.isAnimating, isFalse);
    });

    test('目标未变（同一实例）不重复启动过渡', () {
      final transition = FlowingPaletteTransition(initial: paletteA);
      expect(transition.retarget(paletteB), isTrue);
      transition.advance(const Duration(milliseconds: 200));
      expect(transition.retarget(paletteB), isFalse,
          reason: '同一目标实例不得打断已在进行的过渡');
      expect(transition.isAnimating, isTrue);
    });

    test('混合结果全部在色域内、无 NaN，且 base 仍最暗', () {
      final transition = FlowingPaletteTransition(initial: paletteA)
        ..retarget(paletteB);
      // 逐拍推进，覆盖整条曲线（含端点）
      for (var step = 0; step < 32; step++) {
        transition.advance(const Duration(milliseconds: 32));
        final current = transition.current;
        for (final color in <Color>[
          ...current.pigments,
          current.baseColor,
          ...current.motionColors,
        ]) {
          for (final channel in <double>[color.r, color.g, color.b]) {
            expect(channel.isFinite, isTrue);
            expect(channel >= 0.0 && channel <= 1.0, isTrue,
                reason: '通道越界: $channel');
          }
        }
        final baseLightness = lightness(current.baseColor);
        for (final pigment in current.pigments) {
          expect(baseLightness, lessThan(lightness(pigment)),
              reason: 'base 必须暗于全部 pigment');
        }
      }
    });
  });
}
