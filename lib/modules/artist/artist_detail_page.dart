import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_toast.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class ArtistDetailPage extends StatefulWidget {
  final String artistId;
  final String artistName;
  final String? avatarUrl;
  /// 初始关注状态（从收藏列表进入时传 true）
  final bool initialIsFollowed;

  const ArtistDetailPage({
    super.key,
    required this.artistId,
    required this.artistName,
    this.avatarUrl,
    this.initialIsFollowed = false,
  });

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

enum _SortBy { time, title, duration }

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;
  bool _isFollowing = false;
  bool _isFollowLoading = false;
  String? _description;
  bool _isDescriptionExpanded = false;
  /// 搜索接口通常不返回歌手头像，用 getArtistDetail 接口补全的头像URL
  String? _resolvedAvatarUrl;

  /// 滚动监听：用于 SliverAppBar pinned 后 fade-in 显示歌手名
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

  // 歌曲内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // 排序
  _SortBy _sortBy = _SortBy.time;
  bool _sortAscending = false;

  // 定位正在播放歌曲
  String? _highlightSongId;

  // 缓存的过滤/排序结果
  List<Song>? _cachedDisplaySongs;
  String? _lastSearchQuery;
  _SortBy? _lastSortBy;
  bool? _lastSortAscending;

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
            s.artist.toLowerCase().contains(q) ||
            (s.album?.toLowerCase().contains(q) ?? false);
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

  @override
  void initState() {
    super.initState();
    // 先用传入的初始关注状态（从收藏列表进入时为 true），
    // _fetchArtistSongs 获取到详情后会用接口返回值覆盖
    _isFollowing = widget.initialIsFollowed;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchArtistSongs();
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

  /// 滚动监听：减少无意义 setState，仅在偏移变化超过 1px 时更新
  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _lastReportedOffset).abs() > 1.0) {
      _lastReportedOffset = offset;
      _scrollOffset = offset;
      setState(() {});
    }
  }

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
    // 让目标项落在视口正中而非顶部：index*itemHeight 只对齐顶缘，
    // 减去半个视口余量后当前播放歌曲会居中显示，便于快速锁定。
    final viewport = _scrollController.position.viewportDimension;
    final targetOffset = index * itemHeight - (viewport - itemHeight) / 2;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _fetchArtistSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = KugouApiClient();
      final artistId = widget.artistId;
      final artistName = widget.artistName;

      // 并行获取歌手详情和第一页歌曲
      const batchSize = 30;
      const maxPages = 100;
      final detailFuture = api.getArtistDetail(artistId);
      final firstPageFuture = api.getArtistAudios(
        artistId,
        page: 1,
        pagesize: batchSize,
        noCache: true,
      );

      final initial = await Future.wait([detailFuture, firstPageFuture]);
      if (!mounted) return;

      final detail = initial[0] as KugouArtistDetail?;
      final firstPage = initial[1] as KugouArtistAudios?;

      // 获取歌手简介和头像（搜索接口通常不返回头像，这里补全）
      if (detail != null) {
        if (detail.description != null &&
            detail.description!.isNotEmpty) {
          _description = detail.description;
        }
        if (detail.avatarUrl != null && detail.avatarUrl!.isNotEmpty) {
          _resolvedAvatarUrl = detail.avatarUrl;
        }
        // 只有接口明确返回了关注状态字段时才覆盖初始值，
        // 否则保留从入口传入的 initialIsFollowed
        if (detail.hasFollowStatus) {
          _isFollowing = detail.isFollowed;
        }
      }

      // 一次性拉取全部歌曲
      final allSongs = <KugouSongDetail>[];
      if (firstPage != null && firstPage.songs.isNotEmpty) {
        allSongs.addAll(firstPage.songs);
        final total = firstPage.total;
        final targetTotal = (total > 0) ? total : 999999;

        int currentPage = 2;
        while (allSongs.length < targetTotal && currentPage <= maxPages) {
          final pageResult = await api.getArtistAudios(
            artistId,
            page: currentPage,
            pagesize: batchSize,
            noCache: true,
          );
          if (pageResult == null || pageResult.songs.isEmpty) break;
          allSongs.addAll(pageResult.songs);
          if (pageResult.songs.length < batchSize) break;
          currentPage++;
        }
      }

      // API 返回不足时，用搜索补充
      final expectedTotal = firstPage?.total ?? 0;
      if (allSongs.isEmpty || (expectedTotal > 0 && allSongs.length < expectedTotal && allSongs.length < 30)) {
        final searchSongs = await _searchArtistSongs(api, artistId, artistName);
        if (!mounted) return;
        if (searchSongs.isNotEmpty) {
          final existingHashes = allSongs.map((s) => s.hash).toSet();
          for (final song in searchSongs) {
            if (!existingHashes.contains(song.hash)) {
              allSongs.add(song);
              existingHashes.add(song.hash);
            }
          }
        }
      }

      setState(() {
        _songs = allSongs.map((s) => s.toSong()).toList();
        _isLoading = false;
        _invalidateDisplaySongs();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// 通过搜索获取该歌手的歌曲，用 artistId 精确匹配
  Future<List<KugouSongDetail>> _searchArtistSongs(
    KugouApiClient api,
    String artistId,
    String artistName,
  ) async {
    final matchedSongs = <KugouSongDetail>[];
    final seenHashes = <String>{};
    const maxSearchPages = 10;
    const searchPageSize = 30;

    // 搜索多个页面，用 artistId 精确匹配
    for (int page = 1; page <= maxSearchPages; page++) {
      if (!mounted) break;

      final searchResult = await api.search(
        artistName,
        page: page,
        pagesize: searchPageSize,
        type: 'song',
      );

      if (searchResult == null || searchResult.songs.isEmpty) break;

      bool foundAny = false;
      for (final song in searchResult.songs) {
        if (seenHashes.contains(song.hash)) continue;

        // 用 artistId 精确匹配（最可靠）
        if (song.artistId != null && song.artistId == artistId) {
          matchedSongs.add(song);
          seenHashes.add(song.hash);
          foundAny = true;
          continue;
        }

        // 备选：artistName 完全匹配（忽略大小写）
        if (song.artistName != null &&
            song.artistName!.toLowerCase() == artistName.toLowerCase()) {
          matchedSongs.add(song);
          seenHashes.add(song.hash);
          foundAny = true;
        }
      }

      // 如果本页没有匹配到任何结果，说明后面也不会有了
      if (!foundAny && page > 1) break;

      // 如果返回的歌曲数少于请求的数量，说明已经是最后一页
      if (searchResult.songs.length < searchPageSize) break;
    }

    return matchedSongs;
  }

  /// 将 http:// URL 转换为 https://
  String? _fixImageUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  /// 关注/取消关注歌手
  Future<void> _toggleFollow() async {
    if (_isFollowLoading) return;
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (!mounted) return;
      showToast('请先登录', long: true);
      return;
    }

    setState(() => _isFollowLoading = true);

    final wasFollowing = _isFollowing;
    // 乐观更新：先切换 UI 状态
    setState(() => _isFollowing = !wasFollowing);

    try {
      final result = wasFollowing
          ? await api.unfollowArtist(widget.artistId)
          : await api.followArtist(widget.artistId);

      if (!mounted) return;

      // 检查 API 返回是否成功
      // result 为 null（网络错误），或 status/error_code 表示失败时，回滚
      final status = result?['status'];
      final errCode = result?['error_code'];
      final isFailed = result == null ||
          (status != null && status != 1) ||
          (errCode != null && errCode != 0);

      if (isFailed) {
        // 失败，回滚
        setState(() => _isFollowing = wasFollowing);
        showToast(
          result?['msg'] ?? result?['message'] ?? '操作失败，请重试',
          long: true,
        );
      } else {
        showToast(wasFollowing ? '已取消关注' : '已关注');
      }
    } catch (e) {
      if (!mounted) return;
      // 异常，回滚
      setState(() => _isFollowing = wasFollowing);
      showToast('网络错误: $e', long: true);
    } finally {
      if (mounted) setState(() => _isFollowLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    final avatarUrl = _fixImageUrl(_resolvedAvatarUrl ?? widget.avatarUrl);

    return Scaffold(
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildError(context, colorScheme)
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 240,
                      pinned: true,
                      centerTitle: false,
                      // pinned 后顶栏背景色：滚动到 expandedHeight - kToolbarHeight
                      // 之后从透明渐变到 surface
                      actions: [
                        if (_songs.isNotEmpty)
                          IconButton(
                            icon: Icon(_isSearching ? Icons.close : Icons.search),
                            onPressed: _toggleSearch,
                            tooltip: '搜索',
                          ),
                        if (_songs.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.my_location),
                            onPressed: _scrollToPlayingSong,
                            tooltip: '定位正在播放',
                          ),
                        if (_songs.isNotEmpty)
                          PopupMenuButton<_SortBy>(
                            icon: const Icon(Icons.sort),
                            tooltip: '排序',
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
                                    const Text('添加时间'),
                                    if (_sortBy == _SortBy.time) ...[
                                      const Spacer(),
                                      Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
                                    ],
                                  ],
                                ),
                              ),
                              CheckedPopupMenuItem<_SortBy>(
                                value: _SortBy.title,
                                checked: _sortBy == _SortBy.title,
                                child: Row(
                                  children: [
                                    const Text('歌曲名称'),
                                    if (_sortBy == _SortBy.title) ...[
                                      const Spacer(),
                                      Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
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
                                      Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                      ],
                      // 背景图模式：顶栏恒透明——flexibleSpace 是普通 Stack
                      // （非 FlexibleSpaceBar，折叠时不产生视差位移，壁纸层顶部
                      // 固定裁剪），任意滚动位置壁纸都与主体背景对齐、不透 UI；
                      // 非背景图：上划渐变到 surface（遮住列表不穿透）
                      backgroundColor: useBackgroundImage
                          ? Colors.transparent
                          : Color.lerp(
                              Colors.transparent,
                              colorScheme.surface,
                              (_scrollOffset - (240 - kToolbarHeight))
                                  .clamp(0.0, 60.0) / 60,
                            )!,
                      surfaceTintColor: Colors.transparent,
                      scrolledUnderElevation: 0,
                      // pinned 后顶栏标题：滚动超过阈值后 fade-in 显示歌手名
                      title: Opacity(
                        opacity: ((_scrollOffset - (240 - kToolbarHeight)) /
                                60.0)
                            .clamp(0.0, 1.0),
                        child: Text(
                          widget.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      // 不用 FlexibleSpaceBar：折叠时不产生视差位移，壁纸层
                      // 顶部固定裁剪，滚动中始终与主体背景对齐。
                      // 显式 ClipRect：全屏壁纸层仅靠 Stack 默认 hardEdge 裁剪
                      // 可能失效，必须显式裁剪，否则壁纸会溢出覆盖下方歌曲列表
                      flexibleSpace: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (useBackgroundImage)
                              const WallpaperHeaderBackground(),
                            Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                // 开启壁纸时主题色渐变半透明叠加在壁纸上，
                                // 渐变可见且壁纸透出；未开启时实色渐变
                                useBackgroundImage
                                    ? colorScheme.primaryContainer
                                        .withValues(alpha: 0.35)
                                    : colorScheme.primaryContainer,
                                // 底部渐变到透明：启用全局背景图（页面背景透明）时，
                                // 若此处仍是实色 surface 会与下方背景图形成接缝穿帮。
                                colorScheme.surface.withValues(alpha: 0),
                              ],
                            ),
                          ),
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  avatarUrl != null
                                      ? ClipOval(
                                          child: CachedNetworkImage(
                                            imageUrl: avatarUrl,
                                            memCacheWidth: 300,
                                            memCacheHeight: 300,
                                            width: 100,
                                            height: 100,
                                            fit: BoxFit.cover,
                                            placeholder: (_, _) => Container(
                                              width: 100,
                                              height: 100,
                                              color: colorScheme.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.person,
                                                size: 40,
                                                color: colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                            errorWidget: (_, _, _) => Container(
                                              width: 100,
                                              height: 100,
                                              color: colorScheme.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.person,
                                                size: 40,
                                                color: colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        )
                                      : Container(
                                          width: 100,
                                          height: 100,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: colorScheme.surfaceContainerHighest,
                                          ),
                                          child: Icon(
                                            Icons.person,
                                            size: 40,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.artistName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (_songs.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            '${_songs.length} 首歌曲',
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                              color: colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
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
                  ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _displaySongs.isNotEmpty
                                    ? () {
                                        context
                                            .read<PlayerProvider>()
                                            .playOnlinePlaylist(_displaySongs, 0);
                                      }
                                    : null,
                                icon: const Icon(Icons.play_arrow),
                                label: Text(
                                  '播放全部${_isSearching && _searchQuery.isNotEmpty ? ' (${_displaySongs.length})' : ''}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _displaySongs.isNotEmpty
                                    ? () {
                                        final shuffled = List<Song>.from(_displaySongs)
                                          ..shuffle();
                                        context
                                            .read<PlayerProvider>()
                                            .playOnlinePlaylist(shuffled, 0);
                                      }
                                    : null,
                                icon: const Icon(Icons.shuffle),
                                label: const Text('随机播放'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 关注/取消关注按钮
                            _isFollowLoading
                                ? const SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Center(
                                      child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
                                    ),
                                  )
                                : IconButton.filledTonal(
                                    onPressed: _toggleFollow,
                                    icon: Icon(
                                      _isFollowing
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: _isFollowing
                                          ? colorScheme.error
                                          : null,
                                    ),
                                    tooltip: _isFollowing ? '取消关注' : '关注歌手',
                                  ),
                          ],
                        ),
                      ),
                    ),
                    // 歌手介绍（默认折叠，带动画）
                    if (_description != null && _description!.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _isDescriptionExpanded = !_isDescriptionExpanded;
                              });
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.5),
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
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '歌手介绍',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge
                                            ?.copyWith(
                                              color: colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                      const Spacer(),
                                      AnimatedRotation(
                                        turns: _isDescriptionExpanded ? 0.5 : 0,
                                        duration: const Duration(milliseconds: 200),
                                        child: Icon(
                                          Icons.keyboard_arrow_down,
                                          size: 20,
                                          color: colorScheme.onSurfaceVariant,
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
                                      _description!,
                                      maxLines: _isDescriptionExpanded ? null : 2,
                                      overflow: _isDescriptionExpanded
                                          ? null
                                          : TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                            height: 1.5,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 搜索栏
                    if (_isSearching)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            decoration: InputDecoration(
                              hintText: '搜索歌手的歌曲...',
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
                              fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    // 搜索无结果
                    if (_isSearching && _displaySongs.isEmpty && _songs.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            children: [
                              Icon(Icons.search_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                              const SizedBox(height: 8),
                              Text(
                                '没有找到「$_searchQuery」相关的歌曲',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_songs.isEmpty)
                      SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.music_off,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无歌曲',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
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
                            final song = _displaySongs[index];
                            final isHighlighted = _highlightSongId == song.id;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              color: isHighlighted
                                  ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                                  : Colors.transparent,
                              child: SongListItem(
                                song: song,
                                onTap: () {
                                  context.read<PlayerProvider>().playOnlinePlaylist(
                                        _displaySongs,
                                        index,
                                      );
                                },
                                onMoreTap: () {},
                              ),
                            );
                          },
                          childCount: _displaySongs.length,
                        ),
                      ),
                    ],
                  ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _fetchArtistSongs,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
