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


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === 复制 Rust 本地 API 服务器 dll 到 exe 同目录 ===
# 桌面版 kugou_server.dll 由 kugou_api_server\rust\build_desktop.ps1 产出。
# 打包脚本(scripts\build_windows.ps1)只在 release 构建后手动复制，导致
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
  message(WARNING
    "未找到 kugou_server.dll：${KUGOU_SERVER_DLL}\n"
    "先运行 kugou_api_server\\rust\\build_desktop.ps1 编译，否则本地 API 服务器无法启动，App 无法联网。")
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
