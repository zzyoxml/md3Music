#include "desktop_toast.h"

#include <algorithm>
#include <dwmapi.h>

namespace {
constexpr wchar_t kToastClass[] = L"MD3MusicDesktopToast";
HWND toast_window = nullptr;

HFONT CreateToastFont() {
  return CreateFontW(-17, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
}

int MeasureToastHeight(const std::wstring& text, int width) {
  HDC dc = GetDC(nullptr);
  HFONT font = CreateToastFont();
  auto old_font = SelectObject(dc, font);
  RECT bounds{0, 0, std::max(1, width - 36), 0};
  DrawTextW(dc, text.c_str(), -1, &bounds,
            DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
  SelectObject(dc, old_font);
  DeleteObject(font);
  ReleaseDC(nullptr, dc);
  return std::max(52, static_cast<int>(bounds.bottom) + 24);
}

LRESULT CALLBACK ToastProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CREATE: {
      const auto* params = reinterpret_cast<CREATESTRUCTW*>(lparam);
      auto* text = new std::wstring(
          static_cast<const wchar_t*>(params->lpCreateParams));
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(text));
      return 0;
    }
    case WM_TIMER:
      DestroyWindow(hwnd);
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(hwnd, &paint);
      RECT bounds{};
      GetClientRect(hwnd, &bounds);
      HBRUSH brush = CreateSolidBrush(RGB(48, 48, 52));
      auto old_brush = SelectObject(dc, brush);
      FillRect(dc, &bounds, brush);
      SelectObject(dc, old_brush);
      DeleteObject(brush);
      HFONT font = CreateToastFont();
      auto old_font = SelectObject(dc, font);
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(255, 255, 255));
      InflateRect(&bounds, -18, -10);
      const auto* text = reinterpret_cast<std::wstring*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (text) {
        DrawTextW(dc, text->c_str(), -1, &bounds,
                  DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_NOPREFIX);
      }
      SelectObject(dc, old_font);
      DeleteObject(font);
      EndPaint(hwnd, &paint);
      return 0;
    }
    case WM_NCDESTROY:
      delete reinterpret_cast<std::wstring*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      if (toast_window == hwnd) toast_window = nullptr;
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
}  // namespace

void CloseDesktopToast() {
  if (toast_window) DestroyWindow(toast_window);
}

void ShowDesktopToast(HWND owner, const std::wstring& message, bool long_duration) {
  if (!owner || !IsWindow(owner) || !IsWindowVisible(owner) || message.empty()) return;
  CloseDesktopToast();
  static bool registered = [] {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = ToastProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kToastClass;
    return RegisterClassW(&window_class) != 0;
  }();
  if (!registered) return;

  RECT client{};
  GetClientRect(owner, &client);
  POINT bottom_left{client.left, client.bottom};
  ClientToScreen(owner, &bottom_left);
  const int client_width = client.right - client.left;
  const int width = std::min(420, std::max(180, client_width - 32));
  const int height = MeasureToastHeight(message, width);
  const int x = bottom_left.x + (client_width - width) / 2;
  const int y = bottom_left.y - height - 40;
  toast_window = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kToastClass, L"",
      WS_POPUP, x, y, width, height, owner, nullptr,
      GetModuleHandleW(nullptr), const_cast<wchar_t*>(message.c_str()));
  if (!toast_window) return;
  const DWMNCRENDERINGPOLICY no_nonclient = DWMNCRP_DISABLED;
  DwmSetWindowAttribute(toast_window, DWMWA_NCRENDERING_POLICY,
                        &no_nonclient, sizeof(no_nonclient));
  const COLORREF no_border = DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(toast_window, DWMWA_BORDER_COLOR, &no_border,
                        sizeof(no_border));
  SetWindowPos(toast_window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  HRGN region = CreateRoundRectRgn(0, 0, width, height, 28, 28);
  if (!SetWindowRgn(toast_window, region, TRUE)) DeleteObject(region);
  ShowWindow(toast_window, SW_SHOWNOACTIVATE);
  if (!SetTimer(toast_window, 1, long_duration ? 3500 : 2000, nullptr)) {
    DestroyWindow(toast_window);
  }
}
