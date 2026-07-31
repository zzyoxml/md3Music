import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/collected_playlist_store.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/stream_cache_repository.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/stream_cache_manager.dart';
import '../../widgets/song_list_item.dart';
import '../../widgets/playlist_comments_view.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../player/mini_player.dart';

class PlaylistPage extends StatefulWidget {
  final Playlist playlist;
  // 「我收藏」里的歌单：本身已是已收藏状态，不显示红心收藏按钮。
  final bool isInMyFavorites;
  // 是否为专辑（用于评论类型判断）
  final bool isAlbum;
  // 专辑的 globalCollectionId（用于评论 API）
  final String? albumGlobalCollectionId;
  // 是否为用户自己创建的歌单（可批量删除歌曲）
  final bool isUserCreated;

  const PlaylistPage({
    super.key,
    required this.playlist,
    this.isInMyFavorites = false,
    this.isAlbum = false,
    this.albumGlobalCollectionId,
    this.isUserCreated = false,
  });

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

enum _SortBy { time, title, duration }

class _PlaylistPageState extends State<PlaylistPage> {
  bool _isLoading = true;
  List<Song> _songs = [];
  String? _error;
  // 普通歌单（发现/热门/排行榜）的红心收藏状态
  bool _isCollected = false;
  String? _collectedListId;

  // 排序
  _SortBy _sortBy = _SortBy.time;
  bool _sortAscending = false; // 默认降序（最新在前 / Z→A / 长→短）

  // 歌单内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // 定位正在播放歌曲
  String? _highlightSongId;

  // 歌单介绍展开/折叠
  bool _isDescriptionExpanded = false;

  // 批量选择模式
  bool _isMultiSelectMode = false;
  final Set<String> _selectedSongIds = {};
  bool _isDeleting = false;

  // 已缓存筛选（与历史记录页一致）
  bool _showOnlyPlayable = false;
  Set<String> _playableIds = {};

  /// 删除歌曲用的 listid（仅自己创建的歌单有效）
  String? get _deleteListid => widget.playlist.listCreateListid;

