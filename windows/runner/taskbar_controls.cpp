#include "taskbar_controls.h"

#include <windows.h>

#include <cstdio>

#include "resource.h"

namespace {

// 任务栏按钮创建完成的通知（**注册消息**，不是 WM_* 常量）。
// 首次创建窗口时它往往晚于 OnCreate 到达，靠它兜底补加缩略图按钮。
const UINT kTaskbarButtonCreatedMessage =
    RegisterWindowMessageW(L"TaskbarButtonCreated");

// 注册表：**任务栏**是否使用浅色主题。
//
// 必须是 SystemUsesLightTheme 而不是 AppsUseLightTheme：
// 任务栏跟随的是「Windows 模式」（系统主题），而 AppsUseLightTheme 是
// 「应用模式」。两者可以不同 —— 本机实测 AppsUseLightTheme=1、
// SystemUsesLightTheme=0（应用浅色 + 系统深色），任务栏是深色的。
// 用错这一个键的表现就是「深色任务栏上画了深色图标」，几乎看不见。
//
// 注意 win32_window.cpp 用的是 AppsUseLightTheme：那是给窗口标题栏用的，
// 标题栏跟随应用模式，口径不同、不能互换。
constexpr const wchar_t kThemeKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kThemeValue[] = L"SystemUsesLightTheme";

// 缩略图按钮 id（THUMBBUTTON.iId），也是 THBN_CLICKED 的 LOWORD。
constexpr UINT kButtonPrevious = 1;
constexpr UINT kButtonPlayPause = 2;
constexpr UINT kButtonNext = 3;

// 图标缓存下标（与 icons_ 一一对应）。
constexpr int kIconPrevious = 0;
constexpr int kIconPlay = 1;
constexpr int kIconPause = 2;
constexpr int kIconNext = 3;

// 真机取证用：只记状态与返回值，不落任何用户数据（与 [WindowsFullscreen] 同口径）。
void Log4(const wchar_t* format, int a, int b, unsigned c, unsigned d) {
  wchar_t buffer[192] = {};
  swprintf_s(buffer, format, a, b, c, d);
  OutputDebugStringW(buffer);
}

void Log2(const wchar_t* format, int a, int b) {
  wchar_t buffer[160] = {};
  swprintf_s(buffer, format, a, b);
  OutputDebugStringW(buffer);
}

bool ReadLightTheme() {
  DWORD light_mode = 0;
  DWORD size = sizeof(light_mode);
  const LSTATUS result =
      RegGetValueW(HKEY_CURRENT_USER, kThemeKey, kThemeValue, RRF_RT_REG_DWORD,
                   nullptr, &light_mode, &size);
  // 读不到按深色主题处理（绝大多数音乐播放器场景是深色任务栏）。
  return result == ERROR_SUCCESS && light_mode != 0;
}

}  // namespace

TaskbarControls::~TaskbarControls() { Shutdown(); }

bool TaskbarControls::Initialize(HWND hwnd, ActionCallback on_action) {
  if (initialized_) return true;
  if (hwnd == nullptr) return false;
  hwnd_ = hwnd;
  on_action_ = std::move(on_action);

  HRESULT hr = ::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list_));
  if (FAILED(hr) || list_ == nullptr) {
    list_ = nullptr;
    OutputDebugStringW(L"[Taskbar] init failed: CoCreateInstance\n");
    return false;
  }
  hr = list_->HrInit();
  if (FAILED(hr)) {
    OutputDebugStringW(L"[Taskbar] init failed: HrInit\n");
    list_->Release();
    list_ = nullptr;
    return false;
  }

  initialized_ = true;
  light_theme_ = ReadLightTheme();
  LoadIcons();
  // **不要**在这里加缩略图按钮。
  //
  // 任务栏按钮由 Explorer 在窗口首次显示时才创建，OnCreate 阶段它还不存在。
  // 此时 ThumbBarAddButtons 会**返回 S_OK 但按钮被 Explorer 丢弃** ——
  // 实测日志打出 `buttons=3 added`，悬停任务栏却什么按钮都没有。S_OK 骗人
  // 这条路径是本功能唯一的坑，所以统一等 kTaskbarButtonCreatedMessage 再加。
  return true;
}

void TaskbarControls::Shutdown() {
  initialized_ = false;
  buttons_added_ = false;
  has_last_progress_ = false;
  if (list_ != nullptr) {
    // 缩略图按钮没有「移除」API：它们随窗口销毁一起消失，这里只释放 COM。
    list_->Release();
    list_ = nullptr;
  }
  ReleaseIcons();
  hwnd_ = nullptr;
  on_action_ = nullptr;
}

