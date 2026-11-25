#pragma comment(lib, "windowsapp")

#include "include/just_audio_windows/just_audio_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Media.Devices.h>

#include <map>
#include <memory>
#include <mutex>
#include <iostream>
#include <sstream>

#include "dsp_effects.hpp"
#include "player.hpp"

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Devices::Enumeration::DeviceInformation;
using winrt::Windows::Devices::Enumeration::DeviceInformationUpdate;
using winrt::Windows::Devices::Enumeration::DeviceWatcher;
using winrt::Windows::Media::Devices::AudioDeviceRole;
using winrt::Windows::Media::Devices::MediaDevice;

namespace {

// static std::unordered_map<std::string, AudioPlayer> players;
std::vector<std::unique_ptr<AudioPlayer>> players_;

// --- Windows DSP MethodChannel 兼容层 ---
// 参照 Android ViperMasterProcessor.INSTANCES：channel handler 写全局 DspState
// 并广播给所有 AudioPlayer 实例，避免「开关已开但仍在 MediaPlayer」的假成功。

// Dart 的 int 在 StandardMethodCodec 下可能为 int32/int64，统一读取。
bool ReadInt(const flutter::EncodableValue* value, int64_t* out) {
  if (!value) return false;
  if (auto p = std::get_if<int64_t>(value)) { *out = *p; return true; }
  if (auto p = std::get_if<int32_t>(value)) { *out = *p; return true; }
  return false;
}

bool ReadDouble(const flutter::EncodableValue* value, double* out) {
  if (!value) return false;
  if (auto p = std::get_if<double>(value)) { *out = *p; return true; }
  if (auto p = std::get_if<int64_t>(value)) { *out = static_cast<double>(*p); return true; }
  if (auto p = std::get_if<int32_t>(value)) { *out = static_cast<double>(*p); return true; }
  return false;
}

// 与 equalizer_service.dart 的 customPresets 键顺序一致（9 个），值为 5 区 dB。
const char* const kEqPresetNames[] = {
    "正常", "流行", "摇滚", "爵士", "古典",
    "重低音", "高音增强", "人声", "电子",
};
constexpr std::array<std::array<double, 5>, 9> kEqPresetDb = {{
    {0, 0, 0, 0, 0},      // 正常
    {-1, 2, 4, 2, -1},    // 流行
    {4, -1, 0, 3, 4},     // 摇滚
    {3, 2, -1, 1, 3},     // 爵士
    {4, 0, -1, 2, 4},     // 古典
    {6, 0, 0, 0, 0},      // 重低音
    {0, 0, 0, 4, 6},      // 高音增强
    {-2, 2, 4, 3, -1},    // 人声
    {4, -2, 0, 3, 5},     // 电子
}};

flutter::EncodableMap BandInfoFromSnapshot(
    const md3music::dsp::DspState::Snapshot& state) {
  // 实测 4 段中心频率，单位 milliHz（Task 0 Spike 报告）。
  flutter::EncodableList centers;
  for (int64_t hz : {100000LL, 800000LL, 2000000LL, 10000000LL}) {
    centers.emplace_back(flutter::EncodableValue(hz));
  }
  flutter::EncodableList levels;
  for (double db : state.eq_db) {
    levels.emplace_back(
        flutter::EncodableValue(static_cast<int64_t>(std::lround(db * 100.0))));
  }
  flutter::EncodableMap info;
  info[flutter::EncodableValue("bandCount")] = flutter::EncodableValue(4);
  info[flutter::EncodableValue("minLevel")] = flutter::EncodableValue(-1800);
  info[flutter::EncodableValue("maxLevel")] = flutter::EncodableValue(1800);
  info[flutter::EncodableValue("centerFreqs")] =
      flutter::EncodableValue(std::move(centers));
  info[flutter::EncodableValue("bandLevels")] =
      flutter::EncodableValue(std::move(levels));
  return info;
}

void HandleViperChannel(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) {
    result->Error("bad_args", "expected a map argument");
    return;
  }
  if (call.method_name().compare("setEnabled") == 0) {
    const auto* enabled = std::get_if<bool>(ValueOrNull(*args, "enabled"));
    if (!enabled) {
      result->Error("bad_args", "enabled argument missing");
      return;
    }
    md3music::dsp::DspState::Instance().SetEnabled(*enabled);
    result->Success();
    return;
  }
  if (call.method_name().compare("setEqGains") == 0) {
    const auto* gains =
        std::get_if<flutter::EncodableList>(ValueOrNull(*args, "gains"));
    if (!gains || gains->size() != 10) {
      result->Error("bad_args", "gains must be a 10-element list");
      return;
    }
    std::array<double, 10> values{};
    for (size_t i = 0; i < values.size(); ++i) {
      if (!ReadDouble(&(*gains)[i], &values[i])) {
        result->Error("bad_args", "gains must contain numbers");
        return;
      }
    }
    md3music::dsp::DspState::Instance().SetViperGains(values);
    result->Success();
    return;
  }
  result->NotImplemented();
}

