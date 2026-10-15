#include "media_controls.h"

#include <windows.h>
#include <systemmediatransportcontrolsinterop.h>

#include <chrono>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::AutoRepeatModeChangeRequestedEventArgs;
using winrt::Windows::Media::MediaPlaybackAutoRepeatMode;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

TimeSpan ToTimeSpan(int64_t milliseconds) {
  return std::chrono::duration_cast<TimeSpan>(
      std::chrono::milliseconds(milliseconds));
}

int64_t ToMillis(TimeSpan timespan) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(timespan).count();
}

// 设置封面：http(s) 直接 CreateFromUri；file:// 或纯本地路径转成文件流。
// 所有异常静默吞掉 —— 封面不可用不应影响媒体控制按钮/元数据。
void SetThumbnail(
    const winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater& updater,
    const std::string& art_url) {
  if (art_url.rfind("http://", 0) == 0 || art_url.rfind("https://", 0) == 0) {
    try {
      const auto uri =
          winrt::Windows::Foundation::Uri(winrt::to_hstring(art_url));
      updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(uri));
    } catch (...) {
      // 继续尝试按文件路径解析。
    }
    return;
  }

  std::string path;
  if (art_url.rfind("file://", 0) == 0) {
    path = art_url.substr(7);
  } else if (!art_url.empty() && art_url.rfind("local://", 0) != 0 &&
             art_url.rfind("content://", 0) != 0) {
    path = art_url;
  }
  if (path.empty()) return;

  try {
    const auto file =
        StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
    const auto stream = file.OpenReadAsync().get();
    updater.Thumbnail(RandomAccessStreamReference::CreateFromStream(stream));
  } catch (...) {
    // 封面不可用，忽略。
  }
}

}  // namespace

MediaControlsController::~MediaControlsController() {
  Shutdown();
}

bool MediaControlsController::Initialize(HWND hwnd, ActionCallback on_action) {
  if (initialized_) return true;
  hwnd_ = hwnd;
  on_action_ = std::move(on_action);
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        hwnd_, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(smtc_)));
    if (!smtc_) return false;

    smtc_.IsEnabled(true);
    ConfigureButtons();

    button_token_ = smtc_.ButtonPressed(
        [this](
            const SystemMediaTransportControls&,
            const winrt::Windows::Media::
                SystemMediaTransportControlsButtonPressedEventArgs& args) {
          if (hwnd_ == nullptr) return;
          // 按钮事件可能落在非 UI 线程，PostMessage 到窗口线程统一分发，
          // 避免跨线程直接调用 Flutter messenger。
          int code = 0;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play:
            case SystemMediaTransportControlsButton::Pause:
              code = 1;  // togglePlayPause
              break;
            case SystemMediaTransportControlsButton::Next:
              code = 2;  // next
              break;
            case SystemMediaTransportControlsButton::Previous:
              code = 3;  // previous
              break;
            default:
              break;
          }
          if (code != 0) {
            ::PostMessageW(hwnd_, kMediaControlsActionMessage,
                           static_cast<WPARAM>(code), 0);
          }
        });

    position_token_ = smtc_.PlaybackPositionChangeRequested(
        [this](
            const SystemMediaTransportControls&,
            const winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs&
                args) {
          if (hwnd_ == nullptr) return;
          const int64_t position_ms = ToMillis(args.RequestedPlaybackPosition());
          ::PostMessageW(hwnd_, kMediaControlsActionMessage,
                         static_cast<WPARAM>(4),
                         static_cast<LPARAM>(position_ms));
        });

    // 循环按钮不走 ButtonPressed（SystemMediaTransportControlsButton 里没有
    // Repeat），而是独立的 AutoRepeatModeChangeRequested 事件。系统按
    // None→List→Track→None 循环算好「下一个」模式放在 RequestedAutoRepeatMode
    // 里，App 服从该模式即可保证浮层高亮与实际循环状态严格一致。
    repeat_token_ = smtc_.AutoRepeatModeChangeRequested(
        [this](const SystemMediaTransportControls&,
               const AutoRepeatModeChangeRequestedEventArgs& args) {
          if (hwnd_ == nullptr) return;
          // MediaPlaybackAutoRepeatMode：None=0 / Track=1 / List=2，
          // 恰好与 AppLoopMode off=0 / one=1 / all=2 下标一一对应。
          const auto mode = args.RequestedAutoRepeatMode();
          ::PostMessageW(hwnd_, kMediaControlsActionMessage,
                         static_cast<WPARAM>(6),
                         static_cast<LPARAM>(static_cast<int>(mode)));
        });

    initialized_ = true;
    return true;
  } catch (...) {
    Shutdown();
    return false;
  }
}

