import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/listen_together_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/listen_together_api.dart';
import '../../services/kugou_api/listen_together_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import 'create_room_sheet.dart';
import 'join_room_sheet.dart';
import 'room_page.dart';
import 'widgets/room_cover_image.dart';
import 'widgets/room_preview_sheet.dart';

/// 广场内容的最大宽度：横屏/平板下居中限宽，避免卡片被拉得过宽。
const double _kSquareMaxWidth = 760;

/// 一起听（众乐房）广场页。
///
/// 三态展示：加载中 / 加载失败可重试 / 房间列表（MD3E 卡片列表）。
/// 支持下拉刷新、触底自动加载更多、创建房间与房间号加入。
class ListenTogetherPage extends StatefulWidget {
  const ListenTogetherPage({super.key});

  @override
  State<ListenTogetherPage> createState() => _ListenTogetherPageState();
}

class _ListenTogetherPageState extends State<ListenTogetherPage> {
  /// 0 = 广场，1 = 我的房间。
  int _scopeIndex = 0;

  /// 广场搜索词（纯本地过滤房间名/房主/正在播放，不发请求）。
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lt = context.read<ListenTogetherProvider>();
      // 并发触发解散记忆恢复（完成后 notifyListeners 刷新列表剔除），
      // 与首屏加载并行、不阻塞首屏
      unawaited(lt.restoreDissolvedRooms());
      lt.loadSquare();
    });
  }

  String? _selfUserId() => context.read<KugouProvider>().userid;

  /// 切换广场 / 我的房间；我的房间需要登录态。
  Future<void> _switchScope(int? index) async {
    if (index == null || index == _scopeIndex) return;
    setState(() {
      _scopeIndex = index;
      // 搜索框只存在于广场 Tab：切走时重置，避免返回后「无输入框却仍在过滤」
      _searchQuery = '';
    });
    if (index != 1) return;
    final userId = _selfUserId();
    if (userId == null) {
      showToast('请先登录后再查看我的房间');
      setState(() => _scopeIndex = 0);
      return;
    }
    await context.read<ListenTogetherProvider>().loadMyRooms(selfUserId: userId);
  }

  /// 加入房间并跳转房间页。
  Future<void> _openRoom(String roomId, String roomName) async {
    final lt = context.read<ListenTogetherProvider>();
    final player = context.read<PlayerProvider>();
    final account = context.read<KugouProvider>();
    if (account.userid == null) {
      showToast('请先登录后再使用一起听');
      return;
    }
    try {
      final ok = await lt.enter(
        roomId: roomId,
        roomName: roomName,
        player: player,
        account: account,
      );
      if (!ok || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RoomPage(roomId: roomId)),
      );
    } on ListenTogetherApiError catch (e) {
      if (lt.isKnownDissolved(roomId)) {
        showToast('房间已解散，已从列表移除');
      } else {
        // 上游已给出可读中文时保留，否则回退到错误码映射
        showToast(listenTogetherErrorText(e), long: true);
      }
    } catch (_) {
      showToast('加入房间失败，请稍后重试');
    }
  }

  /// 点卡片先弹预览托盘（room_state 存活校验 + 详情/成员预览，对齐
  /// EchoMusic inspectRoom），确认「加入一起听」后再走原有入房流程。
  Future<void> _previewThenOpen(String roomId, String roomName) async {
    // 按房间号从当前 Tab 列表匹配卡片摘要（懒加载，找不到用占位对象兜底）
    final lt = context.read<ListenTogetherProvider>();
    MusicRoomBrief? brief;
    for (final r in (_scopeIndex == 1 ? lt.myRooms : lt.rooms)) {
      if (r.roomId == roomId) {
        brief = r;
        break;
      }
    }
    final joined = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RoomPreviewSheet(brief: brief ?? MusicRoomBrief.byRoomId(roomId)),
    );
    if (joined != true || !mounted) return;
    await _openRoom(roomId, roomName);
  }

  Future<void> _createRoom() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CreateRoomSheet(),
    );
    if (created != true || !mounted) return;
    final roomId = context.read<ListenTogetherProvider>().session?.roomId;
    if (roomId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RoomPage(roomId: roomId)),
    );
  }

  Future<void> _joinById() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const JoinRoomSheet(),
    );
    if (id == null || id.isEmpty) return;
    await _openRoom(id, '一起听房间');
  }

  /// 脱离态横幅：听众在房间外播放其他音乐时提示可一键回到房间。
  /// 会话存在且已脱离时返回横幅，否则返回 null（不占位）。
  Widget? _buildDetachBanner(ListenTogetherProvider lt) {
    if (!(lt.inRoom && (lt.session?.playbackDetached ?? false))) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.music_note),
          title: const Text('正在播放其他音乐，房间仍在后台同步'),
          trailing: FilledButton.tonal(
            onPressed: () async {
              try {
                await lt.session?.resumeRoomPlayback();
              } catch (_) {
                showToast('恢复失败，请稍后重试');
              }
            },
            child: const Text('回到房间'),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ListenTogetherProvider>();
    return Scaffold(
      appBar: ScrollAwareAppBar(title: '一起听'),
      body: Column(
        children: [
          // 广场 / 我的房间切换（与创建托盘房型同款二选一控件）
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
            child: Center(
              child: M3EToggleButtonGroup(
                actions: const [
                  M3EToggleButtonGroupAction(
                    label: Text('广场'),
                    icon: Icon(Icons.explore_outlined),
                  ),
                  M3EToggleButtonGroupAction(
                    label: Text('我的房间'),
                    icon: Icon(Icons.meeting_room_outlined),
                  ),
                ],
                selectedIndex: _scopeIndex,
                onSelectedIndexChanged: _switchScope,
              ),
            ),
          ),
          Expanded(
            child: Md3PullToRefresh(
              onRefresh: _scopeIndex == 0
                  ? () => provider.loadSquare(refresh: true)
                  : () async {
                      final userId = _selfUserId();
                      if (userId == null) return;
                      await provider.loadMyRooms(selfUserId: userId);
                    },
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _kSquareMaxWidth),
                  child: _buildBody(provider),
                ),
              ),
            ),
          ),
          // 底部固定按钮栏：按钮占独立空间而非悬浮在卡片上，
          // 列表滚动时不会被按钮盖住（此前 FAB 会截断卡片）
          _CreateRoomBar(onCreate: _createRoom, onJoin: _joinById),
        ],
      ),
    );
  }

  Widget _buildBody(ListenTogetherProvider provider) {
    if (_scopeIndex == 1) return _buildMyRoomsBody(provider);
    final rooms = provider.rooms;
    // 首屏加载态
    if (provider.loadingSquare && rooms.isEmpty) {
      return const Center(child: M3ELoadingIndicator());
    }
    // 加载失败态（可重试）
    final error = provider.squareError;
    if (rooms.isEmpty && error != null && error.contains('失败')) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 56, color: cs.outline),
            const SizedBox(height: 12),
            Text(error, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 16),
            M3EFilledButton(
              onPressed: () => provider.loadSquare(refresh: true),
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    // 脱离态横幅（广场/我的房间两个 Tab 的列表首位都展示）
    final detachBanner = _buildDetachBanner(provider);
    // 空态
    if (rooms.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return ListView(
        children: [
          ?detachBanner,
          const SizedBox(height: 120),
          Icon(Icons.groups_outlined, size: 64, color: cs.outline),
          const SizedBox(height: 12),
          Center(
            child: Text(
              error ?? '暂无房间',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: M3EFilledButton(
              onPressed: _createRoom,
              child: const Text('创建第一个房间'),
            ),
          ),
        ],
      );
    }
    // 本地过滤（对齐 EchoMusic 广场搜索口径：名称/房主/正在播放歌曲）
    final filteredRooms = _searchQuery.isEmpty
        ? rooms
        : rooms
            .where((r) =>
                r.name.contains(_searchQuery) ||
                r.ownerName.contains(_searchQuery) ||
                r.currentSongName.contains(_searchQuery))
            .toList();
    // 房间列表：MD3E 卡片列表（整组卡片共享外圆角，组内用内圆角 + 细缝）
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 接近底部时增量加载下一页（列表不显示底部加载条）
        if (provider.hasMore &&
            !provider.loadingSquare &&
            !provider.loadingMore &&
            notification.metrics.extentAfter < 400) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) provider.loadSquare(refresh: false);
          });
        }
        return false;
      },
      // 列表首位插入脱离横幅，下方房间卡片列表占满剩余高度
      child: Column(
        children: [
          // 广场搜索框（仅广场 Tab 展示）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索房间名 / 房主 / 正在播放',
                isDense: true,
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
            ),
          ),
          ?detachBanner,
          Expanded(
            child: filteredRooms.isEmpty
                // 搜索过滤后无结果：轻提示（保留搜索框便于修改关键词）
                ? Center(
                    child: Text(
                      '没有匹配的房间',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  )
                : M3ESegmentedList.builder(
                    itemCount: filteredRooms.length,
                    itemBuilder: (context, index) =>
                        _RoomTile(room: filteredRooms[index]),
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    padding: const EdgeInsets.all(14),
                    outerRadius: 20,
                    innerRadius: 6,
                    gap: 3,
                    haptic: M3EHapticFeedback.light,
                    onTap: (index) => _previewThenOpen(
                        filteredRooms[index].roomId, filteredRooms[index].name),
                  ),
          ),
        ],
      ),
    );
  }

  /// 「我的房间」视图：加载中 / 空态 / 我创建的房间列表（复用广场卡片）。
  Widget _buildMyRoomsBody(ListenTogetherProvider provider) {
    final rooms = provider.myRooms;
    final detachBanner = _buildDetachBanner(provider);
    if (provider.loadingMyRooms && rooms.isEmpty) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (rooms.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return ListView(
        children: [
          ?detachBanner,
          const SizedBox(height: 100),
          Icon(Icons.meeting_room_outlined, size: 64, color: cs.outline),
          const SizedBox(height: 12),
          Center(
            child: Text(
              provider.myRoomsError ?? '还没有可管理的众乐房',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              '近期创建且仍有效的众乐房会显示在这里',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: M3EFilledButton(
              onPressed: _createRoom,
              child: const Text('创建房间'),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        ?detachBanner,
        Expanded(
          child: M3ESegmentedList.builder(
            itemCount: rooms.length,
            itemBuilder: (context, index) => _RoomTile(room: rooms[index], mine: true),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            padding: const EdgeInsets.all(14),
            outerRadius: 20,
            innerRadius: 6,
            gap: 3,
            haptic: M3EHapticFeedback.light,
            onTap: (index) => _previewThenOpen(rooms[index].roomId, rooms[index].name),
          ),
        ),
      ],
    );
  }
}

/// 底部固定的操作按钮栏：与列表互不遮挡。
/// 左侧主操作「创建房间」，右侧次操作「房间号加入」（托盘弹出）。
class _CreateRoomBar extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  const _CreateRoomBar({required this.onCreate, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    // 背景交给 Scaffold：背景图模式下全局 theme 已把 scaffoldBackgroundColor
    // 置为透明，底部栏若自带 `cs.surface` 不透明打底会挡住自定义壁纸
    // （与其它页面底部栏口径不一致）。按钮自带容器色，无需再打底。
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Center(
          // 横屏/平板下与列表同一限宽，视觉对齐
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kSquareMaxWidth),
            child: Padding(
              // 底部留足高度，避免按钮贴边误触全面屏手势
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  // 左右等宽：创建房间与房间号加入同为一级操作
                  Expanded(
                    child: M3EFilledButton(
                      onPressed: onCreate,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.add),
                          SizedBox(width: 8),
                          Text('创建房间'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: M3EOutlinedButton(
                      onPressed: onJoin,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.dialpad, size: 18),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '房间号加入',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 房间卡片内容（卡片外壳由 [M3ESegmentedList] 提供，此处只放内容）。
class _RoomTile extends StatelessWidget {
  final MusicRoomBrief room;

  /// 「我的房间」视图下显示归属徽标。
  final bool mine;

  const _RoomTile({required this.room, this.mine = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 优先当前播放歌曲的专辑封面，缺失时回落房间背景图
    final coverUrl = room.thumbnailUrl;
    return Row(
      children: [
        // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
        SizedBox(
          width: 56,
          height: 56,
          child: RoomCoverImage(
            url: coverUrl,
            iconSize: 24,
            customRadius: BorderRadius.circular(12),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (mine) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '我的房间',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: cs.onPrimaryContainer,
                            ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              if (room.currentSongName.isNotEmpty)
                Text(
                  '正在播：${room.currentSongName}'
                  '${room.currentArtistName.isNotEmpty ? " - ${room.currentArtistName}" : ""}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.primary),
                )
              else if (room.notice.isNotEmpty)
                Text(
                  room.notice,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.person, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    // 上游广场不提供容量，未知（0）时只显示在线人数
                    room.capacity > 0
                        ? '${room.memberCount}/${room.capacity}'
                        : '${room.memberCount}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  if (room.ownerName.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        '房主 ${room.ownerName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
      ],
    );
  }
}
