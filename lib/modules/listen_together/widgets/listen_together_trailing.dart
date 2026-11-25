import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../providers/listen_together_provider.dart';
import '../../../widgets/player_top_bar_actions.dart';
import '../room_page.dart';
import 'chat_panel.dart';

/// 顶栏尾部的「一起听」项。
///
/// 顶栏尾部统一由 [TopBarTrailingCapsule] 渲染（竖屏与睡眠定时、⋯ 合成一颗胶囊，
/// 点开展开后自动收回）。本函数只把会话状态翻成那一项的数据：
///
/// - 无会话 → null，尾部就此少一格；
/// - 文案见 [_listenTogetherBadge]；
/// - 长按直接打开房间聊天托盘，有未读消息时右上角亮红点（游标与房间页共享，
///   任一入口读过后红点同步清除）；
/// - 左上角红点 = 房主有待处理点歌（语义见 [RoomSession.hasPendingSongOrders]：
///   请求被通过/忽略后才消失）；
/// - 「已脱离」态标成 `pinnedOpen`：那是一条必须一直看得见的引导，
///   不参与自动收回。
///
/// 必须在 build 里调用（内部 `watch` 会话）。
TopBarTrailingSegment? listenTogetherTopBarSegment(BuildContext context) {
  final session = context.watch<ListenTogetherProvider>().session;
  if (session == null) return null;
  return TopBarTrailingSegment(
    icon: Icons.groups,
    label: _listenTogetherBadge(session),
    semanticsLabel: '一起听',
    onTap: () => _openListenTogetherRoom(context, session),
    onLongPress: () => _openListenTogetherChat(context, session),
    unreadDot: session.hasUnreadChatMessages,
    pendingDot: session.hasPendingSongOrders,
    pinnedOpen: session.playbackDetached,
  );
}

/// 胶囊上的人数文案：脱离态显示「已脱离」引导回房间；容量未知（0，上游未返回
/// 麦位上限）时只显示在线人数。
String _listenTogetherBadge(RoomSession session) {
  if (session.playbackDetached) return '已脱离';
  return session.capacity > 0
      ? '${session.members.length}/${session.capacity}'
      : '${session.members.length}';
}

/// 进入房间页（暂离后可从播放器顶栏胶囊再次返回）。
Future<void> _openListenTogetherRoom(
  BuildContext context,
  RoomSession session,
) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => RoomPage(roomId: session.roomId)));

/// 长按胶囊：打开房间聊天托盘，读过的消息一并计为已读。
Future<void> _openListenTogetherChat(
  BuildContext context,
  RoomSession session,
) async {
  session.markChatMessagesSeen();
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const ChatPanel(),
  );
  // 托盘开着时新到的消息在关闭瞬间一并计为已读（内部会通知重建）
  session.markChatMessagesSeen();
}
