#ifndef RUNNER_TASKBAR_CONTROLS_H_
#define RUNNER_TASKAR_CONTROLS_H_

#include <windows.h>
#include <shobjidl.h>

#include <cstdint>
#include <functional>
#include <string>

#include "taskbar_progress.h"

// Windows 任务栏按钮的进度条 + 缩略图工具栏（鼠标悬停任务栏图标时出现的
// 上一首 / 播放暂停 / 下一首）。
//
// ## 与 SMTC（media_controls.cpp）的分工
//
// 两者是**互不相干的两套系统入口**，都只是把动作回传给 Dart，Dart 侧共用
// `MediaNotificationService` 的同名回调：
// - SMTC：媒体浮层（Win+G / 锁屏 / 音量浮层）、键盘媒体键、系统播放控制中心；
// - 本类：任务栏图标下的进度条与悬停缩略图按钮（鼠标用户的主入口）。
//
// 因此这里**不自己维护播放状态机**：Dart 侧每次状态变化下发一次快照，
// 本类只负责「把快照翻译成 Shell 调用」，并按值去重避免高频重绘。
//
// ## 三个必须等对时机的点
//
// 1. `ITaskbarList3` 必须在**任务栏按钮已创建**之后才能加缩略图按钮，
//    否则 `ThumbBarAddButtons` 直接失败。首次创建窗口时按钮往往还没好，
//    所以靠 `TaskbarButtonCreated` 注册消息兜底重试（`EnsureButtons`）。
// 2. Explorer 重启后旧的 `ITaskbarList3` 与按钮**全部失效**，且窗口会收到
//    `TaskbarCreated`（注意：与上面那个 `TaskbarButtonCreated` 是两个不同的
//    注册消息，名字只差一个 Button）。必须重建 COM 对象并重加按钮，
//    否则表现为「重启 Explorer 后悬停没有按钮了」。
// 3. `THBN_CLICKED` 走 `WM_COMMAND`，必须在把消息交给 Flutter 引擎之前吃掉，
//    否则引擎可能先消费掉这条命令。
//
// 失败一律静默降级（与 media_controls_ 同口径）：任务栏集成不可用不影响播放。
class TaskbarControls {
 public:
  // 回传动作，方法名与 Dart 侧 MediaNotificationService 的 case 一致：
  // "previous" / "next" / "togglePlayPause"。
  using ActionCallback = std::function<void(const std::string& action)>;

  TaskbarControls() = default;
  ~TaskbarControls();

  TaskbarControls(const TaskbarControls&) = delete;
  TaskbarControls& operator=(const TaskbarControls&) = delete;

  // 绑定窗口并创建 ITaskbarList3。失败返回 false（不致命）。
  bool Initialize(HWND hwnd, ActionCallback on_action);

  // 释放 COM 与图标，幂等。
  void Shutdown();

  // 提交一次播放进度快照。内部按 (状态, 进度值) 去重，重复调用零成本。
  // visible=false 表示「没有可展示的进度」（无歌 / 已停止），收起进度条。
  void SetState(int64_t position_ms, int64_t duration_ms, bool is_playing,
                bool visible);

  // Explorer 重启（TaskbarCreated）：重建 COM 对象并重加按钮。
  void OnTaskbarCreated();

  // 处理窗口消息。返回 true 表示已被本类消费。
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  // 任务栏按钮就绪后加/换缩略图按钮。失败不致命，等下一次时机重试。
  void EnsureButtons();
  // 只换播放/暂停那一枚图标（播放态翻转时用，避免整排重加）。
  void UpdatePlayPauseButton();
  // 把 last_progress_ 重新提交给 Shell。
  //
  // Explorer 重启 / 按钮延迟就绪之后必须补这一下：暂停时 Dart 侧的位置流是
  // 停的（暂停没有新位置可推），只等下一次 SetState 会让进度条一直空着，
  // 直到用户手动播放或切歌才回来。
  void ReplayProgress();
  // 真正调 Shell 的那一层（SetState 与 ReplayProgress 共用）。
  void ApplyProgress(const TaskbarProgress& progress);
  bool LoadIcons();
  void ReleaseIcons();
  // 按系统「应用使用浅色主题」决定图标用深色还是浅色字形。
  void RefreshTheme();

  HWND hwnd_ = nullptr;
  ITaskbarList3* list_ = nullptr;
  ActionCallback on_action_;
  bool initialized_ = false;
  bool buttons_added_ = false;
  bool is_playing_ = false;
  // 最近一次成功提交的进度，用于去重（Shell 每次 SetProgressValue 都会重绘）。
  TaskbarProgress last_progress_{TBPF_NOPROGRESS, 0, 0};
  bool has_last_progress_ = false;
  // 图标缓存：0=上一首 1=播放 2=暂停 3=下一首（当前主题那一套）。
  HICON icons_[4] = {nullptr, nullptr, nullptr, nullptr};
  bool icons_loaded_ = false;
  bool light_theme_ = false;
};

#endif  // RUNNER_TASKBAR_CONTROLS_H_