bool TaskbarControls::LoadIcons() {
  ReleaseIcons();
  // 深色任务栏配浅色字形，浅色任务栏配深色字形；两套资源各 4 枚。
  const int base = light_theme_ ? IDI_TASKBAR_PREV_LIGHT : IDI_TASKBAR_PREV;
  const int cx = GetSystemMetrics(SM_CXSMICON);
  const int cy = GetSystemMetrics(SM_CYSMICON);
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  bool ok = true;
  for (int i = 0; i < 4; ++i) {
    icons_[i] = static_cast<HICON>(LoadImageW(
        instance, MAKEINTRESOURCEW(base + i), IMAGE_ICON, cx, cy,
        LR_DEFAULTCOLOR));
    if (icons_[i] == nullptr) ok = false;
  }
  icons_loaded_ = ok;
  if (!ok) {
    OutputDebugStringW(L"[Taskbar] icon load failed\n");
    ReleaseIcons();
  }
  return ok;
}

void TaskbarControls::ReleaseIcons() {
  for (HICON& icon : icons_) {
    if (icon != nullptr) {
      DestroyIcon(icon);
      icon = nullptr;
    }
  }
  icons_loaded_ = false;
}

void TaskbarControls::RefreshTheme() {
  const bool light = ReadLightTheme();
  if (light == light_theme_ && icons_loaded_) return;
  light_theme_ = light;
  if (!LoadIcons()) return;
  // 图标换了要整排重加：ThumbBarUpdateButtons 虽然也能换图标，但重加更省事
  // 且这条路只在系统主题切换时走一次。
  buttons_added_ = false;
  EnsureButtons();
}

void TaskbarControls::EnsureButtons() {
  if (!initialized_ || list_ == nullptr || hwnd_ == nullptr) return;
  if (buttons_added_) return;
  if (!icons_loaded_) return;

  THUMBBUTTON buttons[3] = {};
  const UINT ids[3] = {kButtonPrevious, kButtonPlayPause, kButtonNext};
  const HICON glyphs[3] = {
      icons_[kIconPrevious],
      is_playing_ ? icons_[kIconPause] : icons_[kIconPlay],
      icons_[kIconNext],
  };
  const wchar_t* tips[3] = {
      L"上一首",
      is_playing_ ? L"暂停" : L"播放",
      L"下一首",
  };
  for (int i = 0; i < 3; ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    buttons[i].hIcon = glyphs[i];
    buttons[i].dwFlags = THBF_ENABLED;
    wcscpy_s(buttons[i].szTip, tips[i]);
  }

  const HRESULT hr = list_->ThumbBarAddButtons(hwnd_, 3, buttons);
  // 记录 HRESULT：按钮没出现时，靠这一行区分「调用失败」（时机/图标问题）
  // 与「调用成功但 Shell 没画」（系统设置/预览关闭）。没有它只能猜。
  wchar_t line[128] = {};
  swprintf_s(line, L"[Taskbar] ThumbBarAddButtons hr=0x%08X\n",
             static_cast<unsigned>(hr));
  OutputDebugStringW(line);
  if (FAILED(hr)) {
    // 任务栏按钮尚未就绪（首次创建窗口时几乎必然发生），等
    // kTaskbarButtonCreatedMessage 再试；不当作错误上报。
    return;
  }
  buttons_added_ = true;
  OutputDebugStringW(L"[Taskbar] buttons=3 added\n");
}

void TaskbarControls::UpdatePlayPauseButton() {
  if (!initialized_ || list_ == nullptr || hwnd_ == nullptr) return;
  if (!buttons_added_ || !icons_loaded_) return;

  THUMBBUTTON button = {};
  button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
  button.iId = kButtonPlayPause;
  button.hIcon = is_playing_ ? icons_[kIconPause] : icons_[kIconPlay];
  button.dwFlags = THBF_ENABLED;
  wcscpy_s(button.szTip, is_playing_ ? L"暂停" : L"播放");
  list_->ThumbBarUpdateButtons(hwnd_, 1, &button);
}

void TaskbarControls::SetState(int64_t position_ms, int64_t duration_ms,
                               bool is_playing, bool visible) {
  if (!initialized_ || list_ == nullptr || hwnd_ == nullptr) return;

  // 播放态翻转只换那一枚图标（整排重加会让按钮闪一下）。
  if (is_playing != is_playing_) {
    is_playing_ = is_playing;
    UpdatePlayPauseButton();
  }

  const TaskbarProgress next =
      ResolveTaskbarProgress(position_ms, duration_ms, is_playing, visible);
  if (has_last_progress_ && next.state == last_progress_.state &&
      next.completed == last_progress_.completed &&
      next.total == last_progress_.total) {
    return;
  }
  last_progress_ = next;
  has_last_progress_ = true;
  ApplyProgress(next);
}

