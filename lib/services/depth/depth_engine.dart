import 'package:flutter/foundation.dart';

import '../../core/services/depth_cover_feature.dart';
import 'depth_engine_channel.dart';
import 'depth_engine_windows.dart';

/// 3D 封面推理后端接口（模型加载 + 深度/分层生成 + 用户提示）。
///
/// 为什么要有这层抽象：Android 的深度推理在 Kotlin 插件里（MethodChannel +
/// 裁剪版 ORT AAR + APK 内置模型资产），Windows 没有等价原生实现。原先
/// `DepthCoverService` 直接 invokeMethod，桌面端每次调用都 MissingPluginException
/// → 永远停留在平面封面。本接口把「怎么推理」与「什么时候推理/怎么缓存」拆开：
/// 缓存编排、URI 解析、重试与失败上限仍归 DepthCoverService 所有。
///
/// 后端选择是**编译期** const（`kDepthDartFfi`，见 depth_cover_feature.dart）：
/// 运行时判平台会让 AOT 把 Dart FFI 引擎与整条算法管线保留进 Android 包，
/// 违反 standard 包「零 3D 产物」的口径。
abstract interface class DepthEngine {
  /// 深度模型会话是否就绪（进程内缓存；失败时自行做一次性提示）。
  ///
  /// 返回 false 表示本轮不可用，调用方据此保持平面封面并走既有重试上限。
  Future<bool> ensureModelLoaded();

  /// 神经修补（MI-GAN）会话懒加载：设置项关闭时直接返回、不留内存占用。
  /// 失败静默（调用方继续用 push-pull 结果）。
  Future<void> ensureInpaintSession();

  /// shader 路径：产出单张深度图 + 修补背景。
  ///
  /// 返回 `{'depth': 绝对路径, 'depthStd': double, 'bgFill': 绝对路径?,
  /// 'inpaint': 'migan'|'pushpull'?}`；null = 未产出（同 key 在途 / 解码失败 /
  /// 模型未就绪），调用方按失败重试处理。
  Future<Map<String, Object?>?> generateDepth(
    String sourcePath,
    String outDir,
    String key,
  );

  /// 多层视差降级路径：产出 3 张带 alpha 的分层 PNG（背景/中景/前景）。
  ///
  /// 返回绝对路径列表（长度必须为 3），null 同上。
  Future<List<String>?> generateLayers(
    String sourcePath,
    String outDir,
    String key,
  );

  /// 面向用户的降级/失败提示。两端语义一致：Android 走原生通道 showToast，
  /// Windows 走 app-local 的原生提示窗（showToast 工具已按平台路由）。
  Future<void> showToast(String message);
}

/// 按编译期旗标创建后端（进程内单例，由 DepthCoverService 持有）。
DepthEngine createDepthEngine() {
  if (kDepthDartFfi) {
    debugPrint('[DepthCover] 后端 = Dart FFI（Windows app-local onnxruntime）');
    return WindowsDartDepthEngine();
  }
  debugPrint('[DepthCover] 后端 = 原生 MethodChannel');
  return ChannelDepthEngine();
}
