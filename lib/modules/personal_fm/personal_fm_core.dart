import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '_fm_refill.dart';

/// 一个具名电台：把 API 的 (mode, songPoolId) 包成用户看得懂的一档。
/// 接口共 9 种组合，这里只取 4 组，要全部组合的走完整 FM 页。
class FmStation {
  const FmStation({
    required this.label,
    required this.icon,
    required this.mode,
    required this.songPoolId,
    required this.description,
  });

  final String label;
  final IconData icon;
  final String mode;
  final int songPoolId;
  final String description;
}

/// 与桌面小部件（原生 PersonalFmWidgetProvider 的档位文案/图标）保持一致，
/// 两边调整档位时必须同步。
const List<FmStation> kFmStations = [
  FmStation(
    label: '红心',
    icon: Icons.favorite,
    mode: 'normal',
    songPoolId: 0,
    description: '贴着你标过红心的歌来',
  ),
  FmStation(
    label: '探索',
    icon: Icons.explore,
    mode: 'normal',
    songPoolId: 2,
    description: '跳出常听，找点没听过的',
  ),
  FmStation(
    label: '小众',
    icon: Icons.diamond,
    mode: 'small',
    songPoolId: 1,
    description: '冷门但对味的作品',
  ),
  // 追加在末尾：档位下标同时持久化在 SharedPreferences（[kFmStationPrefKey]）、
  // 续播会话（fm_refill_station）和原生小部件里，0~2 一旦挪动老用户的档位就错位。
  FmStation(
    label: '电台',
    icon: Icons.radio,
    mode: 'radio',
    songPoolId: 0,
    description: '换个频道，整台连着听',
  ),
];

const String kFmStationPrefKey = 'discover_fm_station_index';

/// 队列剩下的歌不多于这个数就提前补货（与完整 FM 页同一条阈值）。
const int kFmPrefetchThreshold = 3;

/// 队列播完那一刻补货的重试次数与退避步长。
///
/// 这里必须重试：[PlayerProvider] 对 `onPlaylistEnd` 只 await、不校验结果，回调
/// 一返回就彻底静止，没有第二次机会。而单次补货失败的路子不少——接口返回 null、
/// 整批都是听过的、撞上在飞的那次预取。
const int kFmQueueEndRetries = 3;
const Duration kFmQueueEndBackoff = Duration(milliseconds: 600);

/// 电台行为回报（红心 / 取消红心 / 播放完成）的唯一出口。
///
/// 三条路径都走它：发现页区块的收藏按钮、桌面小部件的收藏按钮、[FmRefill] 的切歌
/// 与队列到底。写在一处而不是抄三遍，是为了把「静默 + 日志留痕」这条口径钉死：
/// 回报失败**不弹 toast**（一次点击的反馈已经归本地收藏那次写，再弹一条就是打扰），
/// 但发了什么参数必须能在 logcat 里查到，否则真机上无法判断上游收到了什么。
///
/// [KugouProvider.reportPersonalFmAction] 只转发——不动电台列表、不转
/// loading、不写错误态，所以调用方一律 fire-and-forget，本函数也不向上抛异常。
Future<void> reportFmFeedback({
  required KugouProvider kugou,
  required String action,
  required String mode,
  required int songPoolId,
  required KugouSongDetail track,
  int? playtime,
  bool isOverplay = false,
}) async {
  // curMark 缺失 = 这首歌没带回推荐令牌（模型没解析到，或上游就没给），上游只能按
  // (mode, songPoolId) 粗粒度记账。单独打一行，是为了在真机上一眼分辨这两种情况。
  debugPrint(
    '[PersonalFm] action=$action curMark=${track.curMark ?? 'missing'} '
    'hash=${track.hash}',
  );
  try {
    await kugou.reportPersonalFmAction(
      action: action,
      mode: mode,
      songPoolId: songPoolId,
      hash: track.hash,
      songId: track.songId,
      curMark: track.curMark,
      playtime: playtime,
      isOverplay: isOverplay,
    );
  } catch (e) {
    debugPrint('[PersonalFm] action=$action failed: $e');
  }
}

