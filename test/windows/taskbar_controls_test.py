"""在 VS x64 开发环境运行：python test/windows/taskbar_controls_test.py。

编译 `taskbar_progress.h` 的纯函数部分，断言任务栏进度映射的全部边界；
再对 `taskbar_controls.cpp` / `flutter_window.cpp` 做源码结构断言，钉住
三条「改错了不会报错、只会静默失效」的接线：

1. 缩略图按钮必须在任务栏按钮就绪后加（`ThumbBarAddButtons` + `TaskbarButtonCreated`）；
2. Explorer 重启要重建 COM（`OnTaskbarCreated` 挂在 `TaskbarCreated` 分支里）；
3. `THBN_CLICKED` 必须在交给 Flutter 引擎**之前**吃掉。

不启动 Flutter、不创建真实窗口、不碰用户的任务栏。
"""

import argparse
from pathlib import Path
import subprocess
import sys

# 逐条对应 taskbar_progress.h 的规则，一条都不可删：
# 删掉哪条，就会在对应场景下静默显示错进度（而不是报错）。
PROGRESS_CASES = [
    # (说明, position_ms, duration_ms, is_playing, visible, 期望 state, 期望 completed)
    ("无歌/已停止收掉进度条", 120000, 240000, True, False, 0, 0),
    ("时长未知收掉进度条", 120000, 0, True, True, 0, 0),
    ("负时长收掉进度条", 120000, -1, True, True, 0, 0),
    ("播放中 → 绿色 NORMAL", 120000, 240000, True, True, 2, 500),
    ("暂停 → 黄色 PAUSED", 120000, 240000, False, True, 8, 500),
    ("位置为 0 → 0", 0, 240000, True, True, 2, 0),
    ("位置等于时长 → 满格", 240000, 240000, True, True, 2, 1000),
    ("位置越过时长夹到满格", 999999, 240000, True, True, 2, 1000),
    ("负位置夹到 0", -5000, 240000, True, True, 2, 0),
    # 1000ms 的三分之一 = 333.33 → 四舍五入 333；三分之二 = 666.67 → 667
    ("四舍五入：1/3", 1000, 3000, True, True, 2, 333),
    ("四舍五入：2/3", 2000, 3000, True, True, 2, 667),
    # 999/1000 → 999，不是 1000（末段不该提前满格）
    ("末段不满格", 239760, 240000, True, True, 2, 999),
    # 1ms 极短音频：位置 0 时 completed 为 0，不为负/溢出
    ("1ms 极短音频", 0, 1, True, True, 2, 0),
    ("1ms 极短音频末端", 1, 1, True, True, 2, 1000),
]


def build_and_run_progress_probe(root: Path, out: Path) -> int:
    header = root / "windows/runner/taskbar_progress.h"
    harness = (
        r'''
#include <iostream>
#include "taskbar_progress.h"

struct Case {
  const char* name;
  long long position;
  long long duration;
  bool playing;
  bool visible;
  int expect_state;
  unsigned long expect_completed;
};

int main() {
  const Case cases[] = {
'''
        + "\n".join(
            '      {"%s", %d, %d, %s, %s, %d, %d},'
            % (
                name,
                position,
                duration,
                "true" if playing else "false",
                "true" if visible else "false",
                state,
                completed,
            )
            for (
                name,
                position,
                duration,
                playing,
                visible,
                state,
                completed,
            ) in PROGRESS_CASES
        )
        + r'''
  };
  int failures = 0;
  for (const Case& c : cases) {
    const TaskbarProgress p = ResolveTaskbarProgress(
        c.position, c.duration, c.playing, c.visible);
    const bool ok = static_cast<int>(p.state) == c.expect_state &&
                    p.completed == c.expect_completed && p.total == 1000;
    std::cout << c.name << ": state=" << static_cast<int>(p.state)
              << " completed=" << p.completed << "/" << p.total
              << " expected=" << c.expect_state << "/" << c.expect_completed
              << "/1000 " << (ok ? "PASS" : "FAIL") << "\n";
    if (!ok) ++failures;
  }
  // TBPF 常量值本身也要对：Shell 只认这三个值，写错就等于传了非法枚举。
  // 走 volatile 读一遍再比，避免编译器把常量比较折叠成 C4127（/WX 会升级成错误）。
  volatile int no_progress = TBPF_NOPROGRESS;
  volatile int normal = TBPF_NORMAL;
  volatile int paused = TBPF_PAUSED;
  if (no_progress != 0 || normal != 2 || paused != 8) {
    std::cout << "TBPF 常量值不符: NOPROGRESS=" << no_progress
              << " NORMAL=" << normal << " PAUSED=" << paused
              << " FAIL\n";
    ++failures;
  }
  return failures ? 1 : 0;
}
'''
    )
    cpp = out / "taskbar_progress_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "taskbar_progress_test.exe"
    compile_cmd = [
        "cl",
        "/nologo",
        "/std:c++17",
        "/EHsc",
        "/utf-8",
        "/W4",
        "/WX",
        "/wd4100",
        "/DUNICODE",
        "/D_UNICODE",
        f"/I{header.parent}",
        str(cpp),
        f"/Fo{out / 'taskbar_progress_test.obj'}",
        f"/Fe{exe}",
        "user32.lib",
        "ole32.lib",
    ]
    result = subprocess.run(compile_cmd, cwd=out)
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


