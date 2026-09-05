import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_toast.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/collected_playlist_store.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/playlist_comments_view.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class AlbumDetailPage extends StatefulWidget {
  final Album album;

  const AlbumDetailPage({super.key, required this.album});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

enum _SortBy { time, title, duration }

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  bool _isLoading = true;
  List<Song> _songs = [];
  String? _error;
  KugouAlbumDetail? _albumDetail;

  // 排序
  _SortBy _sortBy = _SortBy.time;
  bool _sortAscending = false;

  // 专辑内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // 定位正在播放歌曲
  String? _highlightSongId;

  // 专辑介绍展开/折叠
  bool _isDescriptionExpanded = false;

  // 收藏状态
  bool _isCollected = false;
  String? _collectedListId;

  // 滚动监听
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

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
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchAlbum();
      _checkCollected();
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
    final targetOffset = index * itemHeight;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _fetchAlbum() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = KugouApiClient();
      final detailFuture = api.getAlbumDetail(widget.album.id);
      final songsFuture = api.getAlbumSongs(widget.album.id);

      final results = await Future.wait([detailFuture, songsFuture]);

      final detail = results[0] as KugouAlbumDetail?;
      final songsResult = results[1] as KugouAlbumSongs?;

      setState(() {
        _albumDetail = detail;
        _songs = songsResult?.songs.map((e) => e.toSong()).toList() ?? [];
        _invalidateDisplaySongs();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
    setState(() {
      _isLoading = false;
    });
  }

  // ==================== 收藏 ====================

  Future<void> _checkCollected() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    final cached = await CollectedPlaylistStore.getListId(widget.album.id);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = cached;
        });
      }
      return;
    }

    final listid = await _findCollectedListId(api);
    if (listid != null && mounted) {
      await CollectedPlaylistStore.setListId(widget.album.id, listid);
      setState(() {
        _isCollected = true;
        _collectedListId = listid;
      });
    }
  }

  Future<String?> _findCollectedListId(KugouApiClient api) async {
    try {
      final result = await api.getUserPlaylist(pagesize: 50);
      if (result == null) return null;
      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }
      if (list == null) return null;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final gid = item['global_collection_id']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          if (gid == widget.album.id || name == widget.album.name) {
            return item['listid']?.toString();
          }
        }
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  Future<void> _collectAlbum() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) {
        showToast('请先登录', long: true);
      }
      return;
    }

    // 乐观更新：立即显示已收藏状态
    setState(() {
      _isCollected = true;
    });

    try {
      String artistId = _albumDetail?.artistId ?? '';
      if (artistId.isEmpty && _songs.isNotEmpty) {
        artistId = _songs.first.artistId ?? '';
      }
      final result = await api.collectAlbum(
        widget.album.name,
        artistId: artistId,
        albumId: widget.album.id,
      );
      if (result == null) {
        // 回滚
        if (mounted) {
          setState(() { _isCollected = false; });
          showToast('收藏失败，请重试', long: true);
        }
        return;
      }
      String? newId = await _findCollectedListId(api);
      await CollectedPlaylistStore.setListId(widget.album.id, newId);
      if (mounted) {
        setState(() { _collectedListId = newId; });
        context.read<PlaylistCollectionNotifier>().notifyChanged();
      }
    } catch (e) {
      // 回滚
      if (mounted) {
        setState(() { _isCollected = false; });
        showToast('收藏失败', long: true);
      }
    }
  }

  Future<void> _uncollectAlbum() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 乐观更新：立即显示未收藏状态
    setState(() {
      _isCollected = false;
    });

    String? listId = await CollectedPlaylistStore.getListId(widget.album.id);
    listId ??= _collectedListId;
    listId ??= await _findCollectedListId(api);
    if (listId == null || listId.isEmpty) {
      if (mounted) {
        setState(() { _isCollected = true; });
        showToast('找不到收藏记录，无法取消', long: true);
      }
      return;
    }

    try {
      final result = await api.deletePlaylist(listId, type: 0);
      if (result != null && mounted) {
        await CollectedPlaylistStore.remove(widget.album.id);
        setState(() { _collectedListId = null; });
        context.read<PlaylistCollectionNotifier>().notifyChanged();
      } else if (mounted) {
        // 回滚
        setState(() { _isCollected = true; });
        showToast('取消收藏失败，请重试', long: true);
      }
    } catch (e) {
      if (mounted) {
        // 回滚
        setState(() { _isCollected = true; });
        showToast('取消收藏失败', long: true);
      }
    }
  }

  // ==================== 评论 ====================

  void _showCommentsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          final colorScheme = Theme.of(context).colorScheme;
          return Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.comment_outlined, size: 20, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        '评论',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
                Expanded(
                  child: PlaylistCommentsView(
                    specialId: widget.album.globalCollectionId ?? widget.album.id,
                    commentType: 'album',
                    scrollController: scrollController,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    // 字段级 fallback：API 返回的 albumDetail 优先，但其 artworkUri 为 null 时
    // 保留传入的 widget.album.artworkUri（即 song.artworkUri），避免丢失初始封面
    final apiAlbum = _albumDetail?.toAlbum();
    final displayAlbum = apiAlbum != null
        ? (apiAlbum.artworkUri == null && widget.album.artworkUri != null
            ? apiAlbum.copyWith(artworkUri: widget.album.artworkUri)
            : apiAlbum)
        : widget.album;
    final description = _albumDetail?.description;

    return Scaffold(
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildError(context, colorScheme)
              : Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        controller: _scrollController,
                        slivers: [
                          SliverAppBar(
                            expandedHeight: 280,
                            pinned: true,
                            // 背景图模式：顶栏恒透明——flexibleSpace 是普通 Stack
                            // （非 FlexibleSpaceBar，折叠时不产生视差位移，壁纸层顶部
                            // 固定裁剪），任意滚动位置壁纸都与主体背景对齐、不透 UI；
                            // 非背景图：上划渐变到 surface（遮住列表不穿透）
                            backgroundColor: useBackgroundImage
                                ? Colors.transparent
                                : Color.lerp(
                                    Colors.transparent,
                                    colorScheme.surface,
                                    (_scrollOffset - (280 - kToolbarHeight))
                                        .clamp(0.0, 60.0) / 60,
                                  )!,
                            surfaceTintColor: Colors.transparent,
                            scrolledUnderElevation: 0,
                            actions: [
                              if (_songs.isNotEmpty)
                                IconButton(
                                  icon: Icon(_isSearching ? Icons.close : Icons.search),
                                  onPressed: _toggleSearch,
                                ),
                              if (_songs.isNotEmpty)
                                IconButton(
                                  icon: const Icon(Icons.comment_outlined),
                                  onPressed: () => _showCommentsSheet(context),
                                  tooltip: '评论',
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
                            title: Opacity(
                              opacity: ((_scrollOffset - (280 - kToolbarHeight)) / 60.0)
                                  .clamp(0.0, 1.0),
                              child: Text(
                                displayAlbum.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            // 不用 FlexibleSpaceBar：折叠时不产生视差位移，壁纸层
                            // 顶部固定裁剪，滚动中始终与主体背景对齐。
                            // 显式 ClipRect：全屏壁纸层仅靠 Stack 默认 hardEdge
                            // 裁剪可能失效，必须显式裁剪，否则壁纸会溢出覆盖歌曲列表
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
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: SizedBox(
                                            width: 140,
                                            height: 140,
                                            child: displayAlbum.artworkUri != null
                                                ? CachedNetworkImage(
                                                    imageUrl: displayAlbum.artworkUri!,
                                                    memCacheWidth: 420,
                                                    memCacheHeight: 420,
                                                    fit: BoxFit.cover,
                                                    placeholder: (_, _) => Container(
                                                      color: colorScheme.surfaceContainerHighest,
                                                      child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
                                                    ),
                                                    errorWidget: (_, _, _) => Container(
                                                      color: colorScheme.surfaceContainerHighest,
                                                      child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
                                                    ),
                                                  )
                                                : Container(
                                                    color: colorScheme.surfaceContainerHighest,
                                                    child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
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
                                                displayAlbum.name,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                                              ),
                                              if (displayAlbum.artist.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  displayAlbum.artist,
                                                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                                ),
                                              ],
                                              const SizedBox(height: 4),
                                              Text(
                                                '${_songs.length} 首歌曲',
                                                style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
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
                        ),
                          // 专辑介绍
                          if (description != null && description.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.info_outline, size: 16, color: colorScheme.onSurfaceVariant),
                                            const SizedBox(width: 6),
                                            Text(
                                              '专辑介绍',
                                              style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant),
                                            ),
                                            const Spacer(),
                                            AnimatedRotation(
                                              turns: _isDescriptionExpanded ? 0.5 : 0,
                                              duration: const Duration(milliseconds: 200),
                                              child: Icon(Icons.keyboard_arrow_down, size: 20, color: colorScheme.onSurfaceVariant),
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
                                            description,
                                            maxLines: _isDescriptionExpanded ? null : 2,
                                            overflow: _isDescriptionExpanded ? null : TextOverflow.ellipsis,
                                            style: textTheme.bodyMedium?.copyWith(
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
                                    hintText: '搜索专辑内的歌曲...',
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
                          // 播放按钮 + 收藏红心
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () {
                                        final songs = _displaySongs;
                                        if (songs.isNotEmpty) {
                                          context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
                                        }
                                      },
                                      icon: const Icon(Icons.play_arrow),
                                      label: Text(
                                        '播放全部${_isSearching && _searchQuery.isNotEmpty ? ' (${_displaySongs.length})' : ''}',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        final songs = _displaySongs;
                                        if (songs.isNotEmpty) {
                                          final shuffled = List<Song>.from(songs)..shuffle();
                                          context.read<PlayerProvider>().playOnlinePlaylist(shuffled, 0);
                                        }
                                      },
                                      icon: const Icon(Icons.shuffle),
                                      label: const Text('随机播放'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  IconButton.filledTonal(
                                    onPressed: _isCollected ? _uncollectAlbum : _collectAlbum,
                                    icon: Icon(
                                      _isCollected ? Icons.favorite : Icons.favorite_border,
                                      color: _isCollected ? colorScheme.error : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // 歌曲列表
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
                                      context.read<PlayerProvider>().playOnlinePlaylist(_displaySongs, index);
                                    },
                                    onMoreTap: () {},
                                  ),
                                );
                              },
                              childCount: _displaySongs.length,
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
                                      style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const MiniPlayer(),
                  ],
                ),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _fetchAlbum, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
