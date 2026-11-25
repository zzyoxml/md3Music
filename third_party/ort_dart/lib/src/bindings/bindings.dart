import 'dart:ffi';
import 'dart:io';

import 'package:ort_dart/src/bindings/onnxruntime_bindings_generated.dart';

/// ONNX Runtime 原生库句柄（惰性打开 + 可由调用方注入）。
///
/// 本文件与 `lib/src/**` 其余部分 vendored 自 pub.dev 的 `onnxruntime_plus`
/// 1.5.0（MIT）。相对上游的两处改动见 `ort_dart.dart` 头部说明：
/// 1. 去掉 `flutter: plugin:` 段与 `package:flutter/services.dart` 依赖 ——
///    上游是 FFI plugin，会向**每个**平台注入它自带的 onnxruntime 二进制
///    （Android 两个 jniLibs 合计约 31MB），直接违反本仓「standard 包零 3D
///    产物」的打包口径；
/// 2. 库名/路径允许调用方注入（[initializeOrtBindings]），Windows 侧按 exe
///    同目录的 app-local dll 打开（与 `lib/services/kugou_server.dart` 同法）。
DynamicLibrary? _injected;

/// 注入原生库句柄。必须在**首次访问 [onnxRuntimeBinding] 之前**调用；
/// 两者都是顶层惰性 final，先访问绑定的话本注入不会生效。
void initializeOrtBindings(DynamicLibrary library) {
  _injected = library;
}

/// 上游默认的平台库名（Linux/macOS 去掉了上游写死的 `1.15.1` 版本号后缀，
/// 改由调用方传入完整路径；未注入时仍按裸名走系统搜索路径）。
String _defaultLibraryName() {
  if (Platform.isWindows) return 'onnxruntime.dll';
  if (Platform.isLinux) return 'libonnxruntime.so';
  if (Platform.isMacOS || Platform.isIOS) return 'libonnxruntime.dylib';
  if (Platform.isAndroid) return 'libonnxruntime.so';
  throw UnsupportedError('未知平台：${Platform.operatingSystem}');
}

DynamicLibrary _openDefault() {
  if (Platform.isIOS) return DynamicLibrary.process();
  return DynamicLibrary.open(_defaultLibraryName());
}

// 顶层 final 的初始化器是惰性的：首次读 _dylib 时才决定用注入值还是默认打开。
final DynamicLibrary _dylib = _injected ?? _openDefault();

/// OnnxRuntime Bindings
final onnxRuntimeBinding = OnnxRuntimeBindings(_dylib);
