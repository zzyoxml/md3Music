"""Win11 snap layouts（HTMAXBUTTON 三件套）回归：纯函数矩阵 + 源码接线。

python test/windows/window_caption_snap_test.py            # 需 VS x64 开发环境
python test/windows/window_caption_snap_test.py --source-only   # 无编译器时只跑接线
"""

import argparse
from pathlib import Path
import subprocess
import sys


def source_checks(root, check):
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    dart_controls = (
        root / "lib/core/services/windows_window_controls.dart"
    ).read_text(encoding="utf-8")
    dart_row = (
        root / "lib/core/widgets/windows_caption_buttons.dart"
    ).read_text(encoding="utf-8")

    # 命中：按钮判定必须排在缩放边判定**之前**。播放页三键贴上沿，按钮顶部
    # 那 ~9px 与顶边缩放带重叠；排在后面会被 HTTOP 抢先 → 「上半部无反应」。
    check("hit-returns-maxbutton", "return kCaptionHitMaxButton;" in source)
    check(
        "hit-before-resize-guard",
        source.index("return kCaptionHitMaxButton;")
        < source.index("if (!IsZoomed(hwnd)) {"),
    )
    check(
        "hit-after-fullscreen-guard",
        source.index("if (fullscreen_) return HTCLIENT;")
        < source.index("return kCaptionHitMaxButton;"),
    )
    # 登记通道：set / clear 两个分支都必须自行 return（不落进末尾 IsZoomed）。
    check("channel-set-rect", 'method == "setCaptionMaxButtonRect"' in source)
    check("channel-clear-rect", 'method == "clearCaptionMaxButtonRect"' in source)
    check(
        "set-rect-refuses-fullscreen",
        "if (fullscreen_ || id.empty())" in source,
    )
    # 非客户区动作：UP 走 ToggleMaximize（含退出全屏语义 + 落盘），DBLCLK 被吞。
    check("ncup-toggles", "ToggleMaximize();" in source)
    check(
        "nc-messages-guarded",
        "WM_NCLBUTTONDOWN || message == WM_NCLBUTTONUP" in source
        and "WM_NCLBUTTONDBLCLK" in source,
    )
    # 悬停状态机：命中布防 TME_LEAVE、子窗口钩子负责「移回客户区」的离开清除。
    check("hover-armed", "leave.dwFlags = TME_LEAVE;" in source)
    check("ncmouse-leave", "message == WM_NCMOUSELEAVE" in source)
    check(
        "child-clears-hover",
        "self->caption_hovered_ = false;" in source,
    )
    # 接管态唯一事实源 = 广播（set 换行 / clear 清空 / 全屏形态切换都广播）。
    check("broadcast-takeover", 'InvokeMethod(\n      "onCaptionMaxTakeover"' in source)
    check(
        "takeover-broadcast-count",
        source.count("NotifyCaptionMaxTakeover();") >= 3,
    )
    # snap 后客户区求交：IsZoomed 分支不能再硬编码 rcWork。
    check(
        "nccalc-intersects-work",
        "params->rgrc[0] = IntersectOrFallback(monitor.rcWork" in source,
    )
    # 全屏分支必须排在 IsZoomed 分支之前（W3 的分支顺序约束，限在 NCCALCSIZE 段内比较）
    nccalc = source[source.index("WM_NCCALCSIZE && wparam == TRUE"):]
    check(
        "fullscreen-branch-before-zoomed",
        nccalc.index("if (fullscreen_) {") < nccalc.index("if (IsZoomed(hwnd)) {"),
    )
    # TITLEBARINFOEX 兜底：覆盖索引 3（最大化按钮）。
    check(
        "titlebar-info-ex",
        "message == kMsgGetTitleBarInfoEx" in source
        and "kTitleBarMaxButton = 3" in source,
    )
    # Dart 侧接线：接管态订阅广播；矩形上报带 id；原生入站分发挂进 window_tray。
    check("dart-owner-notifier", "maxButtonOwner" in dart_controls)
    check("dart-report-with-id", "reportMaxButtonRect(\n      String id" in dart_controls)
    check("dart-handle-native", "handleNativeCall" in dart_controls)
    check("dart-row-subscribes-owner", "maxButtonOwner.addListener" in dart_row)
    check("dart-row-native-pointer", "nativePointer" in dart_row)


