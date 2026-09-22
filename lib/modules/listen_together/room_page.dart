import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/listen_together_provider.dart';
import '../../providers/player_provider.dart';
import 'widgets/chat_panel.dart';
import 'widgets/members_sheet.dart';
import 'widgets/order_song_sheet.dart';
import 'widgets/room_cover_image.dart';

/// 众乐房房间页：当前播放、房主控场、成员 / 歌单 / 聊天入口。
///
/// 房主控制播放并上报，成员自动跟随；成员在本地暂停只影响自己的设备。
/// 返回（含系统返回手势）为「暂离」——保留会话与轮询，可从播放器顶部
/// 的一起听胶囊再次进入；底部「离开」才是真正退房/解散。
///
/// 布局随方向自适应：竖屏为「封面在上、信息与操作在下」的单列；
/// 横屏改为「封面在左、信息与操作在右」的双列，避免封面挤压信息区。
///
/// 出栈由 [_RoomPageState._pop] 统一收口并做幂等守卫：主动暂离与「会话被清理」
/// 两条路径都会请求出栈，若无守卫会连弹两层（房间页 → 广场页 → LaunchPad）。
class RoomPage extends StatefulWidget {
  final String roomId;

  const RoomPage({super.key, required this.roomId});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  ListenTogetherProvider? _lt;
  bool _popped = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lt = context.read<ListenTogetherProvider>();
      _lt = lt;
      lt.addListener(_onSessionChanged);
      // 进入本页时会话若已被清理，直接返回
      if (lt.session == null) _pop();
    });
  }

  @override
  void dispose() {
    _lt?.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 会话被外部清理（远端解散）时自动返回。
  void _onSessionChanged() {
    if (!mounted || _popped || _exiting) return;
    if (_lt?.session == null) _pop();
  }

  /// 唯一出栈入口（幂等）：只弹一层，且不会重复弹。
  void _pop() {
    if (_popped || !mounted) return;
    _popped = true;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// 暂离：仅收起本页，保留房间会话（心跳与同步继续），可再次进入。
  void _minimize() {
    if (_popped) return;
    showToast('已暂离，可从播放器顶部的一起听胶囊返回');
    _pop();
  }

  /// 复制房间号（私密房靠它邀请他人）。
  Future<void> _copyRoomId() async {
    await Clipboard.setData(ClipboardData(text: widget.roomId));
    if (mounted) showToast('房间号已复制');
  }

  /// 成员计数文案：容量未知（0，上游未返回麦位上限）时只显示在线人数，
  /// 不编造 x/y 假上限。
  String _memberCountText(RoomSession session) => session.capacity > 0
      ? '${session.members.length}/${session.capacity} 人'
      : '${session.members.length} 人';

  /// 真正离开房间（房主可选解散）。
  Future<void> _exit() async {
    if (_exiting) return;
    final lt = context.read<ListenTogetherProvider>();
    final isOwner = lt.session?.isOwner ?? false;
    if (isOwner) {
      final dismiss = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('离开房间'),
          content: const Text('你是房主。解散房间会结束所有人的一起听；仅离开则房间保留。'),
          actions: [
            M3ETextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('仅离开'),
            ),
            M3EFilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('解散房间'),
            ),
          ],
        ),
      );
      // 取消：留在房间，不退出也不出栈
      if (dismiss == null) return;
      if (!mounted) return;
      setState(() => _exiting = true);
      await lt.exitRoom(dismiss: dismiss);
      showToast(dismiss ? '已解散房间' : '已离开房间');
    } else {
      if (!mounted) return;
      setState(() => _exiting = true);
      await lt.exitRoom();
      showToast('已离开房间');
    }
    _pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<ListenTogetherProvider>().session;
    // 会话已被清理：出栈逻辑由 _onSessionChanged/_pop 处理，这里只渲染占位
    if (session == null) {
      return const Scaffold(body: Center(child: M3ELoadingIndicator()));
    }

    final player = context.watch<PlayerProvider>();
    final cs = Theme.of(context).colorScheme;
    final song = player.currentSong;
    // 未读状态在 RoomSession 上（与播放器胶囊共享游标，任一入口读过即清除）
    final hasUnreadChat = session.hasUnreadChatMessages;
    // 待处理点歌请求（仅房主）：歌单入口右上角红点（胶囊红点见 ListenTogetherPill）
    final hasPendingOrders = session.hasPendingSongOrders;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // 系统返回 = 暂离（保留会话），真正离开走底部「离开」
        if (!didPop) _minimize();
      },
      child: Scaffold(
        appBar: AppBar(
          // 独立房间页（非一级 tab）：标题按屏幕中心对齐
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: '暂离房间',
            onPressed: _minimize,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                session.roomName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                '${session.isOwner ? "房主" : "成员"} · ${_memberCountText(session)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '成员',
              icon: Badge(
                // 主题色徽标：计数可读性与 AppBar 协调（默认 error 红与主题冲突）
                backgroundColor: cs.primary,
                label: Text(
                  '${session.members.length}',
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Icon(Icons.people_outline),
              ),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const MembersSheet(),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: isLandscape
              ? _buildLandscape(session, player, song, hasUnreadChat, hasPendingOrders)
              : _buildPortrait(session, player, song, hasUnreadChat, hasPendingOrders),
        ),
      ),
    );
  }

  /// 竖屏：单列（封面居中，信息与操作在下方）。
  ///
  /// 内容在「小屏 + 错误行」时总高会超过可用高度（固定 220 封面 + 各组固定
  /// 间距），此前直接触发 bottom overflow。改为按可用高度撑开、超出则滚动：
  ///
  /// - `SingleChildScrollView` + `ConstrainedBox(minHeight: 可用高度)`：滚动视图
  ///   传入的 maxHeight 无界，RenderFlex 的 `canFlex=false`，故 Column 先按内容
  ///   高布局，再被 minHeight 抬到可用高 → 实际高度 = max(内容高, 可用高)；
  /// - `MainAxisAlignment.spaceBetween` 把富余高度分给两个间隙，等价复现原
  ///   「双 Spacer」的分配（房间号贴顶、操作组贴底、封面信息组居中）；
  /// - 内容高于可用高度时不再分配间隙，整列变高并可滚动，不再溢出。
  Widget _buildPortrait(
    RoomSession session,
    PlayerProvider player,
    Song? song,
    bool hasUnreadChat,
    bool hasPendingOrders,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _roomIdChip(session),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _cover(song, 220),
                  const SizedBox(height: 24),
                  _titleBlock(song, session.lastError),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _statusRow(session),
                  _controls(session, player),
                  const SizedBox(height: 16),
                  _actions(context, session, hasUnreadChat, hasPendingOrders),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横屏：双列（封面在左自适应高度，信息与操作在右）。
  Widget _buildLandscape(
    RoomSession session,
    PlayerProvider player,
    Song? song,
    bool hasUnreadChat,
    bool hasPendingOrders,
  ) {
    final media = MediaQuery.of(context);
    // 封面按可用高度收缩，避免横屏下把信息区挤出屏幕
    final coverSize = (media.size.height * 0.42).clamp(120.0, 260.0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: Center(child: _cover(song, coverSize)),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: Column(
            children: [
              _roomIdChip(session),
              const Spacer(),
              _titleBlock(song, session.lastError),
              const SizedBox(height: 8),
              _statusRow(session),
              _controls(session, player),
              const Spacer(),
              _actions(context, session, hasUnreadChat, hasPendingOrders),
            ],
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// 房间号胶囊（私密房靠它邀请他人，点击复制）。
  Widget _roomIdChip(RoomSession session) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Material(
        color: cs.surfaceContainerHighest,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _copyRoomId,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tag, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '房间号 ${session.roomId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.copy, size: 14, color: cs.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(Song? song, double size) {
    final artwork = song?.artworkUri;
    return SizedBox(
      width: size,
      height: size,
      // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
      child: RoomCoverImage(
        url: artwork,
        iconSize: size * 0.32,
        customRadius: BorderRadius.circular(16),
      ),
    );
  }

  Widget _titleBlock(Song? song, String? lastError) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Text(
            // displayName：剥离上游 songname/filename 带回的 .mp3/.flac 等后缀
            song?.displayName ?? '房间暂无播放歌曲',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            song?.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          if (lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                lastError,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusRow(RoomSession session) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            session.isOwner ? Icons.record_voice_over : Icons.sync,
            size: 14,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              session.isOwner
                  ? '你控制播放，成员自动跟随'
                  : session.playbackDetached
                      // 脱离态（拖动进度/播放其他音乐）：中央按钮即恢复跟随入口
                      ? '已脱离跟随，点下方按钮恢复'
                      : (session.guestLocallyPaused ? '已暂停（仅本机）' : '跟随房主播放'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 播放控制：房主控制并上报；成员的暂停/恢复只作用于本机播放器。
  ///
  /// 两个分支都只调用播放器本身：房主的服务端上报、成员的本机暂停豁免
  /// 标记均由装配层注册的 `PlayerProvider.onPlaybackStateChangedByUser`
  /// 统一出口维护（见 app.dart 的 _forwardPlaybackStateToRoom，避免双重同步）。
  /// 脱离态下中央按钮变「恢复跟随」：一键清脱离标记并强同步追上房主进度，
  /// 不必绕道广场页的「回到房间」横幅。
  Widget _controls(RoomSession session, PlayerProvider player) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 48,
          color: session.playbackDetached ? cs.primary : null,
          icon: Icon(
            session.playbackDetached
                ? Icons.sync
                : (player.isPlaying ? Icons.pause_circle : Icons.play_circle),
          ),
          onPressed: () async {
            // 脱离态：恢复跟随（清脱离/本机暂停标记并强同步）
            if (session.playbackDetached) {
              try {
                await session.resumeRoomPlayback();
              } catch (_) {
                showToast('恢复跟随失败，请稍后重试');
              }
              return;
            }
            if (session.isOwner) {
              if (player.isPlaying) {
                await player.pause();
              } else {
                await player.resume();
              }
            } else {
              // 成员分支：暂停/恢复只操作播放器；本机暂停豁免标记由装配层的
              // onPlaybackStateChangedByUser 出口统一维护（见 _forwardPlaybackStateToRoom）
              if (player.isPlaying) {
                await player.pause();
              } else {
                await player.resume();
              }
            }
          },
        ),
      ],
    );
  }

  /// 底部三入口。聊天入口带未读红点：打开托盘前与关闭后都收口已读游标，
  /// 托盘开着时新到的消息在关闭瞬间一并计为已读。
  /// 「歌单」入口带待处理点歌红点（房主）：请求通过/忽略后自动消失，
  /// 与聊天未读游标语义不同（见 [RoomSession.hasPendingSongOrders]）。
  Widget _actions(
    BuildContext context,
    RoomSession session,
    bool hasUnreadChat,
    bool hasPendingOrders,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _BottomEntry(
          icon: Icons.queue_music,
          label: '歌单',
          showDot: hasPendingOrders,
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (_) => const OrderSongSheet(),
          ),
        ),
        _BottomEntry(
          icon: Icons.chat_bubble_outline,
          label: '聊天',
          showDot: hasUnreadChat,
          onTap: () async {
            session.markChatMessagesSeen();
            await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ChatPanel(),
            );
            if (!mounted) return;
            // 托盘开着时新到的消息在关闭瞬间一并计为已读（内部会通知重建）
            session.markChatMessagesSeen();
          },
        ),
        _BottomEntry(
          icon: Icons.logout,
          label: '离开',
          onTap: _exit,
        ),
      ],
    );
  }
}

class _BottomEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 图标右上角的红点（聊天未读新消息 / 待处理点歌请求）。
  final bool showDot;

  const _BottomEntry({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: showDot,
              backgroundColor: cs.error,
              smallSize: 10,
              offset: const Offset(3, -3),
              child: Icon(icon),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
