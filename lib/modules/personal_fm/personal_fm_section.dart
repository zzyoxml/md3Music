import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '_fm_refill.dart';

/// 一个具名电台：把 API 的 (mode, songPoolId) 包成用户看得懂的一档。
/// 接口共 9 种组合，这里只取 3 组，要全部组合的走完整 FM 页。
class _Station {
  const _Station({
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

const List<_Station> _kStations = [
  _Station(
    label: '红心',
    icon: Icons.favorite,
    mode: 'normal',
    songPoolId: 0,
    description: '贴着你标过红心的歌来',
  ),
  _Station(
    label: '探索',
    icon: Icons.explore,
    mode: 'normal',
    songPoolId: 2,
    description: '跳出常听，找点没听过的',
  ),
  _Station(
    label: '小众',
    icon: Icons.diamond,
    mode: 'small',
    songPoolId: 1,
    description: '冷门但对味的作品',
  ),
];

const double _kCardRadius = 20.0;
const double _kCoverRadius = 16.0;
const double _kCoverSize = 112.0;
const double _kCoverGap = 12.0;
const double _kNextCoverSize = 48.0;
const double _kNextCoverRadius = 12.0;
const double _kNextCoverGap = 8.0;
const double _kStationButtonSize = 40.0;

/// 律动线的带高与上下留白：3 + 10 + 3 = 16dp 的缝把右栏两排撑到与封面等高，
/// 线的中线因此落在播放按钮与档位按钮圆心的正中。
const double _kWaveBandHeight = 10.0;
const double _kWaveBandInset = 3.0;

/// 「正在播」面板的内边距。律动线靠它的负值贯穿到卡片两边。
const double _kPanelPadding = 16.0;

/// 补齐与上排 48dp 播放按钮的圆心差：两枚按钮都靠右排，40 与 48 差 4dp。
const double _kStationButtonRightInset = 4.0;

const Duration _kDrawerDuration = Duration(milliseconds: 260);
const Curve _kDrawerCurve = Curves.easeInOutCubicEmphasized;

/// 队列剩下的歌不多于这个数就提前补货（与完整 FM 页同一条阈值）。
const int _kPrefetchThreshold = 3;

/// 队列播完那一刻补货的重试次数与退避步长。
///
/// 这里必须重试：[PlayerProvider] 对 `onPlaylistEnd` 只 await、不校验结果，回调
/// 一返回就彻底静止，没有第二次机会。而单次补货失败的路子不少——接口返回 null、
/// 整批都是听过的、撞上在飞的那次预取。
const int _kQueueEndRetries = 3;
const Duration _kQueueEndBackoff = Duration(milliseconds: 600);

/// 电台续播器：把「无限电台」需要的一切收在这里，不引用任何 [State]。
///
/// 补货必须比区块活得久——发现页切走一次就 dispose（[AnimatedSwitcher] 按 tab id
/// 换子树），而队列还在放。所以这里不碰 `mounted`、不碰 [BuildContext]，只依赖两个
/// provider（生命周期跟着 App）和起播时定下的档位；提前补货也由它自己监听播放器，
/// 不再借区块的 listener。
///
/// 它不需要谁来持有：换档重新起播时新的续播器会占掉 `onPlaylistEnd`，旧的在下一次
/// 通知里发现槽位不是自己的就 [retire] 退场。
///
/// 所有权的判据是 [_owned]：本续播器亲手灌进队列的那些 hash。不去问
/// [KugouProvider.personalFmSongs]，因为换档 / 下拉刷新会把那个列表整体替换掉，
/// 一替换就认不出自己的队列了。
class _FmRefill {
  _FmRefill({
    required this.kugou,
    required this.player,
    required this.mode,
    required this.songPoolId,
    required List<KugouSongDetail> songs,
    bool adoptQueue = false,
    this._sessionGeneration,
  }) : _owned = songs.map((s) => s.hash).toSet(),
       _cursor = songs.isEmpty ? null : songs.last {
    // 接管一条已经在放、但槽位空了的队列（见 [_PersonalFmSectionState._armRefill]）：
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
    if (player.playlist.length - index > _kPrefetchThreshold) return;
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
    for (var attempt = 0; attempt < _kQueueEndRetries; attempt++) {
      if (attempt > 0) {
        await Future.delayed(_kQueueEndBackoff * attempt);
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

Color _containerColor(ColorScheme cs) => cs.surfaceContainerLow;

/// 抽屉那一层的底色。不能用 surfaceDim：深色主题下它与页面底色 surface 同值，
/// 抽屉展开后看起来就是没有背景。
Color _drawerColor(ColorScheme cs) => cs.secondaryContainer;

Color _onDrawerColor(ColorScheme cs) => cs.onSecondaryContainer;

/// 发现页内嵌的私人 FM 区块：登录后是电台卡，未登录是登录引导卡。
///
/// 与完整 FM 页的差异：加载后不自动开播、不做「列表顺序反向同步回播放器」、
/// 档位是 3 个具名预设。起播后同样是无限电台，补货由 [_FmRefill] 负责——它不挂在
/// 本区块上，切走发现页也照样续播。
class PersonalFmSection extends StatefulWidget {
  const PersonalFmSection({super.key});

  @override
  State<PersonalFmSection> createState() => _PersonalFmSectionState();
}

class _PersonalFmSectionState extends State<PersonalFmSection> {
  static const String _kStationPrefKey = 'discover_fm_station_index';

  bool _isLoading = false;
  int _stationIndex = 0;
  bool _isStationDrawerOpen = false;

  _Station get _station => _kStations[_stationIndex];

  @override
  void initState() {
    super.initState();
    // initState 里读不到 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reviveRefillIfNeeded();
      _restoreStation();
    });
  }

  /// 杀后台重进的自愈：播放队列被 PlayerStateRepository 恢复了，但续播器
  /// 是内存对象已随进程消失，此时从底栏 resume 出来的是一条永不补货的死队列。
  /// 有持久化的 FM 会话标记（见 [FmRefillStore]）就按当时档位重建续播器，
  /// adoptQueue 接管恢复出来的队列；再补一批把 personalFmSongs 填回来，
  /// 卡片的列表 UI 也随之恢复。
  Future<void> _reviveRefillIfNeeded() async {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.onPlaylistEnd != null) return;
    if (player.playlist.isEmpty || player.currentSong == null) return;
    final stationIndex = await FmRefillStore.activeStationIndex();
    if (!mounted || stationIndex == null) return;
    if (stationIndex < 0 || stationIndex >= _kStations.length) return;
    if (stationIndex != _stationIndex) {
      setState(() => _stationIndex = stationIndex);
    }
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final generation = FmRefillStore.nextGeneration();
    final refill = _FmRefill(
      kugou: kugou,
      player: player,
      mode: _station.mode,
      songPoolId: _station.songPoolId,
      songs: const [],
      adoptQueue: true,
      sessionGeneration: generation,
    );
    player.onPlaylistEnd = refill.onQueueEnd;
    // ignore: discarded_futures
    refill.append();
  }

  /// 恢复上次选的档位。发现页的初始加载不带档位参数（服务端回落到默认档），
  /// 所以恢复出非默认档后要按它重拉列表；但正在放本电台的歌时不能重拉——
  /// 列表一换，正在播的那首就不在列表里了。
  Future<void> _restoreStation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getInt(_kStationPrefKey) ?? 0;
    if (saved == _stationIndex || saved < 0 || saved >= _kStations.length) {
      return;
    }
    setState(() => _stationIndex = saved);

    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final playingId = Provider.of<PlayerProvider>(
      context,
      listen: false,
    ).currentSong?.id;
    if (playingId != null &&
        kugou.personalFmSongs.any((s) => s.hash == playingId)) {
      return;
    }
    await _loadPersonalFm();
  }

  Future<void> _loadPersonalFm() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await Provider.of<KugouProvider>(
        context,
        listen: false,
      ).getPersonalFm(mode: _station.mode, songPoolId: _station.songPoolId);
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _selectStation(int index) {
    if (index == _stationIndex) return;
    setState(() => _stationIndex = index);
    _saveStation(index);
    _loadPersonalFm();
  }

  Future<void> _saveStation(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kStationPrefKey, index);
  }

  void _toggleStationDrawer() {
    setState(() => _isStationDrawerOpen = !_isStationDrawerOpen);
  }

  Future<void> _playSong(KugouSongDetail song) async {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (!kugou.personalFmSongs.any((s) => s.hash == song.hash)) return;

    kugou.moveToFirst(song);
    final refill = _armRefill(kugou, player);
    await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
    refill?.append(); // 立即补一批
  }

  /// 新建续播器占住 `onPlaylistEnd`，返回它（歌单为空时返回 null）。
  ///
  /// 谁起播的队列谁负责补货。续播器不引用本 State，切走发现页把区块 dispose 掉
  /// 也不影响它续播；上一个续播器会在下一次播放器通知里自己退场（见 [_FmRefill]）。
  ///
  /// [adoptQueue] 供「槽位空了但队列还在放」的自愈路径用，见 [_handlePlayPersonalFm]。
  _FmRefill? _armRefill(
    KugouProvider kugou,
    PlayerProvider player, {
    bool adoptQueue = false,
  }) {
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return null;
    final generation = FmRefillStore.nextGeneration();
    final refill = _FmRefill(
      kugou: kugou,
      player: player,
      mode: _station.mode,
      songPoolId: _station.songPoolId,
      songs: songs,
      adoptQueue: adoptQueue,
      sessionGeneration: generation,
    );
    // 持久化「这是一条 FM 队列」：杀后台重进后靠它把续播器挂回来。
    // ignore: discarded_futures
    FmRefillStore.markActive(_stationIndex);
    player.onPlaylistEnd = refill.onQueueEnd;
    return refill;
  }

  /// 不 await 起播：[PlayerProvider.playOnlinePlaylist] 在第一个 await 之前就
  /// 同步设好了 currentSong，详情页立刻能显示这首歌。
  void _openTrack(KugouSongDetail track) {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.currentSong?.id != track.hash) {
      _playSong(track);
    }
    _openPlayerDetail();
  }

  /// 走 [fullPlayerRoute]：与 MiniPlayer 点击展开同一条路由（带拖拽收起、
  /// 交叉淡入、md / AM 两套播放页的选择）。
  void _openPlayerDetail() {
    if (activePlayerRoute?.isCurrent ?? false) return;
    Navigator.of(context).push(fullPlayerRoute(context));
  }

  Future<void> _togglePlay() async {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.resume();
    }
  }

