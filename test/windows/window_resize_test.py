"""无边框窗口边缘缩放的源码接线检查（无需编译器）。

Flutter 视图子窗口铺满整个客户区，会把窗口边缘的缩放热区盖住。原生侧给
子窗口挂了命中钩子：边缘点返回 HTTRANSPARENT，把命中测试让给顶层窗口的
WM_NCHITTEST，由系统进入缩放循环。
"""

from pathlib import Path
import sys

MAXIMIZED_HINT = "if (!IsZoomed(hwnd))"
FULLSCREEN_HINT = "if (fullscreen_) return HTCLIENT;"
SUBCLASS_HINT = "SetWindowSubclass(child_view_"
REMOVE_HINT = "RemoveWindowSubclass(child_view_"
TRANSPARENT_HINT = "return HTTRANSPARENT;"


def main():
    root = Path(__file__).resolve().parents[2]
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    failures = 0

    def check(name, passed):
        nonlocal failures
        print(name, "PASS" if passed else "FAIL")
        if not passed:
            failures += 1

    check("child-subclass-installed", SUBCLASS_HINT in source)
    check("child-subclass-removed", REMOVE_HINT in source)
    check("child-returns-transparent", TRANSPARENT_HINT in source)
    check(
        "top-level-uses-resolver",
        "hit = ResolveResizeHit(" in source,
    )
    check(
        "subclass-uses-resolver",
        "self->ResolveResizeHit(point)" in source,
    )
    check("fullscreen-guard", FULLSCREEN_HINT in source)
    check("maximized-guard", MAXIMIZED_HINT in source)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
