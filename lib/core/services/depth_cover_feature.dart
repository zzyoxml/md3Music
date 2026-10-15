/// 3D 深度封面功能开关（编译期常量，非运行时配置）。
///
/// 仅 `depth3d` flavor 的构建命令携带
/// `--dart-define=ENABLE_DEPTH_3D=true`，此时 APK 内含
/// libonnxruntime.so 与深度模型资产；`standard` flavor 不携带
/// 任何 3D 相关产物，Dart 侧据此整体隐藏该功能（设置项/生成请求）。
const bool kDepthCoverAvailable =
    bool.fromEnvironment('ENABLE_DEPTH_3D');
