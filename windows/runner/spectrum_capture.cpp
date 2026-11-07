#include "spectrum_capture.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <objbase.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#endif

// 进程环回（Application Loopback）的结构体在 SDK 里受
// `NTDDI_VERSION >= NTDDI_WIN10_FE` 保护：用 10.0.19041 等较老 SDK 构建时
// 整块都会被裁掉，编译直接失败。下面按 SDK 原样补一份声明（GUID/字段布局
// 与官方头文件一致），运行期门槛仍由 ActivateAudioInterfaceAsync 的返回值决定
// ——Windows 10 build 20348 之前会失败，自动回落到设备环回。
#if !defined(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK)
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
typedef enum PROCESS_LOOPBACK_MODE {
  PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0,
  PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE = 1,
} PROCESS_LOOPBACK_MODE;
typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
  DWORD TargetProcessId;
  PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;
typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
  AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT = 0,
  AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1,
} AUDIOCLIENT_ACTIVATION_TYPE;
typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
  AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
  union {
    AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
  } DUMMYUNIONNAME;
} AUDIOCLIENT_ACTIVATION_PARAMS;
#endif  // !defined(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK)

namespace {

// 与 Android 端 SpectrumPlugin 完全对齐：1024 点窗、40 段、最小发射间隔 23ms
//（≈43fps，等于 1024 样本 @44.1kHz 的窗长，相邻帧无空隙）。
constexpr int kFftSize = 1024;
constexpr int kBandCount = 40;
constexpr int kMinEmitIntervalMs = 23;
constexpr int kActivateTimeoutMs = 1500;
constexpr int kProcessCaptureRate = 44100;
constexpr double kPi = 3.14159265358979323846;

// WAVEFORMATEXTENSIBLE 的 SubFormat。直接用本地常量比较，避免为了
// KSDATAFORMAT_SUBTYPE_* 去引 ksmedia.h / ksuser.lib。
constexpr GUID kSubtypeIeeeFloat = {
    0x00000003,
    0x0000,
    0x0010,
    {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
constexpr GUID kSubtypePcm = {
    0x00000001,
    0x0000,
    0x0010,
    {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

// 采集格式描述：目前只认共享模式混音常见的 float32 / int16 交错两种。
struct CaptureWaveFormat {
  bool is_float = false;
  int channels = 0;
  int bits_per_sample = 0;
  int sample_rate = 0;
};

bool DescribeFormat(const WAVEFORMATEX& format, CaptureWaveFormat* out) {
  if (format.nChannels == 0 || format.nChannels > 8) return false;
  if (format.nSamplesPerSec == 0) return false;

  bool is_float = false;
  if (format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    is_float = true;
  } else if (format.wFormatTag == WAVE_FORMAT_PCM) {
    is_float = false;
  } else if (format.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    if (format.cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
      return false;
    }
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(&format);
    if (IsEqualGUID(extensible->SubFormat, kSubtypeIeeeFloat)) {
      is_float = true;
    } else if (IsEqualGUID(extensible->SubFormat, kSubtypePcm)) {
      is_float = false;
    } else {
      return false;
    }
  } else {
    return false;
  }

  if (is_float && format.wBitsPerSample != 32) return false;
  if (!is_float && format.wBitsPerSample != 16) return false;

  out->is_float = is_float;
  out->channels = static_cast<int>(format.nChannels);
  out->bits_per_sample = static_cast<int>(format.wBitsPerSample);
  out->sample_rate = static_cast<int>(format.nSamplesPerSec);
  return true;
}

// 基 2 迭代 FFT（位反转 + 蝶形），与 Android `SpectrumFft.transform()` 同一算法。
void Fft(double* real,
         double* imag,
         const double* twiddle_re,
         const double* twiddle_im,
         int n) {
  int j = 0;
  for (int i = 0; i < n - 1; ++i) {
    if (i < j) {
      std::swap(real[i], real[j]);
      std::swap(imag[i], imag[j]);
    }
    int m = n >> 1;
    while (j >= m) {
      j -= m;
      m >>= 1;
    }
    j += m;
  }

  for (int len = 2; len <= n; len <<= 1) {
    const int half = len >> 1;
    const int step = n / len;
    for (int i = 0; i < n; i += len) {
      for (int k = 0; k < half; ++k) {
        const int twiddle = k * step;
        const double wr = twiddle_re[twiddle];
        const double wi = twiddle_im[twiddle];
        const int lo = i + k;
        const int hi = lo + half;
        const double vr = real[hi] * wr - imag[hi] * wi;
        const double vi = real[hi] * wi + imag[hi] * wr;
        real[hi] = real[lo] - vr;
        imag[hi] = imag[lo] - vi;
        real[lo] += vr;
        imag[lo] += vi;
      }
    }
  }
}

// 单个采集会话的分析器：环形样本缓冲 + 加窗 FFT + 40 段归一化。
// 与 Android `SpectrumAnalyzer` / `SpectrumFft` 行为一致（含"只取前 40 个 bin"
// 与"按帧内最大值自归一化"两条口径，保证跨端观感相同）。
class Analyzer {
 public:
  explicit Analyzer()
      : hann_(new double[kFftSize]),
        twiddle_re_(new double[kFftSize / 2]),
        twiddle_im_(new double[kFftSize / 2]),
        real_(new double[kFftSize]),
        imag_(new double[kFftSize]),
        snapshot_(new double[kFftSize]) {
    for (int i = 0; i < kFftSize; ++i) {
      hann_[i] = 0.5 * (1.0 - std::cos(2.0 * kPi * i / (kFftSize - 1)));
    }
    for (int i = 0; i < kFftSize / 2; ++i) {
      const double angle = -2.0 * kPi * i / kFftSize;
      twiddle_re_[i] = std::cos(angle);
      twiddle_im_[i] = std::sin(angle);
    }
  }

  ~Analyzer() = default;

  Analyzer(const Analyzer&) = delete;
  Analyzer& operator=(const Analyzer&) = delete;

  void AppendSilence(UINT32 frames) {
    for (UINT32 i = 0; i < frames; ++i) Push(0.0f);
  }

  void AppendInterleaved(const BYTE* data,
                         UINT32 frames,
                         const CaptureWaveFormat& format) {
    const int bytes_per_sample = format.bits_per_sample / 8;
    const int frame_stride = bytes_per_sample * format.channels;
    for (UINT32 frame = 0; frame < frames; ++frame) {
      const BYTE* frame_base =
          data + static_cast<size_t>(frame) * static_cast<size_t>(frame_stride);
      float mono = 0.0f;
      for (int channel = 0; channel < format.channels; ++channel) {
        const BYTE* sample =
            frame_base + static_cast<size_t>(channel * bytes_per_sample);
        if (format.is_float) {
          float value = 0.0f;
          std::memcpy(&value, sample, sizeof(value));
          mono += value;
        } else {
          int16_t value = 0;
          std::memcpy(&value, sample, sizeof(value));
          mono += static_cast<float>(value) / 32768.0f;
        }
      }
      Push(mono / static_cast<float>(format.channels));
    }
  }

  // 帧回调由调用方提供，内部只在节流条件满足时触发。
  template <typename Emit>
  void MaybeEmit(Emit emit) {
    if (filled_ < kFftSize) return;
    const uint32_t now = static_cast<uint32_t>(GetTickCount64());
    if (last_emit_ms_ >= 0 &&
        now - static_cast<uint32_t>(last_emit_ms_) < kMinEmitIntervalMs) {
      return;
    }
    last_emit_ms_ = static_cast<int64_t>(now);

    // 快照最近 kFftSize 个样本：ring 会被下一包数据覆盖，必须先拷出来。
    for (int i = 0; i < kFftSize; ++i) {
      snapshot_[i] = ring_[(write_pos_ + i) % kFftSize];
    }
    emit(ComputeBands());
  }

 private:
  void Push(float sample) {
    ring_[write_pos_] = static_cast<double>(sample);
    write_pos_ = (write_pos_ + 1) % kFftSize;
    if (filled_ < kFftSize) ++filled_;
  }

  std::vector<double> ComputeBands() {
    for (int i = 0; i < kFftSize; ++i) {
      real_[i] = snapshot_[i] * hann_[i];
      imag_[i] = 0.0;
    }
    Fft(real_.get(), imag_.get(), twiddle_re_.get(), twiddle_im_.get(),
        kFftSize);

    // 跳过 DC（bin 0）；只取前 kBandCount 个 bin —— 与 Android 视觉口径一致。
    double magnitudes[kBandCount];
    double max_magnitude = 1.0;
    for (int i = 0; i < kBandCount; ++i) {
      const double re = real_[i + 1];
      const double im = imag_[i + 1];
      const double magnitude = std::sqrt(re * re + im * im);
      magnitudes[i] = magnitude;
      if (magnitude > max_magnitude) max_magnitude = magnitude;
    }

    std::vector<double> bands(kBandCount, 0.0);
    for (int i = 0; i < kBandCount; ++i) {
      const double normalized = magnitudes[i] / max_magnitude;
      bands[static_cast<size_t>(i)] = std::min(1.0, std::max(0.0, normalized));
    }
    return bands;
  }

  double ring_[kFftSize] = {};
  int write_pos_ = 0;
  int filled_ = 0;
  int64_t last_emit_ms_ = -1;

  std::unique_ptr<double[]> hann_;
  std::unique_ptr<double[]> twiddle_re_;
  std::unique_ptr<double[]> twiddle_im_;
  std::unique_ptr<double[]> real_;
  std::unique_ptr<double[]> imag_;
  std::unique_ptr<double[]> snapshot_;
};

// ActivateAudioInterfaceAsync 的完成回调。手工实现 IUnknown，
// 并额外接受 IID_IAgileObject：回调由系统在 MTA 线程上执行，
// 非敏捷对象在跨套间投递时会拿到 E_ILLEGAL_METHOD_CALL。
class ActivationCompletedHandler final
    : public IActivateAudioInterfaceCompletionHandler {
 public:
  // 完成事件由本对象持有并在析构时关闭：激活超时后系统仍可能回调，
  // 若由调用方按超时提前 CloseHandle，迟到回调会 SetEvent 到一个已关闭
  //（甚至被复用的）句柄上。
  ActivationCompletedHandler()
      : completed_event_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

  bool valid() const { return completed_event_ != nullptr; }
  HANDLE wait_handle() const { return completed_event_; }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override {
    if (object == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(IActivateAudioInterfaceCompletionHandler) ||
        riid == __uuidof(IAgileObject)) {
      *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&ref_count_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return static_cast<ULONG>(count);
  }

  HRESULT STDMETHODCALLTYPE ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activate_result = E_UNEXPECTED;
    IUnknown* activated = nullptr;
    HRESULT hr = operation != nullptr
                     ? operation->GetActivateResult(&activate_result, &activated)
                     : E_POINTER;
    if (SUCCEEDED(hr)) hr = activate_result;
    if (SUCCEEDED(hr) && activated != nullptr) {
      hr = activated->QueryInterface(__uuidof(IAudioClient),
                                     reinterpret_cast<void**>(&client_));
    }
    if (activated != nullptr) activated->Release();
    result_ = hr;
    SetEvent(completed_event_);
    return S_OK;
  }

  // 成功时把 IAudioClient 的所有权交给调用方。
  IAudioClient* TakeClient() {
    IAudioClient* client = client_;
    client_ = nullptr;
    return client;
  }

  HRESULT result() const { return result_; }

 private:
  ~ActivationCompletedHandler() {
    if (client_ != nullptr) client_->Release();
    if (completed_event_ != nullptr) CloseHandle(completed_event_);
  }

  LONG ref_count_ = 1;
  HANDLE completed_event_ = nullptr;
  IAudioClient* client_ = nullptr;
  HRESULT result_ = E_FAIL;
};

// 进程环回：只采本进程（含子进程）的音频输出。Windows 10 build 20348 之前
// 该 API 不支持，会返回失败，由调用方回落到设备环回。
HRESULT TryProcessLoopback(IAudioClient** client_out) {
  *client_out = nullptr;

  AUDIOCLIENT_ACTIVATION_PARAMS activation = {};
  activation.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activation.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  activation.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT activate_params = {};
  activate_params.vt = VT_BLOB;
  activate_params.blob.cbSize = sizeof(activation);
  activate_params.blob.pBlobData = reinterpret_cast<BYTE*>(&activation);

  auto* handler = new (std::nothrow) ActivationCompletedHandler();
  if (handler == nullptr) return E_OUTOFMEMORY;
  if (!handler->valid()) {
    const HRESULT create_hr = HRESULT_FROM_WIN32(GetLastError());
    handler->Release();
    return create_hr;
  }

  IActivateAudioInterfaceAsyncOperation* operation = nullptr;
  HRESULT hr = ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &activate_params, handler, &operation);
  if (SUCCEEDED(hr)) {
    if (WaitForSingleObject(handler->wait_handle(), kActivateTimeoutMs) !=
        WAIT_OBJECT_0) {
      hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    } else {
      hr = handler->result();
      if (SUCCEEDED(hr)) *client_out = handler->TakeClient();
    }
  }
  if (operation != nullptr) operation->Release();
  handler->Release();
  return hr;
}

// 设备环回：默认渲染端点的系统混音。老系统 / 进程环回失败时的兜底，
// 缺点是会混入其他应用的声音（Stats.mode == "device" 可辨认）。
HRESULT TryDeviceLoopback(IAudioClient** client_out, WAVEFORMATEX** mix_out) {
  *client_out = nullptr;
  *mix_out = nullptr;

  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) return hr;

  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  enumerator->Release();
  if (FAILED(hr)) return hr;

  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(client_out));
  device->Release();
  if (FAILED(hr)) return hr;

  WAVEFORMATEX* mix_format = nullptr;
  hr = (*client_out)->GetMixFormat(&mix_format);
  if (FAILED(hr)) {
    (*client_out)->Release();
    *client_out = nullptr;
    return hr;
  }
  *mix_out = mix_format;
  return S_OK;
}

HRESULT InitializeLoopbackClient(IAudioClient* client,
                                 const WAVEFORMATEX* format,
                                 DWORD extra_flags) {
  return client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
          extra_flags,
      0, 0, format, nullptr);
}

}  // namespace

