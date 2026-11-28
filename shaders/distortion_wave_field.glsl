// 两个波 shader 共读的那一个场（DistortionWaveShaders.metal 的 fieldAt）：
// 到波前的有符号距离，鼓包、模糊和颜色都从它推出来，所以三者不会互相错位。
//
//   d > 0  波还没到这一点
//   d = 0  波前
//   d < 0  波已经过去了
//
// 波前从源自己的轮廓（一个胶囊）出发，张开成圆弧：胶囊的脊线缩到 0，半径一直长。
// 摸在源的一侧时，波的坐标系会转（tilt）。环形没有脊线也不压扁；圆弧上随 x 变化
// 的量，环上就随角度变化。坐标单位是逻辑像素，y 向下。
//
// 引用它的 shader 要在 include 之前声明：
//   uniform vec4 uFront;  // originX, originY, spine, radius
//   uniform vec4 uShape;  // squash, time, swell, tilt
// 并定义 WAVE_RING / WAVE_HOLD（1 / 0 表示环形；被保护不动的半径）。
//
// 移植自 Libraries.dev Distortion waves（MIT，Copyright (c) 2026 Jakub Antalik）。

#ifndef DISTORTION_WAVE_FIELD_GLSL_
#define DISTORTION_WAVE_FIELD_GLSL_

// 两屏交叉淡入的那段的一半，pt（WaveFront.coverZone）。
const float coverZone = 60.0;
const float wavePi = 3.14159265;

// 波在这一点上有多少作用：保护区内 0，离远了 1。
float heldAt(vec2 p) {
  float hold = WAVE_HOLD;
  if (hold <= 0.0) return 1.0;
  return smoothstep(hold * 0.9, hold * 1.8, length(p - uFront.xy));
}

// p 处到波前的有符号距离。n 是屏幕上背离源的法线；q 是 p 在波坐标系里的位置，
// raw 是屏幕上的位移，两者都从波原算起；g 是原始距离的增长速度，d 已经除过它。
float fieldAt(vec2 p, out vec2 n, out vec2 q, out vec2 raw, out float g) {
  raw = p - uFront.xy;
  float cs = cos(uShape.w);
  float sn = sin(uShape.w);
  q = vec2(cs * raw.x + sn * raw.y, -sn * raw.x + cs * raw.y);
  float spine = uFront.z;
  float radius = uFront.w;
  float squash = uShape.x;
  float time = uShape.y;
  float swell = uShape.z;

  // x 的度量更窄，波前就弓起来：不弓的话，它在手机屏上几乎是一条平线。
  float mx = q.x * squash;
  vec2 v = vec2(max(abs(mx) - spine, 0.0), q.y);
  float l = max(length(v), 1e-3);
  vec2 grad = vec2(v.x * sign(q.x) * squash, v.y) / l;
  g = max(length(grad), 1e-3);

  // 沿波前的慢速弯曲，免得看着像圆规画出来的。
  float bend;
  if (WAVE_RING > 0.5) {
    float a = atan(q.y, q.x);
    bend = 0.62 * sin(2.0 * a + time * 1.1) + 0.38 * sin(3.0 * a - time * 1.5 + 1.7);
  } else {
    float s = mx * 0.0058;
    bend = 0.62 * sin(s + time * 1.1) + 0.38 * sin(s * 2.1 - time * 1.5 + 1.7);
  }

  vec2 m = grad / g;
  n = vec2(cs * m.x - sn * m.y, sn * m.x + cs * m.y);
  return (l - radius) / g + swell * bend;
}

#endif
