#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>

#include <winrt/Windows.Media.h>

// 桌面端系统媒体传输控件（SMTC）封装。
//
// just_audio_windows 在创建 MediaPlayer 时主动 `CommandManager().IsEnabled(false)`
// 退出了 Windows 的自动 SMTC 集成（否则媒体浮层是空白的、且媒体键会绕过 Dart
// 直接驱动原生播放器，导致 just_audio 的 playing 状态与 App 状态脱节）。因此
// 桌面端必须像 Android 的 MediaSession 一样，手动把播放状态/元数据发布到 SMTC，
// 并把播放/暂停/上一首/下一首/进度拖动等用户操作回传给 Dart。
class MediaControlsController {
 public:
  // 回传动作。action 与 Dart 侧 MediaNotificationService 的 method 名一致：
  // "togglePlayPause" / "next" / "previous" / "seekTo" / "setLoopMode"。
  // 仅 seekTo 时 position_ms 有效；仅 setLoopMode 时 arg 有效（'off'/'one'/'all'）。
  using ActionCallback = std::function<void(
      const std::string& action, int64_t position_ms, const std::string& arg)>;

  MediaControlsController() = default;
  ~MediaControlsController();

  MediaControlsController(const MediaControlsController&) = delete;
  MediaControlsController& operator=(const MediaControlsController&) = delete;

  // 初始化并绑定到顶层窗口。失败返回 false（不致命，媒体控制静默降级）。
  bool Initialize(HWND hwnd, ActionCallback on_action);

  // 释放 SMTC 与事件注册，幂等。
  void Shutdown();

  // 更新元数据、时间轴与播放状态。duration_ms<=0 时跳过时间轴更新。
  // loop_mode 取 AppLoopMode.name（'off'/'one'/'all'），映射到 SMTC 循环按钮
  // 状态（off→None、one→Track、all→List）；shuffle_enabled 暂只透传不发布
  // （SMTC 的随机按钮与 App 的随机语义不完全等价，保持最小改动）。
  void UpdateMetadata(const std::string& title,
                      const std::string& artist,
                      const std::string& art_url,
                      int64_t position_ms,
                      int64_t duration_ms,
                      bool is_playing,
                      const std::string& loop_mode,
                      bool shuffle_enabled);

  // 仅更新播放状态（播放/暂停）。
  void SetPlaybackStatus(bool is_playing);

  // 处理窗口消息：SMTC 事件经 PostMessage 封送到 UI 线程后在此分发。
  // 返回 true 表示该消息已被本控制器消费。
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void ConfigureButtons();

  winrt::Windows::Media::SystemMediaTransportControls smtc_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token position_token_{};
  winrt::event_token repeat_token_{};
  ActionCallback on_action_;
  HWND hwnd_ = nullptr;
  bool initialized_ = false;
};

// 内部封送消息：SMTC 事件从任意线程 PostMessage 到主线程后统一分发。
inline constexpr UINT kMediaControlsActionMessage = WM_APP + 0x4D;

#endif  // RUNNER_MEDIA_CONTROLS_H_
