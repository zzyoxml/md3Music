import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'flowing_background_palette.dart';

/// 可见时间 → 轨道弧度的时间缩放（与上游 myune_music_android-main 逐字一致）。
///
/// `orbit = time × 0.15`；1 rad 约 6.667 秒。
const double fluidShaderTimeScale = 0.15;

/// 轨道周期：`2π / 0.15 ≈ 41.888` 秒。
const double fluidOrbitPeriod = math.pi * 2 / fluidShaderTimeScale;

// fluidMotionColourCount（=8）定义在 flowing_background_palette.dart：它同时被
// 调色板派生（32 个运动色）与这里（颜色相位回绕）使用，只保留一份定义避免
// 两个库重复导出同名常量。

/// quintic smoothstep（`p³(p(6p-15)+10)`）：端点速度为 0，混合中段连续变速。
///
/// 与 shader 的 `coverage` 混合无关，只用于颜色变体之间的插值；上游同名函数
/// [fluidPaletteBlend] 的逐字移植。
double fluidPaletteBlend(double progress) {
  final p = progress.clamp(0.0, 1.0).toDouble();
  return p * p * p * (p * (p * 6 - 15) + 10);
}

/// 轨道角速度的三角冲程积分（上游 `_orbitRamp` 逐字移植）。
///
/// 只在冲程两端的 `corner`（0.12 rad）窗口内做加速度过渡，其余约 19 秒线性；
/// 返回值是**速度积分**（不是速度），因此接缝处位置与速度都连续。
double _orbitRamp(double phase) {
  const strength = .4, corner = .12;
  final cycle = phase % (2 * math.pi);
  final x = cycle > math.pi ? cycle - math.pi : cycle;
  double integral;
  if (x < corner) {
    integral =
        -strength * x +
        strength * corner * x / math.pi +
        strength * x * x * x / (3 * math.pi * corner);
  } else if (x > math.pi - corner) {
    final z = x - math.pi;
    integral =
        (strength - strength * corner / math.pi) * z -
        strength * z * z * z / (3 * math.pi * corner);
  } else {
    integral =
        -strength * x +
        strength * x * x / math.pi +
        strength * corner * corner / (3 * math.pi);
  }
  return cycle > math.pi ? -integral : integral;
}

/// 单个 pigment 场的轨道角：匀速轨道 + 场偏移 + 速度冲程积分。
///
/// 上游 [fluidOrbitAngle] 逐字移植。`_orbitRamp(orbit + stagger) - _orbitRamp(stagger)`
/// 的形式保证不同场的相位错开（每场错 0.20 rad）且不改变整体平均速度。
double fluidOrbitAngle(double orbit, int field, double amplitude) {
  final offset = field * math.pi / 2;
  final stagger = field * .20;
  return orbit +
      offset +
      amplitude * (_orbitRamp(orbit + stagger) - _orbitRamp(stagger));
}

/// 颜色相位（上游 `fluidColourPhase` 逐字移植）：轨道角 × 2 + 场偏移 + 三次谐波。
double fluidColourPhase(double orbit, int field) {
  orbit *= 2;
  final phase = orbit - field * math.pi / 2;
  return orbit +
      .8 * math.sin(phase) +
      .15 * math.sin(2 * phase) +
      (.08 / 3) * math.sin(3 * phase);
}

/// 当前颜色位置（0..8 的连续值，整数部分是变体索引、小数部分是 quintic 权重）。
double fluidColourPosition(double time, int field) {
  final position =
      (fluidColourPhase(time * fluidShaderTimeScale, field) * 2 / math.pi) %
      fluidMotionColourCount;
  return position >= fluidMotionColourCount ? 0 : position;
}

/// 45 个 float 的 uniform 布局（与 `shaders/flowing_background.frag` 声明顺序对齐）。
///
/// | 索引 | 内容 |
/// |---|---|
/// | 0-1 | size（画布逻辑尺寸） |
/// | 2 | motion（音乐频谱驱动的律动强度，无数据时 = 1.0） |
/// | 3 | dim（本仓恒 0.0，变暗由既有 0.35 蒙版负责） |
/// | 4-5 | phases（域扭曲的两个相位） |
/// | 6-13 | 4 × centre（vec2） |
/// | 14-25 | 4 × pigment（vec3，当前时刻的运动色） |
/// | 26-28 | base（vec3，最暗 pigment 压暗后的底色） |
/// | 29-44 | 4 × shape（vec4，逆旋转/半径矩阵） |
class FlowingUniforms {
  FlowingUniforms._();