  /// 顶栏渐变 ScrollController：监听 CustomScrollView 滚动 offset，
  /// 用于 SliverAppBar pinned 后 fade-in 显示歌单名称
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _checkCollected();
      // 「我的收藏」里的歌单：先 await 缓存就位（避免 dio 失败先于
      // SharedPreferences 读到 cache，导致 _error 覆盖了缓存歌曲列表）
      if (widget.isInMyFavorites) {
        await _loadCachedSongs();
      }
      _fetchSongs();
      // 等歌曲列表加载完后检测"已缓存"状态
      Future.delayed(const Duration(milliseconds: 500), _checkPlayableSongs);
    });
  }

  /// 「我的收藏」歌单的本地缓存读取。无网络时立即显示。失败忽略。
  Future<void> _loadCachedSongs() async {
    final key = _cacheKey();
    if (key == null || key.isEmpty) return;
    try {
      final cached = await FavoriteListsCache.readPlaylistSongs(key);
      if (!mounted) return;
      if (cached.isNotEmpty && _songs.isEmpty) {
        setState(() {
          _songs = cached;
          _isLoading = false;
          // 兜底：清掉之前网络失败留下的错误文案（dio 失败通常比
          // SharedPreferences 快，会先写 _error 覆盖 UI）
          _error = null;
        });
      }
    } catch (_) {
      // 忽略
    }
  }

  /// 歌单内容缓存 key。与 [_fetchSongs] 实际请求用的 id 对齐：
  /// `subscribedListId` 优先（用户订阅/收藏版本的 listid），其次 `listCreateListid`（自建），
  /// 最后 fallback 到 `id`。
  String? _cacheKey() {
    if (!widget.isInMyFavorites) return null;
    return widget.playlist.subscribedListId ??
        widget.playlist.listCreateListid ??
        widget.playlist.id;
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

  /// 缓存的过滤/排序结果，避免每次 build 重新计算
  List<Song>? _cachedDisplaySongs;
  String? _lastSearchQuery;
  _SortBy? _lastSortBy;
  bool? _lastSortAscending;
  bool? _lastShowOnlyPlayable;
  int? _lastPlayableIdsHash;

  /// 获取当前显示的歌曲列表（带缓存）
  List<Song> get _displaySongs {
    if (_cachedDisplaySongs != null &&
        _lastSearchQuery == _searchQuery &&
        _lastSortBy == _sortBy &&
        _lastSortAscending == _sortAscending &&
        _lastShowOnlyPlayable == _showOnlyPlayable &&
        _lastPlayableIdsHash == _playableIds.length) {
      return _cachedDisplaySongs!;
    }
    _rebuildDisplaySongs();
    return _cachedDisplaySongs!;
  }

  void _rebuildDisplaySongs() {
    List<Song> list;
    // 先按"已缓存"过滤（在搜索/排序之前；空集表示还没检测完）
    if (_showOnlyPlayable) {
      list = _songs.where((s) => _playableIds.contains(s.id)).toList();
    } else if (_searchQuery.isEmpty) {
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
    _lastShowOnlyPlayable = _showOnlyPlayable;
    _lastPlayableIdsHash = _playableIds.length;
  }

  /// 切换"仅显示已缓存"
  void _togglePlayableFilter() {
    setState(() {
      _showOnlyPlayable = !_showOnlyPlayable;
      _invalidateDisplaySongs();
    });
  }

  /// 检测 _songs 里哪些歌曲已经被流缓存（边听边存），
  /// 结果存在 _playableIds。完成后 invalidate display cache 触发重 build。
  Future<void> _checkPlayableSongs() async {
    if (_songs.isEmpty) return;
    try {
      await StreamCacheManager.instance.ensureInitialized();
    } catch (_) {}

    final ids = <String>{};
    for (final song in _songs) {
      try {
        final entry = StreamCacheRepository.instance.getEntry(song.id);
        if (entry != null && entry.audio.isNotEmpty) {
          ids.add(song.id);
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _playableIds = ids;
      _invalidateDisplaySongs();
    });
  }

  /// 使显示列表缓存失效
  void _invalidateDisplaySongs() {
    _cachedDisplaySongs = null;
  }

  // ==================== 批量选择模式 ====================

  void _enterMultiSelectMode(String songId) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedSongIds.clear();
      _selectedSongIds.add(songId);
      // 退出搜索状态，显示全部歌曲供选择
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
      _invalidateDisplaySongs();
    });
  }

  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedSongIds.clear();
    });
  }

  void _toggleSongSelection(String songId) {
    setState(() {
      if (_selectedSongIds.contains(songId)) {
        _selectedSongIds.remove(songId);
        // 如果取消选中了最后一首，自动退出多选
        if (_selectedSongIds.isEmpty) {
          _isMultiSelectMode = false;
        }
      } else {
        _selectedSongIds.add(songId);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedSongIds.length == _displaySongs.length) {
        _selectedSongIds.clear();
      } else {
        _selectedSongIds
          ..clear()
          ..addAll(_displaySongs.map((s) => s.id));
      }
    });
  }

  // ==================== 批量下载 ====================

  void _showBatchDownloadDialog() {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先登录'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final selectedSongs =
        _songs.where((s) => _selectedSongIds.contains(s.id)).toList();
    if (selectedSongs.isEmpty) return;

    final qualityOptions = [
      ('标准音质 (128kbps)', '128'),
      ('高音质 (320kbps)', '320'),
      ('无损音质 (FLAC)', 'flac'),
      ('Hi-Res 无损', 'high'),
    ];

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Column(
          children: [
            const Text('批量下载'),
            Text(
              '已选 ${selectedSongs.length} 首歌曲',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '部分歌曲不支持所选音质时将自动降级',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        children: qualityOptions.map((opt) {
          final (label, quality) = opt;
          return SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx);
              _startBatchDownload(selectedSongs, quality);
            },
            child: Row(
              children: [
                Icon(Icons.music_note,
                    size: 20, color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  void _startBatchDownload(List<Song> songs, String quality) async {
    _exitMultiSelectMode();
    if (!mounted) return;

    final downloadsProvider = context.read<DownloadsProvider>();
    final total = songs.length;
    final progress = ValueNotifier<int>(0);
    final currentTitle = ValueNotifier<String?>(null);
    final downgraded = ValueNotifier<int>(0);
    bool dialogActive = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AnimatedBuilder(
        animation: Listenable.merge([progress, currentTitle, downgraded]),
        builder: (ctx, _) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: total > 0 ? progress.value / total : 0,
              ),
              const SizedBox(height: 16),
              Text('正在处理 ${progress.value} / $total'),
              if (currentTitle.value != null) ...[
                const SizedBox(height: 8),
                Text(
                  currentTitle.value!,
                  style: Theme.of(ctx).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (downgraded.value > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '已降级 ${downgraded.value} 首',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                dialogActive = false;
                Navigator.pop(ctx);
              },
              child: const Text('后台下载'),
            ),
          ],
        ),
      ),
    ).then((_) => dialogActive = false);

    final result = await downloadsProvider.downloadMultipleSongs(
      songs,
      quality: quality,
      onProgress: (c, t, title, d) {
        if (!dialogActive) return;
        progress.value = c;
        currentTitle.value = title;
        downgraded.value = d;
      },
    );

    if (dialogActive && mounted) {
      Navigator.pop(context);
    }

    if (dialogActive && mounted) {
      _showBatchDownloadResult(result);
    }

    progress.dispose();
    currentTitle.dispose();
    downgraded.dispose();
  }

  void _showBatchDownloadResult(Map<String, int> result) {
    final success = result['success'] ?? 0;
    final failed = result['failed'] ?? 0;
    final skipped = result['skipped'] ?? 0;
    final downgraded = result['downgraded'] ?? 0;
    final blocked = result['blocked'] ?? 0;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已加入下载: $success 首'),
            if (failed > 0)
              Text('失败: $failed 首',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            if (skipped > 0) Text('跳过（已下载）: $skipped 首'),
            if (downgraded > 0) Text('音质自动降级: $downgraded 首'),
            if (blocked > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '风控拦截: $blocked 首\n你的账号已被kugou风控,请等待kugou解除风控后再试',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelectedSongs() async {
    if (_selectedSongIds.isEmpty) return;
    final listid = _deleteListid;
    if (listid == null || listid.isEmpty) return;

    final count = _selectedSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌曲'),
        content: Text('确定从歌单中删除选中的 $count 首歌曲吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isDeleting = true);

    // 构造 fileids：优先用 fileId（>0），否则用 song.id（hash）
    final selectedSongs = _songs.where((s) => _selectedSongIds.contains(s.id)).toList();
    final fileids = selectedSongs.map((s) {
      if (s.fileId != null && s.fileId! > 0) return s.fileId.toString();
      return s.id;
    }).join(',');

    try {
      final api = KugouApiClient();
      final result = await api.deletePlaylistTracks(listid, fileids);
      if (!mounted) return;

      if (result != null) {
        // 从本地列表中移除已删除的歌曲
        setState(() {
          _songs.removeWhere((s) => _selectedSongIds.contains(s.id));
          _isMultiSelectMode = false;
          _selectedSongIds.clear();
          _isDeleting = false;
          _invalidateDisplaySongs();
        });
        // 通知「我的收藏」刷新歌曲数
        context.read<PlaylistCollectionNotifier>().notifyChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已删除 $count 首歌曲'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else if (mounted) {
        setState(() => _isDeleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('删除失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      } else {
        // 延迟聚焦，等 UI 构建完成
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

    // 高亮提示
    setState(() => _highlightSongId = currentSong.id);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightSongId = null);
    });

    // 使用 SliverChildBuilderDelegate 的 key 来定位并滚动
    // 通过 ScrollController 滚动到大致位置（每项约 72px 高度）
    const itemHeight = 72.0;
    final targetOffset = index * itemHeight;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _showCommentsSheet(BuildContext context) {
    // 收藏歌单使用 listCreateGid 作为评论 ID（原始歌单的 global_collection_id）
    // 专辑使用 globalCollectionId（如果有的话）
    final commentId = widget.isAlbum
        ? (widget.albumGlobalCollectionId ?? widget.playlist.id)
        : (widget.playlist.listCreateGid ?? widget.playlist.id);
    final commentType = widget.isAlbum ? 'album' : 'playlist';
    debugPrint('[CommentsSheet] commentId=$commentId, commentType=$commentType');
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
                // 拖动手柄
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 标题栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.comment_outlined,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '评论',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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
                // 评论列表（使用 DraggableScrollableSheet 的 controller 实现拖拽扩展）
                Expanded(
                  child: PlaylistCommentsView(
                    specialId: commentId,
                    commentType: commentType,
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

  // ==================== 收藏本地缓存（解决后端 user/playlist 列表 ~1-2 分钟缓存才同步的问题）====================

  /// 查询当前歌单是否已被收藏。
  /// 「我收藏」里点进来的歌单本身已是已收藏状态，直接标记为已收藏。
  Future<void> _checkCollected() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 「我收藏」里的歌单直接标记为已收藏
    if (widget.isInMyFavorites) {
      if (mounted) {
        setState(() {
          _isCollected = true;
        });
      }
      return;
    }

    // 1) 本地缓存优先：即时显示红心，不再等后端 1~2 分钟的缓存
    final cached = await CollectedPlaylistStore.getListId(widget.playlist.id);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = cached;
        });
      }
      return;
    }

    // 2) 本地无记录时回退到服务器查询（覆盖在官方 App / 其他端收藏的外部场景）
    final listid = await _findCollectedListId(api);
    if (listid != null && mounted) {
      await CollectedPlaylistStore.setListId(widget.playlist.id, listid);
      setState(() {
        _isCollected = true;
        _collectedListId = listid;
      });
    }
  }

  /// 尽量多路径地从 playlist/add 响应里解析出新建歌单的 listid
  String? _parseListId(Map<String, dynamic>? result) {
    if (result == null) return null;
    final data = result['data'];
    if (data is Map) {
      for (final key in const ['listid', 'list_id', 'ListId', 'id']) {
        final v = data[key];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
    }
    for (final key in const ['listid', 'list_id', 'id']) {
      final v = result[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return null;
  }

  /// 兜底：重新拉取用户歌单列表，按 gid/name 匹配出新收藏歌单的 listid
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
          if (gid == widget.playlist.id || name == widget.playlist.name) {
            return item['listid']?.toString();
          }
        }
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  Future<void> _collectPlaylist() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先登录'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    try {
      String? listCreateUserid = widget.playlist.listCreateUserid;
      String? listCreateListid = widget.playlist.listCreateListid;
      if ((listCreateUserid == null || listCreateListid == null) &&
          widget.playlist.id.contains('_')) {
        final parts = widget.playlist.id.split('_');
        if (parts.length >= 4) {
          listCreateUserid ??= parts[2];
          listCreateListid ??= parts[3];
        }
      }
      final result = await api.createPlaylist(
        widget.playlist.name,
        type: 1,
        listCreateUserid: listCreateUserid,
        listCreateListid: listCreateListid,
        globalCollectionId: widget.playlist.id,
      );
      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('收藏失败，请重试'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      // 尽量解析新建歌单的 listid；解析不到再回退到服务器查询
      String? newId = _parseListId(result);
      newId ??= await _findCollectedListId(api);
      await CollectedPlaylistStore.setListId(widget.playlist.id, newId);
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = newId;
        });
        // 通知「我的收藏」tab 立即刷新（绕过本地代理 2 分钟缓存）
        context.read<PlaylistCollectionNotifier>().notifyChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('收藏成功'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('收藏失败'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _uncollectPlaylist() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 优先取本地缓存 / 页面状态里的 listid，取不到再回查服务器
    String? listId = await CollectedPlaylistStore.getListId(widget.playlist.id);
    listId ??= _collectedListId;
    listId ??= await _findCollectedListId(api);
    if (listId == null || listId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找不到收藏记录，无法取消'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      // 收藏的歌单用 type=0 取消（与「我的收藏」页删除收藏歌单保持一致）
      final result = await api.deletePlaylist(listId, type: 0);
      if (result != null && mounted) {
        await CollectedPlaylistStore.remove(widget.playlist.id);
        setState(() {
          _isCollected = false;
          _collectedListId = null;
        });
        // 通知「我的收藏」tab 立即刷新（绕过本地代理 2 分钟缓存）
        context.read<PlaylistCollectionNotifier>().notifyChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已取消收藏'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('取消收藏失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('取消收藏失败'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _fetchSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 「我的收藏」里的歌单（listid 是用户订阅的版本）走 listid 接口拿完整歌曲；
      // 其它歌单（发现页、排行榜、热门歌单）走 globalCollectionId。
      // 两种情况都强制 forceRefresh，绕过本地代理 2 分钟 apicache，
      // 避免"换个歌单回来老歌单不刷新"。
      final api = KugouApiClient();
      final isLoggedIn = api.isLoggedIn;
      // 拉取歌曲的 listid 优先级：
      // 1. subscribedListId（用户订阅/收藏版本的 listid，调 /playlist/track/all/new）
      // 2. listCreateListid（仅自己创建的歌单有效，收藏别人的歌单这个是原作者的 id）
      final fetchListid =
          widget.playlist.subscribedListId ?? widget.playlist.listCreateListid;

      List<Song> all = [];
      // 追踪 API 是否真的成功过：KugouApiClient._get 在网络异常时返回 null
      // （吞了 DioException），不抛异常；KugouProvider.getPlaylistTrackAll
      // 类似，仅设 _error 后吞掉。所以必须主动追踪"有没有成功调用过"。
      bool apiSucceeded = false;
      if (isLoggedIn && fetchListid != null && fetchListid.isNotEmpty) {
        // 已登录 + 有 listid：用 /playlist/track/all/new 拉（仅支持用户创建/收藏的歌单）
        const int pageSize = 200;
        const int maxPages = 10;
        for (int page = 1; page <= maxPages; page++) {
          final r = await api.getPlaylistSongsByListid(
            listid: fetchListid,
            page: page,
            pagesize: pageSize,
            noCache: true,
          );
          if (!mounted) return;
          if (r == null) break;
          apiSucceeded = true;
          final batch = r.songs.map((s) => s.toSong()).toList();
          all.addAll(batch);
          if (batch.length < pageSize) break;
        }
        // listid 接口拉不到歌曲时，回退到用原始歌单的 global_collection_id 拉取
        // （收藏的歌单 listid 有时失效，用原始歌单的 listCreateGid 才能正确拉取
        final fallbackGid =
            widget.playlist.listCreateGid ??
            (widget.playlist.listCreateListid != null
                ? null
                : widget.playlist.id);
        if (all.isEmpty && fallbackGid != null && fallbackGid.isNotEmpty) {
          await context.read<KugouProvider>().getPlaylistTrackAll(
            id: fallbackGid,
            forceRefresh: true,
          );
          if (!mounted) return;
          all = context
              .read<KugouProvider>()
              .currentPlaylistSongs
              .map((e) => e.toSong())
              .toList();
          if (all.isNotEmpty) apiSucceeded = true;
        }
      } else if (widget.playlist.id.isNotEmpty) {
        // 未登录 或 无 listid：用 global_collection_id 调 /playlist/track/all 拉
        await context.read<KugouProvider>().getPlaylistTrackAll(
          id: widget.playlist.id,
          forceRefresh: true,
        );
        if (!mounted) return;
        all = context
            .read<KugouProvider>()
            .currentPlaylistSongs
            .map((e) => e.toSong())
            .toList();
        if (all.isNotEmpty) apiSucceeded = true;
      } else {
        // 普通歌单（未登录）：走 KugouProvider 的分页聚合（/playlist/track/all，30 一次翻页拉全）
        await context.read<KugouProvider>().getPlaylistTrackAll(
          id: widget.playlist.id,
          forceRefresh: true,
        );
        if (!mounted) return;
        all = context
            .read<KugouProvider>()
            .currentPlaylistSongs
            .map((e) => e.toSong())
            .toList();
        if (all.isNotEmpty) apiSucceeded = true;
      }

      setState(() {
        // 网络拿到数据时正常覆盖；网络空但本地已有 cache 时保留 cache，
        // 避免断网重进歌单时被空响应覆盖掉本地缓存的歌曲
        if (all.isNotEmpty || _songs.isEmpty) {
          _songs = all.where((song) {
            final validTitle = song.title.isNotEmpty && song.title != '-';
            final validDuration = song.duration.inMilliseconds > 0;
            return validTitle && validDuration;
          }).toList();
        }
        _invalidateDisplaySongs();
      });
      // 「我的收藏」里的歌单：成功拉到歌曲时写本地缓存
      if (apiSucceeded && _songs.isNotEmpty) {
        final cacheKey = _cacheKey();
        if (cacheKey != null && cacheKey.isNotEmpty) {
          FavoriteListsCache.savePlaylistSongs(cacheKey, _songs);
        }
      } else if (!apiSucceeded) {
        // 网络失败（KugouApiClient._get 把异常吞成 null 时走这里）
        // 有 cache（_songs 非空）保留显示；无 cache 报错
        if (mounted) {
          setState(() {
            if (_songs.isEmpty) {
              _error = '加载失败，请检查手机网络连接（WiFi / 移动数据）';
            } else {
              _error = null;
            }
          });
        }
      }
    } catch (e) {
      // 已有本地缓存（_songs 非空）时，吞掉错误，保留 cache 给用户查看
      if (mounted) {
        setState(() {
          if (_songs.isNotEmpty) {
            _isLoading = false;
            _error = null;
          } else {
            _error = e.toString();
          }
        });
      }
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final displayPlaylist = widget.playlist.copyWith(songs: _songs);

    return PopScope(
      canPop: !_isMultiSelectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isMultiSelectMode) _exitMultiSelectMode();
      },
      child: Scaffold(
      body: Column(
        children: [
          if (_isLoading)
            const Expanded(child: Center(child: MD3ELoadingIndicator()))
          else ...[
            // 加载失败时显示顶部 banner（不再完全覆盖 UI，
            // 歌单的元数据/封面/描述仍可见）
            if (_error != null) _buildErrorBanner(context, colorScheme, textTheme),
            if (_isMultiSelectMode)
              _buildMultiSelectBar(colorScheme, textTheme),
            Expanded(
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  if (!_isMultiSelectMode)
                  SliverAppBar(
                        expandedHeight: 280,
                        pinned: true,
                        // pinned 后顶栏背景色：滚动到 expandedHeight - kToolbarHeight
                        // 之后从透明渐变到 surface
                        backgroundColor: Color.lerp(
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
                              icon: Icon(
                                _showOnlyPlayable
                                    ? Icons.filter_alt
                                    : Icons.filter_alt_outlined,
                                color: _showOnlyPlayable
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              tooltip: _showOnlyPlayable
                                  ? '显示全部'
                                  : '仅显示已缓存',
                              onPressed: _togglePlayableFilter,
                            ),
                          if (_songs.isNotEmpty)
                            IconButton(
                              icon: Icon(
                                _isSearching ? Icons.close : Icons.search,
                              ),
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
                                        Icon(
                                          _sortAscending
                                              ? Icons.arrow_upward
                                              : Icons.arrow_downward,
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
                                      const Text('歌曲名称'),
                                      if (_sortBy == _SortBy.title) ...[
                                        const Spacer(),
                                        Icon(
                                          _sortAscending
                                              ? Icons.arrow_upward
                                              : Icons.arrow_downward,
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
                                          _sortAscending
                                              ? Icons.arrow_upward
                                              : Icons.arrow_downward,
                                          size: 16,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                        // pinned 后顶栏标题：滚动超过阈值后 fade-in 显示歌单名称
                        title: Opacity(
                          opacity: ((_scrollOffset - (280 - kToolbarHeight)) /
                                  60.0)
                              .clamp(0.0, 1.0),
                          child: Text(
                            displayPlaylist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        flexibleSpace: FlexibleSpaceBar(
                          background: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  colorScheme.primaryContainer,
                                  colorScheme.surface,
                                ],
                              ),
                            ),
                            child: SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  48,
                                  24,
                                  16,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 140,
                                        height: 140,
                                        child:
                                            displayPlaylist.artworkUri != null
                                            ? CachedNetworkImage(
                                                imageUrl:
                                                    displayPlaylist.artworkUri!,
                                                fit: BoxFit.cover,
                                                placeholder: (_, _) => Container(
                                                  color: colorScheme
                                                      .surfaceContainerHighest,
                                                  child: Icon(
                                                    Icons.queue_music,
                                                    size: 48,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                                errorWidget: (_, _, _) =>
                                                    Container(
                                                      color: colorScheme
                                                          .surfaceContainerHighest,
                                                      child: Icon(
                                                        Icons.queue_music,
                                                        size: 48,
                                                        color: colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                              )
                                            : Container(
                                                color: colorScheme
                                                    .surfaceContainerHighest,
                                                child: Icon(
                                                  Icons.queue_music,
                                                  size: 48,
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 20),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          Text(
                                            displayPlaylist.name,
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${displayPlaylist.creator ?? ''} · ${_songs.length} 首',
                                            style: textTheme.labelMedium
                                                ?.copyWith(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
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
                        ),
                      ),
                      // 歌单介绍（默认折叠，最多显示2行，带动画）
                      if (!_isMultiSelectMode &&
                          displayPlaylist.description != null &&
                          displayPlaylist.description!.isNotEmpty)
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
                                          '歌单介绍',
                                          style: textTheme.labelLarge?.copyWith(
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
                                        displayPlaylist.description!,
                                        maxLines: _isDescriptionExpanded ? null : 2,
                                        overflow: _isDescriptionExpanded
                                              ? null
                                              : TextOverflow.ellipsis,
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
                      // 歌单内搜索栏（点击搜索图标后展开）
                      if (!_isMultiSelectMode && _isSearching)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              decoration: InputDecoration(
                                hintText: '搜索歌单内的歌曲...',
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
                                fillColor: colorScheme.surfaceContainerHighest
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
                      if (!_isMultiSelectMode)
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
                                  onPressed: () {
                                    final songs = _displaySongs;
                                    if (songs.isNotEmpty) {
                                      context
                                          .read<PlayerProvider>()
                                          .playOnlinePlaylist(songs, 0);
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
                                      final shuffled = List<Song>.from(songs)
                                        ..shuffle();
                                      context
                                          .read<PlayerProvider>()
                                          .playOnlinePlaylist(shuffled, 0);
                                    }
                                  },
                                  icon: const Icon(Icons.shuffle),
                                  label: const Text('随机播放'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 红心收藏按钮：始终显示，支持收藏/取消收藏
                              IconButton.filledTonal(
                                onPressed: widget.isInMyFavorites
                                    ? _uncollectPlaylist
                                    : (_isCollected
                                        ? _uncollectPlaylist
                                        : _collectPlaylist),
                                icon: Icon(
                                  widget.isInMyFavorites || _isCollected
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: widget.isInMyFavorites || _isCollected
                                      ? colorScheme.error
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final song = _displaySongs[index];
                          final isHighlighted = _highlightSongId == song.id;
                          final isSelected = _selectedSongIds.contains(song.id);
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            color: isHighlighted && !_isMultiSelectMode
                                ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                                : Colors.transparent,
                            child: SongListItem(
                              song: song,
                              isSelectMode: _isMultiSelectMode,
                              isSelected: isSelected,
                              onLongPress: () => _enterMultiSelectMode(song.id),
                              onSelectToggle: () => _toggleSongSelection(song.id),
                              onTap: () {
                                context.read<PlayerProvider>().playOnlinePlaylist(
                                  _displaySongs,
                                  index,
                                );
                              },
                              onMoreTap: () {},
                            ),
                          );
                        }, childCount: _displaySongs.length),
                      ),
                      // 搜索无结果提示
                      if (!_isMultiSelectMode &&
                          _isSearching && _displaySongs.isEmpty && _songs.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.search_off,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '没有找到「$_searchQuery」相关的歌曲',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // 离线/首次打开无缓存时：歌单歌曲为空状态
                      if (!_isMultiSelectMode && _songs.isEmpty)
                        SliverToBoxAdapter(
                          child: _buildEmptySongsHint(colorScheme, textTheme),
                        ),
                      // 开启"仅显示已缓存"但无匹配歌曲时
                      if (!_isMultiSelectMode &&
                          _showOnlyPlayable &&
                          _songs.isNotEmpty &&
                          _displaySongs.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.cloud_off_outlined,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '没有已缓存的歌曲',
                                  style: textTheme.titleMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '播放歌曲时会自动缓存',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
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
            ],
            ),
      ),
    );
  }

  /// 离线时无缓存歌曲的空状态：仅展示歌单元数据，不显示错误页面。
  Widget _buildEmptySongsHint(ColorScheme colorScheme, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            _error != null ? Icons.cloud_off_outlined : Icons.queue_music,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _error != null ? '暂无缓存的歌曲' : '暂无歌曲',
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(
              '联网后下拉刷新即可加载',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _fetchSongs,
              child: const Text('重新加载'),
            ),
          ],
        ],
      ),
    );
  }

  /// 加载失败顶部 banner：歌单元数据仍可看，不完全覆盖 UI。
  Widget _buildErrorBanner(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: _fetchSongs,
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onErrorContainer,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 多选模式顶栏：关闭 / 已选 N 首 / 全选 / 删除
  Widget _buildMultiSelectBar(ColorScheme colorScheme, TextTheme textTheme) {
    final selectedCount = _selectedSongIds.length;
    final totalCount = _displaySongs.length;
    final allSelected = selectedCount == totalCount && totalCount > 0;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitMultiSelectMode,
                tooltip: '退出选择',
              ),
              Expanded(
                child: Text(
                  '已选 $selectedCount 首',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_isDeleting)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: MD3ELoadingIndicator(size: 20),
                )
              else ...[
                IconButton(
                  icon: Icon(
                    allSelected ? Icons.deselect : Icons.select_all,
                  ),
                  onPressed: _toggleSelectAll,
                  tooltip: allSelected ? '取消全选' : '全选',
                ),
                IconButton(
                  icon: Icon(
                    Icons.download_outlined,
                    color: selectedCount > 0 ? colorScheme.primary : null,
                  ),
                  onPressed: selectedCount > 0 ? _showBatchDownloadDialog : null,
                  tooltip: '下载',
                ),
                if (widget.isUserCreated)
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      color: selectedCount > 0 ? colorScheme.error : null,
                    ),
                    onPressed: selectedCount > 0 ? _deleteSelectedSongs : null,
                    tooltip: '删除',
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
