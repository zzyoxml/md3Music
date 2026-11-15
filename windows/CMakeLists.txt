# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(md3Music LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "md3Music")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# 新 MSVC 会把 <experimental/coroutine>/<await> 的弃用告警升级为编译错误（STL1011），
# 导致 permission_handler_windows 等插件编译失败。此处统一抑制该告警。
# 注意：仅作用于 Windows 构建，不影响 Android 打包。
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

if(MSVC)
  # 中文系统代码页(936/GBK)下，UTF-8 编码的插件源文件会触发 C4819 警告，
  # 再被 APPLY_STANDARD_SETTINGS 的 /WX 升级为编译错误（C2220），导致
  # just_audio_windows 等插件在本机(zh-CN)构建失败。CI 的 en-US 代码页不触发。
  # 强制按 UTF-8 解析源文件并忽略 C4819，解决本机智建失败。
  add_compile_options(/utf-8 /wd4819)
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# === 预下载 WIL (Windows Implementation Library) NuGet 包 ===
# video_player_win 在【构建期】用自定义目标下载 WIL，却没为 video_player_win_plugin
# 声明对该目标的依赖；而 CMake 生成的 vcxproj 里 WIL 的 .targets 导入带
# Condition="Exists(...)"。MSBuild 并行构建时插件工程可能先于下载完成被加载 →
# 导入被静默跳过 → AdditionalIncludeDirectories 缺 WIL 头文件路径 →
# error C1083: Cannot open include file: 'wil/com.h'。
# 本机因 packages/ 有上次构建的残留而侥幸成功，CI 全新 clone 必然失败。
# 这里在【配置期】提前装好，保证生成 vcxproj 时 .targets 已存在。
# 版本须与 video_player_win/windows/CMakeLists.txt 的 WIL_VERSION 保持一致。
if(EXISTS "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/video_player_win")
  set(WIL_VERSION "1.0.220914.1")
  set(WIL_TARGETS_FILE
    "${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary/build/native/Microsoft.Windows.ImplementationLibrary.targets")
  if(NOT EXISTS "${WIL_TARGETS_FILE}")
    find_program(NUGET_EXE nuget)
    if(NOT NUGET_EXE)
      set(NUGET_EXE "${CMAKE_BINARY_DIR}/nuget.exe")
      if(NOT EXISTS "${NUGET_EXE}")
        message(STATUS "下载 nuget.exe ...")
        file(DOWNLOAD
          "https://dist.nuget.org/win-x86-commandline/v5.10.0/nuget.exe"
          "${NUGET_EXE}"
          EXPECTED_HASH SHA256=852b71cc8c8c2d40d09ea49d321ff56fd2397b9d6ea9f96e532530307bbbafd3)
      endif()
    endif()
    message(STATUS "预下载 WIL ${WIL_VERSION}（video_player_win 依赖）...")
    execute_process(
      COMMAND "${NUGET_EXE}" install Microsoft.Windows.ImplementationLibrary
              -Version ${WIL_VERSION} -ExcludeVersion
              -OutputDirectory "${CMAKE_BINARY_DIR}/packages"
      RESULT_VARIABLE WIL_INSTALL_RESULT
      OUTPUT_VARIABLE WIL_INSTALL_OUTPUT
      ERROR_VARIABLE WIL_INSTALL_OUTPUT)
    if(NOT WIL_INSTALL_RESULT EQUAL 0 OR NOT EXISTS "${WIL_TARGETS_FILE}")
      message(FATAL_ERROR
        "WIL NuGet 包预下载失败，video_player_win 将因缺少 wil/com.h 编译失败：\n"
        "${WIL_INSTALL_OUTPUT}")
    endif()
  endif()
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === ATL 静态库兜底（flutter_secure_storage_windows 依赖 atls.lib） ===
# 该插件源码 include <atlstr.h>，CA2W/CW2A 等符号定义在 ATL 静态库 atls.lib
# 里（经 <atlstr.h> 的 #pragma comment(lib,"atls.lib") 隐式链接）。
# 本机 Build Tools 只装了 Spectre 版 ATL（atlmfc\lib\spectre\x64\atls.lib），
# 标准版 atlmfc\lib\x64 缺失 → vcvars 的 LIB 里没有 ATL 库路径 → 链接期
# LNK1104: 无法打开 atls.lib。Spectre 库与标准库 ABI 兼容（仅多 Spectre 缓解
# 指令，混链到非 /Qspectre 目标安全），这里给该插件补 spectre 库搜索路径兜底。
if(TARGET flutter_secure_storage_windows_plugin)
  # CMAKE_CXX_COMPILER = ...\MSVC\<ver>\bin\Hostx64\x64\cl.exe
  get_filename_component(_md3_msvc_bin "${CMAKE_CXX_COMPILER}" DIRECTORY)
  get_filename_component(_md3_msvc_ver "${_md3_msvc_bin}/../../.." ABSOLUTE)
  set(_md3_atl_spectre_lib "${_md3_msvc_ver}/atlmfc/lib/spectre/x64")
  if(EXISTS "${_md3_atl_spectre_lib}/atls.lib")
    target_link_directories(flutter_secure_storage_windows_plugin PRIVATE
      "${_md3_atl_spectre_lib}")
  endif()
