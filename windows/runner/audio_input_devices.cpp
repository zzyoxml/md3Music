#include "audio_input_devices.h"

#include <mmdeviceapi.h>
#include <objbase.h>
#include <windows.h>

namespace {

// {a45c254e-df1c-4efd-8020-67d146a850e0}, 14 = PKEY_Device_FriendlyName。
// 本地声明而不用 functiondiscoverykeys_devpkey.h：避免为一个 PROPERTYKEY
// 额外依赖 propertykey 的链接单元，与 spectrum_capture.cpp 手写
// AUDIOCLIENT_ACTIVATION_PARAMS 的做法同源。
const PROPERTYKEY kDeviceFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};

std::string Utf8FromWide(const wchar_t* wide) {
  if (wide == nullptr || wide[0] == L'\0') return {};
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                         nullptr, nullptr);
  if (size <= 1) return {};
  std::string utf8(static_cast<size_t>(size - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8.data(), size, nullptr,
                        nullptr);
  return utf8;
}

std::string EndpointId(IMMDevice* device) {
  if (device == nullptr) return {};
  LPWSTR id = nullptr;
  if (FAILED(device->GetId(&id)) || id == nullptr) return {};
  std::string result = Utf8FromWide(id);
  ::CoTaskMemFree(id);
  return result;
}

std::string FriendlyName(IMMDevice* device) {
  if (device == nullptr) return {};
  IPropertyStore* store = nullptr;
  if (FAILED(device->OpenPropertyStore(STGM_READ, &store)) || store == nullptr) {
    return {};
  }
  PROPVARIANT value;
  ::PropVariantInit(&value);
  std::string name;
  if (SUCCEEDED(store->GetValue(kDeviceFriendlyName, &value)) &&
      value.vt == VT_LPWSTR) {
    name = Utf8FromWide(value.pwszVal);
  }
  ::PropVariantClear(&value);
  store->Release();
  return name;
}

}  // namespace

std::vector<AudioInputDeviceInfo> ListAudioInputDevices() {
  std::vector<AudioInputDeviceInfo> devices;

  IMMDeviceEnumerator* enumerator = nullptr;
  const HRESULT created = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
  if (FAILED(created) || enumerator == nullptr) return devices;

  std::string default_id;
  IMMDevice* default_device = nullptr;
  if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole,
                                                    &default_device)) &&
      default_device != nullptr) {
    default_id = EndpointId(default_device);
    default_device->Release();
  }

  IMMDeviceCollection* collection = nullptr;
  if (SUCCEEDED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                               &collection)) &&
      collection != nullptr) {
    UINT count = 0;
    if (SUCCEEDED(collection->GetCount(&count))) {
      for (UINT index = 0; index < count; ++index) {
        IMMDevice* device = nullptr;
        if (FAILED(collection->Item(index, &device)) || device == nullptr) {
          continue;
        }
        AudioInputDeviceInfo info;
        info.id = EndpointId(device);
        info.name = FriendlyName(device);
        if (info.name.empty()) {
          info.name = "麦克风 " + std::to_string(index + 1);
        }
        info.is_default = !default_id.empty() && info.id == default_id;
        if (!info.id.empty()) devices.push_back(std::move(info));
        device->Release();
      }
    }
    collection->Release();
  }

  enumerator->Release();
  return devices;
}
