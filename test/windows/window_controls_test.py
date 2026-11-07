"""VS x64 开发环境运行：编译实际 MethodChannel 分支，核验 Win32 调用参数。"""

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
    out = (args.out or root / "tmp/window-controls-test").resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    if 'if (method == "minimize")' in source:
        start = source.index('if (method == "minimize")')
        end = source.index(';', source.index('result->Success', start)) + 1
        controls = source[start:end]
    else:
        controls = 'result->NotImplemented();'
    harness = r'''
#include <windows.h>
#include <iostream>
#include <string>
bool maximized=false, minimized=false, implemented=true, value=false;
UINT posted=0, sent=0; WPARAM sent_wparam=0; LPARAM sent_lparam=0; bool released=false;
BOOL FakeShow(HWND,int command) {
  minimized=command==SW_MINIMIZE;
  if(command==SW_MAXIMIZE) maximized=true;
  if(command==SW_RESTORE) maximized=false;
  return TRUE;
}
BOOL FakeZoomed(HWND) {return maximized;}
BOOL FakePost(HWND,UINT message,WPARAM,LPARAM) {posted=message;return TRUE;}
BOOL FakeCursor(POINT* point) {point->x=123;point->y=234;return TRUE;}
BOOL FakeRelease() {released=true;return TRUE;}
LRESULT FakeSend(HWND,UINT message,WPARAM wp,LPARAM lp) {sent=message;sent_wparam=wp;sent_lparam=lp;return 0;}
namespace flutter {using EncodableValue=bool;}
struct Result {
  void Success(bool v) {value=v;}
  void NotImplemented() {implemented=false;}
};
#define ShowWindow FakeShow
#define IsZoomed FakeZoomed
#define PostMessageW FakePost
#define GetCursorPos FakeCursor
#define ReleaseCapture FakeRelease
#define SendMessageW FakeSend
class Probe {
 public:
  HWND GetHandle() {return reinterpret_cast<HWND>(1);}
  void Control(const std::string& method) {
    Result response; auto* result=&response;
    (void)method;
    {{CONTROLS}}
  }
};
int main() {
  Probe window;int failures=0;
  auto check=[&](const char* name,bool passed){std::cout<<name<<" "<<(passed?"PASS":"FAIL")<<"\n";if(!passed)++failures;};
  window.Control("minimize");check("minimize-command",implemented && minimized);
  window.Control("toggleMaximize");check("maximize-command",implemented && maximized && value);
  window.Control("isMaximized");check("maximized-query",implemented && value);
  window.Control("toggleMaximize");check("restore-command",implemented && !maximized && !value);
  window.Control("closeWindow");check("close-posts-WM_CLOSE",implemented && posted==WM_CLOSE);
  window.Control("startDrag");check("drag-command",implemented && released && sent==WM_NCLBUTTONDOWN && sent_wparam==HTCAPTION && sent_lparam==MAKELPARAM(123,234));
  return failures?1:0;
}
'''.replace("{{CONTROLS}}", controls)
    cpp = out / "window_controls_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "window_controls_test.exe"
    result = subprocess.run(["cl", "/nologo", "/std:c++17", "/EHsc", "/utf-8", "/W4", "/WX", "/wd4100", "/DUNICODE", "/D_UNICODE", str(cpp), f"/Fo{out / 'window_controls_test.obj'}", f"/Fe{exe}"], cwd=out)
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


if __name__ == "__main__":
    sys.exit(main())
