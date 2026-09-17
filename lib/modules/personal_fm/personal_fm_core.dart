import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '_fm_refill.dart';

/// 一个具名电台：把 API 的 (mode, songPoolId) 包成用户看得懂的一档。
/// 接口共 9 种组合，这里只取 3 组，要全部组合的走完整 FM 页。
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

  /// 队列快见底时提前补货：[PlayerProvider] 一次只把一首歌灌进 audio_service，
  /// 队列末尾没有预加载。
  void _onPlayerChanged() {
    if (_retired) return;
    // 别人抢了槽位（完整 FM 页、或换档后重新起播），本续播器该退场了。
    if (player.onPlaylistEnd != onQueueEnd) {
      retire();
      return;
    }
    final playingId = player.currentSong?.id;
    // 起播过程中会有一瞬间没有当前曲目，那不代表队列换主了。
    if (playingId == null) return;
    if (!_owned.contains(playingId)) {
      retire();
      return;
    }
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
/// 行为一致：起播路径都走共享的 [FmRefill] 续播器，两边调整时必须同步维护。
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
  /// 切换收藏。
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
    await favorites.toggleFavorite(songs[currentIndex].toSong());
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
