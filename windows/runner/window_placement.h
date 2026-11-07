#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

// 主窗口启动几何：居中/恢复/可见性校验。
//
// 纯计算与注册表读写分开：本头文件只依赖 windows.h 的 RECT，可直接被
// `test/windows/window_placement_test.py` 单独编译断言；注册表部分在 .cpp。
namespace window_placement {

struct Placement {
  // 普通态窗口矩形（物理像素，工作区坐标系）。
  RECT rect = {0, 0, 0, 0};
  bool maximized = false;
  // 保存时的显示器 DPI；恢复时按比例缩放尺寸。
  int dpi = 0;
};

// 首次启动的最大占屏比：1920×1020 的工作区在 150% 缩放下会把
// 1920×1080 的期望尺寸收到 1728×918，避免窗口越出工作区被任务栏压住。
constexpr double kMaxWorkAreaRatio = 0.90;

inline LONG ClampLong(LONG value, LONG low, LONG high) {
  if (high < low) return low;
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

// 在工作区内居中，尺寸不超过工作区的 kMaxWorkAreaRatio。
inline RECT CenterInWorkArea(const RECT& work_area, int desired_width,
                             int desired_height) {
  const LONG work_width = work_area.right - work_area.left;
  const LONG work_height = work_area.bottom - work_area.top;
  if (work_width <= 0 || work_height <= 0) {
    return {0, 0, desired_width > 0 ? desired_width : 0,
            desired_height > 0 ? desired_height : 0};
  }
  const LONG max_width =
      static_cast<LONG>(static_cast<double>(work_width) * kMaxWorkAreaRatio);
  const LONG max_height =
      static_cast<LONG>(static_cast<double>(work_height) * kMaxWorkAreaRatio);
  LONG width = desired_width > 0 ? static_cast<LONG>(desired_width) : max_width;
  LONG height =
      desired_height > 0 ? static_cast<LONG>(desired_height) : max_height;
  if (width < 1) width = 1;
  if (height < 1) height = 1;
  if (width > max_width) width = max_width;
  if (height > max_height) height = max_height;
  const LONG left = work_area.left + (work_width - width) / 2;
  const LONG top = work_area.top + (work_height - height) / 2;
  return {left, top, left + width, top + height};
}

// 校验并修正保存的几何。
//
// 返回 false 表示保存值已经不可用（尺寸非法 / 与工作区交集不足 25%），
// 调用方应回退到 CenterInWorkArea。返回 true 时 out 已被夹到工作区内。
inline bool SanitizePlacement(const Placement& saved, const RECT& work_area,
                              int current_dpi, Placement* out) {
  if (out == nullptr) return false;
  RECT rect = saved.rect;
  LONG width = rect.right - rect.left;
  LONG height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return false;
  if (saved.dpi > 0 && current_dpi > 0 && saved.dpi != current_dpi) {
    const double ratio =
        static_cast<double>(current_dpi) / static_cast<double>(saved.dpi);
    width = static_cast<LONG>(static_cast<double>(width) * ratio);
    height = static_cast<LONG>(static_cast<double>(height) * ratio);
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    rect.right = rect.left + width;
    rect.bottom = rect.top + height;
  }

  RECT work = work_area;
  RECT intersection = {0, 0, 0, 0};
  if (!IntersectRect(&intersection, &rect, &work)) return false;
  const LONGLONG area = static_cast<LONGLONG>(width) * height;
  const LONGLONG visible_area =
      static_cast<LONGLONG>(intersection.right - intersection.left) *
      (intersection.bottom - intersection.top);
  // 可见面积不足 25%：当作显示器已拔掉 / 窗口被拖到屏幕外，回到居中。
  if (visible_area * 4 < area) return false;

  const LONG work_width = work_area.right - work_area.left;
  const LONG work_height = work_area.bottom - work_area.top;
  if (width > work_width) width = work_width;
  if (height > work_height) height = work_height;
  const LONG left =
      ClampLong(rect.left, work_area.left, work_area.right - width);
  const LONG top =
      ClampLong(rect.top, work_area.top, work_area.bottom - height);
  out->rect = {left, top, left + width, top + height};
  out->maximized = saved.maximized;
  out->dpi = current_dpi;
  return true;
}

// 读取 / 写入 HKCU\Software\md3Music\Window。Load 在缺项或损坏时返回 false。
bool Load(Placement* out);
void Save(const Placement& placement);

}  // namespace window_placement

#endif  // RUNNER_WINDOW_PLACEMENT_H_
