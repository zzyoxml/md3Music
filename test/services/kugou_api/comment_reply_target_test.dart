import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/comment_reply_target.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 楼中楼：把「楼层根评论 + 被回复的回复」翻译成 /comment/floor/send 的参数。
///
/// 参数形态来自 2026-09-18 真机只读取证（见 docs/superpowers/plans/
/// 2026-09-18-comment-floor-nested-reply.md 第 0 节）：
/// tid 恒为楼层根评论 id，pid 为被回复的回复 id（回复楼主时为 0），
/// content 由服务端按 reply_user_name/reply_content 拼 //@用户名:原文。
void main() {
  KugouComment comment({
    required String id,
    String username = '某人',
    String content = '内容',
    String? parentId,
    String? specialId,
    String? userId,
  }) =>
      KugouComment(
        id: id,
        username: username,
        content: content,
        parentId: parentId,
        specialId: specialId,
        userId: userId,
      );

  test('回复楼主：pid=0，引用楼主内容', () {
    final top = comment(
      id: '1001',
      username: '楼主',
      content: '祝福自己吧，路还远',
      specialId: '100285259',
      userId: '677633563',
    );
    final target = CommentReplyTarget(top: top);

    expect(target.isNested, isFalse);
    expect(target.displayName, '楼主');

    final args = buildFloorReplyArgs(target);
    expect(args.tid, '1001');
    expect(args.pid, '0');
    expect(args.specialId, '100285259');
    expect(args.replyUserName, '楼主');
    expect(args.replyContent, '祝福自己吧，路还远');
  });

  test('回复一级回复：pid=该回复 id，tid 仍是楼层根', () {
    final top = comment(id: '1001', username: '楼主', specialId: '100285259');
    final reply = comment(
      id: '2002',
      username: '小明',
      content: '加油',
      parentId: '0',
      specialId: '100285259',
    );
    final args = buildFloorReplyArgs(CommentReplyTarget(top: top, reply: reply));

    expect(args.tid, '1001', reason: '嵌套不改变 tid');
    expect(args.pid, '2002');
    expect(args.replyUserName, '小明');
    expect(args.replyContent, '加油');
    expect(args.specialId, '100285259');
  });

  test('回复嵌套回复：被回复内容里的引用后缀要先剥掉，避免后缀套娃', () {
    final top = comment(id: '1001', specialId: '100285259');
    final reply = comment(
      id: '2002',
      username: '小明',
      // 这条本身是回复别人的，内容尾部已带引用后缀
      content: '收到//@小红:先谢谢你',
      parentId: '2001',
    );
    final args = buildFloorReplyArgs(CommentReplyTarget(top: top, reply: reply));

    expect(args.pid, '2002');
    expect(args.replyContent, '收到', reason: '只保留被回复内容的正文');
  });

  test('楼层根缺 special_id 时用调用方兜底值', () {
    final top = comment(id: '1001'); // 无 specialId
    final args = buildFloorReplyArgs(
      CommentReplyTarget(top: top),
      fallbackSpecialId: '100285259',
    );
    expect(args.specialId, '100285259');
  });

  test('顶层评论缺 id 时不做任何 fallback（由调用方保证非空）', () {
    final args = buildFloorReplyArgs(
      CommentReplyTarget(top: comment(id: '')),
    );
    expect(args.tid, '');
  });

  test('KugouComment.userId 解析 user_id 字段', () {
    final c = KugouComment.fromJson({
      'id': '1',
      'user_name': '某人',
      'content': 'x',
      'user_id': 677633563,
    });
    expect(c.userId, '677633563');
  });
}