/// 「不喜欢」的唯一出口：上报 garbage，并把上游带回的替换批次接进电台列表与播放队列。
///
/// 两条调用路径共用它（完整 FM 页与发现页区块）——两边的业务语义必须逐字一致，抄
/// 两遍必然会漂。返回值分三态，调用方据此决定要不要提示：
/// - `null`：**上报请求本身**失败（`_get` 吞掉一切错误返回 null）。调用方 toast，
///   但**仍然要推进**：不喜欢不能被一次反馈 ping 卡住。
/// - 空列表：上报成功，上游只回了 ack、没带回替换批次。属于成功，误报会让每次
///   不喜欢都像坏了。
/// - 非空：已按 hash 去重写进 [KugouProvider.personalFmSongs] 与播放队列的新歌。
///
/// 上报失败不抛异常（与 [reportFmFeedback] 同一口径），调用方无需 try。
Future<List<KugouSongDetail>?> dislikeFmTrack({
  required KugouProvider kugou,
  required PlayerProvider player,
  required KugouSongDetail track,
  required String mode,
  required int songPoolId,
}) async {
  debugPrint(
    '[PersonalFm] action=garbage hash=${track.hash} curMark=${track.curMark}',
  );
  final List<KugouSongDetail>? result;
  try {
    result = await kugou.reportPersonalFmAction(
      action: 'garbage',
      mode: mode,
      songPoolId: songPoolId,
      hash: track.hash,
      songId: track.songId,
      curMark: track.curMark,
    );
  } catch (e) {
    debugPrint('[PersonalFm] garbage failed: $e');
    return null;
  }
  if (result == null) {
    debugPrint('[PersonalFm] garbage failed: request returned null');
    return null;
  }
  if (result.isEmpty) {
    debugPrint('[PersonalFm] garbage ok, no replacement batch');
    return const <KugouSongDetail>[];
  }
  // 整批都听过的可能：去重后为空仍算上报成功，调用方不该 toast。
  final currentSongs = kugou.personalFmSongs;
  final fresh = result
      .where((s) => !currentSongs.any((c) => c.hash == s.hash))
      .toList();
  if (fresh.isEmpty) return const <KugouSongDetail>[];
  kugou.appendFmSongs(fresh);
  try {
    await player.appendPlaylist(fresh.map((e) => e.toSong()).toList());
  } catch (e) {
    // 与 [FmRefill._append] 同一降级口径：真实实现是先把歌塞进 _playlist、再去动
    // audio_service 队列，后半段抛异常时队列其实已经能继续放了。这里不能报失败，
    // 否则发现页会把这批已经生效的替换批次当成没接上。
    debugPrint('[PersonalFm] garbage append failed: $e');
  }
  return fresh;
}

/// 电台续播器：把「无限电台」需要的一切收在这里，不引用任何 UI。
///
/// 补货必须比区块活得久——发现页切走一次就 dispose（AnimatedSwitcher 按 tab id
/// 换子树），而队列还在放。所以这里不碰 `mounted`、不碰 BuildContext，只依赖两个
/// provider（生命周期跟着 App）和起播时定下的档位；提前补货也由它自己监听播放器，
/// 不再借区块的 listener。
///
/// 它不需要谁来持有：换档重新起播时新的续播器会占掉 `onPlaylistEnd`，旧的在下一次
/// 通知里发现槽位不是自己的就 [retire] 退场。
///
/// 它还替电台把「上一首听了多久」报回去（切歌与队列到底各一次 [reportFmFeedback]），
/// 复用同一条播放器通知，不另起 Timer / 不订阅 positionStream（AGENTS §10）。
///
/// 所有权的判据是 [_owned]：本续播器亲手灌进队列的那些 hash。不去问
/// [KugouProvider.personalFmSongs]，因为换档 / 下拉刷新会把那个列表整体替换掉，
/// 一替换就认不出自己的队列了。
class FmRefill {
  FmRefill({
    required this.kugou,
    required this.player,
    required this.mode,
    required this.songPoolId,
    required List<KugouSongDetail> songs,
    bool adoptQueue = false,
    this._sessionGeneration,
  }) : _owned = songs.map((s) => s.hash).toSet(),
       _cursor = songs.isEmpty ? null : songs.last {
    // 接管一条已经在放、但槽位空了的队列（发现页区块与桌面小部件的自愈路径）：
    // 队列里可能有换档前灌进去、已经不在 personalFmSongs 里的歌，不一并认下来的话
    // 第一次通知就会被判成「别人的队列」而立刻退场。
    if (adoptQueue) {
      _owned.addAll(player.playlist.map((s) => s.id));
    }
    player.addListener(_onPlayerChanged);
  }

