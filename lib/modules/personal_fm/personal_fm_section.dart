import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/remote/tv_card_focus.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '_fm_refill.dart';
import 'personal_fm_core.dart';

const double _kCardRadius = 20.0;
const double _kCoverRadius = 16.0;
const double _kCoverSize = 112.0;
const double _kCoverGap = 12.0;
const double _kNextCoverSize = 48.0;
const double _kNextCoverRadius = 12.0;
const double _kNextCoverGap = 8.0;

/// 档位按钮的边长：与预告封面 / 「不喜欢」同尺寸同圆角（48 圆角矩形），底排右端
/// 那两枚按钮因此与上排 48dp 的播放按钮天然圆心对齐，不再需要补差值内衬。
const double _kStationButtonSize = 48.0;

/// 律动线的带高与上下留白：3 + 10 + 3 = 16dp 的缝把右栏两排撑到与封面等高，
/// 线的中线因此落在播放按钮与档位按钮圆心的正中。
const double _kWaveBandHeight = 10.0;
const double _kWaveBandInset = 3.0;

/// 「正在播」面板的内边距。律动线靠它的负值贯穿到卡片两边。
const double _kPanelPadding = 16.0;

const Duration _kDrawerDuration = Duration(milliseconds: 260);
const Curve _kDrawerCurve = Curves.easeInOutCubicEmphasized;

Color _containerColor(ColorScheme cs) => cs.surfaceContainerLow;

/// 抽屉那一层的底色。不能用 surfaceDim：深色主题下它与页面底色 surface 同值，
/// 抽屉展开后看起来就是没有背景。
Color _drawerColor(ColorScheme cs) => cs.secondaryContainer;

Color _onDrawerColor(ColorScheme cs) => cs.onSecondaryContainer;

