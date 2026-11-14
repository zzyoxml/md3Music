// 动态流光背景（flowing background）fragment shader。
//
// 来源：myune_music_android-main 的 shaders/fluid_background.frag，
//       逐字移植（4 个椭圆反二次 pigment 场 + 双轴 sin 域扭曲 +
//       coverage=0.84 与 base 混合 + vignette + 交错梯度抖动）。
// 上游：xiaobaimc/myune_music（https://github.com/xiaobaimc/myune_music）
// 许可：Apache License 2.0（见仓库根目录 THIRD_PARTY_NOTICES.md）
//
// 本仓修改点（MD3Music）：
//   1) 时间由共享节拍 PlayerFrameDriver.instance 提供（每 2 拍推进一次
//      ≈30fps），不再由独立 Ticker/计时器驱动；
//   2) uDim 由本仓恒传 0.0 —— 变暗仍由 FlowingBackground 既有的 0.35 蒙版层
//      完成，shader 内自带的 dim 项保留但不再参与变暗；
//   3) uMotion 恒传 1.0（本仓暂不接 FFT），保留 shader 的强度语义。
// uniform 名称与声明顺序保持与上游完全一致：Dart 侧按索引打包 45 个 float
// （lib/widgets/flowing_background_uniforms.dart），不可重排。

#include <flutter/runtime_effect.glsl>

// Packed with FluidFrameUniforms; frame-only work is evaluated once in Dart.
uniform vec2 uSize;
uniform float uMotion;
uniform float uDim;
uniform vec2 uPhases;
uniform vec2 uCentre0;
uniform vec2 uCentre1;
uniform vec2 uCentre2;
uniform vec2 uCentre3;
uniform vec3 uPigment0;
uniform vec3 uPigment1;
uniform vec3 uPigment2;
uniform vec3 uPigment3;
uniform vec3 uBase;
uniform vec4 uShape0;
uniform vec4 uShape1;
uniform vec4 uShape2;
uniform vec4 uShape3;
out vec4 fragColor;

float pigmentWeight(vec2 point, vec2 centre, vec4 shape) {
  vec2 scale = uSize / max(min(uSize.x, uSize.y), 1.0);
  vec2 local = (point - centre) * scale;
  vec2 delta = vec2(dot(shape.xy, local), dot(shape.zw, local));
  // Bounded asymmetric curvature without extra pixel sine, noise or texture.
  float bend = uMotion / (1.0 + dot(delta, delta));
  delta += bend * vec2(0.20 * delta.y * delta.y, 0.16 * delta.x * delta.y);
  float falloff = 1.0 / (1.0 + dot(delta, delta));
  // Convex, open fields retain the wide edge while reducing distant pigment
  // contamination of dark centres; no additive whitening or layered enclosure.
  return falloff * falloff * (0.65 + 0.35 * falloff);
}
float interleavedGradientNoise(vec2 pixel) {
  return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}
void main() {
  vec2 uv = FlutterFragCoord().xy / max(uSize, vec2(1.0));
  vec2 point = uv + uMotion * vec2(
      0.055 * sin(uv.y * 2.3 + uPhases.y),
      0.045 * sin(uv.x * 2.0 - uPhases.x));
  vec4 weights = vec4(pigmentWeight(point, uCentre0, uShape0),
      pigmentWeight(point, uCentre1, uShape1), pigmentWeight(point, uCentre2, uShape2),
      pigmentWeight(point, uCentre3, uShape3));
  float mass = dot(weights, vec4(1.0));
  weights /= max(mass, 0.00001);
  vec3 pigment = uPigment0 * weights.x + uPigment1 * weights.y +
      uPigment2 * weights.z + uPigment3 * weights.w;
  // Do not reinforce a rounded outline with a distance-dependent colour veil.
  float coverage = 0.84;
  vec3 color = mix(uBase, pigment, coverage);
  float vignette = 1.0 - smoothstep(0.35, 1.10, distance(uv, vec2(0.5, 0.48)));
  color *= mix(0.98, 1.00, vignette);
  color *= 1.0 - clamp(uDim, 0.0, 0.60) * 0.25;
  float dither = (interleavedGradientNoise(FlutterFragCoord().xy) - 0.5) * (0.70 / 255.0);
  color = clamp(color + vec3(dither), vec3(0.0), vec3(1.0));
  fragColor = vec4(color, 1.0);
}