  final KugouProvider kugou;
  final PlayerProvider player;
  final String mode;
  final int songPoolId;

  /// 本续播器灌进队列的全部 hash，同时用于所有权判定和新歌去重。
  final Set<String> _owned;

  /// 下一批的游标：上一批的最后一首（与完整 FM 页一致，hash + songId）。
  /// 冷启动恢复出来的续播器拿不到 KugouSongDetail 游标，可空即为「不带游标要一批」。
  KugouSongDetail? _cursor;

  /// 会话代次（见 [FmRefillStore]）：非空时退场要把持久化的活跃标记清掉。
  final int? _sessionGeneration;

  /// 在飞的那次补货。并发调用合流到同一个 Future，而不是让后来者拿到 false——
  /// 队列末尾那次若把「有人正在补」当成「补不到」，就不会推 next()，
  /// 播放器会抱着一条刚补满的队列停死。
  Future<bool>? _inFlight;

  /// 上一次提前补货时的播放下标，避免停在同一首上反复请求。
  int _lastPrefetchIndex = -1;

  /// 上一次通知时播放器停在本续播器的哪一首、那一刻采到的位置与总时长。
  /// 切歌时要拿它们给**上一首**补一次 play 回报（见 [_reportPreviousTrack]）。
  String? _lastTrackId;
  int _lastPosSeconds = 0;
  Duration? _lastDuration;

  /// 本条电台会话里已经报过 play 的歌。队列到底那条路径里，补货成功时的
  /// `appendPlaylist` 通知会把 [_lastTrackId] 重新设成刚按「听完」报过的那首，
  /// 随后 `next()` 的切歌检测就会照着同一首再报一遍（而且第二回 playtime 更小、
  /// is_overplay 还会翻成 false）。按下标记账是唯一能钉死「每首只报一次」的办法。
  final Set<String> _reportedTracks = {};

  /// [onQueueEnd] 的重试全部用尽后置位：那一刻队列已经放到底、播放器 pause 在
  /// 最后一首上，再没有谁会调 [PlayerProvider.next]。之后任何一次补货成功都要
  /// 自己补推一把 next()，否则这条队列永远不会再往前走。
  bool _stalledAtQueueEnd = false;

  bool _retired = false;

  /// 队列是不是还归本续播器管。
  bool get _ownsQueue {
    final playingId = player.currentSong?.id;
    return playingId != null && _owned.contains(playingId);
  }

  /// 交还槽位并停止监听。
  ///
  /// 必须真的把 `onPlaylistEnd` 置回 null：[PlayerProvider] 只看槽位非空就把
  /// 「播完」整个交给回调，一个不干活的回调会连普通歌单的「播完回到第一首」
  /// 兜底一起遮蔽掉。
  void retire() {
    if (_retired) return;
    _retired = true;
    player.removeListener(_onPlayerChanged);
    if (player.onPlaylistEnd == onQueueEnd) {
      player.onPlaylistEnd = null;
    }
    final gen = _sessionGeneration;
    if (gen != null) {
      // ignore: discarded_futures
      FmRefillStore.clearIfCurrent(gen);
    }
  }

  /// 认领一批**不是本续播器自己要来**的电台歌（发现页「不喜欢」带回的替换批次）。
  ///
  /// 所有权集合 [_owned] 是退场判据（见 [_ownsQueue] 与 [_onPlayerChanged]）：这批歌
  /// 由 [dislikeFmTrack] 直接写进列表与队列，不在这里登记的话，电台随后播到它们时
  /// 会被判成「队列换主」而当场 [retire]，这条电台从此不再补货——用户看到的就是
  /// 「点了几次不喜欢，电台就放完了」。
  ///
  /// 游标 [_cursor] **不动**：替换批次与续播请求的批次是两条独立的召回窗口，拿它
  /// 当游标只会把下一次要歌推到不相干的位置。集合并集，重复调用幂等。
  void adopt(List<KugouSongDetail> songs) {
    if (_retired) return;
    _owned.addAll(songs.map((s) => s.hash));
  }

