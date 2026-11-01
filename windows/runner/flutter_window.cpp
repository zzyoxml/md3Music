#include "flutter_window.h"

#include <memory>
#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_toast.h"
#include "resource.h"

namespace {
// 保留 Flutter 自绘标题栏，由 DWM 合成原生圆角和窗口边缘。
void ApplyWindowFrame(HWND hwnd, bool fullscreen) {
  const DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
  DwmSetWindowAttribute(hwnd, DWMWA_NCRENDERING_POLICY, &policy, sizeof(policy));
  const DWM_WINDOW_CORNER_PREFERENCE corners =
      fullscreen ? DWMWCP_DONOTROUND : DWMWCP_ROUND;
  // Windows 10 不支持该属性，失败时保留原有外观。
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                       &corners, sizeof(corners));
  const int edge = fullscreen ? 0 : 1;
  const MARGINS margins{edge, edge, edge, edge};
  DwmExtendFrameIntoClientArea(hwnd, &margins);
}

using Arguments = flutter::EncodableMap;
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayMenuShow = 1;
constexpr UINT kTrayMenuExit = 2;
const UINT kTaskbarCreatedMessage = RegisterWindowMessageW(L"TaskbarCreated");

std::string StringArg(const Arguments* args, const char* key) {
  if (!args) return {};
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string{};
}

int IntArg(const Arguments* args, const char* key, int fallback) {
  if (!args) return fallback;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return static_cast<int>(*value);
  if (const auto* value = std::get_if<double>(&it->second)) return static_cast<int>(*value);
  return fallback;
}

bool BoolArg(const Arguments* args, const char* key, bool fallback) {
  if (!args) return fallback;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  const auto* value = std::get_if<bool>(&it->second);
  return value ? *value : fallback;
}

std::wstring Wide(const std::string& text);

std::vector<FloatingLyricWord> WordsArg(const Arguments* args) {
  std::vector<FloatingLyricWord> words;
  if (!args) return words;
  const auto it = args->find(flutter::EncodableValue("words"));
  if (it == args->end()) return words;
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (!list) return words;
  for (const auto& item : *list) {
    const auto* map = std::get_if<flutter::EncodableMap>(&item);
    if (!map) continue;
    const auto text = map->find(flutter::EncodableValue("t"));
    if (text == map->end()) continue;
    const auto* value = std::get_if<std::string>(&text->second);
    if (!value) continue;
    auto number = [&](const char* key) {
      const auto field = map->find(flutter::EncodableValue(key));
      if (field == map->end()) return 0;
      if (const auto* n = std::get_if<int32_t>(&field->second)) return *n;
      if (const auto* n = std::get_if<int64_t>(&field->second)) return static_cast<int>(*n);
      if (const auto* n = std::get_if<double>(&field->second)) return static_cast<int>(*n);
      return 0;
    };
    words.push_back({Wide(*value), number("s"), number("d")});
  }
  return words;
}

/// 取浮点参数。Dart 侧 fontSize / displayScale 是 double，
/// StandardMethodCodec 会编码成 EncodableValue(double)，必须走这个函数；
/// 误用 IntArg 取不到值会静默退回默认值（表现为「改了字号没反应」）。
double DoubleArg(const Arguments* args, const char* key, double fallback) {
  if (!args) return fallback;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

/// 颜色参数统一按 int32 取出后转成 ARGB（0xAARRGGBB）。
std::uint32_t ColorArg(const Arguments* args, const char* key,
                       std::uint32_t fallback) {
  return static_cast<std::uint32_t>(IntArg(args, key, static_cast<int>(fallback)));
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), length);
  return result;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::EnsureTrayIcon() {
  NOTIFYICONDATAW tray_icon{};
  tray_icon.cbSize = sizeof(tray_icon);
  tray_icon.hWnd = GetHandle();
  tray_icon.uID = 1;
  tray_icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon.uCallbackMessage = kTrayCallbackMessage;
  tray_icon.hIcon = LoadIconW(GetModuleHandleW(nullptr),
                              MAKEINTRESOURCEW(IDI_APP_ICON));
  if (!tray_icon.hIcon) {
    tray_icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  }
  wcscpy_s(tray_icon.szTip, L"MD3Music");
  // 启动时成功不代表现在仍存在（Explorer 重启会移除图标）。
  // 先更新确认，丢失时重新添加；失败就不能继续按「已入托盘」隐藏窗口。
  tray_icon_added_ = tray_icon.hIcon &&
                    (Shell_NotifyIconW(NIM_MODIFY, &tray_icon) == TRUE ||
                     Shell_NotifyIconW(NIM_ADD, &tray_icon) == TRUE);
  return tray_icon_added_;
}

