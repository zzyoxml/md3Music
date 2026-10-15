cmake_minimum_required(VERSION 3.22)
project(usb_audio_driver LANGUAGES CXX)

# USB 独占输出 C++ 驱动（移植自 decent-player libs/decent-usb-audio-driver）
# 与 Rust 侧 libkugou_server.so 完全独立，互不干扰。
# TV flavor 传 -DUSB_DRIVER=OFF：不编译此驱动（libusb_audio_driver.so 不进 TV 包）。
option(USB_DRIVER "Build USB exclusive-output driver" ON)
if(USB_DRIVER)
    add_library(usb_audio_driver SHARED
            usb-audio-output.cpp)

    target_compile_options(usb_audio_driver PRIVATE -fexceptions -frtti)
    target_link_libraries(usb_audio_driver PRIVATE log android)
endif()