  /// 队列快见底时提前补货：[PlayerProvider] 一次只把一首歌灌进 audio_service，
  /// 队列末尾没有预加载。
  void _onPlayerChanged() {
    if (_retired) return;
    // 别人抢了槽位（完整 FM 页、或换档后重新起播），本续播器该退场了。
    if (player.onPlaylistEnd != onQueueEnd) {
      _flushPendingReport();
      retire();
      return;
    }
    final playingId = player.currentSong?.id;
    // 起播过程中会有一瞬间没有当前曲目，那不代表队列换主了。
    if (playingId == null) return;
    if (!_owned.contains(playingId)) {
      // 换成了别人的歌：先把本续播器欠着的那首报掉再退场。「听完一首电台歌再去点
      // 普通歌单」是最常见的路径，不在这里收尾就永远少一次收听时长回报。
      _flushPendingReport();
      retire();
      return;
    }
    // 切歌了：先把上一首的 play 回报补掉，再刷新采样。放在提前补货那几行 return
    // 之前——那几个 return 只关心队列长度，不该把回报一起挡掉。能走到这里说明
    // playingId 归本续播器管，而 _lastTrackId 只可能是更早一次同样过了所有权检查
    // 的 id，所以「只报自己灌进队列的歌」这条判据不用再写第二遍。
    if (playingId != _lastTrackId) {
      final previousId = _lastTrackId;
      _lastTrackId = playingId;
      if (previousId != null) _reportPreviousTrack(previousId);
    }
    // 只能采「本次通知那一刻」的位置：播放器的高频位置更新走 positionNotifier，
    // 不触发 notifyListeners，为它再起一路定时器和 §10 的限帧约定冲突。暂停、
    // seek、播放态迁移都会进到本回调，所以自动切歌时这个值可能偏小——少报好过
    // 多引一路常驻刷新。
    _lastPosSeconds = player.position.inSeconds;
    _lastDuration = player.duration;
    final index = player.currentIndex;
    if (index < 0) return;
    if (player.playlist.length - index > kFmPrefetchThreshold) return;
    if (index == _lastPrefetchIndex) return;
    _lastPrefetchIndex = index;
    // 失败不能烧掉这个下标：还停在同一首上时得允许再试一次，否则一次网络
    // 抖动就让这条队列再也不补货。
    append().then((ok) {
      if (!ok) {
        if (_lastPrefetchIndex == index) _lastPrefetchIndex = -1;
        return;
      }
      // 停摆过就得自己推一把：那一刻播放器已经 pause 在最后一首上，接上新歌
      // 也没有谁会调 next()。
      if (_stalledAtQueueEnd && !_retired && _ownsQueue) {
        _stalledAtQueueEnd = false;
        player.next();
      }
    });
  }

  /// 队列播完了：补一批新歌再推一把 [PlayerProvider.next]——播放器 await 完这个
  /// 回调就不再切歌，而它给 audio_service 的永远只有当前这一首。
  Future<void> onQueueEnd() async {
    if (_retired) return;
    if (!_ownsQueue) {
      retire();
      return;
    }
    _reportQueueEndTrack();
    for (var attempt = 0; attempt < kFmQueueEndRetries; attempt++) {
      if (attempt > 0) {
        await Future.delayed(kFmQueueEndBackoff * attempt);
        if (_retired || !_ownsQueue) return;
      }
      if (await append()) {
        _stalledAtQueueEnd = false;
        await player.next();
        return;
      }
    }
    // 重试用尽后不能就这么算了：播放器这时停在最后一首（[PlayerProvider.next]
    // 到末尾就 pause），而提前补货那条路还被烧掉的下标挡着——两条路一起断，这
    // 条队列就永久不补货了，用户在发现页怎么点都恢复不过来。放开下标并记下停摆
    // 状态：下一次播放器通知（暂停事件本身就是一次，回前台点播放又是一次）能
    // 重新试，补上了由 [_onPlayerChanged] 推 next()。
    _stalledAtQueueEnd = true;
    _lastPrefetchIndex = -1;
  }

