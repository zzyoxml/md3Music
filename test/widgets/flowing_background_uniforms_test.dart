import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/flowing_background_palette.dart';
import 'package:md3music/widgets/flowing_background_uniforms.dart';
import 'package:md3music/widgets/flowing_palette_transition.dart';

/// 流光 uniform 打包的纯函数语义（不依赖 GPU / FragmentShader）。
///
/// 断言的三件事：
/// 1. 45 个 float 的索引布局与 shader 声明顺序对齐（size/motion/dim/phases/
///    centres/pigments/base/shapes）；
/// 2. 数学与上游 myune_music_android-main 对齐（orbit=time×0.15、shapePhase=
///    orbit×1.6、形状矩阵 cos/rx, sin/rx, -sin/ry, cos/ry、quintic 颜色混合）；
/// 3. 相位在一个轨道周期接缝处位置/速度连续（无跳变），且值域合法、无 NaN；
/// 4. 脏检查：同帧重复调用写入 0 次。
void main() {
  final palette = FlowingPalette.fallback;
  const size = Size(400, 800);

  Float32List pack({
    double time = 0,
    double motion = 1,
    double dim = 0,
    Size canvas = size,
    FlowingPalette? colors,
    FlowingUniformState? state,
  }) {
    final values = Float32List(FlowingUniforms.uniformFloatCount);
    writeFlowingUniforms(
      values,
      size: canvas,
      time: time,
      motion: motion,
      dim: dim,
      palette: colors ?? palette,
      state: state ?? FlowingUniformState(),
    );
    return values;
  }

  group('45 floats 索引布局', () {
    test('size / motion / dim / phases 落在 0-5', () {
      final v = pack();
      expect(v[FlowingUniforms.sizeX], 400);
      expect(v[FlowingUniforms.sizeY], 800);
      expect(v[FlowingUniforms.motion], 1);
      expect(v[FlowingUniforms.dim], 0);
      // orbit = time × 0.15 = 0；
      // phase = orbit + 0.28sin(orbit) + 0.06sin(2orbit+1.7)
      expect(
        v[FlowingUniforms.phaseX],
        closeTo(0.06 * math.sin(1.7), 1e-6),
      );
      expect(
        v[FlowingUniforms.phaseY],
        closeTo(0.26 * math.sin(2.1) + 0.04 * math.sin(0.8), 1e-6),
      );
    });

    test('4 个中心落在 6-13 且为有限值', () {
      final v = pack();
      for (var field = 0; field < 4; field++) {
        final x = v[FlowingUniforms.centreBase + field * 2];
        final y = v[FlowingUniforms.centreBase + field * 2 + 1];
        expect(x.isFinite, isTrue);
        expect(y.isFinite, isTrue);
        // 中心在屏幕外一点点以内（hub ± radius，radius ≤ 0.78）
        expect(x, inInclusiveRange(-0.3, 1.3));
        expect(y, inInclusiveRange(-0.3, 1.3));
      }
      // field 0 在 orbit=0 时 angle=0、radius=.46+.26sin(.7)，x = hubX + radius
      final hubX = .5 + .11 * math.sin(.9);
      final radius = .46 + .26 * math.sin(.7);
      expect(
        v[FlowingUniforms.centreBase],
        closeTo(hubX + radius, 1e-6),
      );
    });

    test('4 个 pigment 落在 14-25：t=0 时 field0 取 motionColors[0]', () {
      final v = pack();
      final first = palette.motionColors[0];
      expect(v[FlowingUniforms.pigmentBase], closeTo(first.r, 1e-6));
      expect(v[FlowingUniforms.pigmentBase + 1], closeTo(first.g, 1e-6));
      expect(v[FlowingUniforms.pigmentBase + 2], closeTo(first.b, 1e-6));
      // 其余场走各自的颜色相位，索引不能串场
      for (var field = 0; field < 4; field++) {
        final position = fluidColourPosition(0, field);
        final variant = position.floor();
        final next = (variant + 1) % fluidMotionColourCount;
        final blend = fluidPaletteBlend(position - variant);
        final from = palette.motionColor(field, variant);
        final to = palette.motionColor(field, next);
        expect(
          v[FlowingUniforms.pigmentBase + field * 3],
          closeTo(from.r + (to.r - from.r) * blend, 1e-6),
        );
      }
    });

    test('base 落在 26-28，等于 palette.baseColor', () {
      final v = pack();
      expect(v[FlowingUniforms.baseBase], closeTo(palette.baseColor.r, 1e-6));
      expect(v[FlowingUniforms.baseBase + 1], closeTo(palette.baseColor.g, 1e-6));
      expect(v[FlowingUniforms.baseBase + 2], closeTo(palette.baseColor.b, 1e-6));
    });

    test('4 个形状矩阵落在 29-44（逆旋转/半径矩阵语义）', () {
      final v = pack();
      // field0：orbit=0 → shapePhase=0，rotation=.35sin(.4)
      final radiusBase = math.min(.52, size.longestSide / size.shortestSide / (3 * 1.16));
      final radiusX = radiusBase * (1 + .16 * math.sin(.8));
      final radiusY = radiusBase * (1 + .16 * math.sin(1.2));
      final rotation = .35 * math.sin(.4);
      final cosine = math.cos(rotation), sine = math.sin(rotation);
      const base = FlowingUniforms.shapeBase;
      expect(v[base], closeTo(cosine / radiusX, 1e-6));
      expect(v[base + 1], closeTo(sine / radiusX, 1e-6));
      expect(v[base + 2], closeTo(-sine / radiusY, 1e-6));
      expect(v[base + 3], closeTo(cosine / radiusY, 1e-6));
      // 不是正向旋转矩阵：xy 行模长的倒数关系仍应可反解出半径
      final recoveredX = 1 / math.sqrt(v[base] * v[base] + v[base + 1] * v[base + 1]);
      expect(recoveredX, closeTo(radiusX, 1e-6));
    });

    test('motion / dim 参与计算但不越界', () {
      final v = pack(motion: 2.5, dim: 0.9);
      // amplitude = motion.clamp(0, FlowingUniforms.maxMotion)
      // （本仓为音乐律动保留 >1 的头部空间，不再裁到 1）
      expect(v[FlowingUniforms.motion], closeTo(FlowingUniforms.maxMotion, 1e-6));
      // dim = dim.clamp(0, .60)
      expect(v[FlowingUniforms.dim], closeTo(.60, 1e-6));
    });
  });

  group('轨道相位连续性（无跳变）', () {
    test('fluidOrbitAngle 在 0 与 2π 接缝处位置/速度都连续', () {
      const twoPi = 2 * math.pi;
      for (var field = 0; field < 4; field++) {
        final atZero = fluidOrbitAngle(0, field, 1);
        final atSeam = fluidOrbitAngle(twoPi, field, 1);
        // 一个整周后角度差正好 2π → 朝向完全一致
        expect(math.cos(atSeam), closeTo(math.cos(atZero), 1e-9));
        expect(math.sin(atSeam), closeTo(math.sin(atZero), 1e-9));

        // 接缝左右的速度（数值微分）必须相等
        double speed(double orbit) => (fluidOrbitAngle(orbit + 1e-5, field, 1) -
                fluidOrbitAngle(orbit - 1e-5, field, 1)) /
            2e-5;
        expect(speed(twoPi - 1e-3), closeTo(speed(twoPi + 1e-3), 1e-3),
            reason: 'field=$field 接缝处速度不连续');
      }
    });

    test('t=0 与 t≈fluidOrbitPeriod(41.888s) 的中心/颜色无跳变', () {
      final start = pack(time: 0);
      final next = pack(time: fluidOrbitPeriod);
      // 中心与颜色相位在整整一个轨道后回到同一朝向
      for (var i = FlowingUniforms.centreBase;
          i < FlowingUniforms.centreBase + 8;
          i++) {
        expect(next[i], closeTo(start[i], 1e-4), reason: 'index $i 中心跳变');
      }
      for (var i = FlowingUniforms.pigmentBase;
          i < FlowingUniforms.pigmentBase + 12;
          i++) {
        expect(next[i], closeTo(start[i], 1e-4), reason: 'index $i 颜色跳变');
      }
      // phases（域扭曲）以轨道为周期：角度本身会累积 2π 的整数倍（shader 只吃
      // sin(... + phase)），因此比较 sin/cos 而不是裸角度。
      final startPhase = start[FlowingUniforms.phaseX];
      final nextPhase = next[FlowingUniforms.phaseX];
      expect(math.sin(nextPhase), closeTo(math.sin(startPhase), 1e-4));
      expect(math.cos(nextPhase), closeTo(math.cos(startPhase), 1e-4));
      expect(
        math.sin(next[FlowingUniforms.phaseY]),
        closeTo(math.sin(start[FlowingUniforms.phaseY]), 1e-4),
      );
      expect(
        math.cos(next[FlowingUniforms.phaseY]),
        closeTo(math.cos(start[FlowingUniforms.phaseY]), 1e-4),
      );
    });

    test('t=0 与 t=5×fluidOrbitPeriod（完整时钟周期）全部 45 项连续', () {
      final start = pack(time: 0);
      final next = pack(time: fluidOrbitPeriod * 5);
      for (var i = 0; i < FlowingUniforms.uniformFloatCount; i++) {
        if (i == FlowingUniforms.phaseX || i == FlowingUniforms.phaseY) {
          // 角度按 2π 累积，shader 侧只经 sin/cos 使用 → 比较三角值
          expect(math.sin(next[i]), closeTo(math.sin(start[i]), 1e-3),
              reason: 'index $i（相位 sin）在时钟周期处跳变');
          expect(math.cos(next[i]), closeTo(math.cos(start[i]), 1e-3),
              reason: 'index $i（相位 cos）在时钟周期处跳变');
          continue;
        }
        expect(next[i], closeTo(start[i], 1e-3), reason: 'index $i 在时钟周期处跳变');
      }
    });
  });

  group('值域与 NaN', () {
    test('多尺寸/多时刻/两种调色板：45 项全有限，pigment/base 在 0..1', () {
      final custom = buildFlowingPalette(const [Color(0xFF3366CC)]);
      const canvases = <Size>[
        Size(360, 640),
        Size(800, 400),
        Size(1, 1),
        Size.zero,
      ];
      const times = <double>[0, 1, 7.3, 41.888, 209.44, 12345.6];
      for (final canvas in canvases) {
        for (final time in times) {
          for (final colors in <FlowingPalette>[palette, custom]) {
            final v = pack(canvas: canvas, time: time, colors: colors);
            for (var i = 0; i < FlowingUniforms.uniformFloatCount; i++) {
              expect(v[i].isFinite, isTrue,
                  reason: 'size=$canvas t=$time index=$i 不是有限值');
            }
            for (var i = FlowingUniforms.pigmentBase;
                i < FlowingUniforms.pigmentBase + 12;
                i++) {
              expect(v[i], inInclusiveRange(0, 1), reason: 'pigment index $i 越界');
            }
            for (var i = FlowingUniforms.baseBase;
                i < FlowingUniforms.baseBase + 3;
                i++) {
              expect(v[i], inInclusiveRange(0, 1), reason: 'base index $i 越界');
            }
          }
        }
      }
    });
  });

  group('uMotion（音乐频谱驱动）', () {
    test('>1 的值原样写入（本仓有意不裁到 1）', () {
      expect(
        pack(motion: 1.5)[FlowingUniforms.motion],
        closeTo(1.5, 1e-6),
      );
    });

    test('超过 maxMotion 被钳制', () {
      expect(
        pack(motion: 9)[FlowingUniforms.motion],
        closeTo(FlowingUniforms.maxMotion, 1e-6),
      );
    });

    test('NaN / 负值兜底为 0（不污染 uniform 表）', () {
      expect(pack(motion: double.nan)[FlowingUniforms.motion], 0);
      expect(pack(motion: -2)[FlowingUniforms.motion], 0);
    });

    test('motion 越大，场中心的游走幅度越大（律动可见）', () {
      double centreDistance(double motion) {
        final v = pack(motion: motion);
        final dx = v[FlowingUniforms.centreBase] - 0.5;
        final dy = v[FlowingUniforms.centreBase + 1] - 0.5;
        return dx * dx + dy * dy;
      }

      expect(centreDistance(1.5), greaterThan(centreDistance(0.6)));
    });
  });

  group('调色板过渡快照（切歌交叉淡化）', () {
    test('中点快照：pigment / base 都落在旧→新之间，45 项全有限', () {
      final from = FlowingPalette.fallback;
      final to = buildFlowingPalette(const [Color(0xFF3366CC)]);
      final transition = FlowingPaletteTransition(initial: from)
        ..retarget(to)
        ..advance(const Duration(milliseconds: 450));
      final mid = transition.current;

      final before = pack(colors: from);
      final after = pack(colors: to);
      final blended = pack(colors: mid);

      for (var i = 0; i < FlowingUniforms.uniformFloatCount; i++) {
        expect(blended[i].isFinite, isTrue, reason: 'index $i 出现非有限值');
      }
      // pigment（14..25）与 base（26..28）必须夹在两端之间（含端点）；
      // 时间/中心/形状等与调色板无关的字段不该被影响。
      for (var i = FlowingUniforms.pigmentBase;
          i < FlowingUniforms.pigmentBase + 12;
          i++) {
        final lo = math.min(before[i], after[i]) - 1e-6;
        final hi = math.max(before[i], after[i]) + 1e-6;
        expect(blended[i], inInclusiveRange(lo, hi), reason: 'pigment index $i');
      }
      for (var i = FlowingUniforms.baseBase;
          i < FlowingUniforms.baseBase + 3;
          i++) {
        final lo = math.min(before[i], after[i]) - 1e-6;
        final hi = math.max(before[i], after[i]) + 1e-6;
        expect(blended[i], inInclusiveRange(lo, hi), reason: 'base index $i');
      }
      for (var i = FlowingUniforms.centreBase;
          i < FlowingUniforms.centreBase + 8;
          i++) {
        expect(blended[i], closeTo(before[i], 1e-9),
            reason: '中心与调色板无关，不得漂移（index $i）');
      }
    });
  });

  group('脏检查（只写变化项）', () {
    test('首帧全写、同帧重复 0 次、时间推进后只写变化项', () {
      final state = FlowingUniformState();
      final values = Float32List(FlowingUniforms.uniformFloatCount);

      void write(double time) => writeFlowingUniforms(
            values,
            size: size,
            time: time,
            motion: 1,
            dim: 0,
            palette: palette,
            state: state,
          );

      write(0);
      expect(state.dirtyCount, FlowingUniforms.uniformFloatCount,
          reason: '_written 初值 NaN → 首帧必然全量');
      expect(state.flush(null), FlowingUniforms.uniformFloatCount);

      // 同帧重复调用：值与"上次已提交"完全一致 → 0 次写入
      write(0);
      expect(state.dirtyCount, 0);
      expect(state.flush(null), 0);

      // 时间推进：只写发生变化的那部分（不是 45 全写）
      write(0.5);
      expect(state.dirtyCount, greaterThan(0));
      expect(state.dirtyCount, lessThan(FlowingUniforms.uniformFloatCount));
      final expected = state.dirtyCount; // flush 会清零 dirtyCount，先取值
      expect(state.flush(null), expected);
      expect(state.flush(null), 0, reason: '同帧再次 flush 不得重复写');
    });
  });
}
