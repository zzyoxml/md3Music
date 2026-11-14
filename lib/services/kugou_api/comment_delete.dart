import 'kugou_models.dart';

/// `/comment/music/del` 的参数集合（对齐服务端 `comment_send.rs::handle_music_del`）。
///
/// - [cid]：评论列表返回的评论 id；
/// - [specialId]：资源 special_child_id（歌曲/歌单/专辑评论池通用）；
/// - [mixsongid]：歌曲场景推荐传 `album_audio_id`，服务端先查一次歌曲评论自动反查，
///   比手填 special_id 更可靠；
/// - [tid]：楼中楼回复必传，恒为楼层根评论 id（嵌套不改变它）；
/// - [resourceType]：`song` / `playlist` / `album`，服务端按它解析评论池 code；
/// - [code]：显式评论池 code，优先级最高，通常为 null。
typedef CommentDeleteArgs = ({
  String cid,
  String? specialId,
  String? mixsongid,
  String? tid,
  String resourceType,
  String? code,
});

/// 把一条评论（顶层或楼中楼回复）翻译成删除参数。
///
/// [comment] 为被删的那条；[floorRoot] 非空表示删的是楼中楼回复——此时
/// `tid` 取楼层根评论 id、`special_id` 取楼层根的 `specialId`（回复项自身的
/// `special_child_id`/`tid` 字段语义与资源定位不同，必须忽略）。
/// [fallbackSpecialId] 为评论项缺 `special_child_id` 时的兜底（歌曲列表传顶层
/// `childrenid`；歌单/专辑页面评论区的 `childrenid`。**不要**传歌单
/// `global_collection_id`——那不是评论池的 special id）。
///
/// 解析不出有效参数（缺评论 id、缺楼层根 id、资源定位参数全缺）返回 null，
/// 调用方应不显示删除入口而不是发起必然失败的请求。
CommentDeleteArgs? buildCommentDeleteArgs({
  required KugouComment comment,
  KugouComment? floorRoot,
  required String resourceType,
  String? fallbackSpecialId,
  String? mixsongid,
}) {
  final cid = comment.id.trim();
  if (cid.isEmpty) return null;

  String? specialId;
  String? tid;
  if (floorRoot != null) {
    tid = floorRoot.id.trim();
    if (tid.isEmpty) return null;
    specialId = floorRoot.specialId?.isNotEmpty == true
        ? floorRoot.specialId
        : fallbackSpecialId;
  } else {
    specialId = comment.specialId?.isNotEmpty == true
        ? comment.specialId
        : fallbackSpecialId;
  }

  final sid = (specialId ?? '').trim();
  final mid = (mixsongid ?? '').trim();
  // 服务端要求 special_id 与 mixsongid 至少一个（歌曲场景只有 mixsongid 会反查）
  if (sid.isEmpty && mid.isEmpty) return null;

  final code = comment.code?.trim();
  return (
    cid: cid,
    specialId: sid.isEmpty ? null : sid,
    mixsongid: mid.isEmpty ? null : mid,
    tid: (tid == null || tid.isEmpty) ? null : tid,
    resourceType: resourceType,
    code: (code == null || code.isEmpty) ? null : code,
  );
}

/// 该评论是否为当前登录账号所发。
///
/// 任一侧（评论作者 id / 当前登录 id）缺失或空白时返回 false——
/// 宁可不出删除入口，也不能把别人的评论标成可删。
bool isOwnComment(KugouComment comment, String? currentUserid) {
  final uid = currentUserid?.trim() ?? '';
  final author = comment.userId?.trim() ?? '';
  return uid.isNotEmpty && author.isNotEmpty && uid == author;
}
