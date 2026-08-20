import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 跨平台文件夹选择：Android 走 SAF MethodChannel；Windows 走 file_selector。
class FolderPickerService {
  static const _channel = MethodChannel('com.md3music.md3music/folder_picker');

  /// 打开系统文件夹选择器，返回用户选择的目录路径。
  ///
  /// 返回 `null` 表示用户取消选择。
  static Future<String?> pickFolder() async {
    if (!kIsWeb && Platform.isWindows) {
      return getDirectoryPath(confirmButtonText: '选择文件夹');
    }
    try {
      final uri = await _channel.invokeMethod<String>('pickFolder');
      if (uri == null) return null;
      // 将 SAF URI 转换为实际文件路径
      return _uriToPath(uri);
    } catch (_) {
      return null;
    }
  }

  /// 将 SAF content URI 转换为实际文件系统路径。
  ///
  /// URI 格式示例：
  /// `content://com.android.externalstorage.documents/tree/primary%3AMusic%2Fmd3Music`
  /// 转换为：`/storage/emulated/0/Music/md3Music`
  static String? _uriToPath(String uri) {
    try {
      final treeIndex = uri.indexOf('/tree/');
      if (treeIndex == -1) return null;

      var path = Uri.decodeComponent(uri.substring(treeIndex + 6));
      // 替换 primary: 为 /storage/emulated/0/
      path = path.replaceFirst('primary:', '/storage/emulated/0/');
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 对已保存的 URI 请求持久化读写权限。
  ///
  /// 在 App 冷启动时调用，确保之前选择的目录仍然可访问。
  /// Windows 无 SAF 持久化权限，直接视为成功。
  static Future<bool> persistUriPermission(String uri) async {
    if (!kIsWeb && Platform.isWindows) return true;
    try {
      final result = await _channel.invokeMethod<bool>(
        'getPersistedUriPermission',
        {'uri': uri},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
