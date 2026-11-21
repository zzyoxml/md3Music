#pragma comment(lib, "windowsapp")

#include <chrono>
#include <cstdio>
#include <optional>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "uri_utils.hpp"

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.System.h>
#include "dsp_engine.hpp"
#define TO_MILLISECONDS(timespan) timespan.count() / 10000
#define TO_MICROSECONDS(timespan) TO_MILLISECONDS(timespan) * 1000

using flutter::EncodableMap;
using flutter::EncodableValue;

using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Media;

using winrt::Windows::Media::Core::MediaSource;

// Looks for |key| in |map|, returning the associated value if it is present, or
// a nullptr if not.
//
// The variant types are mapped with Dart types in following ways:
// std::monostate       -> null
// bool                 -> bool
// int32_t              -> int
// int64_t              -> int
// double               -> double
// std::string          -> String
// std::vector<uint8_t> -> Uint8List
// std::vector<int32_t> -> Int32List
// std::vector<int64_t> -> Int64List
// std::vector<float>   -> Float32List
// std::vector<double>  -> Float64List
// EncodableList        -> List
// EncodableMap         -> Map
const EncodableValue* ValueOrNull(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}

// Converts a std::string to std::wstring
auto TO_WIDESTRING = [](std::string string) -> std::wstring {
  if (string.empty()) {
    return std::wstring();
  }
  int32_t target_length =
    ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, string.data(),
      static_cast<int32_t>(string.length()), nullptr, 0);
  if (target_length == 0) {
    return std::wstring();
  }
  std::wstring utf16_string;
  utf16_string.resize(target_length);
  int32_t converted_length =
    ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, string.data(),
      static_cast<int32_t>(string.length()),
      utf16_string.data(), target_length);
  if (converted_length == 0) {
    return std::wstring();
  }
  return utf16_string;
};


class JustAudioEventSink {
public:
  // Prevent copying.
  JustAudioEventSink(JustAudioEventSink const&) = delete;
  JustAudioEventSink& operator=(JustAudioEventSink const&) = delete;

  JustAudioEventSink::JustAudioEventSink(flutter::BinaryMessenger* messenger, const std::string& id) {
    auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(messenger, id, &flutter::StandardMethodCodec::GetInstance());

    auto event_handler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [self = this](const EncodableValue* arguments, std::unique_ptr<flutter::EventSink<>>&& events) -> std::unique_ptr<flutter::StreamHandlerError<>> {
      self->sink = std::move(events);
      return nullptr;
    }, [self = this](const EncodableValue* arguments) -> std::unique_ptr<flutter::StreamHandlerError<>> {
      self->sink.reset();
      return nullptr;
    });

    event_channel->SetStreamHandler(std::move(event_handler));
  }

  void Success(const EncodableValue& event) {
    if (sink) {
      sink->Success(event);
    }
  }

  void Error(const std::string& error_code,
    const std::string& error_message) {
    if (sink) {
      sink->Error(error_code, error_message);
    }
  }
private:
  std::unique_ptr<flutter::EventSink<>> sink = nullptr;
};

class AudioPlayer {
private:
  bool disposed_ = false;

  void Dispose() {
    if (disposed_) return;
    disposed_ = true;
    auto session = mediaPlayer.PlaybackSession();
    session.PlaybackStateChanged(playback_state_token_);
    mediaPlayer.MediaFailed(media_failed_token_);
    mediaPlayer.MediaOpened(mp_opened_token_);
    mediaPlaybackList.CurrentItemChanged(item_changed_token_);
    mediaPlaybackList.ItemFailed(item_failed_token_);
    dsp_probe.PlaybackSession().PlaybackStateChanged(dsp_probe_state_token_);
    dsp_probe.MediaOpened(dsp_probe_opened_token_);
    dsp_probe.Close();
    player_channel_->SetMethodCallHandler(nullptr);
    event_sink_.reset();
    data_sink_.reset();
    mediaPlayer.Close();
    // 反注册广播表并释放可能存在的 AudioGraph，避免野回调与资源残留。
    md3music::dsp::DspState::Instance().Unregister(this);
    // 先停工作线程（任务里检查 disposed_ 会自行跳过），再清图。
    if (dsp_worker_) {
      {
        std::lock_guard<std::mutex> lk(dsp_graph_mutex_);
        dsp_worker_quit_ = true;
      }
      dsp_worker_cv_.notify_all();
      dsp_worker_->join();
      dsp_worker_.reset();
      dsp_worker_quit_ = false;
    }
    {
      std::lock_guard<std::mutex> lk(dsp_graph_mutex_);
      if (dsp_graph_) {
        dsp_graph_->Close();
        dsp_graph_.reset();
      }
    }
  }

  // DSP 专用 MTA 工作线程：惰性启动，串行处理投递的任务。
  void DspEnsureWorker() const {
    if (dsp_worker_) return;
    dsp_worker_ = std::make_unique<std::thread>([this]() {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      for (;;) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lk(dsp_graph_mutex_);
          dsp_worker_cv_.wait(lk, [&] {
            return dsp_worker_quit_ || !dsp_worker_tasks_.empty();
          });
          if (dsp_worker_quit_ && dsp_worker_tasks_.empty()) return;
          task = std::move(dsp_worker_tasks_.front());
          dsp_worker_tasks_.pop_front();
        }
        task();
      }
    });
  }

  void DspPost(std::function<void()> task) const {
    if (disposed_) return;
    DspEnsureWorker();
    {
      std::lock_guard<std::mutex> lk(dsp_graph_mutex_);
      dsp_worker_tasks_.push_back(std::move(task));
    }
    dsp_worker_cv_.notify_one();
  }
