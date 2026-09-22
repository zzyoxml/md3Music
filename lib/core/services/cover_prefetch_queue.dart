import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 带宽感知的封面预取队列。
///
/// 一起听场景：切歌/进房瞬间高音质音频流（30-80MB）占满下行带宽，
/// 同时并发请求十几张封面只会排队超时。队列三原则：
/// 1. **串行出队**（并发 1）：封面小（40-80KB/张），串行总耗时可控，
///    不与音频流抢连接池；
/// 2. **带宽让路**：[isBandwidthBusy] 为真（播放器 loading/buffering，
///    音频正在抢带宽）时挂起出队；就绪/暂停（带宽空闲）后自动恢复——
///    暂停态正是补齐封面的黄金窗口；
/// 3. **落盘复用**：默认用 DefaultCacheManager 下载（与 CachedNetworkImage
///    同一磁盘缓存池），预取完成后所有 UI 侧零网络命中。
class CoverPrefetchQueue {
  CoverPrefetchQueue({
    bool Function()? isBandwidthBusy,
    Future<void> Function(String url)? fetch,
    this.pauseInterval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 8),
    this.maxRetries = 2,
    this.maxQueueLength = 64,
  })  : _isBandwidthBusy = isBandwidthBusy ?? (() => false),
        _fetch = fetch ?? _defaultFetch;

  /// 默认下载：进 DefaultCacheManager 磁盘缓存（CachedNetworkImage 同池）。
  static Future<void> _defaultFetch(String url) async {
    await DefaultCacheManager().downloadFile(url);
  }

  final bool Function() _isBandwidthBusy;
  final Future<void> Function(String url) _fetch;
  final Duration pauseInterval;
  final Duration timeout;
  final int maxRetries;
  final int maxQueueLength;

  final Set<String> _known = {}; // 已入队/已发起（去重）
  final List<String> _queue = [];
  final Map<String, int> _retries = {};
  bool _draining = false;
  bool _disposed = false;

  /// 当前歌封面：移到队首尽快出队。已完成（已在磁盘缓存）则无操作。
  void prioritize(String url) {
    final u = url.trim();
    if (u.isEmpty || _disposed) return;
    if (_known.contains(u)) {
      final i = _queue.indexOf(u);
      if (i > 0) {
        _queue.removeAt(i);
        _queue.insert(0, u);
      }
    } else {
      _known.add(u);
      _queue.insert(0, u);
    }
    unawaited(_drain());
  }

  /// 批量入队（顺序保留、去重、截断到 [maxQueueLength]）。
  void enqueueAll(Iterable<String> urls) {
    if (_disposed) return;
    for (final raw in urls) {
      final u = raw.trim();
      if (u.isEmpty || _known.contains(u)) continue;
      if (_queue.length >= maxQueueLength) break;
      _known.add(u);
      _queue.add(u);
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        // 带宽让路：音频装载/缓冲中挂起出队，避免与音频流抢带宽
        while (!_disposed && _isBandwidthBusy()) {
          await Future<void>.delayed(pauseInterval);
        }
        if (_disposed) return;
        final url = _queue.removeAt(0);
        try {
          await _fetch(url).timeout(timeout);
          _retries.remove(url);
        } catch (_) {
          final n = (_retries[url] ?? 0) + 1;
          if (n <= maxRetries) {
            _retries[url] = n;
            _queue.add(url); // 回队尾稍后重试
          } else {
            _retries.remove(url);
            _known.remove(url); // 超限放弃：允许将来重新入队
          }
          if (!_disposed && _queue.isNotEmpty) {
            await Future<void>.delayed(pauseInterval);
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  void dispose() => _disposed = true;
}