def matrix_harness():
    return r'''
#include <cstdio>
#include "caption_snap.h"

int main() {
  int failures = 0;
  auto check = [&](const char* name, bool ok) {
    std::printf("%s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) ++failures;
  };
  const RECT button{100, 0, 146, 32};
  check("inside", PtInCaptionRectExclusive(POINT{120, 16}, button));
  check("left-edge-inclusive", PtInCaptionRectExclusive(POINT{100, 16}, button));
  check("top-edge-inclusive", PtInCaptionRectExclusive(POINT{120, 0}, button));
  check("right-edge-exclusive", !PtInCaptionRectExclusive(POINT{146, 16}, button));
  check("bottom-edge-exclusive", !PtInCaptionRectExclusive(POINT{120, 32}, button));
  check("outside-left", !PtInCaptionRectExclusive(POINT{99, 16}, button));
  check("empty-rect", !PtInCaptionRectExclusive(POINT{0, 0}, RECT{0, 0, 0, 0}));

  // 经典最大化：窗口矩形 = rcMonitor 向四周扩出边框（{-8,-8,1928,1088} 对应
  // 1920×1080 屏），∩rcWork = rcWork（与旧的硬编码逐像素等价）。
  RECT window{ -8, -8, 1928, 1088 };
  RECT work{0, 0, 1920, 1020};
  RECT classic = IntersectOrFallback(work, window);
  check("classic-equals-work",
        classic.left == 0 && classic.top == 0 && classic.right == 1920 && classic.bottom == 1020);
  // 左半分区：窗口矩形完全落在 rcWork 内，取交集 = 分区矩形（不被撑成整块工作区）。
  RECT left_half{0, 0, 960, 1020};
  RECT snapped = IntersectOrFallback(work, left_half);
  check("half-snap-keeps-zone",
        snapped.left == 0 && snapped.top == 0 && snapped.right == 960 && snapped.bottom == 1020);
  // 四分之一（左上）分区。
  RECT quarter{0, 0, 960, 510};
  RECT q = IntersectOrFallback(work, quarter);
  check("quarter-snap-keeps-zone", q.right == 960 && q.bottom == 510);
  // 空交集（异常几何，如拔掉显示器后的残留矩形）回退第一个参数，不塌成零尺寸。
  RECT far_away{5000, 5000, 6000, 6000};
  RECT fallback = IntersectOrFallback(work, far_away);
  check("empty-intersect-fallback",
        fallback.left == 0 && fallback.right == 1920 && fallback.bottom == 1020);
  return failures ? 1 : 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    failures = 0

    def check(name, passed):
        nonlocal failures
        print(name, "PASS" if passed else "FAIL")
        if not passed:
            failures += 1

    source_checks(root, check)
    if args.source_only:
        return 1 if failures else 0

    out = (args.out or root / "tmp/window-caption-snap-test").resolve()
    out.mkdir(parents=True, exist_ok=True)
    cpp = out / "caption_snap_matrix.cpp"
    cpp.write_text(matrix_harness(), encoding="utf-8")
    exe = out / "caption_snap_matrix.exe"
    result = subprocess.run(
        [
            "cl", "/nologo", "/std:c++17", "/EHsc", "/utf-8", "/W4", "/WX",
            "/wd4100", "/DUNICODE", "/D_UNICODE",
            f"/I{root / 'windows/runner'}",
            str(cpp), f"/Fo{out / 'caption_snap_matrix.obj'}", f"/Fe{exe}",
        ],
        cwd=out,
    )
    if result.returncode:
        return result.returncode
    return max(failures, 0) or subprocess.run([str(exe)], cwd=out).returncode


if __name__ == "__main__":
    sys.exit(main())
