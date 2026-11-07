import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生文件夹选择器：通过 SAF (Storage Access Framework) 打开系统目录选择界面。
///
/// 用户选择的目录 URI 获得持久化读取权限；U 盘必须通过 URI 扫描，
/// 不能把 document tree URI 猜成 /storage 路径。
class FolderPickerService {
  static const _channel = MethodChannel('com.md3music.md3music/folder_picker');

  /// 打开系统文件夹选择器。Windows 返回路径，Android 返回 SAF tree URI。
  ///
  /// 返回 `null` 表示用户取消选择。
  /// Android 返回的 content:// URI 只可经 ContentResolver 读取。
  static Future<String?> pickFolder() async {
    try {
      // 按**目标平台**判断，不用 Platform.isWindows：后者在 Windows 宿主上跑
      // `flutter test` 时也为 true（测试目标其实是 android），会把测试里的选择器
      // 短路成桌面实现，MethodChannel 一次都不走。
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        final path = await getDirectoryPath();
        return path;
      }
      return await _channel.invokeMethod<String>('pickFolder');
    } catch (error) {
      // 静默失败会让用户只看到"点了没反应"，这里留日志便于定位
      // （Windows 上 fluttertoast 无实现，弹窗提示走不通）。
      debugPrint('[FolderPickerService] 选择文件夹失败: $error');
      return null;
    }
  }

  static bool isTreeUri(String path) =>
      path.startsWith('content://') && path.contains('/tree/');

  static String displayName(String path) {
    if (isTreeUri(path)) {
      final id = Uri.parse(path).pathSegments.last;
      return id.substring(id.lastIndexOf('/') + 1).split(':').last;
    }
    final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  /// 原生侧使用持久化 tree grant 遍历目录，返回可播放的 document URI。
  static Future<List<Map<String, dynamic>>> queryTreeAudioFiles(String uri) async {
    final rows = await _channel.invokeMethod<List<dynamic>>(
      'queryTreeAudioFiles',
      {'uri': uri},
    );
    return rows?.whereType<Map>().map((row) =>
        row.map((key, value) => MapEntry(key.toString(), value))).toList() ?? [];
  }

  /// 对已保存的 URI 确认持久化读取权限。
  ///
  /// 在 App 冷启动时调用，确保之前选择的目录仍然可访问。
  static Future<bool> persistUriPermission(String uri) async {
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
