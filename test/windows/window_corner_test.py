"""VS x64 开发环境运行：编译 window_corner.h 的偏好矩阵，并核验原生接线。"""

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
    out = (args.out or root / "tmp/window-corner-test").resolve()
    out.mkdir(parents=True, exist_ok=True)

    failures = 0

    def check(name, passed):
        nonlocal failures
        print(name, "PASS" if passed else "FAIL")
        if not passed:
            failures += 1

    # 源码接线：圆角偏好必须覆盖 OnCreate / SetFullscreen / WM_SIZE 三条路径，
    # 且只在最大化状态真正切换时重设（拖拽缩放也会发 SIZE_RESTORED）。
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    check("includes-window-corner", '"window_corner.h"' in source)
    check("uses-pure-resolver", "ResolveCornerPreference" in source)
    check(
        "dwm-attribute",
        "DwmSetWindowAttribute" in source and "kDwmWindowCornerPreference" in source,
    )
    check(
        "reapply-paths",
        # SetFullscreen 末尾 / OnCreate / WM_SIZE
        source.count("ApplyWindowCornerPreference();") >= 3,
    )
    check("maximize-transition-guard", "maximized_now != last_maximized_" in source)

    harness = r'''
#include <cstdio>
#include "window_corner.h"

int main() {
  int failures = 0;
  auto check = [&](const char* name, int got, int want) {
    const bool ok = got == want;
    std::printf("%s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) ++failures;
  };
  check("normal-round", ResolveCornerPreference(false, false),
        kDwmCornerRound);
  check("maximized-no-round", ResolveCornerPreference(false, true),
        kDwmCornerDoNotRound);
  check("fullscreen-no-round", ResolveCornerPreference(true, false),
        kDwmCornerDoNotRound);
  check("fullscreen-maximized-no-round", ResolveCornerPreference(true, true),
        kDwmCornerDoNotRound);
  return failures ? 1 : 0;
}
'''
    cpp = out / "window_corner_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "window_corner_test.exe"
    result = subprocess.run(
        [
            "cl",
            "/nologo",
            "/std:c++17",
            "/EHsc",
            "/utf-8",
            "/W4",
            "/WX",
            f"/I{root / 'windows/runner'}",
            str(cpp),
            f"/Fo{out / 'window_corner_test.obj'}",
            f"/Fe{exe}",
        ],
        cwd=out,
    )
    if result.returncode:
        return result.returncode
    runtime = subprocess.run([str(exe)], cwd=out).returncode
    return 1 if (failures or runtime) else 0


if __name__ == "__main__":
    sys.exit(main())
