import 'dart:io';

import 'package:flutter/services.dart';

/// 字体来源枚举。
///
/// - [FontSource.system]：使用手机系统字体（默认，符合"优先展示用户手机字体"需求）
/// - [FontSource.bundled]：使用内置打包的 SimHei
/// - [FontSource.custom]：使用用户通过 SAF 选择的 TTF/OTF 文件
enum FontSource {
  system,
  bundled,
  custom,
}

/// 自定义字体加载与选择服务。
///
/// 提供两个能力：
/// 1. [CustomFontLoader.loadIfAvailable]：启动时根据持久化路径加载自定义 TTF，
///    返回注册成功的 fontFamily
/// 2. [CustomFontLoader.pickFontFile]：通过 Android 原生 SAF 文件选择器选择字体文件，
///    原生端会把文件拷贝到 filesDir/fonts/user_custom.ttf 后返回路径
///
/// 使用 Flutter 内置的 [FontLoader] 动态注册字体，
/// 无需新增 pubspec 依赖。每次 app 启动需重新注册。
class CustomFontLoader {
  /// 注册到 Flutter 的自定义字体 family 名前缀（每次加载追加计数器）
  static const String customFontFamily = 'UserCustomFont';
  static int _loadCounter = 0;

  static const String _channel = 'com.md3music.md3music/font_picker';

  /// 从持久化的字符串名还原 [FontSource]，无效时回退到 [FontSource.system]
  static FontSource fromName(String? name) {
    switch (name) {
      case 'bundled':
        return FontSource.bundled;
      case 'custom':
        return FontSource.custom;
      default:
        return FontSource.system;
    }
  }

  /// 启动时尝试加载已持久化的自定义字体。
  ///
  /// [fontPath] 为原生端拷贝到 filesDir 的真实文件路径。
  /// 返回注册成功的 fontFamily（即 [customFontFamily]），失败返回 null。
  ///
  /// 失败场景：
  /// - path 为 null / 文件不存在 / 不是 TTF
  /// - FontLoader.load() 抛异常
  static Future<String?> loadIfAvailable(String? fontPath) async {
    if (fontPath == null || fontPath.isEmpty) return null;
    final file = File(fontPath);
    if (!file.existsSync()) {
      print('[CustomFontLoader] 字体文件不存在: $fontPath');
      return null;
    }
    try {
      final bytes = await file.readAsBytes();
      // 每次使用唯一的 family name，避免 FontLoader 重复注册同一 family 抛异常
      _loadCounter++;
      final familyName = '$customFontFamily#$_loadCounter';
      final loader = FontLoader(familyName);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      return familyName;
    } catch (e) {
      print('[CustomFontLoader] 字体加载失败: $e');
      return null;
    }
  }

  /// 打开 Android 原生文件选择器，让用户选择 TTF/OTF 字体文件。
  ///
  /// 原生端会通过 SAF 拿到 content URI，将文件流拷贝到
  /// `filesDir/fonts/user_custom.ttf`，返回该文件绝对路径。
  /// 用户取消返回 null。
  static Future<String?> pickFontFile() async {
    try {
      final channel = MethodChannel(_channel);
      return await channel.invokeMethod<String>('pickFontFile');
    } catch (_) {
      return null;
    }
  }
}
