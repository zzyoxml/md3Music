#include "window_placement.h"

#include <windows.h>

namespace {

constexpr const wchar_t kWindowKey[] = L"Software\\md3Music\\Window";
constexpr const wchar_t kValueX[] = L"X";
constexpr const wchar_t kValueY[] = L"Y";
constexpr const wchar_t kValueWidth[] = L"W";
constexpr const wchar_t kValueHeight[] = L"H";
constexpr const wchar_t kValueMaximized[] = L"Maximized";
constexpr const wchar_t kValueDpi[] = L"Dpi";

bool ReadDword(const wchar_t* name, DWORD* out) {
  DWORD value = 0;
  DWORD size = static_cast<DWORD>(sizeof(value));
  const LSTATUS status =
      RegGetValueW(HKEY_CURRENT_USER, kWindowKey, name, RRF_RT_REG_DWORD,
                   nullptr, &value, &size);
  if (status != ERROR_SUCCESS) return false;
  *out = value;
  return true;
}

bool WriteDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value),
                        static_cast<DWORD>(sizeof(value))) == ERROR_SUCCESS;
}

}  // namespace

namespace window_placement {

bool Load(Placement* out) {
  if (out == nullptr) return false;
  DWORD x = 0;
  DWORD y = 0;
  DWORD width = 0;
  DWORD height = 0;
  DWORD maximized = 0;
  DWORD dpi = 0;
  if (!ReadDword(kValueX, &x) || !ReadDword(kValueY, &y) ||
      !ReadDword(kValueWidth, &width) || !ReadDword(kValueHeight, &height) ||
      !ReadDword(kValueMaximized, &maximized) || !ReadDword(kValueDpi, &dpi)) {
    return false;
  }
  if (width == 0 || height == 0) return false;
  out->rect = {static_cast<LONG>(x), static_cast<LONG>(y),
               static_cast<LONG>(x + width), static_cast<LONG>(y + height)};
  out->maximized = maximized != 0;
  out->dpi = static_cast<int>(dpi);
  return true;
}

void Save(const Placement& placement) {
  const LONG width = placement.rect.right - placement.rect.left;
  const LONG height = placement.rect.bottom - placement.rect.top;
  if (width <= 0 || height <= 0) return;

  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  WriteDword(key, kValueX, static_cast<DWORD>(placement.rect.left));
  WriteDword(key, kValueY, static_cast<DWORD>(placement.rect.top));
  WriteDword(key, kValueWidth, static_cast<DWORD>(width));
  WriteDword(key, kValueHeight, static_cast<DWORD>(height));
  WriteDword(key, kValueMaximized, placement.maximized ? 1u : 0u);
  WriteDword(key, kValueDpi, static_cast<DWORD>(placement.dpi));
  RegCloseKey(key);
}

}  // namespace window_placement