public:
  std::string id;
  Playback::MediaPlayer mediaPlayer{};
  Playback::MediaPlaybackList mediaPlaybackList{};

  // 音效开关：默认关闭，MediaPlayer 行为保持不变；Task 3 起由 DspState 广播置位。
  bool dsp_active_ = false;
  // 图代次：DspState.release 递增时释放旧图，避免残留 AudioGraph。
  std::uint64_t dsp_epoch_ = 0;
  // AudioGraph 的构建涉及 IAsyncOperation::get()，禁止在 STA 平台线程阻塞，
  // 因此所有图操作都投递到专用 MTA 工作线程串行执行（见 DspPost）。
  mutable std::optional<md3music::DspGraph> dsp_graph_;
  mutable std::wstring dsp_current_uri_;
  mutable std::mutex dsp_graph_mutex_;
  mutable std::atomic<bool> dsp_playing_{false};
  // 最近一次已知的曲目时长：probe 尚未打开时广播用，避免 UI 时长闪 0。
  mutable std::atomic<int64_t> dsp_last_duration_us_{0};
  // DSP→正常交还时的挂起进度：MediaPlayer 源尚未 open 时 Position 会抛异常，
  // 先记录，MediaOpened 后再落位（-1 表示无挂起）。
  mutable std::atomic<int64_t> dsp_pending_mp_pos_us_{-1};
  mutable std::unique_ptr<std::thread> dsp_worker_;
  mutable bool dsp_worker_quit_ = false;
  mutable std::condition_variable dsp_worker_cv_;
  mutable std::deque<std::function<void()>> dsp_worker_tasks_;
  // DSP 静音时钟播放器：AudioGraph 无时长/进度/状态事件，用同 URI 的
  // Volume=0 MediaPlayer 作为状态机源头（时长/进度/playing/completed）。
  // 代价：同一 URL 双连接双解码，调试期可接受；Phase 2 再优化。
  Playback::MediaPlayer dsp_probe{};
  winrt::event_token dsp_probe_state_token_{};
  winrt::event_token dsp_probe_opened_token_{};
  winrt::event_token mp_opened_token_{};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> player_channel_;
  std::unique_ptr<JustAudioEventSink> event_sink_ = nullptr;
  std::unique_ptr<JustAudioEventSink> data_sink_ = nullptr;

  // Tokens for event unsubscription
  winrt::event_token playback_state_token_{};
  winrt::event_token media_failed_token_{};
  winrt::event_token item_changed_token_{};
  winrt::event_token item_failed_token_{};

