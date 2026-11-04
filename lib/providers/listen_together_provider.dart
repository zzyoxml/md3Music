import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/utils/app_toast.dart';
import '../core/services/media_notification_service.dart';
import '../core/services/cover_prefetch_queue.dart';
import '../data/models/song.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import '../services/kugou_api/listen_together_api.dart';
import '../services/kugou_api/listen_together_models.dart';
import 'kugou_provider.dart';
import 'player_provider.dart';
import 'room_follow_target.dart';
import 'room_song_patch.dart';

// ===========================================================================
// 轮询节奏与纠偏参数
//
// 一起听的播放同步依赖 HTTP 轮询（服务端无推送）。三档节奏分离：
//   - 心跳 55s：维持房间在线态，避免过于频繁被风控
//   - 快轮询 5s：聊天、成员、播放状态（感知时延的主要来源）
//   - 慢轮询 15s：房间详情、点歌列表（低频变化，降低请求量）
// 每个循环都有 in-flight 标志，避免慢网络下请求堆叠。
// ===========================================================================
const Duration kHeartbeatInterval = Duration(seconds: 55);
const Duration kFastPollInterval = Duration(seconds: 5);
const Duration kSlowPollInterval = Duration(seconds: 15);

/// 播放态进度纠偏容差：超出才 seek，避免频繁拖动导致解码器反复重启。
const int kPlayingSyncDriftToleranceMs = 8000;

/// 暂停态纠偏容差（暂停时不做时间推进，允许更小的误差校准）。
const int kPausedSyncDriftToleranceMs = 1500;

/// force 同步（听众恢复播放、显式复同步）时的收紧容差。
///
/// 语义与 EchoMusic 一致：force 表示「用更严格的容差校准」而**不是**无条件 seek——
/// 无条件 seek 会触发播放器 seek 事件，听众恢复逻辑再次 force seek，形成死循环。
const int kForceSyncDriftToleranceMs = 750;

/// seek 领先补偿上限（毫秒）：抵消「seek 生效期间播放器继续走」的延迟。
const int kSeekLatencyLeadCapMs = 10000;

/// seek 生效延迟 EWMA 的最小采样阈值：低于此值视为瞬时完成，不污染估计。
const int kSeekLatencySampleMinMs = 250;

/// 房主本地控制后的宽限期：期间跳过普通轮询，防止未完成的旧请求覆盖新操作。
const Duration kOwnerControlGrace = Duration(seconds: 3);

/// 房间授权播放地址失败后的退避时长，避免跟随 5s 轮询反复打接口。
const Duration kPlaybackRetryBackoff = Duration(seconds: 30);

/// 歌单游标被上游拒绝（30009）后的退避时长。
const Duration kPlaylistCursorBackoff = Duration(seconds: 60);

/// 歌单加载失败（网络/签名等瞬时故障）后的重试退避：快轮询的安全网按此
/// 节奏重试，直到拿到真实歌单为止。
const Duration kPlaylistLoadRetryBackoff = Duration(seconds: 10);

const int kPlaylistMaxPages = 20;
const int kPlaylistPageSize = 50;
const int kMaxMessages = 200;

/// 同一条远端快照的 seek 幂等窗口。
const int kSeekIdempotentWindowMs = 2000;

/// 「施加远端动作」互斥锁的卡死阈值。
///
/// 正常施加是一两秒的事（含在线源解析与缓冲）；超过这个量级说明起播链路挂住了，
/// 此时必须强制放行，否则整场会话的远端同步永久失效（见 [RoomSession] 的
/// `_applyingRemoteSince`）。
const Duration kApplyRemoteStaleTimeout = Duration(seconds: 20);

// ===========================================================================
// 同步决策（纯函数，单测覆盖）
// ===========================================================================

enum SyncAction { none, switchSong, seek, resume, pause }

class SyncDecision {
  final SyncAction action;
  final String? targetHash;
  final int? targetPositionMs;

  const SyncDecision(this.action, {this.targetHash, this.targetPositionMs});
}

/// seek 幂等键：同一房间 + 同一歌曲 + 同一快照时间 + 同一目标位置视为同一次纠偏。
String buildSeekKey({
  required String roomId,
  required String hash,
  required int updatedAtMs,
  required int positionMs,
}) =>
    '$roomId:${hash.toLowerCase()}:$updatedAtMs:$positionMs';

/// 是否应当执行一次远端纠偏 seek。
///
/// 三个否决条件：
///  1. 目标位置无效（<= 0）；
///  2. 播放器尚未就绪——`just_audio.seek()` 在 `ProcessingState.loading` 时
///     直接 return 静默丢弃（铁律 18），执行等于白做；
///  3. 同一快照 + 同一目标已在幂等窗口内执行过（防 seek 事件回环）。
///
/// **未就绪时必须连幂等键一起放弃**：若先登记键再 seek，那次被丢弃的 seek 会在
/// 整个窗口内被当成「已执行」，纠偏静默丢失（表现为「进度有时不追」）。
bool shouldApplyRemoteSeek({
  required int targetMs,
  required bool playbackReady,
  required String seekKey,
  required String? lastSeekKey,
  required int nowMs,
  required int lastSeekAtMs,
  int idempotentWindowMs = kSeekIdempotentWindowMs,
}) {
  if (targetMs <= 0) return false;
  if (!playbackReady) return false;
  if (seekKey == lastSeekKey && nowMs - lastSeekAtMs < idempotentWindowMs) {
    return false;
  }
  return true;
}

/// 曲目在房间里是否具备可上报身份（本地文件没有 hash → 无法点歌）。
///
/// 与 [RoomSong.fromSong] 的空 hash 语义配套：调用方据此决定是否需要弹
/// 「脱离房间播放 / 申请点歌」确认窗——本地文件点不了歌，弹窗只是白打扰。
bool canOrderSongIntoRoom(Song song) => RoomSong.fromSong(song).hash.isNotEmpty;

/// 播放器曲目是否就是房间自身正在装载的接管曲目。
///
/// 跟随起播（`RoomSession._playRoomSong`）会带房间授权地址走
/// `PlayerProvider.playSong`，与「用户点击其他歌曲」共用入口。按**身份**而非
/// 时间窗判定：冷 CDN 源上装载 Future 11s+ 才回包，时间窗会误伤整个装载窗口
/// （见 `RoomSession.detachIfPlayingOutside` 的既有注释）。
bool isTakeoverTargetSong({required RoomSong? takeover, required Song song}) =>
    takeover != null && takeover.sameAs(RoomSong.fromSong(song));

/// 听众点击其他曲目时是否需要弹「脱离房间播放 / 申请点歌」确认窗。
///
/// 四个否决条件（任一命中即不弹窗，按既有路径直接处理）：
///  1. 不在房间（含会话已关闭）——没有可脱离的对象；
///  2. 自己是房主——房主有独立的播放守卫（`OwnerPlayRejection`）；
///  3. 目标曲目正是房间正在装载的接管曲目——那是跟随起播，不是用户点击；
///  4. 曲目在房间里没有可上报身份（本地文件）——点不了歌，不多打扰一次。
///
/// 注意：**刻意不把「是否已脱离」纳入判定**。已脱离的听众仍可能需要
/// 「申请点歌」，一旦按脱离态否决，这个入口就永久消失了。
bool shouldPromptGuestPlay({
  required bool inRoom,
  required bool isOwner,
  required bool isTakeoverTarget,
  required bool canOrder,
}) =>
    inRoom && !isOwner && !isTakeoverTarget && canOrder;

/// seek 目标的领先补偿（毫秒）：播放中按 seek 生效延迟的 EWMA 估计把目标提前，
/// 抵消「seek 生效需要时间、期间播放器继续走」造成的系统性落后。上限
/// [kSeekLatencyLeadCapMs]。暂停中无时间推进，不补偿。
int seekLatencyLeadMs(int ewmaMs) => ewmaMs.clamp(0, kSeekLatencyLeadCapMs);

/// EWMA 平滑更新 seek 生效延迟估计（权重 0.7/0.3）。
/// 仅采样 ≥ [kSeekLatencySampleMinMs] 的样本：瞬时完成的 seek 不代表真实链路延迟；
/// 首个有效样本直接采信（0 表示尚无估计）。
int updateSeekLatencyEwma(int currentMs, int elapsedMs) {
  if (elapsedMs < kSeekLatencySampleMinMs) return currentMs;
  if (currentMs <= 0) return elapsedMs;
  return (currentMs * 0.7 + elapsedMs * 0.3).round();
}

/// 起播对齐兜底：起播返回后是否需要立刻补一次 seek。
///
/// `setPlaylist(initialPosition:)` 是「交给平台在 prepare 阶段定位」，**不保证落地**：
/// 真机实测同一首歌请求 287s 时平台从 0 起播（`player.position` 停在 22s），
/// 而请求 3s 时正常。而此时源已就绪，补一次普通 `seek()` 比依赖 initialPosition 可靠。
///
/// [tolerance] 以内的偏差视为已对齐，不做无谓 seek（seek 会重启解码器）。
bool needsStartAlignmentFixup({
  required Duration? requested,
  required Duration actual,
  required bool playbackReady,
  Duration tolerance = const Duration(seconds: 5),
}) {
  if (requested == null || requested <= Duration.zero) return false;
  if (!playbackReady) return false;
  final diff = actual - requested;
  return diff.abs() > tolerance;
}

/// 收集 payload 任意深度 key 为 [key] 的全部字符串值（含字符串数组）。
///
/// 房间授权地址（`music_reqcmd` → `data.url`）可能返回**多个**候选（不同格式/音质）。
/// 之前只取第一个：若它是 `.kgs/.kgg` 这类本机不可解码的私有格式，就把整条授权
/// 路径放弃、回退常规解析链——而常规解析链的 CDN 对大偏移 seek 极慢（实测起播卡 24s）。
/// 全部收集后再挑第一个可解码的，能把能用的授权地址救回来。
List<String> collectNestedStringValues(Object? payload, String key, [int depth = 0]) {
  if (depth > 6 || payload == null) return const [];
  final out = <String>[];
  if (payload is Map) {
    final v = payload[key];
    if (v is String && v.trim().isNotEmpty) out.add(v.trim());
    if (v is List) {
      for (final item in v) {
        if (item is String && item.trim().isNotEmpty) out.add(item.trim());
      }
    }
    for (final child in payload.values) {
      out.addAll(collectNestedStringValues(child, key, depth + 1));
    }
  } else if (payload is List) {
    for (final item in payload) {
      out.addAll(collectNestedStringValues(item, key, depth + 1));
    }
  }
  return out;
}

/// 从候选 URL 里挑第一个本机可解码的；全不可用返回空串。
String pickPlayableRoomAudioUrl(List<String> urls) {
  for (final url in urls) {
    if (url.startsWith('http') && !isKugouPrivateAudioUrl(url)) return url;
  }
  return '';
}

/// 施加远端动作期间，远端快照是否已经前进（换歌或收到更新的快照）。
///
/// 一次 seek / 起播的往返可能跨越服务端换歌：动作结束后若不复查，跟随端会停在
/// 旧歌上直到下一轮快轮询（最长 5s）。注意判据必须是「相对**本次已施加的快照**」，
/// 而不是「相对上一次轮询」——否则会自激。
bool shouldReapplyAfterApply({
  required PlayerSyncState applied,
  required PlayerSyncState? latest,
}) {
  if (latest == null || latest.hash.isEmpty) return false;
  if (latest.updatedAtMs > applied.updatedAtMs) return true;
  return latest.hash.toLowerCase() != applied.hash.toLowerCase();
}

/// 「房间在播、本机也停在同一首、但本地音源已不可用」时是否需要重装载房间曲目。
///
/// 对齐 EchoMusic 的 `playbackUnavailable → trackChanged` 重装载：解析/解码失败的
/// 曲目不会被 resume 唤醒（`play()` 对空源是 no-op），只靠播放器自身的「网络变化
/// / 回前台」重试会让听众长时间停在旧歌（「房主切歌听众有概率不跟随」的形态之一）。
/// [retryAfterMs] 是上次重装载的退避截止（墙钟毫秒），未到点不重复发起。
bool shouldReloadUnavailableRoomSource({
  required bool remotePlaying,
  required bool sameSong,
  required String? resolveError,
  required int nowMs,
  required int retryAfterMs,
}) {
  if (!remotePlaying || !sameSong) return false;
  if (resolveError == null || resolveError.isEmpty) return false;
  return nowMs >= retryAfterMs;
}

/// 根据本地与远端播放状态决定成员端动作。
///
/// 优先级：换歌 > 听众本地暂停豁免 > 播放态对齐 > 进度纠偏。
/// [guestLocallyPaused] 为真时不做任何自动恢复：听众的暂停只影响本机。
/// [force] 表示「用更严格的容差校准」（听众恢复播放、显式复同步路径传入），
/// 播放中与暂停中的纠偏容差均收紧为 [kForceSyncDriftToleranceMs]；
/// 它**不是**无条件 seek——常规容差内的偏差在 force 下仍可能触发纠偏，
/// 但绝不是绕过状态判定直接 seek，否则会触发响应式死循环。
/// 同歌判定：hash 忽略大小写相等，或 mixSongId 相同——上游 sync 返回的
/// cur_song 身份与本地歌曲 id 存在大小写/形式错位，严格比对会把正在播的
/// 同一首歌误判为换歌（房主端会被无元数据的歌单条目覆盖当前歌）。
SyncDecision decideSync({
  required String? localHash,
  String? localMixSongId,
  required bool localPlaying,
  required int localPositionMs,
  required PlayerSyncState remote,
  required int nowMs,
  bool guestLocallyPaused = false,
  bool force = false,
}) {
  if (remote.hash.isEmpty) return const SyncDecision(SyncAction.none);
  // 换歌优先级最高（本地无歌时同样走换歌）
  final sameHash = localHash != null &&
      localHash.isNotEmpty &&
      localHash.toLowerCase() == remote.hash.toLowerCase();
  final sameMixSong = localMixSongId != null &&
      localMixSongId.isNotEmpty &&
      remote.mixSongId.isNotEmpty &&
      localMixSongId == remote.mixSongId;
  if (!sameHash && !sameMixSong) {
    return SyncDecision(SyncAction.switchSong, targetHash: remote.hash);
  }
  // 暂停豁免只挡「自动起播」（远端在播、本机确未播放），不挡漂移校准：
  // 本机实际在播时豁免标记可能被迟到的 pause 通告重新置上（实测每次恢复
  // 播放后 1ms 内都有一条），一刀切返回 none 会让听众永远停在自己的进度、
  // 没有任何纠偏。暂停态（localPlaying=false）仍然豁免。
  if (guestLocallyPaused && remote.isPlaying && !localPlaying) {
    return const SyncDecision(SyncAction.none);
  }
  if (remote.isPlaying && !localPlaying) return const SyncDecision(SyncAction.resume);
  if (!remote.isPlaying && localPlaying) return const SyncDecision(SyncAction.pause);
  // 双方都在播放：目标为「投影后的远端位置」，force 时收紧容差
  if (remote.isPlaying && localPlaying) {
    final projected = projectRemotePosition(remote, nowMs);
    final tolerance = force ? kForceSyncDriftToleranceMs : kPlayingSyncDriftToleranceMs;
    if ((projected - localPositionMs).abs() > tolerance) {
      return SyncDecision(SyncAction.seek, targetPositionMs: projected);
    }
  }
  // 双方都暂停：静止比对（无时间推进、无投影），偏差大就校准一次
  if (!remote.isPlaying && !localPlaying) {
    final tolerance = force ? kForceSyncDriftToleranceMs : kPausedSyncDriftToleranceMs;
    if ((remote.progressMs - localPositionMs).abs() > tolerance) {
      return SyncDecision(SyncAction.seek, targetPositionMs: remote.progressMs);
    }
  }
  return const SyncDecision(SyncAction.none);
}

/// 房主是否应当采纳远端快照的「播放态」。
///
/// 房主是播放权威：他自己的暂停/播放已经上报给服务端，随后每条 5s 快照都会
/// 把同一个状态回传。若房主像听众一样对这些回传做 resume/pause 纠偏，就会
/// 出现「暂停后又自己播起来」——具体触发链：
///   1. 房主点暂停 → 本地 pause + 上报 action=3 pause=2；
///   2. [_finishOwnerControl] 立刻做一次同步，读回的仍是上报**之前**的快照
///      （上游写入有传播延迟），里面 pause=1 → 判定 resume → 本地被拉回播放；
///   3. 之后每次轮询读到的才是 pause=2，但第 2 步已经把状态弄脏了。
///
/// 因此房主只跟随「换歌」与「进度」两类远端信息，播放态一律以本地为准。
/// 例外：房主本地无歌（跨设备恢复会话）时必须按远端起播，否则房间无人播放。
///
/// 返回 true 表示允许采纳远端的播放态（resume / pause）。
bool shouldOwnerFollowRemotePlaying({required bool localHasSong}) => !localHasSong;

/// 跟随装载完成后的播放态决策（纯函数）。
///
/// 修复「切歌后不能续播」：旧实现 `startPaused || !(latest?.isPlaying ?? false)`
/// 有两坑——latest 为缓存快照，切歌瞬间房主快照可能短暂 false（switch_song
/// 传播延迟）误暂停新歌；latest 为 null 时 `?? false` 无条件暂停。且只暂停
/// 从不恢复，装载期间丢掉的 play 没有即刻纠正，只能等 5s 轮询。
enum FollowLoadAction { play, pause, none }

FollowLoadAction resolveFollowLoadPlayback({
  required bool startPaused,
  required bool? latestIsPlaying,
  required bool localPlaying,
}) {
  // 听众自己暂停的（装载前已暂停）：装载完保持暂停，豁免语义交给轮询
  if (startPaused) return FollowLoadAction.pause;
  // 有匹配目标歌的最新快照：以它为准，即刻纠正播放态
  if (latestIsPlaying != null) {
    if (latestIsPlaying && !localPlaying) return FollowLoadAction.play;
    if (!latestIsPlaying && localPlaying) return FollowLoadAction.pause;
    return FollowLoadAction.none;
  }
  // 无匹配快照：不动作。playSong 已下发 play，盲暂停会杀掉新歌
  return FollowLoadAction.none;
}

