import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../providers/listen_together_provider.dart';
import '../room_page.dart';
import 'chat_panel.dart';

/// 播放器顶部「一起听」胶囊。
///
/// 仅在房间会话存活时显示，形如 `👥 1/5`（在线人数 / 人数上限）。
/// 点击进入房间页——房间页「暂离」后可从这里再次返回原房间；
/// 长按直接打开房间聊天托盘，有未读消息时胶囊右上角亮红点
/// （游标与房间页共享，任一入口读过后红点同步清除）；
/// 房主有待处理点歌请求时胶囊左上角亮红点（语义见
/// [RoomSession.hasPendingSongOrders]：请求被通过/忽略后才消失）。
class ListenTogetherPill extends StatelessWidget {
  /// AM 播放器样式：半透明白底白字（与 AM 音质胶囊统一）。
  /// 默认样式跟随主题 primaryContainer（与常规音质胶囊统一）。
  final bool amStyle;

  const ListenTogetherPill({super.key, this.amStyle = false});

  /// 胶囊上的小红点：8px 实心圆 + 与胶囊同色描边（微出血，避免被圆角吃掉）。
  Widget _dot(Color color, Color borderColor) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1.5),
        ),
      );

  Future<void> _openChat(BuildContext context, RoomSession session) async {
    session.markChatMessagesSeen();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ChatPanel(),
    );
    // 托盘开着时新到的消息在关闭瞬间一并计为已读（内部会通知重建）
    session.markChatMessagesSeen();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<ListenTogetherProvider>().session;
    if (session == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 背景与前景按宿主页面的音质胶囊风格取色，保证视觉统一
    final background = amStyle ? Colors.white.withValues(alpha: 0.15) : cs.primaryContainer;
    final foreground = amStyle ? Colors.white : cs.onPrimaryContainer;
    final hasUnread = session.hasUnreadChatMessages;
    // 待处理点歌请求（仅房主）：与聊天未读分列左右两角，两件事分开可见
    final hasPendingOrders = session.hasPendingSongOrders;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: background,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RoomPage(roomId: session.roomId)),
          ),
          onLongPress: () => _openChat(context, session),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.groups, size: 14, color: foreground),
                    const SizedBox(width: 4),
                    Text(
                      // 脱离态显示「已脱离」引导回房间；容量未知（0，上游未返回
                      // 麦位上限）时只显示在线人数
                      session.playbackDetached
                          ? '已脱离'
                          : session.capacity > 0
                              ? '${session.members.length}/${session.capacity}'
                              : '${session.members.length}',
                      // labelMedium 与音质胶囊同款字号与行高，保证胶囊高度一致
                      style: textTheme.labelMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                // 未读红点：悬于胶囊右上角，微出血避免被圆角吃掉
                if (hasUnread)
                  Positioned(
                    top: -3,
                    right: -4,
                    child: _dot(cs.error, background),
                  ),
                // 待处理点歌红点：悬于胶囊**左上角**（与聊天未读的右上角分开，
                // 合并成一个点会丢掉「两件事各自是否待处理」的信息）
                if (hasPendingOrders)
                  Positioned(
                    top: -3,
                    left: -4,
                    child: _dot(cs.error, background),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
