#pragma once
#include <cstdio>
#include <string>
#include <atomic>
#include <thread>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Effects.h>
#include <winrt/Windows.Media.Render.h>
#include <winrt/base.h>

#include "dsp_effects.hpp"

namespace md3music {

class DspGraph {
 public:
  winrt::Windows::Media::Audio::AudioGraph graph{nullptr};
  winrt::Windows::Media::Audio::MediaSourceAudioInputNode input{nullptr};
  winrt::Windows::Media::Audio::AudioDeviceOutputNode output{nullptr};
  winrt::event_token dsp_err_token_{};

  // 内置效果定义：4 段 EQ + 限幅。API 与 Task 0 Spike 实测一致。
  winrt::Windows::Media::Audio::EqualizerEffectDefinition eq_def{nullptr};
  winrt::Windows::Media::Audio::LimiterEffectDefinition limiter_def{nullptr};

  // C++17 无 /await：所有 WinRT 异步均用 .get() 同步等待。
  // 调用方是 DSP 工作线程（MTA），同步等待可接受；但 .get() 必须带超时，
  // 否则设备初始化竞态会让异步永不完成 → join 永久挂死（已发生）。
  template <typename TOp>
  bool WaitAsync(TOp&& op, const char* what) {
    std::atomic<bool> done{false};
    try {
      op.Completed([&done](auto&&, auto&&) mutable { done = true; });
    } catch (...) {
      done = true;
    }
    int waited = 0;
    while (!done.load() && waited < 3000) {
      Sleep(50);
      waited += 50;
    }
    if (!done.load()) {
      std::fprintf(stderr, "[DSPTRACE] %s TIMEOUT after 3s\n", what);
      try { op.Cancel(); } catch (...) {}
      return false;
    }
    return true;
  }

  void Create(
      std::wstring_view uri,
      winrt::Windows::Devices::Enumeration::DeviceInformation const* device) {
    using namespace winrt::Windows::Media::Audio;
    using namespace winrt::Windows::Media::Core;
    using namespace winrt::Windows::Media::Render;

    AudioGraphSettings settings(AudioRenderCategory::Media);
    if (device != nullptr) settings.PrimaryRenderDevice(*device);
    auto created_op = AudioGraph::CreateAsync(settings);
    if (!WaitAsync(created_op, "AudioGraph::CreateAsync")) return;
    auto created = created_op.get();
    if (created.Status() != AudioGraphCreationStatus::Success) {
      std::fprintf(stderr, "[DSPTRACE] Create FAIL at graph (status=%d)\n", (int)created.Status());
      return;
    }
    graph = created.Graph();

    // 不可恢复错误探针：设备/解码层面的致命错误会让图静音而无任何上层信号。
    dsp_err_token_ = graph.UnrecoverableErrorOccurred([this](auto&&, auto&& args) {
      std::fprintf(stderr, "[DSPTRACE] Graph UNRECOVERABLE ERROR\n");
    });

    auto out_op = graph.CreateDeviceOutputNodeAsync();
    if (!WaitAsync(out_op, "CreateDeviceOutputNodeAsync")) return;
    auto out = out_op.get();
    if (out.Status() != AudioDeviceNodeCreationStatus::Success) {
      std::fprintf(stderr, "[DSPTRACE] Create FAIL at output node (status=%d)\n", (int)out.Status());
      return;
    }
    output = out.DeviceOutputNode();

    winrt::Windows::Foundation::Uri sourceUri{nullptr};
    try {
      sourceUri = winrt::Windows::Foundation::Uri(winrt::hstring(uri));
    } catch (const winrt::hresult_error& e) {
      std::fprintf(stderr, "[DSPTRACE] Create FAIL at Uri parse: %s uri=%ls\n",
                   winrt::to_string(e.message()).c_str(), std::wstring(uri).c_str());
      return;
    }
    auto source = MediaSource::CreateFromUri(sourceUri);
    try {
      auto in_op = graph.CreateMediaSourceAudioInputNodeAsync(source);
      if (!WaitAsync(in_op, "CreateMediaSourceAudioInputNodeAsync")) return;
      auto in = in_op.get();
      if (in.Status() != MediaSourceAudioInputNodeCreationStatus::Success) {
        std::fprintf(stderr, "[DSPTRACE] Create FAIL at input node status=%d uri=%ls\n",
                     (int)in.Status(), std::wstring(uri).c_str());
        return;
      }
      input = in.Node();
    } catch (const winrt::hresult_error& e) {
      std::fprintf(stderr, "[DSPTRACE] Create FAIL at input node exception: %s\n",
                   winrt::to_string(e.message()).c_str());
      return;
    }
    input.AddOutgoingConnection(output);

    // 建图即挂载效果链，并把 DspState 当前生效值刷进去（新曲/新实例也带效果）。
    AttachInboxEffects();
    ApplyDspStateToEffects();
    std::fprintf(stderr,
                 "[DSPTRACE] DspGraph::Create OK eqDef=%d limiterDef=%d\n",
                 eq_def ? 1 : 0, limiter_def ? 1 : 0);
  }

