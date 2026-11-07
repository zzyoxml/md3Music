import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/cover_flip_physics.dart';

void main() {
  group('角度', () {
    test('t=0：旧封面就位、新封面侧立在 −90°', () {
      expect(coverFlipOldAngle(0), 0);
      expect(coverFlipNewAngle(0), closeTo(-math.pi / 2, 1e-9));
    });

    test('t=0.5：新旧封面都在侧立位（+90° 与 −90°，投影同为零宽）', () {
      expect(coverFlipOldAngle(0.5), closeTo(math.pi / 2, 1e-9));
      expect(coverFlipNewAngle(0.5), closeTo(-math.pi / 2, 1e-9));
      // 交接点两层都侧立：cos 归零 ⇒ 投影宽度严格为零，换图不可见
      expect(math.cos(coverFlipOldAngle(0.5)), closeTo(0, 1e-9));
      expect(math.cos(coverFlipNewAngle(0.5)), closeTo(0, 1e-9));
    });

    test('交接两侧角度符号相反（整段是同一方向的 180° 翻转）', () {
      // 回归守卫：新层曾经走 +90°→0，与旧层同号 ⇒ 角度在交接点反向，
      // 观感是「翻到一半又翻回来」，且新层透视与旧层同侧（左侧小右侧大）。
      // 区间取到 0.68：easeOutBack 在 t≈0.69 越过 0（进过冲段），之后转正。
      for (var i = 1; i <= 49; i++) {
        expect(coverFlipOldAngle(i / 100), greaterThan(0));
      }
      for (var i = 51; i <= 68; i++) {
        expect(coverFlipNewAngle(i / 100), lessThan(0));
      }
    });

    test('t=1：新封面就位', () {
      expect(coverFlipNewAngle(1), 0);
    });

    test('角度单调：旧层升；新层过冲前往 0 升（同为负值区间）', () {
      double prev = -1.0;
      for (var i = 0; i <= 50; i++) {
        final a = coverFlipOldAngle(i / 50);
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
      // 新层：−90° → 0 主体单调升；easeOutBack 末段过冲（t≈0.69 越过 0 后
      // 短暂转正，峰值约 t≈0.71），因此只钉「过冲点之前」单调（0.5~0.68）。
      prev = -double.infinity;
      for (var i = 25; i <= 34; i++) {
        final t = i / 50;
        final a = coverFlipNewAngle(t);
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
    });

    test('新层旋转末段过冲回弹（翻转过头的超出感）', () {
      // easeOutBack 进度峰值约 1.1 → 角度越过就位角短暂转正。
      double maxAngle = -double.infinity;
      for (var i = 50; i <= 100; i++) {
        final t = i / 100;
        maxAngle = math.max(maxAngle, coverFlipNewAngle(t));
      }
      expect(maxAngle, greaterThan(0)); // 确实翻过了头
      expect(maxAngle, lessThan(kCoverFlipHalfTurn * 0.2)); // 但不过分
      expect(coverFlipNewAngle(1), 0); // 最终回到就位角
    });

    test('新层模糊单调不过冲（与旋转解耦）', () {
      double prev = kCoverFlipBlurSigma + 1;
      for (var i = 50; i <= 100; i++) {
        final s = coverFlipNewBlur(i / 100);
        expect(s, lessThanOrEqualTo(prev));
        expect(s, greaterThanOrEqualTo(0));
        prev = s;
      }
    });

    test('越界值钳制（t<0 / t>1 不炸）', () {
      expect(coverFlipOldAngle(-1), 0);
      expect(coverFlipNewAngle(2), 0);
    });
  });

  group('模糊', () {
    test('两端为 0', () {
      expect(coverFlipOldBlur(0), 0);
      expect(coverFlipNewBlur(1), 0);
    });

    test('峰值在交接点两侧逼近（旧层 t→0.5⁻、新层 t→0.5⁺）', () {
      // easeIn/easeOut 是渐近曲线，峰值只在 t→0.5 极限处达到。
      // 钉「逼近且不超过峰值」而非「等于峰值」。
      expect(coverFlipOldBlur(0.49), greaterThan(kCoverFlipBlurSigma * 0.95));
      expect(coverFlipNewBlur(0.51), greaterThan(kCoverFlipBlurSigma * 0.95));
      expect(coverFlipOldBlur(0.49), lessThanOrEqualTo(kCoverFlipBlurSigma));
      expect(coverFlipNewBlur(0.51), lessThanOrEqualTo(kCoverFlipBlurSigma));
    });

    test('旧层模糊只在前半程非零、新层只在后半程非零（窗口外不过滤镜）', () {
      expect(coverFlipOldBlur(0.75), 0);
      expect(coverFlipNewBlur(0.25), 0);
    });

    test('模糊非负', () {
      for (var i = 0; i <= 50; i++) {
        final t = i / 50;
        expect(coverFlipOldBlur(t), greaterThanOrEqualTo(0));
        expect(coverFlipNewBlur(t), greaterThanOrEqualTo(0));
      }
    });
  });

  group('快照叠层 alpha', () {
    test('端点：sigma 0→α 0，峰值→α 1', () {
      expect(coverFlipBlurAlpha(0), 0);
      expect(coverFlipBlurAlpha(kCoverFlipBlurEpsilon / 2), 0);
      expect(coverFlipBlurAlpha(kCoverFlipBlurSigma), closeTo(1.0, 1e-9));
    });

    test('√ 曲线：中段快于线性（清晰残影更早被吞掉），但单调', () {
      final half = kCoverFlipBlurSigma / 2;
      // α(σmax/2)=√0.5≈0.707 > 0.5：观感「变化剧烈」的来源。
      expect(coverFlipBlurAlpha(half), greaterThan(0.5));
      expect(coverFlipBlurAlpha(half), closeTo(0.7071, 1e-3));
      double prev = -1;
      for (var i = 0; i <= 100; i++) {
        final a = coverFlipBlurAlpha(i * 0.4);
        expect(a, greaterThanOrEqualTo(prev));
        expect(a, lessThanOrEqualTo(1.0));
        prev = a;
      }
    });
  });

  group('量化阶梯', () {
    test('≤epsilon 归零（不挂滤镜）', () {
      expect(coverFlipQuantizeSigma(0), 0);
      expect(coverFlipQuantizeSigma(kCoverFlipBlurEpsilon), 0);
      expect(coverFlipQuantizeSigma(-1), 0);
    });

    test('取不小于它的最近档，且单调不减', () {
      // 阶梯 = [8, 17, 26, 34]（σmax=34 的四等分）。
      expect(coverFlipQuantizeSigma(0.5), 8);
      expect(coverFlipQuantizeSigma(8), 8);
      expect(coverFlipQuantizeSigma(8.1), 17);
      expect(coverFlipQuantizeSigma(17), 17);
      expect(coverFlipQuantizeSigma(17.5), 26);
      expect(coverFlipQuantizeSigma(26), 26);
      expect(coverFlipQuantizeSigma(26.5), 34);
      expect(coverFlipQuantizeSigma(34), 34);
      double prev = -1;
      for (var i = 1; i <= 100; i++) {
        final q = coverFlipQuantizeSigma(i * 0.3);
        expect(q, greaterThanOrEqualTo(prev));
        prev = q;
      }
    });

    test('超峰值钳到峰值、唯一取值不超过阶梯大小', () {
      expect(coverFlipQuantizeSigma(100), kCoverFlipBlurSigma);
      final values = <double>{};
      for (var i = 0; i <= 50; i++) {
        // 旧层前半程的连续 sigma 全部量化后，取值集合就是阶梯
        values.add(coverFlipQuantizeSigma(coverFlipOldBlur(i / 100)));
      }
      expect(values.length, lessThanOrEqualTo(kCoverFlipBlurLadder.length + 1));
      for (final v in values) {
        expect(
          v == 0 || kCoverFlipBlurLadder.contains(v),
          isTrue,
          reason: '量化值必须落在阶梯上（$v）',
        );
      }
    });
  });

  group('矩阵', () {
    test('angle=0 时旋转部分是单位变换', () {
      final m = coverFlipMatrix(angle: 0);
      expect(m.entry(0, 0), 1);
      expect(m.entry(0, 2), 0);
      expect(m.entry(2, 0), 0);
      expect(m.entry(2, 2), 1);
    });

    test('90° 时平面投影横坐标归零（压成竖线）', () {
      final m = coverFlipMatrix(angle: math.pi / 2);
      // 平面点 (x, y, 0) 变换后 x' = entry(0,0)*x + entry(0,2)*0
      final xPrime = m.entry(0, 0) * 180 + m.entry(0, 2) * 0;
      expect(xPrime, closeTo(0, 1e-9));
    });

    test('45° 时投影宽度约为 cos45（无穿帮）', () {
      final m = coverFlipMatrix(angle: math.pi / 4);
      expect(m.entry(0, 0), closeTo(math.sqrt2 / 2, 1e-9));
    });

    test('透视系数可覆盖', () {
      final m = coverFlipMatrix(angle: 0.3, perspective: 0.0);
      expect(m.entry(3, 2), 0);
    });
  });
}