endif()


# === 复制 Rust 本地 API 服务器 dll 到 exe 同目录 ===
# 桌面版 kugou_server.dll 由 kugou_api_server\rust\build_desktop.ps1 产出。
# 打包脚本(scripts\md3.ps1 windows)只在 release 构建后手动复制，导致
# `flutter run --debug` 时 DynamicLibrary.open('kugou_server.dll') 找不到 dll，
# 本地 API 服务器无法启动 → 所有酷狗联网请求失败（搜索/播放/歌词全挂），
# 且会误触播放列表"自动切下一首"。
# 这里统一在构建 exe 后自动复制，Debug/Release 构建都带上，开发调试即可联网。
set(KUGOU_SERVER_DLL
  "${CMAKE_CURRENT_SOURCE_DIR}/../kugou_api_server/rust/target/release/kugou_server.dll")
if(EXISTS "${KUGOU_SERVER_DLL}")
  # md3Music target 在 runner/CMakeLists.txt 创建，本目录无法对它加 POST_BUILD。
  # 用 ALL 自定义目标，每次构建都执行复制，Debug/Release 均带上 dll。
  add_custom_target(kugou_server_dll_copy ALL
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${KUGOU_SERVER_DLL}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/kugou_server.dll"
    COMMENT "复制 kugou_server.dll 到 exe 目录")
else()
  # 必须是 FATAL_ERROR 而不是 WARNING：缺 dll 的包能构建成功、能启动、能显示 UI，
  # 但 DynamicLibrary.open 失败后所有 API 请求都打不出去（历史上表现为
  # "延迟极高 + 资源加载不出来"）。WARNING 会被 flutter build 的输出刷掉，
  # 残包直到用户运行时才暴露问题。宁可构建期就失败。
  message(FATAL_ERROR
    "未找到 kugou_server.dll：${KUGOU_SERVER_DLL}\n"
    "先运行 kugou_api_server\\rust\\build_desktop.ps1 编译（或直接用 scripts\\md3.ps1 windows 一键构建），"
    "否则本地 API 服务器无法启动，App 无法联网。")
endif()

