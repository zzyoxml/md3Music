import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../core/build_flags.dart';
import '../../core/layout/adaptive_navigator.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/entry_transition_gate.dart';
import '../../core/widgets/app_background.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

/// 听书专辑详情页：专辑信息 + 简介 + 章节列表（可播放）。
///
/// UI 对齐歌单详情页（PlaylistPage）：SliverAppBar 大头部渐变、
/// 简介动画折叠、搜索/排序/定位正在播放、播放全部+随机播放。
class AudiobookAlbumDetailPage extends StatefulWidget {
  final KugouLongAudioAlbum album;

  const AudiobookAlbumDetailPage({super.key, required this.album});

  @override
  State<AudiobookAlbumDetailPage> createState() =>
      _AudiobookAlbumDetailPageState();
}

enum _SortBy { time, title, duration }

class _AudiobookAlbumDetailPageState extends State<AudiobookAlbumDetailPage> {
  bool _isLoading = true;
  bool _isIntroExpanded = false;
  String? _error;

  /// 页头真实封面是否已拿到加载完成的图片。喂给 `PlaylistCoverHero.destReady`：
  /// 进场飞行落位要等它变 true 才撤走，否则交接瞬间露出的是页头兜底占位
  /// （卡片按 540 解码、页头按 420 解码是两个缓存键）。
  final ValueNotifier<bool> _headerCoverReady = ValueNotifier<bool>(false);

  /// 进场转场动画（在任何 await 之前捕获，见 [_startLoadingAfterEntry]）。
  Animation<double>? _entryAnim;

  /// 本地章节数据副本（避免搜索/排序污染全局 Provider 状态）
  List<KugouLongAudioAudio> _audios = [];
  List<Song> _songs = [];

  // 分页：章节列表一次只返回 30 条，滚动到底自动加载后续页
  int _audioPage = 1;
  bool _hasMoreAudio = false;
  bool _loadingMore = false;

  // 排序（默认按章节原始顺序正序：第 1 集在最上面）
  _SortBy _sortBy = _SortBy.time;
  bool _sortAscending = true;

  // 章节内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // 定位正在播放章节
  String? _highlightSongId;

  // 顶栏渐变 ScrollController：与 SliverAppBar pinned 标题 fade-in 共享
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

