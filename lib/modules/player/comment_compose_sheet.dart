import 'package:material_ui/material_ui.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/comment_reply_target.dart';
import '../../services/kugou_api/comment_send_result.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/comment_composer.dart';

/// 仅含输入框的评论托盘（全屏播放器：长按评论段 / 点评论项「回复」弹出）。
///
/// 主题色设计：背景走 modal bottom sheet 的默认 surface 色系，与其它弹层一致。
/// [target] 非空时进入回复模式（`target.reply` 非空即楼中楼，`pid` 指向该回复）；
/// 否则发送歌曲顶层评论（special_id 与歌名由服务端自动解析）。
void showCommentComposeSheet(
  BuildContext context, {
  required Song song,
  CommentReplyTarget? target,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => _CommentComposeBody(song: song, target: target),
  );
}

class _CommentComposeBody extends StatefulWidget {
  final Song song;
  final CommentReplyTarget? target;

  const _CommentComposeBody({required this.song, this.target});

  @override
  State<_CommentComposeBody> createState() => _CommentComposeBodyState();
}

class _CommentComposeBodyState extends State<_CommentComposeBody> {
  bool _sending = false;

  Future<bool> _submit(String text) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录后再评论', long: true);
      return false;
    }

    setState(() => _sending = true);
    final CommentSendResult result;
    try {
      final target = widget.target;
      if (target == null) {
        result = await api.sendSongComment(
          content: text,
          mixsongid: widget.song.albumAudioId,
        );
      } else {
        // special_id 取楼层根的 special_child_id；compose 托盘没有评论区
        // childrenid 可兜底，正常情况下该字段恒存在（真机取证）
        final args = buildFloorReplyArgs(target);
        result = await api.sendFloorReply(
          specialId: args.specialId,
          tid: args.tid,
          content: text,
          resourceType: 'song',
          code: target.top.code,
          pid: args.pid,
          mixsongid: target.top.mixSongId ?? widget.song.albumAudioId,
          replyUserName: args.replyUserName,
          replyContent: args.replyContent,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }

    if (!result.ok) {
      showToast(result.message, long: true);
      return false;
    }
    showToast('评论已提交，审核通过后展示');
    if (mounted) Navigator.of(context).pop();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 拖动手柄（与其它弹层一致）
        Container(
          width: 32,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        CommentComposer(
          sending: _sending,
          autofocus: true,
          // 只有输入框没有列表，顶部分隔线会显成一条突兀的白线
          showTopBorder: false,
          // 弹层不会随键盘上移，输入框必须自己避让，否则被输入法遮挡
          avoidKeyboard: true,
          replyToName: widget.target?.displayName,
          onSubmit: _submit,
        ),
      ],
    );
  }
}
