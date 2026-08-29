import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/audio_scanner.dart';

/// 本地音乐封面懒加载缓存服务。
///
/// 扫描阶段不提取封面（使用 `getImage: false` 快速扫描），
/// 在 UI 显示时通过 [getArtwork] 懒加载，内存缓存避免重复读取。
class LocalArtworkCache {
  static final LocalArtworkCache _instance = LocalArtworkCache._();
  factory LocalArtworkCache() => _instance;
  LocalArtworkCache._();

  /// 内存缓存：filePath → 封面字节数据（null 表示已确认无封面）。
  final Map<String, Uint8List?> _cache = {};

  /// 获取封面，优先从内存缓存读取。
  ///
  /// 未命中缓存时在 Isolate 中读取文件元数据提取封面。
  /// 返回 null 表示该文件无封面图。
  Future<Uint8List?> getArtwork(String filePath) async {
    if (_cache.containsKey(filePath)) return _cache[filePath];
    try {
      final result = await compute(readArtworkInIsolate, filePath);
      if (result != null) {
        _cache[filePath] = result['bytes'] as Uint8List;
      } else {
        _cache[filePath] = null;
      }
    } catch (_) {
      _cache[filePath] = null;
    }
    return _cache[filePath];
  }

  /// 清除所有缓存（重新扫描后调用）。
  void clear() => _cache.clear();
}
