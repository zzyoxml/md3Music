#version 460 core

#include <flutter/runtime_effect.glsl>

// 分层 gather 视差 + 让出区填充（layered gather + disocclusion fill）
//
// 【位移 ∝ 1/z（透视）而非 ∝ d（线性）】
// 相机平移 t 时，深度为 z 的点在屏幕上的位移 = f·t/z —— **与 1/z 成正比**。
// 直接 ∝ d 会让整幅画面（含远景背景）一起滑动，结果是"整体平移"而非"立体分层"；
// 改为 ∝ 1/z 后远景几乎钉死、位移集中在最近的少数像素上 → 前景真正浮出。
// 实测（2026-09-26，采样修正后的离线复刻，对自身真值 scatter+z-buffer）：
// 需 AI 修补的让出面积 9px 档 0.66%→0.16%、40px 档 4.16%→1.14%（约 −73%），
// 且自身真值 MAE 与 ∝d 版持平（0.0081 vs 0.0055）→ 保真度无损；
// 封面上的标题文字不再随视差错位（见 tmp/repro_out/stage2_truth_s40.png）。
//
// 正向模型：源点 p 显示在屏幕 p + shift·w(d(p))，其中 w = perspectiveWeight。
// 其逆映射为 src = uv − shift·w(占据 uv 的那个表面的深度)。
// 关键：偏移里用的是**占据 uv 的表面深度**，而不是 depth(uv)。
// 旧版写成 suv = uv - shift·depth(uv)（拿屏幕点自身的深度当表面深度），在物体
// 内部两者相等所以看不出问题，但在物体轮廓处不等——物体「移动过去」新覆盖的那条
// 带（宽度 = shift·w(d)）里 depth(uv) 仍是**旧背景**的深度，于是位移量
// 趋近 0，采样到的还是旧背景 —— 表现为「主体被背景咬掉一条边 / 主体在背景下面」。
//
// 【本实现的做法】由近及远试探 kLayers 个候选权重层 wk（在 w 空间均匀分层）：
//      src = uv - shift·wk ；若 |w(depth(src)) - wk| < tol 则该源点确实映射到 uv
//      （因为 src + shift·w(depth(src)) ≈ src + shift·wk = uv），取**最近**的命中层。
// 最终的位移用的是命中层的**真实连续值 w(depth(src))**，不是离散的 wk —— 所以位移
// 不会被量化成平板（旧 POM 把 plane 量化到 0.1 一级，才会把主体切成若干刚性平板
// 互相错位）。
//
// 【让出区】物体移走后露出的背景在源图里根本不存在，必须用 AI 修补背景 bg_fill：
//   ① 所有层都不命中 —— 没有任何源点映射到本点（纯空洞）；
//   ② 本点原属近处物体（depth(uv) 高），但可见表面明显更远（depth(uv) - dv 大）
//      —— 物体已移走，命中到的是被拉伸的轮廓过渡像素。
// 判据②刻意用「原处深度 vs 命中表面深度」而非旧版的 depth(uv) - depth(suv)：后者
// 在物体新覆盖带里也会触发，正是把主体填成背景的元凶。
uniform vec2 u_size;       // 画布像素尺寸（逻辑坐标，与 FlutterFragCoord 同空间）
uniform vec2 u_tilt;       // 归一化倾斜 -1..1（已平滑）
uniform float u_shift;     // 最大位移占宽度比例（自适应强度在 Dart 侧乘好）
uniform float u_holeLo;    // 让出区判据下沿（depth(uv) - 可见表面深度）
uniform float u_holeHi;    // 让出区判据上沿

out vec4 fragColor;

// 约定：sampler uniform 必须声明在所有 float uniform 之后
uniform sampler2D u_image; // 原图
uniform sampler2D u_depth; // 深度图
uniform sampler2D u_bg;    // 修补背景（无则 Dart 侧绑原图占位，行为退化等价旧版）

const int kLayers = 16;                  // 试探层数（16 次深度采样）
const float kLayerTol = 1.0 / float(kLayers); // 一致性窗口 = 层宽，相邻层无缝覆盖
const float kBackgroundShiftRatio = 0.35; // 修补背景的位移比（远景，弱于前景）
// 归一化深度 → 相机距离的经验映射区间：d=1(最近)→z=kZB，d=0(最远)→z=kZA+kZB。
// 比值 kZA/kZB=10 决定远近位移比（近 11× 远），取自 Gaussian-3D-Scanner 的
// z=d*3+0.3 并翻转到「d 大=近」的约定。改动它会改变立体强度，需重跑离线对照。
const float kZA = 3.0;
const float kZB = 0.3;

// 位移权重 w(d) = 归一化的 1/z ∈ [0,1]，w(0)=0（最远不动）、w(1)=1（最近满位移）。
float perspectiveWeight(float d) {
  float z = kZA * (1.0 - d) + kZB;
  float invMin = 1.0 / (kZA + kZB); // d=0
  float invMax = 1.0 / kZB;         // d=1
  return (1.0 / z - invMin) / (invMax - invMin);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
  vec2 shift = u_tilt * u_shift;

  float d0 = texture(u_depth, uv).x;

  // 由近及远找「占据本屏幕点」的最近表面。
  // dv = 该表面的原始深度（让出判据用，阈值语义不变）；wv = 该表面的位移权重。
  float dv = -1.0;
  float wv = -1.0;
  for (int k = kLayers - 1; k >= 0; k--) {
    float wk = (float(k) + 0.5) / float(kLayers);
    vec2 s = clamp(uv - shift * wk, vec2(0.0), vec2(1.0));
    float raw = texture(u_depth, s).x;
    float ds = perspectiveWeight(raw);
    // 无分支：仅当尚未命中且本层一致时才采纳
    float w = step(abs(ds - wk), kLayerTol) * step(dv, -0.5);
    dv = mix(dv, raw, w);
    wv = mix(wv, ds, w);
  }

  float hit = step(0.0, dv);        // 1 = 找到可见表面，0 = 纯空洞
  float wo = max(wv, 0.0);          // 位移权重（连续值，不量化 → 无平板错位）

  vec2 suv = clamp(uv - shift * wo, vec2(0.0), vec2(1.0));
  vec2 buv = clamp(uv - shift * kBackgroundShiftRatio, vec2(0.0), vec2(1.0));

  float hole = max(1.0 - hit, hit * smoothstep(u_holeLo, u_holeHi, d0 - max(dv, 0.0)));
  fragColor = mix(texture(u_image, suv), texture(u_bg, buv), hole);
}
