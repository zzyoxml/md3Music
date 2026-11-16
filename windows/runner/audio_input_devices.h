#ifndef RUNNER_AUDIO_INPUT_DEVICES_H_
#define RUNNER_AUDIO_INPUT_DEVICES_H_

#include <string>
#include <vector>

// 一个 Windows 录音端点（WASAPI capture / MediaFoundation audcap）。
struct AudioInputDeviceInfo {
  // WASAPI 端点 ID（如 `{0.0.1.00000000}.{GUID}`）——同时也是
  // MediaFoundation 的 MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID，
  // 因此 Dart 侧可以把这个字符串直接交给 record_windows 选设备。
  std::string id;
  // PKEY_Device_FriendlyName 的 UTF-8 形式；取不到时回落到「麦克风 N」。
  std::string name;
  // 是否为 eCapture + eConsole 视角的系统默认设备。
  bool is_default = false;
};

// 枚举当前活动（DEVICE_STATE_ACTIVE）的录音端点。
//
// **为什么不用 record_windows 自带的 listInputDevices**：该插件只在
// `InitRecording` 里调用 `MFStartup`，而 `ListInputDevices` 在其之前执行
// `MFEnumDeviceSources`，进程尚未初始化 MediaFoundation 时会失败/返回空。
// 这里直接走 WASAPI（runner 的平台线程已由 Flutter embedder 初始化 COM STA），
// 与 spectrum_capture.cpp 的设备环回同一套 COM 基础设施。
//
// 失败（无 COM、无设备、权限为零）时返回空 vector，不抛异常。
std::vector<AudioInputDeviceInfo> ListAudioInputDevices();

#endif  // RUNNER_AUDIO_INPUT_DEVICES_H_
