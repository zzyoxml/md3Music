import 'package:flutter/foundation.dart';

import '../utils/audio_scanner.dart';
import '../utils/local_media_path.dart';

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
  ///
  /// **入参先经 [normalizeLocalMediaPath] 归一**：播放解析会把本地歌曲的
  /// `localPath` 回写成 `file://` URI（中文/空格还带 percent 编码），而
  /// `File()` 不认这些前缀与编码——不归一时 `existsSync()` 恒为 false，
  /// 播放页封面恒为占位符（列表用曲库对象、未经回写，所以不受影响）。
  /// 归一后的路径同时用作缓存键：同一文件经裸路径与 `file://` 两种入参
  /// 只读一次盘、共用一份字节。
  Future<Uint8List?> getArtwork(String filePath) async {
    final normalized = normalizeLocalMediaPath(filePath);
    if (normalized == null) return null;
    // 归一后仍非本地形态（content:// / http(s):// 等）：`dart:io` 读不了，
    // 保持既有「无内嵌封面」语义，且不占用缓存位（原实现会把 null 写进缓存）。
    if (normalized.startsWith('content://') ||
        normalized.startsWith('http://') ||
        normalized.startsWith('https://')) {
      return null;
    }

    // 命中即刷新访问序（remove + put 移到末尾）
    if (_cache.containsKey(normalized)) {
      final v = _cache.remove(normalized);
      _cache[normalized] = v;
      return v;
    }
    final pending = _inFlight[normalized];
    if (pending != null) return pending;

    final generation = _generation;
    late final Future<Uint8List?> request;
    request = _readArtwork(normalized)
        .then((bytes) {
          // clear() 后仍允许旧调用者拿到结果，但不能把过期结果写回新缓存。
          if (generation == _generation) _put(normalized, bytes);
          return bytes;
        })
        .whenComplete(() {
          if (identical(_inFlight[normalized], request)) {
            _inFlight.remove(normalized);
          }
        });
    _inFlight[normalized] = request;
    return request;
  }

  Future<Uint8List?> _readArtwork(String filePath) async {
    try {
      final reader = _reader;
      if (reader != null) return await reader(filePath);
      final result = await compute(readArtworkInIsolate, filePath);
      final bytes = result != null ? result['bytes'] as Uint8List : null;
      if (bytes == null) {
        // 真机取证用：区分「文件不存在/读不了」与「元数据里确实没有封面」。
        debugPrint('[LocalArtworkCache] 未提取到内嵌封面 path=$filePath');
      }
      return bytes;
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
