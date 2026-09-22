import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/danmaku_parser.dart';

void main() {
  group('parseDanmakuList', () {
    test('解析扁平数组（Bilibili p 属性风格字段名）', () {
      final list = parseDanmakuList([
        {'time': 2000, 'text': 'b', 'color': 16777215, 'type': 1},
        {'time': 1000, 'text': 'a', 'color': 255, 'type': 5},
      ]);
      expect(list.length, 2);
      expect(list[0].time, const Duration(milliseconds: 1000));
      expect(list[0].text, 'a');
      expect(list[0].colorValue, 255);
      expect(list[0].mode, DanmakuMode.top);
      expect(list[1].mode, DanmakuMode.scroll);
    });

    test('解析 {data: [...]} 与 {data: {list: [...]}} 两种包装', () {
      final a = parseDanmakuList({
        'data': [
          {'time': 1, 'text': 'x'},
        ],
      });
      expect(a.length, 1);
      final b = parseDanmakuList({
        'data': {
          'list': [
            {'time': 1, 'text': 'x'},
          ],
        },
      });
      expect(b.length, 1);
    });

    test('mode 映射：1→scroll / 4→bottom / 5→top', () {
      final list = parseDanmakuList([
        {'time': 1, 'text': 's', 'type': 1},
        {'time': 2, 'text': 'b', 'type': 4},
        {'time': 3, 'text': 't', 'type': 5},
      ]);
      expect(list[0].mode, DanmakuMode.scroll);
      expect(list[1].mode, DanmakuMode.bottom);
      expect(list[2].mode, DanmakuMode.top);
    });

    test('time 支持 number / 字符串毫秒', () {
      final list = parseDanmakuList([
        {'time': 1500, 'text': 'a'},
        {'time': '2500', 'text': 'b'},
      ]);
      expect(list[0].time, const Duration(milliseconds: 1500));
      expect(list[1].time, const Duration(milliseconds: 2500));
    });

    test('空文本与非法条目被丢弃', () {
      final list = parseDanmakuList([
        {'time': 1, 'text': '   '},
        {'time': 2},
        'not a map',
        {'time': 3, 'text': 'ok'},
      ]);
      expect(list.length, 1);
      expect(list.first.text, 'ok');
    });

    test('结果按 time 升序，且 time 为负的条目被丢弃', () {
      final list = parseDanmakuList([
        {'time': 3000, 'text': 'c'},
        {'time': -5, 'text': 'bad'},
        {'time': 1000, 'text': 'a'},
        {'time': 2000, 'text': 'b'},
      ]);
      expect(list.map((e) => e.text).toList(), ['a', 'b', 'c']);
    });

    test('非列表输入返回空列表而不抛异常', () {
      expect(parseDanmakuList(null), isEmpty);
      expect(parseDanmakuList('nonsense'), isEmpty);
      expect(parseDanmakuList({'data': 'nonsense'}), isEmpty);
    });
  });
}
