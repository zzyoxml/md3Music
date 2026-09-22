import 'comment_thread.dart' show stripReplyQuote;
import 'kugou_models.dart';

/// 楼层回复目标：楼层根评论（对应上游 `tid`）+ 可选的「被回复的那条回复」。
///
/// 上游嵌套约定（2026-09-18 真机只读取证，见
/// docs/superpowers/plans/2026-09-18-comment-floor-nested-reply.md 第 0 节）：
/// - `tid` 恒为该楼层的根评论 id，**嵌套不改变它**；
/// - `pid` 为被回复的那条回复的 id，回复楼主时为 0（上游按 `is_t=1` 处理）；
/// - 内容尾部要带 `//@被回复者名字:被回复内容`，一级回复也不例外。
class CommentReplyTarget {
  /// 楼层根评论（楼主）。
  final KugouComment top;

  /// 被回复的具体回复；null = 回复楼主。
  final KugouComment? reply;

  const CommentReplyTarget({required this.top, this.reply});

  /// 输入框「回复 @xxx」提示条里显示的名字。
  String get displayName => (reply ?? top).username;

  /// 是否楼中楼（回复某条回复）。
  bool get isNested => reply != null;

  /// 上游 `pid`。
  String get pid => reply?.id ?? '0';
}

/// `/comment/floor/send` 的参数集合（不含 content）。
typedef FloorReplyArgs = ({
  String tid,
  String pid,
  String specialId,
  String? replyUserName,
  String? replyContent,
});

/// 把回复目标翻译成上游参数。
///
/// [fallbackSpecialId] 为楼层根缺 `special_child_id` 时的兜底（通常传评论区的
/// `childrenid`）。
FloorReplyArgs buildFloorReplyArgs(
  CommentReplyTarget target, {
  String? fallbackSpecialId,
}) {
  final quoted = target.reply ?? target.top;
  final specialId = target.top.specialId?.isNotEmpty == true
      ? target.top.specialId!
      : (fallbackSpecialId ?? '');
  return (
    tid: target.top.id,
    pid: target.pid,
    specialId: specialId,
    replyUserName: quoted.username,
    // 被回复内容自带引用后缀时先剥掉，否则每嵌套一层后缀就套一层
    replyContent: stripReplyQuote(quoted.content),
  );
}
