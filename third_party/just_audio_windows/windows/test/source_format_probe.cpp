// Windows 原生集成回归：传入 192kHz/24-bit FLAC 和 48kHz/24-bit 立体声 WAV。
// 仅装载，不发声；直接调用插件的实际方法分支，不依赖运行中的 Flutter 引擎。
#include <iostream>
#include <future>
#include <atomic>
#include <flutter/method_result_functions.h>
#include "player.hpp"

class Messenger : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply = nullptr) const override {}
  void SetMessageHandler(const std::string&,
                         flutter::BinaryMessageHandler) override {}
};

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  Messenger messenger;
  AudioPlayer player("format_probe", &messenger);
  player.mediaPlayer.AutoPlay(false);
  int failures = 0;
  auto query = [&](int rate, int bits, int channels) {
    auto result = std::make_unique<flutter::MethodResultFunctions<>>(
        [&](const EncodableValue* value) {
          const auto& map = std::get<EncodableMap>(*value);
          const bool hasData = std::get<bool>(*ValueOrNull(map, "hasData"));
          auto number = [&](const char* key) {
            const auto* v = ValueOrNull(map, key);
            return v ? static_cast<int>(v->LongValue()) : 0;
          };
          std::cout << "FORMAT hasData=" << hasData
                    << " sampleRate=" << number("sampleRate")
                    << " bitsPerSample=" << number("bitsPerSample")
                    << " channelCount=" << number("channelCount") << std::endl;
          if (hasData != (rate > 0) || number("sampleRate") != rate ||
              number("bitsPerSample") != bits || number("channelCount") != channels)
            ++failures;
        },
        [&](const std::string& code, const std::string&, const EncodableValue*) {
          std::cout << "ERROR=" << code << std::endl;
          ++failures;
        },
        [&] { std::cout << "NOT_IMPLEMENTED" << std::endl; ++failures; });
    player.HandleMethodCall(flutter::MethodCall<>("getSourceFormat", nullptr),
                            std::move(result));
  };
  query(0, 0, 0);
  for (int i = 1; i <= 2; ++i) {
    std::atomic<bool> done{false};
    std::promise<bool> loaded;
    auto ready = loaded.get_future();
    auto opened = player.mediaPlayer.MediaOpened([&](auto&&, auto&&) {
      if (!done.exchange(true)) loaded.set_value(true);
    });
    auto failed = player.mediaPlayer.MediaFailed([&](auto&&, auto&&) {
      if (!done.exchange(true)) loaded.set_value(false);
    });
    std::wstring path = L"file:///" + std::wstring(argv[i]);
    for (auto& c : path) if (c == L'\\') c = L'/';
    auto source = MediaSource::CreateFromUri(Uri(winrt::to_hstring(
        PrepareMediaSourceUri(winrt::to_string(path)))));
    auto item = Playback::MediaPlaybackItem(source);
    if (i == 1) {
      player.mediaPlaybackList.Items().Append(item);
      player.mediaPlayer.Source(player.mediaPlaybackList);
    } else {
      player.mediaPlayer.Source(item);
    }
    if (ready.wait_for(std::chrono::seconds(15)) != std::future_status::ready ||
        !ready.get()) {
      std::cout << "LOAD_FAILED file=" << i << std::endl;
      ++failures;
    } else {
      query(i == 1 ? 192000 : 48000, 24, 2);
    }
    done.store(true);
    player.mediaPlayer.MediaOpened(opened);
    player.mediaPlayer.MediaFailed(failed);
  }
  player.HandleMethodCall(flutter::MethodCall<>("dispose", nullptr),
                          std::make_unique<flutter::MethodResultFunctions<>>(
                              nullptr, nullptr, nullptr));
  query(0, 0, 0);
  std::cout << "FAILURES=" << failures << std::endl;
  return failures == 0 ? 0 : 1;
}
