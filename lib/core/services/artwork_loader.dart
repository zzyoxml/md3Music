import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

/// 封面图加载的统一入口。
///
/// 支持三种来源：
/// 1. **文件路径**（如 `/storage/emulated/0/Music/song.mp3`）：通过
///    `audio_metadata_reader` 读取 ID3 标签内嵌封面。
/// 2. **content:// URI**（如 `content://media/external/audio/media/123`）：
///    Android 11+ MediaStore 沙箱模式下，由调用方在调用前预取封面并存储
///    到 cache，文件路径为 `cache://artwork/<albumId>` 形式。
/// 3. **cache:// URI**：从内存缓存直接返回。
class ArtworkLoader {
  static final ArtworkLoader _instance = ArtworkLoader._();
  factory ArtworkLoader() => _instance;
  ArtworkLoader._();

  /// 内存缓存：key → 封面字节数据（null 表示已确认无封面）。
  final Map<String, Uint8List?> _cache = {};

  /// 加载封面图。
  ///
  /// [key] 缓存 key（通常为 filePath 或 albumId）。
  /// [sourceUri] 实际数据来源 URI。
  Future<Uint8List?> load({
    required String key,
    required String sourceUri,
  }) async {
    if (_cache.containsKey(key)) return _cache[key];

    Uint8List? bytes;
    try {
      if (sourceUri.startsWith('content://')) {
        // MediaStore 路径：通过 audio_metadata_reader 读取 metadata 不支持 content URI。
        // 实际生产中应该在 MediaStoreScanner 阶段一次性预取封面，写入 cache。
        bytes = null;
      } else if (sourceUri.startsWith('cache://')) {
        // 缓存路径：直接返回（应在 preload 时填好缓存）
        bytes = null;
      } else {
        bytes = await _loadFromFile(sourceUri);
      }
    } catch (e) {
      debugPrint('[ArtworkLoader] 加载封面失败: $sourceUri, $e');
    }

    _cache[key] = bytes;
    return bytes;
  }

  /// 通过 audio_metadata_reader 读取文件内嵌封面。
  Future<Uint8List?> _loadFromFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final metadata = readMetadata(file, getImage: true);
    if (metadata.pictures.isEmpty) return null;
    final frontCover = metadata.pictures.firstWhere(
      (p) => p.pictureType == PictureType.coverFront,
      orElse: () => metadata.pictures.first,
    );
    return frontCover.bytes;
  }

  /// 预填缓存（供 MediaStore 扫描时使用）。
  void put(String key, Uint8List? bytes) {
    _cache[key] = bytes;
  }

  /// 清除所有缓存。
  void clear() => _cache.clear();
}