# === 复制 ONNX Runtime 与深度模型到 exe 同目录（3D 封面，可选能力） ===
# Dart FFI 后端（--dart-define=DEPTH_BACKEND=dart_ffi）用 dart:ffi 打开 exe 同目录的
# onnxruntime.dll 做深度推理，模型从 exe 同目录的 depth_model\ 子目录按文件名加载。
# 运行时来源：windows/vendor/onnxruntime/（官方 win-x64 zip 里挑的两个 dll，**不入库**，
# 缺失时由 scripts\md3.ps1 windows -With3D 按固定版本 + SHA256 下载；CI/发布包不带 3D，
# 因此既不下载也不随包；见该脚本头部常量）。
# 模型来源：android/app/src/depth3d/assets/models/（已入库，直接拷贝，不进 flutter_assets
# —— 否则 Android APK 被这约 30MB 资产增重）。
#
# 与上面 kugou_server.dll 的处理**故意不同**：那里 FATAL_ERROR，这里只 WARNING。
# 理由：kugou_server.dll 缺失会打出「能开、能显示 UI、但完全不能联网」的残包，用户无从
# 判断原因，必须构建期就失败；3D 封面是可选能力，运行时缺 dll 时 App 只提示一次并回落
# 平面封面（其余功能完全正常）。若这里也硬失败，所有还没取过 ONNX Runtime 的开发者
# （含离线环境、以及只做普通功能改动的贡献者）连 `flutter run -d windows` 都起不来，
# 代价远大于收益。
set(ORT_VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/onnxruntime")
# onnxruntime_providers_shared.dll 是 CPU EP 运行必需的配套 dll（provider bridge 的共享
# 符号在其中），漏带会让 CreateSession 失败，必须与主 dll 成对复制，因此两个都在才算就位。
if(EXISTS "${ORT_VENDOR_DIR}/onnxruntime.dll" AND
   EXISTS "${ORT_VENDOR_DIR}/onnxruntime_providers_shared.dll")
  add_custom_target(depth_runtime_copy ALL
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${ORT_VENDOR_DIR}/onnxruntime.dll"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/onnxruntime.dll"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${ORT_VENDOR_DIR}/onnxruntime_providers_shared.dll"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/onnxruntime_providers_shared.dll"
    COMMENT "复制 onnxruntime dll 到 exe 目录（3D 封面）")
else()
  message(WARNING
    "未找到 ONNX Runtime：${ORT_VENDOR_DIR}/onnxruntime.dll\n"
    "3D 封面将不可用（App 内提示一次并回落平面封面），其余功能不受影响。\n"
    "要启用：运行 scripts\\md3.ps1 windows（自动按固定版本下载并校验），或手动下载官方\n"
    "onnxruntime-win-x64 zip，把 lib\\onnxruntime.dll 与 lib\\onnxruntime_providers_shared.dll\n"
    "（1.30.0 在 lib\\ 下，更早版本在 bin\\）放到 windows\\vendor\\onnxruntime\\。\n"
    "注意本判断在【配置期】做：补齐 dll 后需让 CMake 重新配置（flutter clean，或删除\n"
    "build\\windows）才会生成复制目标；否则只有构建脚本/CI 会把 dll 放进 Release 目录。")
endif()

set(DEPTH_MODEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../android/app/src/depth3d/assets/models")
if(EXISTS "${DEPTH_MODEL_DIR}/depth_anything_v2_vits_q4f16.onnx" AND
   EXISTS "${DEPTH_MODEL_DIR}/migan512_pipeline_int8.onnx")
  # 两份模型逐条 copy（每条一个源文件、路径整体加引号）：仓库路径可能含空格
  #（本机即 "TRAE SOLO"），把多个文件塞进同一条 copy 的参数列表容易被生成器拆错。
  add_custom_target(depth_model_copy ALL
    # 目标子目录不存在时 copy_if_different 不会自建，先显式创建。
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/depth_model"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${DEPTH_MODEL_DIR}/depth_anything_v2_vits_q4f16.onnx"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/depth_model/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${DEPTH_MODEL_DIR}/migan512_pipeline_int8.onnx"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/depth_model/"
    COMMENT "复制深度模型到 exe 目录的 depth_model\\（3D 封面）")
else()
  message(WARNING
    "未找到深度模型：${DEPTH_MODEL_DIR}\n"
    "3D 封面不可用（App 内提示一次并回落平面封面），其余功能不受影响。\n"
    "仓库正常应带这两份 .onnx（depth_anything_v2_vits_q4f16.onnx / migan512_pipeline_int8.onnx），"
    "缺失请先 git checkout -- android/app/src/depth3d/assets/models 恢复。")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# 仅 Windows 便携包携带字体；不写入 pubspec.yaml，Android/TV APK 不包含它。
install(FILES
  "${CMAKE_SOURCE_DIR}/runner/fonts/SOURCEHANSANSCN-MEDIUM.OTF"
  "${CMAKE_SOURCE_DIR}/runner/fonts/LICENSE-APACHE-2.0.txt"
  "${CMAKE_SOURCE_DIR}/runner/fonts/NOTICE.txt"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/fonts" COMPONENT Runtime)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
