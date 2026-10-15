import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/entry_transition_gate.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/collected_playlist_store.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/keyboard_expand_sheet.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/playlist_comments_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

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

  /// 页头真实封面是否已拿到加载完成的图片。喂给 `PlaylistCoverHero.destReady`：
  /// 进场飞行落位要等它变 true 才撤走，否则交接瞬间露出的是页头的兜底占位。
  final ValueNotifier<bool> _headerCoverReady = ValueNotifier<bool>(false);

  /// 进场转场动画（在任何 await 之前捕获，见 [_startLoadingAfterEntry]）。
  Animation<double>? _entryAnim;

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 转场动画对象必须在任何 await 之前抓好：让路逻辑之后不再碰 context。
      _entryAnim = ModalRoute.of(context)?.animation;
      _checkCollected();
      await _startLoadingAfterEntry();
    });
  }

  /// 进场转场收敛后才开始拉专辑详情/歌曲。
  ///
  /// `_fetchAlbum` 是两次 HTTP + 逐首 `toSong()` 映射，全跑在 UI 线程；落在转场
  /// 那几十帧里会把封面连贯过渡顶停（与 playlist_page 同一教训，见
  /// `lib/core/utils/entry_transition_gate.dart`）。页头现在首帧即渲染，所以动画
  /// 期间页面并不空。超时兜底由 `waitUntilEntrySettled` 保证，不会不加载。
  /// 转场后还要让过底栏收起动画（同 playlist_page，见 `waitUntilBottomChromeSettled`）。
  Future<void> _startLoadingAfterEntry() async {
    final waited = await waitUntilEntrySettled(_entryAnim);
    if (!mounted) return;
    // completed 回调跑在帧的动画阶段，再让出一帧，首屏列表构建才不挤进转场末帧。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (waited > 0) {
      // ignore: avoid_print
      print('[FlashTrace] AlbumDetailPage 让路转场 ${waited}ms '
          'id=${widget.album.id}');
    }
    await waitUntilBottomChromeSettled(context);
    if (!mounted) return;
    await _fetchAlbum();
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
      builder: (context) => KeyboardExpandScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        // 键盘弹出时也展开到这个高度，否则打字时列表被托盘比例限制成一条缝
        maxChildSize: 0.95,
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
                  margin: const EdgeInsets.only(top: AppSpacing.md),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                  child: Row(
                    children: [
                      Icon(Icons.comment_outlined, size: 20, color: colorScheme.onSurfaceVariant),
                      const Gap(AppSpacing.sm),
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
      body: SecondaryMiniPlayerHost(
        // 页头恒渲染：封面连贯过渡的**终点**必须在转场期间就存在，否则飞行只能
        // 等页面滑完后单独补飞（与 playlist_page 同一教训）。加载态降级成列表区的
        // 占位 sliver（见下方 `if (_isLoading)`），不再整页替换。
        // 错误仍走整页错误页——失败发生在转场之后，观感与改动前一致。
        child: _error != null
            ? _buildError(context, colorScheme)
            : Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        controller: _scrollController,
                        slivers: [
                          SliverAppBar(
                            expandedHeight: DetailPaneContent.headerHeight(
                            context,
                            280,
                          ),
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
                                    (_scrollOffset - (DetailPaneContent.headerHeight(
                                                    context,
                                                    280 ,
                                                  ) - kToolbarHeight))
                                        .clamp(0.0, 60.0) / 60,
                                  )!,
                            surfaceTintColor: Colors.transparent,
                            scrolledUnderElevation: 0,
                            actions: [
                              if (_songs.isNotEmpty)
                                IconButton(
                                  icon: Icon(_isSearching ? Icons.close : Icons.search,
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
                                M3ESortButton<_SortBy>(
                                  tooltip: '排序',
                                  current: _sortBy,
                                  options: const [
                                    (value: _SortBy.time, label: '添加时间'),
                                    (value: _SortBy.title, label: '歌曲名称'),
                                    (value: _SortBy.duration, label: '时长'),
                                  ],
                                  onPicked: (value, repeated) {
                                    setState(() {
                                      if (repeated) {
                                        // 再次点当前项 → 翻转升/降序
                                        _sortAscending = !_sortAscending;
                                      } else {
                                        _sortBy = value;
                                        _sortAscending = value == _SortBy.time ? false : true;
                                      }
                                      _invalidateDisplaySongs();
                                    });
                                  },
                                ),
                            ],
                            title: Opacity(
                              opacity: ((_scrollOffset - (DetailPaneContent.headerHeight(
                                                  context,
                                                  280 ,
                                                ) - kToolbarHeight)) / 60.0)
                                  .clamp(0.0, 1.0),
                              child: Text(
                                displayAlbum.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600,
                              ),
                              ),
                            ),
                            flexibleSpace: ClipRect(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  // 折叠时 flexibleSpace 高度从 224px 缩到 0：
                                  // 封面随可用高度平滑缩放（140 → 0）而非固定
                                  // 140 被视口上边界截断，避免 RenderFlex
                                  // overflow；可用高度不足以容纳封面+文字时
                                  // 文字淡出。与歌单页（playlist_page.dart）
                                  // 的防溢出方案保持一致。
                                  final safeTop = MediaQuery.paddingOf(context,
                                ).top;
                                  final availH = (constraints.maxHeight - 64 - safeTop)
                                      .clamp(0.0, constraints.maxHeight);
                                  final coverSize = availH.clamp(0.0, 140.0);
                                  // 标题透明度连续映射：可用高度充足时全显示，
                                  // 折叠到阈值以下时淡出，实现平滑过渡。
                                  final textOpacity = ((availH - 100) / 22).clamp(0.0, 1.0,
                                );
                                  return Stack(
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
                                              colorScheme.surface.withValues(alpha: 0,
                                            ),
                                            ],
                                          ),
                                        ),
                                        child: SafeArea(
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xxxl, AppSpacing.xl, AppSpacing.lg,
                                          ),
                                            child: Row(
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                SizedBox(
                                                  width: coverSize,
                                                  height: coverSize,
                                                  child: PlaylistCoverHero(
                                                    // tag 一律取 widget.album.id：与来源卡片
                                                    // （搜索专辑 tab / 新碟上架）同一个 Album 对象，
                                                    // 天然对齐。不能用 displayAlbum.id（_albumDetail
                                                    // 到位后会换一份 toAlbum()），也不能用
                                                    // globalCollectionId（已被歌单命名空间占用）。
                                                    tag: albumCoverHeroTag(
                                                      widget.album.id,
                                                    ),
                                                    radius: AppRadius.mdAll,
                                                    destReady: _headerCoverReady,
                                                    child: displayAlbum.artworkUri !=
                                                            null
                                                        ? CachedNetworkImage(
                                                            imageUrl: displayAlbum.artworkUri!,
                                                            memCacheWidth: 420,
                                                            memCacheHeight: 420,
                                                            // 兜底占位淡出默认 1s、图片淡入默认
                                                            // 500ms。共享元素过渡本身就是动画，
                                                            // 两端都不要再做渐变，否则落位时暗一下。
                                                            fadeOutDuration: Duration.zero,
                                                            fadeInDuration: Duration.zero,
                                                            // 真实封面的就绪信号：imageBuilder 只在
                                                            // 图片加载完成后被调用，此时占位图已经不
                                                            // 会再出现。
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
                                                              // （memCache 会包一层 ResizeImage），
                                                              // 不会多解码一份。
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
                                                            placeholder: (_, _) => Container(
                                                              color: colorScheme.surfaceContainerHighest,
                                                              child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant,
                                                            ),
                                                            ),
                                                            errorWidget: (_, _, _) => Container(
                                                              color: colorScheme.surfaceContainerHighest,
                                                              child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant,
                                                            ),
                                                            ),
                                                          )
                                                        : Container(
                                                            color: colorScheme.surfaceContainerHighest,
                                                            child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant,
                                                          ),
                                                          ),
                                                  ),
                                                ),
                                                const SizedBox(width: 20),
                                                Expanded(
                                                  // 文字区可视高度随 availH 收缩：超出部分由
                                                  // ClipRect 裁掉并配合淡出，折叠过程中不触发
                                                  // RenderFlex overflow（黄条）。
                                                  child: SizedBox(
                                                    height: availH,
                                                    child: Align(
                                                      alignment: Alignment.bottomLeft,
                                                      child: ClipRect(
                                                        child: Opacity(
                                                          opacity: textOpacity,
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Text(
                                                                displayAlbum.name,
                                                                maxLines: 2,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold,
                                                                  ),
                                                              ),
                                                              if (displayAlbum.artist.isNotEmpty) ...[
                                                                const Gap(AppSpacing.xs,
                                                              ),
                                                                Text(
                                                                  displayAlbum.artist,
                                                                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant,
                                                                    ),
                                                                ),
                                                              ],
                                                              const Gap(AppSpacing.xs,
                                                            ),
                                                              Text(
                                                                // 页头现在首帧即渲染，歌曲却要等接口：
                                                                // 加载期取传入 album 自带的曲数，否则会先
                                                                // 闪一帧「0 首歌曲」。
                                                                '${_songs.isNotEmpty ? _songs.length : displayAlbum.songCount} 首歌曲',
                                                                style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant,
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
                        ),
                          // 专辑介绍
                          if (description != null && description.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.none,
                              ),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isDescriptionExpanded = !_isDescriptionExpanded;
                                    });
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(AppSpacing.md),
                                    decoration: BoxDecoration(
                                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                      borderRadius: AppRadius.mdAll,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.info_outline, size: 16, color: colorScheme.onSurfaceVariant,
                                          ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '专辑介绍',
                                              style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant,
                                                ),
                                            ),
                                            const Spacer(),
                                            AnimatedRotation(
                                              turns: _isDescriptionExpanded ? 0.5 : 0,
                                              duration: const Duration(milliseconds: 200,
                                            ),
                                              child: Icon(Icons.keyboard_arrow_down, size: 20, color: colorScheme.onSurfaceVariant,
                                            ),
                                            ),
                                          ],
                                        ),
                                        const Gap(AppSpacing.sm),
                                        AnimatedSize(
                                          duration: const Duration(milliseconds: 250,
                                        ),
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
                                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.none,
                              ),
                                child: TextField(
                                  controller: _searchController,
                                  focusNode: _searchFocusNode,
                                  contextMenuBuilder: buildAppTextContextMenu,
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
                                      borderRadius: AppRadius.xlAll,
                                      borderSide: BorderSide.none,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md,
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
                          // 加载中：歌曲区只挂占位，页头/介绍首帧即渲染（见 body 处说明）。
                          // 原实现整页加载闸门期间只有转圈，页头（封面连贯过渡的终点实体）
                          // 要等专辑详情回来才存在，观感变成「先看加载、再看到动画」。
                          if (_isLoading)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 48),
                                child: Center(child: M3ELoadingIndicator()),
                              ),
                            ),
                          // 播放按钮 + 收藏红心
                          if (!_isLoading)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm,
                            ),
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
                                  const Gap(AppSpacing.md),
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
                                  const Gap(AppSpacing.md),
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
                          if (!_isLoading)
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index,
                          ) {
                                final song = _displaySongs[index];
                                final isHighlighted = _highlightSongId == song.id;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  color: isHighlighted
                                      ? colorScheme.primaryContainer.withValues(alpha: 0.5,
                                    )
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
                              childCount: _displaySongs.length),
                          ),
                          // 搜索无结果
                          if (_isSearching && _displaySongs.isEmpty && _songs.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.xxl),
                                child: Column(
                                  children: [
                                    Icon(Icons.search_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                  ),
                                    const Gap(AppSpacing.sm),
                                    Text(
                                      '没有找到「$_searchQuery」相关的歌曲',
                                      style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant,
                                    ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
      ),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(onPressed: _fetchAlbum, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
