import 'package:flutter/services.dart';

/// 背景图片选择服务：通过 Android 原生 SAF 文件选择器选择一张图片。
///
/// 与 [CustomFontLoader] 同款模式：原生端用 ACTION_OPEN_DOCUMENT 打开系统
/// 文件选择器，选中后把 content URI 流拷贝到 `filesDir/background/` 下，
/// 返回真实路径给 Dart 端用于 Image.file 渲染与莫奈取色。
class BackgroundImageLoader {
  BackgroundImageLoader._();

  static const String _channel = 'com.md3music.md3music/background_picker';

  /// 打开系统图片选择器，返回拷贝到 filesDir 后的图片路径。
  ///
  /// 用户取消返回 null。
  static Future<String?> pickBackgroundImage() async {
    try {
      final channel = MethodChannel(_channel);
      return await channel.invokeMethod<String>('pickBackgroundImage');
    } catch (_) {
      return null;
    }
  }
}