  static const int uniformFloatCount = 45;

  /// `uMotion` 写入上限（本仓**有意大于 1**）。
  ///
  /// 上游 myune 的 Dart 侧把包络 `clamp(0, 1)`，导致 1.0 以上的律动全部饱和、
  /// 只剩「安静时变弱」。本仓把 1.0 定义为**无音乐数据时的基线**，高潮段允许
  /// 冲到 1.5 左右（shader 侧形变/轨道幅度数学在 1.6 以内均安全：域扭曲偏移
  /// 0.055×1.6≈0.088、半径 ≤ base×1.26、旋转 ≤0.56rad）。
  static const double maxMotion = 1.6;

  static const int sizeX = 0;
  static const int sizeY = 1;
  static const int motion = 2;
  static const int dim = 3;
  static const int phaseX = 4;
  static const int phaseY = 5;

  /// 4 个中心：`centreBase + field * 2`。
  static const int centreBase = 6;

  /// 4 个 pigment：`pigmentBase + field * 3`。
  static const int pigmentBase = 14;

  /// base 颜色（vec3）：26..28。
  static const int baseBase = 26;

  /// 4 个形状矩阵：`shapeBase + field * 4`。
  static const int shapeBase = 29;
}

/// 把当前帧的 45 个 uniform 写入 [out]（复用缓冲区，逐帧零分配）。
///
/// 数学与上游 `FluidFrameUniforms.write` 逐项对齐。调色板过渡状态机**不在本
/// 函数内**：上游把它塞进 uniform 打包（source/target/stagedFields 三套状态），
/// 本仓改由 `FlowingPaletteTransition` 在写入前把两份 palette 混成单一份，
/// 因此这里只吃一个 [palette]，等价上游 `paletteProgress == 1` 的单 palette 路径。
void writeFlowingUniforms(
  Float32List out, {
  required ui.Size size,
  required double time,
  required double motion,
  required double dim,
  required FlowingPalette palette,
  required FlowingUniformState state,
}) {
  assert(out.length >= FlowingUniforms.uniformFloatCount);
  final orbit = time * fluidShaderTimeScale;
  final shapePhase = orbit * 1.6;
  final phase =
      orbit + .28 * math.sin(orbit) + .06 * math.sin(2 * orbit + 1.7);
  final phase2 =
      orbit + .26 * math.sin(orbit + 2.1) + .04 * math.sin(2 * orbit + .8);
  // 保留 >1 的头部空间（见 [FlowingUniforms.maxMotion] 注释）。
  // 非有限值兜底为 0：NaN 会污染整张 uniform 表（clamp 对 NaN 不做修复），
  // 一旦漏进来就是整屏黑/花屏，宁可退化成「无律动」。
  final double rawMotion = motion.isFinite ? motion : 0.0;
  final double amplitude =
      rawMotion.clamp(0.0, FlowingUniforms.maxMotion).toDouble();
  final hubX = .5 + amplitude * .11 * math.sin(orbit + .9);
  final hubY = .5 + amplitude * .10 * math.cos(orbit - .4);
  // min 保护：布局尺寸为 0 时（首帧 / 未布局）shortSide 被钳到 1，且半径兜底到
  // 非零值，避免 radiusBase=0 → 形状矩阵除零产生 Inf/NaN。
  final shortSide = math.max(math.min(size.width, size.height), 1.0);
  final radiusBase = math.max(
    .001,
    math.min(.52, size.longestSide / shortSide / (3 * 1.16)),
  );
  out[FlowingUniforms.sizeX] = size.width;
  out[FlowingUniforms.sizeY] = size.height;
  out[FlowingUniforms.motion] = amplitude;
  out[FlowingUniforms.dim] = dim.clamp(0.0, .60).toDouble();
  out[FlowingUniforms.phaseX] = phase;
  out[FlowingUniforms.phaseY] = phase2;
  for (var field = 0; field < 4; field++) {
    final offset = field * math.pi / 2;
    final angle = fluidOrbitAngle(orbit, field, amplitude);
    final radius =
        .46 +
        amplitude *
            (.26 * math.sin(orbit + offset + .7) +
                .06 * math.sin(2 * orbit - offset));
    out[FlowingUniforms.centreBase + field * 2] =
        hubX + radius * math.cos(angle);
    out[FlowingUniforms.centreBase + field * 2 + 1] =
        hubY + radius * math.sin(angle) * 1.08;
    final radiusX =
        radiusBase * (1 + .16 * amplitude * math.sin(shapePhase + offset + .8));
    final radiusY =
        radiusBase *
        (1 + .16 * amplitude * math.sin(2 * shapePhase - offset + 1.2));
    final rotation = .35 * amplitude * math.sin(shapePhase - offset + .4);
    final cosine = math.cos(rotation), sine = math.sin(rotation);
    final shape = FlowingUniforms.shapeBase + field * 4;
    // 逆旋转/半径矩阵：shader 侧是 dot(shape.xy, local) / dot(shape.zw, local)，
    // 不是正向旋转矩阵，切勿改写符号。
    out[shape] = cosine / radiusX;
    out[shape + 1] = sine / radiusX;
    out[shape + 2] = -sine / radiusY;
    out[shape + 3] = cosine / radiusY;
    final colourPosition = fluidColourPosition(time, field);
    final variant = colourPosition.floor();
    final nextVariant = (variant + 1) % fluidMotionColourCount;
    final part = colourPosition - variant;
    // quintic 混合：颜色变体之间零端点速度，避免视觉上的"跳色"。
    final colourBlend = fluidPaletteBlend(part);
    final from = palette.motionColor(field, variant);
    final to = palette.motionColor(field, nextVariant);
    final pigment = FlowingUniforms.pigmentBase + field * 3;
    out[pigment] = from.r * from.a + (to.r * to.a - from.r * from.a) * colourBlend;
    out[pigment + 1] =
        from.g * from.a + (to.g * to.a - from.g * from.a) * colourBlend;
    out[pigment + 2] =
        from.b * from.a + (to.b * to.a - from.b * from.a) * colourBlend;
  }
  final base = palette.baseColor;
  out[FlowingUniforms.baseBase] = base.r * base.a;
  out[FlowingUniforms.baseBase + 1] = base.g * base.a;
  out[FlowingUniforms.baseBase + 2] = base.b * base.a;
  state.record(out);
}

