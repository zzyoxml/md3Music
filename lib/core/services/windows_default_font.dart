import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 便携包内的默认字体；不进入 Flutter assets，因此不会打进 Android APK。
class WindowsDefaultFont {
  static const String family = 'WindowsSourceHanSansCNMedium';
  static String? _loadedFamily;
  static bool _attempted = false;

  static String? get loadedFamily => _loadedFamily;

  static Future<void> load({String? fontFilePath}) async {
    if (!Platform.isWindows || _attempted) return;
    _attempted = true;
    final separator = Platform.pathSeparator;
    final directory = File(Platform.resolvedExecutable).parent.path;
    final file = File(fontFilePath ??
        '$directory${separator}data${separator}fonts${separator}'
            'SOURCEHANSANSCN-MEDIUM.OTF');
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
