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
pub mod mss_http;
pub mod modules;
pub mod request;
pub mod server;
pub mod simulate;
pub mod spectrum;
pub mod util;

use std::ffi::CStr;
use std::os::raw::{c_char, c_double, c_float, c_int};

// ---------------------------------------------------------------------------
// 纯 C FFI（供 dart:ffi 直接调用）
// ---------------------------------------------------------------------------

/// 启动服务器。port==0 表示随机选端口（被占用则 1s 后换下一个，最多 10 次）。
/// data_dir 用于持久化 device_info.json。返回实际监听端口（0=失败）。
/// # Safety
/// `data_dir` 必须是指向 NUL 结尾 C 字符串的有效指针，调用者需保证生命周期覆盖本次调用。
#[no_mangle]
pub unsafe extern "C" fn start_server(port: c_int, data_dir: *const c_char) -> c_int {
    // 初始化 Android 日志（仅 Android）
    #[cfg(target_os = "android")]
    {
        android_logger::init_once(
            android_logger::Config::default().with_max_level(log::LevelFilter::Info)
        );
    }

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
// 频谱分析 FFI（供 SpectrumPlugin / Dart FFI 调用）
// ---------------------------------------------------------------------------

/// 创建频谱分析器。返回 opaque 指针（null 表示失败）。
#[no_mangle]
pub extern "C" fn spectrum_init() -> *mut spectrum::SpectrumState {
    let boxed = Box::new(spectrum::SpectrumState::new());
    Box::into_raw(boxed)
}

/// 释放频谱分析器。
/// # Safety
/// `state` 必须是由 `spectrum_init` 返回的有效指针，不得 double-free。
#[no_mangle]
pub unsafe extern "C" fn spectrum_drop_state(state: *mut spectrum::SpectrumState) {
    if !state.is_null() {
        drop(Box::from_raw(state));
    }
}

/// 重置内部状态（切歌/重绑时调用）。
/// # Safety
/// `state` 必须是由 `spectrum_init` 返回的有效指针。
#[no_mangle]
pub unsafe extern "C" fn spectrum_reset(state: *mut spectrum::SpectrumState) {
    unsafe { (*state).reset() }
}

/// 向环形缓冲追加一块 PCM 数据。节流满足时自动触发 FFT 并发布帧。
///
/// # Safety
/// - `pcm_ptr` 必须指向至少 `pcm_len` 字节的已初始化内存
/// - `state` 必须是由 `spectrum_init` 返回的有效指针
#[no_mangle]
pub unsafe extern "C" fn spectrum_feed_pcm(
    state: *mut spectrum::SpectrumState,
    pcm_ptr: *const u8,
    pcm_len: usize,
    encoding: c_int,
    sample_rate: c_int,
    channels: c_int,
) {
    if state.is_null() || pcm_ptr.is_null() || pcm_len == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(pcm_ptr, pcm_len) };
    unsafe { (*state).feed_pcm(slice, encoding, sample_rate, channels) }
}

/// Dart 侧轮询：有新帧返回 true 并拷出到 [bands_out] / [features_out]，否则返回 false。
///
/// `bands_out` 至少需要 `spectrum::BAND_COUNT` (40) 个 f64；
/// `features_out` 至少需要 `spectrum::FEATURE_COUNT` (20) 个 f32。
///
/// # Safety
/// `state`, `bands_out`, `features_out` 必须分别是有效指针与足够长的已分配内存。
#[no_mangle]
pub unsafe extern "C" fn spectrum_poll_frame(
    state: *mut spectrum::SpectrumState,
    bands_out: *mut c_double,
    features_out: *mut c_float,
) -> bool {
    if state.is_null() || bands_out.is_null() || features_out.is_null() {
        return false;
    }
    let bands = unsafe { std::slice::from_raw_parts_mut(bands_out, spectrum::BAND_COUNT) };
    let features = unsafe { std::slice::from_raw_parts_mut(features_out, spectrum::FEATURE_COUNT) };
    unsafe { (*state).poll_frame(bands, features) }
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

// ---------------------------------------------------------------------------
// 频谱 JNI（供 SpectrumPlugin.kt 的 external 声明调用）
// ---------------------------------------------------------------------------

/// Java_com_md3music_md3music_SpectrumPlugin_nativeSpectrumFeedPCM(JNIEnv*, jobject,
///     jlong state, jbyteArray pcm, jint encoding, jint sampleRate, jint channels)
///
/// 渲染线程调用：把一块 PCM 数据追加到 Rust 环形缓冲。
/// 状态指针由 Dart 侧 `spectrum_init()` 创建后通过 MethodChannel 传入。
/// Kotlin 侧传完整 PCM 字节数组（无需 offset——调用方已截取所需范围）。
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_md3music_md3music_SpectrumPlugin_nativeSpectrumFeedPCM(
    env: jni::JNIEnv,
    _this: jni::objects::JObject,
    state: jni::sys::jlong,
    pcm: jni::objects::JByteArray,
    encoding: jni::sys::jint,
    sample_rate: jni::sys::jint,
    channels: jni::sys::jint,
) {
    if state == 0 {
        return;
    }
    // 从 JByteArray 按区域拷贝字节到 Rust Vec。
    // jni 0.21 签名：get_byte_array_region(array, start, &mut [i8]) -> Result<()>
    // Kotlin 侧传入的字节数组已截取所需范围，start 恒为 0。
    let len = match env.get_array_length(&pcm) {
        Ok(n) => n as usize,
        Err(_) => return,
    };
    if len == 0 {
        return;
    }
    let mut buf = vec![0i8; len];
    if env.get_byte_array_region(&pcm, 0, &mut buf).is_err() {
        return;
    }
    let ptr = buf.as_ptr() as *const u8;
    let slice = unsafe { std::slice::from_raw_parts(ptr, buf.len()) };
    let state_ptr = state as *mut spectrum::SpectrumState;
    unsafe { (*state_ptr).feed_pcm(slice, encoding, sample_rate, channels) }
}
