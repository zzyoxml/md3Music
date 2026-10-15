#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "floating_lyric_window.h"
#include "media_controls.h"

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
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> lyric_channel_;
  // fluttertoast 在 Windows 无实现，这里用原生 MessageBoxW 兜底 showToast。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> message_channel_;
  FloatingLyricWindow floating_lyric_;
  // Windows 系统媒体传输控件（媒体浮层/锁屏/媒体键）。
  MediaControlsController media_controls_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
