import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/lyric_sweep_fill.dart';

/// sweep（扫光）模型纯函数单测。
///
/// 覆盖四组契约：
/// 1. [LyricSweepPath]：区间过滤/合并、相位端点外扩、间隙瞬时跨越且单调不回退；
/// 2. [sweepFeather]：钳制区间、慢字 < 快字、非法输入回落基线；
/// 3. [sweepRampFor]：stops 单调非降且在 [0,1]、颜色停点布局、RTL 镜像、退化返回 null；
/// 4. [sweepAlphaAt]：与 myune shader 逐像素公式同式（点采样）。
void main() {
  const Color active = Color(0xFFFFFFFF);
  const Color inactive = Color(0xFF000000);

  group('LyricSweepPath —— 区间构建', () {
    test('空输入 isEmpty，frontX 恒为 0', () {
      final path = LyricSweepPath(const <LyricInkSpan>[]);
      expect(path.isEmpty, isTrue);
      expect(path.totalInk, 0);
      expect(path.frontX(0, feather: 8), 0);
      expect(path.frontX(0.5, feather: 8), 0);
      expect(path.frontX(1, feather: 8), 0);
    });

    test('过滤 end<=start 与非有限值', () {
      final path = LyricSweepPath(<LyricInkSpan>[
        const LyricInkSpan(10, 10), // 零宽
        const LyricInkSpan(20, 5), // 反向
        const LyricInkSpan(0, double.nan), // NaN
        const LyricInkSpan(0, double.infinity), // 无穷
        const LyricInkSpan(30, 40),
      ]);
      expect(path.spanCount, 1);
      expect(path.totalInk, 10);
      expect(path.isEmpty, isFalse);
    });

    test('重叠 / 相接区间合并，总长按合并后计', () {
      final overlap = LyricSweepPath(<LyricInkSpan>[
        const LyricInkSpan(0, 10),
        const LyricInkSpan(5, 20),
      ]);
      expect(overlap.spanCount, 1);
      expect(overlap.totalInk, 20);

      final touching = LyricSweepPath(<LyricInkSpan>[
        const LyricInkSpan(0, 10),
        const LyricInkSpan(10, 25),
      ]);
      expect(touching.spanCount, 1);
      expect(touching.totalInk, 25);
    });

    test('乱序输入按 start 排序后再合并', () {
      final path = LyricSweepPath(<LyricInkSpan>[
        const LyricInkSpan(50, 70),
        const LyricInkSpan(10, 30),
      ]);
      expect(path.spanCount, 2);
      expect(path.totalInk, 40);
      // 排序生效：phase=0、feather=0 时前端恰在首段（10~30）起点
      expect(path.frontX(0, feather: 0), closeTo(10, 1e-9));
    });
  });

  group('LyricSweepPath.frontX —— 相位映射', () {
    // 两段墨迹：10~30、50~70（中间 30~50 是字间空白，不计入推进距离）
    final path = LyricSweepPath(<LyricInkSpan>[
      const LyricInkSpan(10, 30),
      const LyricInkSpan(50, 70),
    ]);

    test('phase=0 前端在首段起点之前（外扩 feather/2）', () {
      expect(path.frontX(0, feather: 8), lessThan(10));
      expect(path.frontX(0, feather: 8), closeTo(6, 1e-9));
      // feather=0 时退化到首段起点之前 0 → 恰好在起点
      expect(path.frontX(0, feather: 0), closeTo(10, 1e-9));
    });

    test('phase=1 前端在末段终点之后（外扩 feather/2）', () {
      expect(path.frontX(1, feather: 8), greaterThan(70));
      expect(path.frontX(1, feather: 8), closeTo(74, 1e-9));
    });

    test('phase=0.5 落在墨迹中点对应的 x（间隙处瞬时跨越）', () {
      // feather=8 → distance = (40+8)*0.5 - 4 = 20 = 首段墨迹全长
      // → 首段刚走完，前端直接跨到第二段起点 x=50
      expect(path.frontX(0.5, feather: 8), closeTo(50, 1e-9));
    });

    test('跨间隙单调不回退，且间隙被瞬时跨越', () {
      double previous = double.negativeInfinity;
      double gapJump = 0;
      double? lastBeforeGap;
      for (int i = 0; i <= 100; i++) {
        final double x = path.frontX(i / 100, feather: 6);
        expect(x, greaterThanOrEqualTo(previous), reason: 'phase=$i/100 回退');
        previous = x;
        if (lastBeforeGap != null) {
          final double jump = x - lastBeforeGap;
          if (jump > gapJump) gapJump = jump;
        }
        lastBeforeGap = x;
      }
      // 40px 墨迹 / 100 步 ≈ 0.4px 均步；间隙 20px 会被一次性跨过，
      // 故最大单步跳变应远大于均步（证明"空白不占推进距离"）。
      expect(gapJump, greaterThan(5));
    });

    test('相位越界被 clamp 到 [0,1]', () {
      expect(path.frontX(-1, feather: 8), path.frontX(0, feather: 8));
      expect(path.frontX(2, feather: 8), path.frontX(1, feather: 8));
    });

    test('rtl=true 相位反向（从行尾向行首）', () {
      expect(
        path.frontX(0, feather: 8, rtl: true),
        path.frontX(1, feather: 8),
      );
      expect(
        path.frontX(1, feather: 8, rtl: true),
        path.frontX(0, feather: 8),
      );
    });

    test('feather 非有限时不污染结果（按 0 处理）', () {
      expect(path.frontX(0.5, feather: double.nan).isFinite, isTrue);
      expect(path.frontX(0.5, feather: 0), closeTo(50, 1e-9));
    });
  });

  group('sweepFeather —— 按字宽/时长自适应羽化', () {
    test('基线由行高决定并钳到 [12, 18]', () {
      // 行高 8 × 0.72 = 5.76 → 钳到 12；此时非法输入回落基线 = 12
      expect(
        sweepFeather(
          fontSize: 8,
          rowHeightFactor: 1.0,
          wordWidth: 0,
          wordDuration: Duration.zero,
        ),
        closeTo(12, 1e-9),
      );
      // 行高 40 × 0.72 = 28.8 → 钳到 18
      final double big = sweepFeather(
        fontSize: 40,
        rowHeightFactor: 1.0,
        wordWidth: 0,
        wordDuration: Duration.zero,
      );
      expect(big, closeTo(18, 1e-9));
    });

    test('结果始终落在 [fontSize*0.12, fontSize*1.20] 且有限', () {
      for (final double width in <double>[1, 8, 40, 200, 400]) {
        for (final int ms in <int>[20, 120, 600, 3000]) {
          final double f = sweepFeather(
            fontSize: 30,
            rowHeightFactor: 1.4,
            wordWidth: width,
            wordDuration: Duration(milliseconds: ms),
          );
          expect(f.isFinite, isTrue);
          expect(f, greaterThanOrEqualTo(30 * 0.12 - 1e-9));
          expect(f, lessThanOrEqualTo(30 * 1.20 + 1e-9));
        }
      }
    });

    test('慢字羽化 < 快字羽化（同宽度、时长不同）', () {
      final double slow = sweepFeather(
        fontSize: 30,
        rowHeightFactor: 1.2,
        wordWidth: 10,
        wordDuration: const Duration(milliseconds: 1000),
      );
      final double fast = sweepFeather(
        fontSize: 30,
        rowHeightFactor: 1.2,
        wordWidth: 10,
        wordDuration: const Duration(milliseconds: 100),
      );
      expect(slow, lessThan(fast));
    });

    test('边界守卫：宽度非法 / 时长 <= 0 → 直接返回基线（非 0、非 NaN）', () {
      final double baseline = sweepFeather(
        fontSize: 30,
        rowHeightFactor: 1.0,
        wordWidth: double.nan,
        wordDuration: const Duration(milliseconds: 500),
      );
      double expected(double fontSize, double factor) =>
          (fontSize * factor * LyricSweepTuning.featherBaselineFactor)
              .clamp(
                LyricSweepTuning.featherBaselineMin,
                LyricSweepTuning.featherBaselineMax,
              )
              .toDouble();
      expect(baseline, closeTo(expected(30, 1.0), 1e-9));

      expect(
        sweepFeather(
          fontSize: 30,
          rowHeightFactor: 1.0,
          wordWidth: 0,
          wordDuration: const Duration(milliseconds: 500),
        ),
        closeTo(expected(30, 1.0), 1e-9),
      );
      expect(
        sweepFeather(
          fontSize: 30,
          rowHeightFactor: 1.0,
          wordWidth: 20,
          wordDuration: Duration.zero,
        ),
        closeTo(expected(30, 1.0), 1e-9),
      );
      expect(
        sweepFeather(
          fontSize: 30,
          rowHeightFactor: 1.0,
          wordWidth: -5,
          wordDuration: const Duration(milliseconds: -10),
        ),
        closeTo(expected(30, 1.0), 1e-9),
      );
    });
  });

  group('sweepRampFor —— 4 停渐变', () {
    const Rect rect = Rect.fromLTWH(100, 0, 200, 40);

    test('前端居中：stops 单调非降且在 [0,1]，颜色顺序 active→inactive', () {
      final ramp = sweepRampFor(
        rect: rect,
        front: 200,
        feather: 40,
        active: active,
        inactive: inactive,
        rtl: false,
      );
      expect(ramp, isNotNull);
      final stops = ramp!.stops;
      expect(stops.length, 4);
      expect(stops.first, 0.0);
      expect(stops.last, 1.0);
      for (int i = 0; i < stops.length; i++) {
        expect(stops[i], greaterThanOrEqualTo(0.0));
        expect(stops[i], lessThanOrEqualTo(1.0));
        if (i > 0) {
          expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
        }
      }
      // front=200 在 rect 内正中（left=100,width=200 → t_center=0.5），
      // feather=40 → 半带宽 20px = 0.1 → stops 0.4 / 0.6
      expect(stops[1], closeTo(0.4, 1e-9));
      expect(stops[2], closeTo(0.6, 1e-9));
      expect(ramp.colors,
          <Color>[active, active, inactive, inactive]);
    });

    test('rtl=true 以 rect.right 为基准镜像（停点不变、颜色序列反转）', () {
      final ltr = sweepRampFor(
        rect: rect,
        front: 200,
        feather: 40,
        active: active,
        inactive: inactive,
        rtl: false,
      )!;
      final rtl = sweepRampFor(
        rect: rect,
        front: 200,
        feather: 40,
        active: active,
        inactive: inactive,
        rtl: true,
      )!;
      expect(rtl.stops, ltr.stops);
      expect(rtl.colors, <Color>[inactive, inactive, active, active]);
      // 镜像语义：低 x（左端）为未播色，高 x（右端）为已播色
      expect(rtl.colors.first, inactive);
      expect(rtl.colors.last, active);
    });

    test('退化返回 null：宽度非正 / 参数非法 / 整段落在已播或未播侧', () {
      Rect rectOf(double width) => Rect.fromLTWH(0, 0, width, 10);
      // 宽度非正
      expect(
        sweepRampFor(
          rect: rectOf(0),
          front: 10,
          feather: 4,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
      // feather <= 0
      expect(
        sweepRampFor(
          rect: rectOf(100),
          front: 10,
          feather: 0,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
      // front / feather 非有限
      expect(
        sweepRampFor(
          rect: rectOf(100),
          front: double.nan,
          feather: 4,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
      expect(
        sweepRampFor(
          rect: rectOf(100),
          front: 10,
          feather: double.infinity,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
      // 整段在已播侧（front 远在右侧，t1 <= 0）
      expect(
        sweepRampFor(
          rect: rectOf(100),
          front: 500,
          feather: 4,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
      // 整段在未播侧（front 远在左侧，t0 >= 1）
      expect(
        sweepRampFor(
          rect: rectOf(100),
          front: -500,
          feather: 4,
          active: active,
          inactive: inactive,
          rtl: false,
        ),
        isNull,
      );
    });

    test('过渡带部分进入矩形（clamp 到边界）时仍可用且 stops 合法', () {
      final ramp = sweepRampFor(
        rect: const Rect.fromLTWH(0, 0, 100, 10),
        front: 2,
        feather: 20,
        active: active,
        inactive: inactive,
        rtl: false,
      );
      expect(ramp, isNotNull);
      final stops = ramp!.stops;
      expect(stops[0], 0.0);
      expect(stops[1], 0.0); // t0 = (2-10)/100 = -0.08 → clamp 0
      expect(stops[2], closeTo(0.12, 1e-9));
      expect(stops[3], 1.0);
    });
  });

  group('sweepAlphaAt —— myune 逐像素公式等价', () {
    test('带中心 0.5、带外两端 0/1、rtl 反向', () {
      expect(sweepAlphaAt(50, 10, 50), closeTo(0.5, 1e-9));
      expect(sweepAlphaAt(50, 10, 0), closeTo(1.0, 1e-9)); // 已播
      expect(sweepAlphaAt(50, 10, 100), closeTo(0.0, 1e-9)); // 未播
      expect(sweepAlphaAt(50, 10, 55), closeTo(0.0, 1e-9));
      expect(sweepAlphaAt(50, 10, 45), closeTo(1.0, 1e-9));
      // rtl：方向反转
      expect(sweepAlphaAt(50, 10, 0, rtl: true), closeTo(0.0, 1e-9));
      expect(sweepAlphaAt(50, 10, 100, rtl: true), closeTo(1.0, 1e-9));
    });

    test('feather < 1 时按 max(feather,1) 兜底（与 shader 同式）', () {
      expect(sweepAlphaAt(10, 0, 10.5), closeTo(0.0, 1e-9));
      expect(sweepAlphaAt(10, 0, 9.5), closeTo(1.0, 1e-9));
      expect(sweepAlphaAt(10, 0, 10), closeTo(0.5, 1e-9));
    });
  });
}
