#include "media_controls.h"

#include <windows.h>
#include <systemmediatransportcontrolsinterop.h>

#include <chrono>
#include <string>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.FileProperties.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include "smtc_metadata.h"

namespace {

using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::AutoRepeatModeChangeRequestedEventArgs;
using winrt::Windows::Media::MediaPlaybackAutoRepeatMode;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::PlaybackRateChangeRequestedEventArgs;
using winrt::Windows::Media::ShuffleEnabledChangeRequestedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::FileProperties::ThumbnailMode;
using winrt::Windows::Storage::FileProperties::ThumbnailOptions;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

TimeSpan ToTimeSpan(int64_t milliseconds) {
  return std::chrono::duration_cast<TimeSpan>(
      std::chrono::milliseconds(milliseconds));
}

int64_t ToMillis(TimeSpan timespan) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(timespan).count();
}

// `MediaPlaybackStatus` 与 `smtc_metadata.h` 的纯常量必须一一对应。
// 在编译期钉死：SDK 若改了枚举值，这里先编译失败，而不是播控中心挂错态。
static_assert(static_cast<int>(MediaPlaybackStatus::Stopped) ==
                  smtc_metadata::kStatusStopped,
              "MediaPlaybackStatus::Stopped 与 smtc_metadata 常量不一致");
static_assert(static_cast<int>(MediaPlaybackStatus::Playing) ==
                  smtc_metadata::kStatusPlaying,
              "MediaPlaybackStatus::Playing 与 smtc_metadata 常量不一致");
static_assert(static_cast<int>(MediaPlaybackStatus::Paused) ==
                  smtc_metadata::kStatusPaused,
              "MediaPlaybackStatus::Paused 与 smtc_metadata 常量不一致");

// 把 Dart 下发的 UTF-8 字段过一遍占位符清洗。
//
// 只清「整体等于占位值」的字符串（「未知歌手」/「Unknown Title」等），
// 真实歌名里带「未知」二字不受影响。空结果表示「这个字段没有值」，
// 调用方**不要**写进 SMTC：写空串会覆盖系统上一次的值，比保留更糟。
std::wstring SanitizedField(const std::string& value) {
  if (value.empty()) return std::wstring();
  return smtc_metadata::SanitizeText(winrt::to_hstring(value).c_str());
}

// 从本地音频文件取封面。
//
// 优先走系统缩略图（`ThumbnailMode::MusicView`）：Windows 会自己解 ID3/FLAC
// 内嵌图，不必在 runner 里引一个 ID3 解析器。取不到再退回读整文件
// （等价于旧行为，只是旧行为对 `local://` 前缀根本没进这条路径）。
RandomAccessStreamReference ThumbnailFromFile(const std::wstring& path) {
  const auto file =
      StorageFile::GetFileFromPathAsync(winrt::hstring(path)).get();
  try {
    const auto thumbnail = file
                               .GetThumbnailAsync(ThumbnailMode::MusicView, 512,
                                                  ThumbnailOptions::None)
                               .get();
    if (thumbnail != nullptr) {
      return RandomAccessStreamReference::CreateFromStream(thumbnail);
    }
  } catch (...) {
    // 缩略图不可用（容器不支持 / 无内嵌图），继续走整文件读取。
  }
  const auto stream = file.OpenReadAsync().get();
  return RandomAccessStreamReference::CreateFromStream(stream);
}

}  // namespace

