import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 当前构建实际使用的渲染引擎（'skia' | 'impeller'）的单一真相源。
///
/// 背景：设置页「当前渲染引擎」与诊断导出原先都只问原生 MethodChannel
/// `com.md3music.md3music/render_engine`，该通道**只有 Android MainActivity 注册**。
/// Windows 便携版上调用必抛 MissingPluginException，被 catch 后统一回退成 'skia'，
/// 于是无论用 Impeller（桌面默认）还是 Skia 构建，界面/诊断都误报 Skia。
///
/// 统一口径：
/// - Android：仍以原生通道为准（由构建期 flavor / RenderEngineManager 决定）；
/// - 其它平台：读构建期注入的 [kRenderEngineDefine]（Windows 构建命令统一传
///   `--dart-define=MD3_RENDER_ENGINE=impeller`；显式 Skia 实验构建传 `skia`）；
/// - 原生通道不可用且 define 缺省时按 Flutter 桌面默认值 'impeller' 兜底。
const String kRenderEngineDefine = String.fromEnvironment(
  'MD3_RENDER_ENGINE',
  defaultValue: 'impeller',
);

/// 读取当前构建实际生效的渲染引擎，返回 'impeller' 或 'skia'。
///
/// 所有失败路径都有兜底，调用方无需 try/catch。
Future<String> currentRenderEngine() async {
  if (!kIsWeb && Platform.isAndroid) {
    try {
      const channel = MethodChannel('com.md3music.md3music/render_engine');
      final String? v = await channel.invokeMethod<String>('getCurrent');
      if (v == 'impeller') return 'impeller';
      if (v == 'skia') return 'skia';
    } catch (_) {
      // 原生通道不可用（如测试环境）→ 落到构建期 define。
    }
  }
  return kRenderEngineDefine == 'skia' ? 'skia' : 'impeller';
}

/// 同步版：供不方便 await 的场景（当前无调用点，保留给诊断的纯字符串拼接）。
String get currentRenderEngineSync =>
    kRenderEngineDefine == 'skia' ? 'skia' : 'impeller';
