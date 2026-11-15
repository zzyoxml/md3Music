#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "win32_window.h"
#include "floating_lyric_window.h"
#include "media_controls.h"
#include "spectrum_capture.h"
#include "taskbar_controls.h"
#include "window_placement.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 启动、任务栏重建和隐藏窗口前均确认托盘图标仍然存在。
  bool EnsureTrayIcon();

  // 频谱帧：采集线程写入最新一帧并 PostMessage 唤醒本窗口，这里在平台线程
  // 上补发 onFft（跨线程直接发平台通道消息会要求 messenger 锁）。
  void HandleSpectrumFrame();

  // 启动时按显示器工作区居中，或恢复上次保存的窗口几何。
  void ApplyStartupPlacement();

  // 保存普通态窗口几何（位置/尺寸/最大化）。全屏期间一律跳过。
  void SaveWindowPlacement();

  // Win11 窗口圆角偏好：普通窗口取 ROUND，最大化 / 无边框全屏取 DONOTROUND。
  // Win10 不支持该属性，调用失败静默忽略。
  void ApplyWindowCornerPreference();

  // 屏幕点是否落在窗口缩放边框内：是则返回对应 HT*，否则 HTCLIENT。
  // 顶层 WM_NCHITTEST 与 Flutter 子窗口的命中钩子共用这一份判定。
  LRESULT ResolveResizeHit(POINT screen_point);

  // Flutter 视图子窗口覆盖整个客户区（无边框窗口的客户区=整窗），会把窗口
  // 边缘的缩放热区一并盖住，导致鼠标落点被当成客户区点击、无法拖拽缩放。
  // 子窗口在边缘点返回 HTTRANSPARENT，让系统把命中测试继续落到顶层窗口
  //（同线程的父窗口），由顶层 WM_NCHITTEST 返回 HT* 并进入系统缩放循环。
  static LRESULT CALLBACK ChildHitTestProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           UINT_PTR id, DWORD_PTR ref);

  // 无边框窗口全屏（覆盖整个显示器，含任务栏）。
  //
  // 不用 SW_MAXIMIZE：最大化只铺到工作区（rcWork），任务栏仍可见，
  // 达不到「Zen 完全全屏」的语义。这里临时去掉标题/边框样式，再把窗口
  // 摆到显示器 rcMonitor 上，退出时按进入前的快照（样式 + 窗口位置）恢复。
  // 幂等：已是目标状态时直接返回。
  void SetFullscreen(bool fullscreen);

  // 最大化 / 还原的统一动作（通道 toggleMaximize 与 snap 命中的
  // WM_NCLBUTTONUP 共用），含「最大化/还原不产生 WM_EXITSIZEMOVE，补一次
  // 落盘」的既有口径。
  void ToggleMaximize();

  // snap layouts 悬停反馈：HTMAXBUTTON 命中点变成父窗口非客户区后，
  // Flutter 子窗口收不到该处指针事件（与 W16 的让位机制同源），悬停/按压
  // 高亮改由原生状态经 onCaptionMaxPointerState 回传驱动。仅状态变化时发送。
  void NotifyCaptionMaxPointerState();

  // 广播当前活动登记的行 id（onCaptionMaxTakeover，空串 = 无人接管）。
  // 接管态的**唯一事实源是这条广播**，不是上报返回值——转场中两行并存、
  // 后登记者覆盖时，被覆盖行必须退回纯 Flutter 命中，否则「原生返回
  // HTCLIENT、Flutter 收得到事件」与「Dart 以为自己在接管、订阅着原生
  // 事件」两套状态错位（本地高亮被 Tooltip 撤掉、事件源却不再产生）。
  void NotifyCaptionMaxTakeover();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> lyric_channel_;
  // fluttertoast 在 Windows 无实现，这里使用非模态原生短暂提示。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> message_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  // 音乐频谱：与 Android 同一通道名/同一 onFft 协议，Dart 侧无需分叉。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      spectrum_channel_;
  // 听歌识曲的麦克风枚举（WASAPI capture 端点，见 audio_input_devices.h）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_input_channel_;
  // 听歌识曲的「系统声音」内录：独立实例，走设备环回 + PCM 旁路，
  // 与频谱的 process 环回并行（WASAPI 共享模式允许多客户端）。
  SpectrumCapture system_audio_capture_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_audio_channel_;
  // WASAPI 环回采集（进程环回优先，设备环回兜底）。
  SpectrumCapture spectrum_capture_;
  // 采集线程 → 平台线程的频谱帧信箱（只保留最新一帧，UI 不需要追帧）。
  static constexpr UINT kSpectrumFrameMessage = WM_APP + 2;
  std::mutex spectrum_frame_mutex_;
  std::vector<double> spectrum_pending_bands_;
  bool spectrum_frame_pending_ = false;
  FloatingLyricWindow floating_lyric_;
  // Windows 系统媒体传输控件（媒体浮层/锁屏/媒体键）。
  MediaControlsController media_controls_;
  // 任务栏按钮进度条 + 悬停缩略图工具栏（上一首/播放暂停/下一首）。
  TaskbarControls taskbar_controls_;
  bool tray_icon_added_ = false;
  bool exit_requested_ = false;
  // 当前是否处于无边框全屏。
  bool fullscreen_ = false;
  // 启动时保存的最大化状态：Show() 之后再切最大化（SW_SHOWNORMAL 会还原）。
  bool startup_maximized_ = false;
  // 上一次记录的最大化状态：WM_SIZE 在拖拽缩放时也会发 SIZE_RESTORED，
  // 只有状态真正切换时才需要重设 DWM 圆角偏好。
  bool last_maximized_ = false;
  // Flutter 视图子窗口（命中钩子的挂载目标）。
  HWND child_view_ = nullptr;
  // 自绘最大化按钮的命中登记（客户区坐标、物理像素），由 Dart 侧
  // setCaptionMaxButtonRect 上报，顶层 WM_NCHITTEST 命中返回 HTMAXBUTTON。
  // 单槽 + 行 id：标题栏与播放页顶栏的三键行转场中可短暂并存——后来者
  // 覆盖（Visibility 隐藏即 dispose，被覆盖的行本就不可见）；撤销只有
  // 登记本人（id 相等）有效，迟到的旧行 dispose 不会抹掉新行。
  std::string caption_max_id_;
  RECT caption_max_rect_ = {0, 0, 0, 0};
  // 非客户区命中导致 Flutter 收不到指针事件，这里把 hover/press 状态回传。
  bool caption_hovered_ = false;
  bool caption_pressed_ = false;
  // 进入全屏前的窗口样式（GWL_STYLE）与形态/位置快照，退出全屏时原样恢复。
  LONG_PTR fullscreen_restore_style_ = 0;
  WINDOWPLACEMENT fullscreen_restore_placement_ = {sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