/// 房主切歌被拦截的原因（[RoomSession.ownerPlaySong] 返回值）。
enum OwnerPlayRejection {
  /// 命中房间歌单，已由 [RoomSession.ownerSwitchSong] 完成切歌与上报。
  /// 调用方必须停止自己的播放入口，否则会把同一首再播一遍。
  handledByRoom,

  /// 房间会话已结束，调用方按普通播放处理。
  noRoom,

  /// 房间歌单里没有这首在线曲目——本地音乐、或不在房间歌单中的歌。
  notInRoom,
}

/// 从播放器队列挑出可上报给众乐房的上传曲目。
///
/// 房间歌单只认在线歌曲身份（hash / mixsongid），本地文件没有上游 hash，
/// 传过去会变成成员端无法解析的曲目。这里统一过滤，并保留队列顺序与去重。
List<RoomSong> roomAudiosFromPlaylist(Iterable<Song> playlist, {int limit = 30}) {
  final result = <RoomSong>[];
  final seen = <String>{};
  for (final song in playlist) {
    if (result.length >= limit) break;
    final roomSong = RoomSong.fromSong(song);
    if (roomSong.hash.isEmpty) continue;
    final key = roomSong.hash.toLowerCase();
    if (!seen.add(key)) continue;
    result.add(roomSong);
  }
  return result;
}

/// 房间初始歌单的上报体（上游单批上限 50，调用方按需截断）。
List<Map<String, dynamic>> roomAudioPayload(List<RoomSong> songs) => songs
    .map((s) => <String, dynamic>{'hash': s.hash, 'mixsongid': s.mixSongId})
    .toList();

/// 会话阶段。
enum ListenTogetherPhase { idle, joining, creating, joined, leaving, error }

/// 用播放器当前状态构造房间进度信息。
///
/// 建房初始化与房主加歌时随请求上报，让服务端队列的当前曲目/进度与本地一致；
/// 否则服务端会认为房间停在歌单第一首，房主随后会被远端纠偏换歌。
/// `pause` 与读取口径同源：1 = 正在播放，2 = 已暂停；`progress` 单位为秒。
Map<String, dynamic>? buildRoomProgressInfo(PlayerProvider player) {
  final song = player.currentSong;
  if (song == null || song.id.isEmpty) return null;
  return {
    'hash': song.id,
    'album_audio_id': song.albumAudioId ?? '',
    // 房主上报给服务端的进度必须真实（成员拿它做跟随目标）：
    // _position 会被起播对齐乐观写入成目标值，还没落地时上报出去会带偏全员。
    'progress': player.platformPosition.inSeconds,
    'pause': player.isPlaying ? 1 : 2,
    // 房主加歌/建房初始化随请求上报真实播放模式，服务端队列口径与本地一致
    'play_mode': '${player.roomPlayModeValue}',
  };
}

/// 剔除不属于 [roomId] 的聊天消息。
///
/// 上游消息带房间标签 `rm_<biz>:<房间号>`；标签缺失时无法判定归属，予以保留
/// （本地合成的进出房消息就没有标签）。
List<ChatMessage> scopeMessagesToRoom(List<ChatMessage> messages, String roomId) {
  if (roomId.isEmpty) return messages;
  return messages.where((m) {
    final tagRoom = m.tagRoomId;
    return tagRoom.isEmpty || tagRoom == roomId;
  }).toList();
}

/// 确保成员列表包含自己与房主。
///
/// `get_musicroom_member` 返回的是听众列表（上游注释：普通进入房间的听众才会
/// 出现在其中），房主不在其中。缺失时按需补房主（置顶）与本地账号，避免
/// 成员面板「互相看不到」（听众看不到房主、房主看不到自己）。
List<RoomMember> ensureSelfInMembers(
  List<RoomMember> members,
  String selfUserId, {
  String nickname = '',
  String avatar = '',
  String ownerUserId = '',
  String ownerName = '',
  String ownerAvatar = '',
}) {
  var next = members;
  // 听众端看不到房主：缺失时置顶注入（自己也是房主时无需注入）
  if (ownerUserId.isNotEmpty &&
      ownerUserId != selfUserId &&
      !next.any((m) => m.userId == ownerUserId)) {
    next = [
      RoomMember(
        userId: ownerUserId,
        nickname: ownerName.isEmpty ? '房主' : ownerName,
        // 房主头像取自 room/detail 的 data.user_pic（听众接口不含房主，
        // 不在这里注入就永远拿不到）。缺值时留空由 UI 回退占位图。
        avatar: ownerAvatar,
        studyStatus: 0,
      ),
      ...next,
    ];
  }
  if (selfUserId.isEmpty) return next;
  if (next.any((m) => m.userId == selfUserId)) return next;
  return [
    RoomMember(
      userId: selfUserId,
      nickname: nickname.isEmpty ? '我' : nickname,
      avatar: avatar,
      studyStatus: 0,
    ),
    ...next,
  ];
}

/// 元数据富化的尝试记账。
///
/// 语义是「还允许尝试几次」，而**不是**「是否尝试过」。这个区别是封面
/// 间歇性加载失败的关键：
///
/// `/audio` 完全不返回封面字段（实测 0 个 img/pic/cover 键），封面 100%
/// 依赖 `/search` 命中同 hash 的候选。搜索会因网络抖动抛异常，命中的候选
/// 也可能恰好没图。若把「发起过请求」当作「永远不必再试」的凭据，那首歌的
/// 封面就再也补不上——表现为「有概率加载不出封面」。
///
/// 因此：请求前 [bump] 消耗额度，失败或未拿到封面时 [refund] 退还，
/// 真正补齐后 [settle] 销账；额度耗尽（[isExhausted]）才放弃，
/// 避免上游持续无封面时形成请求风暴。
class MetadataAttemptTracker {
  /// 同一首歌最多尝试几次补齐元数据。
  static const int maxAttempts = 3;

  final Map<String, int> _counts = {};

  /// 是否已达尝试上限（达上限则不应再作为富化目标）。
  bool isExhausted(String hash) =>
      (_counts[hash.toLowerCase()] ?? 0) >= maxAttempts;

  /// 是否持有该 hash 的未结清额度（即「本轮已被选为目标」）。
  bool isTracked(String hash) => _counts.containsKey(hash.toLowerCase());

  /// 消耗一次尝试额度（发起请求前调用）。
  void bump(String hash) {
    final key = hash.toLowerCase();
    _counts[key] = (_counts[key] ?? 0) + 1;
  }

  /// 退还一次尝试额度（请求失败 / 未拿到封面时调用，允许重试）。
  void refund(String hash) {
    final key = hash.toLowerCase();
    final n = _counts[key] ?? 0;
    if (n <= 1) {
      _counts.remove(key);
    } else {
      _counts[key] = n - 1;
    }
  }

  /// 销账（元数据已补齐，无需再试）。
  void settle(String hash) => _counts.remove(hash.toLowerCase());

  /// 手动刷新时清空记账：会话早先耗尽额度的 hash 重新允许尝试
  /// （对齐 EchoMusic refreshRoomSongs 里 metadataLookupAttempted.clear()）。
  void reset() => _counts.clear();

  /// 当前记账条目数（测试与诊断用）。
  int get trackedCount => _counts.length;
}

/// 房主头像就地回填：成员列表可能早于房间详情返回。
///
/// 那种时序下房主条目已按 `avatar: ''` 注入并进了 [_memberSnapshot]，
/// 详情返回后 [ensureSelfInMembers] 因「房主已存在」直接返回原列表，
/// 头像是空的事实被 `length` 比较掩盖 → 永久留空。这里按 userId 定位
/// 房主条目并在头像为空时替换，返回新列表（无变化时返回原实例以便调用方
/// 用 identical 判断）。
List<RoomMember> backfillOwnerAvatar(
  List<RoomMember> members, {
  required String ownerUserId,
  required String ownerAvatar,
}) {
  if (ownerUserId.isEmpty || ownerAvatar.isEmpty) return members;
  final idx = members.indexWhere((m) => m.userId == ownerUserId);
  if (idx < 0 || members[idx].avatar == ownerAvatar) return members;
  final next = List<RoomMember>.from(members);
  final old = next[idx];
  next[idx] = RoomMember(
    userId: old.userId,
    nickname: old.nickname,
    avatar: ownerAvatar,
    studyStatus: old.studyStatus,
  );
  return next;
}

// ===========================================================================
// 入口级 Provider：广场 + 当前房间会话
// ===========================================================================

class ListenTogetherProvider extends ChangeNotifier {
  ListenTogetherProvider();

  final ListenTogetherApi _api = ListenTogetherApi();

  // ----- 广场状态 -----
  List<MusicRoomBrief> _rooms = [];
  bool _loadingSquare = false;
  bool _loadingMore = false;
  String? _squareError;
  int _page = 1;
  bool _hasMore = true;
  final Set<String> _dissolvedRoomIds = {};

  /// 解散记忆的持久化键。
  static const String _kDissolvedKeys = 'listen_together_dissolved_room_ids';

  /// 解散记忆条数上限（对齐 EchoMusic dissolvedRoomKeys），FIFO 淘汰。
  static const int _kDissolvedLimit = 200;

  /// 广场房间列表（已剔除本会话内确认解散的房间）。
  List<MusicRoomBrief> get rooms =>
      _rooms.where((r) => !_dissolvedRoomIds.contains(r.roomId)).toList();
  bool get loadingSquare => _loadingSquare;

  /// 是否正在「加载更多」。与 [loadingSquare] 区分：下拉刷新不显示底部加载条。
  bool get loadingMore => _loadingMore;
  String? get squareError => _squareError;
  bool get hasMore => _hasMore;

  /// 某房间是否已被标记解散（用于加入失败的精准提示）。
  bool isKnownDissolved(String roomId) => _dissolvedRoomIds.contains(roomId);

