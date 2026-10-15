import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../providers/listen_together_provider.dart';
import '../../../services/kugou_api/listen_together_api.dart';
import '../../../services/kugou_api/listen_together_models.dart';
import 'room_cover_image.dart';

/// 从 payload 任意深度读取 `room_state` 的**显式值**；缺失返回 null。
///
/// `readNestedInt` 无法区分「字段缺失」与「值为 0」（都返回 0）：
/// 若上游 state 响应不带该 key，按 `!= 1` 判定会把所有房间误判成已解散，
/// 因此这里单独写小递归保留「缺失」语义（缺失时交由 detail.closed 兜底）。
int? _readRoomStateValue(dynamic payload, [int depth = 0]) {
  if (depth > 6 || payload == null) return null;
  if (payload is Map) {
    final v = payload['room_state'];
    if (v is num) return v.toInt();
    if (v is String && v.trim().isNotEmpty) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
    for (final child in payload.values) {
      final n = _readRoomStateValue(child, depth + 1);
      if (n != null) return n;
    }
  } else if (payload is List) {
    for (final item in payload) {
      final n = _readRoomStateValue(item, depth + 1);
      if (n != null) return n;
    }
  }
  return null;
}

/// 并行请求的守卫：把异常转成 (值, 错误) 记录，单请求失败不拖垮其它请求。
Future<(T?, Object?)> _guard<T>(Future<T> future) async {
  try {
    return (await future, null);
  } catch (e) {
    return (null, e);
  }
}

/// 房间预览托盘（对齐 EchoMusic inspectRoom）：
/// 点房间卡片先弹预览做加入前预检——room_state 校验存活、展示详情与成员，
/// 已解散的房间就地拦截并记入解散名单，「加入一起听」确认后才走入房流程。
class RoomPreviewSheet extends StatefulWidget {
  const RoomPreviewSheet({super.key, required this.brief});

  /// 列表卡片传入的房间摘要（详情返回前作为兜底展示数据）。
  final MusicRoomBrief brief;

  @override
  State<RoomPreviewSheet> createState() => _RoomPreviewSheetState();
}

enum _PreviewPhase { loading, ready, dissolved, error }

class _RoomPreviewSheetState extends State<RoomPreviewSheet> {
  final ListenTogetherApi _api = ListenTogetherApi();
  _PreviewPhase _phase = _PreviewPhase.loading;
  MusicRoomBrief? _detail;
  List<RoomMember> _members = const [];
  String? _error;

  /// 房主头像：detail 的 data.user_pic 是唯一来源（成员接口不含房主），
  /// 提取口径与 RoomSession._loadDetail 一致，缺失时占位条目回退图标。
  String _ownerAvatar = '';