public:
  AudioPlayer::AudioPlayer(std::string idx, flutter::BinaryMessenger* messenger) {
    id = idx;

    // 退出 Windows 系统自动 SMTC 集成（上游 master 已修但截至 0.2.3 未发版）：
    // MediaPlayer.CommandManager().IsEnabled 默认为 true，Windows 会为每个
    // 播放器自动向播控中心注册一张空白媒体卡片，且硬件媒体键会绕过 Dart
    // 直接驱动原生播放器。宿主 App（md3music runner 的 media_controls.cpp）
    // 已手动发布带完整元数据的 SMTC，这里必须关掉，否则播控中心出现两张
    // 卡片、且 just_audio 的 playing 状态与 App 状态脱节。
    mediaPlayer.CommandManager().IsEnabled(false);

    // DSP 静音时钟播放器：不自动播、不注册 SMTC、强制静音（它只提供状态事件，
    // 音频渲染全部由 AudioGraph 负责，不静音会和图同时出声 = 双声音）。
    dsp_probe.CommandManager().IsEnabled(false);
    dsp_probe.AutoPlay(false);
    dsp_probe.Volume(0.0f);
    dsp_probe.IsMuted(true);
    dsp_probe_state_token_ =
        dsp_probe.PlaybackSession().PlaybackStateChanged(
            [this](auto, const auto&) -> void {
      if (disposed_ || !dsp_active_) return;
      broadcastState();
    });
    dsp_probe_opened_token_ = dsp_probe.MediaOpened([this](auto, const auto&) -> void {
      if (disposed_ || !dsp_active_) return;
      broadcastState();
    });
    // DSP→正常交还的挂起进度落位点：MP 源 open 完成后才能 Position。
    mp_opened_token_ = mediaPlayer.MediaOpened([this](auto, const auto&) -> void {
      const int64_t pending = dsp_pending_mp_pos_us_.load();
      if (disposed_ || pending < 0) return;
      dsp_pending_mp_pos_us_ = -1;
      try {
        mediaPlayer.Position(TimeSpan(std::chrono::microseconds(pending)));
        std::fprintf(stderr, "[DSPTRACE] MP resumed to %lldus\n",
                     (long long)pending);
      } catch (...) {}
      broadcastState();
    });

    // Set up channels
    player_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "com.ryanheise.just_audio.methods." + idx,
        &flutter::StandardMethodCodec::GetInstance()
        );

    player_channel_->SetMethodCallHandler(
      [player = this](const auto& call, auto result) {
      player->HandleMethodCall(call, std::move(result));
    });

    event_sink_ = std::make_unique<JustAudioEventSink>(messenger, "com.ryanheise.just_audio.events." + idx);
    data_sink_ = std::make_unique<JustAudioEventSink>(messenger, "com.ryanheise.just_audio.data." + idx);

    /// Set up event callbacks
    // Playback event
    playback_state_token_ = mediaPlayer.PlaybackSession().PlaybackStateChanged([this](auto, const auto& args) -> void {
      if (disposed_) return;
      broadcastState();
    });

    // Player error event
    media_failed_token_ = mediaPlayer.MediaFailed([this](auto, const Playback::MediaPlayerFailedEventArgs& args) -> void {
      if (disposed_) return;
      std::string errorMessage = winrt::to_string(args.ErrorMessage());

      std::cerr << "[just_audio_windows] Media error: " << errorMessage << std::endl;

      auto code = "unknown";

      switch (args.Error()) {
      case Playback::MediaPlayerError::Unknown:
        break;
      case Playback::MediaPlayerError::Aborted:
        code = "aborted";
        break;
      case Playback::MediaPlayerError::NetworkError:
        code = "networkError";
        break;
      case Playback::MediaPlayerError::DecodingError:
        code = "decodingError";
        break;
      case Playback::MediaPlayerError::SourceNotSupported:
        code = "sourceNotSupported";
        break;
      }

      event_sink_->Error(code, errorMessage);
    });

    mediaPlaybackList.MaxPlayedItemsToKeepOpen(2);
    item_changed_token_ = mediaPlaybackList.CurrentItemChanged([this](auto, const auto& args) -> void {
      if (disposed_) return;
      broadcastState();
    });
    item_failed_token_ = mediaPlaybackList.ItemFailed([this](auto, const Playback::MediaPlaybackItemFailedEventArgs& args) -> void {
      if (disposed_) return;
      auto error = winrt::hresult_error(args.Error().ExtendedError());

      auto message = winrt::to_string(error.message());

      std::cerr << "[just_audio_windows] Item error: " << message << std::endl;

      auto code = "unknown";

      switch (args.Error().ErrorCode()) {
      case Playback::MediaPlaybackItemErrorCode::Aborted:
        code = "aborted";
        break;
      case Playback::MediaPlaybackItemErrorCode::NetworkError:
        code = "networkError";
        break;
      case Playback::MediaPlaybackItemErrorCode::DecodeError:
        code = "decodeError";
        break;
      case Playback::MediaPlaybackItemErrorCode::SourceNotSupportedError:
        code = "sourceNotSupportedError";
        break;
      case Playback::MediaPlaybackItemErrorCode::EncryptionError:
        code = "encryptionError";
        break;
      }

      event_sink_->Error(code, message);
    });

    // 注册到全局广播表；构造时若 DspState.enabled 已为 true 则自动走 AudioGraph。
    dsp_epoch_ = md3music::dsp::DspState::Instance().Read().epoch;
    md3music::dsp::DspState::Instance().Register(this, [this]() {
      ApplyDspState();
    });
    ApplyDspState();
  }

  // channel 广播回调：刷新 dsp_active_ 与 EQ 增益；代次变化时释放旧图。
  // 开关切换时做播放接管/交还（DSP↔MediaPlayer），否则中途开关会无声。
  void ApplyDspState() {
    if (disposed_) return;
    auto state = md3music::dsp::DspState::Instance().Read();
    const bool was_active = dsp_active_;
    dsp_active_ = state.enabled;

    if (state.enabled != was_active) {
      bool was_playing = false;
      // 切换前的进度快照：接管/交还都用它续播，避免从头播放。
      int64_t resume_pos_us = 0;
      if (was_active) {
        was_playing = dsp_probe.PlaybackSession().PlaybackState() ==
                      Playback::MediaPlaybackState::Playing;
        resume_pos_us = TO_MICROSECONDS(dsp_probe.PlaybackSession().Position());
      } else {
        was_playing = mediaPlayer.PlaybackSession().PlaybackState() ==
                      Playback::MediaPlaybackState::Playing;
        resume_pos_us = TO_MICROSECONDS(mediaPlayer.PlaybackSession().Position());
      }

      if (!state.enabled) {
        // DSP→正常：同 URI 重建 MediaPlayer 音源并接续进度与播放意图。
        try {
          mediaPlaybackList.Items().Clear();
          auto item = Playback::MediaPlaybackItem(
              MediaSource::CreateFromUri(winrt::Windows::Foundation::Uri(
                  winrt::hstring(dsp_current_uri_))));
          mediaPlaybackList.Items().Append(item);
          mediaPlayer.Source(
              mediaPlaybackList.as<Playback::IMediaPlaybackSource>());
        } catch (...) {}
        // 源尚未 open 时 Position 会抛异常：挂起给 MediaOpened 落位。
        dsp_pending_mp_pos_us_ = resume_pos_us;
        try {
          mediaPlayer.Position(TimeSpan(std::chrono::microseconds(resume_pos_us)));
          dsp_pending_mp_pos_us_ = -1;  // 已 open（如上一首同源），直接落位成功
        } catch (...) {}
        try { dsp_probe.Source(nullptr); } catch (...) {}
        dsp_playing_ = false;
        DspPost([this]() {
          if (disposed_ || !dsp_graph_) return;
          dsp_graph_->Close();
          dsp_graph_.reset();
        });
        if (was_playing) mediaPlayer.Play();
      } else if (!dsp_current_uri_.empty()) {
        // 正常→DSP：建图接管。顺序很关键：
        //   probe.Source → 等 open → Start → Seek（播放中 Seek 才可靠，
        //   Start 前 Seek 会让节点静音，已实测）→ 最后才切掉 MediaPlayer。
        dsp_playing_ = was_playing;
        DspPost([this, uri = dsp_current_uri_, resume_pos_us]() {
          if (disposed_) return;
          if (dsp_graph_) {
            dsp_graph_->Close();
            dsp_graph_.reset();
          }
          dsp_graph_.emplace();
          dsp_graph_->Create(uri, nullptr);
          if (!dsp_graph_->graph) return;
          try {
            dsp_probe.Source(Playback::MediaPlaybackItem(MediaSource::CreateFromUri(
                winrt::Windows::Foundation::Uri(winrt::hstring(uri)))));
          } catch (...) {}
          // 等 probe open（最多 2s），保证 Position/Seek 可用。
          int waited = 0;
          while (waited < 2000) {
            auto pst = dsp_probe.PlaybackSession().PlaybackState();
            if (pst != Playback::MediaPlaybackState::None &&
                pst != Playback::MediaPlaybackState::Opening) break;
            Sleep(50);
            waited += 50;
          }
          try {
            dsp_probe.Position(
                TimeSpan(std::chrono::microseconds(resume_pos_us)));
          } catch (...) {}
          if (dsp_playing_) {
            try { dsp_probe.Play(); } catch (...) {}
            dsp_graph_->StartVerified();
            if (resume_pos_us > 0 && dsp_graph_->input) {
              try {
                dsp_graph_->input.Seek(
                    TimeSpan(std::chrono::microseconds(resume_pos_us)));
              } catch (...) {}
            }
          }
          // 一切就绪后最后切掉 MediaPlayer（期间旧源持续出声）。
          try {
            mediaPlaybackList.Items().Clear();
            mediaPlayer.Source(nullptr);
          } catch (...) {}
        });
      }
    }

    DspPost([this, state]() {
      if (disposed_) return;
      std::fprintf(stderr, "[DSPTRACE] ApplyDspState enabled=%d epoch=%llu/%llu hasGraph=%d\n",
                   state.enabled ? 1 : 0,
                   (unsigned long long)state.epoch, (unsigned long long)dsp_epoch_,
                   dsp_graph_ ? 1 : 0);
      if (state.epoch != dsp_epoch_) {
        dsp_epoch_ = state.epoch;
        if (dsp_graph_) {
          dsp_graph_->Close();
          dsp_graph_.reset();
        }
      }
      if (dsp_graph_) dsp_graph_->ApplyDspStateToEffects();
    });
  }

  void SetAudioDevice(
      winrt::Windows::Devices::Enumeration::DeviceInformation const& device) {
    if (!disposed_) {
      mediaPlayer.AudioDevice(device);
    }
  }

  AudioPlayer::~AudioPlayer() {
    Dispose();
  }

  bool HasPlayerId(std::string playerId) {
    return id == playerId;
  }

  void AudioPlayer::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result
  ) {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());

    std::cerr << "[just_audio_windows] Called " << method_call.method_name() << std::endl;

    if (method_call.method_name().compare("getSourceFormat") == 0) {
      EncodableMap format{{EncodableValue("hasData"), EncodableValue(false)}};
      try {
        // 从当前实际播放项读取源属性，不使用系统混音器的输出格式。
        if (!disposed_) {
          auto source = mediaPlayer.Source();
          Playback::MediaPlaybackItem item{nullptr};
          if (source) {
            if (auto list = source.try_as<Playback::MediaPlaybackList>()) {
              item = list.CurrentItem();
            } else {
              item = source.try_as<Playback::MediaPlaybackItem>();
            }
          }
          if (item) {
            auto tracks = item.AudioTracks();
            const auto selected = tracks.SelectedIndex();
            if (selected >= 0 && static_cast<uint32_t>(selected) < tracks.Size()) {
              auto properties = tracks.GetAt(selected).GetEncodingProperties();
              format[EncodableValue("hasData")] = EncodableValue(properties.SampleRate() > 0);
              format[EncodableValue("sampleRate")] = EncodableValue(static_cast<int32_t>(properties.SampleRate()));
              format[EncodableValue("channelCount")] = EncodableValue(static_cast<int32_t>(properties.ChannelCount()));
              format[EncodableValue("bitsPerSample")] = EncodableValue(static_cast<int32_t>(properties.BitsPerSample()));
              format[EncodableValue("bitrate")] = EncodableValue(static_cast<int32_t>(properties.Bitrate()));
              format[EncodableValue("codec")] = EncodableValue(winrt::to_string(properties.Subtype()));
            }
          }
        }
      } catch (const winrt::hresult_error&) {
        // 尚未就绪/已释放时返回无数据，交由页面稍后补取。
      }
      result->Success(EncodableValue(format));
    } else if (method_call.method_name().compare("load") == 0) {
      const auto* audioSourceData = std::get_if<flutter::EncodableMap>(ValueOrNull(*args, "audioSource"));
      const auto* initialPosition = std::get_if<int>(ValueOrNull(*args, "initialPosition"));
      const auto* initialIndex = std::get_if<int>(ValueOrNull(*args, "initialIndex"));

      try {
        loadSource(*audioSourceData);
      } catch (char* error) {
        return result->Error("load_error", error);
      }

      if (initialIndex != nullptr) {
        seekToItem((uint32_t)*initialIndex);
      }

      if (initialPosition != nullptr) {
        seekToPosition(*initialPosition);
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("play") == 0) {
      if (!disposed_) {
        if (dsp_active_) {
          dsp_playing_ = true;
          try { dsp_probe.Play(); } catch (...) {}
          DspPost([this]() {
            if (disposed_ || !dsp_graph_) return;
            dsp_graph_->StartVerified();
          });
        }
        mediaPlayer.Play();
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("pause") == 0) {
      if (!disposed_) {
        if (dsp_active_) {
          dsp_playing_ = false;
          try { dsp_probe.Pause(); } catch (...) {}
          DspPost([this]() {
            if (disposed_ || !dsp_graph_) return;
            dsp_graph_->Stop();
          });
        }
        mediaPlayer.Pause();
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setVolume") == 0) {
      const auto* volume = std::get_if<double>(ValueOrNull(*args, "volume"));
      if (!volume) {
        return result->Error("volume_error", "volume argument missing");
      }
      float volumeFloat = (float)*volume;
      if (!disposed_) {
        mediaPlayer.Volume(volumeFloat);
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setSpeed") == 0) {
      const auto* speed = std::get_if<double>(ValueOrNull(*args, "speed"));
      if (!speed) {
        return result->Error("speed_error", "speed argument missing");
      }
      float speedFloat = (float)*speed;
      if (!disposed_) {
        mediaPlayer.PlaybackRate(speedFloat);
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setPitch") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setSkipSilence") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setLoopMode") == 0) {
      const auto* loopModePtr = std::get_if<int32_t>(ValueOrNull(*args, "loopMode"));
      if (loopModePtr == nullptr) {
        return result->Error("loopMode_error", "loopMode argument missing");
      }

      if (!disposed_) {
        switch (*loopModePtr) {
        case 0: // off
          mediaPlayer.IsLoopingEnabled(false);
          mediaPlaybackList.AutoRepeatEnabled(false);
          break;
        case 1: // one
          mediaPlayer.IsLoopingEnabled(true);
          mediaPlaybackList.AutoRepeatEnabled(false);
          break;
        case 2: // all
          mediaPlayer.IsLoopingEnabled(false);
          mediaPlaybackList.AutoRepeatEnabled(true);
          break;
        default:
          return result->Error("loopMode_error", "loopMode is invalid");
        }
      }  
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setShuffleMode") == 0) {
      const auto* shuffleModePtr = std::get_if<int32_t>(ValueOrNull(*args, "shuffleMode"));
      if (shuffleModePtr == nullptr) {
        return result->Error("shuffleMode_error", "shuffleMode argument missing");
      }

      switch (*shuffleModePtr) {
      case 0: // none
        mediaPlaybackList.ShuffleEnabled(false);
        break;
      case 1: // all
        mediaPlaybackList.ShuffleEnabled(true);
        break;
      default:
        return result->Error("shuffleMode_error", "shuffleMode is invalid");
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setShuffleOrder") == 0) {
      const auto* source = std::get_if<flutter::EncodableMap>(ValueOrNull(*args, "audioSource"));

      setShuffleOrder(*source);

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setAutomaticallyWaitsToMinimizeStalling") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setCanUseNetworkResourcesForLiveStreamingWhilePaused") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setPreferredPeakBitRate") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("seek") == 0) {
      const auto* index = std::get_if<int>(ValueOrNull(*args, "index"));
      if (index != nullptr) {
        seekToItem((uint32_t)*index);
      }

      const auto* position = ValueOrNull(*args, "position");

      if (position != nullptr && !position->IsNull()) {
        seekToPosition((*position).LongValue());
      }
      
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("concatenatingInsertAll") == 0) {
      const auto* index = std::get_if<int>(ValueOrNull(*args, "index"));
      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(*args, "children"));

      auto items = mediaPlaybackList.Items();

      int currentIndex = *index;
      for (auto& child : *children) {
        const auto* childMap = std::get_if<flutter::EncodableMap>(&child);
        auto mediaSource = createMediaPlaybackItem(*childMap);
        auto item = Playback::MediaPlaybackItem(mediaSource);

        items.InsertAt(currentIndex, item);
        currentIndex++;
      }

      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("concatenatingRemoveRange") == 0) {
      const auto* start = std::get_if<int>(ValueOrNull(*args, "startIndex"));
      const auto* end = std::get_if<int>(ValueOrNull(*args, "endIndex")); // Does not include this item

      int startIndex = *start;
      int endIndex = *end;

      auto items = mediaPlaybackList.Items();
      auto size = (int) items.Size();

      if (endIndex > startIndex && startIndex >= 0 && endIndex <= size) {
        int count = endIndex - startIndex;

        for (int i = 0; i < count; i++) {
          // The item to remove should always be located at `startIndex`.
          items.RemoveAt(startIndex);
        }
        return result->Success(flutter::EncodableMap());
      } else {
        return result->Error("concatenatingRemoveRange_error", "invalid range");
      }
    } else if (method_call.method_name().compare("concatenatingMove") == 0) {
      const auto* from = std::get_if<int>(ValueOrNull(*args, "currentIndex"));
      const auto* to = std::get_if<int>(ValueOrNull(*args, "newIndex"));

      auto items = mediaPlaybackList.Items();
      auto size = (int) items.Size();

      int currentIndex = *from;
      int newIndex = *to;

      auto item = items.GetAt(currentIndex);

      if (currentIndex >= size || newIndex > size) {
        return result->Error("concatenatingMove_error", "index out of bounds");
      }

      items.RemoveAt(currentIndex);
      items.InsertAt(newIndex, item);
      // Do nothing if the two equals
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("setAndroidAudioAttributes") == 0) {
      // Windows 无 Android audio attributes 语义；仅触发一次实例状态同步。
      md3music::dsp::DspState::Instance().NotifyAll();
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("audioEffectSetEnabled") == 0) {
      // just_audio 内部用，与本项目音效无关，保持空返回避免误触。
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidLoudnessEnhancerSetTargetGain") == 0) {
      // Windows 无响度增强等价实现；保持接口透明并同步一次实例状态。
      md3music::dsp::DspState::Instance().NotifyAll();
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidEqualizerGetParameters") == 0) {
      auto state = md3music::dsp::DspState::Instance().Read();
      flutter::EncodableList levels;
      for (double db : state.eq_db) {
        levels.emplace_back(flutter::EncodableValue(
            static_cast<int64_t>(std::llround(db * 100.0))));
      }
      flutter::EncodableMap params;
      params[flutter::EncodableValue("bandCount")] = flutter::EncodableValue(4);
      params[flutter::EncodableValue("bandLevels")] =
          flutter::EncodableValue(std::move(levels));
      result->Success(flutter::EncodableValue(std::move(params)));
    } else if (method_call.method_name().compare("androidEqualizerBandSetGain") == 0) {
      if (args) {
        const auto* band = std::get_if<int32_t>(ValueOrNull(*args, "band"));
        const auto* level = std::get_if<int32_t>(ValueOrNull(*args, "level"));
        if (band && level) {
          md3music::dsp::DspState::Instance().SetEqBand(
              *band, static_cast<double>(*level) / 100.0);
        }
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("dispose") == 0) {
      Dispose();
      result->Success(flutter::EncodableMap());
    } else {
      result->NotImplemented();
    }
  }

  /// 递归提取可播放 URI（progressive/dash/hls）。
  /// App 的 source 结构不总是平铺：切歌/续播时可能包一层 clipping（child 嵌套），
  /// 整表是 concatenating（children 列表）。此前只认平铺 progressive，
  /// 提取失败会让 DSP 分支回落普通路径 → 音源重置 + 自动暂停（已实测）。
  std::string ExtractPlayableUri(const flutter::EncodableMap& source,
                                        int depth = 0) {
    if (depth > 4) return "";
    const std::string* type =
        std::get_if<std::string>(ValueOrNull(source, "type"));
    if (!type) return "";
    if (*type == "progressive" || *type == "dash" || *type == "hls") {
      const auto* v = ValueOrNull(source, "uri");
      if (!v) {
        std::fprintf(stderr, "[DSPTRACE] extract: type=%s no uri key\n",
                     type->c_str());
        return "";
      }
      const std::string* uri = std::get_if<std::string>(v);
      if (!uri) {
        std::fprintf(stderr, "[DSPTRACE] extract: type=%s uri not a string\n",
                     type->c_str());
        return "";
      }
      return *uri;
    }
    if (*type == "clipping") {
      const auto* child =
          std::get_if<flutter::EncodableMap>(ValueOrNull(source, "child"));
      if (child) return ExtractPlayableUri(*child, depth + 1);
    }
    if (*type == "concatenating") {
      const auto* children =
          std::get_if<flutter::EncodableList>(ValueOrNull(source, "children"));
      if (children) {
        for (auto& child : *children) {
          const auto* childMap = std::get_if<flutter::EncodableMap>(&child);
          if (!childMap) continue;
          auto uri = ExtractPlayableUri(*childMap, depth + 1);
          if (!uri.empty()) return uri;
        }
      }
    }
    std::fprintf(stderr, "[DSPTRACE] extract miss: type=%s depth=%d\n",
                 type->c_str(), depth);
    return "";
  }

  void AudioPlayer::loadSource(const flutter::EncodableMap& source) {
    if(disposed_) return;
    // 无论 DSP 是否开启，都提取当前可播放 URI（递归解包 clipping/concatenating），
    // 供 AudioGraph 建图与「开 EQ 接管」使用。
    std::string track_uri = ExtractPlayableUri(source);
    if (!track_uri.empty()) {
      dsp_current_uri_ = TO_WIDESTRING(PrepareMediaSourceUri(track_uri));
    }

    if (dsp_active_) {
      // 音效开启：只走 AudioGraph；App 每次切歌上层都会重新 load（children=1），
      // 整表 gapless 建图为 Phase 2 范围。
      if (!track_uri.empty()) {
        // 保留播放意图：切歌时 Dart 不一定重发 play（just_audio 认为自己仍在
        // 播放），这里清掉会导致新图建好后没人 Start → 切歌无声（已实测）。
        // 顺序与 handover 对齐：probe.Source → 等 open → Play → StartVerified →
        // **最后**才清 MediaPlayer（图确认产出后再切，期间旧源持续出声）。
        // 若先清 MP 再 Start，MP 会话销毁与图启动竞态会导致图静音（已实测）。
        DspPost([this, uri = dsp_current_uri_]() {
          if (disposed_) return;
          bool graph_ready = false;
          if (dsp_graph_ && dsp_graph_->graph) {
            // 图复用：切歌只换输入节点，不销毁图（重建图会静音，已实测）。
            graph_ready = dsp_graph_->RebuildInput(uri);
            if (graph_ready) {
              try {
                dsp_probe.Source(Playback::MediaPlaybackItem(MediaSource::CreateFromUri(
                    winrt::Windows::Foundation::Uri(winrt::hstring(uri)))));
              } catch (...) {}
              int waited = 0;
              while (waited < 2000) {
                auto pst = dsp_probe.PlaybackSession().PlaybackState();
                if (pst != Playback::MediaPlaybackState::None &&
                    pst != Playback::MediaPlaybackState::Opening) break;
                Sleep(50);
                waited += 50;
              }
              if (dsp_playing_) {
                try { dsp_probe.Play(); } catch (...) {}
                dsp_graph_->StartVerified();
              }
              try {
                mediaPlaybackList.Items().Clear();
                mediaPlayer.Source(nullptr);
              } catch (...) {}
            }
          }
          if (!graph_ready) {
            // 图不存在或 RebuildInput 失败：完整重建（含首次建图）。
            if (dsp_graph_) {
              dsp_graph_->Close();
              dsp_graph_.reset();
            }
            dsp_graph_.emplace();
            dsp_graph_->Create(uri, nullptr);
            if (dsp_graph_->graph) {
              try {
                dsp_probe.Source(Playback::MediaPlaybackItem(MediaSource::CreateFromUri(
                    winrt::Windows::Foundation::Uri(winrt::hstring(uri)))));
              } catch (...) {}
              int waited = 0;
              while (waited < 2000) {
                auto pst = dsp_probe.PlaybackSession().PlaybackState();
                if (pst != Playback::MediaPlaybackState::None &&
                    pst != Playback::MediaPlaybackState::Opening) break;
                Sleep(50);
                waited += 50;
              }
              if (dsp_playing_) {
                try { dsp_probe.Play(); } catch (...) {}
                dsp_graph_->StartVerified();
              }
              try {
                mediaPlaybackList.Items().Clear();
                mediaPlayer.Source(nullptr);
              } catch (...) {}
            } else {
              std::fprintf(stderr, "[DSPTRACE] create failed -> keep MP source\n");
            }
          }
        });
        // 平台线程先广播一次，避免 Dart 端 setAudioSource 等不到状态。
        broadcastState();
        return;
      }
      std::fprintf(stderr, "[DSPTRACE] loadSource DSP no playable uri -> fallback\n");
    }
    const std::string* type =
        std::get_if<std::string>(ValueOrNull(source, "type"));
    auto items = mediaPlaybackList.Items();
    items.Clear(); // Always clear the list since we are resetting

    if (type->compare("concatenating") == 0) {
      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(source, "children"));

      for (auto& child : *children) {
        const auto* childMap = std::get_if<flutter::EncodableMap>(&child);
        auto item = createMediaPlaybackItem(*childMap);
        items.Append(item);
      }

      mediaPlayer.Source(mediaPlaybackList.as<Playback::IMediaPlaybackSource>());
    } else {
      mediaPlayer.Source(createMediaPlaybackItem(source).as<Playback::IMediaPlaybackSource>());
    }
  }

  /**
  * Creates a single MediaPlaybackItem, which can be used directly or inside a list.
  */
  Playback::MediaPlaybackItem AudioPlayer::createMediaPlaybackItem(const flutter::EncodableMap& source) const& {
    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));

    if (type->compare("clipping") == 0) {
      const auto* child = std::get_if<flutter::EncodableMap>(ValueOrNull(source, "child"));
      auto childSource = createMediaSource(*child);

      const auto* startUs = std::get_if<int32_t>(ValueOrNull(*child, "start"));
      const auto* endUs = std::get_if<int32_t>(ValueOrNull(*child, "end"));

      auto start = 0; // Default to 0
      if (startUs != nullptr) {
        start = *startUs;
      }

      if (endUs != nullptr) {
        // We have a duration limit
        auto duration = *endUs - start;

        return Playback::MediaPlaybackItem(
          childSource,
          TimeSpan(std::chrono::microseconds(start)),
          TimeSpan(std::chrono::microseconds(duration))
        );
      } else {
        return Playback::MediaPlaybackItem(
          childSource,
          TimeSpan(std::chrono::microseconds(start))
        );
      }
    } else {
      return Playback::MediaPlaybackItem(createMediaSource(source));
    }
  }

  /**
  * Creates a single MediaSource.
  */
  MediaSource AudioPlayer::createMediaSource(const flutter::EncodableMap& source) const {
      const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));
      if (type->compare("progressive") == 0 || type->compare("dash") == 0 || type->compare("hls") == 0) {
          const auto* uri = std::get_if<std::string>(ValueOrNull(source, "uri"));
          return MediaSource::CreateFromUri(
              Uri(TO_WIDESTRING(PrepareMediaSourceUri(*uri)))
          );
      }
      else {
          throw std::invalid_argument("Source is unsupported or can not be nested: " + *type);
      }
  }


  void AudioPlayer::broadcastState() {
    try {
      broadcastPlaybackEvent();
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Broadcast event error: " << winrt::to_string(ex.message()) << std::endl;
    }

    try {
      broadcastDataEvent();
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Broadcast data error: " << winrt::to_string(ex.message()) << std::endl;
    }
  }

  void AudioPlayer::broadcastPlaybackEvent() {
    if(disposed_) return;
    // DSP 模式：状态/时长/进度来自静音时钟播放器（mediaPlayer 无源恒为 0）。
    auto session = dsp_active_ ? dsp_probe.PlaybackSession()
                               : mediaPlayer.PlaybackSession();

    auto eventData = flutter::EncodableMap();

    auto duration = TO_MICROSECONDS(session.NaturalDuration());
    if (duration > 0) dsp_last_duration_us_ = duration;

    auto now = std::chrono::system_clock::now();

    // Try to get the buffering progress or use 1 if an error occurs
    double bufferingProgress;
    try
    {
      bufferingProgress = session.BufferingProgress();
    }
    catch (...)
    {
      // If an error occurs, log it and use 1 as the buffering progress
      std::cerr << "[just_audio_windows]: Broadcast playback event error: Error accessing BufferingProgress. Using default value of 1." << std::endl;
      bufferingProgress = 1;
    }

    int st;
    int64_t out_duration = duration;
    int64_t out_position = TO_MICROSECONDS(session.Position());
    if (dsp_active_) {
      // probe 尚未打开（建图过渡期）：沿用上次时长，避免 UI 时长闪 0。
      if (duration <= 0) out_duration = dsp_last_duration_us_.load();
      // 状态映射基于 probe 会话自身；注意不能用 processingState()——它内部
      // 读空源的 mediaPlayer 会话，0==0 恒判 completed。
      auto pst = session.PlaybackState();
      if (pst == Playback::MediaPlaybackState::None) {
        st = dsp_playing_ ? 3 : 0; // 过渡期有播放意图 → ready
      } else if (pst == Playback::MediaPlaybackState::Opening) {
        st = 1; // loading
      } else if (pst == Playback::MediaPlaybackState::Buffering) {
        st = 2; // buffering
      } else if (out_duration > 0 && out_position >= out_duration) {
        st = 4; // completed
      } else {
        st = 3; // ready
      }
    } else {
      st = processingState(session.PlaybackState());
    }
    eventData[flutter::EncodableValue("processingState")] = flutter::EncodableValue(st);
    eventData[flutter::EncodableValue("updatePosition")] = flutter::EncodableValue(out_position); //int
    eventData[flutter::EncodableValue("updateTime")] = flutter::EncodableValue(TO_MILLISECONDS(now.time_since_epoch())); //int
    eventData[flutter::EncodableValue("bufferedPosition")] = flutter::EncodableValue((int64_t)(out_duration * bufferingProgress)); //int
    eventData[flutter::EncodableValue("duration")] = flutter::EncodableValue(out_duration); //int

    if (mediaPlaybackList.Items().Size() > 0) {
      int64_t currentIndex = mediaPlaybackList.CurrentItemIndex();
      if (currentIndex != 4294967295) { // UINT32_MAX - 1
        eventData[flutter::EncodableValue("currentIndex")] = flutter::EncodableValue(currentIndex); //int
      }
    } else {
      eventData[flutter::EncodableValue("currentIndex")] = flutter::EncodableValue(0); //int
    }

    event_sink_->Success(eventData);
  }

  int AudioPlayer::processingState(Playback::MediaPlaybackState state) {
    if(disposed_) return 0;
    auto session = mediaPlayer.PlaybackSession();

    if (state == Playback::MediaPlaybackState::None) {
      return 0; //idle
    } else if (state == Playback::MediaPlaybackState::Opening) {
      return 1; //loading
    } else if (state == Playback::MediaPlaybackState::Buffering) {
      return 2;//buffering
    } else if (session.Position().count() == session.NaturalDuration().count()) {
      return 4; //completed
    }
    return 3; //ready
  }

  void AudioPlayer::broadcastDataEvent() {
    if(disposed_) return;
    // DSP 模式：playing 状态同样来自静音时钟播放器会话。
    auto session = dsp_active_ ? dsp_probe.PlaybackSession()
                               : mediaPlayer.PlaybackSession();
    auto eventData = flutter::EncodableMap();

    auto isPlaying = session.PlaybackState() == Playback::MediaPlaybackState::Playing;

    eventData[flutter::EncodableValue("playing")] = flutter::EncodableValue(isPlaying);
    eventData[flutter::EncodableValue("volume")] = flutter::EncodableValue(mediaPlayer.Volume());
    eventData[flutter::EncodableValue("speed")] = flutter::EncodableValue(session.PlaybackRate());
    eventData[flutter::EncodableValue("loopMode")] = flutter::EncodableValue(getLoopMode());
    eventData[flutter::EncodableValue("shuffleMode")] = flutter::EncodableValue(getShuffleMode());

    data_sink_->Success(eventData);
  }

  int AudioPlayer::getLoopMode() {
    if (mediaPlayer.IsLoopingEnabled()) {
      // one
      return 1;
    } else if (mediaPlaybackList.AutoRepeatEnabled()) {
      // all
      return 2;
    } else {
      // pff
      return 0;
    }
  }

  int AudioPlayer::getShuffleMode() {
    // TODO(bdlukaa): playlists
    return 0;
  }

  flutter::EncodableMap AudioPlayer::collectIcyMetadata() {
    auto icyData = flutter::EncodableMap();

    // TODO: Icy Metadata
    // mediaPlayer.PlaybackMediaMarkers();

    return icyData;
  }

  /// Transforms a num into positive, if negative
  int negativeToPositive(int num) {
    if (num < 0) { return num * (-1); }
    return num;
  }

  void AudioPlayer::seekToItem(uint32_t index) {
    if (index >= mediaPlaybackList.Items().Size()) {
      return;
    }

    try {
      mediaPlaybackList.MoveTo(index);
    } catch (winrt::hresult_error const& ex) {
      std::cerr << "[just_audio_windows] Failed to seek to item: " << winrt::to_string(ex.message()) << std::endl;
    }

    broadcastState();
  }

  void AudioPlayer::seekToPosition(int64_t microseconds) {
    if(disposed_) return;
    // DSP 模式：MediaSourceAudioInputNode 原生支持 Seek（官方文档确认），
    // 时钟播放器与图输入节点一起跳转，音频真正落在目标位置。
    if (dsp_active_) {
      try {
        dsp_probe.Position(TimeSpan(std::chrono::microseconds(microseconds)));
      } catch (...) {}
      DspPost([this, microseconds]() {
        if (disposed_ || !dsp_graph_ || !dsp_graph_->input) return;
        try {
          dsp_graph_->input.Seek(TimeSpan(std::chrono::microseconds(microseconds)));
        } catch (...) {}
      });
      broadcastState();
      return;
    }
    mediaPlayer.Position(TimeSpan(std::chrono::microseconds(microseconds)));

    broadcastState();
  }

  void AudioPlayer::setShuffleOrder(const flutter::EncodableMap& source) {
    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));
    // const std::string* id = std::get_if<std::string>(ValueOrNull(source, "id"));

    if (type->compare("concatenating") == 0) {
      const auto* shuffleOrder = std::get_if<flutter::EncodableList>(ValueOrNull(source, "shuffleOrder"));

      // A copy of mediaPlaybackList.Items()
      std::vector<Playback::MediaPlaybackItem> itemsCopy {};
      for (auto item : mediaPlaybackList.Items()) {
        itemsCopy.push_back(item);
      }

      // then we apply the suffling to itemsCopy
      for (int i = 0; i < ((int) shuffleOrder->size()); i++) {
        auto item = itemsCopy.at(i);

        auto insertAt = (*shuffleOrder).at(i).LongValue();

        // delete the item at i
        itemsCopy.erase(itemsCopy.begin() + i);
        itemsCopy.insert(itemsCopy.begin() + insertAt, item);
      }

      // and finnaly provide it to the player list
      mediaPlaybackList.SetShuffledItems(itemsCopy);

      itemsCopy.clear();
      itemsCopy.shrink_to_fit();

      const auto* children = std::get_if<flutter::EncodableList>(ValueOrNull(source, "children"));
      for (auto child : *children) {
        setShuffleOrder(std::get<flutter::EncodableMap>(child));
      }
    } else if (type->compare("looping") == 0) {
      const flutter::EncodableMap* child = std::get_if<flutter::EncodableMap>(ValueOrNull(source, "child"));
      setShuffleOrder(*child);
    } else {
      // can not shuffle a single-audio media source
    }
  }

};
