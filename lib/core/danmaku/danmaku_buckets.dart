import 'danmaku_entry.dart';

/// 一次 [DanmakuBuckets.feed] 的产出。
class DanmakuFeedResult {
  /// 本次需要提交给渲染器的弹幕（按时间升序）。
  final List<DanmakuEntry> due;

  /// 为 true 时调用方必须先清屏（发生了往回的时间跳变）。
  final bool reset;

  const DanmakuFeedResult({required this.due, required this.reset});

  static const empty = DanmakuFeedResult(due: [], reset: false);
}

/// PiliPlus 式桶时间轴：弹幕按 100ms 粒度分桶，feed 时遍历
/// 「[_nextMs, posMs]」区间内的桶并投递。
///
/// 参考 PiliPlus `lib/pages/danmaku/controller.dart:88-104`（`_dmSegMap`）。
/// 与其差异：PiliPlus 靠播放器在 seek 时显式 `clear()`（其
/// `lib/plugin/pl_player/controller.dart:776,1085`），本项目 `video_player`
/// 无 seek 回调，因此保留回退检测与跳变阈值作兜底。
///
/// 复杂度：每次 feed 只遍历阈值内的桶（2s 阈值 → 最多 21 桶），
/// 与弹幕总量无关；区间过滤保证同一条弹幕只投递一次。
class DanmakuBuckets {
  /// 桶粒度。与 PiliPlus 一致取 100ms：肉眼不可分辨，且限制单桶容量。
  static const int bucketMs = 100;

  /// 位置回退容差。
  ///
  /// `video_player` 的 position 由 500ms 周期定时器上报，与调用方的墙钟外推
  /// 之间存在**亚秒级抖动**（定时器抖动、缓冲恢复后上报回退）。若把任何回退都
  /// 当成 seek 清屏，表现为「弹幕滚动一下就整体消失」。因此只有回退**超过**本
  /// 容差才判定为真正的向后 seek；容差内视为抖动，不清屏也不重复投递。
  static const Duration backwardTolerance = Duration(milliseconds: 800);

  final Map<int, List<DanmakuEntry>> _buckets;

  /// 下一次应投递的时间起点（毫秒，含）。
  int _nextMs = 0;

  /// 上一次 feed 的位置，用于检测回退与跳变。
  int _lastPosMs = 0;

  bool _started = false;

  DanmakuBuckets(List<DanmakuEntry> entries)
      : _buckets = _buildBuckets(entries);

  static Map<int, List<DanmakuEntry>> _buildBuckets(
    List<DanmakuEntry> entries,
  ) {
    final map = <int, List<DanmakuEntry>>{};
    for (final e in entries) {
      final ms = e.time.inMilliseconds < 0 ? 0 : e.time.inMilliseconds;
      (map[ms ~/ bucketMs] ??= []).add(e);
    }
    return map;
  }

  /// 用当前播放位置推进时间轴。
  ///
  /// - 首次调用：不补投历史弹幕，只把投递刻度定位到 [position]。
  /// - 正常前进：投递 `[_nextMs, position]` 区间内的弹幕。
  /// - 前进超过 [jumpThreshold]：判定为向前 seek，刻度跳到 [position]，不补投。
  /// - 位置回退：判定为向后 seek，返回 `reset = true`，刻度重置到 [position]。
  DanmakuFeedResult feed(
    Duration position, {
    Duration jumpThreshold = const Duration(seconds: 2),
  }) {
    final posMs = position.inMilliseconds;
    if (!_started) {
      _started = true;
      _lastPosMs = posMs;
      _nextMs = posMs;
      return DanmakuFeedResult.empty;
    }

    if (posMs < _lastPosMs) {
      final driftMs = _lastPosMs - posMs;
      if (driftMs <= backwardTolerance.inMilliseconds) {
        // 上报/外推抖动：只回落「上次位置」，不动投递刻度 ——
        // 既不清屏，也不会把已投递的弹幕再投一遍。
        _lastPosMs = posMs;
        return DanmakuFeedResult.empty;
      }
      _lastPosMs = posMs;
      _nextMs = posMs;
      return const DanmakuFeedResult(due: [], reset: true);
    }

    if (posMs - _lastPosMs > jumpThreshold.inMilliseconds) {
      _lastPosMs = posMs;
      _nextMs = posMs;
      return DanmakuFeedResult.empty;
    }

    final due = <DanmakuEntry>[];
    if (posMs >= _nextMs) {
      final startBucket = _nextMs ~/ bucketMs;
      final endBucket = posMs ~/ bucketMs;
      for (var b = startBucket; b <= endBucket; b++) {
        final bucket = _buckets[b];
        if (bucket == null) continue;
        for (final e in bucket) {
          final t = e.time.inMilliseconds;
          if (t >= _nextMs && t <= posMs) {
            due.add(e);
          }
        }
      }
      due.sort((a, b) => a.time.compareTo(b.time));
    }

    _lastPosMs = posMs;
    _nextMs = posMs + 1;
    return DanmakuFeedResult(due: due, reset: false);
  }

  /// 回到未开始状态（视频控制器被重建时使用）。
  void reset() {
    _nextMs = 0;
    _lastPosMs = 0;
    _started = false;
  }
}
