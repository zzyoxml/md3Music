"""VS x64 开发环境运行：断言主窗口居中/恢复的纯计算口径。

python test/windows/window_placement_test.py
"""

import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    out = (args.out or root / "tmp/window-placement-test").resolve()
    out.mkdir(parents=True, exist_ok=True)
    harness = r'''
#include <windows.h>
#include <iostream>
#include "window_placement.h"

using window_placement::Placement;

static bool SameRect(const RECT& actual, LONG left, LONG top, LONG right, LONG bottom) {
  return actual.left == left && actual.top == top && actual.right == right &&
         actual.bottom == bottom;
}

int main() {
  int failures = 0;
  auto check = [&](const char* name, bool passed) {
    std::cout << name << " " << (passed ? "PASS" : "FAIL") << "\n";
    if (!passed) ++failures;
  };

  // 150% 缩放、1920x1020 工作区：期望 1920x1080 收到 1728x918 并居中。
  RECT centered = window_placement::CenterInWorkArea(RECT{0, 0, 1920, 1020}, 1920, 1080);
  check("center-150pct", SameRect(centered, 96, 51, 1824, 969));

  // 小屏：期望尺寸也要夹到 90% 工作区。
  RECT small = window_placement::CenterInWorkArea(RECT{0, 0, 1366, 728}, 1280, 720);
  check("center-small-screen", SameRect(small, 68, 36, 1297, 691));

  // 任务栏在顶部（rcWork.top = 48）：居中必须落在工作区内。
  RECT top_taskbar = window_placement::CenterInWorkArea(RECT{0, 48, 1920, 1080}, 1920, 1080);
  check("center-taskbar-top", SameRect(top_taskbar, 96, 100, 1824, 1028));

  // 期望尺寸小于上限：原尺寸居中。
  RECT normal = window_placement::CenterInWorkArea(RECT{0, 0, 1920, 1020}, 1280, 720);
  check("center-normal", SameRect(normal, 320, 150, 1600, 870));

  Placement out{};
  const RECT work{0, 0, 1920, 1020};

  Placement valid{};
  valid.rect = RECT{100, 100, 1380, 918};
  valid.dpi = 144;
  check("restore-valid",
        window_placement::SanitizePlacement(valid, work, 144, &out) &&
            SameRect(out.rect, 100, 100, 1380, 918));

  Placement offscreen{};
  offscreen.rect = RECT{3000, 3000, 4280, 3918};
  offscreen.dpi = 144;
  check("restore-offscreen-rejected",
        !window_placement::SanitizePlacement(offscreen, work, 144, &out));

  Placement mostly_offscreen{};
  mostly_offscreen.rect = RECT{-800, -800, 480, 118};
  mostly_offscreen.dpi = 144;
  check("restore-below-25pct-rejected",
        !window_placement::SanitizePlacement(mostly_offscreen, work, 144, &out));

  Placement partial{};
  partial.rect = RECT{1200, 400, 2480, 1318};
  partial.dpi = 144;
  check("restore-clamped-inside",
        window_placement::SanitizePlacement(partial, work, 144, &out) &&
            SameRect(out.rect, 640, 102, 1920, 1020));

  Placement oversized{};
  oversized.rect = RECT{0, 0, 2500, 1200};
  oversized.dpi = 144;
  check("restore-oversized-clamped",
        window_placement::SanitizePlacement(oversized, work, 144, &out) &&
            SameRect(out.rect, 0, 0, 1920, 1020));

  Placement other_dpi{};
  other_dpi.rect = RECT{100, 100, 900, 700};
  other_dpi.dpi = 96;
  check("restore-dpi-scaled",
        window_placement::SanitizePlacement(other_dpi, work, 144, &out) &&
            SameRect(out.rect, 100, 100, 1300, 1000));

  Placement zero{};
  zero.rect = RECT{10, 10, 10, 10};
  zero.dpi = 144;
  check("restore-zero-rejected",
        !window_placement::SanitizePlacement(zero, work, 144, &out));

  return failures ? 1 : 0;
}
'''
    cpp = out / "window_placement_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "window_placement_test.exe"
    result = subprocess.run(
        [
            "cl",
            "/nologo",
            "/std:c++17",
            "/EHsc",
            "/utf-8",
            "/W4",
            "/WX",
            "/DUNICODE",
            "/D_UNICODE",
            f"/I{root / 'windows/runner'}",
            str(cpp),
            f"/Fo{out / 'window_placement_test.obj'}",
            f"/Fe{exe}",
            "user32.lib",
        ],
        cwd=out,
    )
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


if __name__ == "__main__":
    sys.exit(main())
