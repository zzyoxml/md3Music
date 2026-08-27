import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../core/widgets/app_background.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/smart_artwork_image.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
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
    if (!mounted || !_hasMoreAudio || _loadingMore) return;
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
      if (mounted) setState(() => _loadingMore = false);
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

  /// 将章节列表转换为可播放的 Song 列表。
  /// 只保留免费/限免章节（canPlay：fail_process==0），隐藏付费章节。
  List<Song> _buildSongs(List<KugouLongAudioAudio> audios) {
    final paid = audios.where((a) => !a.canPlay).length;
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
          ),
        )
        .toList();
    if (paid > 0) {
      // ignore: avoid_print
      print('[AudiobookFree] 详情页隐藏付费章节 $paid 条，免费/限免 ${list.length} 条');
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

  void _playAll() {
    final songs = _displaySongs;
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
  }

  void _playShuffle() {
    final songs = _displaySongs;
    if (songs.isEmpty) return;
    final shuffled = List<Song>.from(songs)..shuffle();
    context.read<PlayerProvider>().playOnlinePlaylist(shuffled, 0);
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
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Column(
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
                      // 播放全部 + 随机播放
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
                                  onPressed: displaySongs.isEmpty
                                      ? null
                                      : _playAll,
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    displaySongs.isEmpty
                                        ? '暂无章节'
                                        : '播放全部 (${displaySongs.length})',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: displaySongs.isEmpty
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
                      const SliverToBoxAdapter(child: Divider(height: 1)),
                      // 章节列表
                      if (displaySongs.isEmpty)
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
                                  onTap: () => context
                                      .read<PlayerProvider>()
                                      .playOnlinePlaylist(
                                        displaySongs,
                                        index,
                                      ),
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
                const MiniPlayer(),
              ],
            ),
    );
  }

  /// SliverAppBar：pinned 大头部（渐变背景）+ 滚动 fade-in 专辑名 + 操作按钮
  Widget _buildSliverAppBar(ColorScheme cs, TextTheme tt, bool useBackgroundImage) {
    final displaySongs = _displaySongs;
    return SliverAppBar(
      expandedHeight: 280,
      pinned: true,
      // 背景图模式：顶栏恒透明——flexibleSpace 是普通 Stack
      // （非 FlexibleSpaceBar，折叠时不产生视差位移，壁纸层顶部固定裁剪），
      // 任意滚动位置壁纸都与主体背景对齐、不透 UI；非背景图：上划渐变到 surface
      backgroundColor: useBackgroundImage
          ? Colors.transparent
          : Color.lerp(
              Colors.transparent,
              cs.surface,
              (_scrollOffset - (280 - kToolbarHeight))
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
          PopupMenuButton<_SortBy>(
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              setState(() {
                if (_sortBy == value) {
                  _sortAscending = !_sortAscending;
                } else {
                  _sortBy = value;
                  _sortAscending = value == _SortBy.time ? false : true;
                }
                _invalidateDisplaySongs();
              });
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem<_SortBy>(
                value: _SortBy.time,
                checked: _sortBy == _SortBy.time,
                child: Row(
                  children: [
                    const Text('章节顺序'),
                    if (_sortBy == _SortBy.time) ...[
                      const Spacer(),
                      Icon(
                        _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 16,
                      ),
                    ],
                  ],
                ),
              ),
              CheckedPopupMenuItem<_SortBy>(
                value: _SortBy.title,
                checked: _sortBy == _SortBy.title,
                child: Row(
                  children: [
                    const Text('章节名称'),
                    if (_sortBy == _SortBy.title) ...[
                      const Spacer(),
                      Icon(
                        _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 16,
                      ),
                    ],
                  ],
                ),
              ),
              CheckedPopupMenuItem<_SortBy>(
                value: _SortBy.duration,
                checked: _sortBy == _SortBy.duration,
                child: Row(
                  children: [
                    const Text('时长'),
                    if (_sortBy == _SortBy.duration) ...[
                      const Spacer(),
                      Icon(
                        _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 16,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
      ],
      title: Opacity(
        opacity: ((_scrollOffset - (280 - kToolbarHeight)) / 60.0).clamp(0.0, 1.0),
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
        child: Stack(
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 140,
                      height: 140,
                      child: SmartArtworkImage(
                        artworkUri: widget.album.coverUrl,
                        size: 140,
                        borderRadius: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          widget.album.name,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
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
                          style: tt.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ],
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
      child: GestureDetector(
        onTap: () => setState(() => _isIntroExpanded = !_isIntroExpanded),
        child: Container(
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
        ),
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
