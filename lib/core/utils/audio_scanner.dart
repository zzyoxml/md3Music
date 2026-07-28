import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

/// 默认扫描目录：覆盖常见音乐 App 下载路径。
const List<String> defaultScanDirs = [
  '/storage/emulated/0/Music',
  '/storage/emulated/0/Download',
  '/storage/emulated/0/Netease/CloudMusic/Music',
  '/storage/emulated/0/qqmusic/song',
  '/storage/emulated/0/kugou/down_data',
  '/storage/emulated/0/kugou/down_kg',
];

/// 支持的音频文件扩展名（用于过滤目录扫描结果）。
/// 仅保留纯音频格式，不含 .mp4/.mov 等视频容器。
const Set<String> audioExtensions = {
  '.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aac', '.ape', '.wma',
  '.aif', '.aiff', '.aifc',
};

/// Isolate 入口函数：批量扫描音频文件并读取 metadata。
///
/// 在 [compute] 中调用，[filePaths] 为文件路径字符串列表。
/// 返回可序列化的 `List<Map>`，每项包含 filePath/title/artist/album/durationMs。
List<Map<String, dynamic>> scanAudioFilesInIsolate(List<String> filePaths) {
  final results = <Map<String, dynamic>>[];
  int skipped = 0;
  for (final path in filePaths) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        skipped++;
        continue;
      }
      final metadata = readMetadata(file, getImage: false);
      results.add({
        'filePath': path,
        'title': metadata.title ?? _extractTitleFromPath(path),
        'artist': metadata.artist ?? '未知艺术家',
        'album': metadata.album ?? '未知专辑',
        'durationMs': metadata.duration?.inMilliseconds ?? 0,
        'bitrate': metadata.bitrate ?? 0,
      });
    } catch (e) {
      skipped++;
      debugPrint('[AudioScanner] 跳过文件: $path, 错误: $e');
    }
  }
  debugPrint(
      '[AudioScanner] 扫描完成: 共 ${filePaths.length} 个文件, 成功 ${results.length}, 失败 $skipped');
  return results;
}

/// Isolate 入口函数：读取单个文件的封面图。
///
/// 在 [compute] 中调用，返回 `Map` 包含 filePath 和 bytes（Uint8List），
/// 或 null 表示无封面。
Map<String, dynamic>? readArtworkInIsolate(String filePath) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final metadata = readMetadata(file, getImage: true);
    if (metadata.pictures.isNotEmpty) {
      // 优先选择 front cover
      final frontCover = metadata.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
      return {
        'filePath': filePath,
        'bytes': frontCover.bytes,
      };
    }
  } catch (_) {}
  return null;
}

/// 递归收集目录中的音频文件路径。
///
/// 在主 Isolate 中同步调用（文件列表收集阶段）。
/// 使用 [audioExtensions] 过滤，去重后返回路径列表。
/// [excludedDirs] 中的目录及其子目录会被跳过。
List<String> collectAudioFiles(List<String> rootDirs, {List<String>? excludedDirs}) {
  final filePaths = <String>[];
  final seen = <String>{};
  final excluded = excludedDirs ?? [];
  for (final rootPath in rootDirs) {
    try {
      final dir = Directory(rootPath);
      if (!dir.existsSync()) {
        debugPrint('[AudioScanner] 目录不存在或不可访问: $rootPath');
        continue;
      }
      // 检查根目录本身是否被排除
      if (_isPathExcluded(rootPath, excluded)) {
        debugPrint('[AudioScanner] 跳过排除目录: $rootPath');
        continue;
      }
      final entities = dir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          final path = entity.path;
          // 排除文件夹过滤
          if (_isPathExcluded(path, excluded)) continue;
          final lowerPath = path.toLowerCase();
          final lastDot = lowerPath.lastIndexOf('.');
          if (lastDot == -1) continue;
          final ext = lowerPath.substring(lastDot);
          if (audioExtensions.contains(ext)) {
            if (seen.add(path)) {
              filePaths.add(path);
            }
          }
        }
      }
      debugPrint(
          '[AudioScanner] 目录 $rootPath: 累计找到 ${filePaths.length} 个音频文件');
    } catch (e) {
      // 跳过无权限访问的目录（Android 11+ 沙箱限制常见）
      debugPrint('[AudioScanner] 目录扫描失败: $rootPath, 错误: $e');
    }
  }
  debugPrint('[AudioScanner] 总计找到 ${filePaths.length} 个音频文件');
  return filePaths;
}

/// 判断路径是否位于排除文件夹内（支持子目录匹配）。
bool _isPathExcluded(String path, List<String> excludedDirs) {
  if (excludedDirs.isEmpty) return false;
  final normalized = path.replaceAll('\\', '/');
  for (final excluded in excludedDirs) {
    final normalizedExcluded = excluded.replaceAll('\\', '/');
    if (normalized == normalizedExcluded ||
        normalized.startsWith('$normalizedExcluded/')) {
      return true;
    }
  }
  return false;
}

/// 从文件路径提取标题（当 metadata 无 title 时回退）。
String _extractTitleFromPath(String path) {
  final fileName = path.split('/').last;
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot > 0) return fileName.substring(0, lastDot);
  return fileName;
}

/// 读取本地音频文件的内嵌歌词（LRC 或纯文本）。
///
/// 使用 `audio_metadata_reader` 解析 ID3 USLT / Vorbis LYRICS / MP4 ©lyr 标签。
/// 在主 Isolate 中调用（播放页切歌时按需读取，不阻塞扫描流程）。
/// 返回歌词文本（可能为 LRC 格式或纯文本），无歌词时返回 null。
String? readEmbeddedLyrics(String filePath) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final metadata = readMetadata(file, getImage: false);
    // AudioMetadata.lyrics 统一聚合了 MP3(USLT)/MP4(©lyr)/Vorbis(LYRICS) 的歌词
    return metadata.lyrics;
  } catch (_) {
    return null;
  }
}