  /// 按 hash 在电台列表里找那首歌。换过档或列表被整体刷新过就可能找不到，
  /// 找不到由调用方决定跳过——绝不拿别的歌的 curMark 顶替。
  KugouSongDetail? _trackByHash(String hash) {
    for (final s in kugou.personalFmSongs) {
      if (s.hash == hash) return s;
    }
    return null;
  }

  /// 上一首的 play 回报：已播时长用最后一次采到的位置，`is_overplay` 按
  /// 「距总时长 2 秒内」判——播放器到末尾的收尾常有几百毫秒的误差，卡太严会
  /// 把听完整首歌也报成没听完。总时长优先用播放器报过的 [_lastDuration]，
  /// 一次都没采到就退回列表里声明的时长。
  void _reportPreviousTrack(String previousId) {
    final previous = _trackByHash(previousId);
    if (previous == null) return;
    // 每首只报一次：队列到底时已经按「听完」报过这一首，之后补货的 appendPlaylist
    // 与 next() 各会通知一次播放器，光靠 [_lastTrackId] 销账会被这些通知重新武装，
    // 于是同一首歌又补出一笔 playtime 更小、is_overplay 还翻成 false 的回报。
    if (!_reportedTracks.add(previousId)) return;
    final total = _lastDuration?.inSeconds ?? previous.duration;
    // ignore: discarded_futures
    reportFmFeedback(
      kugou: kugou,
      action: 'play',
      mode: mode,
      songPoolId: songPoolId,
      track: previous,
      playtime: _lastPosSeconds,
      isOverplay: total > 0 && _lastPosSeconds >= total - 2,
    );
  }

  /// 把「还没回报过的当前曲」补报一次并销账。[_lastTrackId] 非空即代表这一首
  /// 已经采样过进度但还没走到切歌那一步；退场（换主/丢槽位）时必须先收尾，
  /// 否则这次收听对上游就是空的。
  void _flushPendingReport() {
    final pendingId = _lastTrackId;
    if (pendingId == null) return;
    _lastTrackId = null;
    _reportPreviousTrack(pendingId);
  }

  /// 队列到底：最后这一首是真的放完了，直接按 `is_overplay: true` 报，已播时长
  /// 取总时长（这一刻它就是已播的全部），不走切歌那条差 2 秒的判定。
  /// fire-and-forget：本回调被播放器 await，等一次网络往返会把补货整条链路拖住。
  ///
  /// 报完必须把 [_lastTrackId] 清空：紧接着 [onQueueEnd] 会推 [PlayerProvider.next]
  /// 接上新歌，那次切歌的「上一首」还是这一首，不清空就会同一条歌报两回 play，
  /// 而且第二回的 playtime 更小、is_overplay 还会翻成 false。
  void _reportQueueEndTrack() {
    final lastId = player.currentSong?.id;
    if (lastId == null) return;
    final lastTrack = _trackByHash(lastId);
    if (lastTrack == null) return;
    if (!_reportedTracks.add(lastId)) return;
    final total = _lastDuration?.inSeconds ?? lastTrack.duration;
    _lastTrackId = null;
    // ignore: discarded_futures
    reportFmFeedback(
      kugou: kugou,
      action: 'play',
      mode: mode,
      songPoolId: songPoolId,
      track: lastTrack,
      playtime: total > 0 ? total : null,
      isOverplay: true,
    );
  }

