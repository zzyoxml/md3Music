import '../../core/layout/adaptive_navigator.dart';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/build_flags.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/tab_snap_physics.dart';
import '../../core/widgets/app_background.dart';
import '../../providers/theme_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../playlist/playlist_page.dart';
import '../player/secondary_mini_player.dart';
import 'explore_sections.dart';
import 'hot_search_board_card.dart';

class SearchPage extends StatefulWidget {
  /// 打开时预填并立即执行的查询（桌面顶部工具栏搜索框提交时传入，见计划 4.3）。
  final String? initialQuery;

  const SearchPage({super.key, this.initialQuery});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  late TabController _tabController;
  List<String> _searchHistory = [];
  String _query = '';
  bool _hasSearched = false;
  String _currentSearchType = 'song';

  // 云盘搜索 tab 的本地状态
  // 云盘不走通用 /search 接口，进入云盘 tab 时按需懒加载一次用户云盘歌单，
  // 之后用 [_query] 在内存中过滤。生命周期跟随 SearchPage。
  List<Song> _cloudSongs = [];
  bool _cloudLoaded = false;
  bool _cloudLoading = false;
  String? _cloudError;

  static const _historyKey = 'search_history';

  @override
  void initState() {
    super.initState();
    // 云盘 tab 已于 2026-10-10 下线（见下方 TabBar / TabBarView / types 三处注释），
    // 页签数由 6 减为 5 —— 三处必须同步，否则 TabController 索引与 children 错位。
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadSearchHistory();
    // 热搜榜单：进页后台拉一次；失败不自动重试（卡内有「重试」），
    // 状态隔离在 KugouProvider.hotSearch，不影响结果区 loading/error。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<KugouProvider>().loadHotSearch();
    });
    // 桌面工具栏搜索框提交：预填查询并在首帧后立即执行搜索。
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _searchController.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performSearch(q);
      });
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    // 云盘 tab 下线：types 必须与 TabBar 标签、TabBarView children 顺序一致
    final types = ['song', 'album', 'artist', 'special', /* 'cloud', */ 'lyric'];
    final newType = types[_tabController.index];
    if (newType != _currentSearchType && _query.isNotEmpty) {
      _currentSearchType = newType;
      if (newType == 'cloud') {
        // 云盘是本地过滤：未加载过就触发懒加载，加载完成后由 _query 在内存过滤
        if (!_cloudLoaded && !_cloudLoading) {
          _loadCloudSongsForSearch();
        }
        return;
      }
      final kugouProvider = context.read<KugouProvider>();
      if (kugouProvider.hasSearchResultForType(_query, newType)) {
        kugouProvider.restoreSearchResultFromCache(_query, newType);
      } else {
        _performSearchByType(_query, newType);
      }
    }
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _searchHistory = prefs.getStringList(_historyKey) ?? [];
    });
  }

  Future<void> _saveSearchHistory(String query) async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = [
      query,
      ..._searchHistory.where((h) => h != query),
    ].take(10).toList();
    await prefs.setStringList(_historyKey, _searchHistory);
    setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    setState(() {
      _searchHistory = [];
    });
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _query = query.trim();
      _hasSearched = true;
      _currentSearchType = 'song';
    });
    _tabController.animateTo(0);
    _saveSearchHistory(_query);

    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.search(_query, type: 'song');
  }

  Future<void> _performSearchByType(String query, String type) async {
    if (query.trim().isEmpty) return;
    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.search(query, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themeProvider = context.watch<ThemeProvider>();
    final useBackgroundImage = themeProvider.useBackgroundImage;
    // 预计算背景图 provider（与 SliverAppBar flexibleSpace 用同一 cacheWidth →
    // ImageCache 同 key 共享解码），作为参数传入 _TabBarDelegate，
    // 避免在 SliverPersistentHeaderDelegate.build 内 watch ThemeProvider
    // 污染 NestedScrollView 的 sliver 链（导致 TabBarView 结果区被异常重建/覆盖）。
    ImageProvider? tabBarBackgroundImage;
    if (useBackgroundImage) {
      final size = MediaQuery.sizeOf(context);
      final cacheWidth = (size.width * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(540, 1440);
      tabBarBackgroundImage = backgroundImageProvider(
        themeProvider,
        cacheWidth: cacheWidth,
      );
    }

    return Scaffold(
      body: SecondaryMiniPlayerHost(
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverAppBar(
                floating: true,
                pinned: true,
                // 有壁纸时顶栏全透明，flexibleSpace 独立加载同一张背景图
                // （topCenter 对齐与页面主体背景视觉连续）；列表滚到顶栏下时
                // 被这张背景图盖住（不透底下 UI）；无壁纸时不透明 surface
                backgroundColor: useBackgroundImage
                    ? Colors.transparent
                    : colorScheme.surface,
                    // RepaintBoundary：全屏高斯模糊随滚动逐帧移动，独立绘制层把
                    // 模糊重算限制在本层内，不让它扩散到整页（对齐 playlist_page
                    // flexibleSpace 的做法，AGENTS.md §10）。
                    flexibleSpace: useBackgroundImage
                        ? RepaintBoundary(child: ClipRect(
                            child: Builder(builder: (context) {
                              // 与页面主体共用同一背景图解码结果（同 cacheWidth →
                              // ImageCache 同 key），避免各自解码
                              final size = MediaQuery.sizeOf(context);
                              final cacheWidth = (size.width *
                                          MediaQuery.devicePixelRatioOf(context))
                                      .round()
                                      .clamp(540, 1440);
                              final tp = context.watch<ThemeProvider>();
                              // 顶栏区域用全屏尺寸 + 全屏 cover 渲染背景图，再
                              // topCenter 裁剪显示顶部：缩放比例与主体背景完全一致，
                              // 否则窄区域内单独 cover 会放大错位
                              return OverflowBox(
                                alignment: Alignment.topCenter,
                                minWidth: size.width,
                                maxWidth: size.width,
                                minHeight: size.height,
                                maxHeight: size.height,
                                child: SizedBox(
                                  width: size.width,
                                  height: size.height,
                                  // 与 AppBackground 同层结构：surface 打底 +
                                  // 模糊（backgroundBlur）+ 透明度（backgroundOpacity），
                                  // 顶栏背景跟随主体模糊/透明度改动
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.surface,
                                      ),
                                      Opacity(
                                        opacity: tp.backgroundOpacity,
                                        child: ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: tvBlurSigma(
                                              tp.backgroundBlur,
                                            ),
                                            sigmaY: tvBlurSigma(
                                              tp.backgroundBlur,
                                            ),
                                          ),
                                          child: Image(
                                            image: backgroundImageProvider(
                                              tp,
                                              cacheWidth: cacheWidth,
                                            ),
                                            fit: BoxFit.cover,
                                            gaplessPlayback: true,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                        ),
                          ))
                        : null,
                    surfaceTintColor: Colors.transparent,
                    title: SizedBox(
                      height: 40,
                      child: TextField(
                        controller: _searchController,
                        contextMenuBuilder: buildAppTextContextMenu,
                        decoration: InputDecoration(
                          hintText: '搜索歌曲、歌手、专辑',
                          hintStyle: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 20,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: Icon(
                                    Icons.clear,
                                    size: 18,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _query = '';
                                      _hasSearched = false;
                                    });
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.none,
                          ),
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: _performSearch,
                        onChanged: (value) {
                          setState(() {});
                          if (value.trim().isNotEmpty) {
                            context.read<KugouProvider>().getSearchSuggest(
                              value.trim(),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                  if (_hasSearched)
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        // tv: 每个 Tab 一个单停点（OK = 切到该页），非 TV 构建
                        // TvCardFocus 原样透传。这里不包 TvScrollRegion：
                        // _TabBarDelegate 的字段类型是 TabBar，且 minExtent 要读
                        // 它的 preferredSize；6 个页签在 TV 宽度下不滚动，
                        // 左右换页签由同 scope 内的几何候选即可胜任。
                        tabBar: TabBar(
                          controller: _tabController,
                          tabs: [
                            for (final (i, label) in const [
                              '歌曲',
                              '专辑',
                              '歌手',
                              '歌单',
                              // 「搜索页 → 云盘」页签下线（2026-10-10）：
                              // 云盘入口保留在「我的 → 云盘」（cloud_music_page.dart），
                              // 搜索结果里不再单独占一个页签。
                              // '云盘',
                              '歌词',
                            ].indexed)
                              TvCardFocus(
                                onSelect: () => _tabController.animateTo(i),
                                debugLabel: 'search-tab-$label',
                                child: Tab(text: label),
                              ),
                          ],
                        ),
                        useBackgroundImage: useBackgroundImage,
                        backgroundOpacity: themeProvider.backgroundOpacity,
                        backgroundBlur: themeProvider.backgroundBlur,
                        backgroundImage: tabBarBackgroundImage,
                      ),
                    ),
                ];
              },
              body: _hasSearched
                  ? _buildSearchResults()
                  : _searchController.text.trim().isNotEmpty
                  ? _buildSuggestions()
                  : _buildEmptyState(),
            ),
      ),
    );
  }

  Widget _buildEmptyState() {
    // 未输入关键词：热搜榜单卡 + 搜索历史 + 音乐探索（从发现页迁移的内容模块）。
    // 热搜数据在进页时后台拉一次，失败只在卡内呈现（见 HotSearchBoardCard）。
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      children: [
        if (_searchHistory.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('搜索历史', style: Theme.of(context).textTheme.titleMedium),
                TextButton(
                  onPressed: _clearSearchHistory,
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _searchHistory.map((history) {
                return ActionChip(
                  label: Text(history),
                  onPressed: () {
                    _searchController.text = history;
                    _performSearch(history);
                  },
                );
              }).toList(),
            ),
          ),
        ],
        HotSearchBoardCard(
          onKeywordTap: (keyword) {
            _searchController.text = keyword;
            _performSearch(keyword);
          },
        ),
        // 热门搜索与下方「音乐探索」之间加大间距，形成明显分段（见改版计划补充三）。
        const Gap(AppSpacing.lg),
        // 音乐探索：主题歌单 / 场景音乐 / 热门歌单 / 排行榜 / 新碟上架，
        // 复用 KugouProvider 已有数据与缓存（内部数据为空时自动补拉）。
        const MusicExploreSections(),
      ],
    );
  }

  Widget _buildSearchResults() {
    return TabBarView(
      controller: _tabController,
      physics: const TabSnapPhysics(),
      children: [
        TvScrollRegion(
          memoryKey: 'tv/search-song',
          horizontalEdge: DpadEdgeBehavior.leave,
          child: _buildSongResults(),
        ),
        TvScrollRegion(
          memoryKey: 'tv/search-album',
          horizontalEdge: DpadEdgeBehavior.leave,
          child: _buildAlbumResults(),
        ),
        TvScrollRegion(
          memoryKey: 'tv/search-artist',
          horizontalEdge: DpadEdgeBehavior.leave,
          child: _buildArtistResults(),
        ),
        TvScrollRegion(
          memoryKey: 'tv/search-playlist',
          horizontalEdge: DpadEdgeBehavior.leave,
          child: _buildPlaylistResults(),
        ),
        // 云盘结果页（随搜索页「云盘」tab 一并下线，入口仍在我的 → 云盘）：
        // TvScrollRegion(
        //   memoryKey: 'tv/search-cloud',
        //   horizontalEdge: DpadEdgeBehavior.leave,
        //   child: _buildCloudResults(),
        // ),
        TvScrollRegion(
          memoryKey: 'tv/search-lyric',
          horizontalEdge: DpadEdgeBehavior.leave,
          child: _buildLyricResults(),
        ),
      ],
    );
  }

  Widget _buildSuggestions() {
    final colorScheme = Theme.of(context).colorScheme;
    final kugouProvider = context.watch<KugouProvider>();
    final suggestions = kugouProvider.searchSuggest;

    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return TvScrollRegion(
      memoryKey: 'tv/search-suggest',
      horizontalEdge: DpadEdgeBehavior.leave,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        itemCount: suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = suggestions[index];
          return ListTile(
            leading: Icon(
              Icons.search,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            title: Text(suggestion, maxLines: 1, overflow: TextOverflow.ellipsis),
            dense: true,
            onTap: () {
              _searchController.text = suggestion;
              FocusManager.instance.primaryFocus?.unfocus();
              _performSearch(suggestion);
            },
          );
        },
      ),
    );
  }

  Widget _buildSongResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'song');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<Song> results = [];

    if (searchResults != null && searchResults.songs.isNotEmpty) {
      results = searchResults.songs.map((e) => e.toSong()).toList();
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'song');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, index) {
                return SongListItem(
                  song: results[index],
                  showDuration: false,
                  trailingActions: SongTrailingActions.detailAndMv,
                  onTap: () {
                    context.read<PlayerProvider>().playOnlinePlaylist(
                      results,
                      index,
                    );
                  },
                  onMoreTap: () {},
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  /// 歌词搜索结果：按歌词片段搜索到的歌曲列表，每项副标题显示匹配的歌词片段。
  Widget _buildLyricResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'lyric');
      });
    }

    final results = kugouProvider.searchResults?.songs ?? const <KugouSongDetail>[];

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'lyric');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final detail = results[index];
                final snippet = detail.lyrics ?? '';
                final song = detail.toSong();
                final cs = Theme.of(context).colorScheme;
                final tt = Theme.of(context).textTheme;
                return SongListItem(
                  song: song,
                  showDuration: false,
                  trailingActions: SongTrailingActions.detailAndMv,
                  // 保留命中的歌词片段作为副标题（primary 强调）。
                  subtitleOverride: Text(
                    snippet.isNotEmpty ? snippet : song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(
                      color: snippet.isNotEmpty
                          ? cs.primary.withValues(alpha: 0.85)
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  onTap: () {
                    final songs = results.map((e) => e.toSong()).toList();
                    context.read<PlayerProvider>().playOnlinePlaylist(
                      songs,
                      index,
                    );
                  },
                  onMoreTap: () {},
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  /// 输入法还开着时，第一次点大封面卡片只收键盘、不进详情；第二次点击才导航。
  ///
  /// 为什么不让第一次点击直接进详情：这条路径走的是框架 Hero（Tab 内容栈），
  /// 飞行中的封面盒子按**起飞那一刻**的 `navigatorSize` 换算四边
  /// （`heroes.dart:1033`），而本 App 是 `windowSoftInputMode=adjustResize`：
  /// 点下去后输入法随新页面上场收起、窗口高度当场复原，差的那一截键盘高会整段
  /// 加在飞行封面上（真机实测 140 的封面被撑成 436）。先把窗口尺寸稳定下来，
  /// 转场期间高度不再变化，动画才干净。搜索词不会被清掉（只是 unfocus）。
  bool _dismissImeBeforeNavigate() {
    // 两个来源都要判：MediaQuery 的 viewInsets 会被显示缩放换算（ui_density），
    // 平台那份是原始值；真机出现过一方为 0 而键盘仍弹着的情况。
    final double mqInsets = MediaQuery.viewInsetsOf(context).bottom;
    final double platformInsets =
        WidgetsBinding.instance.platformDispatcher.implicitView?.viewInsets.bottom ?? 0;
    if (mqInsets <= 0 && platformInsets <= 0) return false;
    FocusManager.instance.primaryFocus?.unfocus();
    return true;
  }

  void _showAlbumDetail(Album album) {
    AdaptiveNav.openDetail(
      context,
    (_) => AlbumDetailPage(album: album));
  }

  Widget _buildAlbumResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.albums.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.albums.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'album');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<Album> results = [];

    if (searchResults != null && searchResults.albums.isNotEmpty) {
      results = searchResults.albums.map((e) => e.toAlbum()).toList();
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }

    // Hero tag 唯一性防护：专辑 tab 同样分页加载，重叠页会出现重复专辑；同 tag
    // 在同一路由子树出现两次会在转场收集阶段抛 FlutterError。只给每个 id 首次
    // 出现的卡片挂 Hero，空 id 不挂（否则多张空 id 卡互撞）。
    final firstIndexById = <String, int>{};
    for (var i = 0; i < results.length; i++) {
      final id = results[i].id;
      if (id.isEmpty) continue;
      firstIndexById.putIfAbsent(id, () => i);
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'album');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 用 PinchableGridView 替代固定 2 列的 GridView，
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式按局部可用宽度自动调整列数
            child: PinchableGridView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              // 原 childAspectRatio 0.75、spacing 12 保持不变
              childAspectRatio: 0.75,
              spacing: 12,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final album = results[index];
                final cleanName = album.name.replaceAll(RegExp(r'<[^>]*>'), '');
                final cleanArtist = album.artist.replaceAll(
                  RegExp(r'<[^>]*>'),
                  '',
                );
                return _SearchAlbumCard(
                  name: cleanName,
                  artist: cleanArtist,
                  artworkUri: album.artworkUri,
                  icon: Icons.album,
                  heroTag: firstIndexById[album.id] == index
                      ? albumCoverHeroTag(album.id)
                      : null,
                  onTap: () {
                    if (_dismissImeBeforeNavigate()) return;
                    _showAlbumDetail(album);
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  Widget _buildArtistResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.artists.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.artists.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'artist');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<KugouArtistBrief> results = [];

    if (searchResults != null && searchResults.artists.isNotEmpty) {
      results = searchResults.artists;
    }

    print('[_buildArtistResults] results.count=${results.length}');
    for (final a in results) {
      print(
        '[_buildArtistResults] artist: id="${a.id}", name="${a.name}", avatar="${a.avatarUrl}"',
      );
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'artist');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 歌手是卡片类结果：手机竖屏（<600）单列，变宽后铺成多列横向卡片（计划 ⑥）。
            child: AdaptiveContentGrid(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              targetExtent: 380,
              childAspectRatio: 3.5,
              spacing: AppSpacing.sm,
              minColumns: 2,
              maxColumns: 3,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final artist = results[index];
                return ListTile(
                  leading: _ArtistAvatar(
                    artistId: artist.id,
                    avatarUrl: artist.avatarUrl,
                    size: 48,
                  ),
                  title: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('歌手'),
                  onTap: () {
                    AdaptiveNav.openDetail(context,
                      (_) => ArtistDetailPage(
                          artistId: artist.id,
                          artistName: artist.name,
                          avatarUrl: artist.avatarUrl,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.playlists.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.playlists.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'special');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<KugouPlaylistBrief> results = [];

    if (searchResults != null && searchResults.playlists.isNotEmpty) {
      results = searchResults.playlists;
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }

    // Hero tag 唯一性防护：同一子树重复 tag 在转场收集阶段抛 FlutterError
    // （heroes.dart _allHeroesFor 的 assert）。搜索结果可能因分页重叠出现
    // 重复歌单，只给每个 id 的首次出现挂 Hero。
    final firstIndexById = <String, int>{};
    for (var i = 0; i < results.length; i++) {
      firstIndexById.putIfAbsent(
        results[i].globalCollectionId ?? results[i].id,
        () => i,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'special');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 用 PinchableGridView 替代固定 2 列的 GridView，
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式按局部可用宽度自动调整列数
            child: PinchableGridView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              // 原 childAspectRatio 0.75、spacing 12 保持不变
              childAspectRatio: 0.75,
              spacing: 12,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final pl = results[index];
                final cleanName = pl.name.replaceAll(RegExp(r'<[^>]*>'), '');
                final plId = pl.globalCollectionId ?? pl.id;
                return _SearchAlbumCard(
                  name: cleanName,
                  artist: pl.songCount > 0 ? '${pl.songCount} 首歌曲' : '',
                  artworkUri: pl.coverUrl,
                  icon: Icons.queue_music,
                  heroTag: firstIndexById[plId] == index
                      ? playlistCoverHeroTag(plId)
                      : null,
                  onTap: () {
                    // 与专辑 tab 同一口径：输入法没收起时第一下只收键盘（见
                    // [_dismissImeBeforeNavigate]）。
                    if (_dismissImeBeforeNavigate()) return;
                    AdaptiveNav.openDetail(context,
                      (_) => PlaylistPage(playlist: pl.toPlaylist()),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  /// 云盘歌曲加载上限，与 [CloudMusicPage] 对齐。
  static const int _maxCloudSongs = 6000;

  /// 加载云盘歌曲列表（仅进入云盘 tab 时按需调用一次）。
  /// 分页拉取最多 [_maxCloudSongs] 首，加载完成后由 [_query] 在 [_filteredCloudSongs] 中过滤。
  Future<void> _loadCloudSongsForSearch() async {
    if (_cloudLoading) return;
    setState(() {
      _cloudLoading = true;
      _cloudError = null;
    });
    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        setState(() {
          _cloudLoading = false;
          _cloudError = '请先登录';
        });
        return;
      }
      const int pageSize = 100;
      const int maxPages = (_maxCloudSongs + pageSize - 1) ~/ pageSize;
      final songs = <Song>[];
      for (int page = 1; page <= maxPages; page++) {
        final result = await api.getUserCloud(page: page, pagesize: pageSize);
        if (!mounted) return;
        if (result == null) {
          if (page == 1) {
            setState(() {
              _cloudLoading = false;
              _cloudError = '加载失败，请稍后重试';
            });
            return;
          }
          break;
        }
        final data = result['data'];
        List<dynamic>? list;
        if (data is List) {
          list = data;
        } else if (data is Map<String, dynamic>) {
          list = data['info'] as List<dynamic>?;
          list ??= data['list'] as List<dynamic>?;
        }
        if (list == null || list.isEmpty) break;
        for (final e in list) {
          if (e is Map<String, dynamic>) {
            final song = mapCloudApiItemToSong(e);
            if (song.id.isNotEmpty) songs.add(song);
          }
        }
        if (songs.length >= _maxCloudSongs) {
          songs.removeRange(_maxCloudSongs, songs.length);
          break;
        }
        if (list.length < pageSize) break;
      }
      setState(() {
        _cloudSongs = songs;
        _cloudLoaded = true;
        _cloudLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _cloudLoading = false;
          _cloudError = '加载失败：$e';
        });
      }
    }
  }

  /// 根据 [_query] 内存过滤已加载的云盘歌曲（title/artist 子串、不区分大小写）。
  List<Song> get _filteredCloudSongs {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _cloudSongs;
    return _cloudSongs.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q);
    }).toList();
  }

  /// 云盘结果页。**当前未被挂载**（搜索页「云盘」tab 已下线，2026-10-10），
  /// 连同 [_loadCloudSongsForSearch] / [_filteredCloudSongs] 整套保留备用，
  /// 避免将来要恢复时重写；云盘入口仍在「我的 → 云盘」。
  // ignore: unused_element
  Widget _buildCloudResults() {
    if (_cloudLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_cloudError != null) {
      return _buildErrorState(_cloudError!, _loadCloudSongsForSearch);
    }
    if (!_cloudLoaded) {
      // 极端情况：未搜索过就跳到云盘 tab —— 主动触发加载
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_cloudLoaded && !_cloudLoading) {
          _loadCloudSongsForSearch();
        }
      });
      return const Center(child: M3ELoadingIndicator());
    }
    final results = _filteredCloudSongs;
    if (results.isEmpty) {
      return _buildNoResult();
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      itemCount: results.length,
      itemBuilder: (context, index) {
        return SongListItem(
          song: results[index],
          onTap: () {
            // 必须用 playCloudPlaylist 走 /user/cloud/url 解析
            context.read<PlayerProvider>().playCloudPlaylist(results, index);
          },
          onMoreTap: () {},
        );
      },
    );
  }

  Widget _buildErrorState(String error, VoidCallback onRetry) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '搜索失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResult() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const Gap(AppSpacing.md),
          Text(
            '未找到相关结果',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果列表中的歌手头像：搜索接口通常不返回头像 URL，
/// 这里用 getArtistDetail 接口异步补全。
class _ArtistAvatar extends StatefulWidget {
  final String artistId;
  final String? avatarUrl;
  final double size;

  const _ArtistAvatar({required this.artistId, this.avatarUrl, this.size = 48});

  @override
  State<_ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<_ArtistAvatar> {
  String? _resolvedUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty) {
      // 搜索接口已经带了头像，直接用
      _resolvedUrl = _fixUrl(widget.avatarUrl);
      _loading = false;
    } else {
      _resolveAvatar();
    }
  }

  Future<void> _resolveAvatar() async {
    if (widget.artistId.isEmpty) {
      print('[_ArtistAvatar] artistId 为空，跳过');
      if (mounted) setState(() => _loading = false);
      return;
    }
    print('[_ArtistAvatar] 开始获取头像, artistId=${widget.artistId}');
    try {
      final detail = await KugouApiClient().getArtistDetail(widget.artistId);
      if (!mounted) return;
      final url = _fixUrl(detail?.avatarUrl);
      print('[_ArtistAvatar] 获取到头像 URL: $url');
      setState(() {
        _resolvedUrl = url;
        _loading = false;
      });
    } catch (e) {
      print('[_ArtistAvatar] 获取头像失败: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  static String? _fixUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = widget.size;

    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person,
        color: colorScheme.onSurfaceVariant,
        size: size * 0.5,
      ),
    );

    if (_loading) {
      return SizedBox(width: size, height: size, child: placeholder());
    }

    final url = _resolvedUrl;
    if (url == null) return placeholder();

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: 144,
        memCacheHeight: 144,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      ),
    );
  }
}

