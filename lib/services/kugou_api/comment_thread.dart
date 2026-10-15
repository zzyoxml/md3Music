import 'kugou_models.dart';

/// 楼中楼树展开后的一行：回复本身 + 嵌套层级 + 是否为孤儿。
///
/// [depth] 从 0 起算：0 是直接回复楼主的一级回复，1 是回复某条一级回复，依此类推。
/// [isOrphan] 为 true 表示该回复的父级不在已加载的回复里（通常父级还在后续分页
/// 中），此时按一级回复渲染，并保留内容里的「//@某人:原文」引用，否则看不出
/// 它在回复谁。
class CommentReplyNode {
  final KugouComment reply;
  final int depth;
  final bool isOrphan;

  const CommentReplyNode({
    required this.reply,
    required this.depth,
    required this.isOrphan,
  });
}

/// 按热度（点赞数）降序排列评论，点赞数相同时保持接口返回的原顺序。
///
/// [List.sort] 不保证稳定，因此用原始下标作为次级比较键，固定同赞数评论的相对
/// 顺序，避免翻页追加后已看过的评论互相跳动。
List<KugouComment> sortCommentsByHotness(List<KugouComment> comments) {
  final indexed = <(int, KugouComment)>[
    for (var i = 0; i < comments.length; i++) (i, comments[i]),
  ];
  indexed.sort((a, b) {
    final byLikes = b.$2.likes.compareTo(a.$2.likes);
    return byLikes != 0 ? byLikes : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// 把接口返回的扁平回复列表按 `pid`（[KugouComment.parentId]）组装成嵌套树，
/// 再深度优先展开成带层级的一维列表，供列表直接渲染。
///
/// 排序规则：同一层内按时间倒序（新的在前），时间相同或缺失时保持接口返回顺序。
/// 与上游 `replylist` 自身的顺序一致，这样「加载更多回复」只会往下追加更旧的
/// 回复，不会把已经读过的内容顶下去。父级始终在自己的子级之前（子级嵌在父级
/// 下方），与层内方向无关。
///
/// 容错：
/// - 同 id 只保留首次出现，避免分页重叠导致重复渲染；
/// - `pid` 指向未加载的回复时（回复比它的父级新，父级还在后面的分页里），该回复
///   按一级回复插入并标记 [CommentReplyNode.isOrphan]，等父级加载进来后自然归位；
/// - 迭代式深度优先遍历 + visited 集合，脏数据里的 `pid` 成环不会爆栈；
/// - 成环导致不可达的回复兜底追加到末尾，不静默丢内容。
List<CommentReplyNode> buildReplyTree(List<KugouComment> replies) {
  if (replies.isEmpty) return const [];

  final byId = <String, KugouComment>{};
  final ordered = <KugouComment>[];
  for (final reply in replies) {
    if (reply.id.isEmpty || byId.containsKey(reply.id)) continue;
    byId[reply.id] = reply;
    ordered.add(reply);
  }

  /// `pid` 为空/'0' 表示直接回复楼主，不算有父级。
  String? resolvedParentId(KugouComment reply) {
    final pid = reply.parentId;
    if (pid == null || pid.isEmpty || pid == '0') return null;
    if (pid == reply.id) return null;
    return byId.containsKey(pid) ? pid : null;
  }

  bool pointsToMissingParent(KugouComment reply) {
    final pid = reply.parentId;
    if (pid == null || pid.isEmpty || pid == '0' || pid == reply.id) {
      return false;
    }
    return !byId.containsKey(pid);
  }

  final roots = <KugouComment>[];
  final children = <String, List<KugouComment>>{};
  for (final reply in ordered) {
    final parentId = resolvedParentId(reply);
    if (parentId == null) {
      roots.add(reply);
    } else {
      children.putIfAbsent(parentId, () => <KugouComment>[]).add(reply);
    }
  }

  final originalIndex = <String, int>{
    for (var i = 0; i < ordered.length; i++) ordered[i].id: i,
  };
  int byTimeDesc(KugouComment a, KugouComment b) {
    final byTime = b.time.compareTo(a.time);
    if (byTime != 0) return byTime;
    return (originalIndex[a.id] ?? 0).compareTo(originalIndex[b.id] ?? 0);
  }

  roots.sort(byTimeDesc);
  for (final siblings in children.values) {
    siblings.sort(byTimeDesc);
  }

  final nodes = <CommentReplyNode>[];
  final visited = <String>{};
  // 栈按逆序压入，保证弹出顺序与排序后的兄弟顺序一致。
  final stack = <(KugouComment, int)>[
    for (final root in roots.reversed) (root, 0),
  ];
  while (stack.isNotEmpty) {
    final (reply, depth) = stack.removeLast();
    if (!visited.add(reply.id)) continue;
    nodes.add(
      CommentReplyNode(
        reply: reply,
        depth: depth,
        isOrphan: depth == 0 && pointsToMissingParent(reply),
      ),
    );
    final kids = children[reply.id];
    if (kids != null) {
      for (final kid in kids.reversed) {
        stack.add((kid, depth + 1));
      }
    }
  }

  for (final reply in ordered) {
    if (visited.add(reply.id)) {
      nodes.add(CommentReplyNode(reply: reply, depth: 0, isOrphan: true));
    }
  }

  return nodes;
}

/// 去掉楼中楼回复内容尾部的「//@被回复用户名:被回复内容」引用后缀。
///
/// 嵌套渲染后被回复的那条就在正上方，引用后缀是重复信息。仅当父级不在已加载
/// 数据里（[CommentReplyNode.isOrphan]）时才保留原文，用来指明回复对象。
String stripReplyQuote(String content) {
  final idx = content.lastIndexOf('//@');
  if (idx <= 0) return content;
  final ref = content.substring(idx + 3);
  // 没有「用户名:」结构的不当作引用后缀，避免把正文里的 //@ 误截断。
  if (ref.indexOf(':') <= 0) return content;
  final text = content.substring(0, idx).trim();
  return text.isEmpty ? content : text;
}
