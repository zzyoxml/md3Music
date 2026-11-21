// 波前一面的折射（waveLens），叠着它的渐进模糊（waveBlurMask）：这一面的清晰
// 快照、一张 σ=7 的模糊副本、一张 σ=style.blur 的模糊副本，后一张在"该点应有的
// 模糊半径"超过前一张的地方盖住它。
//
// 移植自 Libraries.dev Distortion waves（https://github.com/Jakubantalik/Libraries.dev，
// MIT，Copyright (c) 2026 Jakub Antalik），经 dsh-Go 的 Dart 移植版转写。
//
// side：+1 波前**前方**的那一面（波要离开的旧页）；-1 波前**后方**的那一面（波带进来
// 的新页）。
//
// 鼓包经过时内容抬升一次再落回。重力是它之前的那段：一切朝源头下落，越近越强。
// 色散由同一位移推出来 —— 颜色沿"这个点被挪动的方向"分开，分多少按挪多远，五个
// 采样横跨光谱。

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec4 uFront;   // originX, originY, spine, radius
uniform vec4 uShape;   // squash, time, swell, tilt
uniform vec4 uMotion;  // energy, gravity, ring, hold
uniform vec4 uLens;    // amplitude, lensWidth, aberration, side
uniform vec4 uBlur;    // blur, blurAhead, blurBehind, launched
uniform sampler2D uSharp;
uniform sampler2D uNear;
uniform sampler2D uFar;

out vec4 fragColor;

#define WAVE_RING uMotion.z
#define WAVE_HOLD uMotion.w
#include "distortion_wave_field.glsl"

// 第一张模糊副本的半径；第二张用 style.blur。
const float nearBlur = 7.0;

float ease(float a, float b, float x) {
  float t = clamp((x - a) / max(b - a, 1e-3), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// 这一面在 x 处的颜色：清晰图打底，两张模糊副本依次 over 上去。
vec4 layerAt(vec2 x, float near, float far) {
  vec2 uv = clamp(x, vec2(0.5), uSize - 0.5) / uSize;
  vec4 c = texture(uSharp, uv);
  if (near > 0.0) {
    vec4 a = texture(uNear, uv) * near;
    c = a + c * (1.0 - a.a);
  }
  if (far > 0.0) {
    vec4 b = texture(uFar, uv) * far;
    c = b + c * (1.0 - b.a);
  }
  return c;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 n;
  vec2 q;
  vec2 raw;
  float g;
  float d = fieldAt(p, n, q, raw, g);
  float energy = uMotion.x;
  float gravity = uMotion.y;
  float side = uLens.w;

  // 波前前方（旧页）完全盖住新页的那段，新页没有东西可画；还没发射时新页整面都不画。
  float cover = 1.0;
  if (side > 0.0) {
    if (uBlur.w > 0.5) cover = smoothstep(-coverZone, coverZone, d);
    if (cover <= 0.0) {
      fragColor = vec4(0.0);
      return;
    }
  } else if (d > coverZone + 6.0) {
    fragColor = vec4(0.0);
    return;
  }

  // 前方更陡：它在压缩将要抵达的内容；后方拖得长。
  float u = d / (uLens.y * (d > 0.0 ? 0.85 : 1.5));
  float lift = exp(-u * u);
  float r = max(length(raw), 1.0);

  // 重力挪整屏，但离源头远处只是整体平移：只有在源头附近才把它算成形变。
  float held = heldAt(p);
  vec2 swollen = n * energy * uLens.x * lift * held;
  vec2 inward = raw / r;
  vec2 s = p - swollen + inward * gravity * exp(-r / 900.0) * held;
  vec2 split = (swollen - inward * gravity * exp(-r / 240.0) * held) * uLens.z;

  // 中间采样点落到的位置该有多糊：前方聚起、波前上最强、后方慢慢散开。
  float near = 0.0;
  float far = 0.0;
  if (energy > 0.0 && uBlur.x > 0.0) {
    vec2 sn;
    vec2 sq;
    vec2 sraw;
    float sg;
    float ds = fieldAt(s, sn, sq, sraw, sg);
    float su = ds / (ds > 0.0 ? uBlur.y : uBlur.z);
    float radius = energy * uBlur.x * exp(-su * su) * heldAt(s);
    near = ease(0.0, nearBlur, radius);
    far = ease(nearBlur, uBlur.x, radius);
  }

  // 不到四分之一点，色散看不出来。
  if (dot(split, split) < 0.0625) {
    fragColor = layerAt(s, near, far) * cover;
    return;
  }

  vec4 c0 = layerAt(s - split, near, far);
  vec4 c1 = layerAt(s - split * 0.5, near, far);
  vec4 c2 = layerAt(s, near, far);
  vec4 c3 = layerAt(s + split * 0.5, near, far);
  vec4 c4 = layerAt(s + split, near, far);
  vec3 rgb = c0.rgb * vec3(0.571, 0.0, 0.0) + c1.rgb * vec3(0.343, 0.206, 0.0)
    + c2.rgb * vec3(0.086, 0.588, 0.086) + c3.rgb * vec3(0.0, 0.206, 0.343)
    + c4.rgb * vec3(0.0, 0.0, 0.571);
  float a = (c0.a + c1.a + c2.a + c3.a + c4.a) / 5.0;
  fragColor = vec4(rgb, a) * cover;
}