void HandleEqChannel(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using md3music::dsp::DspState;
  const auto method = call.method_name();
  if (method.compare("init") == 0 || method.compare("getBandInfo") == 0) {
    // Windows 无 audio session 概念，audioSessionId 参数忽略。
    result->Success(flutter::EncodableValue(
        BandInfoFromSnapshot(DspState::Instance().Read())));
    return;
  }
  if (method.compare("setEnabled") == 0) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    const auto* enabled =
        args ? std::get_if<bool>(ValueOrNull(*args, "enabled")) : nullptr;
    if (!enabled) {
      result->Error("bad_args", "enabled argument missing");
      return;
    }
    DspState::Instance().SetEnabled(*enabled);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method.compare("setBandLevel") == 0) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int64_t band = 0;
    int64_t level = 0;
    if (!args || !ReadInt(ValueOrNull(*args, "band"), &band) ||
        !ReadInt(ValueOrNull(*args, "level"), &level)) {
      result->Error("bad_args", "band/level arguments missing");
      return;
    }
    DspState::Instance().SetEqBand(static_cast<int>(band),
                                   static_cast<double>(level) / 100.0);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method.compare("getPresets") == 0) {
    flutter::EncodableList names;
    for (const char* name : kEqPresetNames) {
      names.emplace_back(flutter::EncodableValue(std::string(name)));
    }
    result->Success(flutter::EncodableValue(std::move(names)));
    return;
  }
  if (method.compare("usePreset") == 0) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int64_t preset = 0;
    if (!args || !ReadInt(ValueOrNull(*args, "preset"), &preset)) {
      result->Error("bad_args", "preset argument missing");
      return;
    }
    if (preset >= 0 && preset < 9) {
      auto db4 = md3music::dsp::Downsample5To4(
          kEqPresetDb[static_cast<size_t>(preset)]);
      DspState::Instance().SetEqPreset(static_cast<int>(preset), db4);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method.compare("getCurrentPreset") == 0) {
    result->Success(
        flutter::EncodableValue(DspState::Instance().Read().preset_index));
    return;
  }
  if (method.compare("release") == 0) {
    DspState::Instance().RequestRelease();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

class JustAudioWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  JustAudioWindowsPlugin();

  virtual ~JustAudioWindowsPlugin();

 private:
  void HandleAudioOutputMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      flutter::BinaryMessenger* messenger);
  // Loops through cameras and returns camera
  // with matching camera_id or nullptr.
  AudioPlayer* GetPlayerByPlayerId(std::string id);

  // Disposes camera by camera id.
  void DisposePlayerByPlayerId(std::string id);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> output_channel_;
  std::string selected_output_device_id_;
  std::mutex output_devices_mutex_;
  DeviceWatcher output_device_watcher_{nullptr};
  winrt::event_token output_device_added_token_{};
  winrt::event_token output_device_removed_token_{};
};

// static
void JustAudioWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.ryanheise.just_audio.methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<JustAudioWindowsPlugin>();

  plugin->output_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "md3music/windows_audio_output",
          &flutter::StandardMethodCodec::GetInstance());
  plugin->output_channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleAudioOutputMethodCall(call, std::move(result));
      });

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get(), messenger_pointer = registrar->messenger()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result), std::move(messenger_pointer));
      });

  // 两个 channel 名必须与 Dart 侧逐字一致；handler 只写 DspState 并广播。
  auto eq_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.md3music.md3music/equalizer",
      &flutter::StandardMethodCodec::GetInstance());
  eq_channel->SetMethodCallHandler([](const auto &call, auto result) {
    HandleEqChannel(call, std::move(result));
  });
  auto viper_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.md3music.md3music/viper_dsp",
      &flutter::StandardMethodCodec::GetInstance());
  viper_channel->SetMethodCallHandler([](const auto &call, auto result) {
    HandleViperChannel(call, std::move(result));
  });

  registrar->AddPlugin(std::move(plugin));
}

JustAudioWindowsPlugin::JustAudioWindowsPlugin() {
  try {
    output_device_watcher_ =
        DeviceInformation::CreateWatcher(MediaDevice::GetAudioRenderSelector());
    output_device_added_token_ = output_device_watcher_.Added(
        [this](DeviceWatcher const &, DeviceInformation const &device) {
          try {
            std::lock_guard<std::mutex> lock(output_devices_mutex_);
            if (selected_output_device_id_ != winrt::to_string(device.Id())) return;
            for (const auto &player : players_) {
              player->SetAudioDevice(device);
            }
            std::cerr << "[windows_audio_output] endpoint reconnected: "
                      << winrt::to_string(device.Name()) << std::endl;
          } catch (const winrt::hresult_error &error) {
            std::cerr << "[windows_audio_output] reconnect failed: "
                      << winrt::to_string(error.message()) << std::endl;
          }
        });
    output_device_removed_token_ = output_device_watcher_.Removed(
        [this](DeviceWatcher const &, DeviceInformationUpdate const &device) {
          std::lock_guard<std::mutex> lock(output_devices_mutex_);
          if (selected_output_device_id_ != winrt::to_string(device.Id())) return;
          for (const auto &player : players_) {
            player->SetAudioDevice(DeviceInformation{nullptr});
          }
          std::cerr << "[windows_audio_output] endpoint disconnected; "
                       "using system default until it returns"
                    << std::endl;
        });
    output_device_watcher_.Start();
  } catch (const winrt::hresult_error &error) {
    std::cerr << "[windows_audio_output] device watcher unavailable: "
              << winrt::to_string(error.message()) << std::endl;
  }
}

