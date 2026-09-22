import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/comment_sort.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 评论客户端排序：最热（点赞降序+稳定）、时间升降序。
void main() {
  KugouComment c(String id, {int likes = 0, int time = 0}) => KugouComment(
        id: id,
        username: id,
        content: id,
        likes: likes,
        time: time,
      );

  test('最热：点赞降序，同赞数保持原相对顺序（稳定）', () {
    final list = [c('a', likes: 3), c('b', likes: 9), c('c', likes: 3), c('d')];
    final out = sortCommentsForDisplay(list, CommentSortMode.hottest);
    expect(out.map((e) => e.id).toList(), ['b', 'a', 'c', 'd']);
  });

  test('时间降序：最新在前', () {
    final list = [
      c('old', time: 100),
      c('new', time: 300),
      c('mid', time: 200),
    ];
    final out = sortCommentsForDisplay(list, CommentSortMode.timeDesc);
    expect(out.map((e) => e.id).toList(), ['new', 'mid', 'old']);
  });

  test('时间升序：最早在前', () {
    final list = [
      c('old', time: 100),
      c('new', time: 300),
      c('mid', time: 200),
    ];
    final out = sortCommentsForDisplay(list, CommentSortMode.timeAsc);
    expect(out.map((e) => e.id).toList(), ['old', 'mid', 'new']);
  });

  test('时间相同的条目保持接口返回的原相对顺序', () {
    final list = [c('x1', time: 100), c('x2', time: 100), c('x3', time: 100)];
    for (final mode in CommentSortMode.values) {
      final out = sortCommentsForDisplay(list, mode);
      expect(out.map((e) => e.id).toList(), ['x1', 'x2', 'x3'], reason: '$mode');
    }
  });

  test('空列表与单项列表安全', () {
    expect(sortCommentsForDisplay([], CommentSortMode.hottest), isEmpty);
    final one = sortCommentsForDisplay([c('only', time: 5)], CommentSortMode.timeAsc);
    expect(one.single.id, 'only');
  });
}
