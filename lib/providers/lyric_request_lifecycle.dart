import '../services/kugou_api/lyric_lookup_result.dart';

/// 歌词请求身份。展示代次不在此键中，避免因页面重建破坏相同请求合并。
class LyricRequestKey {
  final String identity;
  final String format;
  final String query;

  const LyricRequestKey({
    required this.identity,
    required this.format,
    required this.query,
  });

  factory LyricRequestKey.forRequest({
    required String identity,
    required String format,
    required String? songName,
  }) => LyricRequestKey(
    identity: identity.trim().toLowerCase(),
    format: format.trim().toLowerCase(),
    query: songName?.trim().toLowerCase() ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is LyricRequestKey &&
      identity == other.identity &&
      format == other.format &&
      query == other.query;

  @override
  int get hashCode => Object.hash(identity, format, query);
}

/// 同一歌词身份只保留一个网络/持久化读取 Future。
class LyricRequestDeduplicator<T> {
  final Map<LyricRequestKey, Future<T>> _inFlight = {};

  Future<T> run(LyricRequestKey key, Future<T> Function() load) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<T> request;
    request = Future<T>.sync(load).whenComplete(() {
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    });
    _inFlight[key] = request;
    return request;
  }
}

/// 仅缓存“已确认无歌词”的短期结果，不缓存网络错误或无效响应。
class LyricNotFoundCache {
  LyricNotFoundCache({
    required this.ttl,
    required this.capacity,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int capacity;
  final DateTime Function() _clock;
  final Map<LyricRequestKey, DateTime> _entries = {};

  bool contains(LyricRequestKey key) {
    final expiresAt = _entries.remove(key);
    if (expiresAt == null) return false;
    if (!_clock().isBefore(expiresAt)) return false;
    _entries[key] = expiresAt;
    return true;
  }

  void put(LyricRequestKey key) {
    if (capacity <= 0 || ttl <= Duration.zero) return;
    _entries.remove(key);
    _entries[key] = _clock().add(ttl);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(LyricRequestKey key) => _entries.remove(key);

  void clear() => _entries.clear();
}

/// 桌面歌词按结果类型退避；不确定失败短退避，确认无词沿用负缓存 TTL。
class LyricRetryPolicy {
  static Duration delayFor(LyricLookupStatus status, int failureCount) {
    if (status == LyricLookupStatus.notFound) {
      return const Duration(minutes: 5);
    }
    if (status == LyricLookupStatus.transientFailure ||
        status == LyricLookupStatus.invalidData) {
      final exponent = (failureCount - 1).clamp(0, 6);
      final milliseconds = (250 * (1 << exponent)).clamp(250, 10000);
      return Duration(milliseconds: milliseconds);
    }
    return Duration.zero;
  }
}