void TaskbarControls::ApplyProgress(const TaskbarProgress& progress) {
  if (!initialized_ || list_ == nullptr || hwnd_ == nullptr) return;
  // 记录 HRESULT：只打「我调了」证明不了「Shell 收下了」。两者都失败时任务栏
  // 上什么都不会出现，而日志看起来一切正常 —— 这个 bug 已经踩过一次。
  const HRESULT state_hr = list_->SetProgressState(hwnd_, progress.state);
  HRESULT value_hr = S_FALSE;
  if (progress.state != TBPF_NOPROGRESS) {
    value_hr = list_->SetProgressValue(hwnd_, progress.completed, progress.total);
  }
  Log4(L"[Taskbar] state=%d completed=%d state_hr=0x%08X value_hr=0x%08X\n",
       static_cast<int>(progress.state),
       static_cast<int>(progress.completed), static_cast<unsigned>(state_hr),
       static_cast<unsigned>(value_hr));
}

void TaskbarControls::ReplayProgress() {
  // 只在真有历史快照时重放：没播放过就别给 Shell 写一条空进度。
  if (!has_last_progress_) return;
  ApplyProgress(last_progress_);
}

void TaskbarControls::OnTaskbarCreated() {
  // Explorer 重启：旧的 ITaskbarList3 与已添加的按钮全部失效，必须重建。
  if (!initialized_) return;
  buttons_added_ = false;
  if (list_ != nullptr) {
    list_->Release();
    list_ = nullptr;
  }
  HRESULT hr = ::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list_));
  if (FAILED(hr) || list_ == nullptr) {
    list_ = nullptr;
    OutputDebugStringW(L"[Taskbar] reinit failed after TaskbarCreated\n");
    return;
  }
  hr = list_->HrInit();
  if (FAILED(hr)) {
    list_->Release();
    list_ = nullptr;
    OutputDebugStringW(L"[Taskbar] reinit failed: HrInit\n");
    return;
  }
  EnsureButtons();
  // 保留 last_progress_ 并重放：暂停时 Dart 侧没有新位置可推，不补这一下
  // 进度条会一直空着，直到用户手动播放/切歌才恢复。
  ReplayProgress();
  // 新的 Explorer 通常还会再发一条 TaskbarButtonCreated；上面这次 EnsureButtons
  // 若已成功，那条消息会因 buttons_added_ 为真而跳过，不会重复加按钮。
}

bool TaskbarControls::HandleWindowMessage(UINT message, WPARAM wparam,
                                          LPARAM lparam) {
  (void)lparam;
  if (!initialized_) return false;

  if (kTaskbarButtonCreatedMessage != 0 &&
      message == kTaskbarButtonCreatedMessage) {
    // 任务栏按钮就绪：**这是唯一能可靠添加缩略图按钮的时机**。
    // 首次显示窗口与 Explorer 重启后各来一条。
    //
    // 仅在尚未添加时动手：Explorer 重启路径里 OnTaskbarCreated 可能已经加过，
    // 无条件重加会让同一批按钮被加两遍（按钮顺序错乱）。
    OutputDebugStringW(L"[Taskbar] TaskbarButtonCreated received\n");
    if (!buttons_added_) {
      EnsureButtons();
    }
    // 窗口首次显示时 Dart 可能已经推过一拍（那时按钮还没就绪，进度写不进
    // 任务栏），这里把最近一次进度补上。
    ReplayProgress();
    return true;
  }

  if (message == WM_COMMAND) {
    if (HIWORD(wparam) != THBN_CLICKED) return false;
    if (!on_action_) return true;
    switch (LOWORD(wparam)) {
      case kButtonPrevious:
        OutputDebugStringW(L"[Taskbar] click=previous\n");
        on_action_("previous");
        return true;
      case kButtonPlayPause:
        OutputDebugStringW(L"[Taskbar] click=togglePlayPause\n");
        on_action_("togglePlayPause");
        return true;
      case kButtonNext:
        OutputDebugStringW(L"[Taskbar] click=next\n");
        on_action_("next");
        return true;
      default:
        return false;
    }
  }

  if (message == WM_SETTINGCHANGE || message == WM_SYSCOLORCHANGE) {
    // 系统主题切换后任务栏底色变了，图标要换字形变体。
    RefreshTheme();
    // 不消费：Flutter / 基类还要按同一条消息刷新自己的主题。
    return false;
  }

  return false;
}
