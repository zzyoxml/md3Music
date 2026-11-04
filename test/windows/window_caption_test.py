"""VS x64 开发环境下运行，验证透明标题栏原生边框；三键由 Widget 测试验证。

python test/windows/window_caption_test.py
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
    out = (args.out or root / "tmp/window-caption-test").resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")
    start = source.index("LRESULT\nFlutterWindow::MessageHandler")
    marker = "  LRESULT dwm_result = 0;" if "DwmDefWindowProc" in source else "  if (message == WM_NCCALCSIZE"
    start = source.index(marker, start)
    frame = source[start:source.index("  if (message == WM_CLOSE)", start)]
    harness = r'''
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <iostream>
class Win32Window {
 public:
  static LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
};
class Probe : public Win32Window {
 public:
  static LRESULT CALLBACK Handle(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
{{FRAME}}
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
};
int main() {
  SetProcessDPIAware();
  WNDCLASSW cls{}; cls.lpfnWndProc=Probe::Handle; cls.hInstance=GetModuleHandleW(nullptr);
  cls.lpszClassName=L"MD3MusicCaptionRegression";
  if (!RegisterClassW(&cls)) return 3;
  HWND hwnd=CreateWindowExW(0,cls.lpszClassName,L"MD3Music caption probe",
      WS_OVERLAPPEDWINDOW,100,100,900,600,nullptr,nullptr,cls.hInstance,nullptr);
  if (!hwnd) return 4;
  SetWindowPos(hwnd,nullptr,0,0,0,0,
      SWP_FRAMECHANGED|SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);
  int failures=0;
  RECT bounds{}; GetWindowRect(hwnd,&bounds);
  POINT origin{0,0}; ClientToScreen(hwnd,&origin);
  const LONG inset=origin.y-bounds.top;
  std::cout<<"custom-caption-inset="<<inset<<" "<<(inset==0?"PASS":"FAIL")<<"\n";
  if (inset!=0) ++failures;
  const int expected[]={HTLEFT,HTRIGHT,HTTOP,HTBOTTOM,HTCLIENT};
  const POINT points[]={{bounds.left+1,bounds.top+100},{bounds.right-2,bounds.top+100},
      {bounds.left+100,bounds.top+1},{bounds.left+100,bounds.bottom-2},
      {bounds.right-30,bounds.top+16}};
  const char* names[]={"resize-left","resize-right","resize-top","resize-bottom","flutter-caption-buttons"};
  for (int i=0;i<5;++i) {
    const auto hit=SendMessageW(hwnd,WM_NCHITTEST,0,MAKELPARAM(points[i].x,points[i].y));
    const bool passed=hit==expected[i];
    std::cout<<names[i]<<": hit="<<hit<<" expected="<<expected[i]<<" "<<(passed?"PASS":"FAIL")<<"\n";
    if (!passed) ++failures;
  }
  DestroyWindow(hwnd); UnregisterClassW(cls.lpszClassName,cls.hInstance);
  return failures?1:0;
}
'''.replace("{{FRAME}}", frame)
    cpp = out / "window_caption_test.cpp"
    cpp.write_text(harness, encoding="utf-8")
    exe = out / "window_caption_test.exe"
    result = subprocess.run(["cl", "/nologo", "/std:c++17", "/EHsc", "/utf-8", "/W4", "/WX", "/wd4100", "/DUNICODE", "/D_UNICODE", str(cpp), f"/Fo{out / 'window_caption_test.obj'}", f"/Fe{exe}", "user32.lib", "dwmapi.lib"], cwd=out)
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


if __name__ == "__main__":
    sys.exit(main())