SpectrumCapture::SpectrumCapture() = default;

SpectrumCapture::~SpectrumCapture() {
  SetFrameCallback(nullptr);
  Stop();
}

void SpectrumCapture::SetFrameCallback(FrameCallback callback) {
  std::lock_guard<std::mutex> lock(callback_mutex_);
  callback_ = std::move(callback);
}

bool SpectrumCapture::Start(LoopbackMode mode) {
  Stop();

  {
    std::lock_guard<std::mutex> lock(pcm_mutex_);
    loopback_mode_ = mode;
  }

  init_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (init_event_ == nullptr || stop_event_ == nullptr) {
    if (init_event_ != nullptr) {
      CloseHandle(init_event_);
      init_event_ = nullptr;
    }
    if (stop_event_ != nullptr) {
      CloseHandle(stop_event_);
      stop_event_ = nullptr;
    }
    return false;
  }

  stop_requested_.store(false);
  frames_.store(0);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    running_.store(false);
    mode_.clear();
    sample_rate_hz_ = 0;
  }

  thread_ = std::thread(&SpectrumCapture::ThreadMain, this);
  const DWORD wait = WaitForSingleObject(init_event_, 3000);
  bool ok = false;
  if (wait == WAIT_OBJECT_0) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    ok = running_.load();
  }
  if (!ok) Stop();
  return ok;
}

