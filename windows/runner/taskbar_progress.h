#ifndef RUNNER_TASKBAR_PROGRESS_H_
#define RUNNER_TASKBAR_PROGRESS_H_

#include <windows.h>
#include <shobjidl.h>

#include <cstdint>

// 任务栏按钮进度条的纯计算部分。
//
// 单独抽成纯头文件（不碰 COM、不碰窗口）是为了让 `test/windows/` 下的
// 原生回归测试能在不启动 Flutter、不创建任务栏按钮的前提下直接断言映射规则 ——
// 进度条的坑几乎全在边界上（无歌、时长为 0、位置越过时长、暂停语义），
// 而这些都能用纯函数覆盖。
//
// 与 `ITaskbarList3::SetProgressValue` 的口径一致：Shell 只认
// `completed/total` 两个 ULONG，自身不做任何夹取，传错值表现为
// 「进度条卡在 0%」或「进度条满格不回收」。

/// 一次进度提交的完整快照。
struct TaskbarProgress {
  TBPFLAG state;
  ULONG completed;
  ULONG total;
};

/// 把播放位置换算成任务栏进度。
///
/// 规则（每条都对应一种真实场景）：
/// - `visible == false`（无歌 / 已停止 / 时长未知）→ `TBPF_NOPROGRESS`，
///   把整条进度收掉。留着 0% 的假进度会让任务栏一直显示一条灰条。
/// - `duration_ms <= 0`（流媒体时长未回填、电台）→ 同样收掉：没有分母可算。
/// - `is_playing == false` → `TBPF_PAUSED`（黄色），保留当前值。这是资源管理器
///   「暂停复制」的同一语义，用户一眼能看出「暂停」而不是「播放中卡住」。
/// - `position_ms` 先夹到 `[0, duration_ms]`：seek 越界、平台上报的旧位置
///   （切歌瞬间）都会出现负数或超过总长的值。
/// - `completed` 用四舍五入（`(pos*1000 + dur/2) / dur`），避免 99.96% 显示成
///   99%；`total` 固定 1000，精度足够且不依赖时长单位。
inline TaskbarProgress ResolveTaskbarProgress(int64_t position_ms,
                                              int64_t duration_ms,
                                              bool is_playing, bool visible) {
  constexpr ULONG kTotal = 1000;
  if (!visible || duration_ms <= 0) {
    return TaskbarProgress{TBPF_NOPROGRESS, 0, kTotal};
  }
  int64_t clamped = position_ms;
  if (clamped < 0) clamped = 0;
  if (clamped > duration_ms) clamped = duration_ms;
  // 四舍五入到千分位；clamped 已夹在 [0, duration_ms] 内，结果不会越界，
  // 但仍夹一次兜住 int64 溢出后的异常值。
  ULONG completed =
      static_cast<ULONG>((clamped * kTotal + duration_ms / 2) / duration_ms);
  if (completed > kTotal) completed = kTotal;
  return TaskbarProgress{is_playing ? TBPF_NORMAL : TBPF_PAUSED, completed,
                         kTotal};
}

#endif  // RUNNER_TASKBAR_PROGRESS_H_