  String get _roomId => widget.brief.roomId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _PreviewPhase.loading;
      _error = null;
    });
    // room_state + 详情 + 成员三路并行（members 只返回听众，pageSize 取 8）
    final stateFuture = _guard(_api.roomState(_roomId));
    final detailFuture = _guard(_api.roomDetail(_roomId));
    final membersFuture = _guard(_api.members(_roomId, pageSize: 8));
    final (statePayload, stateError) = await stateFuture;
    final (detailPayload, detailError) = await detailFuture;
    final (membersPayload, membersError) = await membersFuture;
    if (!mounted) return;

    // —— 解散判定（三路）：state 接口报解散类错误 / room_state != 1 / 详情 closed ——
    if (stateError != null && isDissolvedRoomError(stateError)) {
      _markDissolved();
      return;
    }
    final state = statePayload == null ? null : _readRoomStateValue(statePayload);
    if (state != null && state != 1) {
      _markDissolved();
      return;
    }
    // detail 返回单个房间对象（data 直为对象），解析口径与 _loadDetail 一致
    MusicRoomBrief? detail;
    if (detailPayload != null) {
      final list = extractList(detailPayload);
      final rec = list.isNotEmpty
          ? list.first
          : (asRecord(unwrapListenPayload(detailPayload)) ?? const <String, dynamic>{});
      if (rec.isNotEmpty) {
        detail = MusicRoomBrief.fromJson(rec);
        // 房主头像：detail 顶层 user_pic（众乐房把房主身份直给在 data 顶层）
        _ownerAvatar = readString(rec, const [
          'user_pic',
          'userpic',
          'owner_pic',
          'avatar',
          'headimg',
          'img',
        ]);
      }
    }
    if (detail != null && detail.closed) {
      _markDissolved();
      return;
    }
    if (stateError != null || detailError != null || membersError != null) {
      // 解散类错误已在上面拦截，走到这里都是网络/服务异常
      setState(() {
        _phase = _PreviewPhase.error;
        _error = stateError is ListenTogetherApiError
            ? listenTogetherErrorText(stateError)
            : '预览加载失败，请稍后重试';
      });
      return;
    }

    var members = (membersPayload == null
            ? const <Map<String, dynamic>>[]
            : extractList(membersPayload))
        .map(RoomMember.fromJson)
        .where((m) => m.userId.isNotEmpty)
        .toList();
    // 成员接口只含听众不含房主：有房主名时首位补一个占位条目（轻量场景简化，
    // 不做 ensureSelfInMembers 的完整注入），行总数不超过 8
    final ownerName = (detail ?? widget.brief).ownerName;
    final listenerLimit = ownerName.isNotEmpty ? 7 : 8;
    setState(() {
      _members = [
        if (ownerName.isNotEmpty)
          RoomMember(
              userId: '', nickname: ownerName, avatar: _ownerAvatar, studyStatus: 0),
        ...members.take(listenerLimit),
      ];
      _phase = _PreviewPhase.ready;
    });
  }

  /// 记入解散名单（rooms getter 据此过滤广场列表）并切换到解散空态。
  void _markDissolved() {
    if (!mounted) return;
    context.read<ListenTogetherProvider>().rememberDissolved(_roomId);
    setState(() => _phase = _PreviewPhase.dissolved);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '房间预览',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            switch (_phase) {
              _PreviewPhase.loading => const SizedBox(
                  height: 180,
                  child: Center(child: M3ELoadingIndicator()),
                ),
              _PreviewPhase.dissolved => _buildDissolved(cs),
              _PreviewPhase.error => _buildError(cs),
              _PreviewPhase.ready => _buildReady(cs),
            },
            ?_buildBottomAction(),
          ],
        ),
      ),
    );
  }

  Widget _buildDissolved(ColorScheme cs) {
    return SizedBox(
      height: 180,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.meeting_room_outlined, size: 48, color: cs.outline),
          const SizedBox(height: 12),
          Text('房间已解散', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '该房间已不再可用',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ColorScheme cs) {
    return SizedBox(
      height: 180,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 48, color: cs.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error ?? '预览加载失败，请稍后重试',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReady(ColorScheme cs) {
    // 详情返回前用列表摘要兜底；返回后以详情（实时人数/歌名）为准
    final brief = _detail ?? widget.brief;
    final coverUrl = brief.thumbnailUrl;
    final hasSong = brief.currentSongName.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
              SizedBox(
                width: 84,
                height: 84,
                child: RoomCoverImage(
                  url: coverUrl,
                  iconSize: 24,
                  customRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      brief.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (brief.ownerName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.person, size: 14, color: cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '房主 ${brief.ownerName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.groups_outlined, size: 14, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          // 上游无可靠容量字段（0=未知）时只显示在线人数，不编造 x/y
                          brief.capacity > 0
                              ? '${brief.memberCount}/${brief.capacity} 人在听'
                              : '${brief.memberCount} 人在听',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.music_note, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasSong
                        ? '正在播：${brief.currentSongName}'
                        : '房间暂无播放',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: hasSong ? cs.primary : cs.onSurfaceVariant,
                        ),
                  ),
                ),
                if (brief.currentArtistName.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      brief.currentArtistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_members.isNotEmpty)
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  for (var i = 0; i < _members.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    CircleAvatar(
                      radius: 16,
                      backgroundImage: _members[i].avatar.isNotEmpty
                          ? NetworkImage(_members[i].avatar)
                          : null,
                      child: _members[i].avatar.isEmpty
                          ? const Icon(Icons.person, size: 18)
                          : null,
                    ),
                  ],
                  if (_members.length >= 8) ...[
                    const SizedBox(width: 6),
                    Text('…', style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '暂无其他听众',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget? _buildBottomAction() {
    switch (_phase) {
      case _PreviewPhase.loading:
        return null;
      case _PreviewPhase.error:
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: M3EFilledButton(onPressed: _load, child: const Text('重新加载')),
        );
      case _PreviewPhase.dissolved:
        // 解散态禁用加入（onPressed 为 null 即禁用）
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: M3EFilledButton(onPressed: null, child: const Text('加入一起听')),
        );
      case _PreviewPhase.ready:
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: M3EFilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('加入一起听'),
          ),
        );
    }
  }
}