class _SearchAlbumCard extends StatelessWidget {
  final String name;
  final String artist;
  final String? artworkUri;
  final IconData icon;
  final VoidCallback? onTap;

  /// 非空时封面参与封面连贯过渡；歌单 tab 用 playlistCoverHeroTag、
  /// 专辑 tab 用 albumCoverHeroTag（两个命名空间互斥，见各自注释）。
  final String? heroTag;

  const _SearchAlbumCard({
    required this.name,
    required this.artist,
    this.artworkUri,
    this.icon = Icons.album,
    this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final card = ClipRRect(
      borderRadius: AppRadius.mdAll,
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _coverImage(colorScheme),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, AppSpacing.sm, 10, AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (artist.isNotEmpty) ...[
                      const Gap(AppSpacing.xxs),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
    );

    // tv: 专辑/歌单卡片单停点（OK = 原 onTap）。
    return TvCardFocus(
      onSelect: onTap,
      debugLabel: 'search-album-card',
      child: card,
    );
  }

  Widget _coverImage(ColorScheme colorScheme) {
    final Widget image = artworkUri != null
        ? CachedNetworkImage(
            imageUrl: artworkUri!,
            memCacheWidth: 540,
            memCacheHeight: 540,
            fit: BoxFit.cover,
            width: double.infinity,
            placeholder: (_, _) => _buildPlaceholder(colorScheme),
            errorWidget: (_, _, _) => _buildPlaceholder(colorScheme),
          )
        : _buildPlaceholder(colorScheme);
    if (heroTag == null) return image;
    // 卡片外层 ClipRRect(mdAll) 圆整卡四角，封面区只占卡片上部——可见圆角
    // 仅上两角。hero 圆角与之对齐，飞行起点才与静止封面逐像素重合。
    return PlaylistCoverHero(
      tag: heroTag!,
      radius: const BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
      child: image,
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  /// 是否启用壁纸背景（与顶部 SliverAppBar 的 flexibleSpace 联动）。
  final bool useBackgroundImage;
  final double backgroundOpacity;
  final double backgroundBlur;
  /// 预计算的背景图 [ImageProvider]（由 SearchPage.build 传入，
  /// 与 SliverAppBar flexibleSpace 共享 ImageCache 同 key 解码结果）。
  /// 不在 delegate.build 内 watch ThemeProvider，避免污染 sliver 链。
  final ImageProvider? backgroundImage;

  _TabBarDelegate({
    required this.tabBar,
    required this.useBackgroundImage,
    required this.backgroundOpacity,
    required this.backgroundBlur,
    required this.backgroundImage,
  });

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar ||
        useBackgroundImage != oldDelegate.useBackgroundImage ||
        backgroundOpacity != oldDelegate.backgroundOpacity ||
        backgroundBlur != oldDelegate.backgroundBlur ||
        backgroundImage != oldDelegate.backgroundImage;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!useBackgroundImage || backgroundImage == null) {
      return Container(color: colorScheme.surface, child: tabBar);
    }
    // 有壁纸：与顶部 SliverAppBar flexibleSpace 同结构（surface 打底 +
    // 模糊 + 透明度 + 全屏 cover 背景图 topCenter 裁剪），tab 栏与
    // 搜索框背景视觉连续。ClipRect 把 OverflowBox 溢出内容裁到本 sliver
    // 区域，避免盖住下方 TabBarView 结果区。
    // 外面再套 RepaintBoundary：全屏高斯模糊随滚动逐帧移动，独立绘制层把模糊
    // 重算限制在本层内（与顶部 flexibleSpace 同一处理）。
    final size = MediaQuery.sizeOf(context);
    return RepaintBoundary(child: ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: colorScheme.surface),
                    Opacity(
                      opacity: backgroundOpacity,
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: tvBlurSigma(backgroundBlur),
                          sigmaY: tvBlurSigma(backgroundBlur),
                        ),
                        child: Image(
                          image: backgroundImage!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          tabBar,
        ],
      ),
    ));
  }
}