void SpectrumCapture::Stop() {
  stop_requested_.store(true);
  if (stop_event_ != nullptr) SetEvent(stop_event_);
  if (thread_.joinable()) thread_.join();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    running_.store(false);
    mode_.clear();
    sample_rate_hz_ = 0;
  }
  if (init_event_ != nullptr) {
    CloseHandle(init_event_);
    init_event_ = nullptr;
  }
  if (stop_event_ != nullptr) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
}

SpectrumCapture::Stats SpectrumCapture::GetStats() {
  Stats stats;
  stats.frames = frames_.load();
  std::lock_guard<std::mutex> lock(state_mutex_);
  stats.running = running_.load();
  stats.mode = mode_;
  stats.sample_rate_hz = sample_rate_hz_;
  return stats;
}

void SpectrumCapture::EmitFrame(const std::vector<double>& bands) {
  FrameCallback callback;
  {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    callback = callback_;
  }
  if (!callback) return;
  callback(bands);
  ++frames_;
}

void SpectrumCapture::ThreadMain() {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  (void)com_result;  // 即便已是其它套间也继续尝试，由后续激活结果兜底。

  IAudioClient* client = nullptr;
  WAVEFORMATEX* mix_format = nullptr;
  CaptureWaveFormat format = {};
  std::string mode;
  bool initialized = false;
  HRESULT hr = E_FAIL;

  // ── 1) 进程环回（仅频谱；识曲要整个系统混音，见 LoopbackMode）──────
  LoopbackMode mode_hint = LoopbackMode::kProcessPreferred;
  {
    std::lock_guard<std::mutex> lock(pcm_mutex_);
    mode_hint = loopback_mode_;
  }
  if (mode_hint == LoopbackMode::kProcessPreferred) {
    hr = TryProcessLoopback(&client);
    if (SUCCEEDED(hr) && client != nullptr) {
      // 微软 ApplicationLoopback 示例同款：进程环回必须自己指定格式，
      // AUTOCONVERTPCM 让音频引擎把任意混音格式转成 PCM16。
      WAVEFORMATEX process_format = {};
      process_format.wFormatTag = WAVE_FORMAT_PCM;
      process_format.nChannels = 2;
      process_format.nSamplesPerSec = kProcessCaptureRate;
      process_format.wBitsPerSample = 16;
      process_format.nBlockAlign = 4;
      process_format.nAvgBytesPerSec = kProcessCaptureRate * 4;
      process_format.cbSize = 0;
      hr = InitializeLoopbackClient(client, &process_format,
                                    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM);
      if (SUCCEEDED(hr) && DescribeFormat(process_format, &format)) {
        mode = "process";
      } else {
        client->Release();
        client = nullptr;
        hr = E_FAIL;
      }
    }
  }

  // ── 2) 设备环回（兜底）────────────────────────────────────────────
  if (mode.empty()) {
    if (client != nullptr) {
      client->Release();
      client = nullptr;
    }
    hr = TryDeviceLoopback(&client, &mix_format);
    if (SUCCEEDED(hr) && client != nullptr && mix_format != nullptr) {
      hr = InitializeLoopbackClient(client, mix_format, 0);
      if (SUCCEEDED(hr) && DescribeFormat(*mix_format, &format)) {
        mode = "device";
      } else {
        client->Release();
        client = nullptr;
        hr = E_FAIL;
      }
    }
    if (mix_format != nullptr) {
      CoTaskMemFree(mix_format);
      mix_format = nullptr;
    }
  }

  HANDLE sample_event = nullptr;
  IAudioCaptureClient* capture_client = nullptr;
  if (!mode.empty() && client != nullptr) {
    sample_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (sample_event != nullptr) {
      hr = client->SetEventHandle(sample_event);
    } else {
      hr = HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(hr)) {
      hr = client->GetService(IID_PPV_ARGS(&capture_client));
    }
    if (SUCCEEDED(hr)) hr = client->Start();
  } else {
    hr = E_FAIL;
  }

  initialized = SUCCEEDED(hr) && capture_client != nullptr;
  if (initialized) {
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      mode_ = mode;
      sample_rate_hz_ = format.sample_rate;
      running_.store(true);
    }
    SetEvent(init_event_);

    Analyzer analyzer;
    HANDLE wait_handles[2] = {sample_event, stop_event_};
    while (!stop_requested_.load()) {
      const DWORD wait = WaitForMultipleObjects(2, wait_handles, FALSE, 500);
      if (wait == WAIT_OBJECT_0 + 1) break;
      if (wait != WAIT_OBJECT_0) continue;

      UINT32 packet_frames = 0;
      while (!stop_requested_.load() &&
             SUCCEEDED(capture_client->GetNextPacketSize(&packet_frames)) &&
             packet_frames > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture_client->GetBuffer(&data, &frames, &flags, nullptr,
                                             nullptr))) {
          break;
        }
        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
          if (pcm_tap_enabled_) {
            AppendPcmSilence(frames);
          } else {
            analyzer.AppendSilence(frames);
          }
        } else if (pcm_tap_enabled_) {
          AppendPcm(data, frames, format.is_float, format.channels);
        } else {
          analyzer.AppendInterleaved(data, frames, format);
        }
        capture_client->ReleaseBuffer(frames);
        // 频谱路径逐包喂 MaybeEmit（含静音包，静音也要出零能量帧，
        // 否则界面会卡住上一次的柱形）；PCM 旁路下 analyzer 从未被喂，
        // 这里自然是空操作。
        analyzer.MaybeEmit(
            [this](const std::vector<double>& bands) { EmitFrame(bands); });
      }
    }
    client->Stop();
  } else {
    SetEvent(init_event_);
  }

  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    running_.store(false);
  }
  if (capture_client != nullptr) capture_client->Release();
  if (client != nullptr) client->Release();
  if (sample_event != nullptr) CloseHandle(sample_event);
  if (mix_format != nullptr) CoTaskMemFree(mix_format);
  if (SUCCEEDED(com_result)) CoUninitialize();
}