MediaControlsController::~MediaControlsController() { Shutdown(); }

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

    // 随机 / 倍速：只在 ISystemMediaTransportControls2 可用时注册。
    // 老系统（Win10 早期）拿不到该接口 → 只丢这两项能力，播放控制不受影响。
    //
    // 注意 sender 类型：这些事件的 TypedEventHandler 形参是**具体类型**
    // `SystemMediaTransportControls`（不是 ISystemMediaTransportControls2），
    // 写错接口名编译不过。
    if (auto smtc2 =
            smtc_.try_as<winrt::Windows::Media::ISystemMediaTransportControls2>()) {
      shuffle_token_ = smtc2.ShuffleEnabledChangeRequested(
          [this](const SystemMediaTransportControls&,
                 const ShuffleEnabledChangeRequestedEventArgs& args) {
            if (hwnd_ == nullptr) return;
            // arg 用 "true"/"false"：Dart 侧解析成 bool，与 loop 用字符串传
            // 同一个先例（setLoopMode 传 "off"/"one"/"all"）。
            const char* arg = args.RequestedShuffleEnabled() ? "true" : "false";
            ::PostMessageW(hwnd_, kMediaControlsActionMessage,
                           static_cast<WPARAM>(7),
                           reinterpret_cast<LPARAM>(arg));
          });
      rate_token_ = smtc2.PlaybackRateChangeRequested(
          [this](const SystemMediaTransportControls&,
                 const PlaybackRateChangeRequestedEventArgs& args) {
            if (hwnd_ == nullptr) return;
            // 倍速是 double，塞不进 LPARAM；用一块静态存储把值带过线程边界。
            // 事件之间不会并发（同一 UI 线程封送），且 HandleWindowMessage
            // 立即读走，因此静态槽位安全。
            static double pending_rate = 1.0;
            pending_rate = args.RequestedPlaybackRate();
            ::PostMessageW(hwnd_, kMediaControlsActionMessage,
                           static_cast<WPARAM>(8),
                           reinterpret_cast<LPARAM>(&pending_rate));
          });
    }

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
    thumbnail_cache_.clear();
    thumbnail_order_.clear();
    return;
  }
  initialized_ = false;
  try {
    if (smtc_) {
      smtc_.ButtonPressed(button_token_);
      smtc_.PlaybackPositionChangeRequested(position_token_);
      smtc_.AutoRepeatModeChangeRequested(repeat_token_);
      // 随机/倍速两个 token 只在该接口可用时注册过，移除时同样要判空：
      // 对空 token 调 remove 会抛 invalid_argument，被下面 catch 吞掉后
      // 后面的 IsEnabled(false) 就执行不到了。
      if (auto smtc2 = smtc_.try_as<
              winrt::Windows::Media::ISystemMediaTransportControls2>()) {
        if (shuffle_token_.value != 0) {
          smtc2.ShuffleEnabledChangeRequested(shuffle_token_);
        }
        if (rate_token_.value != 0) {
          smtc2.PlaybackRateChangeRequested(rate_token_);
        }
      }
      smtc_.IsEnabled(false);
    }
  } catch (...) {
  }
  smtc_ = nullptr;
  button_token_ = {};
  position_token_ = {};
  repeat_token_ = {};
  shuffle_token_ = {};
  rate_token_ = {};
  thumbnail_cache_.clear();
  thumbnail_order_.clear();
  hwnd_ = nullptr;
  on_action_ = nullptr;
  stopped_ = false;
}

void MediaControlsController::ConfigureButtons() {
  smtc_.IsPlayEnabled(true);
  smtc_.IsPauseEnabled(true);
  smtc_.IsNextEnabled(true);
  smtc_.IsPreviousEnabled(true);
  smtc_.IsStopEnabled(false);
}

void MediaControlsController::SetThumbnail(
    const winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater&
        updater,
    const std::string& art_url) {
  if (art_url.empty()) {
    try {
      updater.Thumbnail(nullptr);
    } catch (...) {
    }
    return;
  }

  // http(s)：直接交给系统按 URI 拉取（与旧行为一致）。
  if (art_url.rfind("http://", 0) == 0 || art_url.rfind("https://", 0) == 0) {
    try {
      const auto uri =
          winrt::Windows::Foundation::Uri(winrt::to_hstring(art_url));
      updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(uri));
      return;
    } catch (...) {
      // URI 解析失败：清封面，不让上一首的图挂着。
      try {
        updater.Thumbnail(nullptr);
      } catch (...) {
      }
      return;
    }
  }

  // 本地路径：`local://<path>`（本地歌曲的既有写法，旧实现直接跳过 → 本地歌
  // 永远没有封面）、`file://<path>`、或裸绝对路径。
  std::string path;
  if (art_url.rfind("local://", 0) == 0) {
    path = art_url.substr(8);
  } else if (art_url.rfind("file://", 0) == 0) {
    path = art_url.substr(7);
  } else if (art_url.rfind("content://", 0) != 0) {
    // content:// 是 Android 的 MediaStore URI，Windows 上不可解析：当作无封面。
    path = art_url;
  }
  if (path.empty()) {
    try {
      updater.Thumbnail(nullptr);
    } catch (...) {
    }
    return;
  }

  // `local://` 后可能是 `file://` 套娃（本地库两处写法不完全一致），再剥一层。
  if (path.rfind("file://", 0) == 0) path = path.substr(7);

  const std::wstring wide_path = winrt::to_hstring(path).c_str();
  const auto reference = ThumbnailForLocalFile(wide_path);
  try {
    updater.Thumbnail(reference);
  } catch (...) {
  }
}

