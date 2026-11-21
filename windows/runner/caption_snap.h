#ifndef RUNNER_CAPTION_SNAP_H_
#define RUNNER_CAPTION_SNAP_H_

#include <windows.h>

// Win11 的 snap layouts 悬停面板只在 WM_NCHITTEST 对最大化按钮返回
// HTMAXBUTTON(9) 时出现。本窗口是无边框自绘标题栏（客户区=整窗，三键由
// Flutter 画），系统永远轮不到给出这个命中，必须自己判定并返回。
// 常量照 window_corner.h 的口径手写：不依赖 SDK 枚举名，老 SDK 也能编译
// （HTMAXBUTTON 在全部受支持 SDK 里都是 9）。
constexpr int kCaptionHitMaxButton = 9;         // HTMAXBUTTON
constexpr UINT kMsgGetTitleBarInfoEx = 0x033F;  // WM_GETTITLEBARINFOEX

// 按钮命中矩形：客户区坐标、物理像素，右/下开边界（与系统标题栏按钮相邻
// 矩形不重叠、无缝衔接的惯例一致）。空矩形（w/h<=0）恒不命中。
constexpr bool PtInCaptionRectExclusive(POINT p, RECT r) {
  if (r.right <= r.left || r.bottom <= r.top) return false;
  return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom;
}

// 最大化态的客户区求交：Win11 snap 后的窗口也是 IsZoomed==true，但窗口
// 矩形 = 分区矩形（可能远小于整块工作区）；硬编码 rcWork 会把客户区撑出
// 分区、内容被裁。经典最大化时窗口矩形≈rcMonitor，rcMonitor∩rcWork=rcWork，
// 求交与原逻辑等价；空交集（异常几何）回退第一个矩形，保证不塌成零尺寸。
constexpr RECT IntersectOrFallback(RECT a, RECT b) {
  RECT out{a.left > b.left ? a.left : b.left,
           a.top > b.top ? a.top : b.top,
           a.right < b.right ? a.right : b.right,
           a.bottom < b.bottom ? a.bottom : b.bottom};
  if (out.right <= out.left || out.bottom <= out.top) return a;
  return out;
}

#endif  // RUNNER_CAPTION_SNAP_H_