  /// 从磁盘恢复解散记忆（首个 UI 入口进广场时并发触发一次）。
  ///
  /// 恢复是异步的，首屏可能已按空集合渲染；末尾 notifyListeners 让
  /// 实时过滤的 [rooms] 重新计算，自动剔除恢复出的已解散房间。
  Future<void> restoreDissolvedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    _dissolvedRoomIds
      ..clear()
      ..addAll(prefs.getStringList(_kDissolvedKeys) ?? const []);
    notifyListeners();
  }

  /// 记住已解散的房间：置内存 + 上限 [_kDissolvedLimit] FIFO 淘汰 + 异步写盘。
  void rememberDissolved(String roomId) {
    _dissolvedRoomIds.add(roomId);
    final keys = _dissolvedRoomIds.toList();
    if (keys.length > _kDissolvedLimit) {
      keys.removeRange(0, keys.length - _kDissolvedLimit);
      _dissolvedRoomIds
        ..clear()
        ..addAll(keys);
    }
    // 写盘按调用顺序排队即可（getInstance 单例、setStringList 串行），不必精确互斥
    unawaited(SharedPreferences.getInstance()
        .then((p) => p.setStringList(_kDissolvedKeys, keys)));
  }

  /// 加载广场列表。
  ///
  /// [refresh] 为 true 时回到第一页（下拉刷新）；为 false 时追加下一页。
  Future<void> loadSquare({bool refresh = true}) async {
    if (_loadingSquare) return;
    _loadingSquare = true;
    if (!refresh) _loadingMore = true;
    if (refresh) {
      _page = 1;
      _hasMore = true;
    }
    _squareError = null;
    notifyListeners();
    try {
      // 广场双源：概念版广场优先，为空时回落到推荐列表
      var payload = await _api.gentingSquare(page: _page, pageSize: 20);
      var list = payload == null ? const <Map<String, dynamic>>[] : extractList(payload);
      if (list.isEmpty) {
        payload = await _api.recommendRooms(page: _page);
        list = payload == null ? const <Map<String, dynamic>>[] : extractList(payload);
      }
      final parsed = list
          .map(MusicRoomBrief.fromJson)
          .where((r) => r.roomId.isNotEmpty && !r.closed)
          .toList();
      if (refresh) {
        _rooms = parsed;
      } else {
        final seen = _rooms.map((r) => r.roomId).toSet();
        _rooms = [..._rooms, ...parsed.where((r) => !seen.contains(r.roomId))];
      }
      _hasMore = parsed.length >= 20;
      _page += 1;
      if (_rooms.isEmpty) _squareError = '暂无可用房间，可创建一个新房间';
    } on ListenTogetherApiError catch (e) {
      if (refresh) _rooms = [];
      _squareError = e.message;
    } catch (_) {
      if (refresh) _rooms = [];
      _squareError = '内容加载失败，请稍后重试';
    } finally {
      _loadingSquare = false;
      _loadingMore = false;
      notifyListeners();
    }
  }

  // ----- 我的房间（参考 EchoMusic loadOwnedRooms 语义）-----
  List<MusicRoomBrief> _myRooms = [];
  bool _loadingMyRooms = false;
  String? _myRoomsError;
  final Map<String, MusicRoomBrief> _historyBriefs = {};

  /// `created_rooms`（我创建的房间）最近一次解析结果，供三源合并使用。
  final List<MusicRoomBrief> _createdRoomBriefs = [];

  /// 我创建/管理的房间（历史房间经详情校验存活 + 按房主过滤后的快照）。
  List<MusicRoomBrief> get myRooms => _myRooms;
  bool get loadingMyRooms => _loadingMyRooms;
  String? get myRoomsError => _myRoomsError;

  /// 加载「我的房间」：历史房间 + 当前会话双源并行。
  ///
  /// 任一数据源失败都不拖垮整体（对齐 EchoMusic 的 allSettled 语义）；
  /// 历史房间逐个拉详情校验存活，已解散的记入解散名单并剔除，
  /// 最终只保留房主为自己的房间。远端结果是权威快照。
  Future<void> loadMyRooms({required String selfUserId}) async {
    if (_loadingMyRooms || selfUserId.isEmpty) return;
    _loadingMyRooms = true;
    _myRoomsError = null;
    notifyListeners();
    try {
      final results = await Future.wait<Object?>([
        _api.createdRooms().catchError((Object _) => null),
        _api.roomHistory().catchError((Object _) => null),
        _api.roomStatus().catchError((Object _) => null),
      ]);

      final createdPayload = results[0];
      _createdRoomBriefs
        ..clear()
        ..addAll(
          createdPayload is Map<String, dynamic>
              ? extractList(createdPayload)
                  .map(MusicRoomBrief.fromJson)
                  .where((b) => b.roomId.isNotEmpty)
              : const <MusicRoomBrief>[],
        );
      debugPrint('[ListenTogether] 我创建的房间源命中 ${_createdRoomBriefs.length} 条'
          '（0 表示该源对本账号无数据，回落历史/会话兜底）');

      final candidates = <String>[];
      void addCandidate(String id) {
        if (id.isEmpty || candidates.contains(id)) return;
        candidates.add(id);
      }

      final historyPayload = results[1];
      if (historyPayload is Map<String, dynamic>) {
        for (final raw in extractList(historyPayload)) {
          final brief = MusicRoomBrief.fromJson(raw);
          if (brief.roomId.isEmpty || _historyBriefs.containsKey(brief.roomId)) continue;
          _historyBriefs[brief.roomId] = brief;
          addCandidate(brief.roomId);
        }
      }
      // 我创建的房间也纳入候选：created_rooms 是权威列表，条目未必带 ownerId，
      // 用 putIfAbsent 注册进 _historyBriefs（仅当尚无更完整的条目），详情校验时
      // 一并拉取实时快照；不覆盖已有条目避免丢失详情数据。
      for (final b in _createdRoomBriefs) {
        _historyBriefs.putIfAbsent(b.roomId, () => b);
        addCandidate(b.roomId);
      }
      // 当前会话的房间也纳入候选（刚创建的房间可能尚未进历史）；
      // 本地会话是最可靠的信号（胶囊存在即会话存在），history/status
      // 上游可能受限（history 报 20002、status 报 40007）不作为唯一依据
      final statusPayload = results[2];
      if (statusPayload is Map<String, dynamic>) {
        addCandidate(extractRoomId(statusPayload));
      }
      final session = _session;
      if (session != null) addCandidate(session.roomId);

      // 详情逐个校验：成功且未解散的用详情（含实时人数/歌名），
      // 解散的记入名单；详情失败但历史条目存在时保留历史条目兜底
      final details = await Future.wait<MusicRoomBrief?>(candidates.take(20).map((id) async {
        try {
          final payload = await _api.roomDetail(id);
          final list = payload == null ? <Map<String, dynamic>>[] : extractList(payload);
          if (list.isEmpty) return _historyBriefs[id];
          final brief = MusicRoomBrief.fromJson(list.first);
          if (brief.closed) {
            rememberDissolved(id);
            return null;
          }
          return brief;
        } on ListenTogetherApiError catch (e) {
          if (isDissolvedRoomError(e)) {
            rememberDissolved(id);
            return null;
          }
          return _historyBriefs[id];
        } catch (_) {
          return _historyBriefs[id];
        }
      }));

      // 三源合并：created（我创建，权威）> 详情快照 > 历史条目；
      // 去重、归属过滤与解散剔除见 mergeMyRooms（纯函数，已单测）。
      _myRooms = mergeMyRooms(
        created: _createdRoomBriefs,
        detailed: details.whereType<MusicRoomBrief>().toList(),
        history: _historyBriefs.values.toList(),
        selfUserId: selfUserId,
      );
      // 会话房间兜底：详情接口失败时用本地会话信息构造，保证「我的房间」
      // 一定能看到正在进行的房间（房主场景 ownerId 即本地账号）
      if (session != null &&
          session.isOwner &&
          !_myRooms.any((b) => b.roomId == session.roomId)) {
        final curSong = session.player.currentSong;
        _myRooms = [
          MusicRoomBrief(
            roomId: session.roomId,
            name: session.roomName,
            notice: '',
            backgroundUrl: '',
            currentSongCover: curSong?.artworkUri ?? '',
            memberCount: session.members.length,
            capacity: session.capacity,
            ownerId: session.selfUserId,
            ownerName: session.selfNickname,
            currentSongName: curSong?.title ?? '',
            currentArtistName: curSong?.artist ?? '',
            closed: false,
          ),
          ..._myRooms,
        ];
      }
    } catch (_) {
      _myRoomsError = '加载失败，请稍后重试';
    } finally {
      _loadingMyRooms = false;
      notifyListeners();
    }
  }

  // ----- 会话 -----
  RoomSession? _session;
  RoomSession? get session => _session;

  /// 入房前的播放快照（仅首次入房捕获；退房恢复后清空）。
  ({List<Song> playlist, List<Song> originalPlaylist, int index, Duration position, bool playing})?
      _playbackBeforeRoom;

  /// 退房后正在进行的队列恢复任务：恢复含起播链路（URL 解析）耗时较长，
  /// 后台执行；换房时 [_startSession] 须等它完成再捕获，避免捕到房间歌队列。
  Future<void>? _pendingRestore;

  /// 当前是否处于「听众跟随」态：在房间里，但不是房主且未脱离。
  ///
  /// 听众允许拖动进度条（拖动即进入脱离态，见 [RoomSession.detachBySeek]），
  /// 播放器进度条不再据此降级为只读。保留该判定供「跟随/脱离」语义展示用。
  bool get followingAsGuest {
    final s = _session;
    return s != null && !s.isOwner && !s.playbackDetached;
  }
  bool get inRoom => _session != null;

  /// 会话内部状态（成员/消息/播放快照等）变更时转发给 provider。
  /// 界面都 watch 的是 provider，若不转发，人数胶囊、AppBar 计数等
  /// 会话级数据永远不会触发重建（只有旋转屏幕等被动重建才能刷出新值）。
  void _forwardSessionUpdate() => notifyListeners();

  /// 加入房间；命中 20006 会话冲突时先查当前会话并按需恢复。
  Future<bool> enter({
    required String roomId,
    required String roomName,
    required PlayerProvider player,
    required KugouProvider account,
  }) async {
    final current = _session;
    if (current != null && current.roomId == roomId) return true;
    // 切换到别的房间：先静默离开原房间。否则上游以 20006 拒绝，
    // 且可能继续按旧会话返回数据（聊天/成员会串到上一个房间）。
    if (current != null) await exitRoom();
    try {
      final resp = await _api.joinRoom(roomId);
      final id = resp == null ? '' : extractRoomId(resp);
      await _startSession(id.isNotEmpty ? id : roomId, false, roomName, player, account);
      return true;
    } on ListenTogetherApiError catch (e) {
      if (isSessionConflictError(e)) {
        return _recoverCurrentSession(roomId, roomName, player, account);
      }
      if (isDissolvedRoomError(e)) rememberDissolved(roomId);
      rethrow;
    }
  }

  /// 冷启动会话恢复：App 进程被杀重启后本地会话状态丢失，但服务端会话
  /// 仍在进行（其他成员还能看到自己）——按服务端会话重建 RoomSession。
  ///
  /// 流程：room/status（空 room_id 查账号当前会话）→ 有会话则取 is_owner
  /// 旗标，room/detail 校正房主身份并取房间名（detail 失败不阻塞恢复，
  /// 房间名用占位、慢轮询会补齐）→ _startSession 重建轮询与歌单。
  /// EchoMusic 在一起听页 onMounted 做同款恢复；本项目在装配层启动时调用，
  /// 让播放器胶囊不进页也能立即回到会话态。已在本会话中则幂等返回 true。
  Future<bool> restoreCurrentSessionIfAny({
    required PlayerProvider player,
    required KugouProvider account,
  }) async {
    if (_session != null) return true;
    try {
      final status = await _api.roomStatus();
      final currentId = status == null ? '' : extractRoomId(status);
      if (currentId.isEmpty) return false;
      var isOwner = readNestedFlag(status, 'is_owner');
      var roomName = '一起听房间';
      try {
        final detail = await _api.roomDetail(currentId);
        final list = detail == null ? <Map<String, dynamic>>[] : extractList(detail);
        final rec = list.isNotEmpty
            ? list.first
            : (asRecord(unwrapListenPayload(detail)) ?? const <String, dynamic>{});
        if (rec.isNotEmpty) {
          final brief = MusicRoomBrief.fromJson(rec);
          if (brief.name.isNotEmpty) roomName = brief.name;
          // 房主身份以 ownerId 与自身 userid 比对校正（status 旗标之外的第二判据）
          final ownerId = brief.ownerId.isNotEmpty
              ? brief.ownerId
              : readString(rec, const ['userid', 'owner_id', 'ownerid', 'create_userid']);
          if (ownerId.isNotEmpty && ownerId == account.userid) isOwner = true;
        }
      } catch (_) {
        // 详情失败不阻塞恢复
      }
      await _startSession(currentId, isOwner, roomName, player, account);
      debugPrint('[ListenTogether] 已恢复进行中的房间会话: '
          '$currentId（${isOwner ? "房主" : "听众"}）');
      return true;
    } catch (e) {
      // 恢复是尽力而为：任何失败都按「没有进行中的会话」处理，
      // 登录态/网络问题由用户显式操作时的完整链路给出错误提示。
      debugPrint('[ListenTogether] 会话恢复失败: $e');
      return false;
    }
  }

  /// 创建并进入房间。
  ///
  /// [roomPrivacy] 1 = 公开房，2 = 私密房（默认私密）。
  /// 前置预检：账号可能已有未结束的会话（多设备或上次异常退出），
  /// 直接恢复而不重复创建（否则上游以 20006 拒绝）。
  Future<bool> createAndEnter({
    required String roomName,
    String backgroundUrl = '',
    int roomPrivacy = 2,
    int capacity = 5,
    List<Map<String, dynamic>> initialAudios = const [],
    required PlayerProvider player,
    required KugouProvider account,
  }) async {
    final existing = await _tryResolveCurrentSession(roomName, player, account);
    if (existing) return true;

    Map<String, dynamic>? created;
    try {
      created = await _api.createMusicRoom(
        roomName: roomName,
        backgroundUrl: backgroundUrl,
        roomPrivacy: roomPrivacy,
        capacity: capacity,
      );
    } on ListenTogetherApiError catch (e) {
      // 预检与创建之间可能被另一台设备抢先建立会话
      if (isSessionConflictError(e)) {
        if (await _tryResolveCurrentSession(roomName, player, account)) return true;
      }
      rethrow;
    }

    final roomId = created == null ? '' : extractRoomId(created);
    if (roomId.isEmpty) {
      throw const ListenTogetherApiError('服务端未返回新房间 ID', 0);
    }
    if (initialAudios.isNotEmpty) {
      try {
        // 一同上报当前播放进度，避免开房后服务端把当前曲目当作歌单第一首
        await _api.initializeRoom(
          roomId: roomId,
          audios: initialAudios,
          progressInfo: buildRoomProgressInfo(player),
        );
      } catch (_) {
        // 初始化失败时清理半成品房间，避免账号被一个空房间占住会话
        try {
          await _api.dismissRoom(roomId);
        } catch (_) {}
        rethrow;
      }
    }
    // 人数上限仅私密房由用户自选；公开房为麦位制、上限未知（0）
    await _startSession(
      roomId,
      true,
      roomName,
      player,
      account,
      capacity: roomPrivacy == 2 ? capacity : 0,
    );
    return true;
  }

  /// 查账号当前会话；若已有会话则直接恢复并返回 true。
  ///
  /// 这是「尽力而为」的前置查询：任何失败都当作「没有进行中的会话」继续走创建，
  /// 真正的鉴权/风控问题由随后的创建请求给出明确错误，避免预检异常阻断建房。
  Future<bool> _tryResolveCurrentSession(
    String roomName,
    PlayerProvider player,
    KugouProvider account,
  ) async {
    try {
      final status = await _api.roomStatus();
      final currentId = status == null ? '' : extractRoomId(status);
      if (currentId.isEmpty) return false;
      final isOwner = readNestedFlag(status, 'is_owner');
      await _startSession(currentId, isOwner, roomName, player, account);
      return true;
    } catch (e) {
      debugPrint('[ListenTogether] session preflight failed, creating anyway: $e');
      return false;
    }
  }

  /// 20006 冲突恢复：仅当服务端会话指向目标房间时恢复，否则原样抛出。
  Future<bool> _recoverCurrentSession(
    String roomId,
    String roomName,
    PlayerProvider player,
    KugouProvider account,
  ) async {
    final status = await _api.roomStatus().catchError((Object e) {
      // 恢复查询本身失败时，仍以会话冲突文案上抛，不让网络错误掩盖真实原因
      debugPrint('[ListenTogether] session recovery query failed: $e');
      return <String, dynamic>{};
    });
    final currentId = status == null ? '' : extractRoomId(status);
    if (currentId.isNotEmpty && (roomId.isEmpty || currentId == roomId)) {
      final isOwner = readNestedFlag(status, 'is_owner');
      await _startSession(currentId, isOwner, roomName, player, account);
      return true;
    }
    throw const ListenTogetherApiError('账号当前已有未结束的众乐房会话', 20006);
  }

  Future<void> _startSession(
    String roomId,
    bool isOwner,
    String roomName,
    PlayerProvider player,
    KugouProvider account, {
    // 上游无可靠的房间人数上限字段，加入/恢复场景默认 0（未知），
    // 仅自建私密房传入用户自选值；展示端未知时只显示在线人数
    int capacity = 0,
  }) async {
    // 换房链路（enter 先 exitRoom 再进新房间）：上一房间的退房恢复是后台任务，
    // 必须等它完成再捕获——否则快照可能仍是旧房间的房间歌队列，且后台恢复
    // 会与新会话的起播互相覆盖。恢复失败不阻塞入房。
    final pendingRestore = _pendingRestore;
    _pendingRestore = null;
    if (pendingRestore != null) await pendingRestore;
    // 首次入房捕获当前播放快照，退房时恢复（对齐 EchoMusic
    // capturePreviousPlaybackQueue/restorePreviousPlaybackQueue）
    _playbackBeforeRoom ??= player.capturePlaybackSnapshot();
    final old = _session;
    // 先摘掉转发监听再销毁，避免向已 dispose 的会话移除监听时报错
    old?.removeListener(_forwardSessionUpdate);
    old?.dispose();
    _session = RoomSession(
      _api,
      isOwner,
      roomId: roomId,
      roomName: roomName,
      capacity: capacity,
      player: player,
      selfUserId: account.userid ?? '',
      selfNickname: account.userInfo?.nickname ?? '',
      selfAvatar: account.userInfo?.avatar ?? '',
      onDissolved: _handleSessionDissolved,
    );
    _session!.addListener(_forwardSessionUpdate);
    notifyListeners();
  }

  /// 离开房间（[dismiss] 为 true 且自己是房主时解散房间）。
  Future<void> exitRoom({bool dismiss = false}) async {
    final s = _session;
    if (s != null) {
      await s.close(dismiss: dismiss);
      _detachSession(s);
    }
    notifyListeners();
  }

  /// 清除会话引用并恢复入房前的播放队列（退房 / 远端解散共用）。
  ///
  /// 恢复含起播链路（URL 解析）耗时较长，注册为后台任务让收口立即返回、不卡
  /// 离开对话框；换房时由 [_startSession] 等待该任务完成后再捕获快照，避免
  /// 捕到房间歌队列或起播竞态。恢复失败静默忽略，不阻塞收口。
  void _detachSession(RoomSession s) {
    s.removeListener(_forwardSessionUpdate);
    _session = null;
    final snapshot = _playbackBeforeRoom;
    _playbackBeforeRoom = null;
    if (snapshot != null) {
      _pendingRestore = s.player
          .restorePlaybackSnapshot(
            playlist: snapshot.playlist,
            originalPlaylist: snapshot.originalPlaylist,
            index: snapshot.index,
            position: snapshot.position,
            playing: snapshot.playing,
          )
          .catchError((Object _) {});
    }
    notifyListeners();
  }

  /// 会话被远端解散（房主解散 / 房间过期 / 详情 `hidden=1`）后的**本地收口**。
  ///
  /// 与 [exitRoom] 的差别：**不再调用服务端接口**（房间已不存在，leaveRoom 无意义），
  /// 但必须完成同等的本地收口——否则 `inRoom` 恒真：房间页（判据 `session == null`）
  /// 不弹栈、播放器胶囊常驻，用户完全不知道房间已经没了（「房主解散后听众还留在
  /// 房间里且无任何提示」的根因）。对照 EchoMusic `handleDissolvedSessionError`：
  /// `resetSessionState()` + `lastError` + 解散 toast。
  ///
  /// 幂等：会话内部检出解散时已 `closed = true` 并取消定时器，这里只做提供者侧的
  /// 引用切断；**不在会话自己的调用栈里 dispose 它**（避免 ChangeNotifier 在随后
  /// 的 notifyListeners 上抛「used after dispose」）。
  void _handleSessionDissolved(String roomId) {
    rememberDissolved(roomId);
    final s = _session;
    // 只收口「当前会话」：换房时旧会话的迟到解散错误不能拆掉刚建好的新房间
    if (s == null || s.roomId != roomId) return;
    _detachSession(s);
    showToast('「${s.roomName}」已解散，已退出一起听', long: true);
  }

  @override
  void dispose() {
    _session?.removeListener(_forwardSessionUpdate);
    _session?.dispose();
    super.dispose();
  }
}

/// 单首歌的富化中间结果：详情与搜索合并后的字段草稿。
class _EnrichDraft {
  _EnrichDraft({
    required this.title,
    required this.artist,
    required this.coverUrl,
    required this.artistId,
    required this.albumId,
    required this.mixSongId,
    required this.durationSeconds,
    required this.matchHashes,
  });
  String title;
  String artist;
  String coverUrl;
  String artistId;
  String albumId;
  final String mixSongId;
  final int durationSeconds;
  final Set<String> matchHashes;
}

/// 一个待搜索的歌：hash 用于记账退还，index 用于写回 next 列表。
class _EnrichSearchJob {
  _EnrichSearchJob({
    required this.hash,
    required this.index,
    required this.query,
    required this.draft,
  });
  final String hash;
  final int index;
  final String query;
  final _EnrichDraft draft;
  bool searchFailed = false;
}

/// 搜索词的歌手归一：多歌手「、」连接时只取首位。
/// 酷狗搜索对「、」连接的整串歌手命中率为 0（实测「Jonas Blue、RANI
/// Finally」「The Midnight、Nikki Flores Jason」全部未命中），而首波搜索
/// 命中的歌恰为单歌手——多歌手歌必须取首位歌手才能搜到。
String enrichSearchArtist(String artist) {
  final a = artist.trim();
  if (a.isEmpty) return '';
  return a.split('、').first.trim();
}