def check_source(root: Path) -> int:
    controls = (root / "windows/runner/taskbar_controls.cpp").read_text(
        encoding="utf-8"
    )
    window = (root / "windows/runner/flutter_window.cpp").read_text(
        encoding="utf-8"
    )
    header = (root / "windows/runner/taskbar_controls.h").read_text(
        encoding="utf-8"
    )
    cmake = (root / "windows/runner/CMakeLists.txt").read_text(encoding="utf-8")

    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"{name}: {'PASS' if ok else 'FAIL'}{(' ' + detail) if detail and not ok else ''}")
        if not ok:
            failures += 1

    # 1. 三个按钮：加 / 换 / 点击分发
    check("ThumbBarAddButtons 存在", "ThumbBarAddButtons" in controls)
    check("ThumbBarUpdateButtons 存在", "ThumbBarUpdateButtons" in controls)
    check("THBN_CLICKED 分发", "THBN_CLICKED" in controls)
    check("TaskbarButtonCreated 兜底重加", "TaskbarButtonCreated" in controls)
    check("TaskbarCreated 重建入口", "void TaskbarControls::OnTaskbarCreated" in controls)
    check(
        "重建时释放旧 COM",
        "OnTaskbarCreated" in controls
        and controls.index("void TaskbarControls::OnTaskbarCreated")
        < controls.index("CoCreateInstance", controls.index("void TaskbarControls::OnTaskbarCreated")),
    )
    # 2. 进度：去重 + 两种状态
    check("SetProgressState 调用", "SetProgressState" in controls)
    check("SetProgressValue 调用", "SetProgressValue" in controls)
    check("进度去重（has_last_progress_）", "has_last_progress_" in header)
    check(
        "NOPROGRESS 时不写进度值",
        "progress.state != TBPF_NOPROGRESS" in controls,
    )
    # 3. 图标成对释放（漏 DestroyIcon 就是每个主题切换漏 4 个 HICON）
    check(
        "DestroyIcon 与 LoadImageW 成对",
        "DestroyIcon" in controls and "LoadImageW" in controls,
    )
    check("图标按主题选变体（任务栏用 SystemUsesLightTheme）", "SystemUsesLightTheme" in controls)

    # 4. flutter_window 接线
    check("Initialize 接线", "taskbar_controls_.Initialize" in window)
    check("Shutdown 接线", "taskbar_controls_.Shutdown" in window)
    check("TaskbarCreated 分支调用重建", "taskbar_controls_.OnTaskbarCreated" in window)
    check("通道方法 setTaskbarState", 'method == "setTaskbarState"' in window)
    # 通道里 setTaskbarState 必须自己 return，不能落到末尾那句 IsZoomed 返回值
    start = window.index('method == "setTaskbarState"')
    segment = window[start : window.index("} else if", start + 10)]
    check("setTaskbarState 自行 return", "return;" in segment)
    # 5. THBN_CLICKED 必须先于 Flutter 引擎
    # 取**最后一次**出现：MessageHandler 前面的 WM_DPICHANGED 分支也调了
    # HandleTopLevelWindowProc，用 index() 会拿到那一处，断言就没意义了。
    handle = window.index("taskbar_controls_.HandleWindowMessage")
    flutter = window.rindex("HandleTopLevelWindowProc")
    check(
        "HandleWindowMessage 在 Flutter 之前",
        handle < flutter,
        f"handle={handle} flutter={flutter}",
    )
    # 6. CMake 收录新源文件
    check("CMakeLists 收录 taskbar_controls.cpp", '"taskbar_controls.cpp"' in cmake)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--source-only",
        action="store_true",
        help="只跑源码结构断言（没有 VS 开发环境时用）",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    out = (args.out or root / "tmp/taskbar-controls-test").resolve()
    out.mkdir(parents=True, exist_ok=True)

    failures = 0
    if not args.source_only:
        failures += build_and_run_progress_probe(root, out)
    failures += check_source(root)
    if failures:
        print(f"\n{failures} 项失败")
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
