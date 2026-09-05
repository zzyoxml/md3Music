import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/audio_scanner.dart';

/// 本地音乐封面懒加载缓存服务。
///
/// 扫描阶段不提取封面（使用 `getImage: false` 快速扫描），
/// 在 UI 显示时通过 [getArtwork] 懒加载，内存缓存避免重复读取。
///
/// 内存缓存为访问序 LRU（上限 [_cacheLimit] 条）：大曲库滚动浏览时
/// 原始封面字节（可达数百 KB/张）不再无限常驻，超限逐出最久未用项。
class LocalArtworkCache {
  static final LocalArtworkCache _instance = LocalArtworkCache._();
  factory LocalArtworkCache() => _instance;
  LocalArtworkCache._();

  /// 内存缓存上限：封面原始字节较大，需封顶防止长会话累积。
  static const int _cacheLimit = 100;

  /// 内存缓存：filePath → 封面字节数据（null 表示已确认无封面）。
  /// Dart 字面量 Map 为 LinkedHashMap：命中/写入即刷新访问序，
  /// 超限逐出首位（最久未用）。
  final Map<String, Uint8List?> _cache = {};

  /// 获取封面，优先从内存缓存读取。
  ///
  /// 未命中缓存时在 Isolate 中读取文件元数据提取封面。
  /// 返回 null 表示该文件无封面图。
  Future<Uint8List?> getArtwork(String filePath) async {
    // 命中即刷新访问序（remove + put 移到末尾）
    if (_cache.containsKey(filePath)) {
      final v = _cache.remove(filePath);
      _cache[filePath] = v;
      return v;
    }
    try {
      final result = await compute(readArtworkInIsolate, filePath);
      _put(filePath, result != null ? result['bytes'] as Uint8List : null);
    } catch (_) {
      _put(filePath, null);
    }
    return _cache[filePath];
  }

  /// 写入缓存并处理超限驱逐（LRU，逐出最久未用项）。
  void _put(String key, Uint8List? bytes) {
    if (_cache.containsKey(key)) _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 清除所有缓存（重新扫描后调用）。
  void clear() => _cache.clear();
}