// ── PCM 旁路（识曲用）──────────────────────────────────────────────────

void SpectrumCapture::EnablePcmTap(int max_duration_ms) {
  std::lock_guard<std::mutex> lock(pcm_mutex_);
  pcm_samples_.clear();
  pcm_truncated_ = false;
  const bool enabled = max_duration_ms > 0;
  // 上限只能按 48kHz 估：EnablePcmTap 发生在 Start 之前，采集格式（44.1/48k）
  // 要到激活后才确定。按 48k 估对 44.1k 端点相当于多留 8% 余量，无副作用。
  pcm_max_samples_ = enabled ? static_cast<size_t>(max_duration_ms) * 48 : 0;
  pcm_tap_enabled_.store(enabled);
}

void SpectrumCapture::DisablePcmTap() { pcm_tap_enabled_.store(false); }

SpectrumCapture::PcmSegment SpectrumCapture::TakePcm() {
  PcmSegment segment;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    segment.sample_rate_hz = sample_rate_hz_;
  }
  std::lock_guard<std::mutex> lock(pcm_mutex_);
  segment.samples.swap(pcm_samples_);
  segment.truncated = pcm_truncated_;
  pcm_truncated_ = false;
  return segment;
}

void SpectrumCapture::AppendPcmSilence(UINT32 frames) {
  std::lock_guard<std::mutex> lock(pcm_mutex_);
  if (!pcm_tap_enabled_.load()) return;
  for (UINT32 i = 0; i < frames; ++i) {
    if (pcm_samples_.size() >= pcm_max_samples_) {
      pcm_truncated_ = true;
      return;
    }
    pcm_samples_.push_back(0);
  }
}

void SpectrumCapture::AppendPcm(const BYTE* data, UINT32 frames, bool is_float,
                                int channels) {
  if (data == nullptr || channels <= 0) return;
  std::lock_guard<std::mutex> lock(pcm_mutex_);
  if (!pcm_tap_enabled_.load()) return;

  const auto* as_float = reinterpret_cast<const float*>(data);
  const auto* as_int16 = reinterpret_cast<const int16_t*>(data);

  for (UINT32 frame = 0; frame < frames; ++frame) {
    if (pcm_samples_.size() >= pcm_max_samples_) {
      pcm_truncated_ = true;
      return;
    }
    double mixed = 0.0;
    for (int channel = 0; channel < channels; ++channel) {
      const size_t index =
          static_cast<size_t>(frame) * static_cast<size_t>(channels) +
          static_cast<size_t>(channel);
      mixed += is_float ? static_cast<double>(as_float[index])
                        : static_cast<double>(as_int16[index]) / 32768.0;
    }
    mixed /= channels;
    mixed = mixed > 1.0 ? 1.0 : (mixed < -1.0 ? -1.0 : mixed);
    pcm_samples_.push_back(static_cast<int16_t>(mixed * 32767.0));
  }
}
