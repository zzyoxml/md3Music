// 扭曲波的颜色（waveBand），压在两屏之上，分两部分：
// 贴着波前的彩带，和留在屏幕边缘的余色。
//
// 移植自 Libraries.dev Distortion waves（https://github.com/Jakubantalik/Libraries.dev，
// MIT，Copyright (c) 2026 Jakub Antalik），经 dsh-Go 的 Dart 移植版转写。
// 改动只限：去掉未用的效果开关、注释按本仓库风格收短。
//
// 波前：调色板沿波前流动，前方一道色边、后方一道，中间一层辉光，每一处边缘都是
// 宽而羽化的。边缘：中间清空之后，颜色贴住屏幕圆角继续停留 —— 七个高斯团块沿周长
// 漂移呼吸，玻璃上还有一条细线，直到后面两道波前把它们擦掉。
//
// 调色板在 OKLab 里混合，最多八色加前后两条色边，相邻两色不会经过灰色。

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec4 uFront;   // originX, originY, spine, radius
uniform vec4 uShape;   // squash, time, swell, tilt
uniform vec4 uGlow;    // glow, rim, clearRadius, hairClearRadius
uniform vec4 uKind;    // ring, hold, lead, tail
uniform vec4 uRimA;    // strength, rimWidth, rimSoftness, cornerRadius
uniform vec4 uRimB;    // unevenness, pulse, hairlineWidth, hairlineOpacity
uniform vec4 uRimC;    // hairlineWhite, palette count, -, -
uniform vec4 uP0;
uniform vec4 uP1;
uniform vec4 uP2;
uniform vec4 uP3;
uniform vec4 uP4;
uniform vec4 uP5;
uniform vec4 uP6;
uniform vec4 uP7;
uniform vec4 uAhead;
uniform vec4 uBehind;
// 边缘的团块：沿周长的中心、长度、深度（WaveRim）。
uniform vec4 uL0;
uniform vec4 uL1;
uniform vec4 uL2;
uniform vec4 uL3;
uniform vec4 uL4;
uniform vec4 uL5;
uniform vec4 uL6;

out vec4 fragColor;

#define WAVE_RING uKind.x
#define WAVE_HOLD uKind.y
#include "distortion_wave_field.glsl"

float sq(float x) {
  return x * x;
}

vec3 oklabToSRGB(vec3 c) {
  float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
  float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
  float s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
  l = l * l * l;
  m = m * m * m;
  s = s * s * s;
  vec3 lin = clamp(vec3(
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  ), 0.0, 1.0);
  return mix(12.92 * lin, 1.055 * pow(lin, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), lin));
}

// 到"连续圆角矩形"的有符号距离：手机屏幕的圆角不是正圆，曲率从 1.53r 处开始，
// 45 度方向穿过正圆角所在的位置。
float continuousRectSDF(vec2 p, vec2 halfSize, float radius) {
  float a = min(radius * 1.528665, min(halfSize.x, halfSize.y));
  vec2 q = abs(p) - (halfSize - a);
  if (q.x <= 0.0 || q.y <= 0.0) {
    return max(abs(p.x) - halfSize.x, abs(p.y) - halfSize.y);
  }
  const float n = 3.26;
  vec2 u = q / a;
  float norm = pow(pow(u.x, n) + pow(u.y, n), 1.0 / n);
  vec2 g = pow(u / max(norm, 1e-4), vec2(n - 1.0));
  return (norm - 1.0) * a / max(length(g), 1e-3);
}