JustAudioWindowsPlugin::~JustAudioWindowsPlugin() {
  if (output_device_watcher_) {
    output_device_watcher_.Added(output_device_added_token_);
    output_device_watcher_.Removed(output_device_removed_token_);
    output_device_watcher_.Stop();
  }
}

void JustAudioWindowsPlugin::HandleAudioOutputMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
    if (method_call.method_name().compare("listOutputDevices") == 0) {
      const auto devices = DeviceInformation::FindAllAsync(
          MediaDevice::GetAudioRenderSelector()).get();
      const auto default_id = MediaDevice::GetDefaultAudioRenderId(
          AudioDeviceRole::Default);
      flutter::EncodableList rows;
      for (const auto &device : devices) {
        flutter::EncodableMap row;
        row[EncodableValue("id")] = EncodableValue(winrt::to_string(device.Id()));
        row[EncodableValue("name")] = EncodableValue(winrt::to_string(device.Name()));
        row[EncodableValue("isSystemDefault")] =
            EncodableValue(device.Id() == default_id);
        rows.emplace_back(std::move(row));
      }
      result->Success(EncodableValue(std::move(rows)));
      return;
    }
    if (method_call.method_name().compare("setOutputDevice") == 0) {
      const auto *args = std::get_if<flutter::EncodableMap>(method_call.arguments());
      const auto *id = args ? std::get_if<std::string>(ValueOrNull(*args, "deviceId")) : nullptr;
      const std::string device_id = id ? *id : std::string();
      DeviceInformation device{nullptr};
      bool endpoint_available = device_id.empty();
      if (!device_id.empty()) {
        try {
          device = DeviceInformation::CreateFromIdAsync(
              TO_WIDESTRING(device_id)).get();
          endpoint_available = true;
        } catch (const winrt::hresult_error &) {
          // 设备暂时离线时先输出到系统默认；watcher 在设备重现时切回。
        }
      }
      {
        std::lock_guard<std::mutex> lock(output_devices_mutex_);
        selected_output_device_id_ = device_id;
        for (const auto &player : players_) {
          player->SetAudioDevice(device);
        }
      }
      if (!endpoint_available) {
        std::cerr << "[windows_audio_output] endpoint unavailable; waiting to reconnect: "
                  << device_id << std::endl;
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  } catch (const winrt::hresult_error &error) {
    result->Error("audio_output_error", winrt::to_string(error.message()));
  } catch (const std::exception &error) {
    result->Error("audio_output_error", error.what());
  }
}

void JustAudioWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    flutter::BinaryMessenger* messenger) {
  const auto* args =std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (args) {
    if (method_call.method_name().compare("init") == 0) {
      const auto* id = std::get_if<std::string>(ValueOrNull(*args, "id"));
      if (!id) {
        return result->Error("argument_error", "id argument missing");
      }
      auto player = std::make_unique<AudioPlayer>(*id, messenger);
      {
        std::lock_guard<std::mutex> lock(output_devices_mutex_);
        if (!selected_output_device_id_.empty()) {
          try {
            auto device = DeviceInformation::CreateFromIdAsync(
                TO_WIDESTRING(selected_output_device_id_)).get();
            player->SetAudioDevice(device);
          } catch (const winrt::hresult_error &) {
            // 已保存的输出端点离线时保留选择，watcher 后续自动重连。
          }
        }
        players_.push_back(std::move(player));
      }
      result->Success();
    } else if (method_call.method_name().compare("disposePlayer") == 0) {
      const auto* id = std::get_if<std::string>(ValueOrNull(*args, "id"));
      if (!id) {
        return result->Error("argument_error", "id argument missing");
      }
      DisposePlayerByPlayerId(*id);
      result->Success(flutter::EncodableMap());
    } else if (method_call.method_name().compare("disposeAllPlayers") == 0) {
      std::lock_guard<std::mutex> lock(output_devices_mutex_);
      players_.clear();
      result->Success(flutter::EncodableMap());
    } else {
      result->NotImplemented();
    }
  } else {
    result->NotImplemented();
  }
}

AudioPlayer* JustAudioWindowsPlugin::GetPlayerByPlayerId(std::string id) {
  std::lock_guard<std::mutex> lock(output_devices_mutex_);
  for (auto it = begin(players_); it != end(players_); ++it) {
    if ((*it)->HasPlayerId(id)) {
      return it->get();
    }
  }
  return nullptr;
}

void JustAudioWindowsPlugin::DisposePlayerByPlayerId(std::string id) {
  std::lock_guard<std::mutex> lock(output_devices_mutex_);
  for (auto it = begin(players_); it != end(players_); ++it) {
    if ((*it)->HasPlayerId(id)) {
      players_.erase(it);
      return;
    }
  }
}

}  // namespace

void JustAudioWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  JustAudioWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
