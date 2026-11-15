"""在 VS x64 开发环境运行：python test/windows/tray_lifecycle_test.py。

编译源码中实际的托盘创建、WM_CLOSE、TaskbarCreated 分支，使用可控 Shell
模拟任务栏重建和 API 失败；不启动 Flutter，也不重启用户的 Explorer。
"""

import argparse
from pathlib import Path
import subprocess
import sys


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    out = (args.out or root / "tmp/tray-lifecycle-test").resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    modern = "bool FlutterWindow::EnsureTrayIcon()" in source
    if modern:
        create = "EnsureTrayIcon();"
        ensure = block(source, "bool FlutterWindow::EnsureTrayIcon()")
    else:
        start = source.index("  NOTIFYICONDATAW tray_icon{};", source.index("bool FlutterWindow::OnCreate()"))
        end = source.index(";", source.index("tray_icon_added_ = Shell_NotifyIconW", start)) + 1
        create = source[start:end]
        ensure = ""
    close = block(source, "if (message == WM_CLOSE)")
    restart = block(source, "if (kTaskbarCreatedMessage != 0") if modern else ""
    harness = r'''
#include <cwchar>
#include <iostream>
using UINT = unsigned; using HWND = int; using HICON = int;
constexpr int NIF_ICON=1, NIF_MESSAGE=2, NIF_TIP=4;
constexpr int NIM_ADD=0, NIM_MODIFY=1, SW_HIDE=0, SW_RESTORE=9;
constexpr int WM_CLOSE=16, kTrayCallbackMessage=1025, kTaskbarCreatedMessage=50000;
constexpr int IDI_APP_ICON=101, IDI_APPLICATION=32512;
constexpr bool TRUE=true;
#define MAKEINTRESOURCE(x) (x)
#define MAKEINTRESOURCEW(x) (x)
struct NOTIFYICONDATAW { unsigned cbSize; HWND hWnd; UINT uID, uFlags, uCallbackMessage; HICON hIcon; wchar_t szTip[128]; };
bool present=false, shell_ready=true, resource_ok=true, visible=true, destroyed=false;
void* GetModuleHandle(void*) { return reinterpret_cast<void*>(1); }
void* GetModuleHandleW(void*) { return reinterpret_cast<void*>(1); }
int LoadIcon(void*, int) { return resource_ok ? 1 : 0; }
int LoadIconW(void* module, int) { return module == nullptr || resource_ok ? 1 : 0; }
bool Shell_NotifyIconW(int op, NOTIFYICONDATAW* data) {
  if (!shell_ready || !data->hIcon) return false;
  if (op == NIM_MODIFY) return present;
  present = true; return true;
}
bool IsWindowVisible(HWND) { return visible; }
void ShowWindow(HWND,int cmd) { visible = cmd != SW_HIDE; }
class FlutterWindow {
 public:
  bool tray_icon_added_=false;
  HWND GetHandle() { return 1; }
  void SetQuitOnClose(bool) {}
  void Destroy() { destroyed=true; }
  bool EnsureTrayIcon();
  void Start() { {{CREATE}} }
  int Message(int message) { HWND hwnd=GetHandle(); {{RESTART}} {{CLOSE}} return 0; }
};
{{ENSURE}}
int main() {
  int failures=0;
  auto check = [&](const char* name, bool passed) {
    std::cout << name << ": icon=" << present << " visible=" << visible
              << " destroyed=" << destroyed << " " << (passed?"PASS":"FAIL") << "\n";
    if (!passed) ++failures;
  };
  auto reset = [&]() { present=false; shell_ready=true; resource_ok=true; visible=true; destroyed=false; };
  reset(); FlutterWindow startup; startup.Start();
  check("startup", present);
  visible=false; present=false; startup.Message(kTaskbarCreatedMessage);
  check("taskbar-recreated", present);
  reset(); FlutterWindow lost; lost.Start(); present=false; lost.Message(WM_CLOSE);
  check("lost-icon-before-close", present && !visible && !destroyed);
  reset(); FlutterWindow failed; failed.Start(); visible=false; present=false; shell_ready=false;
  failed.Message(kTaskbarCreatedMessage);
  check("taskbar-recreate-failed", visible && !present);
  reset(); FlutterWindow closing; closing.Start(); present=false; shell_ready=false; closing.Message(WM_CLOSE);
  check("shell-unavailable-on-close", destroyed && visible);
  reset(); resource_ok=false; FlutterWindow fallback; fallback.Start();
  check("resource-fallback", present);
  return failures ? 1 : 0;
}
'''
    harness = harness.replace("{{CREATE}}", create).replace("{{RESTART}}", restart).replace("{{CLOSE}}", close).replace("{{ENSURE}}", ensure)
    # 只替换占位符，不能改变 WM_CLOSE / NIM_* 等源码标识符。
    cpp = out / "tray_lifecycle_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "tray_lifecycle_test.exe"
    result = subprocess.run(["cl", "/nologo", "/std:c++17", "/EHsc", "/utf-8", "/W4", "/WX", "/wd4100", str(cpp), f"/Fo{out / 'tray_lifecycle_test.obj'}", f"/Fe{exe}"], cwd=out)
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


if __name__ == "__main__":
    sys.exit(main())
