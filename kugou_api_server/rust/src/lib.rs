//! kugou_server — Rust 实现的酷狗 API 本地服务器（libkugou_server.so）。
//!
//! 取代 libnode.so + server_bundle.js：在进程内启动 tiny_http 服务，监听
//! 127.0.0.1 上的随机端口（端口号回传给 Dart），行为等价于 kugou_api_server/server.js。
//!
//! 对外接口：
//!  - JNI：Java_com_md3music_premium_KugouApiService_{nativeStartNode,nativeIsNodeRunning,nativeStopNode}
//!  - 纯 C FFI：start_server / stop_server / is_server_running / get_server_port

pub mod cache;
pub mod config;
pub mod crypto;
pub mod device;
pub mod helper;
pub mod modules;
pub mod request;
pub mod server;
pub mod simulate;
pub mod util;

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

// ---------------------------------------------------------------------------
// 纯 C FFI（供 dart:ffi 直接调用）
// ---------------------------------------------------------------------------

/// 启动服务器。port==0 表示随机选端口（被占用则 1s 后换下一个，最多 10 次）。
/// data_dir 用于持久化 device_info.json。返回实际监听端口（0=失败）。
/// # Safety
/// `data_dir` 必须是指向 NUL 结尾 C 字符串的有效指针，调用者需保证生命周期覆盖本次调用。
#[no_mangle]
pub unsafe extern "C" fn start_server(port: c_int, data_dir: *const c_char) -> c_int {
    if data_dir.is_null() {
        return 0;
    }
    let dir = unsafe { CStr::from_ptr(data_dir) }
        .to_string_lossy()
        .into_owned();
    match server::start(port as u16, dir) {
        Some(p) => p as c_int,
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn stop_server() {
    server::stop();
}

#[no_mangle]
pub extern "C" fn is_server_running() -> c_int {
    if server::is_running() {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn get_server_port() -> c_int {
    server::get_port() as c_int
}

// ---------------------------------------------------------------------------
// JNI（供 KugouApiService.kt 的 external 声明调用）
// ---------------------------------------------------------------------------

/// Java_com_md3music_premium_KugouApiService_nativeStartNode(JNIEnv*, jobject, jint port, jstring dataDir)
/// port==0 表示随机选端口。返回实际监听端口（0=失败）。
/// 仅 Android 构建导出（桌面用纯 C FFI，不编译 JNI 符号）。
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_md3music_premium_KugouApiService_nativeStartNode(
    mut env: jni::JNIEnv,
    _this: jni::objects::JObject,
    port: jni::sys::jint,
    data_dir: jni::objects::JString,
) -> jni::sys::jint {
    let dir: String = match env.get_string(&data_dir) {
        Ok(s) => s.into(),
        Err(_) => String::new(),
    };
    match server::start(port as u16, dir) {
        Some(p) => p as jni::sys::jint,
        None => 0,
    }
}

/// Java_com_md3music_premium_KugouApiService_nativeIsNodeRunning(JNIEnv*, jobject)
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_md3music_premium_KugouApiService_nativeIsNodeRunning(
    _env: jni::JNIEnv,
    _this: jni::objects::JObject,
) -> jni::sys::jboolean {
    if server::is_running() {
        1
    } else {
        0
    }
}

/// Java_com_md3music_premium_KugouApiService_nativeStopNode(JNIEnv*, jobject)
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_md3music_premium_KugouApiService_nativeStopNode(
    _env: jni::JNIEnv,
    _this: jni::objects::JObject,
) {
    server::stop();
}
