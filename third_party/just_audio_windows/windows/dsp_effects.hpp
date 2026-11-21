// dsp_effects.hpp
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace md3music::dsp {

// 与 Android ViperMasterService._maxGainDb 一致
inline constexpr double kMaxGainDb = 12.0;
// 与 XAPOFX fxeq 常量一致（官方 AudioCreation 示例）
inline constexpr double kLinearMin = 0.126;
inline constexpr double kLinearMax = 7.94;

inline double DbToLinear(double db) { return std::pow(10.0, db / 20.0); }
inline double LinearToDb(double linear) { return 20.0 * std::log10(linear); }
inline double ClampDb(double db) {
  return std::clamp(db, -kMaxGainDb, kMaxGainDb);
}

// 对频率取对数后按段中心均分，取落在各区间的增益最大值（保留预设特征）
inline std::array<double, 4> Downsample10To4(
    const std::array<double, 10>& gains10) {
  // 10 段中心频率，与 ViperMasterService.bandFrequencies 一致
  constexpr std::array<double, 10> kBandHz = {
      31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
  // 4 段实测默认中心 100/800/2000/10000 Hz（见 Spike 报告），边界取相邻几何平均
  constexpr std::array<double, 3> kBounds = {283.0, 1265.0, 4472.0};
  std::array<double, 4> out{};
  for (int i = 0; i < 10; ++i) {
    int zone = (kBandHz[i] < kBounds[0]) ? 0
             : (kBandHz[i] < kBounds[1]) ? 1
             : (kBandHz[i] < kBounds[2]) ? 2 : 3;
    // windows.h 的 max 宏会破坏 std::max 调用，加括号阻止宏展开。
    out[zone] = (std::max)(out[zone], gains10[i]);
  }
  return out;
}

inline std::array<double, 4> Downsample5To4(
    const std::array<double, 5>& gains5) {
  // EqualizerService._zoneBoundaries = [250, 500, 2000, 6000]（mHz 转 Hz 后的区域）
  // 5 区 → 4 段：合并 lowmid(250-500) 与 mid(500-2000) 中绝对值较大者
  std::array<double, 4> out = {gains5[0], gains5[1], gains5[3], gains5[4]};
  if (std::abs(gains5[2]) > std::abs(out[1])) out[1] = gains5[2];
  if (std::abs(gains5[2]) > std::abs(out[2])) out[2] = gains5[2];
  return out;
}

// 全局 DSP 状态：插件级 MethodChannel 与每个 AudioPlayer 实例之间的桥。
// 参照 Android ViperMasterProcessor.INSTANCES 的静态广播表：channel handler
// 只写这里，再通知所有活着的播放器刷新自己的 dsp_active_ 与 EQ 增益，
// 避免「开关已开启但正在播放的实例仍是 MediaPlayer」的假成功。
class DspState {
 public:
  struct Snapshot {
    bool enabled;
    std::array<double, 10> viper_gains;  // 10 段母带增益（dB）
    std::array<double, 4> eq_db;         // 4 段内置 EQ 生效增益（dB）
    int preset_index;                    // 当前 EQ 预设索引
    std::uint64_t epoch;                 // 图代次：release 时递增，触发实例释放旧图
  };

  static DspState& Instance() {
    static DspState instance;
    return instance;
  }

  // 读一致性快照。NotifyAll 在调用回调前已释放锁，故回调内调用本方法安全。
  Snapshot Read() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return Snapshot{enabled_, viper_gains_, eq_db_, preset_index_, epoch_};
  }

  // 播放器实例注册/反注册；key 用实例 this 指针，析构时精确移除。
  void Register(void* key, std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    listeners_[key] = std::move(callback);
  }
  void Unregister(void* key) {
    std::lock_guard<std::mutex> lock(mutex_);
    listeners_.erase(key);
  }

  // 遍历通知所有活着的播放器。先拷贝回调再释放锁：既避免回调读快照时死锁，
  // 也避免某个实例在回调中反注册导致迭代器失效。
  void NotifyAll() {
    std::vector<std::function<void()>> snapshot;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      snapshot.reserve(listeners_.size());
      for (auto& entry : listeners_) snapshot.push_back(entry.second);
    }
    for (auto& callback : snapshot) {
      if (callback) callback();
    }
  }

  void SetEnabled(bool enabled) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      enabled_ = enabled;
    }
    std::fprintf(stderr, "[DSPTRACE] DspState::SetEnabled=%d listeners=%zu\n",
                 enabled ? 1 : 0, listeners_.size());
    NotifyAll();
  }

  // 蝰蛇 10 段增益写入；同时降采样为 4 段内置 EQ 的生效值。
  void SetViperGains(const std::array<double, 10>& gains) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      viper_gains_ = gains;
      eq_db_ = Downsample10To4(gains);
    }
    NotifyAll();
  }

  // 均衡器单段增益（mB→dB 已由调用方换算）；写回后置为「自定义」。
  void SetEqBand(int band, double db) {
    if (band < 0 || band >= 4) return;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      eq_db_[band] = ClampDb(db);
      preset_index_ = -1;
    }
    std::fprintf(stderr, "[DSPTRACE] SetEqBand band=%d db=%.2f eq=[%.2f,%.2f,%.2f,%.2f]\n",
                 band, db, eq_db_[0], eq_db_[1], eq_db_[2], eq_db_[3]);
    NotifyAll();
  }

  // 均衡器预设：5 段 dB 由调用方降采样为 4 段后传入。
  void SetEqPreset(int index, const std::array<double, 4>& db) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      eq_db_ = db;
      preset_index_ = index;
    }
    std::fprintf(stderr, "[DSPTRACE] SetEqPreset index=%d eq=[%.2f,%.2f,%.2f,%.2f]\n",
                 index, db[0], db[1], db[2], db[3]);
    NotifyAll();
  }

  // release：退回 MediaPlayer 并让所有实例释放已建的 AudioGraph。
  void RequestRelease() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      enabled_ = false;
      ++epoch_;
    }
    NotifyAll();
  }

 private:
  DspState() = default;
  DspState(const DspState&) = delete;
  DspState& operator=(const DspState&) = delete;

  mutable std::mutex mutex_;
  bool enabled_ = false;
  std::array<double, 10> viper_gains_{};
  std::array<double, 4> eq_db_{};
  int preset_index_ = 0;
  std::uint64_t epoch_ = 0;
  std::unordered_map<void*, std::function<void()>> listeners_;
};

}  // namespace md3music::dsp
