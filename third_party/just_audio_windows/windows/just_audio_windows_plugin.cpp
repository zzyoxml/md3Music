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