void MediaControlsController::Shutdown() {
  if (!initialized_) {
    hwnd_ = nullptr;
    on_action_ = nullptr;
    smtc_ = nullptr;
    return;
  }
  initialized_ = false;
  try {
    if (smtc_) {
      smtc_.ButtonPressed(button_token_);
      smtc_.PlaybackPositionChangeRequested(position_token_);
      smtc_.AutoRepeatModeChangeRequested(repeat_token_);
      smtc_.IsEnabled(false);
    }
  } catch (...) {
  }
  smtc_ = nullptr;
  button_token_ = {};
  position_token_ = {};
  repeat_token_ = {};
  hwnd_ = nullptr;
  on_action_ = nullptr;
}

void MediaControlsController::ConfigureButtons() {
  smtc_.IsPlayEnabled(true);
  smtc_.IsPauseEnabled(true);
  smtc_.IsNextEnabled(true);
  smtc_.IsPreviousEnabled(true);
  smtc_.IsStopEnabled(false);
}

void MediaControlsController::UpdateMetadata(const std::string& title,
                                             const std::string& artist,
                                             const std::string& art_url,
                                             int64_t position_ms,
                                             int64_t duration_ms,
                                             bool is_playing,
                                             const std::string& loop_mode,
                                             bool shuffle_enabled) {
  (void)shuffle_enabled;  // 随机按钮暂不发布，保持与 SMTC 语义一致的最小改动
  if (!initialized_ || !smtc_) return;
  try {
    const auto updater = smtc_.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    const auto music = updater.MusicProperties();
    music.Title(winrt::to_hstring(title));
    music.Artist(winrt::to_hstring(artist));
    if (!art_url.empty()) {
      SetThumbnail(updater, art_url);
    }
    updater.Update();

    // 循环模式 → SMTC 循环按钮状态（Repeat 按钮高亮随 AutoRepeatMode 变化）。
    if (loop_mode == "one") {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::Track);
    } else if (loop_mode == "all") {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::List);
    } else {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::None);
    }

    if (duration_ms > 0) {
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(ToTimeSpan(0));
      timeline.MinSeekTime(ToTimeSpan(0));
      timeline.Position(ToTimeSpan(position_ms));
      timeline.EndTime(ToTimeSpan(duration_ms));
      timeline.MaxSeekTime(ToTimeSpan(duration_ms));
      smtc_.UpdateTimelineProperties(timeline);
    }

    smtc_.PlaybackStatus(is_playing ? MediaPlaybackStatus::Playing
                                    : MediaPlaybackStatus::Paused);
  } catch (...) {
    // SMTC 更新失败不致命。
  }
}

void MediaControlsController::SetPlaybackStatus(bool is_playing) {
  if (!initialized_ || !smtc_) return;
  try {
    smtc_.PlaybackStatus(is_playing ? MediaPlaybackStatus::Playing
                                    : MediaPlaybackStatus::Paused);
  } catch (...) {
  }
}

bool MediaControlsController::HandleWindowMessage(UINT message, WPARAM wparam,
                                                  LPARAM lparam) {
  if (message != kMediaControlsActionMessage) return false;
  if (!on_action_) return true;
  switch (static_cast<int>(wparam)) {
    case 1:
      on_action_("togglePlayPause", 0, "");
      break;
    case 2:
      on_action_("next", 0, "");
      break;
    case 3:
      on_action_("previous", 0, "");
      break;
    case 4:
      on_action_("seekTo", static_cast<int64_t>(lparam), "");
      break;
    case 6: {
      // 循环按钮：lparam 为目标循环模式下标（0=off 1=one 2=all）。
      const int idx = static_cast<int>(lparam);
      const char* mode = (idx == 1) ? "one" : (idx == 2) ? "all" : "off";
      on_action_("setLoopMode", 0, mode);
      break;
    }
    default:
      break;
  }
  return true;
}
