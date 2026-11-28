import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Windows 便携包内嵌的中文默认字体（可商用、SIL OFL 1.1）。
///
/// 字体来源：Noto Sans SC / Source Han Sans（Adobe + Google，SIL OFL 1.1），
/// 取 GB2312 常用汉字 + 日文假名 + 韩文 Hangul 子集（约 2.4MB），按 OFL
/// 条件 3 改名为 **MD3MusicSans**（不使用保留字体名 Source），随便携包分发，
/// 不进入 Flutter assets，因此不会打进 Android APK。
///
/// 实例化字重为 **Medium（500）**：小字号笔画更实、更清晰。全局 UI、
/// MD3/AM 歌词、Windows 原生悬浮歌词统一使用本字体。
///
/// 字重钳制：字体内只有 500 一档，凡请求超过 500 的字重（主题里常见的
/// w600、以及歌词在 Windows 的 w600~w900）都会触发 Skia/GDI 的假粗体合成
/// ——笔画被机械加粗，边缘发糊。用 [bundledAwareFontWeight] 在 Windows 使用
/// 内置字体时把请求回落到 500（用真实字形渲染）；非 Windows 与自定义字体
/// 不受影响。
class WindowsDefaultFont {
  /// 字体族名（与 .ttf 内部 nameID 1 一致，FontLoader 与 C++ CreateFontW 共用）。
  static const String family = 'MD3MusicSans';

  /// 便携包内字体文件名（相对 <exe目录>/data/fonts/）。
  static const String fileName = 'MD3MusicSans.ttf';

  static String? _loadedFamily;
  static bool _attempted = false;

  static String? get loadedFamily => _loadedFamily;

  /// 内置字体的实际字重（Medium 500，单实例静态字体）。
  static const int bundledFontWeight = 500;

  /// 按「是否正在使用内置字体」钳制请求字重。
  ///
  /// Windows 且内置字体已注册时：请求字重高于 [bundledFontWeight] 一律回落到
  /// 500，避免 Skia/GDI 对单档静态字体做假粗体合成（机械加粗、边缘发糊）。
  /// 请求低于 500 保持原值（Skia 取最近档即 500 字形，无需合成）；
  /// 非 Windows、内置字体未加载、或用户选了自定义字体时原样返回。
  static FontWeight bundledAwareFontWeight(FontWeight requested) {
    if (!Platform.isWindows || _loadedFamily == null) return requested;
    return requested.value > bundledFontWeight
        ? const FontWeight(bundledFontWeight)
        : requested;
  }

  /// 字体文件的绝对路径（供原生 C++ 悬浮窗加载；非 Windows 返回 null）。
  ///
  /// 原生侧用 AddFontResourceExW 加载同一份字体并用 [family] 创建字体，
  /// 与 Flutter 侧保持完全一致。
  static String? get bundledFontPath {
    if (!Platform.isWindows) return null;
    final directory = File(Platform.resolvedExecutable).parent.path;
    return '$directory${Platform.pathSeparator}data${Platform.pathSeparator}fonts'
        '${Platform.pathSeparator}$fileName';
  }

  static Future<void> load({String? fontFilePath}) async {
    if (!Platform.isWindows || _attempted) return;
    _attempted = true;
    final file = File(fontFilePath ?? bundledFontPath!);
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedFamily = family;
    } catch (error) {
      // 旧便携包缺少字体时保留系统字体，不让应用启动失败。
      debugPrint('[WindowsDefaultFont] 字体未加载: $error');
    }
  }
}
