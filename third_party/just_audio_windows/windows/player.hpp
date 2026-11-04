#pragma comment(lib, "windowsapp")

#include <chrono>

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
    mediaPlaybackList.CurrentItemChanged(item_changed_token_);
    mediaPlaybackList.ItemFailed(item_failed_token_);
    player_channel_->SetMethodCallHandler(nullptr);
    event_sink_.reset();
    data_sink_.reset();
    mediaPlayer.Close();
  }
public:
  std::string id;
  Playback::MediaPlayer mediaPlayer{};
  Playback::MediaPlaybackList mediaPlaybackList{};

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
        mediaPlayer.Play();
      }
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("pause") == 0) {
      if (!disposed_) {
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
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("audioEffectSetEnabled") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidLoudnessEnhancerSetTargetGain") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidEqualizerGetParameters") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("androidEqualizerBandSetGain") == 0) {
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("dispose") == 0) {
      Dispose();
      result->Success(flutter::EncodableMap());
    } else {
      result->NotImplemented();
    }
  }

  void AudioPlayer::loadSource(const flutter::EncodableMap& source) const& {
    if(disposed_) return;
    auto items = mediaPlaybackList.Items();
    items.Clear(); // Always clear the list since we are resetting

    const std::string* type = std::get_if<std::string>(ValueOrNull(source, "type"));

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
    auto session = mediaPlayer.PlaybackSession();

    auto eventData = flutter::EncodableMap();

    auto duration = TO_MICROSECONDS(session.NaturalDuration());

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

    eventData[flutter::EncodableValue("processingState")] = flutter::EncodableValue(processingState(session.PlaybackState()));
    eventData[flutter::EncodableValue("updatePosition")] = flutter::EncodableValue(TO_MICROSECONDS(session.Position())); //int
    eventData[flutter::EncodableValue("updateTime")] = flutter::EncodableValue(TO_MILLISECONDS(now.time_since_epoch())); //int
    eventData[flutter::EncodableValue("bufferedPosition")] = flutter::EncodableValue((int64_t)(duration * bufferingProgress)); //int
    eventData[flutter::EncodableValue("duration")] = flutter::EncodableValue(duration); //int

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
    auto session = mediaPlayer.PlaybackSession();
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
