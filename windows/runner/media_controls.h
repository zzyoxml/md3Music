#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <windows.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <string>

#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

// 桌面端系统媒体传输控件（SMTC）封装。
//
// just_audio_windows 在创建 MediaPlayer 时主动 `CommandManager().IsEnabled(false)`
// 退出了 Windows 的自动 SMTC 集成（否则媒体浮层是空白的、且媒体键会绕过 Dart
// 直接驱动原生播放器，导致 just_audio 的 playing 状态与 App 状态脱节）。因此
// 桌面端必须像 Android 的 MediaSession 一样，手动把播放状态/元数据发布到 SMTC，
// 并把播放/暂停/上一首/下一首/进度拖动等用户操作回传给 Dart。
//
// **本类同时是「第三方任务栏歌词工具」的数据源**（TaskbarLyrics、AF Media Bar
// 等一律通过 `GlobalSystemMediaTransportControlsSessionManager` 读本会话）。
// 它们只看 SMTC，不读 App 内部状态，所以这里少发布一个字段，那边就静默少一块
// 能力：不发 AlbumTitle → 歌词匹配少一维身份；不发 PlaybackRate → 倍速播放时
// 歌词持续漂移；不发 Thumbnail → 媒体栏没有封面。纯计算规则见
// `smtc_metadata.h`（可被 `test/windows/` 直接编译断言）。
class MediaControlsController {
 public:
  // 回传动作。action 与 Dart 侧 MediaNotificationService 的 method 名一致：
  // "togglePlayPause" / "next" / "previous" / "seekTo" / "setLoopMode" /
  // "setShuffle" / "setPlaybackSpeed"。
  // 仅 seekTo 时 position_ms 有效；setLoopMode / setShuffle 时 arg 有效；
  // setPlaybackSpeed 时 playback_rate 有效。
  using ActionCallback = std::function<void(
      const std::string& action, int64_t position_ms, const std::string& arg,
      double playback_rate)>;

  MediaControlsController() = default;
  ~MediaControlsController();

  MediaControlsController(const MediaControlsController&) = delete;
  MediaControlsController& operator=(const MediaControlsController&) = delete;

  // 初始化并绑定到顶层窗口。失败返回 false（不致命，媒体控制静默降级）。
  bool Initialize(HWND hwnd, ActionCallback on_action);

  // 释放 SMTC 与事件注册，幂等。
  void Shutdown();

  // 仅更新时间轴与播放状态（每秒的位置推进轻量路径）。
  //
  // **绝不触碰 DisplayUpdater / Thumbnail**：`DisplayUpdater.Update()` 会让系统
  // 重新发布整张媒体卡片，播控中心随之重绘封面。位置上报间隔为 1s 时若走全量
  // `UpdateMetadata`，封面就会每秒重建一次 —— 表现为「封面固定 1s 闪烁」。
  // `UpdateTimelineProperties` 只是属性写入，不重建卡片，可以安全地每秒调用。
  void UpdateTimeline(int64_t position_ms, int64_t duration_ms, bool is_playing);

  // 更新元数据、时间轴与播放状态。duration_ms<=0 时跳过时间轴更新。
  // loop_mode 取 AppLoopMode.name（'off'/'one'/'all'），映射到 SMTC 循环按钮
  // 状态（off→None、one→Track、all→List）。
  // playback_rate 为 App 实际倍速，越界/非有限值一律按 1.0 发布。
  // 空标题/歌手/专辑会被 `smtc_metadata.h` 清洗成空串后**不写入**（写空串会
  // 覆盖系统上一次的值，比保留更糟）。
  void UpdateMetadata(const std::string& title, const std::string& artist,
                      const std::string& album, const std::string& album_artist,
                      const std::string& art_url, int64_t position_ms,
                      int64_t duration_ms, bool is_playing,
                      const std::string& loop_mode, bool shuffle_enabled,
                      double playback_rate);

  // 仅更新播放状态（播放/暂停）。
  void SetPlaybackStatus(bool is_playing);

  // 主动停止：置 Stopped 并清空显示（退出 App / 空闲停播）。
  //
  // **必须发 Stopped 而不是 Paused**：Paused 会让播控中心与第三方歌词工具
  // 一直挂着上一首的卡片与歌词；Stopped + ClearAll 才会让它们收掉。
  void MarkStopped();

  // 处理窗口消息：SMTC 事件经 PostMessage 封送到 UI 线程后在此分发。
  // 返回 true 表示该消息已被本控制器消费。
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void ConfigureButtons();

  // 封面缓存：按本地路径缓存 `RandomAccessStreamReference`，避免 30s 一次的
  // 元数据刷新反复读盘/重新解码内嵌封面。上限 8 条（切歌窗口足够）。
  static constexpr size_t kMaxThumbnailCache = 8;
  winrt::Windows::Storage::Streams::RandomAccessStreamReference
  ThumbnailForLocalFile(const std::wstring& path);

  // 把封面写进 DisplayUpdater。art_url 支持 http(s) / file:// / 裸路径 /
  // `local://<path>`（本地歌曲的既有写法）；都取不到时清掉上一首的封面，
  // 让外部工具回退到自己的占位图，而不是挂着旧图。
  void SetThumbnail(
      const winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater&
          updater,
      const std::string& art_url);

  winrt::Windows::Media::SystemMediaTransportControls smtc_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token position_token_{};
  winrt::event_token repeat_token_{};
  winrt::event_token shuffle_token_{};
  winrt::event_token rate_token_{};
  std::map<std::wstring,
           winrt::Windows::Storage::Streams::RandomAccessStreamReference>
      thumbnail_cache_;
  std::deque<std::wstring> thumbnail_order_;
  ActionCallback on_action_;
  HWND hwnd_ = nullptr;
  bool initialized_ = false;
  // 是否处于「主动停止」态：由 MarkStopped 置位，UpdateMetadata 复位。
  bool stopped_ = false;
};

// 内部封送消息：SMTC 事件从任意线程 PostMessage 到主线程后统一分发。
inline constexpr UINT kMediaControlsActionMessage = WM_APP + 0x4D;

#endif  // RUNNER_MEDIA_CONTROLS_H_