/// 发现页内嵌的私人 FM 区块：登录后是电台卡，未登录是登录引导卡。
///
/// 与完整 FM 页的差异：加载后不自动开播、不做「列表顺序反向同步回播放器」、
/// 档位是 4 个具名预设。起播后同样是无限电台，补货由 [FmRefill] 负责——它不挂在
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

  /// 本区块最近一次起播用的续播器。只为「不喜欢」带回的替换批次能被它认领
  /// （见 [FmRefill.adopt]）：所有权集合漏了这些 hash，电台下一刻就会把自己灌进
  /// 队列的歌判成「别人抢了队列」而退场，从此不再补货。
  ///
  /// 不持有、不 dispose——续播器的生命周期归它自己（退场由 `onPlaylistEnd`
  /// 槽位易主驱动），这里只是留一份引用。
  FmRefill? _refill;

  FmStation get _station => kFmStations[_stationIndex];

  @override
  void initState() {
    super.initState();
    // 小部件上切过档：同步本区块档位（列表已由动作处理器重拉，这里不重拉）。
    PersonalFmWidgetActions.onStationChanged = _onWidgetStationChanged;
    // initState 里读不到 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reviveRefillIfNeeded();
      _restoreStation();
    });
  }

  void _onWidgetStationChanged(int index) {
    if (!mounted || index == _stationIndex) return;
    if (index < 0 || index >= kFmStations.length) return;
    setState(() => _stationIndex = index);
  }

  @override
  void dispose() {
    if (PersonalFmWidgetActions.onStationChanged == _onWidgetStationChanged) {
      PersonalFmWidgetActions.onStationChanged = null;
    }
    // 只丢引用，不动 `onPlaylistEnd` 槽位：续播器不依赖本 State，切走发现页也要
    // 照常续播（见 [FmRefill] 的类注释）。这里清掉是为了不让已销毁的 State 被
    // 续播器间接持有。
    _refill = null;
    super.dispose();
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
    if (stationIndex < 0 || stationIndex >= kFmStations.length) return;
    if (stationIndex != _stationIndex) {
      setState(() => _stationIndex = stationIndex);
    }
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final generation = FmRefillStore.nextGeneration();
    final refill = FmRefill(
      kugou: kugou,
      player: player,
      mode: _station.mode,
      songPoolId: _station.songPoolId,
      songs: const [],
      adoptQueue: true,
      sessionGeneration: generation,
    );
    player.onPlaylistEnd = refill.onQueueEnd;
    _refill = refill;
    // ignore: discarded_futures
    refill.append();
  }

  /// 恢复上次选的档位。发现页首屏已按保存档位拉过一批（见 [DiscoverPage] 的
  /// _loadAllData），所以这里通常只把档位同步过来、不重拉——两次结果都写
  /// _personalFmSongs 会让卡片内容当场翻一次；只有列表为空（首拉失败等）才补拉。
  /// 正在放本电台的歌时也不能重拉：列表一换，正在播的那首就不在列表里了。
  Future<void> _restoreStation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getInt(_kStationPrefKey) ?? 0;
    if (saved < 0 || saved >= kFmStations.length) return;
    if (saved != _stationIndex) {
      setState(() => _stationIndex = saved);
    }

    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final playingId = Provider.of<PlayerProvider>(
      context,
      listen: false,
    ).currentSong?.id;
    if (playingId != null &&
        kugou.personalFmSongs.any((s) => s.hash == playingId)) {
      return;
    }
    if (kugou.personalFmSongs.isNotEmpty) return;
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
  /// 也不影响它续播；上一个续播器会在下一次播放器通知里自己退场（见 [FmRefill]）。
  ///
  /// [adoptQueue] 供「槽位空了但队列还在放」的自愈路径用，见 [_handlePlayPersonalFm]。
  FmRefill? _armRefill(
    KugouProvider kugou,
    PlayerProvider player, {
    bool adoptQueue = false,
  }) {
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return null;
    final generation = FmRefillStore.nextGeneration();
    final refill = FmRefill(
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
    _refill = refill;
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
    openFullPlayer(context);
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

  /// 「不喜欢」：上报 garbage，把替换批次接进列表与队列，再让电台往前走。
  ///
  /// 上报与写回都在 [dislikeFmTrack]（与完整 FM 页共用一份实现），这里只负责两件
  /// 本地事：把替换批次交给续播器认领、决定怎么「推进」。
  ///
  /// **推进分两种，不能一律 next()**：播放器停在本电台上时 next() 是唯一正确的做法；
  /// 但卡片渲染的是「播放器当前那一首，退不回列表第一首」——没起播时它渲染的就是
  /// 列表第一首，此时播放器放的是**别人的队列**，next() 推的是别人的歌。那种情况
  /// 只换一批推荐，不替用户起播（本区块的设计前提：加载后不自动开播）。
  Future<void> _handleDislike(KugouSongDetail track) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final onThisTrack = player.currentSong?.id == track.hash;
    try {
      final fresh = await dislikeFmTrack(
        kugou: kugou,
        player: player,
        track: track,
        mode: _station.mode,
        songPoolId: _station.songPoolId,
      );
      if (fresh == null) {
        // 空列表是「上游只回了 ack」，属上报成功，误报会让每次不喜欢都像坏了。
        showToast('不喜欢上报失败');
      } else if (fresh.isNotEmpty) {
        // 所有权的账要记上：不认领的话，电台播到这些歌时会以为自己被换下台。
        _refill?.adopt(fresh);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    if (!mounted) return;
    // 无论上报成败都推进——不喜欢不能被一次反馈 ping 卡住。
    if (onThisTrack) {
      await player.next();
    } else {
      await _loadPersonalFm();
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
            rootNavigator: true,
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
            // 与「不喜欢」、预告封面同一枚圆角矩形（48 / 12），不再用胶囊。
            borderRadius: BorderRadius.circular(_kNextCoverRadius),
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
      segments: kFmStations
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
                      // 收藏与播放之间垫一份封面缝（8dp）：底排的「不喜欢」与档位
                      // 正是这个缝宽（圆心 288 / 344），上排紧贴时收藏圆心落在 296，
                      // 上下两列就错开 8dp。播放仍贴右缘，圆心与档位同为 344。
                      const SizedBox(width: _kNextCoverGap),
                      _buildPlayButton(cs, currentTrack, isPlaying),
                    ],
                  ),
                  const SizedBox(height: _kWaveBandInset),
                  _buildWaveBand(cs, isPlaying),
                  const SizedBox(height: _kWaveBandInset),
                  // 底排常驻：档位按钮是这张卡上唯一的档位入口，「不喜欢」作用于
                  // 卡片正在渲染的这一首（与收藏按钮同口径）。
                  _buildBottomRow(cs, currentTrack, nextTracks),
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

  /// 底排：预告封面靠左，右端是「不喜欢」+ 档位两枚同规格圆角矩形。
  ///
  /// 格数按可用宽度算。**两枚按钮各占掉一个封面位**：它们取代的就是原先右下角那
  /// 两张预告封面。代价是能放的预告更少，换来的是按钮有了常驻位置——把按钮叠在
  /// 封面上或另起一行都会让这张卡在窄屏上溢出。
  ///
  /// 先扣掉右端常驻的两枚按钮（各带一份左边距）再整除，否则窄屏上封面会顶到
  /// 按钮身上。两枚按钮的圆心（288 / 344）是上排收藏与播放的对齐基准。
  Widget _buildBottomRow(
    ColorScheme cs,
    KugouSongDetail? currentTrack,
    List<KugouSongDetail> nextTracks,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 最后一张右边不需要间距，所以先补一份再按「封面 + 间距」整除。
        final slot = _kNextCoverSize + _kNextCoverGap;
        final available =
            constraints.maxWidth -
            (_kNextCoverSize + _kNextCoverGap) * 2;
        final fits = ((available + _kNextCoverGap) / slot).floor();
        final count = fits.clamp(0, nextTracks.length);
        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _kNextCoverGap),
              _buildNextCover(cs, nextTracks[i]),
            ],
            const Spacer(),
            // 只在左边真有封面时才要这一份间距；没有封面时它是白占宽度，
            // 极窄屏上会让整排溢出。
            if (count > 0) const SizedBox(width: _kNextCoverGap),
            _buildDislikeButton(cs, currentTrack),
            const SizedBox(width: _kNextCoverGap),
            _buildStationButton(cs),
          ],
        );
      },
    );
  }

  /// 「不喜欢」：上报 garbage 并换掉这一首，与完整 FM 页同一套行为
  /// （见 [dislikeFmTrack]）。尺寸/圆角刻意与旁边的预告封面一致，读起来就是
  /// 「这里原本有一张封面」。
  Widget _buildDislikeButton(ColorScheme cs, KugouSongDetail? currentTrack) {
    final button = MergeSemantics(
      child: Semantics(
        button: true,
        // currentTrack 为空时按钮是禁用的，语义上不该说「可以点」。
        enabled: currentTrack != null,
        label: '不喜欢这首歌',
        excludeSemantics: true,
        child: Tooltip(
          message: '不喜欢',
          child: Material(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(_kNextCoverRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: currentTrack == null
                  ? null
                  : () => _handleDislike(currentTrack),
              child: SizedBox(
                width: _kNextCoverSize,
                height: _kNextCoverSize,
                child: Center(
                  child: Icon(
                    Icons.thumb_down_rounded,
                    size: 20,
                    color: currentTrack == null
                        ? cs.onSurfaceVariant.withValues(alpha: 0.38)
                        : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // tv: 单停点，OK = 原 onTap。currentTrack 为空时不传 onSelect，
    // TvCardFocus 由此不制造死停点（遥控焦点落上去却什么都做不了）。
    return TvCardFocus(
      onSelect: currentTrack == null
          ? null
          : () => _handleDislike(currentTrack),
      debugLabel: 'discover-fm-dislike',
      child: button,
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

  /// 本地收藏写完之后，往电台接口静默补一次红心回报。
  ///
  /// 档位取区块当前的 [_station]——与起播用的是同一个来源，所以回报的
  /// (mode, songPoolId) 一定和用户此刻看到的档位一致。失败只写日志不弹提示：
  /// 这次点击的反馈已经由本地收藏那次给过了，口径见 [reportFmFeedback]。
  void _reportFmAction({
    required String action,
    required KugouSongDetail track,
  }) {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    // ignore: discarded_futures
    reportFmFeedback(
      kugou: kugou,
      action: action,
      mode: _station.mode,
      songPoolId: _station.songPoolId,
      track: track,
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
          onPressed: () {
            context.read<FavoritesProvider>().toggleFavorite(
              currentTrack.toSong(),
            );
            // isFavorite 是切换**前**的值：已红心 → 这次点的是取消红心。
            _reportFmAction(
              action: isFavorite ? 'cancel_red' : 'click_red',
              track: currentTrack,
            );
          },
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
