import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通过原生 MediaStore 扫描设备上的所有音频文件。
///
/// Android 11+ 沙箱模式下，直接通过 `dart:io` 的 `Directory.listSync` 无法访问
/// 网易云/QQ 音乐/酷狗等其他 App 的私有下载目录。但只要应用持有
/// READ_MEDIA_AUDIO (Android 13+) 或 READ_EXTERNAL_STORAGE (Android 12-) 权限，
/// MediaStore 会自动聚合系统已索引的所有可见音频。
class MediaStoreService {
  static const _channel =
      MethodChannel('com.md3music.md3music/media_store');

  /// 缓存最近一次查询到的 SDK 版本。
  static int? _cachedSdkVersion;

  /// 获取 Android SDK 版本。
  ///
  /// 走原生 MethodChannel，未连接设备时返回 null。
  static Future<int?> getSdkVersion() async {
    if (kIsWeb) return null;
    if (_cachedSdkVersion != null) return _cachedSdkVersion;
    try {
      final result = await _channel.invokeMethod<int>('getSdkVersion');
      _cachedSdkVersion = result;
      return result;
    } catch (e) {
      debugPrint('[MediaStoreService] 获取 SDK 版本失败: $e');
      return null;
    }
  }

  /// 查询设备上的所有音频文件。
  ///
  /// 返回值每项为 Map，包含 filePath (content:// URI)、title、artist、album、
  /// durationMs、relativePath、mimeType 等字段。
  ///
  /// 在不支持的平台上（如 iOS/Web）返回空列表。
  static Future<List<Map<String, dynamic>>> queryAudioFiles() async {
    if (kIsWeb) return [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'queryAudioFiles',
      );
      if (result == null) return [];
      return result
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (e) {
      debugPrint('[MediaStoreService] 查询失败: $e');
      return [];
    }
  }

  /// 把 `content://` URI 解析为 just_audio 可播放的真实文件路径。
  ///
  /// **为什么需要这个方法**：`just_audio` 的 `setUrl` 不支持 `content://` 协议，
  /// 直接传 `content://media/external/audio/media/{id}` 会导致"播放没声音"
  /// （加载失败但 UI 进度条仍在动）。本地音乐通过 MediaStore 拿到的就是
  /// `content://` URI，必须先解析为真实文件路径。
  ///
  /// **返回**：
  /// - 成功：真实文件路径（部分设备直接返回 `/storage/...`，否则返回 App
  ///   私有缓存目录下的拷贝）
  /// - 失败 / 非 content URI：返回 null（调用方应做兜底处理）
  static Future<String?> resolveLocalPath(String contentUri) async {
    if (kIsWeb) return null;
    try {
      final result = await _channel.invokeMethod<String>(
        'resolveLocalPath',
        {'uri': contentUri},
      );
      return result;
    } catch (e) {
      debugPrint('[MediaStoreService] resolveLocalPath 失败: $e');
      return null;
    }
  }
}