RandomAccessStreamReference MediaControlsController::ThumbnailForLocalFile(
    const std::wstring& path) {
  const auto cached = thumbnail_cache_.find(path);
  if (cached != thumbnail_cache_.end()) return cached->second;
  RandomAccessStreamReference reference{nullptr};
  try {
    reference = ThumbnailFromFile(path);
  } catch (...) {
    // 文件不存在 / 无权限 / 格式不支持：返回空引用，调用方据此清封面。
    return RandomAccessStreamReference{nullptr};
  }
  if (reference == nullptr) return reference;
  // 简单 FIFO 淘汰：切歌窗口内最多 8 条，超出丢最旧的一条。
  //
  // 用 insert_or_assign 而不是 `cache[key] = ...`：`RandomAccessStreamReference`
  // 没有默认构造函数，`operator[]` 会在缺键时先默认构造再赋值，直接编译失败
  // （C2512）。
  thumbnail_cache_.insert_or_assign(path, reference);
  thumbnail_order_.push_back(path);
  while (thumbnail_order_.size() > kMaxThumbnailCache) {
    thumbnail_cache_.erase(thumbnail_order_.front());
    thumbnail_order_.pop_front();
  }
  return reference;
}

void MediaControlsController::UpdateTimeline(int64_t position_ms,
                                             int64_t duration_ms,
                                             bool is_playing) {
  if (!initialized_ || !smtc_) return;
  try {
    int64_t clamped_position = position_ms;
    int64_t clamped_duration = duration_ms;
    if (smtc_metadata::ResolveTimeline(position_ms, duration_ms,
                                       &clamped_position, &clamped_duration)) {
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(ToTimeSpan(0));
      timeline.MinSeekTime(ToTimeSpan(0));
      timeline.Position(ToTimeSpan(clamped_position));
      timeline.EndTime(ToTimeSpan(clamped_duration));
      timeline.MaxSeekTime(ToTimeSpan(clamped_duration));
      smtc_.UpdateTimelineProperties(timeline);
    } else {
      // 时长未知（duration<=0）：**必须**把时间轴收成 0 长度，不能什么都不做。
      //
      // 切歌瞬间 Dart 侧 durationStream 还没给出新值，_pushNotification 会带着
      // 上一首（或 0）的时长进来。若此时跳过更新，SMTC 的 EndTime 就停在**上一首**
      // 的值上。第三方任务栏歌词工具（TaskbarLyrics / AF Media Bar）都按
      // `EndTime - StartTime` 取曲长，并拿它做歌词候选打分（AF 的
      // KugouLyricsProvider 按「候选时长与目标时长最接近」排序）与进度换算 ——
      // 时长错就等于取不到词。
      //
      // 收成 0 是诚实的：工具看到「时长未知」会走它自己的兜底，比看到一串
      // 错误的数字要好。Dart 侧 durationStream 回填后会立刻补推真实时长。
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(ToTimeSpan(0));
      timeline.MinSeekTime(ToTimeSpan(0));
      timeline.Position(ToTimeSpan(0));
      timeline.EndTime(ToTimeSpan(0));
      timeline.MaxSeekTime(ToTimeSpan(0));
      smtc_.UpdateTimelineProperties(timeline);
    }

    smtc_.PlaybackStatus(is_playing ? MediaPlaybackStatus::Playing
                                    : MediaPlaybackStatus::Paused);
  } catch (...) {
    // SMTC 更新失败不致命。
  }
}