/// uniform 脏检查状态（每个 shader 实例一份）。
///
/// 上游用 `Float32List(45)..fillRange(0, 45, double.nan)` 作"上次写入值"；
/// NaN 与任何值都不相等（包括自身），因此首帧必然全量写一次，属预期行为。
/// 这里用 [Float64List] 存**上次真正提交给 shader 的 float 值**，避免 float32
/// 往返比较误差：`record` 只标记脏项，`flush` 才真正 `setFloat` 并更新基准。
class FlowingUniformState {
  FlowingUniformState();

  final Float64List _written = Float64List(FlowingUniforms.uniformFloatCount)
    ..fillRange(0, FlowingUniforms.uniformFloatCount, double.nan);
  final Int32List _dirty = Int32List(FlowingUniforms.uniformFloatCount);
  int _dirtyCount = 0;
  Float32List? _values;
  ui.FragmentShader? _lastShader;

  /// 上次 [record] 相对"上次已提交值"变化的 uniform 个数（诊断/测试用）。
  int get dirtyCount => _dirtyCount;

  /// 记录本帧计算值，标记脏项（尚不写 shader）。
  void record(Float32List values) {
    _values = values;
    _dirtyCount = 0;
    for (var i = 0; i < FlowingUniforms.uniformFloatCount; i++) {
      if (_written[i] == values[i]) continue;
      _dirty[_dirtyCount++] = i;
    }
  }

  /// 把脏项提交给 shader，返回本次 `setFloat` 次数（测试可断言"重复调用 0 次"）。
  ///
  /// [shader] 为 null 时只提交基准（GPU 不可用的单测路径），返回的仍是"本应写入"
  /// 的次数，便于验证脏检查逻辑。shader 实例变化（每个 State 一个实例）时全量写一次。
  int flush(ui.FragmentShader? shader) {
    final values = _values;
    if (values == null) return 0;
    final changedShader = shader != null && !identical(shader, _lastShader);
    if (shader != null) _lastShader = shader;
    var writes = 0;
    if (changedShader) {
      for (var i = 0; i < FlowingUniforms.uniformFloatCount; i++) {
        shader.setFloat(i, values[i]);
        _written[i] = values[i];
        writes++;
      }
    } else {
      for (var k = 0; k < _dirtyCount; k++) {
        final i = _dirty[k];
        shader?.setFloat(i, values[i]);
        _written[i] = values[i];
        writes++;
      }
    }
    _dirtyCount = 0;
    return writes;
  }
}