  /// 向电台列表和播放队列各接一批新歌，返回是否真的接上了。
  Future<bool> append() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final started = _append();
    _inFlight = started;
    return started.whenComplete(() {
      if (_inFlight == started) _inFlight = null;
    });
  }

  Future<bool> _append() async {
    if (_retired || !_ownsQueue) return false;
    final lengthBefore = player.playlist.length;
    try {
      // 带游标要不到新歌就退回不带游标再要一次。这一步必须显式写出来：
      // getPersonalFm 从不抛异常（_get 吞掉一切返回 null），靠 catch 兜是死代码。
      var fresh = await _fetch(_cursor);
      fresh ??= await _fetch(null);
      if (fresh == null || _retired) return false;

      _owned.addAll(fresh.map((s) => s.hash));
      _cursor = fresh.last;
      kugou.appendFmSongs(fresh);
      await player.appendPlaylist(fresh.map((e) => e.toSong()).toList());
      return true;
    } catch (_) {
      // 抛出来只会变成没人接的异步异常，还会中断 [onQueueEnd] 的重试循环
      // （播放器 await 这个回调，且不 catch）。降级成「队列到底有没有变长」：
      // [PlayerProvider.appendPlaylist] 先把歌塞进 _playlist，再去动
      // audio_service 队列，后半段抛异常时队列其实已经能继续放了，这时报失败会
      // 让 [onQueueEnd] 白白放弃一条补满了的队列。
      return player.playlist.length > lengthBefore;
    }
  }

  /// 去重后的新歌；要不到、或整批都听过都返回 null，由调用方决定要不要退一步。
  Future<List<KugouSongDetail>?> _fetch(KugouSongDetail? cursor) async {
    final result = await kugou.fetchMorePersonalFm(
      mode: mode,
      songPoolId: songPoolId,
      hash: cursor?.hash,
      songId: cursor?.songId,
    );
    if (result == null || result.isEmpty) return null;
    final fresh = result.where((s) => !_owned.contains(s.hash)).toList();
    return fresh.isEmpty ? null : fresh;
  }
}

/// 桌面小部件按钮动作的 Flutter 侧处理器。
///
/// 动作链路：小部件 → AudioPlaybackService → MethodChannel →
/// MediaNotificationService 静态回调 →（FmWidgetSync 包装后）本类。
/// 各方法与 [PersonalFmSection]（personal_fm_section.dart）的对应逻辑保持
/// 行为一致：起播路径都走共享的 [FmRefill] 续播器，收藏那一步两边都是「先写本地
/// 收藏、再 [reportFmFeedback] 静默补一次电台红心回报」，调整任一侧必须同步另一侧。
class PersonalFmWidgetActions {
  PersonalFmWidgetActions._();

  /// 小部件切档完成后的通知：发现页区块订阅它同步自身档位（不重拉列表，
  /// 列表已由本类重拉过）。
  static void Function(int stationIndex)? onStationChanged;

