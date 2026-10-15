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
  LocalArtworkCache._()
    : _reader = null,
      _cacheLimit = defaultCacheLimit,
      _cacheByteLimit = defaultCacheByteLimit;

  @visibleForTesting
  LocalArtworkCache.forTesting({
    required Future<Uint8List?> Function(String filePath) reader,
    int cacheLimit = defaultCacheLimit,
    int cacheByteLimit = defaultCacheByteLimit,
  }) : _reader = reader,
       _cacheLimit = cacheLimit,
       _cacheByteLimit = cacheByteLimit;

  /// 内存缓存上限：封面原始字节较大，需封顶防止长会话累积。
  static const int defaultCacheLimit = 100;
  static const int defaultCacheByteLimit = 8 * 1024 * 1024;
  final Future<Uint8List?> Function(String filePath)? _reader;
  final int _cacheLimit;
  final int _cacheByteLimit;

  /// 内存缓存：filePath → 封面字节数据（null 表示已确认无封面）。
  /// Dart 字面量 Map 为 LinkedHashMap：命中/写入即刷新访问序，
  /// 超限逐出首位（最久未用）。
  final Map<String, Uint8List?> _cache = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};
  int _generation = 0;
  int _cachedBytes = 0;

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
    final pending = _inFlight[filePath];
    if (pending != null) return pending;

    final generation = _generation;
    late final Future<Uint8List?> request;
    request = _readArtwork(filePath)
        .then((bytes) {
          // clear() 后仍允许旧调用者拿到结果，但不能把过期结果写回新缓存。
          if (generation == _generation) _put(filePath, bytes);
          return bytes;
        })
        .whenComplete(() {
          if (identical(_inFlight[filePath], request)) {
            _inFlight.remove(filePath);
          }
        });
    _inFlight[filePath] = request;
    return request;
  }

  Future<Uint8List?> _readArtwork(String filePath) async {
    try {
      final reader = _reader;
      if (reader != null) return await reader(filePath);
      final result = await compute(readArtworkInIsolate, filePath);
      return result != null ? result['bytes'] as Uint8List : null;
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存并处理超限驱逐（LRU，逐出最久未用项）。
  void _put(String key, Uint8List? bytes) {
    final previous = _cache.remove(key);
    _cachedBytes -= previous?.length ?? 0;
    // 单张超过总预算时不常驻，但不影响本次调用者显示封面。
    if ((bytes?.length ?? 0) > _cacheByteLimit) return;
    _cache[key] = bytes;
    _cachedBytes += bytes?.length ?? 0;
    while (_cache.length > _cacheLimit || _cachedBytes > _cacheByteLimit) {
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey);
      _cachedBytes -= oldest?.length ?? 0;
    }
  }

  /// 清除所有缓存（重新扫描后调用）。
  void clear() {
    _generation++;
    _cache.clear();
    _inFlight.clear();
    _cachedBytes = 0;
  }
}
