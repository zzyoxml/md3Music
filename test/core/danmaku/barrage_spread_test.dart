import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/barrage_spread.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';

void main() {
  const duration = Duration(seconds: 100);

  BarrageItem item(String text, {String id = '', int like = 0}) =>
      BarrageItem(text: text, id: id, likeCount: like);

  group('spreadBarrage', () {
    test('4 条：首条落在 duration/2n（12.5s），末条落在 (n-0.5)/n（87.5s）', () {
      final entries = spreadBarrage(
        [item('a'), item('b'), item('c'), item('d')],
        duration: duration,
      );
      expect(entries, hasLength(4));
      expect(entries.first.time, const Duration(milliseconds: 12500));
      expect(entries.last.time, const Duration(milliseconds: 87500));
      // 顺序消费前提：严格按时间升序
      for (var i = 1; i < entries.length; i++) {
        expect(entries[i].time, greaterThan(entries[i - 1].time));
      }
    });

    test('池仅 1 条 → 落在中段（50s），不是开头一闪而过', () {
      final entries = spreadBarrage([item('only')], duration: duration);
      expect(entries.single.time, const Duration(seconds: 50));
    });

    test('点赞降序优先；同赞数按 id 升序，排序结果确定', () {
      final entries = spreadBarrage([
        item('低赞', id: '1', like: 0),
        item('高赞', id: '2', like: 9),
        item('同赞b', id: 'b', like: 3),
        item('同赞a', id: 'a', like: 3),
      ], duration: duration);
      expect(entries.map((e) => e.text).toList(), ['高赞', '同赞a', '同赞b', '低赞']);
    });

    test('空文本条目被丢弃（含纯空白）', () {
      final entries = spreadBarrage([
        item('   ', id: '1'),
        item('', id: '2'),
        item('有效', id: '3'),
      ], duration: duration);
      expect(entries, hasLength(1));
      expect(entries.single.text, '有效');
    });

    test('maxCount 截断：取的是排序后的前 N 条', () {
      final entries = spreadBarrage(
        [item('a', id: '1', like: 5), item('b', id: '2', like: 9)],
        duration: duration,
        maxCount: 1,
      );
      expect(entries, hasLength(1));
      expect(entries.single.text, 'b');
    });

    test('评论池无颜色/类型字段 → 统一白色滚动弹幕，id 前缀 barrage-', () {
      final entries = spreadBarrage([item('x', id: '42')], duration: duration);
      expect(entries.single.colorValue, 0xFFFFFF);
      expect(entries.single.mode, DanmakuMode.scroll);
      expect(entries.single.id, 'barrage-42');
    });

    test('无 id 时用下标兜底，避免渲染层拿到重复空 id', () {
      final entries = spreadBarrage([item('x')], duration: duration);
      expect(entries.single.id, 'barrage-by-index-0');
    });

    test('duration 非正数 → 空；空输入 → 空', () {
      expect(spreadBarrage([item('x')], duration: Duration.zero), isEmpty);
      expect(
        spreadBarrage([item('x')], duration: const Duration(milliseconds: -1)),
        isEmpty,
      );
      expect(spreadBarrage(const [], duration: duration), isEmpty);
    });
  });

  group('共享取数助手', () {
    test('extractBarrageItems：顶层 list 优先，兼容 data 包装与裸数组', () {
      expect(extractBarrageItems({'list': [1, 2]}), [1, 2]);
      expect(
        extractBarrageItems({
          'data': {
            'list': [3],
          },
        }),
        [3],
      );
      expect(extractBarrageItems([4]), [4]);
      expect(extractBarrageItems({'foo': 'bar'}), isEmpty);
      expect(extractBarrageItems(null), isEmpty);
    });

    test('barrageLikeCount：like 对象（likenum/count）与裸数字都吃得下', () {
      expect(barrageLikeCount({'likenum': 232, 'count': 232, 'haslike': false}), 232);
      expect(barrageLikeCount({'count': '7'}), 7);
      expect(barrageLikeCount(12), 12);
      expect(barrageLikeCount(null), 0);
    });
  });
}