  /// 读取持久化档位；越界回落到默认档。
  static Future<int> restoreStationIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(kFmStationPrefKey) ?? 0;
    if (saved < 0 || saved >= kFmStations.length) return 0;
    return saved;
  }

  /// 按档位拉一批 FM 歌曲替换列表。与发现页一致：不自动开播。
  static Future<void> loadFm(KugouProvider kugou, FmStation station) async {
    try {
      await kugou.getPersonalFm(
        mode: station.mode,
        songPoolId: station.songPoolId,
      );
    } catch (_) {}
  }

  /// 新建续播器占住 `onPlaylistEnd`，返回它（歌单为空时返回 null）。
  /// 与发现页区块的 _armRefill 等价。
  static FmRefill? armRefill(
    KugouProvider kugou,
    PlayerProvider player,
    int stationIndex, {
    bool adoptQueue = false,
  }) {
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return null;
    final station = kFmStations[stationIndex];
    final generation = FmRefillStore.nextGeneration();
    final refill = FmRefill(
      kugou: kugou,
      player: player,
      mode: station.mode,
      songPoolId: station.songPoolId,
      songs: songs,
      adoptQueue: adoptQueue,
      sessionGeneration: generation,
    );
    // 持久化「这是一条 FM 队列」：杀后台重进后靠它把续播器挂回来。
    // ignore: discarded_futures
    FmRefillStore.markActive(stationIndex);
    player.onPlaylistEnd = refill.onQueueEnd;
    return refill;
  }

  /// 从当前电台第一首起播。与发现页区块的 _playSong 等价。
  static Future<void> playSong(
    KugouProvider kugou,
    PlayerProvider player,
    int stationIndex,
    KugouSongDetail song,
  ) async {
    if (!kugou.personalFmSongs.any((s) => s.hash == song.hash)) return;

    kugou.moveToFirst(song);
    final refill = armRefill(kugou, player, stationIndex);
    await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
    refill?.append(); // 立即补一批
  }

  /// 小部件播放/暂停按钮：与发现页 _handlePlayPersonalFm 等价。
  /// 依据是播放器的当前曲目而不是按钮画的图标：暂停在第三首时按钮画的是播放，
  /// 但那时要的是 resume，走 playSong 会把这首从头重放。
  static Future<void> handlePlayPause({
    required KugouProvider kugou,
    required PlayerProvider player,
  }) async {
    final stationIndex = await restoreStationIndex();

    if (kugou.personalFmSongs.isEmpty) {
      await loadFm(kugou, kFmStations[stationIndex]);
      return;
    }

    final playingId = player.currentSong?.id;
    final isOnThisStation =
        playingId != null &&
        kugou.personalFmSongs.any((s) => s.hash == playingId);
    if (isOnThisStation) {
      // 槽位空着说明这条队列已经没有续播器了（区块重建过、或上一个续播器退场
      // 了）。直接 resume 出来的是一条永远不会补货的队列。先把续播器补挂回去。
      if (player.onPlaylistEnd == null) {
        armRefill(kugou, player, stationIndex, adoptQueue: true);
      }
      if (player.isPlaying) {
        await player.pause();
      } else {
        await player.resume();
      }
    } else {
      final songs = kugou.personalFmSongs;
      if (songs.isEmpty) return;
      await playSong(kugou, player, stationIndex, songs[0]);
    }
  }

  /// 小部件封面/预告封面点击：后台起播对应歌曲，不拉起 app。
  /// 已是播放器当前曲目时不重复起播（与发现页 _openTrack 的守卫一致）。
  static Future<void> handleOpenTrack({
    required KugouProvider kugou,
    required PlayerProvider player,
    required String hash,
  }) async {
    if (player.currentSong?.id == hash) return;
    KugouSongDetail? track;
    for (final s in kugou.personalFmSongs) {
      if (s.hash == hash) {
        track = s;
        break;
      }
    }
    if (track == null) return;
    final stationIndex = await restoreStationIndex();
    await playSong(kugou, player, stationIndex, track);
  }

  /// 小部件收藏按钮：对卡片渲染的那一首（与发现页 currentIndex 同一套计算）
  /// 切换收藏，随后与发现页同一口径补一次电台红心回报。
  static Future<void> handleToggleFavorite({
    required KugouProvider kugou,
    required PlayerProvider player,
    required FavoritesProvider favorites,
  }) async {
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return;
    final playingId = player.currentSong?.id;
    final playingIndex = playingId == null
        ? -1
        : songs.indexWhere((s) => s.hash == playingId);
    final currentIndex = playingIndex >= 0 ? playingIndex : 0;
    final track = songs[currentIndex];
    // action 取切换**前**的状态：已经红心 → 这一次点的是取消红心。
    final isFavorite = favorites.isFavorite(track.hash);
    await favorites.toggleFavorite(track.toSong());
    // ignore: discarded_futures
    _reportStationFeedback(
      kugou: kugou,
      action: isFavorite ? 'cancel_red' : 'click_red',
      track: track,
    );
  }

  /// 按持久化档位补一次行为回报。本类没有 BuildContext，档位只能读 prefs
  /// （与周围方法同一套 [restoreStationIndex]）；prefs 读取也一起裹进 try，
  /// 免得这个 fire-and-forget 的 Future 带着没人处理的错误落地。
  static Future<void> _reportStationFeedback({
    required KugouProvider kugou,
    required String action,
    required KugouSongDetail track,
  }) async {
    try {
      final station = kFmStations[await restoreStationIndex()];
      await reportFmFeedback(
        kugou: kugou,
        action: action,
        mode: station.mode,
        songPoolId: station.songPoolId,
        track: track,
      );
    } catch (e) {
      debugPrint('[PersonalFm] action=$action failed: $e');
    }
  }

  /// 小部件档位切换：存 prefs + 重拉列表，不自动开播（与发现页 _selectStation
  /// 一致）。加载态由 FmWidgetSync 的包装器负责推送。
  static Future<void> handleSelectStation({
    required KugouProvider kugou,
    required int index,
  }) async {
    if (index < 0 || index >= kFmStations.length) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kFmStationPrefKey, index);
    await loadFm(kugou, kFmStations[index]);
    onStationChanged?.call(index);
  }
}