  // 缓存的过滤/排序结果
  List<Song>? _cachedDisplaySongs;
  String? _lastSearchQuery;
  _SortBy? _lastSortBy;
  bool? _lastSortAscending;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 转场动画对象必须在任何 await 之前抓好：让路逻辑之后不再碰 context。
      _entryAnim = ModalRoute.of(context)?.animation;
      await _startLoadingAfterEntry();
    });
  }

  /// 进场转场收敛后才开始拉专辑详情/章节。
  ///
  /// `_load` 是两次 HTTP + 逐章 `_buildSongs` 映射，之后还会接一个 `_loadAllAudios`
  /// 循环翻页；全部跑在 UI 线程上，落在转场那几十帧里会把封面连贯过渡顶停（与
  /// 歌单/专辑详情页同一教训，见 `lib/core/utils/entry_transition_gate.dart`）。
  /// 页头现在转场期间即渲染，所以动画期间页面并不空。超时兜底由
  /// `waitUntilEntrySettled` 保证，不会不加载。转场后还要让过底栏收起动画
  /// （同 playlist_page，见 `waitUntilBottomChromeSettled`）。
  Future<void> _startLoadingAfterEntry() async {
    final waited = await waitUntilEntrySettled(_entryAnim);
    if (!mounted) return;
    // completed 回调跑在帧的动画阶段，再让出一帧，首屏章节构建才不挤进转场末帧。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (waited > 0) {
      // ignore: avoid_print
      print('[FlashTrace] AudiobookAlbumDetailPage 让路转场 ${waited}ms '
          'id=${widget.album.id}');
    }
    await waitUntilBottomChromeSettled(context);
    if (!mounted) return;
    await _load();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _headerCoverReady.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _lastReportedOffset).abs() > 1.0) {
      _lastReportedOffset = offset;
      _scrollOffset = offset;
      setState(() {});
    }
    // 接近底部时自动加载下一页章节（自动翻页）
    final pos = _scrollController.position;
    if (pos != null &&
        pos.maxScrollExtent > 0 &&
        pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMoreAudios();
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final kugou = context.read<KugouProvider>();
    try {
      await Future.wait([
        kugou.getLongaudioAlbumDetail(widget.album.id),
        kugou.getLongaudioAlbumAudios(
          widget.album.id,
          page: 1,
          pageSize: 50,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _audios = List.of(kugou.longAudioAudios);
        _songs = _buildSongs(_audios);
        _audioPage = kugou.longAudioAudiosPage;
        _hasMoreAudio = kugou.longAudioAudiosHasMore;
        _loadingMore = false;
        _isLoading = false;
        _invalidateDisplaySongs();
      });
      // 进入页面即自动加载全书全部章节（循环翻页直到到底），不等用户滚动。
      // 付费章节由 _buildSongs 按 canPlay（列表接口 fail_process）直接过滤隐藏。
      _loadAllAudios();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败，请检查网络后重试';
        _isLoading = false;
      });
    }
  }

  /// 自动加载全部章节：循环请求后续页并追加，直到 hasMore=false 或页面销毁。
  /// 期间 _loadingMore 置位，滚动触发的 _loadMoreAudios 会被 guard 拦截，避免并发。
  Future<void> _loadAllAudios() async {
    if (!mounted) return;
    if (!_hasMoreAudio) {
      return;
    }
    if (_loadingMore) return;
    _loadingMore = true;
    final kugou = context.read<KugouProvider>();
    try {
      while (_hasMoreAudio && mounted) {
        final prevPage = _audioPage;
        await kugou.getLongaudioAlbumAudios(
          widget.album.id,
          page: _audioPage + 1,
          pageSize: 50,
          append: true,
        );
        if (!mounted) return;
        // 先同步 provider 状态到页面局部变量
        _audios = List.of(kugou.longAudioAudios);
        _songs = _buildSongs(_audios);
        _audioPage = kugou.longAudioAudiosPage;
        _hasMoreAudio = kugou.longAudioAudiosHasMore;
        _invalidateDisplaySongs();
        // 请求失败时 provider 不更新页码（_audioPage 未前进），停止避免死循环。
        // 注意：必须在同步之后判断，否则首次循环 _audioPage 恒等于 prevPage 会误 break。
        if (_audioPage == prevPage) break;
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  /// 滚动到底时加载下一页章节，追加到现有列表（自动翻页）。
  Future<void> _loadMoreAudios() async {
    if (_loadingMore || !_hasMoreAudio || _isLoading) return;
    setState(() => _loadingMore = true);
    final kugou = context.read<KugouProvider>();
    await kugou.getLongaudioAlbumAudios(
      widget.album.id,
      page: _audioPage + 1,
      pageSize: 50,
      append: true,
    );
    if (!mounted) return;
    setState(() {
      _audios = List.of(kugou.longAudioAudios);
      _songs = _buildSongs(_audios);
      _audioPage = kugou.longAudioAudiosPage;
      _hasMoreAudio = kugou.longAudioAudiosHasMore;
      _loadingMore = false;
      _invalidateDisplaySongs();
    });
  }

  /// 将章节列表转换为 Song 列表：仅展示可播放（免费/限免）章节，
  /// 付费章节（列表接口 fail_process 非 0，模型 canPlay=false）直接隐藏不显示。
  List<Song> _buildSongs(List<KugouLongAudioAudio> audios) {
    final list = audios
        .where((a) => a.canPlay)
        .map(
          (a) => Song(
            id: a.id,
            title: a.name,
            artist: a.author ?? '',
            album: widget.album.name,
            duration: a.duration,
            artworkUri: a.artworkUri ?? widget.album.coverUrl,
            isOnline: true,
            albumId: a.albumId ?? widget.album.id,
            albumAudioId: a.albumAudioId,
            isLongAudio: true,
          ),
        )
        .toList();
    final hidden = audios.length - list.length;
    if (hidden > 0) {
      // ignore: avoid_print
      print('[AudiobookFree] 详情页隐藏付费章节 $hidden 条，展示 ${list.length} 条');
    }
    return list;
  }

  /// 简介：优先取列表接口解析出的 intro，兜底取详情接口原始数据。
  String? get _intro {
    final albumIntro = widget.album.intro;
    if (albumIntro != null && albumIntro.isNotEmpty) return albumIntro;
    final detail = context.read<KugouProvider>().longAudioAlbumDetail;
    final data = detail?['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map<String, dynamic>) {
        final intro = first['intro'] ?? first['mix_intro'] ?? first['full_intro'];
        if (intro is String && intro.isNotEmpty) return intro;
      }
    }
    return null;
  }

  // ==================== 显示列表（搜索 + 排序） ====================

  /// 当前显示的章节（带缓存）
  List<Song> get _displaySongs {
    if (_cachedDisplaySongs != null &&
        _lastSearchQuery == _searchQuery &&
        _lastSortBy == _sortBy &&
        _lastSortAscending == _sortAscending) {
      return _cachedDisplaySongs!;
    }
    _rebuildDisplaySongs();
    return _cachedDisplaySongs!;
  }

  void _rebuildDisplaySongs() {
    List<Song> list;
    if (_searchQuery.isEmpty) {
      list = List.of(_songs);
    } else {
      final q = _searchQuery.toLowerCase();
      list = _songs.where((s) {
        return s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q);
      }).toList();
    }
    list.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case _SortBy.time:
          cmp = _songs.indexOf(a).compareTo(_songs.indexOf(b));
          break;
        case _SortBy.title:
          cmp = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
          break;
        case _SortBy.duration:
          cmp = a.duration.compareTo(b.duration);
          break;
      }
      return _sortAscending ? cmp : -cmp;
    });
    _cachedDisplaySongs = list;
    _lastSearchQuery = _searchQuery;
    _lastSortBy = _sortBy;
    _lastSortAscending = _sortAscending;
  }

  void _invalidateDisplaySongs() {
    _cachedDisplaySongs = null;
  }

  // ==================== 播放 ====================

  /// 可播放章节（当前显示列表均为免费/限免章节，付费章节已被 _buildSongs 过滤）。
  List<Song> get _playableSongs => _displaySongs;

  void _playAll() {
    final songs = _playableSongs;
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
  }

  void _playShuffle() {
    final songs = _playableSongs;
    if (songs.isEmpty) return;
    final shuffled = List<Song>.from(songs)..shuffle();
    context.read<PlayerProvider>().playOnlinePlaylist(shuffled, 0);
  }

  /// 点击章节：在当前显示列表（均为免费/限免）内按当前排序播放。
  void _playChapterAt(int index) {
    final display = _displaySongs;
    final song = display[index];
    final playable = _playableSongs;
    final freeIndex = playable.indexOf(song);
    if (freeIndex == -1) return;
    context.read<PlayerProvider>().playOnlinePlaylist(playable, freeIndex);
  }

  // ==================== 搜索 / 定位 ====================

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
        _invalidateDisplaySongs();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
    });
  }

  void _scrollToPlayingSong() {
    final player = context.read<PlayerProvider>();
    final currentSong = player.currentSong;
    if (currentSong == null) return;

    final displayList = _displaySongs;
    final index = displayList.indexWhere((s) => s.id == currentSong.id);
    if (index == -1) return;

    setState(() => _highlightSongId = currentSong.id);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightSongId = null);
    });

    const itemHeight = 72.0;
    final targetOffset = index * itemHeight;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    final intro = _intro;
    final displaySongs = _displaySongs;

    return Scaffold(
      body: SecondaryMiniPlayerHost(
        // 页头恒渲染：封面连贯过渡的**终点**必须在进场转场期间就存在，否则飞行只能
        // 等页面滑完之后单独补飞（与 playlist_page / album_detail_page 同一教训）。
        // 加载态降级成章节区的占位 sliver（见下方 `if (_isLoading)`），不再整页替换；
        // 加载失败仍是「页头 + 顶部 banner」，观感与改动前一致。
        child: Column(
              children: [
                // 加载失败顶部 banner：专辑元数据仍可看
                if (_error != null)
                  _buildErrorBanner(context, cs, tt),
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      _buildSliverAppBar(cs, tt, useBackgroundImage),
                      // 加载中：章节区只挂占位（页头/错误横幅照常渲染）。
                      if (_isLoading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Center(child: M3ELoadingIndicator()),
                          ),
                        ),
                      // 简介（默认折叠，带动画）
                      if (intro != null)
                        SliverToBoxAdapter(
                          child: _buildIntroCard(context, cs, tt, intro),
                        ),
                      // 章节搜索栏
                      if (_isSearching)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              contextMenuBuilder: buildAppTextContextMenu,
                              decoration: InputDecoration(
                                hintText: '搜索章节...',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() {
                                            _searchQuery = '';
                                            _invalidateDisplaySongs();
                                          });
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: cs.surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(28),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                  _invalidateDisplaySongs();
                                });
                              },
                            ),
                          ),
                        ),
                      // 播放全部 + 随机播放（加载期不渲染：按钮文案此刻无意义）
                      if (!_isLoading)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _playableSongs.isEmpty
                                      ? null
                                      : _playAll,
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    _playableSongs.isEmpty
                                        ? '暂无免费章节'
                                        : '播放全部 (${_playableSongs.length})',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _playableSongs.isEmpty
                                      ? null
                                      : _playShuffle,
                                  icon: const Icon(Icons.shuffle),
                                  label: const Text('随机播放'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (!_isLoading)
                        const SliverToBoxAdapter(child: Divider(height: 1)),
                      // 章节列表：加载期两个分支都不渲染（否则会先闪一帧「暂无章节」
                      // 空态）。占位 sliver 只用来占住 if/else 链的首分支。
                      if (_isLoading)
                        const SliverToBoxAdapter(child: SizedBox.shrink())
                      else if (displaySongs.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.headphones_outlined,
                                    size: 48,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _searchQuery.isNotEmpty
                                        ? '没有找到相关章节'
                                        : '暂无章节',
                                    style: tt.titleMedium?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = displaySongs[index];
                              final isHighlighted =
                                  _highlightSongId == song.id;
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                color: isHighlighted
                                    ? cs.primaryContainer.withValues(alpha: 0.35)
                                    : Colors.transparent,
                                child: SongListItem(
                                  song: song,
                                  onTap: () => _playChapterAt(index),
                                ),
                              );
                            },
                            childCount: displaySongs.length,
                          ),
                        ),
                        // 加载更多 footer（滚动到底自动翻页）
                        if (_audios.isNotEmpty)
                          SliverToBoxAdapter(
                            child: _buildLoadMoreFooter(),
                          ),
                    ],
                  ),
                ),
              ],
            ),
      ),
    );
  }

  /// 页头封面兜底：与列表卡片/其它详情页头同形（surfaceContainerHighest + 图标），
  /// 图标用 `menu_book_outlined` 贴合听书语义。
  Widget _headerCoverPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.menu_book_outlined, size: 48, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// SliverAppBar：pinned 大头部（渐变背景）+ 滚动 fade-in 专辑名 + 操作按钮
  Widget _buildSliverAppBar(ColorScheme cs, TextTheme tt, bool useBackgroundImage) {
    final displaySongs = _displaySongs;
    // 双栏窄面板时头部降为 220（与歌单/专辑详情页一致），折叠 offset 数学同步跟随
    final headerH = DetailPaneContent.headerHeight(context, 280);
    return SliverAppBar(
      expandedHeight: headerH,
      pinned: true,
      // 背景图模式：顶栏恒透明——flexibleSpace 是普通 Stack
      // （非 FlexibleSpaceBar，折叠时不产生视差位移，壁纸层顶部固定裁剪），
      // 任意滚动位置壁纸都与主体背景对齐、不透 UI；非背景图：上划渐变到 surface
      backgroundColor: useBackgroundImage
          ? Colors.transparent
          : Color.lerp(
              Colors.transparent,
              cs.surface,
              (_scrollOffset - (headerH - kToolbarHeight))
                  .clamp(0.0, 60.0) / 60,
            )!,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actions: [
        if (displaySongs.isNotEmpty)
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: _isSearching ? '关闭搜索' : '搜索章节',
            onPressed: _toggleSearch,
          ),
        if (displaySongs.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: '定位正在播放',
            onPressed: _scrollToPlayingSong,
          ),
        if (displaySongs.isNotEmpty)
          M3ESortButton<_SortBy>(
            tooltip: '排序',
            current: _sortBy,
            options: const [
              (value: _SortBy.time, label: '章节顺序'),
              (value: _SortBy.title, label: '章节名称'),
              (value: _SortBy.duration, label: '时长'),
            ],
            onPicked: (value, repeated) {
              setState(() {
                if (repeated) {
                  // 再次点当前项：只翻转升/降序
                  _sortAscending = !_sortAscending;
                } else {
                  _sortBy = value;
                  // 章序默认正序（第 1 集在最上面），其余默认降序
                  _sortAscending = value == _SortBy.time ? false : true;
                }
                _invalidateDisplaySongs();
              });
            },
          ),
      ],
      title: Opacity(
        opacity: ((_scrollOffset - (headerH - kToolbarHeight)) / 60.0)
            .clamp(0.0, 1.0),
        child: Text(
          widget.album.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      // 不用 FlexibleSpaceBar：折叠时不产生视差位移，壁纸层顶部固定裁剪，
      // 滚动中始终与主体背景对齐。显式 ClipRect：全屏壁纸层仅靠 Stack
      // 默认 hardEdge 裁剪可能失效，必须显式裁剪，否则壁纸会溢出覆盖歌曲列表
      flexibleSpace: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 折叠时 flexibleSpace 高度缩到 0：封面随可用高度平滑缩放
            // （140 → 0）而非固定 140 被视口上边界截断，同时不触发
            // RenderFlex overflow；可用高度不足以容纳封面+文字时文字淡出。
            // 可用高度需同时扣除 SafeArea 顶部 inset（状态栏）与 padding 上下
            // 64（48+16），否则折叠过程中 coverSize 会按偏大的高度计算，
            // 超出 Row 真实可用高度触发 RenderFlex overflow（黄条）。
            // 与歌单详情页（playlist_page.dart）的防溢出方案保持一致。
            final safeTop = MediaQuery.paddingOf(context).top;
            final availH = (constraints.maxHeight - 64 - safeTop)
                .clamp(0.0, constraints.maxHeight);
            final coverSize = availH.clamp(0.0, 140.0);
            // 标题透明度连续映射：可用高度充足时全显示（1.0），折叠到阈值
            // 以下时淡出（0.0），实现平滑淡出而非折叠瞬间直接消失。
            final textOpacity = ((availH - 100) / 22).clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                if (useBackgroundImage) const WallpaperHeaderBackground(),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        // 开启壁纸时主题色渐变半透明叠加在壁纸上，
                        // 渐变可见且壁纸透出；未开启时实色渐变
                        useBackgroundImage
                            ? cs.primaryContainer.withValues(alpha: 0.35)
                            : cs.primaryContainer,
                        // 底部渐变到透明：与歌单详情页一致，启用全局背景图时不形成接缝穿帮
                        cs.surface.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: coverSize,
                            height: coverSize,
                            child: PlaylistCoverHero(
                              // tag 一律取 widget.album.id：与听书主页卡片
                              // （audiobook_page.dart 的 _buildAlbumCard）拿到的是
                              // 同一个 KugouLongAudioAlbum 对象，天然对齐。
                              tag: audiobookCoverHeroTag(widget.album.id),
                              radius: AppRadius.lgAll,
                              // 落位保持到真实封面拿到图片为止（信号来自下面那张图的
                              // imageBuilder，它只在图片加载完成后才被调用）。
                              destReady: _headerCoverReady,
                              child: widget.album.coverUrl != null
                                  ? CachedNetworkImage(
                                      imageUrl: widget.album.coverUrl!,
                                      // 解码尺寸必须恒定：随折叠变化的 coverSize 会让
                                      // 每帧都是新缓存键、图片逐帧重新下载导致闪烁
                                      // （原 SmartArtworkImage 固定 size:140 同理，
                                      // 缩小由外层 SizedBox 的 tight 约束 + BoxFit.cover
                                      // 完成）。
                                      memCacheWidth: 420,
                                      memCacheHeight: 420,
                                      // 兜底占位淡出默认 1s、**图片淡入默认 500ms**。
                                      // 共享元素过渡本身就是动画，两端都不要再做渐变，
                                      // 否则飞行途中/落位时会暗一下。
                                      fadeOutDuration: Duration.zero,
                                      fadeInDuration: Duration.zero,
                                      imageBuilder: (context, provider) {
                                        if (!_headerCoverReady.value) {
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                            if (mounted) {
                                              _headerCoverReady.value = true;
                                            }
                                          });
                                        }
                                        // 与 CachedNetworkImage 内部同键
                                        // （memCache 会包一层 ResizeImage），不多解码。
                                        return Image(
                                          image: ResizeImage(
                                            provider,
                                            width: 420,
                                            height: 420,
                                          ),
                                          fit: BoxFit.cover,
                                        );
                                      },
                                      fit: BoxFit.cover,
                                      placeholder: (_, _) =>
                                          _headerCoverPlaceholder(cs),
                                      errorWidget: (_, _, _) =>
                                          _headerCoverPlaceholder(cs),
                                    )
                                  : _headerCoverPlaceholder(cs),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            // 文字区可视高度随 availH 收缩：超出部分由 ClipRect
                            // 裁掉并配合淡出（opacity），封面缩小时不会残留文字
                            // 超出 Row 实际高度而触发 RenderFlex overflow（黄条）。
                            child: SizedBox(
                              height: availH,
                              child: Align(
                                alignment: Alignment.bottomLeft,
                                child: ClipRect(
                                  child: Opacity(
                                    opacity: textOpacity,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          widget.album.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.fade,
                                          style: tt.headlineSmall?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          [
                                            if (widget.album.author != null &&
                                                widget.album.author!.isNotEmpty)
                                              widget.album.author!,
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: tt.labelMedium?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 简介卡片：info 图标 + 旋转箭头 + AnimatedSize 展开动画
  Widget _buildIntroCard(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    String intro,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      // tv: TV 构建下简介卡单停点（GestureDetector 不可聚焦，D-pad 原生
      // 遍历到不了；OK=展开/收起简介）
      child: kTvBuild
          ? DpadFocusable(
              onSelect: () =>
                  setState(() => _isIntroExpanded = !_isIntroExpanded),
              child: _buildIntroCardBody(context, cs, tt, intro),
            )
          : GestureDetector(
              onTap: () => setState(() => _isIntroExpanded = !_isIntroExpanded),
              child: _buildIntroCardBody(context, cs, tt, intro),
            ),
    );
  }

  Widget _buildIntroCardBody(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    String intro,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '简介',
                style: tt.labelLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _isIntroExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                clipBehavior: Clip.hardEdge,
                child: Text(
                  intro,
                  maxLines: _isIntroExpanded ? null : 2,
                  overflow:
                      _isIntroExpanded ? null : TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  /// 加载更多 footer：仅加载中转圈（滚动到底自动翻页用）。
  Widget _buildLoadMoreFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const SizedBox(height: 20),
      ),
    );
  }

  /// 加载失败顶部 banner：专辑元数据仍可看，不完全覆盖 UI。
  Widget _buildErrorBanner(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
  ) {
    return Material(
      color: cs.errorContainer.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: cs.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: _load,
              style: TextButton.styleFrom(
                foregroundColor: cs.onErrorContainer,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
