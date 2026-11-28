// 内嵌字体统一入口（便携包 data/fonts/MD3MusicSans.ttf）。
//
// Windows 原生 GDI 渲染面（桌面歌词悬浮窗、系统通知）与 Flutter 侧共用
// 同一份内嵌字体，保证全局字形一致。字体为 Noto Sans SC 的子集化 Medium
// （SIL OFL 1.1 可商用，族名按 OFL 条件 3 自定义为 MD3MusicSans）。
#pragma once

#include <windows.h>

#include <string>

namespace md3_bundled_font {

/// 字体族名（与 .ttf 内部 nameID 1、FontLoader 注册名一致）。
constexpr wchar_t kFamily[] = L"MD3MusicSans";

/// 相对 exe 目录的字体文件路径：\data\fonts\MD3MusicSans.ttf。
constexpr wchar_t kRelativePath[] = L"\\data\\fonts\\MD3MusicSans.ttf";

/// 把字体加载进当前进程（FR_PRIVATE，仅本进程可见；幂等）。
///
/// 在每个原生窗口第一次绘制前调用一次即可。失败（无 exe 目录 / 文件缺失）
/// 时静默：CreateFontW 会按族名找不到字体并回落到系统默认，不影响可用性。
inline void EnsureLoaded() {
  static bool loaded = false;
  if (loaded) return;
  loaded = true;
  wchar_t exe_path[MAX_PATH]{};
  const DWORD n = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return;
  std::wstring font_path(exe_path);
  const size_t slash = font_path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) font_path.resize(slash);
  font_path += kRelativePath;
  AddFontResourceExW(font_path.c_str(), FR_PRIVATE, nullptr);
}

}  // namespace md3_bundled_font