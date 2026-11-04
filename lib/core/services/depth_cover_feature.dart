/// 3D 深度封面功能开关（编译期常量，非运行时配置）。
///
/// 两个来源：
/// - `--dart-define=MD3_FULL=true`（Android `full` flavor）：全功能包，3D 封面与
///   端侧分离一起随包；
/// - `--dart-define=ENABLE_DEPTH_3D=true`（Windows `scripts\md3.ps1 windows -With3D`
///   与既有 3D 单测仍用它，保留兼容）。
///
/// `lite` flavor（默认/对外公开）两个 define 都不带，APK 里既没有 libonnxruntime.so
/// 也没有深度模型资产，Dart 侧据此整体隐藏该功能（设置项/生成请求）。
const bool kDepthCoverAvailable =
    bool.fromEnvironment('MD3_FULL') ||
    bool.fromEnvironment('ENABLE_DEPTH_3D');

/// 深度推理后端（编译期常量）：
/// - `channel`（默认）：走原生 MethodChannel（Android `DepthCoverPlugin.kt` +
///   裁剪版 ORT AAR）。**Android / TV 永远取这个值**，构建命令不带本 define。
/// - `dart_ffi`：走纯 Dart ONNX Runtime FFI（`third_party/ort_dart`，
///   Windows 便携包 app-local 的 onnxruntime.dll）。
///
/// 必须是 `--dart-define` 而不是运行时判平台：运行时判断会让 AOT 把 FFI 引擎
/// 与整条 Dart 管线（ort_dart + 算法）保留进 Android 包（standard 包承诺「零
/// 3D 产物」，depth3d 包也已靠 flavor 挡掉这些依赖），而 const false 分支连同
/// 其 import 会被树摇剔除。
const String kDepthBackend =
    String.fromEnvironment('DEPTH_BACKEND', defaultValue: 'channel');

/// 是否使用 Dart FFI 推理引擎（Windows 端唯一 true 的来源）。
const bool kDepthDartFfi = kDepthCoverAvailable && kDepthBackend == 'dart_ffi';
