import '../services/kugou_api/listen_together_models.dart';

/// 跟随目标解析结果。
class FollowTarget {
  /// 起播用的房间条目（命中歌单时为歌单条目，否则为按远端身份构造的占位条目）。
  final RoomSong song;

  /// true 表示 [song] 是服务端歌单中的条目；false 表示歌单里没有它。
  final bool fromPlaylist;

  const FollowTarget({required this.song, required this.fromPlaylist});
}

/// 在房间歌单中定位远端正在播放的曲目。
///
/// 未命中时**不把占位条目塞进歌单**：服务端歌单是权威列表，本地插入会在下一次
/// 权威加载时被整表覆盖丢弃（列表长度来回跳，EM 亦有同结论），且丢弃后当前歌
/// 再也匹配不到富化结果 → 名称/封面永久停在「未知歌曲」。占位条目由调用方
/// （`RoomSession._pendingRemoteSong`）单独持有。
FollowTarget resolveFollowTarget({
  required List<RoomSong> playlist,
  required PlayerSyncState remote,
}) {
  final idx = playlist.indexWhere((s) => s.matchesRemote(remote));
  if (idx >= 0) return FollowTarget(song: playlist[idx], fromPlaylist: true);
  return FollowTarget(
    song: RoomSong(
      hash: remote.hash,
      originalHash: remote.originalHash,
      mixSongId: remote.mixSongId,
      name: '',
      singer: '',
      durationSeconds: 0,
      coverUrl: '',
      orderUserId: '',
    ),
    fromPlaylist: false,
  );
}

/// 富化结果回写的切分。
///
/// 富化入参把占位条目排在首位（`[占位, ...歌单, ...附加组]`），回写时必须按
/// 同一偏移拆开，否则占位条目的富化结果会落进歌单第 0 项、整表错位一格。
///
/// [extraCount] 是尾部附加组的长度（房主端待处理点歌）：单独返回、由调用方按
/// hash 回填到点歌条目上——点歌条目不是歌单成员，混进 [playlist] 会在下一次
/// 权威列表覆盖时凭空多出几首（与占位条目同样的错位陷阱）。
/// 超出长度时钳制，不抛 `RangeError`。
({RoomSong? pending, List<RoomSong> playlist, List<RoomSong> extra})
    splitEnriched({
  required List<RoomSong> enriched,
  required bool hasPending,
  int extraCount = 0,
}) {
  if (enriched.isEmpty) {
    return (pending: null, playlist: const [], extra: const []);
  }
  final extraN = extraCount.clamp(0, enriched.length);
  final start = hasPending ? 1 : 0;
  final end = enriched.length - extraN;
  return (
    pending: hasPending ? enriched.first : null,
    playlist: start >= end ? const <RoomSong>[] : enriched.sublist(start, end),
    extra: extraN == 0
        ? const <RoomSong>[]
        : enriched.sublist(enriched.length - extraN),
  );
}
