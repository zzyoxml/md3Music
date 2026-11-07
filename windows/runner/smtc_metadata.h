#ifndef RUNNER_SMTC_METADATA_H_
#define RUNNER_SMTC_METADATA_H_

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cwchar>
#include <cwctype>
#include <string>

// 对外 SMTC 发布口径的纯计算部分。
//
// 单独抽成纯头文件（不碰 COM、不碰窗口、不引 winrt）是为了让 `test/windows/`
// 下的原生回归测试能在不启动 Flutter、不初始化 SMTC 的前提下直接断言这些规则 ——
// 它们全是「改错了不会报错、只会让第三方歌词工具静默失效」的类型：
//
// - **占位符清洗**：App 内部用「未知歌手 / 未知艺术家 / 未知歌曲 / 未知专辑」
//   表示「没有这个字段」。直接下发会让外部工具当成真实值：TaskbarLyrics 的
//   `HasUsefulArtist` 只认英文 `unknown artist`、`IsUnknownTitle` 只认
//   `Unknown Title`，中文占位符于是被算成「有效歌手」，artist 相似度≈0、
//   总分跌破 80 分门槛 → 直接取不到词。
// - **播放倍速**：`ISystemMediaTransportControls2::PlaybackRate` 不发布时
//   外部工具一律按 1.0x 外推时间轴，1.25x/1.5x 播放时歌词会越拖越远。
// - **时间轴夹取**：切歌瞬间平台会报上「上一首的位置」或负数，外部工具拿它
//   算行索引会越界。
// - **播放状态**：退出 App / 空闲停播必须发 `Stopped`（而不是 `Paused`），
//   否则播控中心与第三方工具会一直挂着上一首的卡片和歌词。

namespace smtc_metadata {

// 与 winrt::Windows::Media::MediaPlaybackStatus 的数值一一对应。
//
// 刻意不引 winrt：纯函数头要能被 `cl` 单独编译（测试 harness 不链 windowsapp.lib）。
// 数值由 `test/windows/smtc_metadata_test.py` 对着 SDK 头做交叉断言钉住。
inline constexpr int kStatusStopped = 2;
inline constexpr int kStatusPlaying = 3;
inline constexpr int kStatusPaused = 4;

// App 支持的倍速区间（与 PlayerProvider.setSpeed 的 clamp 一致）。
inline constexpr double kMinPlaybackRate = 0.25;
inline constexpr double kMaxPlaybackRate = 4.0;

namespace detail {

/// 去掉首尾空白（ASCII 空白 + 全角空格 U+3000）。
///
/// 全角空格必须一起处理：中文标签里「未知歌手　」这种尾随全角空格很常见，
/// 只 trim ASCII 会让清洗失效，占位符又漏回外部工具。
inline std::wstring Trim(const std::wstring& value) {
  std::size_t begin = 0;
  std::size_t end = value.size();
  while (begin < end) {
    const wchar_t ch = value[begin];
    if (ch == L' ' || ch == L'\t' || ch == L'\r' || ch == L'\n' ||
        ch == 0x3000) {
      ++begin;
      continue;
    }
    break;
  }
  while (end > begin) {
    const wchar_t ch = value[end - 1];
    if (ch == L' ' || ch == L'\t' || ch == L'\r' || ch == L'\n' ||
        ch == 0x3000) {
      --end;
      continue;
    }
    break;
  }
  return value.substr(begin, end - begin);
}

/// 大小写不敏感比较（只对 ASCII 有意义，中文占位符按原样比）。
inline bool EqualsIgnoreCase(const std::wstring& left, const wchar_t* right) {
  const std::size_t right_length = std::wcslen(right);
  if (left.size() != right_length) return false;
  for (std::size_t i = 0; i < right_length; ++i) {
    const wchar_t a = static_cast<wchar_t>(std::towlower(left[i]));
    const wchar_t b = static_cast<wchar_t>(std::towlower(right[i]));
    if (a != b) return false;
  }
  return true;
}

}  // namespace detail

/// 把 App 内部的占位值换成空串，避免外部工具当成真实元数据。
///
/// 只清「明确的占位值」，不猜内容：真实歌名恰好叫「未知」这类边界不受影响。
/// 返回空串表示「这个字段没有值」，调用方据此决定是否写进 SMTC（写空串会覆盖
/// 系统上一次的值，比不写更糟）。
inline std::wstring SanitizeText(const std::wstring& value) {
  const std::wstring trimmed = detail::Trim(value);
  if (trimmed.empty()) return std::wstring();
  static const wchar_t* const kPlaceholders[] = {
      L"未知歌手", L"未知艺术家", L"未知艺人", L"未知歌曲", L"未知专辑",
      L"未知",     L"Unknown Title", L"Unknown Artist", L"Unknown Album",
      L"unknown",
  };
  for (const wchar_t* placeholder : kPlaceholders) {
    if (detail::EqualsIgnoreCase(trimmed, placeholder)) return std::wstring();
  }
  return trimmed;
}

/// App 倍速 → SMTC PlaybackRate。
///
/// 非有限值、非正数、超出 App 支持区间一律回 1.0：外部工具按错误倍速外推
/// 会让歌词持续漂移，比「按 1.0x 播」（至少暂停/切歌会重新对齐）更糟。
inline double ResolvePlaybackRate(double app_speed) {
  if (!std::isfinite(app_speed)) return 1.0;
  if (app_speed < kMinPlaybackRate || app_speed > kMaxPlaybackRate) return 1.0;
  return app_speed;
}

/// 时间轴夹取。`duration_ms <= 0` 返回 false（此时不该推时间轴）。
///
/// 位置先夹到 `[0, duration]`：切歌瞬间平台会上报上一首的位置、seek 越界、
/// 拖回 0 之前都可能出现越界值，外部工具拿它算歌词行索引会直接越界。
inline bool ResolveTimeline(int64_t position_ms, int64_t duration_ms,
                            int64_t* out_position, int64_t* out_duration) {
  if (duration_ms <= 0) return false;
  int64_t clamped = position_ms;
  if (clamped < 0) clamped = 0;
  if (clamped > duration_ms) clamped = duration_ms;
  if (out_position != nullptr) *out_position = clamped;
  if (out_duration != nullptr) *out_duration = duration_ms;
  return true;
}

/// 播放状态映射。
///
/// `stopped` 优先于 `is_playing`：退出 App / 空闲停播走的是「主动结束」路径，
/// 必须发 Stopped 才能让系统清掉卡片；发 Paused 会让卡片永远停在上一首。
inline int ResolvePlaybackStatus(bool is_playing, bool stopped) {
  if (stopped) return kStatusStopped;
  return is_playing ? kStatusPlaying : kStatusPaused;
}

}  // namespace smtc_metadata

#endif  // RUNNER_SMTC_METADATA_H_