/// 歌名同一性判定（搜索兜底的 hash 放宽）。
///
/// /audio 详情对部分歌（OGG 授权版本）不返回任何 hash 家族与封面，搜索
/// 结果的 hash 必然对不上 matchHashes——此时按「歌名精确相等」兜底采信
/// 搜索结果的封面。归一保守：去空白、忽略大小写、统一全角括号、剥离
/// 「歌手 - 」前缀；**不剥离** Live/Remix/Explicit 等后缀，避免误配不同
/// 版本的封面。
bool isSameSongTitle(String a, String b) {
  String norm(String raw) {
    var s = raw.trim().toLowerCase();
    final i = s.indexOf(' - ');
    if (i > 0) s = s.substring(i + 3);
    return s
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('（', '(')
        .replaceAll('）', ')');
  }

  final na = norm(a);
  final nb = norm(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na == nb;
}

// ===========================================================================
// 房间会话
// ===========================================================================

/// 单个房间的运行时会话：三频轮询 + 播放同步 + 房主控制上报。
class RoomSession extends ChangeNotifier {
  RoomSession(
    this._api,
    this._isOwner, {
    required this.roomId,
    required this.roomName,
    required this.player,
    required this.selfUserId,
    required this.selfNickname,
    required this.selfAvatar,
    this.capacity = 0,
    this.onDissolved,
  }) {
    _startTimers();
    unawaited(_hydrate());
  }

  final ListenTogetherApi _api;
  final String roomId;
  final String roomName;
  final PlayerProvider player;
  final String selfUserId;
  final String selfNickname;
  final String selfAvatar;

  /// 人数上限，仅用于展示 x/y。0 = 未知（上游无可靠容量字段）：
  /// 私密自建房为用户自选值，其余场景默认未知，展示端只显示在线人数。
  int capacity;

  /// 房主信息（由房间详情接口校正）：听众接口 get_musicroom_member
  /// 只返回听众不含房主，成员面板需要用它注入房主，否则互相看不到。
  String ownerUserId = '';
  String ownerName = '';
  /// 房主头像（room/detail 的 data.user_pic），注入成员面板用。
  String _ownerAvatar = '';

  /// 房间解散时回调（提供者侧据此做本地收口：清除会话、恢复入房前队列、toast）。
  final void Function(String roomId)? onDissolved;

  bool _isOwner;

  /// 是否为房主。入房时按会话判定，随后由房间详情接口按 ownerId 校正。
  bool get isOwner => _isOwner;

  // ----- 对外状态 -----
  ListenTogetherPhase phase = ListenTogetherPhase.joined;
  String? lastError;
  PlayerSyncState? remoteState;

  /// 封面预取队列：带宽让路（音频 loading/buffering 中挂起出队）+ 串行
  /// 下载进 DefaultCacheManager 磁盘缓存，与 UI 侧 CachedNetworkImage 同池
  /// 复用。原生 prefetchCover（Glide）只服务通知栏，Dart 侧 UI 命中不了。
  late final CoverPrefetchQueue _coverQueue = CoverPrefetchQueue(
    isBandwidthBusy: () => player.isPlaybackNotReady,
  );
  List<RoomSong> playlist = [];
  List<RoomMember> members = [];
  List<ChatMessage> messages = [];
  List<OrderSongEntry> songOrders = [];
  String listVersion = '';
  bool loadingRoom = true;
  bool guestLocallyPaused = false;
  bool closed = false;

  /// 房主是否开启聊天（update_chat 口径；由房间详情 allow_chat 刷新，
  /// 默认开启）。成员端聊天输入框按此禁用。
  bool allowChat = true;

  // ----- 内部状态 -----

  /// 房间接管起播窗口（时间窗）：仅用于装配层守卫的**房主分支防递归**——
  /// ownerSwitchSong→_playRoomSong→playSong 会同步再入守卫，歌单内必命中
  /// handledByRoom，若无此标志会无限递归且永不真正起播。听众分支的脱离
  /// 判定不用时间窗（装载 Future 在冷 CDN 上 11s+ 才回包，会误拦窗口内的
  /// 用户脱离），改按 [_takeoverTarget] 身份判定。
  bool _roomTakeoverPlayback = false;

  /// 房间接管起播窗口是否激活（装配层守卫据此放行，见 [_roomTakeoverPlayback]）。
  bool get isRoomTakeoverPlaybackActive => _roomTakeoverPlayback;

  /// 当前接管装载的目标曲目（身份而非时间窗）。
  ///
  /// 装载 Future 在冷 CDN 源上 11s+ 才回包，时间窗标志会让整个装载窗口内的
  /// 用户点击被误判；按「点的歌是否就是接管目标」判定则与时长无关。
  RoomSong? _takeoverTarget;

  /// 用户脱离态：听众在房间外播放其他音乐时置位（Task 9 完善检测），
  /// 脱离期间房间状态轮询继续，但不再接管本地播放器。
  bool playbackDetached = false;

  /// 聊天已读游标：最后一条「看过」的消息 id。
  ///
  /// 房间页与播放器胶囊共享同一游标（任意入口打开聊天后红点同步清除）；
  /// 用 id 而非条数：消息列表有 200 条上限，活跃房间长度饱和后按条数
  /// 差值永远算不出新消息。基线在 [_mergeMessages] 首次收到非空列表时建立
  /// （进房历史不算未读）。
  String? _lastSeenChatMessageId;

  /// 聊天是否有未读新消息（驱动房间页与播放器胶囊的红点）。
  bool get hasUnreadChatMessages {
    final list = messages;
    if (list.isEmpty || _lastSeenChatMessageId == null) return false;
    return list.last.id != _lastSeenChatMessageId;
  }

  /// 是否有待处理的点歌请求（驱动房间页「歌单」入口与播放器胶囊的红点）。
  ///
  /// 语义是「待处理」而非「未读」：请求被通过/忽略后 `songOrders` 移除该条，
  /// 红点随之消失；与聊天未读游标（id 游标、任一入口读过即清）刻意区分——
  /// 房主要的是「还有事没做」的提醒，看过不看都不该消掉。
  /// `songOrders` 只有房主会拉取（[_loadSongOrders] 带 `_isOwner` 守卫），
  /// 这里的 `_isOwner` 判定是第二道闸。
  bool get hasPendingSongOrders => _isOwner && songOrders.isNotEmpty;

  /// 把当前最后一条消息记为已读（打开聊天托盘前与关闭后各收口一次）。
  /// 游标实际变化时才通知，避免打开托盘的瞬时重复重建。
  void markChatMessagesSeen() {
    final list = messages;
    if (list.isEmpty) return;
    final lastId = list.last.id;
    if (_lastSeenChatMessageId == lastId) return;
    _lastSeenChatMessageId = lastId;
    notifyListeners();
  }

  Timer? _heartbeatTimer;
  Timer? _fastTimer;
  Timer? _slowTimer;
  bool _heartbeatInFlight = false;
  bool _fastInFlight = false;
  bool _slowInFlight = false;
  int _heartbeatFailureCount = 0;
  int _memberLoadRevision = 0;
  int _songsLoadRevision = 0;
  int _ownerControlRevision = 0;
  DateTime? _ownerGraceUntil;

  /// 「施加远端动作」的重入互斥：记录**开始时刻**而非布尔，便于发现卡死。
  ///
  /// 锁必须跨越「起播」这种长 await（否则同一首歌会被并发起播多次），但起播链路
  /// 一旦挂起（例如被后续 load 取代的 play 请求永不完成），布尔锁会让本次会话的
  /// 远端同步**永久失效**——成员冻结在旧歌上，此后不再有任何纠偏日志，只能退出重进。
  /// 因此带一个超时兜底，超过 [kApplyRemoteStaleTimeout] 视为异常并强制放行。
  DateTime? _applyingRemoteSince;
  String? _lastSeekKey;
  int _lastSeekAt = 0;

  /// seek 生效延迟的 EWMA 估计（毫秒），0 表示尚无样本。
  /// 用于把纠偏 seek 的目标提前一个估计延迟（对齐 EchoMusic
  /// remoteSeekLatencyEstimateMs），否则每次纠偏都系统性落后一个生效延迟。
  int _remoteSeekLatencyMs = 0;

  /// 「房间在播但本机未播放且本轮无动作」的守卫原因，用于日志边沿去重
  /// （见 [_applyRemotePlayback] 的诊断分支）。
  String? _resumeBlockReason;

  /// 「本地音源不可用」重装载的退避截止（墙钟毫秒），未到点不重复发起。
  int _unavailableReloadAfterMs = 0;

  /// 正在跟随装载的目标身份（`hash:mixSongId`）；同一目标不重复起播。
  ///
  /// 见 [_followRemoteSong] 的互斥说明。
  String? _followInFlightKey;

  /// 房主播放态与服务端不一致的持续观测标记
  /// （见 [_reconcileOwnerPlaybackState]：连续两轮不一致才补报）。
  bool _ownerPlayMismatch = false;
  int _songsRetryAfterMs = 0;
  Future<void>? _songsLoadInFlight;
  Future<void> _ownerCommandQueue = Future<void>.value();
  final Map<String, int> _playbackRetryAfterMs = {};
  /// 富化尝试记账（语义见 [MetadataAttemptTracker]）。
  final MetadataAttemptTracker _metadataAttempts = MetadataAttemptTracker();
  /// 富化重入保护：多个 fire-and-forget 调用点并发时的互斥（见
  /// [_enrichMetadataInBackground] 的文档，去掉它会导致封面概率性缺失）。
  bool _enrichInFlight = false;
  /// 已建立成员基线快照的房间号（首次加载只建基线，不合成进出消息）。
  String _memberSnapshotRoomId = '';
  Map<String, RoomMember> _memberSnapshot = {};

  /// 远端正在播放、但不在服务端歌单里的曲目（占位条目）。
  ///
  /// 不能塞进 [playlist]：权威列表每次加载都会整表覆盖，插入的条目被丢弃后
  /// [_patchCurrentSongMetadata] 再也匹配不到当前歌 → 名称/封面永久停在占位值。
  RoomSong? _pendingRemoteSong;

  /// 首次 sync_player 的原始响应与解析结果只打印一次（进房对齐问题的取证用）。
  ///
  /// 「成员进房从头播」有两个候选根因：上游没给进度，或我们解析错位。
  /// 原始响应 + 解析字段配对打印，一次日志即可区分，避免靠猜。
  bool _loggedFirstSync = false;

  // =========================================================================
  // 生命周期
  // =========================================================================

  void _startTimers() {
    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) => unawaited(_heartbeat()));
    _fastTimer = Timer.periodic(kFastPollInterval, (_) => unawaited(_fastPoll()));
    _slowTimer = Timer.periodic(kSlowPollInterval, (_) => unawaited(_slowPoll()));
  }

  void _cancelTimers() {
    _heartbeatTimer?.cancel();
    _fastTimer?.cancel();
    _slowTimer?.cancel();
    _heartbeatTimer = null;
    _fastTimer = null;
    _slowTimer = null;
    _heartbeatInFlight = false;
    _fastInFlight = false;
    _slowInFlight = false;
  }

  /// 入房后首轮加载：核心数据（歌单 + 播放状态）阻塞等待，
  /// 外围数据（成员/聊天/点歌）后台补齐。
  Future<void> _hydrate() async {
    try {
      await Future.wait([_loadSongs(force: true), _syncPlayback(force: true)]);
    } catch (e) {
      if (_handleDissolved(e)) return;
      if (e is ListenTogetherApiError) lastError = e.message;
    }
    if (closed) return;
    loadingRoom = false;
    notifyListeners();
    unawaited(_loadDetail());
    unawaited(_loadMembers());
    unawaited(_loadMessages());
    if (_isOwner) unawaited(_loadSongOrders());
  }

  /// 解散统一出口：命中解散类错误时结束本地会话并通知调用方。
  /// 返回 true 表示错误已被处理。
  bool _handleDissolved(Object error) {
    if (!isDissolvedRoomError(error)) return false;
    _cancelTimers();
    closed = true;
    _coverQueue.dispose();
    // 房间已解散，暂停属收尾而非用户意图；且会话已 closed，上报也无意义
    unawaited(player.pause(notifyRoom: false));
    onDissolved?.call(roomId);
    notifyListeners();
    return true;
  }

  // =========================================================================
  // 三频轮询
  // =========================================================================

  Future<void> _heartbeat() async {
    if (closed || _heartbeatInFlight) return;
    _heartbeatInFlight = true;
    try {
      await _api.heartbeat(roomId);
      _heartbeatFailureCount = 0;
    } catch (e) {
      if (_handleDissolved(e)) return;
      _heartbeatFailureCount += 1;
      if (_heartbeatFailureCount >= 3) {
        lastError = '房间连接不稳定，正在继续重试';
        notifyListeners();
      }
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> _fastPoll() async {
    if (closed || _fastInFlight) return;
    _fastInFlight = true;
    try {
      // 单项失败不拖垮其他项
      await Future.wait([
        _loadMessages().catchError((_) {}),
        _loadMembers().catchError((_) {}),
        _syncPlayback().catchError((_) {}),
      ]);
    } finally {
      _fastInFlight = false;
    }
  }

  Future<void> _slowPoll() async {
    if (closed || _slowInFlight) return;
    _slowInFlight = true;
    try {
      await Future.wait([
        _loadDetail().catchError((_) {}),
        if (_isOwner) _loadSongOrders().catchError((_) {}),
      ]);
    } finally {
      _slowInFlight = false;
    }
  }

  // =========================================================================
  // 歌单
  // =========================================================================

  /// 加载房间歌单。
  ///
  /// 房主走 music_fetch_list（50/页 + 游标翻页，quantity 截断）；
  /// 听众走 music_recent_list（服务端维护的近期队列，一次替换）。
  Future<void> _loadSongs({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now < _songsRetryAfterMs) return;
    final inFlight = _songsLoadInFlight;
    if (inFlight != null) return inFlight;

    final request = _doLoadSongs();
    _songsLoadInFlight = request;
    try {
      await request;
    } finally {
      if (identical(_songsLoadInFlight, request)) _songsLoadInFlight = null;
    }
  }

  Future<void> _doLoadSongs() async {
    final revision = ++_songsLoadRevision;
    bool isCurrent() => !closed && _songsLoadRevision == revision;
    try {
      final Map<String, dynamic>? payload;
      final List<RoomSong> songs;
      if (_isOwner) {
        final result = await _loadOwnerPlaylistWithCursor(
          onPartial: (partial) {
            // 增量发布：每页先合并进歌单让 UI 即时可见；占位条目
            // （_pendingRemoteSong）不动，只在下方权威整表回写时清理
            if (!isCurrent() || partial.isEmpty) return;
            playlist = _mergeSongList(partial);
            unawaited(_enrichMetadataInBackground());
            // 歌单自带封面的歌不进富化目标：直接批量投预取队列
            // （去重幂等，重复投递无副作用）
            _coverQueue.enqueueAll(playlist.map((s) => s.coverUrl));
            notifyListeners();
          },
        );
        payload = result.payload;
        songs = result.songs;
      } else {
        payload = await _api.recentPlaylist(roomId);
        songs = extractList(payload).map(RoomSong.fromJson).toList();
      }
      if (songs.isEmpty && isCurrent()) {
        // 权威来源返回 0 首：要么上游真空、要么响应结构与解析预期错位——
        // 留原始响应取证，否则「歌单只有三首（同步窗口）」这类问题无从排查。
        final raw = payload.toString();
        debugPrint('[ListenTogether] 权威歌单返回 0 首'
            '（${_isOwner ? "fetch_list" : "recent_list"}）: '
            '${raw.length > 800 ? '${raw.substring(0, 800)}…' : raw}');
      }
      if (!isCurrent()) return;

      final nextVersion = readNestedString(payload, 'list_version');
      if (nextVersion.isNotEmpty) listVersion = nextVersion;
      // sync 响应里也可能带播放快照，顺手采信（时间戳更新的优先）
      final snap = payload == null ? null : _snapshotFrom(payload);
      if (snap != null &&
          snap.hash.isNotEmpty &&
          (remoteState == null || snap.updatedAtMs >= remoteState!.updatedAtMs)) {
        remoteState = snap;
      }
      if (songs.isNotEmpty) {
        playlist = _mergeSongList(songs);
        // 占位条目已进入权威歌单：改由歌单条目承载，避免同一首歌两份身份
        final pending = _pendingRemoteSong;
        if (pending != null && songs.any((s) => s.sameAs(pending))) {
          _pendingRemoteSong = null;
        }
        unawaited(_enrichMetadataInBackground());
        _coverQueue.enqueueAll(playlist.map((s) => s.coverUrl));
      }
      notifyListeners();
    } catch (e) {
      if (_handleDissolved(e)) return;
      if (e is ListenTogetherApiError && e.code == 30009) {
        // 游标已到尾/暂时拒绝：保留已拉取的歌单并退避
        _songsRetryAfterMs =
            DateTime.now().millisecondsSinceEpoch + kPlaylistCursorBackoff.inMilliseconds;
        return;
      }
      // 其他失败：必须留痕并退避——此前完全静默，首次加载失败后 list_version
      // 不变就不会再触发加载，歌单会永远停留在空/同步窗口状态且无从排查。
      debugPrint('[ListenTogether] 歌单加载失败'
          '（${_isOwner ? "fetch_list" : "recent_list"}）: $e');
      _songsRetryAfterMs =
          DateTime.now().millisecondsSinceEpoch + kPlaylistLoadRetryBackoff.inMilliseconds;
    }
  }

  /// 房主歌单：以最后一首为游标继续翻页，最多 [kPlaylistMaxPages] 页。
  ///
  /// [onPartial] 为增量发布回调：首页解析后与每页成功追加后各调用一次，
  /// 弱网下「先可见再补全」（对齐 EchoMusic publishSongs），不等游标分页
  /// 全部结束。回调内不得改动 [_pendingRemoteSong]——占位条目只在末尾
  /// 权威整表回写路径清理。
  Future<({Map<String, dynamic>? payload, List<RoomSong> songs})>
      _loadOwnerPlaylistWithCursor(
          {void Function(List<RoomSong> songs)? onPartial}) async {
    final first = await _api.playlist(roomId);
    final songs = extractList(first).map(RoomSong.fromJson).toList();
    onPartial?.call(songs); // 首页先可见：不等游标分页全部结束（对齐 EchoMusic publishSongs）
    final quantity = readNestedInt(first, 'quantity');
    if (songs.isEmpty || songs.length < kPlaylistPageSize) {
      return (payload: first, songs: songs);
    }
    final seen = songs.map((s) => s.hash.toLowerCase()).toSet();
    final seenCursors = <String>{};
    var cursor = songs.last;
    for (var page = 1;
        page < kPlaylistMaxPages && (quantity <= 0 || songs.length < quantity);
        page++) {
      final cursorKey = '${cursor.originalHash.isNotEmpty ? cursor.originalHash : cursor.hash}'
          ':${cursor.mixSongId}';
      if (seenCursors.contains(cursorKey)) break;
      seenCursors.add(cursorKey);
      final List<RoomSong> pageSongs;
      try {
        final pagePayload = await _api.playlist(roomId, cursorAudio: {
          'hash': cursor.originalHash.isNotEmpty ? cursor.originalHash : cursor.hash,
          'mixsongid': cursor.mixSongId,
        });
        pageSongs = extractList(pagePayload).map(RoomSong.fromJson).toList();
      } on ListenTogetherApiError catch (e) {
        // 30009 表示当前游标不可继续，APP 到此即停止翻页；已拉取的页面仍有效
        if (e.code == 30009) break;
        rethrow;
      }
      var appended = 0;
      for (final s in pageSongs) {
        final key = s.hash.toLowerCase();
        if (seen.contains(key)) continue;
        seen.add(key);
        songs.add(s);
        appended += 1;
      }
      if (appended > 0) {
        onPartial?.call(songs); // 每页追加即发布，弱网下歌单逐步增长可见
      }
      if (pageSongs.isEmpty || appended == 0 || pageSongs.length < kPlaylistPageSize) break;
      cursor = pageSongs.last;
    }
    // quantity 是服务端歌单的权威数量，游标边界偶尔返回重叠项
    final trimmed = (quantity > 0 && songs.length > quantity)
        ? songs.sublist(0, quantity)
        : songs;
    return (payload: first, songs: trimmed);
  }

  /// 按歌曲身份去重合并；同一首歌的元数据交给
  /// [mergeRoomSongPreferRicher] 评分择优（身份字段缓存优先，展示字段择优）。
  List<RoomSong> _mergeSongList(List<RoomSong> incoming) {
    final merged = <RoomSong>[];
    for (final s in incoming) {
      final idx = merged.indexWhere((e) => e.sameAs(s));
      if (idx < 0) {
        merged.add(s);
        continue;
      }
      merged[idx] = mergeRoomSongPreferRicher(merged[idx], s);
    }
    return merged;
  }

  /// 元数据富化：歌单接口常只给 hash，用 /audio 补齐名称/歌手/封面。
  /// 仅增强展示与歌词定位，失败不影响列表可见性。
  ///
  /// **重入保护（[_enrichInFlight]）是必需的，不能去掉**：调用方有三处
  /// （`_syncPlayback` 每 5s、`_doLoadSongs`、歌单合并）且全是 fire-and-forget。
  /// 无保护时多路并发的后果是互相覆盖：
  ///   1. 各自在入口做 `next = List.from(playlist)` 快照，结束时整表回写
  ///      `playlist = next`；后完成的一路会用**陈旧的快照**覆盖掉先完成一路
  ///      已富化出的歌名/封面（表现为「有概率加载不出封面」）。
  ///   2. 每路各 `bump` 一次记账，[MetadataAttemptTracker] 额度被并发路径
  ///      加速耗尽，之后 `_metadataExhausted` 直接跳过 → 封面永久空缺。
  Future<void> _enrichMetadataInBackground() async {
    if (_enrichInFlight) return;
    _enrichInFlight = true;
    try {
      await _doEnrichMetadata();
    } finally {
      _enrichInFlight = false;
    }
  }

  /// 搜索同歌候选并挑选「最优命中」：优先带封面的候选（多版本/合辑场景，
  /// 首个 hash 匹配项可能恰好无图，必须遍历全部匹配项）。
  ///
  /// hash 家族不命中时的兜底：[expectedTitle] 非空时按 [isSameSongTitle]
  /// 采信搜索结果的歌名精确匹配项——/audio 对 OGG 授权版本常不返回任何
  /// hash 家族，hash 严格匹配会把能搜到的歌误判为「未命中」（表现为
  /// 封面/artistId/albumId 永远补不上）。歌名匹配项只用于补展示字段
  /// （封面/身份 id），不动 hash/播放，风险可控。
  Future<KugouSongDetail?> _searchEnrichHit(
    String query,
    Set<String> matchHashes, {
    String? expectedTitle,
  }) async {
    final result = await KugouApiClient().search(query);
    KugouSongDetail? hit;
    KugouSongDetail? titleMatch;
    for (final e in result?.songs ?? const <KugouSongDetail>[]) {
      if (titleMatch == null &&
          expectedTitle != null &&
          expectedTitle.isNotEmpty &&
          isSameSongTitle(e.songName, expectedTitle)) {
        titleMatch = e;
      }
      final hashes = [
        e.hash,
        e.hash128 ?? '',
        e.hash320 ?? '',
        e.hqHash ?? '',
        e.sqHash ?? '',
      ];
      final matched = hashes.any(
        (h) => h.isNotEmpty && matchHashes.contains(h.toLowerCase()),
      );
      if (!matched) continue;
      final hasCover = (e.artworkUri ?? '').isNotEmpty;
      if (hit == null) {
        hit = e;
        if (hasCover) break;
        continue;
      }
      if (hasCover) {
        hit = e;
        break;
      }
    }
    return hit ?? titleMatch;
  }

  /// 执行单个搜索任务：命中则把干净短歌名/封面/身份 id 合入草稿。
  /// 搜索异常（网络抖动/限流）不是「查无此歌」：退还该歌尝试额度并标记
  /// searchFailed（本轮不写回，等下一轮重试）。
  Future<void> _runEnrichSearchJob(_EnrichSearchJob job) async {
    try {
      final hit = await _searchEnrichHit(
        job.query,
        job.draft.matchHashes,
        expectedTitle: job.draft.title,
      );
      if (hit != null) {
        final hitSong = hit.toSong();
        if (hitSong.title.isNotEmpty) job.draft.title = hitSong.title;
        if (hitSong.artist.isNotEmpty && hitSong.artist != '未知歌手') {
          job.draft.artist = hitSong.artist;
        }
        if (hitSong.artworkUri != null && hitSong.artworkUri!.isNotEmpty) {
          job.draft.coverUrl = normalizeCoverUrl(hitSong.artworkUri!);
        }
        // 搜索结果对「多歌手/多版本」的 artist_id 更准（详情接口常只给
        // singerinfo 首位），命中同 hash 时以搜索结果的 id 为准
        if (hitSong.artistId != null && hitSong.artistId!.isNotEmpty) {
          job.draft.artistId = hitSong.artistId!;
        }
        if (hitSong.albumId != null && hitSong.albumId!.isNotEmpty) {
          job.draft.albumId = hitSong.albumId!;
        }
        debugPrint('[ListenTogether] 搜索命中同歌: ${hit.hash} -> ${hitSong.title}');
      } else {
        debugPrint('[ListenTogether] 搜索未命中: ${job.query}');
      }
    } catch (e) {
      _refundMetadataAttempt(job.hash);
      job.searchFailed = true;
      debugPrint('[ListenTogether] 搜索异常(将重试): ${job.hash} $e');
    }
  }

  Future<void> _doEnrichMetadata() async {
    // 占位条目不在歌单里，必须显式带上：否则「远端歌单外曲目」的名称/封面
    // 永远补不上（表现为房间页长期显示「未知歌曲」）。
    final pendingRemote = _pendingRemoteSong;
    // 房主端待处理点歌：`song_order_list` 的 song_info 与歌单同源、同样不带封面
    // （歌单封面靠 search 二次补齐），不纳入富化则请求列表永远只有占位音符图。
    // 排在索引末尾：不改变既有「占位 → 歌单」的偏移约定，由 splitEnriched 的
    // extraCount 单独切出，避免混进 playlist 被下一次权威列表覆盖时凭空多出。
    final orderSongs =
        _isOwner ? songOrders.map((e) => e.song).toList() : const <RoomSong>[];
    final seed = <RoomSong>[
      ?pendingRemote,
      ...playlist,
      ...orderSongs,
    ];
    // 当前播放的曲目必须排在第一位处理（见 [prioritizeCurrentForEnrichment]）。
    final pending = seed
        .where((s) =>
            s.hash.isNotEmpty &&
            (s.name.isEmpty || s.singer.isEmpty || s.coverUrl.isEmpty) &&
            !_metadataExhausted(s.hash))
        .take(10)
        .toList();
    if (pending.isEmpty) return;
    final targets = prioritizeCurrentForEnrichment(
      pending,
      currentId: player.currentSong?.id,
    );
    for (final s in targets) {
      _bumpMetadataAttempt(s.hash);
    }
    debugPrint('[ListenTogether] 富化开始(批量): ${targets.map((s) => s.hash).join(',')}');
    try {
      final client = KugouApiClient();
      // ① 单次批量 /audio：hash 逗号拼接，一次请求补齐整批详情。
      //    原实现逐首 getSongDetail 串行（10 首 = 10 次串行 RTT），是封面
      //    加载慢的主因之一（对齐 EchoMusic getAudioMetadata 的批量形态）。
      final details = await client.getSongsDetails(
        targets.map((s) => s.hash).toList(),
      );
      final detailByHash = <String, KugouSongDetail>{
        for (final d in details)
          if (d.hash.isNotEmpty) d.hash.toLowerCase(): d,
      };
      final next = List<RoomSong>.from(seed);
      // ② 组装字段草稿；详情接口没有封面，仍缺封面的歌收集为搜索任务
      final drafts = <_EnrichDraft>[];
      final searchJobs = <_EnrichSearchJob>[];
      for (final s in targets) {
        final i = next.indexWhere((e) => identical(e, s));
        if (i < 0) continue;
        final detail = detailByHash[s.hash.toLowerCase()];
        if (detail == null) {
          // 查无详情多为瞬时抖动：退还本次尝试额度，下一轮轮询可重试
          _refundMetadataAttempt(s.hash);
          debugPrint('[ListenTogether] 富化失败(hash 查无详情): ${s.hash}');
          continue;
        }
        final song = detail.toSong();
        // 归一化：歌单/详情回包的封面可能带 {size} 占位符、http 明文或旧域名，
        // 原样下发 Image.network 必 404（「只有个别歌能显示封面」根因）。
        final coverUrl = normalizeCoverUrl(
          s.coverUrl.isNotEmpty ? s.coverUrl : (song.artworkUri ?? ''),
        );
        // 房间 hash 是 OGG 授权哈希，与搜索结果的标准版权哈希值不相等；
        // 必须用 /audio 回包的标准 hash（song.id）匹配（详见原实现注释）。
        final matchHashes = <String>{
          song.id.toLowerCase(),
          detail.hash.toLowerCase(),
          if (detail.hash128 != null) detail.hash128!.toLowerCase(),
          if (detail.hash320 != null) detail.hash320!.toLowerCase(),
          if (detail.hqHash != null) detail.hqHash!.toLowerCase(),
          if (detail.sqHash != null) detail.sqHash!.toLowerCase(),
        };
        matchHashes.removeWhere((h) => h.isEmpty);
        final draft = _EnrichDraft(
          title: song.title,
          artist: song.artist,
          coverUrl: coverUrl,
          artistId: s.artistId.isNotEmpty ? s.artistId : (song.artistId ?? ''),
          albumId: s.albumId.isNotEmpty ? s.albumId : (song.albumId ?? ''),
          mixSongId: s.mixSongId.isNotEmpty ? '' : (song.albumAudioId ?? ''),
          durationSeconds: s.durationSeconds > 0 ? 0 : song.duration.inSeconds,
          matchHashes: matchHashes,
        );
        drafts.add(draft);
        if (song.title.isNotEmpty || matchHashes.isNotEmpty) {
          searchJobs.add(_EnrichSearchJob(
            hash: s.hash,
            index: i,
            // 搜索词歌手归一：多歌手「、」连接整串在酷狗搜索命中率为 0，
            // 取首位歌手 + 歌名
            query: '${enrichSearchArtist(song.artist)} ${song.title}'.trim(),
            draft: draft,
          ));
        }
      }
      // ③ 有界并发搜索（并发 4）：原实现串行逐首 search，是封面慢的另一主因。
      //    每个任务独立容错：单首失败只退该歌额度，不影响整批。
      const searchConcurrency = 4;
      for (var start = 0; start < searchJobs.length; start += searchConcurrency) {
        final chunk = searchJobs.skip(start).take(searchConcurrency).toList();
        await Future.wait(chunk.map(_runEnrichSearchJob));
      }
      // ④ 统一写回（搜索失败的歌本轮不写，保留原值等下轮重试）
      var changed = false;
      for (final job in searchJobs) {
        if (job.searchFailed) continue;
        final d = job.draft;
        final s = next[job.index];
        // copyWith 的 null 语义是「保持原值」：原值优先的字段传 null
        next[job.index] = s.copyWith(
          mixSongId: s.mixSongId.isNotEmpty ? null : d.mixSongId,
          name: s.name.isNotEmpty ? null : d.title,
          singer: s.singer.isNotEmpty ? null : d.artist,
          durationSeconds: s.durationSeconds > 0 ? null : d.durationSeconds,
          coverUrl: d.coverUrl.isEmpty ? null : d.coverUrl,
          artistId: d.artistId.isEmpty ? null : d.artistId,
          albumId: d.albumId.isEmpty ? null : d.albumId,
        );
        changed = true;
        debugPrint('[ListenTogether] 富化成功: ${s.hash} -> ${d.title}/${d.artist} '
            'artistId=${d.artistId} albumId=${d.albumId} cover=${d.coverUrl.isNotEmpty}');
        // 封面仍未拿到时不销账：下一轮继续尝试（由尝试次数上限兜底）
        if (next[job.index].coverUrl.isNotEmpty) {
          _settleMetadataAttempt(s.hash);
          // 封面立即预取进原生缓存：回写触发 showNotification 时命中缓存秒显
          MediaNotificationService.prefetchCover([next[job.index].coverUrl]);
          _coverQueue.enqueueAll([next[job.index].coverUrl]);
        }
      }
      if (changed && !closed) {
        final split = splitEnriched(
          enriched: next,
          hasPending: pendingRemote != null,
          extraCount: orderSongs.length,
        );
        _pendingRemoteSong = split.pending;
        playlist = split.playlist;
        _patchSongOrdersMetadata(split.extra);
        _patchCurrentSongMetadata(<RoomSong>[
          ?_pendingRemoteSong,
          ...split.playlist,
        ]);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[ListenTogether] 富化异常: $e');
      // 异常可能来自网络抖动：退还本轮记账，下一轮重试
      for (final s in targets) {
        _refundMetadataAttempt(s.hash);
      }
      // 富化失败不回滚已建立的歌曲列表
    }
  }

  /// 富化记账：判断该 hash 是否已达尝试上限（达上限则不再作为目标）。
  bool _metadataExhausted(String hash) => _metadataAttempts.isExhausted(hash);

  /// 富化记账：消耗一次尝试额度（发起请求前调用）。
  void _bumpMetadataAttempt(String hash) => _metadataAttempts.bump(hash);

  /// 富化记账：退还一次尝试额度（请求失败 / 未拿到封面时调用，允许重试）。
  void _refundMetadataAttempt(String hash) => _metadataAttempts.refund(hash);

  /// 富化记账：销账（元数据已补齐，含封面，无需再试）。
  void _settleMetadataAttempt(String hash) => _metadataAttempts.settle(hash);

  /// 把富化结果回填到房主端待处理点歌条目（封面/歌名）。
  ///
  /// 按 hash 匹配而非下标：富化是异步的，期间点歌列表可能已被
  /// [_loadSongOrders] 整表替换、或条目已被处理掉。
  /// 富化草稿是**基于点歌条目自身的实例** copyWith 出来的，故 `identical` 命中
  /// 即代表本轮没有新信息，保持原实例，避免无谓重建与通知。
  void _patchSongOrdersMetadata(List<RoomSong> enriched) {
    if (songOrders.isEmpty || enriched.isEmpty) return;
    final byHash = <String, RoomSong>{
      for (final s in enriched)
        if (s.hash.isNotEmpty) s.hash.toLowerCase(): s,
    };
    var changed = false;
    final next = <OrderSongEntry>[];
    for (final entry in songOrders) {
      final richer = byHash[entry.song.hash.toLowerCase()];
      if (richer == null || identical(richer, entry.song)) {
        next.add(entry);
        continue;
      }
      next.add(entry.copyWithSong(richer));
      changed = true;
    }
    if (changed) {
      songOrders = next;
      debugPrint('[ListenTogether] 点歌条目元数据回填: '
          '${next.where((e) => e.song.coverUrl.isNotEmpty).length}/${next.length} 条带封面');
    }
  }

  /// 把富化结果回写到正在播放的歌曲。
  ///
  /// 听众端跟随播放的曲目只有 hash 身份（toSong 会把缺失名称兜底成
  /// 「未知歌曲」），房间页标题/封面读自 player.currentSong，
  /// 富化只更新 playlist 列表、不回写当前歌的话展示会一直空白。
  /// 匹配：hash/originalHash 忽略大小写，或 mixSongId 相同（身份形式
  /// 错位时 hash 比对会落空）。
  void _patchCurrentSongMetadata(List<RoomSong> songs) {
    final cur = player.currentSong;
    if (cur == null) return;
    final idLower = cur.id.toLowerCase();
    for (final s in songs) {
      final matched = s.hash.toLowerCase() == idLower ||
          (s.originalHash.isNotEmpty && s.originalHash.toLowerCase() == idLower) ||
          (s.mixSongId.isNotEmpty &&
              cur.albumAudioId != null &&
              cur.albumAudioId == s.mixSongId);
      if (!matched) continue;
      debugPrint('[ListenTogether] 回写当前歌元数据: hash=${s.hash} '
          'name=${s.name} singer=${s.singer} cover=${s.coverUrl.isNotEmpty} '
          'duration=${s.durationSeconds}s');
      // 逐字段覆盖策略见 patchSongFromRoomSong（含时长：起播时为 0，
      // 富化补齐后才能落到历史/通知/歌词渠道）。
      final patched = patchSongFromRoomSong(cur, s);
      if (patched == null) return;
      // 兜底预取：富化销账处已预取过则命中缓存直接跳过；走歌单字段
      // 直达回写（sync 窗口自带封面等路径）时仍能提前把封面送进缓存。
      // 必须在 updateCurrentSongMetadata 之前，让原生下载与 Dart 侧
      // 通知重建（_updateNotification → showNotification）并行起跑。
      if (s.coverUrl.isNotEmpty) {
        MediaNotificationService.prefetchCover([s.coverUrl]);
        _coverQueue.prioritize(s.coverUrl);
      }
      player.updateCurrentSongMetadata(patched);
      // 历史条目是起播瞬间的快照，此刻才拿到完整元数据：就地修正它。
      // 不用重新 _recordHistory —— 那会重复计数并把条目重排到最前。
      player.refreshHistoryEntry(patched);
      return;
    }
  }

  PlayerSyncState? _snapshotFrom(Map<String, dynamic> payload) {
    try {
      final snap = PlayerSyncState.fromJson(payload);
      return snap.hash.isEmpty ? null : snap;
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // 播放同步
  // =========================================================================

  Future<void> _syncPlayback({bool force = false}) async {
    if (closed) return;
    // 房主刚发出控制指令时跳过普通轮询，避免旧快照覆盖新操作
    final grace = _ownerGraceUntil;
    if (!force && _isOwner && grace != null && DateTime.now().isBefore(grace)) return;

    final revisionAtRequest = _ownerControlRevision;
    final Map<String, dynamic>? payload;
    try {
      payload = await _api.syncPlayer(roomId);
    } catch (e) {
      if (_handleDissolved(e)) return;
      rethrow;
    }
    if (closed || payload == null) return;
    if (!force && _isOwner && revisionAtRequest != _ownerControlRevision) return;

    final mapped = PlayerSyncState.fromJson(payload);
    // 进房首次同步取证：原始响应 + 解析结果配对打印。
    // 「成员进房从头播」要么是上游没给进度、要么是解析错位；只有这一对日志能区分。
    // 只打一次，避免 5s 轮询刷屏。
    if (!_loggedFirstSync) {
      _loggedFirstSync = true;
      final raw = payload.toString();
      debugPrint('[ListenTogether] sync_player 原始响应(截断1200): '
          '${raw.length > 1200 ? '${raw.substring(0, 1200)}…' : raw}');
      debugPrint('[ListenTogether] 首次快照解析: hash=${mapped.hash} '
          'mix=${mapped.mixSongId} playing=${mapped.isPlaying} '
          'progress=${mapped.progressMs}ms duration=${mapped.durationMs}ms '
          'updatedAt=${mapped.updatedAtMs} 本机now=${DateTime.now().millisecondsSinceEpoch} '
          'listVersion=${mapped.listVersion}');
    }
    if (mapped.hash.isNotEmpty &&
        (remoteState == null || mapped.updatedAtMs >= remoteState!.updatedAtMs)) {
      remoteState = mapped;
    }
    // 房主播放态自愈：服务端 pause 必须跟随房主本地的真实播放态（见下）
    if (_isOwner) _reconcileOwnerPlaybackState(mapped);
    final syncedVersion = readNestedString(payload, 'list_version');
    if (syncedVersion.isNotEmpty && syncedVersion != listVersion) {
      await _loadSongs(force: true);
      if (closed) return;
    }
    // 安全网：权威歌单为空（首次加载失败等）时跟随快轮询重试加载，直到拿到
    // 真实歌单为止。否则首次加载失败后 list_version 不变就不会再触发加载，
    // 歌单永远停留在空状态。重试节奏由 _loadSongs 的 _songsRetryAfterMs 退避。
    if (playlist.isEmpty) {
      await _loadSongs();
      if (closed) return;
    }
    // sync 响应中的 song_info 是「三首同步窗口」（上一首/当前/下一首），
    // **不是完整歌单**：权威歌单为空时先等它就绪（上面的安全网），然后只把
    // 窗口内的授权字段/元数据合并进**已有**条目。窗口条目不允许新增进列表
    // ——否则权威加载失败时歌单会退化成 3 首（「房间歌单只有三首」根因）。
    final syncedSongs = extractList(payload).map(RoomSong.fromJson).toList();
    if (syncedSongs.isNotEmpty && playlist.isNotEmpty) {
      // 变更判据用展示字段签名（mergeRoomSongPreferRicher 总是返回新实例，
      // 对象同一性恒为「有变化」，会让每轮轮询都误判并触发无谓重建/富化）
      String sig(RoomSong s) =>
          '${s.name}\u0001${s.singer}\u0001${s.coverUrl}\u0001${s.durationSeconds}\u0001${s.mixSongId}';
      var changed = false;
      final merged = <RoomSong>[];
      for (final s in playlist) {
        RoomSong next = s;
        for (final w in syncedSongs) {
          if (w.sameAs(s)) {
            next = mergeRoomSongPreferRicher(s, w);
            if (sig(next) != sig(s)) changed = true;
            break;
          }
        }
        merged.add(next);
      }
      if (changed) {
        playlist = merged;
        // sync 窗口（song_info 三首窗口）带回更富元数据时立即回写当前歌，
        // 不等后台富化完成（富化还要 detail+search 两个 RTT）。若窗口
        // 自带封面，通知栏封面可提前数秒出现；无封面时本调用被
        // patchSongFromRoomSong 的空值语义与 hasMetadataChanged 去重，
        // 无副作用。
        _patchCurrentSongMetadata(merged);
        unawaited(_enrichMetadataInBackground());
      }
    }
    await _applyRemotePlayback(force: force);
    notifyListeners();
  }

  /// 成员跟随远端播放状态。
  ///
  /// 房主跳过远端纠偏（本地是权威），只有跨设备恢复会话这种本地无歌
  /// 场景才按远端起播。房主切歌/seek/暂停由 ownerSwitchSong 等本地执行
  /// + 远端上报，不能被快照覆盖。
  ///
  /// 播放态（resume/pause）单独一道过滤（见 [shouldOwnerFollowRemotePlaying]）：
  /// 光靠 [_ownerGraceUntil] 3 秒宽限不足以防住回声——宽限一过，上报前的旧快照
  /// 仍可能被读到并触发 resume，表现为「房主暂停后又自动继续播放」。
  Future<void> _applyRemotePlayback({bool force = false}) async {
    // 脱离态只保持房间数据轮询，不接管本地播放器（对齐 EchoMusic）
    if (playbackDetached) return;
    final remote = remoteState;
    if (closed || remote == null || remote.hash.isEmpty) return;
    final heldSince = _applyingRemoteSince;
    if (heldSince != null) {
      final held = DateTime.now().difference(heldSince);
      if (held < kApplyRemoteStaleTimeout) return;
      // 卡死兜底：先把陈旧的锁显式释放掉，随后本次施加会重新占锁。
      // 上一次施加挂住时，成员会冻结在旧歌且之后不再有任何纠偏日志。
      debugPrint('[ListenTogether] 远端施加已卡住 ${held.inSeconds}s'
          '（阈值 ${kApplyRemoteStaleTimeout.inSeconds}s），强制放行以恢复同步');
      _applyingRemoteSince = null;
    }
    // 本地暂停只抑制「自动起播」，不能连换歌一起挡掉（见 decideSync 的优先级：
    // 换歌 > 听众本地暂停豁免）。过早 return 会让跟随端在房主换歌后仍停在旧歌，
    // 页面/通知/胶囊全部滞后。
    final locallyPaused = guestLocallyPaused && !_isOwner;
    final ownerLocalHasSong = (_isOwner && (player.currentSong?.id.isNotEmpty ?? false));
    if (_isOwner) {
      // 房主刚发出控制指令时跳过普通轮询，避免旧快照覆盖新操作；
      // 宽限期过后恢复跟随（同歌时进度纠偏仍需对齐）
      final grace = _ownerGraceUntil;
      if (!force && grace != null && DateTime.now().isBefore(grace)) return;
      // 房主本地有歌时只做进度纠偏，不触发换歌（切歌走 ownerSwitchSong）
      final decision = decideSync(
        localHash: player.currentSong?.id,
        localMixSongId: player.currentSong?.albumAudioId,
        localPlaying: player.platformIsPlaying,
        // 用平台真实位置：_position 会被起播对齐乐观写入成目标值，
        // 拿它比较会得出「已对齐」的假结论（见 PlayerProvider.platformPosition）。
        localPositionMs: player.platformPosition.inMilliseconds,
        remote: remote,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (decision.action == SyncAction.switchSong) return;
    }

    _applyingRemoteSince = DateTime.now();
    try {
      // 本地音源已死（解析失败）时的补救：重装载房间曲目，别停在旧歌/哑火状态。
      // 放在决策之前并 return——本轮由重装载接管（_followRemoteSong 自带对齐段）。
      final currentLocal = player.currentSong;
      final sameLocalSong = currentLocal != null &&
          RoomSong.fromSong(currentLocal).matchesRemote(remote);
      final nowMsForReload = DateTime.now().millisecondsSinceEpoch;
      if (!_isOwner &&
          shouldReloadUnavailableRoomSource(
            remotePlaying: remote.isPlaying,
            sameSong: sameLocalSong,
            resolveError: player.resolveError,
            nowMs: nowMsForReload,
            retryAfterMs: _unavailableReloadAfterMs,
          )) {
        _unavailableReloadAfterMs =
            nowMsForReload + kPlaybackRetryBackoff.inMilliseconds;
        debugPrint('[ListenTogether] 本地音源不可用（${player.resolveError}），'
            '重装载房间曲目 hash=${remote.hash}');
        unawaited(_followRemoteSong(remote));
        return;
      }
      var decision = decideSync(
        localHash: player.currentSong?.id,
        localMixSongId: player.currentSong?.albumAudioId,
        // 播放态用平台真实值而非 Dart 乐观缓存：缓存被平台事件写脏时会
        // 把「房间在播、本机其实已停」判成「双方都在播」，本轮只做进度纠偏
        // 而不起播 → 听众永久停在暂停（「房主恢复播放听众不恢复」根因之一）。
        localPlaying: player.platformIsPlaying,
        // 用平台真实位置：_position 会被起播对齐乐观写入成目标值，
        // 拿它比较会得出「已对齐」的假结论（见 PlayerProvider.platformPosition）。
        localPositionMs: player.platformPosition.inMilliseconds,
        remote: remote,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        guestLocallyPaused: force ? false : locallyPaused,
        force: force,
      );
      if (!_isOwner &&
          (force || decision.action != SyncAction.none)) {
        debugPrint('[ListenTogether][Resume] 听众决策: action=${decision.action} '
            'force=$force localPlaying=${player.platformIsPlaying} '
            'localPos=${player.platformPosition.inMilliseconds}ms '
            'remotePlaying=${remote.isPlaying} remoteProgress=${remote.progressMs}ms '
            'remoteUpdated=${remote.updatedAtMs} now=${DateTime.now().millisecondsSinceEpoch} '
            '投影=${projectRemotePosition(remote, DateTime.now().millisecondsSinceEpoch)}ms');
      }
      // 房主不采纳远端播放态：他自己的暂停/播放已上报，快照回传只是回声，
      // 按回声做 resume/pause 会让「暂停后又自动继续播放」（见函数文档）
      if (decision.action == SyncAction.resume || decision.action == SyncAction.pause) {
        if (!shouldOwnerFollowRemotePlaying(localHasSong: ownerLocalHasSong)) {
          debugPrint('[ListenTogether] 房主忽略远端播放态回声: '
              '${decision.action} / 远端 playing=${remote.isPlaying} '
              '本地 playing=${player.platformIsPlaying}');
          decision = const SyncDecision(SyncAction.none);
        }
      }
      // 诊断（边沿触发，同一原因只打一次）：房间在播、本机却没在播、且本轮
      // 判定不动作时，把挡下恢复的守卫打出来。「房主恢复播放听众不恢复」只可能
      // 由这两条守卫造成，真机日志可一锤定音（见 PITFALLS 铁律 7：以日志为准）。
      if (!_isOwner && remote.isPlaying && !player.platformIsPlaying) {
        if (decision.action == SyncAction.resume ||
            decision.action == SyncAction.switchSong) {
          _resumeBlockReason = null;
        } else {
          final reason =
              'guestLocallyPaused=$locallyPaused detached=$playbackDetached';
          if (_resumeBlockReason != reason) {
            _resumeBlockReason = reason;
            debugPrint('[ListenTogether][Resume] 房间在播但本机未播放且本轮无动作: $reason');
          }
        }
      } else {
        _resumeBlockReason = null;
      }
      switch (decision.action) {
        case SyncAction.switchSong:
          debugPrint('[ListenTogether] 判定换歌: 远端 hash=${remote.hash} '
              'mix=${remote.mixSongId} / 本地 id=${player.currentSong?.id} '
              'mix=${player.currentSong?.albumAudioId}');
          // 不 await：_followRemoteSong 内含对齐循环（最长 15s），内联等待
          // 会占住 _fastInFlight，饿死后续 5s 轮询——「切歌后 15s 无任何
          // 听众决策日志」的根因。装载与对齐交由其内部自主完成。
          unawaited(_followRemoteSong(remote, startPaused: locallyPaused));
        case SyncAction.seek:
          final target = decision.targetPositionMs ?? remote.progressMs;
          debugPrint('[ListenTogether] 进度纠偏: 本地=${player.position.inMilliseconds}ms '
              '目标=${target}ms 偏差=${target - player.position.inMilliseconds}ms '
              '远端playing=${remote.isPlaying} updatedAt=${remote.updatedAtMs}');
          await _seekToRemote(
            remote,
            target,
          );
        case SyncAction.resume:
          // 恢复跟随：force 路径（听众显式恢复）先按最新投影校准再恢复——
          // 暂停态源已就绪、seek 可靠，让「恢复播放」直接从房主当前位置
          // 继续，而不是从本机暂停位置续播后再等下一轮 5s 轮询纠偏。
          // 非 force（轮询自动恢复）保持原语义，不额外 seek。
          if (force) {
            final projectedMs = projectRemotePosition(
              remote,
              DateTime.now().millisecondsSinceEpoch,
            );
            final localMs = player.platformPosition.inMilliseconds;
            if ((projectedMs - localMs).abs() > kForceSyncDriftToleranceMs) {
              debugPrint('[ListenTogether][Resume] 恢复跟随校准: 本地=${localMs}ms '
                  '→ 投影=${projectedMs}ms（领先补偿前）');
              await _seekToRemote(remote, projectedMs);
            }
          }
          // 纠偏不是用户意图：走 notifyRoom:false 内部通道，不触发房间通告。
          // 不能用 suppressPlaybackNotify 包公开 pause/resume——纠偏 seek 的
          // 抑制窗口可达数秒（在线源 seek 需重新缓冲），期间用户真实的暂停/
          // 恢复通告会被一并吞掉（实测：听众暂停被吞 → 豁免不登记 → 轮询
          // 把用户拉回播放，无限拉锯）。
          await player.resume(notifyRoom: false);
        case SyncAction.pause:
          await player.pause(notifyRoom: false);
        case SyncAction.none:
          break;
      }
    } catch (e) {
      debugPrint('[ListenTogether] apply remote playback failed: $e');
    } finally {
      _applyingRemoteSince = null;
      // 动作期间远端可能已前进（服务端换歌 / 新快照到达）：立即再应用一次，
      // 不必等下一轮快轮询。判据基于「本次施加的快照」而非上次轮询，无自激风险。
      if (!closed && shouldReapplyAfterApply(applied: remote, latest: remoteState)) {
        debugPrint('[ListenTogether] 动作期间远端已前进，立即补应用一次');
        scheduleMicrotask(() => unawaited(_applyRemotePlayback()));
      }
    }
  }

  /// 房主播放态与服务端一致性自愈。
  ///
  /// 房主是播放权威：服务端的 `pause` 必须跟随房主本地真实播放态。上报一旦
  /// 丢失（网络抖动、指令被后续控制覆盖）或上游写入未生效，服务端会**永久**
  /// 停在旧值，听众随即停在「房主已恢复播放但房间仍是暂停」——这正是
  /// 「房主暂停后再点恢复，听众有概率不恢复」的可见故障。
  ///
  /// 判据与节奏：
  ///   - 只在**同歌身份**下比对（换歌瞬间上游 pause 与本地短暂不一致属正常）；
  ///   - 控制宽限期内不比对（刚发出的指令尚未回传，读到旧值属传播延迟）；
  ///   - 单轮不动作，**连续两轮**（≥10s）仍不一致才按本地补报，避免与传播延迟
  ///     打架、避免自激；补报后重新计时。
  ///   - 比对用 [PlayerProvider.platformIsPlaying]（平台真实态）而非乐观缓存：
  ///     缓存被平台事件写脏时按缓存补报，会把房主真实的暂停又改回播放。
  void _reconcileOwnerPlaybackState(PlayerSyncState remote) {
    if (closed || !_isOwner || remote.hash.isEmpty) return;
    final grace = _ownerGraceUntil;
    if (grace != null && DateTime.now().isBefore(grace)) {
      _ownerPlayMismatch = false;
      return;
    }
    final current = player.currentSong;
    final localId = current?.id ?? '';
    final sameSong = localId.isNotEmpty &&
        (localId.toLowerCase() == remote.hash.toLowerCase() ||
            (current?.albumAudioId != null &&
                remote.mixSongId.isNotEmpty &&
                current?.albumAudioId == remote.mixSongId));
    final localPlaying = player.platformIsPlaying;
    if (!sameSong || localPlaying == remote.isPlaying) {
      _ownerPlayMismatch = false;
      return;
    }
    if (!_ownerPlayMismatch) {
      _ownerPlayMismatch = true;
      debugPrint('[ListenTogether][OwnerSync] 播放态与服务端不一致(第1轮): '
          '本地=$localPlaying 服务端=${remote.isPlaying}，下一轮仍不一致则补报');
      return;
    }
    _ownerPlayMismatch = false;
    debugPrint('[ListenTogether][OwnerSync] 播放态连续两轮不一致，按本地补报 '
        'playing=$localPlaying');
    ownerSetPlaying(localPlaying);
  }

  /// 播放房间歌曲：优先房间授权地址，私有格式或失败时回退常规解析链。
  ///
  /// **不带定位参数**：跟随对齐由 [_followRemoteSong] 的对齐段按最新快照
  /// 完成（两段式起播）；房主切歌则从 0 起播（房主是播放权威）。
  Future<void> _playRoomSong(RoomSong target) async {
    // 记录接管目标身份：守卫回调据此区分「房间自己的装载」与「用户点击其他
    // 歌曲」（见 [_takeoverTarget] 文档）。
    _takeoverTarget = target;
    final playbackHash =
        target.originalHash.isNotEmpty ? target.originalHash : target.hash;
    final retryKey = '$playbackHash:${target.mixSongId}';
    final now = DateTime.now().millisecondsSinceEpoch;
    String authorizedUrl = '';

    if (now >= (_playbackRetryAfterMs[retryKey] ?? 0)) {
      try {
        final resp = await _api.playbackUrl(
          roomId: roomId,
          hash: playbackHash,
          mixSongId: target.mixSongId,
        );
        // 候选可能不止一条：挑第一个本机可解码的，而不是「第一个是私有格式
        // 就整条放弃」（见 [collectNestedStringValues] 文档）。
        final candidates = resp == null ? const <String>[] : collectNestedStringValues(resp, 'url');
        authorizedUrl = pickPlayableRoomAudioUrl(candidates);
        if (authorizedUrl.isEmpty) {
          debugPrint('[ListenTogether] 房间授权地址不可用（候选 ${candidates.length} 条'
              '${candidates.isEmpty ? '' : '，首条=${candidates.first}'}），回退常规解析链');
        }
      } catch (e) {
        debugPrint('[ListenTogether] playback_url failed: $e');
      }
      if (authorizedUrl.isEmpty) {
        _playbackRetryAfterMs[retryKey] =
            now + kPlaybackRetryBackoff.inMilliseconds;
      } else {
        _playbackRetryAfterMs.remove(retryKey);
      }
    }

    debugPrint('[ListenTogether] 起播下发: hash=${target.hash} '
        'authorized=${authorizedUrl.isNotEmpty}');
    // 接管起播窗口：playSong 内部会同步回调房间守卫，置位标志让听众分支的
    // detach 判定放行（见 _roomTakeoverPlayback 文档），finally 确保复位。
    _roomTakeoverPlayback = true;
    try {
      await player.playSong(target.toSong(playUrl: authorizedUrl));
    } finally {
      _roomTakeoverPlayback = false;
    }
  }

  /// 成员跟随换歌：优先使用房间授权地址，失败或私有格式时回退常规解析。
  ///
  /// [startPaused] 为 true 表示听众本机正处于暂停（不自动起播）。
  Future<void> _followRemoteSong(PlayerSyncState remote, {bool startPaused = false}) async {
    // 命中歌单用歌单条目（带房间授权字段）；未命中的远端曲目用独立占位条目，
    // 不污染权威列表（见 [_pendingRemoteSong] 文档）。
    final target = resolveFollowTarget(playlist: playlist, remote: remote);

    // 同一目标的跟随装载已在途 → 不再重复起播（对齐 EchoMusic `applyingPlayback`
    // 的互斥语义，其注释原话：「多个首次同步调用同时在等待歌单…避免它们同时进入
    // playTrack，反复替换同一个原生音源」）。
    //
    // 本函数是 unawaited 调用（不能让 15s 对齐循环饿死 _fastInFlight），而
    // _playRoomSong 里 playbackUrl 的网络往返与 playOnlineSong 的解析链都发生在
    // `player.currentSong` 落定**之前** → 这期间下一轮快轮询会再次判定「换歌」并
    // 重复起播：两次 _issuePlaybackRequest 互相作废、原生音源被反复替换，切歌
    // 表现为「有概率不跟随」。
    final followKey = '${target.song.hash.toLowerCase()}:${target.song.mixSongId}';
    if (_followInFlightKey == followKey) {
      debugPrint('[ListenTogether] 跟随装载已在途，跳过重复起播: $followKey');
      return;
    }
    _followInFlightKey = followKey;
    _pendingRemoteSong = target.fromPlaylist ? null : target.song;
    try {
      await _runFollowRemoteSong(target, remote, startPaused: startPaused);
    } finally {
      // 只有仍是本次登记的目标才清空：更新的换歌可能已接管
      if (_followInFlightKey == followKey) _followInFlightKey = null;
    }
  }

  /// [_followRemoteSong] 的实际实现（已过在途互斥）。
  Future<void> _runFollowRemoteSong(
    FollowTarget target,
    PlayerSyncState remote, {
    bool startPaused = false,
  }) async {
    // **两段式起播（对齐 EchoMusic）**：
    // ① 装载段：**不带 initialPosition** 下发装载，且**不等待 playSong 的
    //    Future**——实测 just_audio 的 setAudioSource 在冷 CDN 源上 11s+ 才
    //    回包（音频 ~1s 内就开始播），等它会让对齐推迟整整一个缓冲周期
    //    （「进房同步延迟」的直接原因）。改用 ② 的 isPlaybackNotReady 翻转
    //    判定源就绪。装载错误由 playOnlineSong 内部 catch 落到 _resolveError。
    debugPrint('[ListenTogether] 跟随起播（两段式·装载）: hash=${remote.hash} '
        'inPlaylist=${target.fromPlaylist} playing=${remote.isPlaying} '
        'progress=${remote.progressMs}ms updatedAt=${remote.updatedAtMs}');
    unawaited(
      _playRoomSong(target.song).catchError((Object e) {
        debugPrint('[ListenTogether] 装载失败: $e');
      }),
    );

    // ② 对齐段：等「旧源 ready → 新源 loading」的翻转开始，再等 loading →
    //    ready 完成，源一就绪**立刻**按最新快照对齐（不再被装载 Future 拖到
    //    就绪后 11s）。走 _seekToRemote：EWMA 领先补偿 + 幂等键，一次精确
    //    跳转。装载期间又换歌（currentSong 被顶掉）则放弃，交给补应用。
    bool playingTarget() {
      final cur = player.currentSong;
      if (cur == null) return false;
      return RoomSong.fromSong(cur).sameAs(target.song);
    }

    var sawLoading = false;
    final startedAt = DateTime.now();
    final deadline = startedAt.add(const Duration(seconds: 15));
    while (!closed && DateTime.now().isBefore(deadline)) {
      final ready = !player.isPlaybackNotReady;
      if (!ready) sawLoading = true;
      // 退出条件：源就绪且当前歌仍是目标歌。观察过 loading 翻转即可退出；
      // 极快装载（本地缓存命中）可能观察不到翻转，以「已等待 ≥1s」兜底，
      // 避免空等到 15s 超时。
      if (ready &&
          playingTarget() &&
          (sawLoading ||
              DateTime.now().isBefore(startedAt.add(const Duration(seconds: 1))) ==
                  false)) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
    if (closed || !playingTarget()) return;

    // 对齐：最新快照投影期望位置，与平台实际位置差 >1s（roomStartSeekTarget
    // 同款阈值）才 seek；快照已切到别的歌则交给补应用走完整换歌流程。
    final latest = remoteState;
    if (latest != null &&
        latest.hash.isNotEmpty &&
        target.song.matchesRemote(latest) &&
        !player.isPlaybackNotReady) {
      final expectedMs = projectRemotePosition(
        latest,
        DateTime.now().millisecondsSinceEpoch,
      );
      final actualMs = player.platformPosition.inMilliseconds;
      if (expectedMs > 1000 && (expectedMs - actualMs).abs() > 1000) {
        debugPrint('[ListenTogether] 起播对齐（最新快照）: '
            '本地=${(actualMs / 1000).toStringAsFixed(1)}s '
            '目标=${(expectedMs / 1000).toStringAsFixed(1)}s '
            '快照龄=${DateTime.now().millisecondsSinceEpoch - latest.updatedAtMs}ms');
        await _seekToRemote(latest, expectedMs);
      }
    }
    if (closed) return;
    // 装载完成即刻纠正播放态（不等 5s 轮询）：快照必须匹配目标歌才采信，
    // 匹配不上（快照已又切歌/为空）不盲动——playSong 已下发 play，盲暂停
    // 会杀掉新歌（「切歌后不能续播」根因）。恢复走 notifyRoom:false 内部
    // 通道避免回声上报；源未就绪时放弃本轮纠正，交给轮询兜底。
    final latestMatches = latest != null &&
        latest.hash.isNotEmpty &&
        target.song.matchesRemote(latest);
    final action = resolveFollowLoadPlayback(
      startPaused: startPaused,
      latestIsPlaying: latestMatches ? latest.isPlaying : null,
      localPlaying: player.isPlaying,
    );
    switch (action) {
      case FollowLoadAction.pause:
        await player.pause(notifyRoom: false);
      case FollowLoadAction.play:
        // 不做 isPlaybackNotReady 门控：两段式装载源设置即下发 play，
        // playWhenReady 会在源就绪时自动起播；此处的 resume 是纠偏兜底，
        // 未就绪时 just_audio 的 resume 只是置 playWhenReady=true（排队生效），
        // 拦掉它反而让「装载完成但无人恢复」卡住（fastPoll 已不再被饿死，
        // 但仍多等一轮 5s）。
        await player.resume(notifyRoom: false);
      case FollowLoadAction.none:
        break;
    }
    // 起播后立即触发一次元数据补齐：歌单内条目同样可能缺名称/封面。
    // 此前仅 !fromPlaylist 触发，歌单内占位条目要等下一轮 5s 快轮询、
    // 且仅当 sync 窗口 merge 使 sig 变化才会补 → 封面最坏延迟 5s+。
    // 幂等由 _enrichInFlight 互斥、MetadataAttemptTracker 额度与
    // hasMetadataChanged 回写去重共同保证，重复触发无副作用。
    unawaited(_enrichMetadataInBackground());
  }

  Future<void> _seekToRemote(PlayerSyncState remote, int targetMs) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = buildSeekKey(
      roomId: roomId,
      hash: remote.hash,
      updatedAtMs: remote.updatedAtMs,
      positionMs: targetMs,
    );
    // 就绪检查与幂等键登记必须成对：未就绪时直接返回，**不登记** key，
    // 让下一次轮询（新快照 → 新 key，或同 key 但已过窗口）重新纠偏。
    if (!shouldApplyRemoteSeek(
      targetMs: targetMs,
      playbackReady: !player.isPlaybackNotReady,
      seekKey: key,
      lastSeekKey: _lastSeekKey,
      nowMs: now,
      lastSeekAtMs: _lastSeekAt,
    )) {
      debugPrint('[ListenTogether][Resume] seek 被门控拦截: target=${targetMs}ms '
          'ready=${!player.isPlaybackNotReady} sameKey=${_lastSeekKey == key} '
          'sinceLastSeek=${now - _lastSeekAt}ms');
      return;
    }
    _lastSeekKey = key;
    _lastSeekAt = now;
    // 领先补偿：seek 生效期间播放器继续走，目标提前一个估计延迟（仅播放中）。
    // 幂等键按未补偿的 targetMs 登记，补偿值变化不会破坏幂等窗口。
    final effectiveMs = remote.isPlaying
        ? targetMs + seekLatencyLeadMs(_remoteSeekLatencyMs)
        : targetMs;
    final stopwatch = Stopwatch()..start();
    try {
      // 纠偏不是用户意图：抑制通告，否则房主会把纠偏当成自己的拖动再上报一次，
      // 成员会因 onSeekedByUser 触发自激的复同步。
      await player.suppressPlaybackNotify(
        () => player.seek(Duration(milliseconds: effectiveMs)),
      );
    } finally {
      stopwatch.stop();
      _remoteSeekLatencyMs =
          updateSeekLatencyEwma(_remoteSeekLatencyMs, stopwatch.elapsedMilliseconds);
    }
  }

  // =========================================================================
  // 房间详情 / 成员 / 聊天 / 点歌
  // =========================================================================

  Future<void> _loadDetail() async {
    if (closed) return;
    try {
      final payload = await _api.roomDetail(roomId);
      if (payload == null || closed) return;
      // detail 返回的是**单个房间对象**（data 直为对象，不是数组），
      // extractList 取不到 → 退化解 data 包裹直接读；列表形式仍然兼容。
      final list = extractList(payload);
      final rec = list.isNotEmpty
          ? list.first
          : (asRecord(unwrapListenPayload(payload)) ?? const <String, dynamic>{});
      if (rec.isNotEmpty) {
        final brief = MusicRoomBrief.fromJson(rec);
        if (brief.closed) {
          throw ListenTogetherApiError('房间已解散', 20005, payload);
        }
        // 人数上限以服务端为准（创建时客户端值仅作即时展示）
        if (brief.capacity > 0 && brief.capacity != capacity) {
          capacity = brief.capacity;
          notifyListeners();
        }
        // 聊天开关随详情刷新（仅变化时赋值并通知，避免空转重建）
        final detailAllowChat = brief.allowChat == 1;
        if (detailAllowChat != allowChat) {
          allowChat = detailAllowChat;
          notifyListeners();
        }
        // 房主：众乐房详情把房主身份直给在 data 顶层（userid / nick_name），
        // 不包在 user_info 里，因此 brief.ownerId 常为空——必须回退直读，
        // 否则成员面板永远注入不了房主（听众接口不含房主）。
        final ownerId = brief.ownerId.isNotEmpty
            ? brief.ownerId
            : readString(rec, const [
                'userid',
                'owner_id',
                'ownerid',
                'create_userid',
              ]);
        final ownerNick = (brief.ownerName.isNotEmpty && brief.ownerName != '房主')
            ? brief.ownerName
            : readString(rec, const ['nick_name', 'nickname', 'owner_name']);
        // 房主头像：detail 的 data.user_pic 是唯一来源（成员接口不含房主，
        // RoomMember.fromJson 的同名字段在注入路径上无从生效）。
        final ownerAvatar = readString(rec, const [
          'user_pic',
          'userpic',
          'owner_pic',
          'avatar',
          'headimg',
          'img',
        ]);
        // 记录房主信息（成员面板注入房主用；听众接口不返回房主）
        if (ownerId.isNotEmpty) {
          ownerUserId = ownerId;
          if (ownerNick.isNotEmpty) ownerName = ownerNick;
          if (ownerAvatar.isNotEmpty) _ownerAvatar = ownerAvatar;
          // 成员已先于详情返回时立即补房主，并同步快照避免被误判为「刚加入」。
          // 注意两种时序：成员晚于详情 → 长度变化（新增）；成员早于详情 →
          // 长度不变但房主头像可能刚从空变非空，必须就地回填，否则永久留空。
          final backfilled = backfillOwnerAvatar(
            members,
            ownerUserId: ownerUserId,
            ownerAvatar: _ownerAvatar,
          );
          final merged = ensureSelfInMembers(
            backfilled,
            selfUserId,
            nickname: selfNickname,
            avatar: selfAvatar,
            ownerUserId: ownerUserId,
            ownerName: ownerName,
            ownerAvatar: _ownerAvatar,
          );
          if (!identical(merged, members)) {
            members = merged;
            if (_memberSnapshotRoomId == roomId && _memberSnapshot.isNotEmpty) {
              _memberSnapshot = {for (final m in merged) m.userId: m};
            }
            notifyListeners();
          }
        }
        // 房主身份以 ownerId 与自身 userid 比对校正（跨设备恢复场景）
        if (ownerId.isNotEmpty && selfUserId.isNotEmpty) {
          final ownerNow = ownerId == selfUserId;
          if (ownerNow != _isOwner) {
            _isOwner = ownerNow;
            notifyListeners();
          }
        }
      }
    } catch (e) {
      if (_handleDissolved(e)) return;
      // 详情失败不阻塞，慢轮询会重试
    }
  }

  Future<void> _loadMembers() async {
    if (closed) return;
    final revision = ++_memberLoadRevision;
    final List<Map<String, dynamic>> raw;
    try {
      final payload = await _api.members(roomId);
      raw = extractList(payload);
    } catch (e) {
      if (_handleDissolved(e)) return;
      return;
    }
    if (closed || revision != _memberLoadRevision) return;

    // 听众接口不含房主本人：缺失时把房主与本地账号补进列表（在快照对比前
    // 注入，保证自己不会在后续轮询中被误判为「离开房间」）
    var next = raw.map(RoomMember.fromJson).where((m) => m.userId.isNotEmpty).toList();
    next = ensureSelfInMembers(
      next,
      selfUserId,
      nickname: selfNickname,
      avatar: selfAvatar,
      ownerUserId: ownerUserId,
      ownerName: ownerName,
      ownerAvatar: _ownerAvatar,
    );
    final nextSnapshot = {for (final m in next) m.userId: m};

    // 对比上一次快照，本地合成成员进出系统消息（首次只建基线）
    if (_memberSnapshotRoomId == roomId && _memberSnapshot.isNotEmpty) {
      final detectedAt = DateTime.now().millisecondsSinceEpoch;
      final presence = <ChatMessage>[];
      for (final entry in nextSnapshot.entries) {
        if (_memberSnapshot.containsKey(entry.key)) continue;
        presence.add(ChatMessage(
          id: 'presence:4001:${entry.key}:$detectedAt',
          userId: entry.key,
          text: '${entry.value.nickname}已加入一起听',
          nickname: entry.value.nickname,
          avatar: entry.value.avatar,
          type: 4001,
          timestampMs: detectedAt,
          isSystem: true,
        ));
      }
      for (final entry in _memberSnapshot.entries) {
        if (nextSnapshot.containsKey(entry.key)) continue;
        presence.add(ChatMessage(
          id: 'presence:4002:${entry.key}:$detectedAt',
          userId: entry.key,
          text: '${entry.value.nickname} 离开了房间',
          nickname: entry.value.nickname,
          avatar: entry.value.avatar,
          type: 4002,
          timestampMs: detectedAt,
          isSystem: true,
        ));
      }
      if (presence.isNotEmpty) _mergeMessages(presence);
    }
    _memberSnapshotRoomId = roomId;
    _memberSnapshot = nextSnapshot;
    members = next;
    notifyListeners();
  }

  Future<void> _loadMessages() async {
    if (closed) return;
    final List<Map<String, dynamic>> raw;
    try {
      final payload = await _api.chatHistory(roomId);
      raw = extractList(payload);
    } catch (e) {
      if (_handleDissolved(e)) return;
      return;
    }
    if (closed) return;
    _mergeMessages(
      raw.map(ChatMessage.fromJson).where((m) => m.text.isNotEmpty).toList(),
    );
  }

  /// 按 id 去重、按时间升序、进出房消息 30 秒内同用户去重、总量限 200。
  ///
  /// 上游每条消息都带房间标签（`rm_1009:<房间号>`）。若账号仍持有上一个房间的
  /// 服务端会话，请求新房间时上游可能按会话返回原房间的群聊；这里按标签剔除，
  /// 保证聊天面板只呈现当前房间的消息。
  void _mergeMessages(List<ChatMessage> incoming) {
    final scoped = scopeMessagesToRoom(incoming, roomId);
    if (scoped.isEmpty) return;
    final byId = <String, ChatMessage>{for (final m in messages) m.id: m};
    for (final m in scoped) {
      byId.putIfAbsent(m.id, () => m);
    }
    var sorted = byId.values.toList()..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    final presence = <ChatMessage>[];
    sorted = sorted.where((m) {
      if ((m.type != 4001 && m.type != 4002) || m.userId.isEmpty) return true;
      final duplicated = presence.any((e) =>
          e.type == m.type &&
          e.userId == m.userId &&
          (e.timestampMs - m.timestampMs).abs() <= 30000);
      if (duplicated) return false;
      presence.add(m);
      return true;
    }).toList();
    if (sorted.length > kMaxMessages) {
      sorted = sorted.sublist(sorted.length - kMaxMessages);
    }
    messages = sorted;
    // 首次见到非空消息列表（进房历史拉取完成）：把历史基线记为已读，
    // 之后到达的消息才计为未读（见 hasUnreadChatMessages）。
    _lastSeenChatMessageId ??= sorted.last.id;
    notifyListeners();
  }

  Future<void> _loadSongOrders() async {
    if (closed || !_isOwner) return;
    try {
      final payload = await _api.songOrderList(roomId);
      if (closed || payload == null) return;
      songOrders = extractList(payload)
          .map(OrderSongEntry.fromJson)
          .where((e) => e.song.hash.isNotEmpty)
          .toList();
      notifyListeners();
      // 新请求到达立刻补齐封面（与歌单封面同一条富化链路）：只等慢轮询或
      // 歌单变更触发的话，请求会挂在列表里最长一轮才出封面。
      // 幂等由 _enrichInFlight 互斥 + 目标过滤（已补齐的不再入选）保证。
      unawaited(_enrichMetadataInBackground());
    } catch (e) {
      if (_handleDissolved(e)) return;
    }
  }

  // =========================================================================
  // 对外动作
  // =========================================================================

  /// 发送聊天消息。
  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || closed) return;
    final content =
        trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
    try {
      final resp = await _api.sendChat(
        roomId: roomId,
        text: content,
        nickname: selfNickname,
        avatar: selfAvatar,
      );
      debugPrint('[ListenTogether] 聊天发送响应: '
          '${resp == null ? 'null' : 'status=${resp['status']} err=${resp['error_code']}'}');
    } on ListenTogetherApiError catch (e) {
      // 带上上游原始响应体：业务错误码（如 30002）需要看 payload 才能定位
      debugPrint('[ListenTogether] 聊天发送失败: $e payload=${e.payload}');
      rethrow;
    } catch (e) {
      debugPrint('[ListenTogether] 聊天发送失败: $e');
      rethrow;
    }
    await _loadMessages();
  }

  /// 成员点歌互斥：防连点重复提交。
  bool _ordering = false;

  /// 成员点歌（带互斥：防连点重复提交）。
  Future<void> orderSong(RoomSong song) async {
    if (song.hash.isEmpty || _ordering || closed) return;
    _ordering = true;
    try {
      await _api.orderSong(roomId: roomId, hash: song.hash, mixSongId: song.mixSongId);
      showToast('已点播「${song.name}」，等待房主允许加歌');
    } catch (_) {
      showToast('点歌失败，请稍后重试');
      rethrow;
    } finally {
      _ordering = false;
    }
  }

  /// 房主把歌曲加入歌单。
  /// [orderUserId] 非空表示通过该成员的点歌请求。
  Future<void> ownerAddSongs(List<RoomSong> songs, {String? orderUserId}) async {
    if (closed || !_isOwner || songs.isEmpty) return;
    final valid = songs.where((s) => s.hash.isNotEmpty).toList();
    if (valid.isEmpty) return;
    _markOwnerControl();
    await _api.musicAdd(
      roomId: roomId,
      audios: valid.map((s) => {'hash': s.hash, 'mixsongid': s.mixSongId}).toList(),
      listVersion: listVersion,
      orderUserId: orderUserId,
      progressInfo: _currentProgressInfo(),
    );
    if (closed) return;
    await _loadSongs(force: true);
    // 批量加歌/通过点歌后立即重拉点歌列表，让「通过」后的请求即时消失
    unawaited(_loadSongOrders());
    if (orderUserId != null && orderUserId.isNotEmpty) {
      songOrders.removeWhere((e) => valid.any((s) => e.song.sameAs(s)));
    }
    showToast(valid.length == 1 ? '已加入「${valid.first.name}」' : '已加入 ${valid.length} 首歌曲');
    notifyListeners();
  }

  /// 房主忽略一条点歌请求。
  Future<void> ownerRemoveOrder(OrderSongEntry entry) async {
    if (closed || !_isOwner) return;
    await _api.removeSong(
      roomId: roomId,
      hash: entry.song.hash,
      mixSongId: entry.song.mixSongId,
      orderUserId: entry.orderUserId,
    );
    songOrders.removeWhere((e) => identical(e, entry));
    showToast('已忽略这条点歌请求');
    notifyListeners();
  }

  /// 手动刷新房间歌单：清元数据记账与 30009 退避后强制重拉
  /// （对齐 EchoMusic refreshRoomSongs——不清记账的话，早先耗尽额度的
  /// 歌曲封面永远补不上）。
  Future<void> refreshSongs() async {
    if (closed) return;
    _metadataAttempts.reset();
    _songsRetryAfterMs = 0;
    await _loadSongs(force: true);
  }

  /// 房主切歌：本地立即播放目标歌（房主是权威，不靠远端快照回跟），
  /// 随后上报 switch_song 让成员跟随。
  void ownerSwitchSong(RoomSong song, {bool isAuto = false}) {
    if (closed || !_isOwner || song.hash.isEmpty) return;
    final revision = _markOwnerControl();
    unawaited(_playRoomSong(song));
    _enqueueOwnerCommand(() async {
      await _api.switchSong(
        roomId: roomId,
        hash: song.hash,
        mixSongId: song.mixSongId,
        listVersion: listVersion,
        isAuto: isAuto,
      );
      await _loadSongs(force: true);
      await _finishOwnerControl(revision);
    });
  }

  /// 房主点击任意歌曲（在线曲库 / 本地音乐）播放入口。
  ///
  /// 房主播放权威且会上报服务端，客户端本地起播绕不过去：必须先把该曲目变成
  /// 房间曲目（切歌），成员才能跟随。因此：
  ///   - 命中房间歌单 → 等价于 [ownerSwitchSong]；
  ///   - 未命中（本地音乐，或不在歌单里的歌）→ 返回 [OwnerPlayRejection.notInRoom]
  ///     由调用方明确拒绝，不做「本地照播 + 上报一个不存在的 hash」的半同步
  ///     （成员会跟着拿到无法解析的曲目，比直接拦截更糟）。
  ///
  /// 命中判定用 [RoomSong.sameAs]（hash / genting_hash / mixSongId 全键），
  /// 上游歌单条目的 hash 与播放器歌曲 id 存在大小写与形式错位。
  OwnerPlayRejection ownerPlaySong(Song song) {
    if (closed || !_isOwner) return OwnerPlayRejection.noRoom;
    final target = RoomSong.fromSong(song);
    if (target.hash.isEmpty) return OwnerPlayRejection.notInRoom;
    for (final s in playlist) {
      if (s.sameAs(target)) {
        // 房主切歌由房间会话自己起播并上报；调用方不得再播一遍
        ownerSwitchSong(s);
        return OwnerPlayRejection.handledByRoom;
      }
    }
    return OwnerPlayRejection.notInRoom;
  }

  /// 房主暂停/恢复（播放器动作由 UI 同步执行，这里只做上报）。
  void ownerSetPlaying(bool playing) {
    if (closed || !_isOwner) return;
    final revision = _markOwnerControl();
    _enqueueOwnerCommand(() async {
      await _api.playerOperation(roomId: roomId, action: 3, playing: playing);
      await _finishOwnerControl(revision);
    });
  }

  /// 房主拖动进度上报（入参毫秒，上游单位为秒）。
  void ownerSeek(int progressMs) {
    if (closed || !_isOwner) return;
    final revision = _markOwnerControl();
    _enqueueOwnerCommand(() async {
      await _api.playerOperation(
        roomId: roomId,
        action: 2,
        progressSec: (progressMs / 1000).floor().clamp(0, 1 << 31),
      );
      await _finishOwnerControl(revision);
    });
  }

  /// 播放器自然播完（房主）：切到房间歌单的下一首并按自动切歌上报
  /// （is_auto=true）。返回 true 表示已接管，调用方不得再执行本地连播。
  bool ownerHandleSongCompleted(Song completed) {
    if (closed || !_isOwner || playlist.isEmpty) return false;
    final target = _adjacentRoomSong(completed, forward: true);
    if (target == null) return false;
    ownerSwitchSong(target, isAuto: true);
    return true;
  }

  /// 房主手动上一首/下一首：路由到房间歌单相邻曲目（循环绕回）。
  /// 返回 true 表示已接管。房间内房主队列是单曲（playSong 置单元素队列），
  /// 本地 next/previous 不经此路由会在末尾暂停或静默绕回且不上报。
  bool ownerSkip({required bool forward}) {
    if (closed || !_isOwner || playlist.isEmpty) return false;
    final current = player.currentSong;
    final target = current == null
        ? (forward ? playlist.first : playlist.last)
        : _adjacentRoomSong(current, forward: forward);
    if (target == null) return false;
    ownerSwitchSong(target);
    return true;
  }

  /// 在房间歌单中定位 [song] 的相邻曲目；匹配不到（如占位条目未入列）时
  /// 正向从头取、反向从尾取，保证房主任何时刻都能切歌。
  RoomSong? _adjacentRoomSong(Song song, {required bool forward}) {
    if (playlist.isEmpty) return null;
    final ref = RoomSong.fromSong(song);
    var idx = playlist.indexWhere((s) => s.sameAs(ref));
    if (idx < 0 && ref.hash.isNotEmpty) {
      final hash = ref.hash.toLowerCase();
      idx = playlist.indexWhere((s) =>
          s.hash.toLowerCase() == hash ||
          (s.originalHash.isNotEmpty && s.originalHash.toLowerCase() == hash));
    }
    if (forward) {
      idx = idx < 0 ? 0 : (idx + 1) % playlist.length;
    } else {
      idx = idx <= 0 ? playlist.length - 1 : idx - 1;
    }
    return playlist[idx];
  }

  /// 房主播放模式上报（player_operation action=1：1=顺序 2=单曲循环 3=随机）。
  void ownerSetPlayMode(int playMode) {
    if (closed || !_isOwner) return;
    final revision = _markOwnerControl();
    _enqueueOwnerCommand(() async {
      await _api.playerOperation(roomId: roomId, action: 1, playMode: playMode);
      await _finishOwnerControl(revision);
    });
  }

  /// 房主开关聊天（update_chat）。成员端输入框按 [allowChat] 禁用；
  /// 请求失败时向上抛异常（UI 提示），本地状态不回滚误标。
  Future<void> ownerSetChatEnabled(bool allow) async {
    if (closed || !_isOwner) return;
    await _api.updateChat(roomId, allow: allow);
    allowChat = allow;
    notifyListeners();
  }

  /// 听众恢复播放：清除本地暂停标记，**立即**按缓存快照投影校准到远端位置，
  /// 再强制同步一次精修。
  ///
  /// 校准必须在同步 API 往返（~150ms）**之前**执行：实测这 150ms 窗口内
  /// 进度条滑条事件（用户拖动/滑条自激发 seek）会插队置 detached，等 API
  /// 返回时 apply 看到 detached 直接放弃，表现为「点播放没反应，再点一次
  /// 才跟上」。缓存快照至多滞后一个轮询周期（5s），投影计算会按墙钟补偿。
  Future<void> guestResume() async {
    debugPrint('[ListenTogether][Resume] guestResume 入口: '
        'paused=$guestLocallyPaused detached=$playbackDetached '
        'localPlaying=${player.isPlaying} localPos=${player.platformPosition.inMilliseconds}ms');
    guestLocallyPaused = false;
    notifyListeners();
    final remote = remoteState;
    final current = player.currentSong;
    final sameSong = remote != null &&
        remote.hash.isNotEmpty &&
        current != null &&
        ((current.id.isNotEmpty &&
                current.id.toLowerCase() == remote.hash.toLowerCase()) ||
            (current.albumAudioId != null &&
                current.albumAudioId!.isNotEmpty &&
                remote.mixSongId.isNotEmpty &&
                current.albumAudioId == remote.mixSongId));
    if (sameSong) {
      final projectedMs = projectRemotePosition(
        remote,
        DateTime.now().millisecondsSinceEpoch,
      );
      final localMs = player.platformPosition.inMilliseconds;
      if ((projectedMs - localMs).abs() > kForceSyncDriftToleranceMs) {
        debugPrint('[ListenTogether][Resume] 立即校准（缓存快照）: '
            '本地=${localMs}ms → 投影=${projectedMs}ms');
        await _seekToRemote(remote, projectedMs);
      }
    }
    await _syncPlayback(force: true);
  }

  /// 目标曲目是否为房间自身正在装载的接管曲目（见 [isTakeoverTargetSong]）。
  ///
  /// 对外暴露供装配层判定「这次起播是不是用户点击」——房间自己的跟随装载
  /// 不能弹确认窗。
  bool isRoomTakeoverTarget(Song song) =>
      isTakeoverTargetSong(takeover: _takeoverTarget, song: song);

  /// 听众拖动进度条：进入脱离态。
  ///
  /// 听众允许拖进度（进度条不再只读），但拖动是对房间进度的显式偏离——
  /// 置脱离标记停止远端接管，本地从拖动位置自由播放；恢复跟随走
  /// [resumeRoomPlayback]（房间页中央按钮 / 广场横幅）。本地暂停标记一并
  /// 清除：既然手动定了位置，暂停豁免语义已被覆盖。
  void detachBySeek() {
    if (closed || _isOwner) return;
    debugPrint('[ListenTogether] 听众拖动进度 → 脱离跟随'
        '（原 detached=$playbackDetached, paused=$guestLocallyPaused）');
    playbackDetached = true;
    guestLocallyPaused = false;
    notifyListeners();
  }

  /// 听众暂停：仅标记本地，不上报也不被轮询自动拉回。
  void guestPause() {
    if (_isOwner) return;
    debugPrint('[ListenTogether][Resume] guestPause: 置本机暂停豁免'
        '（localPos=${player.platformPosition.inMilliseconds}ms）');
    guestLocallyPaused = true;
    notifyListeners();
  }

  /// 听众在房间外播放其他音乐：保留会话与轮询，但停止让房间状态接管本地
  /// 播放器（对齐 EchoMusic playbackDetachedByUser——否则 5s 轮询会把
  /// 用户刚点的歌强制换成房间歌曲）。房主不脱离（播放守卫已拦截）。
  void detachIfPlayingOutside(Song song) {
    if (closed || _isOwner) return;
    // 房间接管的目标歌本身（跟随装载/装载重入）不算「外放」——按**身份**判定
    // 而非时间窗：装载 Future 在冷 CDN 上 11s+ 才回包，时间窗会误拦整个装载
    // 窗口内的用户脱离（实测「跟随中点击其他歌曲无法脱离」的根因）。
    if (isRoomTakeoverTarget(song)) return;
    final current = player.currentSong;
    final isSameSong = current != null &&
        (current.id == song.id ||
            (current.albumAudioId != null &&
                song.albumAudioId != null &&
                current.albumAudioId == song.albumAudioId));
    // 同一首歌重复起播不触发脱离（跟随端被纠偏拉回房间的同曲不属于「外放」）；
    // 已脱离状态下再置位是幂等操作（无需依赖此分支，恢复只走 resumeRoomPlayback）
    if (isSameSong && !playbackDetached) return;
    playbackDetached = true;
    notifyListeners();
  }

  /// 回到房间：清除脱离与本机暂停标记，强制同步追上房间进度。
  Future<void> resumeRoomPlayback() async {
    if (closed || _isOwner) return;
    playbackDetached = false;
    guestLocallyPaused = false;
    notifyListeners();
    await _syncPlayback(force: true);
  }

  /// 房主加歌时随请求上报的当前进度（服务端据此保持队列与播放一致）。
  Map<String, dynamic>? _currentProgressInfo() => buildRoomProgressInfo(player);

  /// 标记房主本地控制开始，返回本次控制的版本号。
  ///
  /// 控制期间跳过普通轮询（见 [_syncPlayback]），避免尚未完成的旧快照
  /// 把刚发出的操作立即覆盖回上一个状态。
  int _markOwnerControl() {
    final revision = ++_ownerControlRevision;
    _ownerGraceUntil = DateTime.now().add(kOwnerControlGrace);
    return revision;
  }

  /// 房主控制上报完成：解除宽限并立即同步一次服务端权威状态。
  ///
  /// 必须在「自己的写入已生效」之后再同步，否则宽限期内的自查询会读到
  /// 写入前的旧值，与本地状态来回回正（表现为暂停后无法继续播放）。
  Future<void> _finishOwnerControl(int revision) async {
    // 期间又产生了新的控制操作：交给最后一次收尾，避免旧结果覆盖新状态
    if (revision != _ownerControlRevision) return;
    _ownerGraceUntil = null;
    await _syncPlayback();
  }

  /// 房主指令串行执行：保证上报顺序与本地操作一致，互不覆盖。
  void _enqueueOwnerCommand(Future<void> Function() command) {
    _ownerCommandQueue = _ownerCommandQueue.then((_) => command()).catchError((Object e) {
      debugPrint('[ListenTogether] owner command failed: $e');
      if (_handleDissolved(e)) return;
      if (e is ListenTogetherApiError) {
        lastError = e.message;
        notifyListeners();
      }
    });
  }

  /// 离开房间；[dismiss] 为 true 且自己是房主时解散房间。
  Future<void> close({bool dismiss = false}) async {
    if (closed) return;
    closed = true;
    _coverQueue.dispose();
    _cancelTimers();
    try {
      if (dismiss && _isOwner) {
        await _api.dismissRoom(roomId);
      } else {
        await _api.leaveRoom(roomId);
      }
    } catch (e) {
      debugPrint('[ListenTogether] leave failed: $e');
      showToast('已退出本地会话，但服务端未确认离房');
    }
  }

  @override
  void dispose() {
    closed = true;
    _coverQueue.dispose();
    _cancelTimers();
    super.dispose();
  }
}