void MediaControlsController::UpdateMetadata(
    const std::string& title, const std::string& artist,
    const std::string& album, const std::string& album_artist,
    const std::string& art_url, int64_t position_ms, int64_t duration_ms,
    bool is_playing, const std::string& loop_mode, bool shuffle_enabled,
    double playback_rate) {
  if (!initialized_ || !smtc_) return;
  // 有新元数据进来即退出「主动停止」态（下一次 MarkStopped 再置位）。
  stopped_ = false;
  try {
    const auto updater = smtc_.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    const auto music = updater.MusicProperties();
    // 三个文本字段先清洗：App 内部占位值（未知歌手/Unknown Title…）一旦下发，
    // 第三方歌词工具会当成真实元数据，直接把歌词匹配拉出门槛。
    const std::wstring clean_title = SanitizedField(title);
    const std::wstring clean_artist = SanitizedField(artist);
    const std::wstring clean_album = SanitizedField(album);
    const std::wstring clean_album_artist = SanitizedField(album_artist);
    if (!clean_title.empty()) music.Title(clean_title);
    if (!clean_artist.empty()) music.Artist(clean_artist);
    // AlbumTitle 是第三方歌词工具的**身份维度之一**：TaskbarLyrics 的
    // CoverIdentity / LyricMatcher 与 AF Media Bar 的 MediaSnapshotBuilder
    // 都读它，缺它会让同名歌曲的匹配精度下降。
    if (!clean_album.empty()) music.AlbumTitle(clean_album);
    if (!clean_album_artist.empty()) music.AlbumArtist(clean_album_artist);
    SetThumbnail(updater, art_url);
    updater.Update();

    // 随机态 + 倍速：ISystemMediaTransportControls2 才有的属性。
    if (auto smtc2 = smtc_.try_as<
            winrt::Windows::Media::ISystemMediaTransportControls2>()) {
      smtc2.ShuffleEnabled(shuffle_enabled);
      // 倍速不发布时外部工具一律按 1.0x 外推时间轴，1.25x/1.5x 播放会持续漂移。
      smtc2.PlaybackRate(smtc_metadata::ResolvePlaybackRate(playback_rate));
    }

    // 循环模式 → SMTC 循环按钮状态（Repeat 按钮高亮随 AutoRepeatMode 变化）。
    if (loop_mode == "one") {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::Track);
    } else if (loop_mode == "all") {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::List);
    } else {
      smtc_.AutoRepeatMode(MediaPlaybackAutoRepeatMode::None);
    }

    // 时间轴 + 播放状态收敛在 UpdateTimeline（全量路径与每秒轻量路径共用）。
    UpdateTimeline(position_ms, duration_ms, is_playing);
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

void MediaControlsController::MarkStopped() {
  if (!initialized_ || !smtc_) return;
  stopped_ = true;
  try {
    // 顺序不能反：先清显示再置状态，否则部分系统版本会在清空的瞬间把
    // 卡片重建成「上一首 + 空标题」。
    const auto updater = smtc_.DisplayUpdater();
    updater.ClearAll();
    smtc_.PlaybackStatus(MediaPlaybackStatus::Stopped);
  } catch (...) {
  }
}

bool MediaControlsController::HandleWindowMessage(UINT message, WPARAM wparam,
                                                  LPARAM lparam) {
  if (message != kMediaControlsActionMessage) return false;
  if (!on_action_) return true;
  switch (static_cast<int>(wparam)) {
    case 1:
      on_action_("togglePlayPause", 0, "", 0.0);
      break;
    case 2:
      on_action_("next", 0, "", 0.0);
      break;
    case 3:
      on_action_("previous", 0, "", 0.0);
      break;
    case 4:
      on_action_("seekTo", static_cast<int64_t>(lparam), "", 0.0);
      break;
    case 6: {
      // 循环按钮：lparam 为目标循环模式下标（0=off 1=one 2=all）。
      const int idx = static_cast<int>(lparam);
      const char* mode = (idx == 1) ? "one" : (idx == 2) ? "all" : "off";
      on_action_("setLoopMode", 0, mode, 0.0);
      break;
    }
    case 7: {
      // 随机按钮：lparam 指向静态字符串 "true"/"false"（见事件注册处）。
      const char* arg = reinterpret_cast<const char*>(lparam);
      on_action_("setShuffle", 0, arg != nullptr ? arg : "false", 0.0);
      break;
    }
    case 8: {
      // 倍速按钮：lparam 指向静态 double（见事件注册处）。
      const auto* rate = reinterpret_cast<const double*>(lparam);
      on_action_("setPlaybackSpeed", 0, "",
                 rate != nullptr ? *rate : 1.0);
      break;
    }
    default:
      break;
  }
  return true;
}
