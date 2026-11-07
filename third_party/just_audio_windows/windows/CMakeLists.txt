cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "just_audio_windows")
project(${PROJECT_NAME} LANGUAGES CXX)
set(CPPWINRT_VERSION 2.0.210806.1)
set(CMAKE_CXX_STANDARD 17)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "just_audio_windows_plugin")

add_library(${PLUGIN_NAME} SHARED
  "just_audio_windows_plugin.cpp"
  "player.hpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin
set(just_audio_windows_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===

if (${include_${PROJECT_NAME}_tests})
  set(TEST_RUNNER "${PROJECT_NAME}_test")
  enable_testing()

  # Download googletest. Using the same version as the camera_windows plugin
  # for consistency across Flutter Windows plugins.
  include(FetchContent)
  FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/release-1.11.0.zip
  )
  # Prevent overriding the parent project's compiler/linker settings.
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  # Disable install commands for gtest so it doesn't end up in the bundle.
  set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)

  FetchContent_MakeAvailable(googletest)

  # uri_utils.hpp is a header-only, WinRT-free helper, so the test binary
  # needs no plugin sources or special Windows libraries.
  add_executable(${TEST_RUNNER}
    test/uri_utils_test.cpp
  )
  apply_standard_settings(${TEST_RUNNER})
  target_include_directories(${TEST_RUNNER} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main)

  include(GoogleTest)
  gtest_discover_tests(${TEST_RUNNER})
endif()