  // 挂载内置 4 段 EQ + 限幅；EQ 默认关闭，由 SetEqEnabled 按开关启用。
  // 中心频率取 Task 0 实测值 100/800/2000/10000Hz，增益为线性倍数（1.0=0dB）。
  void AttachInboxEffects() {
    using namespace winrt::Windows::Media::Audio;
    if (!graph || !input) return;
    if (!eq_def) {
      eq_def = EqualizerEffectDefinition(graph);
      auto bands = eq_def.Bands();
      constexpr std::array<double, 4> kCenter = {100.0, 800.0, 2000.0, 10000.0};
      constexpr std::array<double, 4> kBandwidth = {1.5, 1.5, 1.5, 2.0};
      for (int i = 0; i < 4 && i < (int)bands.Size(); ++i) {
        bands.GetAt(i).FrequencyCenter((float)kCenter[i]);
        bands.GetAt(i).Bandwidth((float)kBandwidth[i]);
        bands.GetAt(i).Gain(1.0f);
      }
      input.EffectDefinitions().Append(eq_def);
      input.DisableEffectsByDefinition(eq_def);
    }
    if (!limiter_def) {
      limiter_def = LimiterEffectDefinition(graph);
      limiter_def.Loudness(1000u);  // 与 Android 软削波阈值同量级，实测再调
      limiter_def.Release(10u);
      input.EffectDefinitions().Append(limiter_def);
      input.EnableEffectsByDefinition(limiter_def);
    }
  }

  // dB → 线性增益写回 4 段 EQ；增益超界按 ±12dB 钳制（XAPOFX 范围更宽）。
  void SetEqDb(const std::array<double, 4>& db) {
    if (!eq_def) return;
    auto bands = eq_def.Bands();
    for (size_t i = 0; i < db.size() && i < static_cast<size_t>(bands.Size()); ++i) {
      bands.GetAt(static_cast<uint32_t>(i)).Gain(
          static_cast<float>(dsp::DbToLinear(dsp::ClampDb(db[i]))));
    }
  }

  void SetEqEnabled(bool enabled) {
    if (!eq_def) return;
    if (enabled) input.EnableEffectsByDefinition(eq_def);
    else input.DisableEffectsByDefinition(eq_def);
  }

  // 从全局 DspState 读当前开关与增益刷到效果链；channel 广播后由实例调用。
  void ApplyDspStateToEffects() {
    auto s = dsp::DspState::Instance().Read();
    SetEqDb(s.eq_db);
    SetEqEnabled(s.enabled);
    std::fprintf(stderr,
                 "[DSPTRACE] ApplyDspStateToEffects enabled=%d eq=[%.2f,%.2f,%.2f,%.2f]\n",
                 s.enabled ? 1 : 0, s.eq_db[0], s.eq_db[1], s.eq_db[2], s.eq_db[3]);
  }

  // 换曲：在同一图上重建输入节点（不销毁图）。
  // 实测销毁重建整个图后，第 2/3 个图虽然节点在产出（Position 前进），
  // 但设备端静音——AudioGraph 的已知缺陷，必须复用图实例。
  bool RebuildInput(std::wstring_view uri) {
    if (!graph || !output) return false;
    if (input) {
      try { input.Close(); } catch (...) {}
      input = nullptr;
      // 效果定义挂在输入节点的 EffectDefinitions 上，节点没了需重挂。
      eq_def = nullptr;
      limiter_def = nullptr;
    }
    using namespace winrt::Windows::Media::Core;
    using namespace winrt::Windows::Media::Audio;
    winrt::Windows::Foundation::Uri sourceUri{nullptr};
    try {
      sourceUri = winrt::Windows::Foundation::Uri(winrt::hstring(uri));
    } catch (...) {
      std::fprintf(stderr, "[DSPTRACE] RebuildInput FAIL at Uri parse\n");
      return false;
    }
    auto source = MediaSource::CreateFromUri(sourceUri);
    try {
      auto in_op = graph.CreateMediaSourceAudioInputNodeAsync(source);
      if (!WaitAsync(in_op, "RebuildInput node")) return false;
      auto in = in_op.get();
      if (in.Status() != MediaSourceAudioInputNodeCreationStatus::Success) {
        std::fprintf(stderr, "[DSPTRACE] RebuildInput FAIL node status=%d\n",
                     (int)in.Status());
        return false;
      }
      input = in.Node();
      input.AddOutgoingConnection(output);
      AttachInboxEffects();
      ApplyDspStateToEffects();
      input.Start();
      std::fprintf(stderr, "[DSPTRACE] RebuildInput OK\n");
      return true;
    } catch (const winrt::hresult_error& e) {
      std::fprintf(stderr, "[DSPTRACE] RebuildInput FAIL exception: %s\n",
                   winrt::to_string(e.message()).c_str());
      return false;
    }
  }

  void Start() {
    if (!graph) return;
    graph.Start();
  }

  // 验证式启动：MediaSourceAudioInputNode 的媒体是异步打开的，若媒体未 open
  // 就 graph.Start()，节点会**永远不产出**（恒静音，已实测）。这里启动后轮询
  // 节点 Position，未产出就 Stop→Start 重踢，直到数据流动为止。
  void StartVerified() {
    if (!graph) return;
    graph.Start();
    int kicks = 0;
    while (kicks < 4) {
      Sleep(250);
      if (!input || !graph) return;
      const auto pos = input.Position().count();
      if (pos > 0) {
        std::fprintf(stderr, "[DSPTRACE] node producing pos=%lldms kicks=%d\n",
                     (long long)(pos / 10000), kicks);
        return;
      }
      graph.Stop();
      Sleep(80);
      graph.Start();
      kicks++;
      std::fprintf(stderr, "[DSPTRACE] node silent, re-kick #%d\n", kicks);
    }
    std::fprintf(stderr, "[DSPTRACE] node STILL silent after kicks\n");
  }
  void Stop() { if (graph) graph.Stop(); }
  void Close() {
    if (input) input.Close();
    if (output) output.Close();
    if (graph) {
      try { graph.UnrecoverableErrorOccurred(dsp_err_token_); } catch (...) {}
      graph.Close();
    }
    input = nullptr; output = nullptr; graph = nullptr;
    eq_def = nullptr; limiter_def = nullptr;
  }
};

}  // namespace md3music
