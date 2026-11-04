import 'dart:async';

import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/tab_snap_physics.dart';
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
import 'search_section_header.dart';

/// 搜索页签单一来源:(接口 type, 展示文案)。
/// TabBar 标签、TabController 长度与 [_SearchPageState._onTabChanged]
/// 的类型切换都从这里取值,新增/删减页签只改这一处。
/// 「云盘」页签已于 2026-10-10 下线(入口在「我的 → 云盘」),恢复时在此追加。
const List<(String, String)> kSearchTabs = [
  ('song', '歌曲'),
  ('album', '专辑'),
  ('artist', '歌手'),
  ('special', '歌单'),
  ('lyric', '歌词'),
];

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
  String _currentSearchType = 'song';

  /// 搜索建议防抖:onChanged 里 250ms 内的连续输入只发最后一次建议请求。
  Timer? _suggestDebounce;

  /// 搜索框焦点节点:「换个关键词」按钮用它把焦点和键盘交还给搜索框。
  final FocusNode _searchFocusNode = FocusNode();

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
    // 页签数必须与 [kSearchTabs] 长度一致,否则 TabController 索引与 children 错位。
    _tabController = TabController(length: kSearchTabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadSearchHistory();
    // 热搜榜单:进页后台拉一次;失败不自动重试(卡内有「重试」),
    // 状态隔离在 KugouProvider.hotSearch,不影响结果区 loading/error。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<KugouProvider>().loadHotSearch();
    });
    // 桌面工具栏搜索框提交:预填查询并在首帧后立即执行搜索。
    // 这里同步把 _query 预置为 q,首帧三态派生即为「结果态」,
    // 避免首帧闪一下建议态(postFrame 里的 _performSearch 随后落地)。
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _searchController.text = q;
      _query = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performSearch(q);
      });
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _searchFocusNode.dispose();
    _tabController.removeListener(_onTabChanged);
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    // 类型与 TabBar 标签同源于 [kSearchTabs](顺序必须一致)。
    final newType = kSearchTabs[_tabController.index].$1;
    if (newType != _currentSearchType && _query.isNotEmpty) {
      _currentSearchType = newType;
      // 云盘分支随「云盘」页签一并下线(2026-10-10):云盘是本地过滤,
      // 未加载过才触发懒加载。恢复页签时连同 TabBar/TabBarView 一起解开。
      // if (newType == 'cloud') {
      //   if (!_cloudLoaded && !_cloudLoading) {
      //     _loadCloudSongsForSearch();
      //   }
      //   return;
      // }
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
    showToast('已清空搜索历史');
  }

  /// 输入框 × 按钮:清空输入,回空态(历史+热搜)。三态派生见 build。
  void _clearSearchInput() {
    _suggestDebounce?.cancel();
    _searchController.clear();
    setState(() {});
  }

  /// 输入回调:刷新清除按钮可见性;非空输入防抖 250ms 拉搜索建议。
  void _onSearchInputChanged(String value) {
    setState(() {});
    _suggestDebounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) return;
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) context.read<KugouProvider>().getSearchSuggest(q);
    });
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    // 统一收键盘:键盘搜索键 / 历史 / 热搜 / 建议四条入口都汇到这里。
    FocusManager.instance.primaryFocus?.unfocus();
    _suggestDebounce?.cancel();
    // 输入框同步为修剪后的词,保证 text.trim() 与 _query 相等(结果态判定)。
    if (_searchController.text != q) {
      _searchController.text = q;
    }
    setState(() {
      _query = q;
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
    // 三态派生(单一来源,不再有独立的 _hasSearched 标志):
    //   输入为空 → 空态(历史+热搜);输入词 ≠ 已提交 _query → 建议态;
    //   相等 → 结果态。_query 只在 _performSearch / initState 预填时写入。
    final query = _searchController.text.trim();
    final bool inResultState = query.isNotEmpty && query == _query;
    // 类型切换后台加载:provider 正忙、当前处于结果态、且当前类型还没有
    // 自己的缓存数据(首搜时整仓无数据,不满足,走各 tab 自己的整屏 loading)。
    final kugouProvider = context.watch<KugouProvider>();
    final bool typeSwitchLoading = kugouProvider.isLoading &&
        inResultState &&
        !kugouProvider.hasSearchResultForType(_query, _currentSearchType);
    return Scaffold(
      body: SecondaryMiniPlayerHost(
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverAppBar(
                pinned: true,
                // 壁纸由页面底层统一绘制,顶栏不再重复裁剪一份图片。
                backgroundColor: useBackgroundImage
                    ? Colors.transparent
                    : colorScheme.surface,
                surfaceTintColor: Colors.transparent,
                // M3 SearchBar:高 48、全圆角、surfaceContainerHighest 填充。
                title: SearchBar(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  constraints: const BoxConstraints(
                    minHeight: 48,
                    maxHeight: 48,
                  ),
                  elevation: const WidgetStatePropertyAll(0),
                  backgroundColor: WidgetStatePropertyAll(
                    colorScheme.surfaceContainerHighest,
                  ),
                  shape: const WidgetStatePropertyAll(StadiumBorder()),
                  hintText: '搜索歌曲、歌手、专辑',
                  hintStyle: WidgetStatePropertyAll(
                    Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  leading: Icon(
                    Icons.search,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        onPressed: _clearSearchInput,
                      ),
                  ],
                  contextMenuBuilder: buildAppTextContextMenu,
                  textInputAction: TextInputAction.search,
                  onChanged: _onSearchInputChanged,
                  onSubmitted: _performSearch,
                ),
              ),
              if (inResultState)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    // tv: 每个 Tab 一个单停点(OK = 切到该页),非 TV 构建
                    // TvCardFocus 原样透传。这里不包 TvScrollRegion:
                    // _TabBarDelegate 的字段类型是 TabBar,且 minExtent 要读
                    // 它的 preferredSize;5 个页签在 TV 宽度下不滚动,
                    // 左右换页签由同 scope 内的几何候选即可胜任。
                    tabBar: TabBar(
                      controller: _tabController,
                      dividerColor: Colors.transparent,
                      tabs: [
                        for (final (i, (_, label)) in kSearchTabs.indexed)
                          TvCardFocus(
                            onSelect: () => _tabController.animateTo(i),
                            debugLabel: 'search-tab-$label',
                            child: Tab(text: label),
                          ),
                      ],
                    ),
                    useBackgroundImage: useBackgroundImage,
                  ),
                ),
            ];
          },
          body: Column(
            children: [
              // 类型切换的加载反馈:TabBar 下的细进度条(仅切换且无缓存时),
              // 首搜仍由各 tab 自己的整屏 loading 负责。
              if (typeSwitchLoading)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: inResultState
                    ? _buildSearchResults()
                    : query.isNotEmpty
                    ? _buildSuggestions(query)
                    : _buildEmptyState(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    // 未输入关键词:热搜榜单卡 + 搜索历史 + 音乐探索(从发现页迁移的内容模块)。
    // 热搜数据在进页时后台拉一次,失败只在卡内呈现(见 HotSearchBoardCard)。
    return TvScrollRegion(
      memoryKey: 'tv/search-empty',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          ..._buildHistoryAndHotSearch(),
          // 热门搜索与下方「音乐探索」之间加大间距,形成明显分段(见改版计划补充三)。
          const Gap(AppSpacing.lg),
          // 音乐探索:主题歌单 / 场景音乐 / 热门歌单 / 排行榜 / 新碟上架,
          // 复用 KugouProvider 已有数据与缓存(内部数据为空时自动补拉)。
          const MusicExploreSections(),
        ],
      ),
    );
  }

  /// 「搜索历史 + 热搜榜单」段:空态与建议态回落共用。
  List<Widget> _buildHistoryAndHotSearch() {
    return [
      if (_searchHistory.isNotEmpty) ...[
        // 三段(历史/热搜/探索)统一段落头:同字号、同内边距、同规格动作按钮。
        SearchSectionHeader(
          title: '搜索历史',
          actions: [
            // tv: 清空按钮单停点;同形状仅换 error 色提示破坏性。
            TvCardFocus(
              onSelect: _clearSearchHistory,
              debugLabel: 'search-clear-history',
              child: SearchSectionAction(
                label: '清空',
                onTap: _clearSearchHistory,
                destructive: true,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final history in _searchHistory)
                // tv: 历史词条单停点(OK = 以该词发起搜索)。
                TvCardFocus(
                  onSelect: () => _searchFromKeyword(history),
                  debugLabel: 'search-history-$history',
                  child: ActionChip(
                    label: Text(history),
                    onPressed: () => _searchFromKeyword(history),
                  ),
                ),
            ],
          ),
        ),
      ],
      HotSearchBoardCard(
        onKeywordTap: _searchFromKeyword,
      ),
    ];
  }

  /// 点历史 / 热搜词发起搜索:回填输入框并走统一的 _performSearch。
  void _searchFromKeyword(String keyword) {
    _searchController.text = keyword;
    _performSearch(keyword);
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

  Widget _buildSuggestions(String query) {
    final colorScheme = Theme.of(context).colorScheme;
    final kugouProvider = context.watch<KugouProvider>();
    final suggestions = kugouProvider.searchSuggest;

    if (suggestions.isEmpty) {
      // 建议未返回/为空时回落空态内容(历史+热搜),不留白屏。
      return TvScrollRegion(
        memoryKey: 'tv/search-suggest',
        horizontalEdge: DpadEdgeBehavior.leave,
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          children: _buildHistoryAndHotSearch(),
        ),
      );
    }

    return TvScrollRegion(
      memoryKey: 'tv/search-suggest',
      horizontalEdge: DpadEdgeBehavior.leave,
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: [
          // 固定首项:直接以当前输入词发起搜索(与下方补全项区分,用外发箭头)。
          TvCardFocus(
            onSelect: () => _searchFromKeyword(query),
            debugLabel: 'search-suggest-exact',
            child: ListTile(
              leading: Icon(
                Icons.arrow_outward,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              title: Text(
                '搜索 "$query"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
              onTap: () => _searchFromKeyword(query),
            ),
          ),
          for (final suggestion in suggestions)
            // tv: 建议行单停点(OK = 以该词发起搜索)。
            TvCardFocus(
              onSelect: () => _searchFromKeyword(suggestion),
              debugLabel: 'search-suggest',
              child: ListTile(
                leading: Icon(
                  Icons.search,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  suggestion,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                dense: true,
                onTap: () => _searchFromKeyword(suggestion),
              ),
            ),
        ],
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
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
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
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
          // loadMore 失败(已有数据时的 error):底部给出可重试入口。
          if (kugouProvider.error != null) _buildLoadMoreRetry('song'),
        ],
      ),
    );
  }

  /// 加载更多失败的兜底行:已有数据但翻页请求出错时,列表底部提供重试。
  Widget _buildLoadMoreRetry(String type) {
    final colorScheme = Theme.of(context).colorScheme;
    void retry() {
      final kugouProvider = context.read<KugouProvider>();
      kugouProvider.clearError();
      kugouProvider.loadMoreSearchResults(type: type);
    }

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      // tv: 重试行单停点。
      child: TvCardFocus(
        onSelect: retry,
        debugLabel: 'search-loadmore-retry',
        child: TextButton(
          onPressed: retry,
          child: Text(
            '加载失败，点击重试',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
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
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
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
                  // 命中的歌词片段作副标题;命中与否都用 bodySmall + onSurfaceVariant,
                  // 不再用 primary 强调(视觉纪律:列表副标题统一弱化)。
                  subtitleOverride: Text(
                    snippet.isNotEmpty ? snippet : song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  onTap: () {
                    final songs = results.map((e) => e.toSong()).toList();
                    context.read<PlayerProvider>().playOnlinePlaylist(
                      songs,
                      index,
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
          if (kugouProvider.error != null) _buildLoadMoreRetry('lyric'),
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
            // 用 PinchableGridView 替代固定 2 列的 GridView,
            // Pad 模式下可双指捏合动态调整列数,非 Pad 模式按局部可用宽度自动调整列数
            child: PinchableGridView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              childAspectRatio: 0.8,
              spacing: AppSpacing.md,
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
            // 歌手是卡片型结果:手机竖屏(<600)单列,变宽后铺成多列横向卡片(计划 ⑥)。
            child: AdaptiveContentGrid(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
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
                  onTap: () {
                    AdaptiveNav.openDetail(
                      context,
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
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              childAspectRatio: 0.8,
              spacing: AppSpacing.md,
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
          if (kugouProvider.error != null) _buildLoadMoreRetry('special'),
        ],
      ),
    );
  }

  /// 云盘歌曲加载上限,与 [CloudMusicPage] 对齐。
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
              color: colorScheme.outline,
            ),
            const Gap(AppSpacing.md),
            Text(
              '搜索失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface,
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
            color: colorScheme.outline,
          ),
          const Gap(AppSpacing.md),
          Text(
            '未找到相关结果',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(AppSpacing.lg),
          // 无结果时的下一步引导:清空输入并聚焦搜索框,回到空态重新输入。
          FilledButton.tonal(
            onPressed: () {
              _suggestDebounce?.cancel();
              _searchController.clear();
              setState(() {});
              _searchFocusNode.requestFocus();
            },
            child: const Text('换个关键词'),
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
  /// 已处理过头像解析的 artistId(成功/失败都记):列表滚动会反复重建同一
  /// 歌手行,进程级去重,失败不重试、成功不重复打详情接口。
  static final Set<String> _resolvedAvatarIds = <String>{};

  String? _resolvedUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty) {
      // 搜索接口已经带了头像,直接用
      _resolvedUrl = _fixUrl(widget.avatarUrl);
      _loading = false;
    } else {
      _resolveAvatar();
    }
  }

  Future<void> _resolveAvatar() async {
    final id = widget.artistId;
    if (id.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // 并发/重建去重:add 失败说明该 id 已处理过(含失败),不再发请求。
    if (!_resolvedAvatarIds.add(id)) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final detail = await KugouApiClient().getArtistDetail(id);
      if (!mounted) return;
      final url = _fixUrl(detail?.avatarUrl);
      setState(() {
        _resolvedUrl = url;
        _loading = false;
      });
    } catch (_) {
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
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
  /// 启用壁纸时让页面底层背景直接透出。
  final bool useBackgroundImage;

  _TabBarDelegate({
    required this.tabBar,
    required this.useBackgroundImage,
  });

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar ||
        useBackgroundImage != oldDelegate.useBackgroundImage;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!useBackgroundImage) {
      return Container(color: colorScheme.surface, child: tabBar);
    }
    return tabBar;
  }
}
