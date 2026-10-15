import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import 'personal_fm_core.dart';
import 'personal_fm_page_preferences.dart';

/// 竖屏 hero 里封面的尺寸上限（按可用宽度收缩前的封顶）。
const double _kHeroCoverMax = 320.0;

/// 横屏两栏时封面按**视口高度**取的比例与下限。
///
/// 两栏后卡片只占左列宽度，封面不再受整页宽度约束；反过来必须受高度约束，否则
/// 封面沿用竖屏的 320 会把卡片的曲名与动作行顶出屏幕。
///
/// 0.36 的来源：卡片横排后的高度 = 内衬 48 + 封面 + 缝 24 + 动作行 64，而 420 高
/// 的横屏视口扣掉顶栏 56、正文顶衬 12、引导语与其下缝 44、底衬 16 后只剩 ~292
/// 可给卡片，于是封面的地板上限约 156 ≈ 0.37 × 420。取 0.36 让动作按钮**落在首屏内**
/// ——这正是把按钮留在卡片里的前提；再高就要靠滚动才摸得到播放键了。
/// 更矮的横屏（360 一类）由 [_kLandscapeCoverMin] 兜住可辨识度，差额交给整页
/// `SingleChildScrollView`：分栏要保证的是右列档位与队列不再被压到一整屏之下。
const double _kLandscapeCoverHeightFraction = 0.36;
const double _kLandscapeCoverMin = 120.0;

/// 横屏「正在播」卡片内部横排时，文字/按钮那一侧至少留出的宽度。
///
/// 封面是正方形，它的边长在横排下**同时**受高度预算与宽度预算夹制：宽度预算 =
/// 卡内宽 − 封面与文字的间距 − 这一侧的地板。少了这道地板，窄横屏上封面会把
/// 曲名与动作按钮压成一条竖不起来的窄缝。
const double _kLandscapeHeroMinTextWidth = 160.0;

/// 横屏两栏的左右配比：左列卡片内部横排（封面 + 文字 + 动作按钮），右列只放
/// 两组切换器与即将播放队列。
const int _kTwoPaneLeftFlex = 7;
const int _kTwoPaneRightFlex = 5;

/// 私人 FM 独立页面。
///
/// UI 采用 Material 3 Expressive（m3e_core）：大封面 hero + 即将播放分段队列，
/// 档位 / 歌池用 [M3EToggleButtonGroup]，动作钮用 [M3EFilledButton]。
/// 业务逻辑（取数、续播、反馈上报、状态持久化、TV 焦点）保持不变。
///
/// 注意：本页只用 `material_ui` + `m3e_core`，**不得**引入
/// `package:flutter/material.dart` 的 InkWell/Material 等真·flutter ink 组件
/// （material_ui 的 Scaffold 插的是它自家同名 Material，flutter 的 ink 组件
/// 找不到祖先会抛 `No Material widget found`，见 AGENTS §4.13）。
class PersonalFmPage extends StatefulWidget {
  const PersonalFmPage({super.key});

  @override
  State<PersonalFmPage> createState() => _PersonalFmPageState();
}

class _PersonalFmPageState extends State<PersonalFmPage> {
  bool _isLoading = false;
  bool _isAppending = false;
  String _selectedMode = 'normal';
  int _selectedSongPoolId = 0;
  bool _strategyTouched = false;
  final int _visibleSideCount = 3;

  /// tv: 即将播放队列当前聚焦下标（由 [M3ESegmentedList.onFocusChange] 回填，
  /// 供 OK 键 [ActivateIntent] 取用）。
  int _focusedQueueIndex = 0;

  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享。
  final ScrollController _scrollController = ScrollController();

  /// 防止 _playSong 期间 _syncFmListToPlayer 把已移到首位的歌曲移回去。
  bool _syncEnabled = true;

  final List<Map<String, dynamic>> _modeOptions = [
    {'value': 'normal', 'label': '红心'},
    {'value': 'small', 'label': '小众'},
    {'value': 'peak', 'label': '速览'},
    {'value': 'radio', 'label': '电台'},
  ];

