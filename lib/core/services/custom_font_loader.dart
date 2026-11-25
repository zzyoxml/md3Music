import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 字体来源枚举。
///
/// - [FontSource.system]：使用手机系统字体（默认，符合"优先展示用户手机字体"需求）
/// - [FontSource.bundled]：已废弃（内置 SimHei 已移除，仅保留枚举值以稳定
///   `fontSource.index` 的原生契约 0=system 1=bundled 2=custom），行为等同 system
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
  ///
  /// 历史值 'bundled'（内置 SimHei 已移除）迁移为 [FontSource.system]。
  static FontSource fromName(String? name) {
    switch (name) {
      case 'custom':
        return FontSource.custom;
      default:
        // 'bundled' 与未知值一并归入 system（bundled 字体已不再打包）
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
      if (Platform.isWindows) {
        final selected = await openFile(acceptedTypeGroups: const [
          XTypeGroup(label: '字体', extensions: ['ttf', 'otf']),
        ]);
        if (selected == null) return null;
        final support = await getApplicationSupportDirectory();
        final directory =
            Directory('${support.path}${Platform.pathSeparator}fonts');
        await directory.create(recursive: true);
        final extension = selected.name.split('.').last.toLowerCase();
        // 每次换字体都写**唯一文件名**（时间戳），并清掉上一份：
        // 固定名 `user_custom.ttf` 有两个问题——
        //   1) File.copy 到已存在的路径在部分平台直接抛 FileSystemException；
        //   2) 路径不变时 ThemeProvider 无法感知"内容已变"，新字体加载不上。
        final path = '${directory.path}${Platform.pathSeparator}'
            'user_custom_${DateTime.now().microsecondsSinceEpoch}.$extension';
        await File(selected.path).copy(path);
        await _removeOtherFontFiles(directory, keepPath: path);
        return path;
      }
      final channel = MethodChannel(_channel);
      return await channel.invokeMethod<String>('pickFontFile');
    } catch (error) {
      debugPrint('[CustomFontLoader] 选择字体文件失败: $error');
      return null;
    }
  }

  /// 删除字体目录下除 [keepPath] 外的旧字体文件。
  ///
  /// 避免目录里堆积用户选过的每个字体（几十 MB 很正常）。
  /// 删除失败静默忽略 —— 残留旧文件不影响功能，只是占空间。
  static Future<void> _removeOtherFontFiles(
    Directory directory, {
    required String keepPath,
  }) async {
    final keepName = keepPath.split(Platform.pathSeparator).last;
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        if (entity.path.split(Platform.pathSeparator).last == keepName) {
          continue;
        }
        if (!entity.path.toLowerCase().contains('user_custom')) continue;
        try {
          await entity.delete();
        } catch (_) {
          // 文件被占用等情况：留着即可，不影响功能
        }
      }
    } catch (_) {}
  }
}
