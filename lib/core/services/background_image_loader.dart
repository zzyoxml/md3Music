import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/app_toast.dart';

/// 背景图片选择服务：通过 Android 原生 SAF 文件选择器选择一张图片。
///
/// 与 [CustomFontLoader] 同款模式：原生端用 ACTION_OPEN_DOCUMENT 打开系统
/// 文件选择器，选中后把 content URI 流拷贝到 `filesDir/background/` 下，
/// 返回真实路径给 Dart 端用于 Image.file 渲染与莫奈取色。
class BackgroundImageLoader {
  BackgroundImageLoader._();

  static const String _channel = 'com.md3music.md3music/background_picker';

  /// 打开系统图片选择器，返回拷贝到应用支持目录后的图片路径。
  ///
  /// 用户取消返回 null。
  static Future<String?> pickBackgroundImage() async {
    try {
      if (Platform.isWindows) {
        final selected = await openFile(acceptedTypeGroups: const [
          XTypeGroup(
            label: '图片',
            extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
          ),
        ]);
        if (selected == null) return null;
        final support = await getApplicationSupportDirectory();
        final directory = Directory('${support.path}${Platform.pathSeparator}background');
        await directory.create(recursive: true);
        final extension = selected.name.split('.').last.toLowerCase();
        final path = '${directory.path}${Platform.pathSeparator}background_${DateTime.now().microsecondsSinceEpoch}.$extension';
        await File(selected.path).copy(path);
        return path;
      }
      final channel = MethodChannel(_channel);
      return await channel.invokeMethod<String>('pickBackgroundImage');
    } catch (error, stack) {
      // Windows 上 fluttertoast 无实现，提示必须走 debugPrint 才可见；
      // 这里吞掉异常会让用户只看到"点了没反应"。
      debugPrint('[BackgroundImageLoader] 选择背景图失败: $error');
      debugPrint('[BackgroundImageLoader] $stack');
      showToast('选择背景图片失败：$error');
      return null;
    }
  }

  /// 清理背景图目录下的残留文件，只保留 [keepPath]（null 表示全清）。
  ///
  /// Windows 端每次换图都写新的时间戳文件，而设置页的"清除"只删当前那一张，
  /// 换过N 次就会在磁盘上留下 N-1 张高分辨率照片（很容易上 GB）。
  /// 删除失败静默忽略，残留不影响功能。
  static Future<void> cleanUpExcept(String? keepPath) async {
    if (kIsWeb) return;
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}background',
      );
      if (!directory.existsSync()) return;
      final keepName =
          keepPath == null ? '' : keepPath.split(Platform.pathSeparator).last;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        if (!entity.path.startsWith('background_')) continue;
        if (entity.path.split(Platform.pathSeparator).last == keepName) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {
          // 被占用：留着即可
        }
      }
    } catch (_) {}
  }
}