// 一个点沿视口圆角边长走到哪：从顶部中心顺时针，穿过四段圆弧，单位 pt。
// .y 是整圈周长。
vec2 perimeterAt(vec2 p, vec2 halfSize, float r) {
  float ex = max(halfSize.x - r, 0.0);
  float ey = max(halfSize.y - r, 0.0);
  float arc = 0.5 * wavePi * r;
  float P = 4.0 * (ex + ey + arc);
  float ax = abs(p.x);
  float ay = abs(p.y);
  if (ax > ex && ay > ey) {
    vec2 v = p - vec2(p.x >= 0.0 ? ex : -ex, p.y >= 0.0 ? ey : -ey);
    float a;
    float base;
    if (p.x >= 0.0 && p.y < 0.0) {
      a = atan(v.x, -v.y);
      base = ex;
    } else if (p.x >= 0.0) {
      a = atan(v.y, v.x);
      base = ex + arc + 2.0 * ey;
    } else if (p.y >= 0.0) {
      a = atan(-v.x, v.y);
      base = 3.0 * ex + 2.0 * arc + 2.0 * ey;
    } else {
      a = atan(-v.y, -v.x);
      base = 3.0 * ex + 3.0 * arc + 4.0 * ey;
    }
    return vec2(base + r * clamp(a, 0.0, 0.5 * wavePi), P);
  }
  bool side = ax > ex ? true : (ay > ey ? false : (halfSize.x - ax) < (halfSize.y - ay));
  if (side) {
    return vec2(p.x >= 0.0 ? ex + arc + (p.y + ey) : 3.0 * ex + 3.0 * arc + 2.0 * ey + (ey - p.y), P);
  }
  return vec2(p.y < 0.0 ? (p.x >= 0.0 ? p.x : P + p.x) : ex + 2.0 * arc + 2.0 * ey + (ex - p.x), P);
}

float lumpAt(float s, float P, vec4 lump) {
  float ds = s - lump.x;
  ds -= P * floor(ds / P + 0.5);
  return lump.z * exp(-sq(ds / lump.y));
}

// 沿周长 s 处边缘色有多厚，当成 rimWidth 的倍数：平均 1，最薄约 0.1，最厚近 3。
float rimThickness(float s, float P) {
  float t = 0.08 + lumpAt(s, P, uL0) + lumpAt(s, P, uL1) + lumpAt(s, P, uL2) + lumpAt(s, P, uL3)
    + lumpAt(s, P, uL4) + lumpAt(s, P, uL5) + lumpAt(s, P, uL6);
  return t / 1.0498;
}

// 交错梯度噪声：够盖住色带，又看不出颗粒。
float dither(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) - 0.5;
}

vec3 paletteColor(float k) {
  if (k < 0.5) return uP0.xyz;
  if (k < 1.5) return uP1.xyz;
  if (k < 2.5) return uP2.xyz;
  if (k < 3.5) return uP3.xyz;
  if (k < 4.5) return uP4.xyz;
  if (k < 5.5) return uP5.xyz;
  if (k < 6.5) return uP6.xyz;
  return uP7.xyz;
}