  /// 播放器停在本电台的某一首上就切播放/暂停，否则起播 [track]。
  ///
  /// 依据是播放器的当前曲目而不是按钮画的图标：暂停在第三首时按钮画的是播放，
  /// 但那时要的是 resume，走 [_playSong] 会把这首从头重放。
  Future<void> _handlePlayPersonalFm(KugouSongDetail? track) async {
    if (_isLoading) return;
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);

    if (kugou.personalFmSongs.isEmpty) {
      await _loadPersonalFm();
      return;
    }

    final playingId = player.currentSong?.id;
    final isOnThisStation =
        playingId != null &&
        kugou.personalFmSongs.any((s) => s.hash == playingId);
    if (isOnThisStation) {
      // 槽位空着说明这条队列已经没有续播器了（区块重建过、或上一个续播器退场
      // 了）。直接 resume 出来的是一条永远不会补货的队列——放完最后一首就走
      // [PlayerProvider] 的「回到第一首」兜底，用户在这张卡上再怎么点也恢复不
      // 过来。先把续播器补挂回去。
      if (player.onPlaylistEnd == null) {
        _armRefill(kugou, player, adoptQueue: true);
      }
      await _togglePlay();
    } else {
      if (track == null) return;
      await _playSong(track);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kugou = Provider.of<KugouProvider>(context);
    final player = Provider.of<PlayerProvider>(context);
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isLoggedIn = kugou.isLoggedIn;
    final songs = kugou.personalFmSongs;

    // 卡片渲染的是播放器当前那一首，不是 songs.first：电台自己续到下一首时列表
    // 顺序不变，只有播放器的当前曲目在动。播放器不在本电台上时退回列表第一首。
    final playingId = player.currentSong?.id;
    final playingIndex = playingId == null
        ? -1
        : songs.indexWhere((s) => s.hash == playingId);
    final currentIndex = playingIndex >= 0 ? playingIndex : 0;
    final currentTrack = songs.isEmpty ? null : songs[currentIndex];
    final isPlaying = playingIndex >= 0 && player.isPlaying;
    final nextTracks = songs.isEmpty
        ? const <KugouSongDetail>[]
        : songs.sublist(currentIndex + 1);

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: isLoggedIn
          ? _buildRadioCard(cs, textTheme, currentTrack, nextTracks, isPlaying)
          : _buildLoginPrompt(cs, textTheme),
    );
  }

  Widget _buildLoginPrompt(ColorScheme cs, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: _containerColor(cs),
        borderRadius: BorderRadius.circular(_kCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginPage())),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: cs.primaryContainer,
                  ),
                  child: Icon(
                    Icons.radio,
                    size: 22,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '登录后开启你的专属电台',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '按你的口味不断续播',
                        style: textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 两层叠着：上面是常驻的「正在播」面板，下面是档位抽屉所在的托盘
  /// （[_drawerColor]）。收起时托盘高度等于面板、完全被盖住，面板的阴影也被
  /// 托盘的裁剪收掉。
  Widget _buildRadioCard(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    List<KugouSongDetail> nextTracks,
    bool isPlaying,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: _drawerColor(cs),
        borderRadius: BorderRadius.circular(_kCardRadius),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: _containerColor(cs),
              // 别让 M3 的高度着色再往面板底色上叠一层。
              surfaceTintColor: Colors.transparent,
              elevation: 1,
              borderRadius: BorderRadius.circular(_kCardRadius),
              child: Padding(
                padding: const EdgeInsets.all(_kPanelPadding),
                child: _buildNowPlayingRow(
                  cs,
                  textTheme,
                  currentTrack,
                  nextTracks,
                  isPlaying,
                ),
              ),
            ),
            _buildStationDrawer(cs, textTheme),
          ],
        ),
      ),
    );
  }

  /// 收起时高度为 0：内容还在树里但被裁掉，既点不到也不下发语义
  /// （[Opacity] 在 alpha 为 0 时不下发）。用 `heightFactor` 而不是
  /// [AnimatedCrossFade]，内容才会钉在顶边不动、只有容器高度在长。
  Widget _buildStationDrawer(ColorScheme cs, TextTheme textTheme) {
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.topLeft,
        heightFactor: _isStationDrawerOpen ? 1.0 : 0.0,
        duration: _kDrawerDuration,
        curve: _kDrawerCurve,
        child: AnimatedOpacity(
          opacity: _isStationDrawerOpen ? 1.0 : 0.0,
          duration: _kDrawerDuration,
          curve: Curves.easeInOut,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStationGroup(),
                const SizedBox(height: 8),
                _buildStationDescription(cs, textTheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStationButton(ColorScheme cs) {
    final open = _isStationDrawerOpen;
    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: open,
        label: '电台档位：${_station.label}',
        excludeSemantics: true,
        child: Tooltip(
          message: open ? '收起电台档位' : '电台档位：${_station.label}',
          child: Material(
            color: open ? cs.primary : cs.surfaceContainerHigh,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _toggleStationDrawer,
              child: SizedBox(
                width: _kStationButtonSize,
                height: _kStationButtonSize,
                child: Center(
                  child: Icon(
                    _station.icon,
                    size: 20,
                    color: open ? cs.onPrimary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStationGroup() {
    return SlidingSegmentedControl(
      segments: _kStations
          .map(
            (station) => SlidingSegment(
              label: station.label,
              icon: station.icon,
              semanticLabel: '${station.label}电台',
            ),
          )
          .toList(),
      selectedIndex: _stationIndex,
      onSelected: _selectStation,
      semanticLabel: '电台档位',
    );
  }

  Widget _buildStationDescription(ColorScheme cs, TextTheme textTheme) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Text(
        _station.description,
        key: ValueKey(_stationIndex),
        style: textTheme.bodySmall?.copyWith(color: _onDrawerColor(cs)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 右侧那一列顶对齐：居中会把上下两条空白分开，顶上去才腾得出底排的封面。
  ///
  /// 封面从 [Row] 里挪到 [Stack] 的后一层、原位留一个同尺寸的空位：律动线长在右栏
  /// 的缝里、向左贯穿到卡片边缘，画在封面之下才能被封面盖住。
  Widget _buildNowPlayingRow(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    List<KugouSongDetail> nextTracks,
    bool isPlaying,
  ) {
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: _kCoverSize, height: _kCoverSize),
            const SizedBox(width: _kCoverGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentTrack?.songName ?? '点播放，开启你的电台',
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (currentTrack?.artistName?.isNotEmpty ??
                                false) ...[
                              const SizedBox(height: 3),
                              Text(
                                currentTrack!.artistName!,
                                style: textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _buildFavoriteButton(cs, currentTrack),
                      _buildPlayButton(cs, currentTrack, isPlaying),
                    ],
                  ),
                  const SizedBox(height: _kWaveBandInset),
                  _buildWaveBand(cs, isPlaying),
                  const SizedBox(height: _kWaveBandInset),
                  // 底排常驻：档位按钮是这张卡上唯一的档位入口。
                  _buildBottomRow(cs, nextTracks),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          top: 0,
          child: _buildCurrentCover(cs, currentTrack),
        ),
      ],
    );
  }

  /// 律动线：长在右栏的缝里，靠负偏移贯穿到卡片左右两边，不留边距。
  ///
  /// [Stack] 不裁剪，越出的那段落在封面所在的层之下。[IgnorePointer] 让手势穿过去。
  Widget _buildWaveBand(ColorScheme cs, bool isPlaying) {
    return SizedBox(
      height: _kWaveBandHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -(_kPanelPadding + _kCoverSize + _kCoverGap),
            right: -_kPanelPadding,
            top: 0,
            height: _kWaveBandHeight,
            child: IgnorePointer(
              child: WavyPlaybackLine(
                isPlaying: isPlaying,
                color: isPlaying ? cs.primary : cs.outlineVariant,
                height: _kWaveBandHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentCover(ColorScheme cs, KugouSongDetail? currentTrack) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(_kCoverRadius),
      child: SizedBox(
        width: _kCoverSize,
        height: _kCoverSize,
        child: currentTrack == null
            ? _buildCoverPlaceholder(cs, iconSize: 36)
            : _buildCover(cs, currentTrack, cacheSize: 336, iconSize: 36),
      ),
    );
    if (currentTrack == null) return cover;
    return _buildTappableCover(
      cover: cover,
      radius: _kCoverRadius,
      semanticLabel: '正在播放 ${currentTrack.songName}',
      tooltip: '打开播放详情',
      onTap: () => _openTrack(currentTrack),
    );
  }

  /// 预告封面能放几张按可用宽度算：先扣掉右端常驻的档位按钮和它左边的一份间距，
  /// 否则窄屏上封面会顶到按钮身上。
  Widget _buildBottomRow(ColorScheme cs, List<KugouSongDetail> nextTracks) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 最后一张右边不需要间距，所以先补一份再按「封面 + 间距」整除。
        final slot = _kNextCoverSize + _kNextCoverGap;
        final available =
            constraints.maxWidth -
            _kStationButtonSize -
            _kStationButtonRightInset -
            _kNextCoverGap;
        final fits = ((available + _kNextCoverGap) / slot).floor();
        final count = fits.clamp(0, nextTracks.length);
        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _kNextCoverGap),
              _buildNextCover(cs, nextTracks[i]),
            ],
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: _kStationButtonRightInset),
              child: _buildStationButton(cs),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNextCover(ColorScheme cs, KugouSongDetail track) {
    return _buildTappableCover(
      cover: ClipRRect(
        borderRadius: BorderRadius.circular(_kNextCoverRadius),
        child: SizedBox(
          width: _kNextCoverSize,
          height: _kNextCoverSize,
          child: _buildCover(cs, track, cacheSize: 144, iconSize: 18),
        ),
      ),
      radius: _kNextCoverRadius,
      semanticLabel: '接下来播放 ${track.songName}',
      tooltip: '播放：${track.songName}',
      onTap: () => _openTrack(track),
    );
  }

  /// 透明 Material + InkWell 必须叠在封面**上面**：水波纹画在它所属 Material 的
  /// 表面上，在下层会被不透明的封面整个挡住。
  Widget _buildTappableCover({
    required Widget cover,
    required double radius,
    required String semanticLabel,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return MergeSemantics(
      child: Semantics(
        label: semanticLabel,
        child: Tooltip(
          message: tooltip,
          child: Stack(
            children: [
              cover,
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(radius),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(onTap: onTap),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 只订阅当前曲目那一个布尔值：点收藏不该把带网络封面的整个区块重建一遍。
  Widget _buildFavoriteButton(ColorScheme cs, KugouSongDetail? currentTrack) {
    if (currentTrack == null) {
      return IconButton(
        tooltip: '收藏',
        onPressed: null,
        icon: const Icon(Icons.favorite_border),
        color: cs.onSurfaceVariant,
      );
    }
    return Selector<FavoritesProvider, bool>(
      selector: (_, favorites) => favorites.isFavorite(currentTrack.hash),
      builder: (context, isFavorite, _) {
        return IconButton(
          tooltip: isFavorite ? '取消收藏' : '收藏',
          onPressed: () => context.read<FavoritesProvider>().toggleFavorite(
            currentTrack.toSong(),
          ),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? cs.primary : cs.onSurfaceVariant,
        );
      },
    );
  }

  Widget _buildPlayButton(
    ColorScheme cs,
    KugouSongDetail? currentTrack,
    bool isPlaying,
  ) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _handlePlayPersonalFm(currentTrack),
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: _isLoading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: M3ELoadingIndicator(color: cs.primary),
                  )
                : Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: cs.primary,
                    size: 28,
                  ),
          ),
        ),
      ),
    );
  }

  /// 走 [CachedNetworkImage] 而不是 Image.network：后者每次重建都重新走网络。
  Widget _buildCover(
    ColorScheme cs,
    KugouSongDetail track, {
    required int cacheSize,
    required double iconSize,
  }) {
    final url = track.artworkUri;
    if (url == null || url.isEmpty) {
      return _buildCoverPlaceholder(cs, iconSize: iconSize);
    }
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: cacheSize,
      memCacheHeight: cacheSize,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      placeholder: (_, _) => _buildCoverPlaceholder(cs, iconSize: iconSize),
      errorWidget: (_, _, _) => _buildCoverPlaceholder(cs, iconSize: iconSize),
    );
  }

  Widget _buildCoverPlaceholder(ColorScheme cs, {required double iconSize}) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note,
          size: iconSize,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
