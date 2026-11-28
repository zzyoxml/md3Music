/// 生成的 ONNX Runtime C API 绑定（OrtApi 结构体、OrtStatusPtr、各枚举常量）。
///
/// 单独成库而不是从 `ort_dart.dart` 主库 re-export：生成文件里的
/// `OrtValue` / `OrtSession` 是 ffi 侧的 opaque 类型，与主库导出的同名
/// Dart 封装类**直接冲突**（`import 'package:ort_dart/ort_dart.dart'` 的使用方
/// 会立刻撞名）。调用方按需自行加前缀：
///
/// ```dart
/// import 'package:ort_dart/generated_bindings.dart' as bg;
/// ```
library;

export 'src/bindings/onnxruntime_bindings_generated.dart';