// 调色环上的一点。
vec3 paletteAt(float u) {
  float count = uRimC.y;
  float x = fract(u) * count;
  float i = min(floor(x), count - 1.0);
  float j = mod(i + 1.0, count);
  float m = fract(x);
  m = m * m * (3.0 - 2.0 * m);
  return mix(paletteColor(i), paletteColor(j), m);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float glow = uGlow.x;
  float rim = uGlow.y;
  float lead = uKind.z;
  float tail = uKind.w;
  float strength = uRimA.x;
  float rimWidth = uRimA.y;
  float rimSoftness = uRimA.z;
  float cornerRadius = uRimA.w;
  float unevenness = uRimB.x;
  float pulse = uRimB.y;
  float hairWidth = uRimB.z;
  float hairOpacity = uRimB.w;
  float hairWhite = uRimC.x;

  vec2 c = p - uSize * 0.5;
  float edgeDistance = continuousRectSDF(c, uSize * 0.5, cornerRadius);
  float inset = max(-edgeDistance, 0.0);
  // 圆角之外没有玻璃，边缘色和细线到此为止，0.75pt 抗锯齿。
  float inside = 1.0 - smoothstep(0.0, 0.75, edgeDistance);
  // 再往里，最厚的团块也淡没了，细线更远。
  bool nearEdge = rim > 0.0 && inside > 0.0
    && inset < max(rimWidth * 2.2 * (1.0 + 1.9 * unevenness), hairWidth * 0.5 + 0.75);
  // 波前的颜色没了之后，只剩边缘要画。
  if (glow <= 0.0 && !nearEdge) {
    fragColor = vec4(0.0);
    return;
  }

  vec2 n;
  vec2 q;
  vec2 raw;
  float g;
  float d = fieldAt(p, n, q, raw, g);
  float time = uShape.y;

  // 拖尾沿波前起伏收放，屏幕中间先清干净，那里更淡。
  bool ring = WAVE_RING > 0.5;
  float turn = atan(q.y, q.x);
  float along = q.x * 0.0068;
  float lobes = ring
    ? 0.5 + 0.5 * sin(2.0 * turn + time * 1.4) * cos(turn - time * 0.7 + 1.2)
    : 0.5 + 0.5 * sin(along * 1.3 + time * 1.4) * cos(along * 0.6 - time * 0.7 + 1.2);
  float bandA = 0.0;
  if (glow > 0.0 && d < lead) {
    if (d >= 0.0) {
      float k = 1.0 - d / lead;
      bandA = k * k * k * (k * (k * 6.0 - 15.0) + 10.0);
    } else {
      bandA = pow(1.0 - clamp(-d / (tail * mix(0.6, 1.3, lobes)), 0.0, 1.0), 2.3);
    }
    bandA *= glow * strength * mix(0.6, 1.0, exp(-inset / 140.0)) * heldAt(p);
  }

  // 绕视口一圈，按长宽归一，长边也分到该有的颜色。
  float around = atan(c.y / uSize.y, c.x / uSize.x);
  float rimA = 0.0;
  float hairA = 0.0;
  float shimmer = 0.5;
  if (nearEdge) {
    vec2 edge = perimeterAt(c, uSize * 0.5, cornerRadius);
    float thickness = 1.0;
    if (unevenness > 0.0) {
      thickness = max(1.0 + (rimThickness(edge.x, edge.y) - 1.0) * unevenness, 0.04);
    }
    float hug = exp(-sq(inset / (rimWidth * thickness)));
    float reached = 1.0 - smoothstep(-lead * 0.7, lead * 0.5, d);
    float kept = smoothstep(-rimSoftness, rimSoftness, d + (uFront.w - uGlow.z) / g);
    // 两道柔和的高光绕着边跑。
    shimmer = 0.5 + 0.5 * sin(time * 3.4 - edge.x / edge.y * 4.0 * wavePi);
    rimA = hug * reached * kept * rim * mix(1.0, 0.7 + 0.3 * shimmer, pulse) * inside;

    // 贴在玻璃上的细线：团块处最亮，光跑过的地方发白。由自己那道更晚的波前擦掉。
    if (hairWidth > 0.0) {
      float line = 1.0 - smoothstep(hairWidth * 0.5, hairWidth * 0.5 + 0.75, inset);
      float hairKept = smoothstep(-rimSoftness, rimSoftness, d + (uFront.w - uGlow.w) / g);
      hairA = line * reached * hairKept * rim * hairOpacity
        * mix(0.5, 1.0, smoothstep(0.1, 1.5, thickness))
        * mix(1.0, 0.55 + 0.45 * shimmer, pulse) * inside;
    }
  }

  float a = 1.0 - (1.0 - bandA) * (1.0 - rimA);
  float total = 1.0 - (1.0 - a) * (1.0 - hairA);
  if (total <= 0.0005) {
    fragColor = vec4(0.0);
    return;
  }

  // 环形时调色板跟着绕一圈。
  float flow = 0.62 + (ring ? turn / (2.0 * wavePi) : along * 0.2) + time * 0.13 + d * 0.0015
    + (ring ? 0.0 : 0.05 * sin(q.y * 0.009 + time));
  vec3 lab = paletteAt(flow);
  lab = mix(lab, uAhead.xyz, 0.5 * exp(-sq((d - 30.0) / 50.0)));
  lab = mix(lab, uBehind.xyz, 0.5 * exp(-sq((d + 84.0) / 72.0)));
  lab.yz *= 1.22;
  lab = mix(lab, vec3(0.99, 0.0, 0.0), 0.7 * exp(-sq((d + 8.0) / 26.0)));

  // 绕视口一圈：`around` 会跳整整一圈，fract() 盖住那一跳。
  vec3 rimLab = paletteAt(around / (2.0 * wavePi) + time * (0.12 + 0.25 * pulse) + inset * 0.0012);
  rimLab.yz *= 1.1;
  lab = mix(lab, rimLab, rimA / (rimA + bandA + 1e-4));

  // 辉光上的细线：边自己的颜色，光跑过处发白。
  vec3 rgb = oklabToSRGB(lab);
  if (hairA > 0.0) {
    vec3 hair = mix(oklabToSRGB(rimLab), vec3(1.0), hairWhite * (0.5 + 0.5 * shimmer));
    rgb = (rgb * a * (1.0 - hairA) + hair * hairA) / total;
  }

  float noise = dither(p) * 2.0 / 255.0;
  fragColor = vec4(clamp(rgb * total + noise, 0.0, 1.0), clamp(total + noise, 0.0, 1.0));
}
