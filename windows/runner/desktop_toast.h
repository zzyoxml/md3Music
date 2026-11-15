#ifndef RUNNER_DESKTOP_TOAST_H_
#define RUNNER_DESKTOP_TOAST_H_

#include <windows.h>
#include <string>

// 不抢焦点的短暂提示；关闭主窗口时主动销毁。
void ShowDesktopToast(HWND owner, const std::wstring& message, bool long_duration);
void CloseDesktopToast();

#endif  // RUNNER_DESKTOP_TOAST_H_
