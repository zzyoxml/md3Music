#include "flutter_window.h"

#include <memory>
#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
using Arguments = flutter::EncodableMap;

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
                                      Wide(StringArg(args, "nextLyric")));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateTitle") {
          floating_lyric_.UpdateTitle(Wide(StringArg(args, "title")));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "setDesktopLyricConfig") {
          // Dart 侧下发 13 个字段，这里必须**全部**取到。只读其中几个会让
          // 「改了配色/字号/不透明度没反应」——因为其余字段全走 fallback 默认值。
          floating_lyric_.SetConfig(
              DoubleArg(args, "fontSize", 18.0),
              DoubleArg(args, "displayScale", 1.0),
              BoolArg(args, "doubleLine", true), IntArg(args, "opacity", 50),
              BoolArg(args, "locked", false),
              ColorArg(args, "gradientStart", 0xFF00E5FF),
              ColorArg(args, "gradientEnd", 0xFFFF00FF),
              ColorArg(args, "unplayedColor", 0xFFFFFFFF),
              IntArg(args, "colorMode", 0),
              ColorArg(args, "customStart", 0xFF00E5FF),
              ColorArg(args, "customEnd", 0xFFFF00FF),
              ColorArg(args, "customUnplayed", 0xFFFFFFFF));
          result->Success(flutter::EncodableValue(true));
        } else if (method == "updateProgress" || method == "setPlaying") {
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
  message_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "md3music/desktop_message",
          &flutter::StandardMethodCodec::GetInstance());
  message_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        // fluttertoast 在 Windows 无实现，这里用原生 MessageBoxW 兜底，
        // 保证 showToast 的反馈对用户可见（否则所有提示静默失败）。
        const auto* args = call.arguments()
                               ? std::get_if<Arguments>(call.arguments())
                               : nullptr;
        if (call.method_name() == "show") {
          const std::wstring message = Wide(StringArg(args, "message"));
          const std::wstring title = Wide(StringArg(args, "title"));
          const bool info_icon = BoolArg(args, "infoIcon", false);
          // MB_ICONNONE 不是合法的Win32 常量：无图标就传 0，
          // 有图标用 MB_ICONINFORMATION。
          UINT flags = MB_OK | MB_SETFOREGROUND;
          if (info_icon) flags |= MB_ICONINFORMATION;
          MessageBoxW(GetActiveWindow(), message.empty() ? L" " : message.c_str(),
                      title.empty() ? L"MD3Music" : title.c_str(), flags);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  media_controls_.Shutdown();
  floating_lyric_.Stop();
  lyric_channel_.reset();
  message_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
