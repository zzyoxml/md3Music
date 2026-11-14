#ifndef RUNNER_SPECTRUM_CAPTURE_H_
#define RUNNER_SPECTRUM_CAPTURE_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Windows 端音乐频谱采集：WASAPI 环回 → 单声道 1024 点 Hann 加窗 FFT →
// 40 段归一化幅值（0..1），协议与 Android 端 SpectrumPlugin 的 onFft 完全一致。
//
// **为什么不用播放器内部 PCM**：Windows 播放走 just_audio_windows 的
// Windows.Media.Playback.MediaPlayer，解码与渲染都在系统内部，拿不到样本。
// 业界做法（OBS / 微软 ApplicationLoopback 示例）是 WASAPI 环回采集：
// - 进程环回（Windows 10 build 20348+ / Windows 11）：只采本进程及其子进程的
//   音频，其他应用的声音不会污染频谱；
// - 设备环回（老系统兜底）：采默认渲染端点的系统混音，会混入其他应用。
//
// Start/Stop 幂等：Dart 侧断流恢复会反复调用 start 重建采集。
class SpectrumCapture {
 public:
  // 每帧回调：在采集线程上调用，宿主负责切回平台线程再发通道消息。
  using FrameCallback = std::function<void(const std::vector<double>&)>;

  SpectrumCapture();
  ~SpectrumCapture();

  SpectrumCapture(const SpectrumCapture&) = delete;
  SpectrumCapture& operator=(const SpectrumCapture&) = delete;

  void SetFrameCallback(FrameCallback callback);

  // 环回激活方式。
  // - kProcessPreferred：进程环回优先（只采本进程，频谱用），失败回落设备环回；
  // - kDeviceOnly：只走设备环回（默认渲染端点的系统混音）。
  //   **识曲必须用这个**：进程环回会把用户在浏览器 / 其他播放器里放的声音漏光。
  enum class LoopbackMode { kProcessPreferred, kDeviceOnly };

  // 打开 PCM 旁路：不再做 FFT，改为把采集样本转成「单声道 int16」累积，
  // 上限按 [max_duration_ms] 折算。识曲用它把一段系统声音交给指纹接口。
  void EnablePcmTap(int max_duration_ms);
  void DisablePcmTap();

  struct PcmSegment {
    std::vector<int16_t> samples;  // 单声道 16bit
    int sample_rate_hz = 0;        // 原始采样率（不重采样，交由 Rust 降采样）
    bool truncated = false;        // 达到时长上限被截断
  };

  // 取走本段 PCM（调用前先 Stop()，否则可能取到半段）；取走后缓冲清空。
  PcmSegment TakePcm();

  // 建立采集并等待初始化结果（最多 3s）。已运行时会先停下再重建。
  bool Start(LoopbackMode mode = LoopbackMode::kProcessPreferred);
  void Stop();

  struct Stats {
    bool running = false;
    // "process" = 只采本进程；"device" = 系统混音兜底；空 = 未建立采集。
    std::string mode;
    int64_t frames = 0;       // 已回调的频谱帧数
    int sample_rate_hz = 0;   // 实际采集格式的采样率
  };
  Stats GetStats();

 private:
  void ThreadMain();
  void EmitFrame(const std::vector<double>& bands);
  // PCM 旁路：把一包交错样本（float32 或 int16）平均成单声道 int16 追加。
  void AppendPcm(const BYTE* data, UINT32 frames, bool is_float, int channels);
  void AppendPcmSilence(UINT32 frames);

  std::thread thread_;
  HANDLE init_event_ = nullptr;
  HANDLE stop_event_ = nullptr;

  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> running_{false};
  std::atomic<int64_t> frames_{0};

  std::mutex state_mutex_;
  std::string mode_;
  int sample_rate_hz_ = 0;

  std::mutex callback_mutex_;
  FrameCallback callback_;

  // 采集模式与 PCM 旁路缓冲。pcm_mutex_ 同时保护 loopback_mode_
  // （采集线程只在启动时读一次，无需为它另开锁）。
  LoopbackMode loopback_mode_ = LoopbackMode::kProcessPreferred;
  std::mutex pcm_mutex_;
  std::vector<int16_t> pcm_samples_;
  size_t pcm_max_samples_ = 0;
  // 采集线程每包都会读，用原子量避免与 Enable/DisablePcmTap 数据竞争。
  std::atomic<bool> pcm_tap_enabled_{false};
  bool pcm_truncated_ = false;
};

#endif  // RUNNER_SPECTRUM_CAPTURE_H_
