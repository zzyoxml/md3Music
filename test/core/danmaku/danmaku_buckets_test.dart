import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_buckets.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';

DanmakuEntry _e(int ms, String text) =>
    DanmakuEntry(time: Duration(milliseconds: ms), text: text);

void main() {
  group('DanmakuBuckets', () {
    test('首次 feed 不补投历史弹幕，只定位投递刻度', () {
      final t = DanmakuBuckets([_e(1000, 'a'), _e(6000, 'b')]);
      final r = t.feed(const Duration(seconds: 10));
      expect(r.due, isEmpty);
      expect(r.reset, isFalse);
    });

    test('正常推进：区间内弹幕按时间升序投出', () {
      final t = DanmakuBuckets([
        _e(1000, 'a'),
        _e(1500, 'b'),
        _e(3000, 'c'),
      ]);
      t.feed(const Duration(seconds: 1));
      final r1 = t.feed(const Duration(milliseconds: 1600));
      expect(r1.due.map((e) => e.text).toList(), ['a', 'b']);
      final r2 = t.feed(const Duration(milliseconds: 2000));
      expect(r2.due, isEmpty);
      final r3 = t.feed(const Duration(seconds: 3));
      expect(r3.due.map((e) => e.text).toList(), ['c']);
    });

    test('同位置重复 feed 不重复投递', () {
      final t = DanmakuBuckets([_e(1000, 'a')]);
      t.feed(const Duration(milliseconds: 900));
      expect(t.feed(const Duration(milliseconds: 1000)).due.length, 1);
      expect(t.feed(const Duration(milliseconds: 1000)).due, isEmpty);
      expect(t.feed(const Duration(milliseconds: 1000)).due, isEmpty);
      expect(t.feed(const Duration(milliseconds: 1100)).due, isEmpty);
    });

    test('回退 seek：reset=true，清空后区间重置、弹幕重新投出', () {
      final t = DanmakuBuckets([_e(1000, 'a'), _e(2000, 'b')]);
      t.feed(const Duration(milliseconds: 500));
      expect(t.feed(const Duration(seconds: 2)).due.length, 2);

      final back = t.feed(const Duration(milliseconds: 500));
      expect(back.reset, isTrue);
      expect(back.due, isEmpty);

      final again = t.feed(const Duration(seconds: 2));
      expect(again.reset, isFalse);
      expect(again.due.map((e) => e.text).toList(), ['a', 'b']);
    });

    test('前进 seek 超阈值：不补投被跳过的弹幕', () {
      final t = DanmakuBuckets([
        _e(1000, 'a'),
        _e(2000, 'b'),
        _e(5000, 'c'),
      ]);
      t.feed(const Duration(milliseconds: 900));
      final r = t.feed(const Duration(milliseconds: 4500));
      expect(r.reset, isFalse);
      expect(r.due, isEmpty);
      final r2 = t.feed(const Duration(seconds: 5));
      expect(r2.due.map((e) => e.text).toList(), ['c']);
    });

    test('阈值内的正常播放不触发 seek 判定', () {
      final t = DanmakuBuckets([_e(2000, 'a')]);
      t.feed(const Duration(milliseconds: 500));
      final r = t.feed(const Duration(milliseconds: 2400));
      expect(r.reset, isFalse);
      expect(r.due.map((e) => e.text).toList(), ['a']);
    });

    test('小幅回退（上报抖动）不触发清屏、也不重复投递', () {
      // 真机现象：弹幕滚动一下就整体消失。根因是 video_player 的 500ms 位置上报
      // 与墙钟外推之间的亚秒抖动被误判为 seek → clear()。
      final t = DanmakuBuckets([
        _e(1000, 'a'),
        _e(2000, 'b'),
        _e(3000, 'c'),
      ]);
      t.feed(const Duration(milliseconds: 500));
      expect(t.feed(const Duration(milliseconds: 2000)).due.length, 2);

      // 抖动：位置回落 40ms（远小于 800ms 容差）
      final jitter = t.feed(const Duration(milliseconds: 1960));
      expect(jitter.reset, isFalse, reason: '容差内的回退不得清屏');
      expect(jitter.due, isEmpty);

      // 抖动后继续前进：已投递的弹幕不得重复出现
      expect(t.feed(const Duration(milliseconds: 2100)).due, isEmpty);
      // 越过下一条弹幕时间后正常投递
      expect(
        t.feed(const Duration(milliseconds: 3000)).due.map((e) => e.text).toList(),
        ['c'],
      );
    });

    test('回退恰好等于容差边界时不触发清屏，超过则触发', () {
      final t = DanmakuBuckets([_e(1000, 'a')]);
      t.feed(const Duration(milliseconds: 2000));
      // 恰好 800ms 回退 → 视为抖动
      expect(t.feed(const Duration(milliseconds: 1200)).reset, isFalse);
      // 超过 800ms（此处 801ms 相对上一次的 1200ms）→ 视为 seek
      expect(t.feed(const Duration(milliseconds: 399)).reset, isTrue);
    });

    test('reset() 后回到初始状态', () {
      final t = DanmakuBuckets([_e(1000, 'a')]);
      t.feed(const Duration(milliseconds: 500));
      expect(t.feed(const Duration(seconds: 1)).due.length, 1);
      t.reset();
      final r = t.feed(const Duration(seconds: 20));
      expect(r.due, isEmpty);
    });

    test('同一 100ms 桶内多条弹幕全部投出', () {
      final t = DanmakuBuckets([
        _e(1050, 'a'),
        _e(1080, 'b'),
        _e(1099, 'c'),
      ]);
      t.feed(const Duration(milliseconds: 1000));
      final r = t.feed(const Duration(milliseconds: 1100));
      expect(r.due.map((e) => e.text).toList(), ['a', 'b', 'c']);
    });

    test('桶边界不重不漏：999ms 与 1000ms 分属两桶，各投一次', () {
      final t = DanmakuBuckets([
        _e(999, 'a'),
        _e(1000, 'b'),
        _e(1001, 'c'),
      ]);
      t.feed(const Duration(milliseconds: 900));
      final r = t.feed(const Duration(milliseconds: 1100));
      expect(r.due.map((e) => e.text).toList(), ['a', 'b', 'c']);
      expect(t.feed(const Duration(milliseconds: 1200)).due, isEmpty);
    });

    test('2s 阈值内跨桶遍历有界（不随弹幕总量增长）', () {
      // 1000 条弹幕散布在 0-99.9s，feed 每次只触及阈值内的桶
      final entries = List.generate(
        1000,
        (i) => _e(i * 100, 'd$i'),
      );
      final t = DanmakuBuckets(entries);
      t.feed(const Duration(milliseconds: 50_000));
      final r = t.feed(const Duration(milliseconds: 51_900));
      // 区间 [50000, 51900]，每 100ms 一条 → 20 条
      expect(r.due.length, 20);
    });
  });
}