void FlutterWindow::SetFullscreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (!hwnd || fullscreen == fullscreen_) return;

  if (fullscreen) {
    // 先留快照：退出时要回到「用户原来那个形态」，而不是一律还原成普通窗口
    // （用户可能本来就是最大化 / 手动拖到某个位置）。
    fullscreen_restore_placement_.length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(hwnd, &fullscreen_restore_placement_)) {
      fullscreen_restore_placement_ = {sizeof(WINDOWPLACEMENT)};
    }
    fullscreen_restore_style_ = GetWindowLongPtrW(hwnd, GWL_STYLE);
    // 从最大化进入时必须先退出最大化状态。留着 WS_MAXIMIZE 的话，Windows 仍把
    // 窗口当「最大化窗口」：顶层窗口被 SetWindowPos 摆到 rcMonitor 是 1920×1080，
    // 但 Flutter 的子窗口 FLUTTERVIEW 会被按 rcWork 定成 1920×1020，两者脱节 →
    // 底部 60px 没有内容，任务栏（topmost）正好画在那条空带上，还挡住命中测试
    // （表现为「进了全屏但底部留着状态栏、任务栏点不动、Win 键唤不出开始菜单」）。
    // 快照已在上方取到，这里退出最大化不会丢失「退出全屏后回到最大化」的依据。
    if (IsZoomed(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    }
    // 去掉标题栏与可缩放边框：WS_THICKFRAME 留着的话屏幕边缘那一圈像素会
    // 继续被算成缩放热区（见 MessageHandler 的 WM_NCHITTEST 守卫）。
    // WS_MAXIMIZE 一并清掉：SW_RESTORE 已把窗口还原成普通矩形，样式里若还留着
    // 这一位，窗口会立刻被当成「再次最大化」。
    const LONG_PTR borderless = fullscreen_restore_style_ &
        ~static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                               WS_MAXIMIZEBOX | WS_SYSMENU | WS_MAXIMIZE);
    SetWindowLongPtrW(hwnd, GWL_STYLE, borderless);
    // 标志必须在 SetWindowPos 之前置真：SWP_FRAMECHANGED 会同步触发
    // WM_NCCALCSIZE，那里按 fullscreen_ 决定客户区取 rcMonitor 还是 rcWork。
    // 放在 if 之外：样式已改，即使取显示器信息失败也要让退出路径能还原。
    fullscreen_ = true;
    ApplyWindowFrame(hwnd, fullscreen_);
    MONITORINFO monitor{sizeof(monitor)};
    if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      // rcMonitor 而非 rcWork：铺满整块显示器，任务栏一并覆盖。
      SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left,
                   monitor.rcMonitor.top,
                   monitor.rcMonitor.right - monitor.rcMonitor.left,
                   monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
    }
  } else {
    if (fullscreen_restore_style_ != 0) {
      SetWindowLongPtrW(hwnd, GWL_STYLE, fullscreen_restore_style_);
    }
    fullscreen_ = false;
    ApplyWindowFrame(hwnd, fullscreen_);
    if (fullscreen_restore_placement_.length == sizeof(WINDOWPLACEMENT)) {
      // 先 SW_RESTORE 再套快照：对「已处于 zoomed」的窗口，SetWindowPlacement
      // 不会重跑最大化布局，窗口会停在全屏矩形 (0,0,rcMonitor) 而不是快照里的
      // 最大化形态（实测：窗口盖住任务栏、客户区仍按 rcWork 裁）。
      // 两步在同一个消息循环内完成，用户看不到中间态。
      ShowWindow(hwnd, SW_RESTORE);
      // 恢复形态/位置；SetWindowPlacement 会把最大化态一并还原。
      SetWindowPlacement(hwnd, &fullscreen_restore_placement_);
    }
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
    fullscreen_restore_style_ = 0;
    fullscreen_restore_placement_ = {sizeof(WINDOWPLACEMENT)};
  }
  // 真机取证用：只记状态，不落任何用户数据。
  OutputDebugStringW(fullscreen ? L"[WindowsFullscreen] value=true\n"
                                : L"[WindowsFullscreen] value=false\n");
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "md3music/window_tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = call.arguments()
                               ? std::get_if<Arguments>(call.arguments())
                               : nullptr;
        if (call.method_name() == "finishExit") {
          SetQuitOnClose(true);
          result->Success(flutter::EncodableValue(true));
          Destroy();
          return;
        }
        const auto& method = call.method_name();
        if (method == "minimize") {
          ShowWindow(GetHandle(), SW_MINIMIZE);
        } else if (method == "toggleMaximize") {
          // 无边框全屏下没有「最大化」可言：这个按钮此时语义是「退出全屏」，
          // 直接退出而不是在无标题栏状态下再叠一次 SW_MAXIMIZE。
          if (fullscreen_) {
            SetFullscreen(false);
          } else {
            ShowWindow(GetHandle(),
                       IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
          }
        } else if (method == "setFullscreen") {
          SetFullscreen(BoolArg(args, "value", false));
          result->Success(flutter::EncodableValue(fullscreen_));
          return;
        } else if (method == "toggleFullscreen") {
          SetFullscreen(!fullscreen_);
          result->Success(flutter::EncodableValue(fullscreen_));
          return;
        } else if (method == "isFullscreen") {
          result->Success(flutter::EncodableValue(fullscreen_));
          return;
        } else if (method == "closeWindow") {
          // 复用 WM_CLOSE：托盘可用时隐藏，不绕过既有退出/托盘逻辑。
          PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
        } else if (method == "startDrag") {
          // 全屏下没有可拖的标题栏；此时发 HTCAPTION 会让窗口离开全屏矩形。
          if (!fullscreen_) {
            POINT cursor{};
            GetCursorPos(&cursor);
            ReleaseCapture();
            SendMessageW(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION,
                         MAKELPARAM(cursor.x, cursor.y));
          }
        } else if (method == "setTaskbarState") {
          // 任务栏进度条 + 缩略图按钮播放态。Dart 侧已做 1s 节流，原生侧
          // 再按 (状态, 进度值) 去重：Shell 每次 SetProgressValue 都会重绘
          // 任务栏，重复下发没有意义。
          taskbar_controls_.SetState(
              static_cast<int64_t>(IntArg(args, "position", 0)),
              static_cast<int64_t>(IntArg(args, "duration", 0)),
              BoolArg(args, "isPlaying", false),
              BoolArg(args, "visible", false));
          result->Success(flutter::EncodableValue(true));
          return;
        } else if (method != "isMaximized") {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE));
      });
  EnsureTrayIcon();
  // 悬浮窗内嵌设置面板的改动回传 Dart 侧落盘，语义对齐 Android 的
  // createSettingsPanel()（两端共用同一份 SharedPreferences，改一处两端同步）。
  //
  // 用**单键 config map** 而不是 (key, value) 二元组：Dart 侧已有现成的
  // desktopLyricConfigChanged 分派（_onNativeConfigChanged），它按 map 里的
  // 字段名逐项落盘。发成 map 才能直接复用，不必在 Dart 侧另写一套分派。
  floating_lyric_.SetConfigCallback(
      [](void* user_data, const char* key, int value) {
        auto* self = static_cast<FlutterWindow*>(user_data);
        if (!self || self->lyric_channel_ == nullptr) return;
        flutter::EncodableMap config;
        const std::string name(key);
        // bool 字段必须以 bool 下发：Dart 侧 `_onNativeConfigChanged` 读的是
        // `config['doubleLine'] as bool?`，传 int 会被静默丢弃。
        if (name == "fontSize") {
          config[flutter::EncodableValue("fontSize")] =
              flutter::EncodableValue(static_cast<double>(value));
        } else if (name == "opacity") {
          config[flutter::EncodableValue("opacity")] =
              flutter::EncodableValue(value);
        } else if (name == "doubleLine") {
          config[flutter::EncodableValue("doubleLine")] =
              flutter::EncodableValue(value != 0);
        } else if (name == "locked") {
          config[flutter::EncodableValue("locked")] =
              flutter::EncodableValue(value != 0);
        } else if (name == "preset") {
          // 预设下标：附带起止色，让 Dart 侧无需自己查表即可落盘
          // （与 Android 的 selectPreset() 行为一致）。
          const struct {
            std::uint32_t start;
            std::uint32_t end;
          } kPresets[] = {{0xFF00E5FF, 0xFFFF00FF},
                           {0xFFFF4081, 0xFFFFC400},
                           {0xFF00E676, 0xFF00B0FF},
                           {0xFFFFFFFF, 0xFFFFFFFF}};
          const int index = (value >= 0 && value < 4) ? value : 0;
          config[flutter::EncodableValue("gradientStart")] =
              flutter::EncodableValue(static_cast<int64_t>(kPresets[index].start));
          config[flutter::EncodableValue("gradientEnd")] =
              flutter::EncodableValue(static_cast<int64_t>(kPresets[index].end));
          config[flutter::EncodableValue("activePreset")] =
              flutter::EncodableValue(index);
          config[flutter::EncodableValue("colorMode")] =
              flutter::EncodableValue(0);
          config[flutter::EncodableValue("unplayedColor")] =
              flutter::EncodableValue(static_cast<int64_t>(0xFFFFFFFF));
        } else {
          return;
        }
        // InvokeMethod 收的是 unique_ptr<EncodableValue>，不是值 ——
        // 直接传 flutter::EncodableValue(config) 会编译不过（C2664）。
        self->lyric_channel_->InvokeMethod(
            "desktopLyricConfigChanged",
            std::make_unique<flutter::EncodableValue>(config));
      },
      this);
  lyric_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.md3music.md3music/floating_lyric",
      &flutter::StandardMethodCodec::GetInstance());
  lyric_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = call.arguments()
                               ? std::get_if<Arguments>(call.arguments())
                               : nullptr;
        const std::string& method = call.method_name();
        if (method == "hasOverlayPermission") {
          result->Success(flutter::EncodableValue(true));
        } else if (method == "startFloatingLyric") {
          result->Success(flutter::EncodableValue(floating_lyric_.Start(
              GetHandle(), Wide(StringArg(args, "lyric")),
              Wide(StringArg(args, "title")))));
        } else if (method == "stopFloatingLyric") {
          floating_lyric_.Stop();
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateLyric") {
          floating_lyric_.UpdateLyric(Wide(StringArg(args, "lyric")),
                                      Wide(StringArg(args, "nextLyric")),
                                      WordsArg(args), IntArg(args, "positionMs", 0));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateTitle") {
          floating_lyric_.UpdateTitle(Wide(StringArg(args, "title")));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "setDesktopLyricConfig") {
          // Dart 侧下发 13 个字段，这里必须**全部**取到。只读其中几个会让
          // 「改了配色/字号/不透明度没反应」——因为其余字段全走 fallback 默认值。
          floating_lyric_.SetConfig(
              DoubleArg(args, "fontSize", 40.0),
              DoubleArg(args, "displayScale", 1.0),
              BoolArg(args, "doubleLine", true), IntArg(args, "opacity", 50),
              BoolArg(args, "locked", false),
              ColorArg(args, "gradientStart", 0xFF00E5FF),
              ColorArg(args, "gradientEnd", 0xFFFF00FF),
              ColorArg(args, "unplayedColor", 0xFFFFFFFF),
              IntArg(args, "colorMode", 0),
              ColorArg(args, "customStart", 0xFF00E5FF),
              ColorArg(args, "customEnd", 0xFFFF00FF),
              ColorArg(args, "customUnplayed", 0xFFFFFFFF),
              BoolArg(args, "allowHorizontalMove", true));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateProgress") {
          floating_lyric_.UpdateProgress(IntArg(args, "position", 0));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "setPlaying") {
          floating_lyric_.UpdatePlaying(BoolArg(args, "isPlaying", false));
          result->Success(flutter::EncodableValue(true));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateBluetoothLyric" ||
                   method == "setBluetoothLyricEnabled" ||
                   method == "updateLyricInfo") {
          // Windows 无蓝牙歌词 / LyricInfo 能力，吞掉即可，不要抛
          // NotImplemented 让 Dart 侧反复走异常分支。
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateNotification") {
          // Android 的 updateNotification 在 Windows 上映射到 SMTC
          // （媒体浮层/锁屏/媒体键）。Dart 侧已有完整的元数据/进度/播放态
          // 上报链路，这里直接消费，无需改 Dart。
          media_controls_.UpdateMetadata(
              StringArg(args, "title"), StringArg(args, "artist"),
              StringArg(args, "artUrl"), IntArg(args, "position", 0),
              IntArg(args, "duration", 0), BoolArg(args, "isPlaying", false),
              StringArg(args, "loopMode"), BoolArg(args, "shuffleEnabled", false));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "hideNotification") {
          media_controls_.SetPlaybackStatus(false);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  // 把播放元数据/状态发布到 Windows SMTC，并把媒体键/浮层按钮回传 Dart
  // （复用 lyric_channel_ 上的 previous/next/togglePlayPause/seekTo 方法）。
  media_controls_.Initialize(
      GetHandle(),
      [this](const std::string& action, int64_t position_ms,
             const std::string& arg) {
        if (!lyric_channel_) return;
        if (action == "seekTo") {
          lyric_channel_->InvokeMethod(
              "seekTo",
              std::make_unique<flutter::EncodableValue>(position_ms));
        } else if (action == "setLoopMode") {
          lyric_channel_->InvokeMethod(
              "setLoopMode", std::make_unique<flutter::EncodableValue>(arg));
        } else {
          lyric_channel_->InvokeMethod(
              action, std::make_unique<flutter::EncodableValue>());
        }
      });
  // 任务栏缩略图工具栏的三个按钮复用**同一组 Dart 回调**（previous /
  // next / togglePlayPause 都已在 MediaNotificationService.initCallbacks 里
  // 接到 PlayerProvider），因此这里只需转发方法名，Dart 侧零改动。
  taskbar_controls_.Initialize(GetHandle(),
                              [this](const std::string& action) {
                                if (!lyric_channel_) return;
                                lyric_channel_->InvokeMethod(
                                    action,
                                    std::make_unique<flutter::EncodableValue>());
                              });
  message_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "md3music/desktop_message",
          &flutter::StandardMethodCodec::GetInstance());
  message_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        // fluttertoast 在 Windows 无实现；用非模态短暂提示代替阻塞消息框。
        const auto* args = call.arguments()
                               ? std::get_if<Arguments>(call.arguments())
                               : nullptr;
        if (call.method_name() == "show") {
          const std::wstring message = Wide(StringArg(args, "message"));
          ShowDesktopToast(GetHandle(), message, BoolArg(args, "long", false));
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });
  // 音乐频谱：Windows 端用 WASAPI 环回采集真实输出（进程环回优先，设备环回
  // 兜底），复用 Android 的通道名与 onFft 协议（40 段归一化幅值），
  // Dart 侧 SpectrumService 只按能力分支，不区分具体平台实现。
  spectrum_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.md3music.md3music/spectrum",
          &flutter::StandardMethodCodec::GetInstance());
  spectrum_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "start") {
          // Dart 侧参数（audioSessionId / visualizerFallback）只服务于
          // Android 的 Visualizer 兜底，这里忽略。
          result->Success(flutter::EncodableValue(spectrum_capture_.Start()));
          return;
        }
        if (method == "stop") {
          spectrum_capture_.Stop();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "stats") {
          const SpectrumCapture::Stats stats = spectrum_capture_.GetStats();
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("running")] =
              flutter::EncodableValue(stats.running);
          payload[flutter::EncodableValue("mode")] =
              flutter::EncodableValue(stats.mode);
          payload[flutter::EncodableValue("frames")] =
              flutter::EncodableValue(stats.frames);
          payload[flutter::EncodableValue("sampleRate")] = flutter::EncodableValue(
              static_cast<int32_t>(stats.sample_rate_hz));
          result->Success(flutter::EncodableValue(payload));
          return;
        }
        result->NotImplemented();
      });
  // 采集线程不直接发平台通道消息（`flutter_messenger.h` 要求非平台线程的
  // 调用自己加锁，而 MethodChannel 封装没有暴露锁）；也不用
  // `FlutterEngine::PostPlatformThreadTask`——本引擎版本实测在平台线程执行
  // 投递任务时会读到已释放的 std::function（APPCRASH 0xC0000005，栈落在
  // `std::_Func_class<void>::operator()`）。改用最朴素的 Win32 做法：
  // 采集线程只把最新一帧存进信箱 + PostMessage，由 MessageHandler 在平台
  // 线程上补发 onFft。UI 只关心最新帧，旧帧覆盖丢弃即可。
  spectrum_capture_.SetFrameCallback(
      [this](const std::vector<double>& bands) {
        {
          std::lock_guard<std::mutex> lock(spectrum_frame_mutex_);
          spectrum_pending_bands_ = bands;
          spectrum_frame_pending_ = true;
        }
        PostMessageW(GetHandle(), kSpectrumFrameMessage, 0, 0);
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ApplyWindowFrame(GetHandle(), fullscreen_);
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  CloseDesktopToast();
  if (tray_icon_added_) {
    NOTIFYICONDATAW tray_icon{};
    tray_icon.cbSize = sizeof(tray_icon);
    tray_icon.hWnd = GetHandle();
    tray_icon.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &tray_icon);
    tray_icon_added_ = false;
  }
  media_controls_.Shutdown();
  taskbar_controls_.Shutdown();
  floating_lyric_.Stop();
  // 先停采集线程（join）：之后不会再有新的帧写入信箱 / PostMessage。
  // 已排队的 WM_APP 频谱消息会随窗口销毁被丢弃，帧数据是成员变量，无泄漏。
  spectrum_capture_.Stop();
  {
    std::lock_guard<std::mutex> lock(spectrum_frame_mutex_);
    spectrum_frame_pending_ = false;
    spectrum_pending_bands_.clear();
  }
  spectrum_channel_.reset();
  lyric_channel_.reset();
  message_channel_.reset();
  tray_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleSpectrumFrame() {
  std::vector<double> bands;
  {
    std::lock_guard<std::mutex> lock(spectrum_frame_mutex_);
    if (!spectrum_frame_pending_) return;
    spectrum_frame_pending_ = false;
    bands.swap(spectrum_pending_bands_);
  }
  if (!spectrum_channel_) return;
  flutter::EncodableList payload;
  payload.reserve(bands.size());
  for (const double value : bands) {
    payload.emplace_back(flutter::EncodableValue(value));
  }
  spectrum_channel_->InvokeMethod(
      "onFft", std::make_unique<flutter::EncodableValue>(payload));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kSpectrumFrameMessage) {
    HandleSpectrumFrame();
    return 0;
  }
  if (kTaskbarCreatedMessage != 0 && message == kTaskbarCreatedMessage) {
    tray_icon_added_ = false;
    // Explorer 重启后旧的任务栏按钮与 ITaskbarList3 全部失效，必须重建，
    // 否则表现为「重启资源管理器后悬停没有按钮、进度条也不动了」。
    taskbar_controls_.OnTaskbarCreated();
    if (!EnsureTrayIcon() && !IsWindowVisible(hwnd)) {
      // 恢复失败时把窗口带回来，避免只剩后台进程且没有可操作入口。
      ShowWindow(hwnd, SW_RESTORE);
    }
    return 0;
  }
  if (message == WM_DWMCOMPOSITIONCHANGED) {
    ApplyWindowFrame(hwnd, fullscreen_);
    return 0;
  }
  if (message == WM_NCCALCSIZE && wparam == TRUE) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    // 全屏优先：窗口已被摆到 rcMonitor 且样式去掉了边框，客户区必须铺满整块
    // 显示器。**这条必须排在下面 IsZoomed 分支之前** —— 从「最大化」进全屏时
    // WS_MAXIMIZE 仍在，IsZoomed 依旧为 true，否则客户区会被按 rcWork 裁掉
    // 任务栏那一条（实测 150% 缩放下是 48px），表现为「界面底部留出状态栏空间」。
    if (fullscreen_) {
      MONITORINFO monitor{sizeof(monitor)};
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor)) {
        params->rgrc[0] = monitor.rcMonitor;
      }
      return 0;
    }
    // Flutter 绘制完整的半透明标题栏与三键，而非仅删除系统按钮。
    if (IsZoomed(hwnd)) {
      MONITORINFO monitor{sizeof(monitor)};
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
        params->rgrc[0] = monitor.rcWork;
      }
    }
    return 0;
  }
  if (message == WM_NCHITTEST) {
    // 无边框全屏：整个窗口都是客户区。不做这条守卫的话，贴屏幕边缘的那一圈
    // 像素会被下面的边框判定算成 HTLEFT/HTTOP… → 出现看不见的拉伸热区，
    // 且顶部会变成可拖动的标题区（一拖就把窗口拽出全屏矩形）。
    if (fullscreen_) return HTCLIENT;
    RECT bounds{};
    GetWindowRect(hwnd, &bounds);
    const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    const UINT dpi = GetDpiForWindow(hwnd);
    const int x = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                  GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int y = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                  GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    if (!IsZoomed(hwnd)) {
      const bool left = point.x < bounds.left + x;
      const bool right = point.x >= bounds.right - x;
      const bool top = point.y < bounds.top + y;
      const bool bottom = point.y >= bounds.bottom - y;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
    }
    // 按钮区域交给 Flutter；拖动由标题栏手势发送原生 HTCAPTION。
    return HTCLIENT;
  }
  if (message == WM_DPICHANGED) {
    // 全屏跨到另一块缩放比不同的显示器时，基类实现会把窗口摆到系统建议矩形
    // （那是「普通窗口」的建议尺寸），窗口会当场掉出全屏。这里先照常把消息
    // 转给 Flutter（它要据此更新 devicePixelRatio），再按新显示器的 rcMonitor
    // 重铺一次，并吞掉基类那次重排。
    if (fullscreen_) {
      if (flutter_controller_) {
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
      }
      MONITORINFO monitor{sizeof(monitor)};
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor)) {
        SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left,
                     monitor.rcMonitor.top,
                     monitor.rcMonitor.right - monitor.rcMonitor.left,
                     monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                     SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
      }
      return 0;
    }
  }
  if (message == WM_CLOSE) {
    if (EnsureTrayIcon()) {
      ShowWindow(hwnd, SW_HIDE);
    } else {
      SetQuitOnClose(true);
      Destroy();
    }
    return 0;
  }
  if (message == kTrayCallbackMessage) {
    if (lparam == WM_LBUTTONDBLCLK || lparam == WM_LBUTTONUP) {
      // 全屏状态下 SW_RESTORE 会把窗口从全屏矩形里拉出来；托盘单击只做前台化。
      if (!fullscreen_) ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
      return 0;
    }
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      POINT point{};
      GetCursorPos(&point);
      HMENU menu = CreatePopupMenu();
      if (menu) {
        AppendMenuW(menu, MF_STRING, kTrayMenuShow, L"显示窗口");
        AppendMenuW(menu, MF_STRING, kTrayMenuExit, L"退出");
        SetForegroundWindow(hwnd);
        const UINT selected = TrackPopupMenu(
            menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd,
            nullptr);
        DestroyMenu(menu);
        if (selected == kTrayMenuShow) {
          // 全屏下 SW_RESTORE 会掉出全屏矩形；此时只前台化。
          if (!fullscreen_) ShowWindow(hwnd, SW_RESTORE);
          SetForegroundWindow(hwnd);
        } else if (selected == kTrayMenuExit && !exit_requested_) {
          exit_requested_ = true;
          if (tray_channel_) {
            tray_channel_->InvokeMethod(
                "requestQuit",
                std::make_unique<flutter::EncodableValue>());
          }
        }
      }
      PostMessage(hwnd, WM_NULL, 0, 0);
      return 0;
    }
  }

  // 任务栏：TaskbarButtonCreated（按钮就绪，补加缩略图按钮）与
  // WM_COMMAND/THBN_CLICKED（点了缩略图按钮）必须在交给 Flutter 引擎**之前**
  // 处理 —— 引擎会先吃掉这条命令，按钮就变成点了没反应。
  // 主题变更消息本类不消费（只顺手换图标），返回 false 继续往下走。
  if (taskbar_controls_.HandleWindowMessage(message, wparam, lparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    default:
      // SMTC 媒体键/进度拖动经 PostMessage 封送到 UI 线程后在此分发。
      if (media_controls_.HandleWindowMessage(message, wparam, lparam)) {
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
