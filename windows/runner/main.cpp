#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shobjidl.h>
#include <shlobj.h>
#include <propsys.h>
#include <propkey.h>

#include <string>

// 单实例唤起需要 EnumWindows / SetWindowPos / FlashWindowEx。
#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

namespace {

// AppUserModelID：Shell 用它把 SMTC 媒体会话、任务栏、通知归属到应用身份。
// 未打包（非 MSIX）的 Win32 exe 不设置 AUMID 时，播控中心会显示
// 「未知应用」+ 默认灰色图标。取与 Runner.rc CompanyName 一致的
// com.md3music 域名前缀，保持稳定不再变更（变更会使旧会话身份失效）。
constexpr wchar_t kAppUserModelId[] = L"com.md3music.md3music";

// 单实例互斥体：Local\ 前缀表示「当前登录会话内唯一」，这正是桌面应用要的语义
// ——同一用户双击多少次都只会有一个实例，而 RDP 多会话各得一份互不干扰。
// 不用 Global\：该命名空间要求 SeCreateGlobalPrivilege，普通用户会话下创建会失败，
// 反而退化成「完全没有单实例保护」。
constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\com.md3music.md3music.single";

// 唤起已有实例的窗口：按窗口类名精确定位，找到后从托盘/最小化恢复并前台化。
//
// 注意两点（都是踩过的坑）：
//  1. **不能过滤 IsWindowVisible**：本应用的「关闭」是隐藏到托盘（WM_CLOSE 里
//     ShowWindow(SW_HIDE)），此时窗口不可见。若按可见性过滤会找不到目标，
//     表现为「已打开，再点便携版没反应」。
//  2. 找到后必须 ShowWindow 出来，否则窗口保持隐藏，同样像没反应。
bool ActivateExistingInstance() {
  struct EnumContext {
    DWORD self_pid;
    HWND found;
  } context{::GetCurrentProcessId(), nullptr};

  ::EnumWindows(
      [](HWND hwnd, LPARAM param) -> BOOL {
        auto* ctx = reinterpret_cast<EnumContext*>(param);
        DWORD window_pid = 0;
        ::GetWindowThreadProcessId(hwnd, &window_pid);
        if (window_pid == 0 || window_pid == ctx->self_pid) return TRUE;
        // 不判可见性：托盘隐藏态也要能唤起（见上方注释 1）。
        // 仍要求无 owner：插件创建的辅助窗口一律跳过。
        if (::GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;
        // 类名必须与 runner 注册的顶层窗口类一致，其他程序窗口不会被误选。
        wchar_t class_name[128] = {};
        if (::GetClassNameW(hwnd, class_name, 128) == 0) return TRUE;
        if (_wcsicmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) {
          return TRUE;
        }
        ctx->found = hwnd;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&context));

  const HWND target = context.found;
  if (target == nullptr) return false;

  // 先恢复显示：托盘隐藏（不可见）与最小化两种情况都要处理。
  if (::IsIconic(target)) {
    ::ShowWindowAsync(target, SW_RESTORE);
  } else if (!::IsWindowVisible(target)) {
    ::ShowWindow(target, SW_SHOWNORMAL);
  }
  // SetForegroundWindow 在前台锁生效时会静默失败；临时置顶再取消可绕过，
  // 且不改变窗口的置顶属性。
  const HWND previous_top = ::GetWindow(target, GW_HWNDPREV);
  ::SetWindowPos(target, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (previous_top != nullptr && !(::GetWindowLongW(target, GWL_EXSTYLE) &
                                   WS_EX_TOPMOST)) {
    ::SetWindowPos(target, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  ::SetForegroundWindow(target);
  FLASHWINFO flash{sizeof(flash), target, FLASHW_ALL | FLASHW_TIMERNOFG, 0, 0};
  ::FlashWindowEx(&flash);
  return true;
}

// SMTC 解析 AUMID → 应用名/图标时，需要在开始菜单里存在一条携带
// System.AppUserModel.ID 属性的快捷方式（名称即应用显示名，图标默认
// 取 exe 内嵌图标）。便携分发没有安装器，这里运行时幂等补建：
// 已存在且 target、图标、AUMID 均正确时跳过；exe 位置变化（debug↔release、
// 移动目录）后下次启动自动改写。任何失败静默降级 —— 只影响播控中心的
// 名称/图标显示，不影响 SMTC 功能本身（与 media_controls 的容错口径一致）。
void EnsureStartMenuAumidShortcut() {
  wchar_t appdata[MAX_PATH] = {};
  const DWORD len = ::GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) return;

  const std::wstring shortcut_path =
      std::wstring(appdata) +
      L"\\Microsoft\\Windows\\Start Menu\\Programs\\MD3Music.lnk";

  wchar_t exe_path[MAX_PATH] = {};
  const DWORD exe_len =
      ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (exe_len == 0 || exe_len >= MAX_PATH) return;

  IShellLinkW* link = nullptr;
  IPersistFile* file = nullptr;
  IPropertyStore* store = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&link));
  if (FAILED(hr) || link == nullptr) return;
  hr = link->QueryInterface(IID_PPV_ARGS(&file));
  if (FAILED(hr) || file == nullptr) {
    link->Release();
    return;
  }

  do {
    // 不能只比对 target：同路径的旧快捷方式也可能缺图标或应用身份。
    // 配置完整时不改写，避免每次启动都触发 Shell 重索引。
    hr = link->QueryInterface(IID_PPV_ARGS(&store));
    if (FAILED(hr) || store == nullptr) break;
    // 更新已有 .lnk 的属性需要可写加载；STGM_READ 会使 Commit 失败。
    WCHAR existing[MAX_PATH] = {};
    WCHAR existing_icon[MAX_PATH] = {};
    int icon_index = -1;
    if (SUCCEEDED(file->Load(shortcut_path.c_str(), STGM_READWRITE)) &&
        SUCCEEDED(link->GetPath(existing, MAX_PATH, nullptr, 0)) &&
        _wcsicmp(existing, exe_path) == 0 &&
        SUCCEEDED(link->GetIconLocation(existing_icon, MAX_PATH, &icon_index)) &&
        _wcsicmp(existing_icon, exe_path) == 0 && icon_index == 0) {
      PROPVARIANT existing_id;
      ::PropVariantInit(&existing_id);
      const HRESULT id_hr = store->GetValue(PKEY_AppUserModel_ID, &existing_id);
      const bool identity_matches = SUCCEEDED(id_hr) &&
          existing_id.vt == VT_LPWSTR && existing_id.pwszVal != nullptr &&
          wcscmp(existing_id.pwszVal, kAppUserModelId) == 0;
      ::PropVariantClear(&existing_id);
      if (identity_matches) break;
    }

    hr = link->SetPath(exe_path);
    if (FAILED(hr)) break;
    // 工作目录取 exe 所在目录（去掉文件名部分）。
    std::wstring dir(exe_path);
    const size_t slash = dir.find_last_of(L"\\/");
    hr = link->SetWorkingDirectory(
        slash == std::wstring::npos ? exe_path : dir.substr(0, slash).c_str());
    if (FAILED(hr)) break;

    // 显式写当前 exe 的图标，防止旧 IconLocation 随目录迁移继续指向失效文件。
    hr = link->SetIconLocation(exe_path, 0);
    if (FAILED(hr)) break;
    PROPVARIANT value;
    ::PropVariantInit(&value);
    value.vt = VT_LPWSTR;
    value.pwszVal = const_cast<wchar_t*>(kAppUserModelId);
    // SetValue 会拷贝值；pwszVal 指向静态常量，绝不能 PropVariantClear
    // （它会对 pwszVal 执行 CoTaskMemFree，释放静态存储 → 堆损坏崩溃）。
    hr = store->SetValue(PKEY_AppUserModel_ID, value);
    value.vt = VT_EMPTY;
    value.pwszVal = nullptr;
    if (FAILED(hr)) break;
    hr = store->Commit();
    if (FAILED(hr)) break;

    hr = file->Save(shortcut_path.c_str(), TRUE);
    if (SUCCEEDED(hr)) {
      // 仅通知本快捷方式更新，不清系统图标缓存、不改用户固定列表。
      ::SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, shortcut_path.c_str(), nullptr);
    }
  } while (false);

  if (store) store->Release();
  if (file) file->Release();
  if (link) link->Release();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例闸门必须排在一切初始化之前：重复实例只做「唤起已有窗口」，
  // 不建 COM、不写快捷方式、不加载引擎，秒退。
  {
    ::SetLastError(ERROR_SUCCESS);
    HANDLE instance_mutex =
        ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    const DWORD mutex_error = ::GetLastError();
    if (instance_mutex != nullptr && mutex_error == ERROR_ALREADY_EXISTS) {
      ::CloseHandle(instance_mutex);
      ActivateExistingInstance();
      return EXIT_SUCCESS;
    }
    // 互斥体故意不释放：交给进程退出时由系统回收，生命周期即进程生命周期。
    // mutex_error 为 ACCESS_DENIED 等异常时照常启动：宁可多开一次，也不能
    // 因为拿不到锁让用户完全打不开应用。
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // AUMID 必须在创建窗口 / 初始化 SMTC 之前设置，进程级一次即可。
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  EnsureStartMenuAumidShortcut();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"md3Music", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
