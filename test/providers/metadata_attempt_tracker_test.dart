import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/listen_together_provider.dart';

/// 富化尝试记账的语义回归。
///
/// 背景：/audio 完全不返回封面字段，封面 100% 依赖 /search 命中同 hash 的
/// 候选。搜索会因网络抖动抛异常，命中的候选也可能恰好没图。历史实现把
/// 「发起过请求」当作「永远不必再试」，导致这些歌的封面永久补不上
/// （用户表现为「有概率加载不出封面」）。本组用例锁定修复后的语义。
void main() {
  group('MetadataAttemptTracker（富化记账）', () {
    late MetadataAttemptTracker tracker;

    setUp(() => tracker = MetadataAttemptTracker());

    test('初始状态：无额度、未耗尽、未跟踪', () {
      expect(tracker.isTracked('h1'), isFalse);
      expect(tracker.isExhausted('h1'), isFalse);
      expect(tracker.trackedCount, 0);
    });

    test('bump 消耗额度并进入跟踪', () {
      tracker.bump('h1');
      expect(tracker.isTracked('h1'), isTrue);
      expect(tracker.isExhausted('h1'), isFalse);
      expect(tracker.trackedCount, 1);
    });

    test('达到上限后才算耗尽（第 3 次尝试前仍未耗尽）', () {
      tracker.bump('h1');
      tracker.bump('h1');
      expect(tracker.isExhausted('h1'), isFalse, reason: '2 次 < 上限 3');
      tracker.bump('h1');
      expect(tracker.isExhausted('h1'), isTrue, reason: '3 次 = 上限');
    });

    test('refund 退还额度：失败不消耗重试机会', () {
      tracker.bump('h1');
      tracker.refund('h1');
      expect(tracker.isTracked('h1'), isFalse, reason: '退还至 0 时应清除条目');
      expect(tracker.isExhausted('h1'), isFalse);
    });

    test('refund 只递减计数，不清空既有进度', () {
      tracker.bump('h1'); // 1
      tracker.bump('h1'); // 2
      tracker.refund('h1'); // 回到 1
      expect(tracker.isTracked('h1'), isTrue);
      expect(tracker.isExhausted('h1'), isFalse);
      // 从退还后的 1 再补两次即达上限，证明退还保留了那 1 次已消耗
      tracker.bump('h1'); // 2
      expect(tracker.isExhausted('h1'), isFalse);
      tracker.bump('h1'); // 3
      expect(tracker.isExhausted('h1'), isTrue);
    });

    test('关键回归：搜索反复失败也不会耗尽额度', () {
      // 每次「发起 + 失败」都应回到原点，永不触及上限
      for (var i = 0; i < 10; i++) {
        tracker.bump('h1');
        expect(tracker.isExhausted('h1'), isFalse);
        tracker.refund('h1');
      }
      expect(tracker.isTracked('h1'), isFalse);
      expect(tracker.isExhausted('h1'), isFalse,
          reason: '这正是封面能持续重试、不再永久缺失的原因');
    });

    test('settle 销账：元数据补齐后不再重试', () {
      tracker.bump('h1');
      tracker.settle('h1');
      expect(tracker.isTracked('h1'), isFalse);
      expect(tracker.isExhausted('h1'), isFalse);
      expect(tracker.trackedCount, 0);
    });

    test('hash 大小写不敏感（与匹配维度口径一致）', () {
      tracker.bump('ABCDEF');
      expect(tracker.isTracked('abcdef'), isTrue);
      expect(tracker.isExhausted('AbCdEf'), isFalse);
      tracker.settle('abcdef');
      expect(tracker.isTracked('ABCDEF'), isFalse);
    });

    test('不同 hash 的额度互相独立', () {
      tracker.bump('h1');
      tracker.bump('h1');
      tracker.bump('h1');
      expect(tracker.isExhausted('h1'), isTrue);
      expect(tracker.isExhausted('h2'), isFalse,
          reason: 'h2 未被尝试过，不应受 h1 耗尽影响');
      expect(tracker.trackedCount, 1);
    });

    test('refund 未记账的 hash 是安全的 no-op', () {
      tracker.refund('never-seen');
      expect(tracker.isTracked('never-seen'), isFalse);
      expect(tracker.trackedCount, 0);
    });

    test('上限常量为 3', () {
      expect(MetadataAttemptTracker.maxAttempts, 3);
    });
  });
}
