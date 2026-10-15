import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/video_barrage_mapper.dart';

void main() {
  const duration = Duration(seconds: 100);

  test('真实响应形态：非空，且全部 mode==scroll、colorValue==0xFFFFFF', () {
    final raw = {
      'list': [
        {
          'id': 1700313813,
          'user_name': '虫虫',
          'content': '我怪这张专辑太厉害了👍',
          'addtime': '2026-09-08 20:18:57',
          'like': {'likenum': 0, 'count': 0, 'haslike': false},
        },
        {
          'id': 1700313814,
          'user_name': '路人',
          'content': '副歌绝了',
          'like': {'likenum': 12},
        },
      ],
      'count': 2,
      'status': 1,
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, isNotEmpty);
    for (final e in entries) {
      expect(e.mode, DanmakuMode.scroll);
      expect(e.colorValue, 0xFFFFFF);
    }
  });

  test('没有时间字段时不会用 addtime：单条时间 == duration/2', () {
    final raw = {
      'list': [
        {
          'id': 1,
          'content': '墙上时间不应被用',
          'addtime': '2026-09-08 20:18:57',
        },
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, hasLength(1));
    expect(entries.single.time, const Duration(seconds: 50));
    // addtime 解析出的毫秒数（若误用）不可能等于 50s 的均匀铺开结果
    expect(entries.single.time.inMilliseconds,
        isNot(equals(DateTime.parse('2026-09-08 20:18:57').millisecondsSinceEpoch)));
  });

  test('单条弹幕时间为中点：duration=100s → 50s', () {
    final raw = {
      'list': [
        {'id': 1, 'content': 'only one'},
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, hasLength(1));
    expect(entries.single.time, const Duration(seconds: 50));
  });

  test('两条弹幕 → 25% 与 75%（25s 与 75s）', () {
    final raw = {
      'list': [
        {'id': 1, 'content': 'a'},
        {'id': 2, 'content': 'b'},
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, hasLength(2));
    expect(entries[0].time, const Duration(seconds: 25));
    expect(entries[1].time, const Duration(seconds: 75));
  });

  test('点赞降序：高赞那条时间更早', () {
    final raw = {
      'list': [
        {'id': 1, 'content': '低赞', 'like': {'likenum': 0}},
        {'id': 2, 'content': '高赞', 'like': {'likenum': 5}},
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, hasLength(2));
    expect(entries.first.text, '高赞');
    expect(entries.first.time, lessThan(entries.last.time));
  });

  test('maxCount 生效', () {
    final raw = {
      'list': [
        {'id': 1, 'content': 'a'},
        {'id': 2, 'content': 'b'},
        {'id': 3, 'content': 'c'},
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration, maxCount: 1);
    expect(entries, hasLength(1));
  });

  test('空文本被丢弃 / {data:{list}} 包装可解析', () {
    final rawWithEmpty = {
      'list': [
        {'id': 1, 'content': '   '},
        {'id': 2, 'content': ''},
        {'id': 3, 'content': '有效'},
      ],
    };
    final entries = mapVideoBarrage(rawWithEmpty, videoDuration: duration);
    expect(entries, hasLength(1));
    expect(entries.single.text, '有效');

    final wrapped = {
      'data': {
        'list': [
          {'id': 10, 'content': '包装内'},
        ],
      },
    };
    final wrappedEntries = mapVideoBarrage(wrapped, videoDuration: duration);
    expect(wrappedEntries, hasLength(1));
    expect(wrappedEntries.single.text, '包装内');
  });

  test('videoDuration=0 → 空；非列表输入 → 空', () {
    final zero = mapVideoBarrage(
      {'list': [{'id': 1, 'content': 'x'}]},
      videoDuration: Duration.zero,
    );
    expect(zero, isEmpty);

    final notList = mapVideoBarrage(
      {'foo': 'bar'},
      videoDuration: duration,
    );
    expect(notList, isEmpty);
  });

  test('原生时间字段优先：带 progress 走 parseDanmakuList 分支（3s 而非 50s）', () {
    final raw = {
      'list': [
        {'id': 1, 'content': '带原生时间', 'progress': 3000},
      ],
    };
    final entries = mapVideoBarrage(raw, videoDuration: duration);
    expect(entries, hasLength(1));
    expect(entries.single.time, const Duration(seconds: 3));
  });
}
