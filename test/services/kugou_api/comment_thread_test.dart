import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/comment_thread.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 用 replylist 的真实字段名构造一条回复，顺带覆盖 `pid` / `addtime` 的解析。
KugouComment _reply(
  String id, {
  String pid = '0',
  String addtime = '2024-01-01 00:00:00',
  int likes = 0,
  String content = '内容',
}) {
  return KugouComment.fromJson({
    'id': id,
    'pid': pid,
    'addtime': addtime,
    'like': {'count': likes},
    'content': content,
    'user_name': '用户$id',
  });
}

List<String> _ids(List<CommentReplyNode> nodes) =>
    [for (final n in nodes) n.reply.id];

List<int> _depths(List<CommentReplyNode> nodes) =>
    [for (final n in nodes) n.depth];

void main() {
  group('sortCommentsByHotness', () {
    test('按点赞数降序排列', () {
      final sorted = sortCommentsByHotness([
        _reply('a', likes: 7),
        _reply('b', likes: 986),
        _reply('c', likes: 198),
      ]);

      expect([for (final c in sorted) c.id], ['b', 'c', 'a']);
    });

    test('点赞数相同时保持接口返回的原顺序', () {
      final sorted = sortCommentsByHotness([
        _reply('a', likes: 1),
        _reply('b', likes: 1),
        _reply('c', likes: 5),
        _reply('d', likes: 1),
      ]);

      expect([for (final c in sorted) c.id], ['c', 'a', 'b', 'd']);
    });

    test('空列表返回空列表', () {
      expect(sortCommentsByHotness(const []), isEmpty);
    });
  });

  group('buildReplyTree', () {
    test('pid 为 0 的回复都是一级回复，按时间倒序排列（新的在前）', () {
      final nodes = buildReplyTree([
        _reply('c', addtime: '2024-03-03 00:00:00'),
        _reply('a', addtime: '2024-01-01 00:00:00'),
        _reply('b', addtime: '2024-02-02 00:00:00'),
      ]);

      expect(_ids(nodes), ['c', 'b', 'a']);
      expect(_depths(nodes), [0, 0, 0]);
      expect(nodes.every((n) => !n.isOrphan), isTrue);
    });

    test('pid 指向同楼回复时嵌套在其下方，depth 递增', () {
      final nodes = buildReplyTree([
        _reply('parent', addtime: '2024-01-01 00:00:00'),
        _reply('child', pid: 'parent', addtime: '2024-01-02 00:00:00'),
        _reply('other', addtime: '2024-01-03 00:00:00'),
      ]);

      // other 最新排最前；child 虽比 parent 新，但嵌在 parent 下方而非与之同层
      expect(_ids(nodes), ['other', 'parent', 'child']);
      expect(_depths(nodes), [0, 0, 1]);
    });

    test('回复的回复的回复：多级嵌套层级正确，且父级始终排在子级之前', () {
      final nodes = buildReplyTree([
        _reply('l3', pid: 'l2', addtime: '2024-01-04 00:00:00'),
        _reply('l1', addtime: '2024-01-01 00:00:00'),
        _reply('sibling', addtime: '2024-01-03 00:00:00'),
        _reply('l2', pid: 'l1', addtime: '2024-01-02 00:00:00'),
      ]);

      expect(_ids(nodes), ['sibling', 'l1', 'l2', 'l3']);
      expect(_depths(nodes), [0, 0, 1, 2]);
    });

    test('同一父级下的多条子回复按时间倒序', () {
      final nodes = buildReplyTree([
        _reply('root', addtime: '2024-01-01 00:00:00'),
        _reply('late', pid: 'root', addtime: '2024-05-05 00:00:00'),
        _reply('early', pid: 'root', addtime: '2024-02-02 00:00:00'),
        _reply('mid', pid: 'root', addtime: '2024-03-03 00:00:00'),
      ]);

      expect(_ids(nodes), ['root', 'late', 'mid', 'early']);
      expect(_depths(nodes), [0, 1, 1, 1]);
    });

    test('pid 指向未加载的回复时按一级回复渲染并标记 isOrphan', () {
      final nodes = buildReplyTree([
        _reply('loaded', addtime: '2024-01-01 00:00:00'),
        _reply('orphan', pid: '999999', addtime: '2024-01-02 00:00:00'),
      ]);

      // orphan 更新，排在前面
      expect(_ids(nodes), ['orphan', 'loaded']);
      expect(_depths(nodes), [0, 0]);
      expect(nodes[0].isOrphan, isTrue);
      expect(nodes[1].isOrphan, isFalse);
    });

    test('分页重叠导致的重复 id 只保留首次出现', () {
      final nodes = buildReplyTree([
        _reply('a', addtime: '2024-01-01 00:00:00'),
        _reply('b', addtime: '2024-01-02 00:00:00'),
        _reply('a', addtime: '2024-01-03 00:00:00'),
      ]);

      expect(_ids(nodes), ['b', 'a']);
    });

    test('pid 互相成环时不死循环，且不丢回复', () {
      final nodes = buildReplyTree([
        _reply('x', pid: 'y', addtime: '2024-01-01 00:00:00'),
        _reply('y', pid: 'x', addtime: '2024-01-02 00:00:00'),
      ]);

      expect(_ids(nodes)..sort(), ['x', 'y']);
      expect(_depths(nodes), [0, 0]);
      expect(nodes.every((n) => n.isOrphan), isTrue);
    });

    test('pid 指向自身时按一级回复处理', () {
      final nodes = buildReplyTree([_reply('self', pid: 'self')]);

      expect(_ids(nodes), ['self']);
      expect(nodes.single.depth, 0);
      expect(nodes.single.isOrphan, isFalse);
    });

    test('空列表返回空列表', () {
      expect(buildReplyTree(const []), isEmpty);
    });
  });

  group('stripReplyQuote', () {
    test('去掉「//@用户名:被回复内容」引用后缀', () {
      expect(
        stripReplyQuote('山水一程路一程 加油 //@shir:祝福自己吧，路还远[玫瑰]'),
        '山水一程路一程 加油',
      );
    });

    test('没有引用后缀时原样返回', () {
      expect(stripReplyQuote('加油兄弟'), '加油兄弟');
    });

    test('只有引用、没有正文时原样返回，避免变成空白', () {
      expect(stripReplyQuote('//@shir:祝福自己吧'), '//@shir:祝福自己吧');
    });

    test('「//@」后没有「用户名:」结构时不截断正文', () {
      expect(stripReplyQuote('这个网址 //@没有冒号'), '这个网址 //@没有冒号');
    });
  });

  group('KugouComment 楼中楼字段解析', () {
    test('addtime 按北京时间（UTC+8）解析为秒级时间戳，不受设备时区影响', () {
      final reply = _reply('a', addtime: '2024-09-11 08:38:13');
      final expected =
          DateTime.utc(2024, 9, 11, 0, 38, 13).millisecondsSinceEpoch ~/ 1000;

      expect(reply.time, expected);
    });

    test('createtime 已是秒级时间戳时直接使用', () {
      final comment = KugouComment.fromJson({
        'id': 'a',
        'createtime': 1726015093,
        'content': 'x',
      });

      expect(comment.time, 1726015093);
    });

    test('时间字段缺失或无法解析时为 0', () {
      expect(KugouComment.fromJson({'id': 'a'}).time, 0);
      expect(KugouComment.fromJson({'id': 'a', 'addtime': ''}).time, 0);
      expect(KugouComment.fromJson({'id': 'a', 'addtime': '不是时间'}).time, 0);
    });

    test('pid 解析为 parentId，缺失时为 null', () {
      expect(_reply('a', pid: '716242823').parentId, '716242823');
      expect(_reply('a').parentId, '0');
      expect(KugouComment.fromJson({'id': 'a'}).parentId, isNull);
    });
  });

  group('KugouCommentList.total', () {
    test('楼层评论用 comments_num 作为回复总数', () {
      final list = KugouCommentList.fromJson({
        'comments_num': 27,
        'list': [
          {'id': 'a', 'content': 'x'},
        ],
      });

      expect(list.total, 27);
      expect(list.comments.length, 1);
    });

    test('存在 count 时优先于 comments_num', () {
      final list = KugouCommentList.fromJson({
        'count': 4221,
        'comments_num': 27,
        'list': const [],
      });

      expect(list.total, 4221);
    });
  });
}
