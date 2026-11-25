/// ort_dart —— vendored 的纯 Dart ONNX Runtime 绑定（无平台二进制）。
///
/// 来源：pub.dev `onnxruntime_plus` 1.5.0（MIT，Copyright (c) gtbluesky），
/// 取其 `lib/src/**`（含 ffigen 生成的 `onnxruntime_bindings_generated.dart`）。
/// 本包**刻意不声明** `flutter: plugin:`，因此不会向 Android/iOS 注入上游自带的
/// onnxruntime 二进制（Android 约 31MB jniLibs）——本仓 Android 走 flavor 内的
/// 裁剪版 AAR + Kotlin 插件，Windows 走便携包里 app-local 的官方 dll。
///
/// 与上游的差异只有两处：
/// - `src/ort_session.dart`：删掉未使用的 `package:flutter/services.dart` import；
/// - `src/bindings/bindings.dart`：库句柄支持 [initializeOrtBindings] 注入，
///   并把 Linux/macOS 写死的 `1.15.1` 版本号后缀改为裸名。
///
/// 用法约束（本仓 Windows 3D 封面）：所有推理都在**后台 isolate** 里做，isolate
/// 入口第一步必须 `initializeOrtBindings(DynamicLibrary.open(绝对路径))`。
library;

export 'src/bindings/bindings.dart' show initializeOrtBindings;
export 'src/ort_env.dart';
export 'src/ort_isolate_session.dart';
export 'src/ort_provider.dart';
export 'src/ort_session.dart';
export 'src/ort_status.dart';
export 'src/ort_value.dart';
export 'src/providers/ort_flags.dart';
export 'src/util/list_shape_extension.dart';
