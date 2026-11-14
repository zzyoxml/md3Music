import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生文件夹选择器：通过 SAF (Storage Access Framework) 打开系统目录选择界面。
///
/// 用户选择的目录 URI 获得持久化读取权限；U 盘必须通过 URI 扫描，
/// 不能把 document tree URI 猜成 /storage 路径。
class FolderPickerService {
  static const _channel = MethodChannel('com.md3music.md3music/folder_picker');

  /// 最近一次 [pickFolder] 是否因系统选择器打不开而失败
  /// （原生 ActivityNotFoundException 等回传 PICKER_UNAVAILABLE）。
  ///
  /// TV 上先试系统 SAF 选择器，打不开才兜底内置目录选择弹层；调用方读此
  /// 标志判断是否兜底。每次调用 pickFolder 时重置。
  static bool safUnavailable = false;

  /// 打开系统文件夹选择器。Windows 返回路径，Android 返回 SAF tree URI。
  ///
  /// 返回 `null` 表示用户取消；若 [safUnavailable] 为 true 则表示系统选择器
  /// 根本没打开（非用户取消），调用方可用内置选择器兜底。
  /// Android 返回的 content:// URI 只可经 ContentResolver 读取。
  static Future<String?> pickFolder() async {
    try {
      safUnavailable = false;
      // 按**目标平台**判断，不用 Platform.isWindows：后者在 Windows 宿主上跑
      // `flutter test` 时也为 true（测试目标其实是 android），会把测试里的选择器
      // 短路成桌面实现，MethodChannel 一次都不走。
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        final path = await getDirectoryPath();
        return path;
      }
      return await _channel.invokeMethod<String>('pickFolder');
    } on PlatformException catch (error) {
      if (error.code == 'PICKER_UNAVAILABLE') {
        // 系统目录选择器打不开（TV 无 DocumentsUI 等）：标记供兜底，非用户取消
        safUnavailable = true;
        debugPrint('[FolderPickerService] 系统目录选择器不可用: ${error.message}');
        return null;
      }
      debugPrint('[FolderPickerService] 选择文件夹失败: ${error.message}');
      return null;
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
