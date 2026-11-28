#ifndef RUNNER_WINDOW_CORNER_H_
#define RUNNER_WINDOW_CORNER_H_

// Win11（22000+）的 DWM 窗口圆角属性。老 SDK / Win10 不认识该属性，
// DwmSetWindowAttribute 会返回失败（E_INVALIDARG），调用方忽略即可。
//
// 这里不复用 SDK 的 DWM_WINDOW_CORNER_PREFERENCE 枚举：与
// DWMWA_USE_IMMERSIVE_DARK_MODE 的处理一致，老 SDK 也能编译。
constexpr int kDwmWindowCornerPreference = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
constexpr int kDwmCornerDoNotRound = 1;         // DWMWCP_DONOTROUND
constexpr int kDwmCornerRound = 2;              // DWMWCP_ROUND

// 圆角偏好只给「普通窗口」：最大化贴的是 rcWork、全屏贴的是 rcMonitor，
// 这两种形态必须保持直角，否则屏幕四角会被裁掉、露出桌面。
constexpr int ResolveCornerPreference(bool fullscreen, bool maximized) {
  return (fullscreen || maximized) ? kDwmCornerDoNotRound : kDwmCornerRound;
}

#endif  // RUNNER_WINDOW_CORNER_H_