  final List<Map<String, dynamic>> _songPoolOptions = [
    {'value': 0, 'label': '根据口味'},
    {'value': 1, 'label': '根据风格'},
    {'value': 2, 'label': '探索'},
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_restoreStrategy());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _player = Provider.of<PlayerProvider>(context, listen: false)
        ..addListener(_onPlayerChanged);
    });
  }

  PlayerProvider? _player;

  Future<void> _restoreStrategy() async {
    final selection = await PersonalFmPagePreferences.load();
    if (!mounted || _strategyTouched) return;

    final modeIsValid = _modeOptions.any(
      (option) => option['value'] == selection.mode,
    );
    final songPoolIsValid = _songPoolOptions.any(
      (option) => option['value'] == selection.songPoolId,
    );
    if (!modeIsValid && !songPoolIsValid) return;

    setState(() {
      if (modeIsValid) _selectedMode = selection.mode;
      if (songPoolIsValid) _selectedSongPoolId = selection.songPoolId;
    });
  }

  void _selectStrategy({String? mode, int? songPoolId}) {
    _strategyTouched = true;
    setState(() {
      if (mode != null) _selectedMode = mode;
      if (songPoolId != null) _selectedSongPoolId = songPoolId;
    });
    unawaited(
      PersonalFmPagePreferences.save(
        mode: _selectedMode,
        songPoolId: _selectedSongPoolId,
      ),
    );
    unawaited(_loadPersonalFm());
  }

  int _lastPrefetchIndex = -1;

  /// 上一次已回报的曲目 id（切歌时用来判断「换了一首歌」）。
  String? _lastReportedTrackId;

  /// [_onPlayerChanged] 每次回调采样的当前进度秒数，切歌时作为上一首的
  /// playtime 上送（§10：不新增 Timer，只借这个已有的播放器回调取样）。
  int? _lastKnownPosSeconds;

  /// 上一首所在的 FM 曲目详情（保留整条是为了读它的 curMark / duration）。
  KugouSongDetail? _lastFmTrack;

  void _onPlayerChanged() {
    if (!mounted) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    _reportFmPlayIfNeeded(player);
    _syncFmListToPlayer(player);
    _proactivePrefetch(player);
  }

  /// 切歌时把「上一首 FM 歌」的播放时长/是否播完回报上游（action=play）。
  ///
  /// 只借已有的 [_onPlayerChanged] 取样，不新增任何 Timer/Ticker（§10）。上一首
  /// 不在 [KugouProvider.personalFmSongs] 里就跳过——别把别的队列的播放行为污染成
  /// FM 反馈。回报是 fire-and-forget，失败只记日志、绝不 toast。
  void _reportFmPlayIfNeeded(PlayerProvider player) {
    final currentId = player.currentSong?.id;
    // 本次采样到的进度，留待下一次切歌时作为「本条」的 playtime。
    final posSeconds = player.position.inSeconds;

    if (currentId != null && currentId != _lastReportedTrackId) {
      final prev = _lastFmTrack;
      if (prev != null && _lastReportedTrackId != null) {
        final kugou = Provider.of<KugouProvider>(context, listen: false);
        if (kugou.personalFmSongs.any((s) => s.hash == prev.hash)) {
          final dur = prev.duration; // 秒
          final overplay = dur > 0 && (_lastKnownPosSeconds ?? 0) >= dur - 2;
          // ignore: discarded_futures
          _reportFmPlay(kugou, prev, _lastKnownPosSeconds, overplay);
        }
      }
      _lastReportedTrackId = currentId;
      _lastFmTrack = _findFmTrack(currentId);
    }
    _lastKnownPosSeconds = posSeconds;
  }

  /// 按 id 在当前 FM 列表里找那条曲目详情，找不到返回 null。
  KugouSongDetail? _findFmTrack(String? id) {
    if (id == null) return null;
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final idx = kugou.personalFmSongs.indexWhere((s) => s.hash == id);
    return idx >= 0 ? kugou.personalFmSongs[idx] : null;
  }

  Future<void> _reportFmPlay(
    KugouProvider kugou,
    KugouSongDetail track,
    int? playtime,
    bool isOverplay,
  ) async {
    debugPrint(
      '[PersonalFm] action=play playtime=${playtime ?? 0}s overplay=$isOverplay',
    );
    try {
      await kugou.reportPersonalFmAction(
        action: 'play',
        mode: _selectedMode,
        songPoolId: _selectedSongPoolId,
        hash: track.hash,
        songId: track.songId,
        curMark: track.curMark,
        playtime: playtime,
        isOverplay: isOverplay,
      );
    } catch (e) {
      debugPrint('[PersonalFm] action=play failed: $e');
    }
  }

  void _proactivePrefetch(PlayerProvider player) {
    if (player.playlist.isEmpty) return;
    final idx = player.currentIndex;
    if (idx < 0) return;
    final remaining = player.playlist.length - idx;
    if (remaining <= 3 && idx != _lastPrefetchIndex) {
      _lastPrefetchIndex = idx;
      _appendFmSongs();
    }
  }

  @override
  void dispose() {
    final player = _player;
    if (player != null) {
      player.removeListener(_onPlayerChanged);
      // 交还补货槽位。留着一个指向已销毁 State 的回调有两重害处：队列播完时
      // PlayerProvider 只看槽位非空就把「播完」整个交给它（自己的「回到第一首」
      // 兜底被跳过），而它第一句就要 context —— 抛出来的异常没人接。
      if (player.onPlaylistEnd == _onPlaylistEnd) {
        player.onPlaylistEnd = null;
      }
    }
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPersonalFm() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await Provider.of<KugouProvider>(
        context,
        listen: false,
      ).getPersonalFm(mode: _selectedMode, songPoolId: _selectedSongPoolId);
      if (!mounted) return;
      final kugou = Provider.of<KugouProvider>(context, listen: false);
      if (kugou.personalFmSongs.isNotEmpty) {
        final player = Provider.of<PlayerProvider>(context, listen: false);
        player.onPlaylistEnd = _onPlaylistEnd;
        await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
      }
    } catch (e) {
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    if (mounted) {
      _appendFmSongs();
    }
  }

  Future<void> _onPlaylistEnd() async {
    if (!mounted) return;
    final prevLength = Provider.of<PlayerProvider>(
      context,
      listen: false,
    ).playlist.length;
    await _appendFmSongs();
    if (!mounted) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.playlist.length > prevLength) {
      await player.next();
    } else {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final p2 = Provider.of<PlayerProvider>(context, listen: false);
      final retryPrev = p2.playlist.length;
      _isAppending = false;
      await _appendFmSongs();
      if (mounted && p2.playlist.length > retryPrev) {
        await p2.next();
      }
    }
  }

  Future<void> _appendFmSongs() async {
    if (_isAppending || !mounted) return;
    setState(() => _isAppending = true);
    try {
      final kugou = Provider.of<KugouProvider>(context, listen: false);
      final currentSongs = kugou.personalFmSongs;
      final lastSong = currentSongs.isNotEmpty ? currentSongs.last : null;

      List<KugouSongDetail>? result;
      try {
        result = await kugou.apiClient.getPersonalFm(
          mode: _selectedMode,
          songPoolId: _selectedSongPoolId,
          hash: lastSong?.hash,
          songId: lastSong?.songId,
          action: 'play',
        );
      } catch (_) {
        result = await kugou.apiClient.getPersonalFm(
          mode: _selectedMode,
          songPoolId: _selectedSongPoolId,
          action: 'play',
        );
      }
      if (!mounted) return;

      if (result != null && result.isNotEmpty) {
        final newSongs = result
            .where((s) => !currentSongs.any((c) => c.hash == s.hash))
            .toList();
        if (newSongs.isNotEmpty) {
          kugou.appendFmSongs(newSongs);
          final player = Provider.of<PlayerProvider>(context, listen: false);
          final newSongList = newSongs.map((e) => e.toSong()).toList();
          await player.appendPlaylist(newSongList);
        }
      }
    } catch (e) {
    } finally {
      if (mounted) {
        setState(() => _isAppending = false);
      }
    }
  }

  /// 播放队列里点到的某一首：把它移到 FM 列表首位并接一批新曲，再整队播放。
  ///
  /// 时序不能简化：moveToFirst → _appendFmSongs → playOnlinePlaylist，且全程
  /// `_syncEnabled=false`，防止 [_syncFmListToPlayer] 把新歌移回旧歌。
  Future<void> _playSong(KugouSongDetail song) async {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final songs = kugou.personalFmSongs;

    final index = songs.indexWhere((s) => s.hash == song.hash);
    if (index == -1) return;

    _syncEnabled = false;
    try {
      kugou.moveToFirst(song);
      await _appendFmSongs();
      if (!mounted) return;
      await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
    } finally {
      _syncEnabled = true;
    }
  }

  Future<void> _togglePlay() async {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.resume();
    }
  }

  void _syncFmListToPlayer(PlayerProvider player) {
    if (!_syncEnabled) return;
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty || player.playlist.isEmpty) return;

    final currentSong = player.currentSong;
    if (currentSong == null) return;

    final index = songs.indexWhere((s) => s.hash == currentSong.id);
    if (index > 0) {
      kugou.moveToFirst(songs[index]);
    }
  }

  /// 「不喜欢」：上报 garbage，把上游带回的替换批次去重后接入 FM 列表与播放
  /// 队列，再切到下一首。
  ///
  /// 具体实现收在 [dislikeFmTrack]（与发现页区块共用同一份：两边的业务语义必须
  /// 逐字一致，抄两遍必然漂）。上报失败（null/异常）不阻断用户动作：记日志 +
  /// 轻提示后**仍然切歌**。
  Future<void> _handleDislike(KugouSongDetail track) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    try {
      final result = await dislikeFmTrack(
        kugou: kugou,
        player: player,
        track: track,
        mode: _selectedMode,
        songPoolId: _selectedSongPoolId,
      );
      // 只有请求本身失败（_get 吞掉一切错误返回 null）才提示；空列表是「上游只
      // 回了 ack、没带回替换批次」，属于上报成功，误报会让每次不喜欢都像坏了。
      if (result == null) {
        showToast('不喜欢上报失败');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    // 无论上报成败都推进——不喜欢不能被一次反馈 ping 卡住。
    await player.next();
  }

  /// 红心双写：本地收藏（[FavoritesProvider]）为准先切，再向后上游回报
  /// click_red / cancel_red。第二次写是 fire-and-forget：失败只记日志，绝不 toast、
  /// 不阻断（`wasFavorite` 由调用方从 Selector 值传入，切换前读取）。
  void _handleRedHeart(KugouSongDetail track, bool wasFavorite) {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final favorites = Provider.of<FavoritesProvider>(context, listen: false);
    final action = wasFavorite ? 'cancel_red' : 'click_red';
    debugPrint(
      '[PersonalFm] action=$action hash=${track.hash} curMark=${track.curMark}',
    );
    // ignore: discarded_futures
    _applyRedHeart(favorites, kugou, track, action);
  }

  Future<void> _applyRedHeart(
    FavoritesProvider favorites,
    KugouProvider kugou,
    KugouSongDetail track,
    String action,
  ) async {
    try {
      await favorites.toggleFavorite(track.toSong());
    } catch (e) {
      debugPrint('[PersonalFm] toggleFavorite failed: $e');
    }
    try {
      await kugou.reportPersonalFmAction(
        action: action,
        mode: _selectedMode,
        songPoolId: _selectedSongPoolId,
        hash: track.hash,
        songId: track.songId,
        curMark: track.curMark,
      );
    } catch (e) {
      debugPrint('[PersonalFm] action=$action failed: $e');
    }
  }

  String _formatDuration(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _getModeLabel(String mode) {
    switch (mode) {
      case 'normal':
        return '红心';
      case 'small':
        return '小众';
      case 'peak':
        return '速览';
      case 'radio':
        return '电台';
      default:
        return '红心';
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
    final currentTrack = songs.isNotEmpty ? songs[0] : null;
    final isPlaying =
        player.currentSong?.id == currentTrack?.hash && player.isPlaying;

    final List<KugouSongDetail> sideTracks = songs.length > 1
        ? songs.sublist(1).take(_visibleSideCount).toList()
        : const <KugouSongDetail>[];

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '私人 FM',
        opaque: true,
        tabId: 'fm',
        scrollController: _scrollController,
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        // 底部叠加系统手势条（小横条）高度，避免末项被压住
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.md,
          bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.maxContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '实时推荐会根据你的反馈持续更新',
                  style: textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
                const Gap(AppSpacing.xl),
                if (!isLoggedIn)
                  _buildEmptyState(cs, textTheme)
                else
                  _buildRecommendationBody(
                    cs,
                    textTheme,
                    currentTrack,
                    sideTracks,
                    isPlaying,
                  ),
                const Gap(AppSpacing.xxl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 登录后的推荐主体：竖屏单栏，横屏两栏。
  ///
  /// **横屏分栏的动机**：竖屏把「卡片 → 档位 → 队列」竖着摞三块，横屏时视口高度
  /// 只剩一半出头，队列几乎要到屏幕外才看得见。分栏后左列是完整的「正在播」卡片
  /// （封面 + 信息 + 动作按钮，内部改横排压缩高度），右列只有两组切换器与即将播放。
  ///
  /// **动作按钮留在卡片里**（[wide] 横排，而不是把它们搬去右列）：红心 / 不喜欢 /
  /// 播放控制的就是左列那首歌，和歌名封面同属一个语义块；单独搬走会让卡片变成
  /// 一张只能看的图，操作和对象分处两栏也要眼睛先做配对。
  ///
  /// 分栏判据只取方向、不看宽度：横屏即分栏（内容区另有 [AppLayout.maxContentWidth]
  /// 上限，见 [build]），窄横屏也仍有 400dp 以上的可用高度。
  Widget _buildRecommendationBody(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    List<KugouSongDetail> sideTracks,
    bool isPlaying,
  ) {
    final bool twoPane =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    if (!twoPane) {
      // 竖屏路径逐字保持原样（含 tv 包装的位置）。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTvTransportKeys(
            currentTrack: currentTrack,
            isPlaying: isPlaying,
            child: _buildHeroCard(cs, textTheme, currentTrack, isPlaying),
          ),
          const Gap(AppSpacing.xl),
          _buildControls(),
          const Gap(AppSpacing.xl),
          _buildUpcomingQueue(cs, textTheme, sideTracks),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 左列：完整「正在播」卡片（内部横排，动作按钮仍在卡内） ──
        // tv: 左右键切歌 / OK 播放暂停的包装与竖屏同位——动作按钮仍在卡片内，
        // 落点就还在这一层（见 [_buildTvTransportKeys]）。
        Expanded(
          flex: _kTwoPaneLeftFlex,
          child: _buildTvTransportKeys(
            currentTrack: currentTrack,
            isPlaying: isPlaying,
            child: _buildHeroCard(
              cs,
              textTheme,
              currentTrack,
              isPlaying,
              wide: true,
            ),
          ),
        ),
        const Gap(AppSpacing.xl),
        // ── 右列：档位/歌池 → 即将播放 ──
        Expanded(
          flex: _kTwoPaneRightFlex,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildControls(),
              const Gap(AppSpacing.xl),
              _buildUpcomingQueue(cs, textTheme, sideTracks),
            ],
          ),
        ),
      ],
    );
  }

  // ────────────────────────────── 空态 ──────────────────────────────

  Widget _buildEmptyState(ColorScheme cs, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              borderRadius: AppRadius.xlAll,
              color: cs.primaryContainer,
            ),
            child: Icon(
              Icons.favorite_rounded,
              size: 40,
              color: cs.onPrimaryContainer,
            ),
          ),
          const Gap(AppSpacing.lg),
          Text(
            '登录后查看私人 FM',
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '猜你喜欢和实时推荐需要登录状态',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────── 推荐控制 ──────────────────────────────

  /// 档位（推荐模式）+ 歌池（推荐来源）两组 connected 按钮，水平居中，
  /// 放在「即将播放」队列上方。
  Widget _buildControls() {
    final modeIndex = _modeOptions.indexWhere(
      (o) => o['value'] == _selectedMode,
    );
    final poolIndex = _songPoolOptions.indexWhere(
      (o) => o['value'] == _selectedSongPoolId,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // tv: 切换器是连体按钮组，自带焦点节点，靠区域语义导航，不再逐个包
        // DpadFocusable（避免双停点，与歌手页 Tab 行同口径）。
        TvScrollRegion(
          memoryKey: 'tv/fm-mode',
          child: Center(
            child: M3EToggleButtonGroup(
              actions: [
                for (final o in _modeOptions)
                  M3EToggleButtonGroupAction(label: Text(o['label'] as String)),
              ],
              size: M3EButtonSize.sm,
              density: M3EButtonGroupDensity.compact,
              selectedIndex: modeIndex,
              onSelectedIndexChanged: (index) {
                if (index == null || index < 0) return;
                _selectStrategy(mode: _modeOptions[index]['value'] as String);
              },
            ),
          ),
        ),
        const Gap(AppSpacing.md),
        TvScrollRegion(
          memoryKey: 'tv/fm-pool',
          child: Center(
            child: M3EToggleButtonGroup(
              actions: [
                for (final o in _songPoolOptions)
                  M3EToggleButtonGroupAction(label: Text(o['label'] as String)),
              ],
              size: M3EButtonSize.sm,
              density: M3EButtonGroupDensity.compact,
              selectedIndex: poolIndex,
              onSelectedIndexChanged: (index) {
                if (index == null || index < 0) return;
                _selectStrategy(
                  songPoolId: _songPoolOptions[index]['value'] as int,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ────────────────────────────── 大封面 hero ──────────────────────────────

  /// 「正在播」卡片：封面 + 曲名 + 歌手 + 信息 pills + 动作按钮行。
  ///
  /// [wide] 为 true（横屏两栏的左列）时卡片**内部**改横排：封面与文字块并排、
  /// 动作行整宽垫底。竖排的卡片高度 = 封面 + 曲名 + pills + 动作行，横屏视口
  /// 只有 360~420 高，封面稍有规模动作行就被顶出首屏——而动作按钮属于这首歌，
  /// 不能搬去右列。横排把高度从「封面 + 全部文字」压成「封面与文字取大 + 动作行」，
  /// 按钮就留在屏内了。为 false 即原竖排，与改动前逐像素一致。
  Widget _buildHeroCard(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    bool isPlaying, {
    bool wide = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double inner = constraints.maxWidth - AppSpacing.xl * 2;
        final Widget texts = _buildHeroTexts(cs, textTheme, currentTrack);

        // 刻意不用 math.min：本文件没有 dart:math 依赖，为此加一行 import 不值得。
        double min2(double a, double b) => a < b ? a : b;

        if (wide) {
          // 封面边长同时受三个预算夹制：竖屏同源的宽度上限、横排的高度预算、
          // 以及「给文字侧留出地板」的宽度预算。
          final double heightBudget = (MediaQuery.sizeOf(context).height *
                  _kLandscapeCoverHeightFraction)
              .clamp(_kLandscapeCoverMin, _kHeroCoverMax);
          final double sideBySide =
              inner - AppSpacing.xl - _kLandscapeHeroMinTextWidth;
          final double coverSize = min2(
            min2(heightBudget, sideBySide > _kLandscapeCoverMin
                ? sideBySide
                : _kLandscapeCoverMin),
            _kHeroCoverMax,
          );
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              borderRadius: AppRadius.xlAll,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [cs.surfaceContainerHigh, cs.surfaceContainerLow],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: coverSize,
                      height: coverSize,
                      child: _cover(currentTrack, coverSize, cs, radius: 24),
                    ),
                    const Gap(AppSpacing.xl),
                    Expanded(child: texts),
                  ],
                ),
                const Gap(AppSpacing.lg),
                _buildActionRow(cs, currentTrack, isPlaying),
              ],
            ),
          );
        }

        final double widthBudget =
            inner > _kHeroCoverMax ? _kHeroCoverMax : inner;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            borderRadius: AppRadius.xlAll,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cs.surfaceContainerHigh, cs.surfaceContainerLow],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: SizedBox(
                  width: widthBudget,
                  height: widthBudget,
                  child: _cover(currentTrack, widthBudget, cs, radius: 24),
                ),
              ),
              const Gap(AppSpacing.xl),
              texts,
              const Gap(AppSpacing.lg),
              _buildActionRow(cs, currentTrack, isPlaying),
            ],
          ),
        );
      },
    );
  }

  /// 卡片里封面之外的文字块（曲名 / 歌手 / 信息 pills）。竖排与横排共用一份，
  /// 保证两种形态下的内容与排版口径一致。
  Widget _buildHeroTexts(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          currentTrack != null ? currentTrack.songName : '暂无推荐',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const Gap(AppSpacing.xs),
        Text(
          currentTrack != null
              ? (currentTrack.artistName ?? '')
              : '点击播放，开始为你实时推荐',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        if (currentTrack != null) ...[
          const Gap(AppSpacing.md),
          _buildInfoPills(cs, textTheme, currentTrack),
        ],
      ],
    );
  }

  Widget _buildInfoPills(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail track,
  ) {
    Widget pill(String text, {Color? bg, Color? fg}) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: bg ?? cs.onSurfaceVariant.withValues(alpha: 0.06),
        ),
        child: Text(
          text,
          style: textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: fg ?? cs.onSurfaceVariant.withValues(alpha: 0.72),
          ),
        ),
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        pill(_formatDuration(track.duration)),
        pill('Hi-Res'),
        if (track.songName.contains('国')) pill('国语'),
        pill('相似度高'),
        pill(
          '${_getModeLabel(_selectedMode)} 实时推荐',
          bg: cs.primaryContainer,
          fg: cs.onPrimaryContainer,
        ),
      ],
    );
  }

  /// 动作行：红心 / 不喜欢（tonal 次级钮）+ 播放（filled 主钮）。
  ///
  /// 触屏与手机侧不新增上一首/下一首按钮（保持原有功能面），TV 的上一首/
  /// 下一首由 [_buildTvTransportKeys] 的方向键承担。
  Widget _buildActionRow(
    ColorScheme cs,
    KugouSongDetail? currentTrack,
    bool isPlaying,
  ) {
    final Widget heart;
    if (currentTrack == null) {
      heart = TvCardFocus(
        debugLabel: 'fm-red-heart-disabled',
        child: M3EFilledButton.tonal(
          onPressed: null,
          tooltip: '收藏',
          shape: M3EButtonShape.round,
          decoration: const M3EButtonDecoration(
            fixedSize: Size(52, 52),
            padding: EdgeInsets.zero,
          ),
          child: const Icon(Icons.favorite_border, size: 26),
        ),
      );
    } else {
      heart = Selector<FavoritesProvider, bool>(
        // 红心：只订阅当前曲目那一个布尔值，点收藏不该把整块（含网络封面）重建一遍。
        selector: (_, favorites) => favorites.isFavorite(currentTrack.hash),
        builder: (context, isFavorite, _) {
          return TvCardFocus(
            // tv: 单停点，OK = 原 onTap（红心双写）。
            onSelect: () => _handleRedHeart(currentTrack, isFavorite),
            debugLabel: 'fm-red-heart',
            child: M3EFilledButton.tonal(
              onPressed: () => _handleRedHeart(currentTrack, isFavorite),
              tooltip: isFavorite ? '取消收藏' : '收藏',
              shape: M3EButtonShape.round,
              decoration: M3EButtonDecoration(
                fixedSize: const Size(52, 52),
                padding: EdgeInsets.zero,
                backgroundColor: WidgetStatePropertyAll(
                  isFavorite ? cs.primaryContainer : cs.secondaryContainer,
                ),
                foregroundColor: WidgetStatePropertyAll(
                  isFavorite ? cs.onPrimaryContainer : cs.onSecondaryContainer,
                ),
              ),
              child: Icon(
                isFavorite ? Icons.favorite : Icons.favorite_border,
                size: 26,
                color: isFavorite ? cs.error : null,
              ),
            ),
          );
        },
      );
    }

    final Widget dislike = TvCardFocus(
      // tv: 单停点，OK = 原 onTap（不喜欢）。
      onSelect: currentTrack != null ? () => _handleDislike(currentTrack) : null,
      debugLabel: 'fm-dislike',
      child: M3EFilledButton.tonal(
        onPressed: currentTrack != null
            ? () => _handleDislike(currentTrack)
            : null,
        tooltip: '不喜欢',
        shape: M3EButtonShape.round,
        decoration: const M3EButtonDecoration(
          fixedSize: Size(52, 52),
          padding: EdgeInsets.zero,
        ),
        child: const Icon(Icons.thumb_down, size: 24),
      ),
    );

    final Widget play = TvCardFocus(
      // tv: 单停点，OK = 原 onTap（播放/暂停）。
      onSelect: () => _handlePlayPersonalFm(currentTrack, isPlaying),
      debugLabel: 'fm-play',
      child: M3EFilledButton(
        onPressed: () => _handlePlayPersonalFm(currentTrack, isPlaying),
        tooltip: isPlaying ? '暂停' : '播放',
        shape: M3EButtonShape.round,
        decoration: M3EButtonDecoration(
          fixedSize: const Size(64, 64),
          padding: EdgeInsets.zero,
          backgroundColor: WidgetStatePropertyAll(cs.primary),
          foregroundColor: WidgetStatePropertyAll(cs.onPrimary),
        ),
        child: _isLoading
            ? M3ELoadingIndicator(color: cs.onPrimary)
            : Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: 34,
                color: cs.onPrimary,
              ),
      ),
    );

    return Row(
      children: [
        heart,
        const Gap(AppSpacing.md),
        dislike,
        const Spacer(),
        play,
      ],
    );
  }

  Future<void> _handlePlayPersonalFm(
    KugouSongDetail? track,
    bool isPlaying,
  ) async {
    if (_isLoading) return;
    final kugou = Provider.of<KugouProvider>(context, listen: false);

    // 首次进入：列表为空，点击触发首次加载
    if (kugou.personalFmSongs.isEmpty) {
      await _loadPersonalFm();
      return;
    }

    if (isPlaying) {
      await _togglePlay();
    } else {
      if (track == null) return;
      await _playSong(track);
    }
  }

  /// tv: 唱片堆曾把左右键映射为上一首/下一首、OK 为播放/暂停。焕新后唱片堆
  /// 取消，但这条遥控语义必须保留——包在 hero 外层，左右消费为切歌、上下放行。
  Widget _buildTvTransportKeys({
    required Widget child,
    required KugouSongDetail? currentTrack,
    required bool isPlaying,
  }) {
    if (!kTvBuild) return child;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final player = _player;
        if (player == null) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowRight) {
          player.next();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          player.previous();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter) {
          _handlePlayPersonalFm(currentTrack, isPlaying);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  // ────────────────────────────── 即将播放队列 ──────────────────────────────

  Widget _buildUpcomingQueue(
    ColorScheme cs,
    TextTheme textTheme,
    List<KugouSongDetail> sideTracks,
  ) {
    if (sideTracks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '即将播放',
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const Gap(AppSpacing.md),
        _tvActivateWrap(
          M3ESegmentedList(
            itemCount: sideTracks.length,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            outerRadius: 24,
            innerRadius: 8,
            gap: 2,
            color: cs.surfaceContainerLow,
            haptic: M3EHapticFeedback.none,
            onTap: (index) => _playSong(sideTracks[index]),
            // tv: 记住当前行，OK 键按下时由 _tvActivateWrap 取用。
            onFocusChange: (index, focused) {
              if (focused) _focusedQueueIndex = index;
            },
            itemBuilder: (context, index) =>
                _queueTile(cs, textTheme, sideTracks[index]),
          ),
          (index) {
            if (index >= 0 && index < sideTracks.length) {
              _playSong(sideTracks[index]);
            }
          },
        ),
      ],
    );
  }

  Widget _queueTile(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail track,
  ) {
    return Row(
      children: [
        _cover(track, 52, cs, radius: 12),
        const Gap(AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track.songName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Gap(AppSpacing.xxs),
              Text(
                track.artistName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Gap(AppSpacing.sm),
        Icon(Icons.play_arrow_rounded, color: cs.primary),
      ],
    );
  }

  /// tv: 给「自带焦点节点但不响应 OK 键」的 [M3ESegmentedList] 补 [ActivateIntent]。
  ///
  /// [M3ESegmentedItem] 自带 `M3ESegmentedItem_N` 焦点节点，且位于 itemBuilder
  /// 内容**外层**；包在 itemBuilder 里的 DpadFocusable 是内层节点，dpad 几何候选
  /// 会先选中外层，包了也白包。而它只把 Enter/Space 字面键映射到 onTap，遥控 OK 是
  /// DPAD_CENTER → `select` → `ActivateIntent`，列表没注册对应 Action → 按 OK 无反应。
  /// 故用列表自己的 onFocusChange 记住当前行，再把 ActivateIntent 接到 onActivate 上。
  /// 触屏 onTap 原样保留、零变化。非 TV 构建直接返回 child。
  Widget _tvActivateWrap(Widget child, ValueChanged<int> onActivate) {
    if (!kTvBuild) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onActivate(_focusedQueueIndex);
            return null;
          },
        ),
      },
      child: child,
    );
  }

  // ────────────────────────────── 封面 ──────────────────────────────

  Widget _cover(
    KugouSongDetail? track,
    double size,
    ColorScheme cs, {
    double radius = 16,
  }) {
    final String? url = track?.artworkUri;
    Widget image;
    if (track != null && url != null && url.isNotEmpty) {
      image = Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: child,
          );
        },
        errorBuilder: (_, _, _) => _coverPlaceholder(cs, size),
      );
    } else {
      image = _coverPlaceholder(cs, size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: image),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs, double size) {
    return Container(
      width: size,
      height: size,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.music_note, size: size * 0.36, color: cs.onSurfaceVariant),
    );
  }
}
