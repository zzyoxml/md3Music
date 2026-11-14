import '../../widgets/comment_verification.dart';
import 'package:m3e_core/m3e_core.dart';
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
///
/// [onDanmakuSent] 非空时多出一个「评论 / 弹幕」档位切换（仅顶层模式，弹幕没有
/// 楼层回复语义）；[startInDanmakuMode] 决定初始档位 —— 由封面区的弹幕按钮进来
/// 即默认弹幕档。两者都由调用方给出，本弹层不判断歌曲能否发弹幕（在线/本地与
/// hash 判定收在 `SongDanmakuHost.songDanmakuUsable`，避免两套口径漂移）。
void showCommentComposeSheet(
  BuildContext context, {
  required Song song,
  CommentReplyTarget? target,
  void Function(String text)? onDanmakuSent,
  bool startInDanmakuMode = false,
}) {
  showM3EModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => _CommentComposeBody(
      song: song,
      target: target,
      onDanmakuSent: onDanmakuSent,
      startInDanmakuMode: startInDanmakuMode,
    ),
  );
}

class _CommentComposeBody extends StatefulWidget {
  final Song song;
  final CommentReplyTarget? target;
  final void Function(String text)? onDanmakuSent;
  final bool startInDanmakuMode;

  const _CommentComposeBody({
    required this.song,
    this.target,
    this.onDanmakuSent,
    this.startInDanmakuMode = false,
  });

  @override
  State<_CommentComposeBody> createState() => _CommentComposeBodyState();
}

class _CommentComposeBodyState extends State<_CommentComposeBody> {
  bool _sending = false;

  /// 当前档位：false=评论，true=弹幕。
  late bool _danmaku = widget.startInDanmakuMode && widget.onDanmakuSent != null;

  /// 弹幕档位只在「顶层模式 + 调用方具备弹幕投递能力」时可选；
  /// 回复模式（[CommentReplyTarget] 非空）没有弹幕语义，不显示切换。
  bool get _canSwitchToDanmaku =>
      widget.target == null && widget.onDanmakuSent != null;

  Future<bool> _submit(String text) async {
    if (_danmaku) return _submitDanmaku(text);

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
      if (mounted) {
        setState(() => _sending = true);
        try {
          await handleCommentFailure(context, result);
        } finally {
          if (mounted) setState(() => _sending = false);
        }
      }
      return false;
    }
    showToast('评论已提交，审核通过后展示');
    if (mounted) Navigator.of(context).pop();
    return true;
  }

  /// 弹幕档提交：发到**歌曲弹幕池**（code `articulossong`，与上面的歌曲评论池
  /// 不是同一个池子）。
  ///
  /// 与 MV 页「本地先上屏、远端失败不回滚」的取舍**不同**，这里是远端成功才投递：
  /// 弹层在失败时保留原文供重发，若先落本地再重发会重复存同一条。
  /// special_id 由服务端按 hash 两跳解析，name 一并交给它解析（避免把本地歌名
  /// 写成与池内 `special_child_name` 不一致的值）。
  Future<bool> _submitDanmaku(String text) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录后再发弹幕', long: true);
      return false;
    }

    setState(() => _sending = true);
    final CommentSendResult result;
    try {
      result = await api.sendSongDanmaku(
        content: text,
        hash: widget.song.id,
        mixsongid: widget.song.albumAudioId,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }

    if (!result.ok) {
      if (mounted) {
        setState(() => _sending = true);
        try {
          await handleCommentFailure(context, result);
        } finally {
          if (mounted) setState(() => _sending = false);
        }
      }
      return false;
    }
    widget.onDanmakuSent?.call(text);
    showToast('弹幕已发送');
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
        if (_canSwitchToDanmaku)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('评论')),
                M3EToggleButtonGroupAction(label: Text('弹幕')),
              ],
              size: M3EButtonSize.xs,
              density: M3EButtonGroupDensity.compact,
              selectedIndex: _danmaku ? 1 : 0,
              onSelectedIndexChanged: (index) {
                if (index == null) return;
                setState(() => _danmaku = index == 1);
              },
            ),
          ),
        CommentComposer(
          sending: _sending,
          autofocus: true,
          // 只有输入框没有列表，顶部分隔线会显成一条突兀的白线
          showTopBorder: false,
          // 弹层不会随键盘上移，输入框必须自己避让，否则被输入法遮挡
          avoidKeyboard: true,
          replyToName: _danmaku ? null : widget.target?.displayName,
          onSubmit: _submit,
        ),
      ],
    );
  }
}
