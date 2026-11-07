import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/comment_delete.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// `buildCommentDeleteArgs` / `isOwnComment` 纯函数回归。
///
/// 服务端 `/comment/music/del` 的参数口径（对齐 KuGouMusicApi comment_music_del.js）：
/// - `cid` 必填（评论列表返回的评论 id）；
/// - `special_id` 必须取评论列表项的 `special_child_id`（或顶层 `childrenid`），
///   **不能**用发送评论响应里的 `special_id`；歌曲场景推荐传 `mixsongid` 反查；
/// - 删楼中楼回复时 `tid` 必传，且恒为楼层根评论 id（嵌套不改变它）。
void main() {
  KugouComment comment(Map<String, dynamic> json) => KugouComment.fromJson(json);

  group('buildCommentDeleteArgs（顶层评论）', () {
    test('评论项自带 special_child_id 时优先使用', () {
      final args = buildCommentDeleteArgs(
        comment: comment({
          'id': 'c1',
          'special_child_id': '148401',
          'code': 'pool-code',
        }),
        resourceType: 'song',
        fallbackSpecialId: 'children-1',
        mixsongid: '302362878',
      );

      expect(args, isNotNull);
      expect(args!.cid, 'c1');
      expect(args.specialId, '148401');
      expect(args.mixsongid, '302362878');
      expect(args.tid, isNull, reason: '顶层评论不传 tid');
      expect(args.resourceType, 'song');
      expect(args.code, 'pool-code');
    });

    test('评论项缺 special_child_id 时回退到列表 childrenid', () {
      final args = buildCommentDeleteArgs(
        comment: comment({'id': 'c1'}),
        resourceType: 'playlist',
        fallbackSpecialId: 'children-1',
      );

      expect(args, isNotNull);
      expect(args!.specialId, 'children-1');
      expect(args.mixsongid, isNull);
    });

    test('special_id 与 mixsongid 全缺时返回 null（服务端必然 400）', () {
      final args = buildCommentDeleteArgs(
        comment: comment({'id': 'c1'}),
        resourceType: 'song',
      );

      expect(args, isNull);
    });

    test('评论 id 为空返回 null', () {
      final args = buildCommentDeleteArgs(
        comment: comment({'id': ''}),
        resourceType: 'song',
        fallbackSpecialId: 'x',
      );

      expect(args, isNull);
    });
  });

  group('buildCommentDeleteArgs（楼中楼回复）', () {
    test('tid 取楼层根评论 id，special_id 取楼层根的 specialId', () {
      final root = comment({'id': 'root-1', 'special_child_id': '148401'});
      final reply = comment({
        // 回复项自身的 special_child_id / tid 语义与资源定位不同，必须被忽略
        'id': 'reply-1',
        'special_child_id': 'wrong',
        'tid': 'wrong-tid',
      });

      final args = buildCommentDeleteArgs(
        comment: reply,
        floorRoot: root,
        resourceType: 'song',
        fallbackSpecialId: 'children-1',
        mixsongid: '302362878',
      );

      expect(args, isNotNull);
      expect(args!.cid, 'reply-1');
      expect(args.tid, 'root-1', reason: 'tid 恒为楼层根评论 id');
      expect(args.specialId, '148401');
      expect(args.mixsongid, '302362878');
    });

    test('楼层根缺 specialId 时回退 fallbackSpecialId', () {
      final root = comment({'id': 'root-1'});
      final reply = comment({'id': 'reply-1'});

      final args = buildCommentDeleteArgs(
        comment: reply,
        floorRoot: root,
        resourceType: 'album',
        fallbackSpecialId: 'children-1',
      );

      expect(args, isNotNull);
      expect(args!.specialId, 'children-1');
    });

    test('楼层根 id 为空（无法给 tid）返回 null', () {
      final root = comment({'id': ''});
      final reply = comment({'id': 'reply-1'});

      final args = buildCommentDeleteArgs(
        comment: reply,
        floorRoot: root,
        resourceType: 'song',
        fallbackSpecialId: 'x',
      );

      expect(args, isNull);
    });
  });

  group('isOwnComment', () {
    test('作者与当前登录 userid 一致才算自己的', () {
      final c = comment({'id': 'c1', 'userid': '12345'});
      expect(isOwnComment(c, '12345'), isTrue);
      expect(isOwnComment(c, '67890'), isFalse);
    });

    test('无法判定（任一侧缺失/空白）一律 false，不出删除入口', () {
      expect(isOwnComment(comment({'id': 'c1'}), '12345'), isFalse);
      expect(isOwnComment(comment({'id': 'c1', 'userid': '12345'}), null), isFalse);
      expect(isOwnComment(comment({'id': 'c1', 'userid': '12345'}), ''), isFalse);
      expect(isOwnComment(comment({'id': 'c1', 'userid': ''}), '12345'), isFalse);
    });

    test('user_id 字段名兼容与首尾空白', () {
      final c = comment({'id': 'c1', 'user_id': ' 12345 '});
      expect(isOwnComment(c, '12345'), isTrue);
    });
  });
}
