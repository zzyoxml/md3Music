import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/build_flags.dart';
import '../../core/layout/adaptive_navigator.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/blacklist_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../player/mv_player_page.dart';
import '../player/secondary_mini_player.dart';
import 'artist_media_grid.dart';
import 'artist_album_list_builder.dart';
import 'artist_photo_banner.dart';
import 'artist_photo_header.dart';
import 'artist_scroll_gate.dart';
import 'artist_song_list_builder.dart';

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

/// 歌手页内容 Tab：歌曲（默认）/ 专辑 / MV。
enum _ArtistTab { songs, albums, mv }

// 与 MD 播放器上一曲/下一曲（MD3ETransportRow）同色取色；禁用态 alpha 沿用
// m3e_core 按钮默认口径（背景 0.12 / 前景 0.38）。
WidgetStateProperty<Color?> _photoButtonBackground(ColorScheme cs) =>
    WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled)
            ? cs.primaryContainer.withValues(alpha: 0.12)
            : cs.primaryContainer);

WidgetStateProperty<Color?> _photoButtonForeground(ColorScheme cs) =>
    WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled)
            ? cs.onPrimaryContainer.withValues(alpha: 0.38)
            : cs.onPrimaryContainer);

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  static const _prefArtistSongSortKey = 'pref_artist_song_sort';
  String _artistSongSort = 'hot';
  int _fetchToken = 0;

  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;
  bool _isFollowing = false;
  bool _isFollowLoading = false;
  /// 「屏蔽歌手」切换进行中（防重复提交；ensureFullyLoaded + 增删两段）。
  bool _isBlacklistToggling = false;
  String? _description;

  /// 写真 banner 取图用的歌曲 hash（Song.id 即酷狗 hash）；
  /// 首次拿到非空歌曲列表后设置，写真拉取失败/无图时 banner 自行回落空容器。
  String? _photoHash;

  /// [_photoHash] 是否取自「本歌手独唱曲」。false 表示回落档（可能是合作曲，
  /// 写真归属只能靠 banner 的过滤兜底），后续换排序拿到独唱曲时允许改善式替换。
  bool _photoHashIsSolo = false;

  /// 歌手头像 URL（/artist/detail 补全）：无写真时作为 banner 兜底图。
  String? _resolvedAvatarUrl;

  /// 滚动监听：用于 SliverAppBar pinned 后 fade-in 显示歌手名
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  /// header 高度缓存：build 时写入，供滚动闸门换算淡入窗口。
  double _bannerH = 0;
  final ArtistScrollGate _scrollGate = ArtistScrollGate();

  // 歌曲内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// tv: 写真轮播的翻页入口。banner 自身的 `Focus` 已排除出 dpad 遍历
  /// （全幅矩形会抢走三按钮的落点并困死焦点），左右翻页改由按钮行驱动，
  /// 详见 [ArtistPhotoBanner.flipKey]。
  final GlobalKey<ArtistPhotoBannerState> _photoFlipKey =
      GlobalKey<ArtistPhotoBannerState>();

  // 排序
  ArtistSongSortField _sortBy = ArtistSongSortField.original;
  bool _sortAscending = false;

  // 专辑 / MV Tab（懒加载：首次切入才拉第一页，之后复用已拉数据）
  static const _mediaPageSize = 30;
  static const _prefArtistAlbumSortKey = 'pref_artist_album_sort';
  _ArtistTab _tab = _ArtistTab.songs;

  /// /artist/detail 返回的专辑总数，只用于 Tab 计数与分页收敛
  int _albumCount = 0;

  List<Album> _albums = [];

  /// 服务端排序（Rust artist.rs：hot→3、其他→1），持久化在 [_prefArtistAlbumSortKey]
  String _albumSort = 'hot';

  /// 客户端排序字段与方向：original 即沿用接口顺序（与歌曲列表同一套语义）
  ArtistAlbumSortField _albumSortBy = ArtistAlbumSortField.original;
  bool _albumSortAscending = false;
  int _albumsPage = 1;
  bool _albumsHasMore = true;
  bool _albumsLoading = false;
  bool _albumsLoadingMore = false;
  bool _albumsLoaded = false;
  int _albumsToken = 0;

  List<KugouMvBrief> _mvs = [];
  int _mvTotal = 0;
  int _mvPage = 1;
  bool _mvHasMore = true;
  bool _mvLoading = false;
  bool _mvLoadingMore = false;
  bool _mvLoaded = false;
  int _mvToken = 0;

  /// MV 分类：与 Rust artist.rs 的 tag_idx 映射口径一一对应
  static const _mvTags = ['all', 'official', 'live', 'fan', 'artist'];
  static const _mvTagLabels = ['全部', '官方', '现场', '粉丝', '艺人'];
  String _mvTag = 'all';

  // 专辑展示列表缓存：本页的滚动闸门会持续 setState，不缓存就是每帧
  // 重排一遍（O(n log n)/帧），与 _displaySongs 同一约定。
  List<Album>? _cachedDisplayAlbums;
  String? _lastAlbumQuery;
  ArtistAlbumSortField? _lastAlbumSortBy;
  bool? _lastAlbumSortAscending;
  int? _lastAlbumSourceLength;

  /// 专辑 Tab 的展示列表：搜索沿用歌曲的 `_searchQuery` 做客户端过滤
  /// （零网络请求），排序走 [_albumSortBy]（original 即接口顺序）。
  List<Album> get _displayAlbums {
    if (_cachedDisplayAlbums != null &&
        _lastAlbumQuery == _searchQuery &&
        _lastAlbumSortBy == _albumSortBy &&
        _lastAlbumSortAscending == _albumSortAscending &&
        _lastAlbumSourceLength == _albums.length) {
      return _cachedDisplayAlbums!;
    }
    _cachedDisplayAlbums = buildArtistDisplayAlbums(
      source: _albums,
      field: _albumSortBy,
      ascending: _albumSortAscending,
      query: _searchQuery,
    );
    _lastAlbumQuery = _searchQuery;
    _lastAlbumSortBy = _albumSortBy;
    _lastAlbumSortAscending = _albumSortAscending;
    _lastAlbumSourceLength = _albums.length;
    return _cachedDisplayAlbums!;
  }

  void _invalidateDisplayAlbums() {
    _cachedDisplayAlbums = null;
  }

  /// 专辑排序面板的高亮项：客户端字段生效时返回 'title'，否则返回接口排序
  String get _currentAlbumSortOption {
    if (_albumSortBy == ArtistAlbumSortField.title) return 'title';
    return _albumSort;
  }

  /// 专辑排序：'hot'/'new' 是服务端排序（重拉第一页并持久化偏好），
  /// 'title' 是纯客户端排序。再点当前项不动作；方向由排序面板的分段控件切换。
  Future<void> _switchAlbumSort(String value) async {
    if (value == 'title') {
      if (_albumSortBy == ArtistAlbumSortField.original) {
        setState(() {
          _albumSortBy = ArtistAlbumSortField.title;
          _albumSortAscending = true;
          _invalidateDisplayAlbums();
        });
      }
      return;
    }

    if (value == _albumSort) {
      // 已在该接口排序上但当前展示的是客户端字段排序：收回 original 即可
      if (_albumSortBy == ArtistAlbumSortField.original) return;
      setState(() {
        _albumSortBy = ArtistAlbumSortField.original;
        _albumSortAscending = false;
        _invalidateDisplayAlbums();
      });
      return;
    }

    _albumSort = value;
    _albumSortBy = ArtistAlbumSortField.original;
    _albumSortAscending = false;
    _invalidateDisplayAlbums();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefArtistAlbumSortKey, value);
    } catch (_) {}
    _fetchAlbums();
  }

  /// Tab 文案固定三项。数目不塞进文案（会把切换器撑得忽长忽短），
  /// 另起一行按歌曲页那样显示，见 [_buildMediaCountSliver]。
  static const _tabLabels = ['歌曲', '专辑', 'MV'];

  void _switchArtistSongSort(String newSort) {
    // 再点当前接口排序项：不动作（方向改由排序面板的分段控件切换）
    if (_artistSongSort == newSort) return;
    setState(() {
      _artistSongSort = newSort;
      _sortBy = ArtistSongSortField.original;
      _sortAscending = false;
      _invalidateDisplaySongs();
    });
    _fetchArtistSongs(sort: newSort);
  }

  /// 当前排序项（供 M3E 排序托盘高亮）：字段排序时返回 'title'/'duration'，
  /// 否则返回接口排序 'hot'/'new'。
  String get _currentSortOption {
    if (_sortBy == ArtistSongSortField.title) return 'title';
    if (_sortBy == ArtistSongSortField.duration) return 'duration';
    return _artistSongSort;
  }

  // 定位正在播放歌曲
  String? _highlightSongId;

  // 缓存的过滤/排序结果
  List<Song>? _cachedDisplaySongs;
  String? _lastSearchQuery;
  ArtistSongSortField? _lastSortBy;
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
    _cachedDisplaySongs = buildArtistDisplaySongs(
      source: _songs,
      field: _sortBy,
      ascending: _sortAscending,
      query: _searchQuery,
    );
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
      // 预加载歌手黑名单（登录后）：顶栏「屏蔽歌手」按钮的状态判定
      // 需要全量歌手黑名单；常规只有一次 500/页请求，Provider 去重并发。
      if (KugouApiClient().isLoggedIn) {
        context.read<BlacklistProvider>().ensureFullyLoaded('singer');
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollGate.reset();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 滚动监听：只有顶栏淡入/标题淡入/banner 可见性三者之一真的变了才重建整页。
  /// 越过淡入窗口后（列表区正常滚动）完全停止产帧。
  void _onScroll() {
    if (!mounted) return;
    // 加载更多必须排在滚动闸门之前：越过淡入窗口后 shouldRebuild 会 return，
    // 写在它后面翻页永远触发不了。
    _maybeLoadMoreTabData();
    final offset = _scrollController.offset;
    if (!_scrollGate.shouldRebuild(offset, bannerHeight: _bannerH)) return;
    _scrollOffset = offset;
    setState(() {});
  }

  /// 触底 400px 内为当前 Tab 追加一页；并发由 loading 标志串行化。
  void _maybeLoadMoreTabData() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    if (_tab == _ArtistTab.albums) {
      if (_albumsHasMore && !_albumsLoading && !_albumsLoadingMore) {
        _fetchAlbums(loadMore: true);
      }
    } else if (_tab == _ArtistTab.mv) {
      if (_mvHasMore && !_mvLoading && !_mvLoadingMore) {
        _fetchMvs(loadMore: true);
      }
    }
  }

  /// Tab 切换：首次进入专辑 / MV 才拉第一页（懒加载），已加载过则复用缓存。
  /// 刻意不重置滚动位置：专辑/MV 的 loading 与空态各自撑一屏
  /// （见 [_buildLoadingSliver]），页面总高不会塌陷，偏移得以原地保留。
  void _onTabChanged(int index) {
    final tab = _ArtistTab.values[index];
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (tab == _ArtistTab.albums && !_albumsLoaded && !_albumsLoading) {
      _fetchAlbums();
    } else if (tab == _ArtistTab.mv && !_mvLoaded && !_mvLoading) {
      _fetchMvs();
    }
  }

  /// 切换 MV 分类：清空当页并重新拉第一页（token 自增会让旧的 in-flight 作废）。
  void _onMvTagChanged(int index) {
    final tag = _mvTags[index];
    if (tag == _mvTag) return;
    setState(() {
      _mvTag = tag;
      _mvs = [];
      _mvPage = 1;
      _mvLoaded = false;
    });
    _fetchMvs();
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

  Future<void> _fetchArtistSongs({String? sort}) async {
    final token = ++_fetchToken;

    if (sort != null) {
      _artistSongSort = sort;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefArtistSongSortKey, sort);
      } catch (_) {}
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedSort = prefs.getString(_prefArtistSongSortKey);
        if (savedSort != null && (savedSort == 'hot' || savedSort == 'new')) {
          _artistSongSort = savedSort;
        }
      } catch (_) {}
    }

    if (!mounted || token != _fetchToken) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = KugouApiClient();
      final artistId = widget.artistId;
      final artistName = widget.artistName;
      final currentSort = _artistSongSort;

      // 并行获取歌手详情和第一页歌曲
      const batchSize = 500;
      const maxPages = 100;
      final detailFuture = api.getArtistDetail(artistId);
      final firstPageFuture = api.getArtistAudios(
        artistId,
        page: 1,
        pagesize: batchSize,
        sort: currentSort,
        noCache: true,
      );

      final initial = await Future.wait([detailFuture, firstPageFuture]);
      if (!mounted || token != _fetchToken) return;

      final detail = initial[0] as KugouArtistDetail?;
      final firstPage = initial[1] as KugouArtistAudios?;

      // 获取歌手简介与头像（头像用于无写真时的 banner 兜底）
      if (detail != null) {
        if (detail.description != null &&
            detail.description!.isNotEmpty) {
          _description = detail.description;
        }
        if (detail.avatarUrl != null && detail.avatarUrl!.isNotEmpty) {
          _resolvedAvatarUrl = detail.avatarUrl;
        }
        // 专辑总数用于 Tab 计数与分页收敛
        _albumCount = detail.albumCount;
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
          if (!mounted || token != _fetchToken) return;
          final pageResult = await api.getArtistAudios(
            artistId,
            page: currentPage,
            pagesize: batchSize,
            sort: currentSort,
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
        if (!mounted || token != _fetchToken) return;
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

      if (!mounted || token != _fetchToken) return;

      setState(() {
        _songs = allSongs.map((s) {
          final song = s.toSong();
          return song.copyWith(artistId: song.artistId ?? artistId);
        }).toList();
        // 写真取图键：优先「本歌手独唱曲」。热门曲常是多歌手合作曲，上游
        // `/images/audio` 按歌曲返回该曲**全部歌手**的写真，直接用第一首 hash
        // 会让别人的照片混进本页轮播（缺陷修复）。
        // 已有值时只做「非 solo → solo」的改善式替换：hot/new 切换会让本函数重跑，
        // 无谓换键会让 banner 重新拉图、轮播跳回第 0 页。
        final photoPick = pickArtistPhotoHash(
          _songs,
          artistId: artistId,
          artistName: artistName,
        );
        if (_photoHash == null || (!_photoHashIsSolo && photoPick.isSolo)) {
          _photoHash = photoPick.hash;
          _photoHashIsSolo = photoPick.isSolo;
        }
        _isLoading = false;
        _invalidateDisplaySongs();
      });
    } catch (e) {
      if (mounted && token == _fetchToken) {
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

  /// 拉取歌手专辑（首页与加载更多共用）。
  ///
  /// token 语义：首屏/切排序自增，作废 in-flight 的旧请求；加载更多**不**自增
  /// （并发翻页会互相作废），只靠 loading 标志串行化。
  Future<void> _fetchAlbums({bool loadMore = false}) async {
    if (loadMore) {
      if (_albumsLoading || _albumsLoadingMore || !_albumsHasMore) return;
    } else {
      ++_albumsToken;
    }
    final token = _albumsToken;
    final page = loadMore ? _albumsPage + 1 : 1;

    if (!loadMore) {
      // 服务端排序取持久化偏好（顶栏的专辑排序钮写入，见 _switchAlbumSort）
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedSort = prefs.getString(_prefArtistAlbumSortKey);
        if (savedSort != null &&
            (savedSort == 'hot' || savedSort == 'new')) {
          _albumSort = savedSort;
        }
      } catch (_) {}
      if (!mounted || token != _albumsToken) return;
    }

    setState(() {
      if (loadMore) {
        _albumsLoadingMore = true;
      } else {
        _albumsLoading = true;
        // 重拉第一页期间回到整块 loading，否则旧排序的结果会闪一下
        _albumsLoaded = false;
        _albums = [];
        _albumsPage = 1;
        _albumsHasMore = true;
        _invalidateDisplayAlbums();
      }
    });

    try {
      final result = await KugouApiClient().getArtistAlbums(
        widget.artistId,
        page: page,
        pagesize: _mediaPageSize,
        sort: _albumSort,
      );
      if (!mounted || token != _albumsToken) return;
      // 上游字段口径与网格/详情页一致：统一转成 Album 再累加
      final fetched =
          result?.albums.map((brief) => brief.toAlbum()).toList(growable: false);
      setState(() {
        if (fetched != null && fetched.isNotEmpty) {
          _albums.addAll(fetched);
          _albumsPage = page;
          _invalidateDisplayAlbums();
        }
        _albumsHasMore = fetched != null &&
            fetched.length >= _mediaPageSize &&
            (_albumCount <= 0 || _albums.length < _albumCount);
        _albumsLoaded = true;
        _albumsLoading = false;
        _albumsLoadingMore = false;
      });
    } catch (_) {
      // 失败静默回落空态（对齐本仓解析失败不弹 toast 的口径）
      if (mounted && token == _albumsToken) {
        setState(() {
          _albumsHasMore = false;
          _albumsLoaded = true;
          _albumsLoading = false;
          _albumsLoadingMore = false;
        });
      }
    }
  }

  /// 拉取歌手 MV，token / 并发口径同 [_fetchAlbums]。
  Future<void> _fetchMvs({bool loadMore = false}) async {
    if (loadMore) {
      if (_mvLoading || _mvLoadingMore || !_mvHasMore) return;
    } else {
      ++_mvToken;
    }
    final token = _mvToken;
    final page = loadMore ? _mvPage + 1 : 1;

    setState(() {
      if (loadMore) {
        _mvLoadingMore = true;
      } else {
        _mvLoading = true;
        _mvs = [];
        _mvPage = 1;
        _mvTotal = 0;
        _mvHasMore = true;
      }
    });

    try {
      final result = await KugouApiClient().getArtistVideos(
        widget.artistId,
        page: page,
        pagesize: _mediaPageSize,
        tag: _mvTag,
      );
      if (!mounted || token != _mvToken) return;
      final fetched = result?.mvs;
      setState(() {
        if (fetched != null && fetched.isNotEmpty) {
          _mvs.addAll(fetched);
          _mvPage = page;
        }
        if ((result?.total ?? 0) > 0) _mvTotal = result!.total;
        _mvHasMore = fetched != null &&
            fetched.isNotEmpty &&
            (_mvTotal > 0
                ? _mvs.length < _mvTotal
                : fetched.length >= _mediaPageSize);
        _mvLoaded = true;
        _mvLoading = false;
        _mvLoadingMore = false;
      });
    } catch (_) {
      if (mounted && token == _mvToken) {
        setState(() {
          _mvHasMore = false;
          _mvLoaded = true;
          _mvLoading = false;
          _mvLoadingMore = false;
        });
      }
    }
  }

  /// 播放 MV：必须带 directVideoUrl —— MvPlayerPage 不给直链时内部链路强依赖
  /// song.albumAudioId（上游列表经常不带），缺了就直接判「无 MV」。
  Future<void> _playMv(KugouMvBrief mv) async {
    final api = KugouApiClient();
    // 无 hash 时用 videoId 兜底试一次（与场景视频页口径一致）
    final hash = mv.hash ?? mv.videoId;
    final url = await api.getVideoUrl(hash);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      showToast('该视频暂无法播放', long: true);
      return;
    }
    final song = Song(
      id: mv.videoId,
      title: mv.name,
      artist: mv.authorName ?? widget.artistName,
      album: '',
      duration: Duration.zero,
      isOnline: true,
      artworkUri: mv.coverUrl,
    );
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => MvPlayerPage(song: song, directVideoUrl: url),
      ),
    );
  }

  /// 将 http:// URL 转换为 https://（头像兜底图用）
  String? _toHttps(String? url) {
    if (url == null || !url.startsWith('http://')) return url;
    return url.replaceFirst('http://', 'https://');
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

  /// 屏蔽 / 取消屏蔽歌手（内容黑名单，singer 桶）。
  /// 状态未知时先全量拉取再判定，避免「图标未屏蔽、实际已屏蔽」时误加重复条目；
  /// 已屏蔽则移除对应条目（显示名以黑名单缓存为准）。
  Future<void> _toggleSingerBlacklist() async {
    if (_isBlacklistToggling) return;
    if (!KugouApiClient().isLoggedIn) {
      showToast('请先登录', long: true);
      return;
    }
    setState(() => _isBlacklistToggling = true);
    try {
      final blacklist = context.read<BlacklistProvider>();
      final singerId = widget.artistId;
      if (!blacklist.isFullyLoaded('singer')) {
        await blacklist.ensureFullyLoaded('singer');
      }
      if (blacklist.statusFor('singer', singerId) == BlacklistStatus.present) {
        final matches =
            blacklist.entries('singer').where((e) => e.key == singerId).toList();
        final ok = matches.isNotEmpty && await blacklist.remove(matches.first);
        if (!mounted) return;
        showToast(ok ? '已取消屏蔽歌手' : '操作失败，请稍后重试');
      } else {
        final ok = await blacklist.addSinger(
          singerId: singerId,
          name: widget.artistName,
        );
        if (!mounted) return;
        showToast(ok ? '已屏蔽歌手' : '屏蔽失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _isBlacklistToggling = false);
    }
  }

  /// ⓘ 按钮：半屏弹层展示歌手介绍（替代旧折叠介绍块）。
  void _showArtistInfoSheet() {
    final description = _description;
    if (description == null || description.isEmpty) return;
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xxl),
          children: [
            Text(
              widget.artistName,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '${_songs.length} 首歌曲 · ${_artistSongSort == "hot" ? "热门" : "最新"}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const Gap(AppSpacing.md),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「播放全部」：触屏 onPressed 与 TV 的 onSelect 共用同一份动作，
  /// 抽出来是为了不把闭包在参数列表里写两遍。
  void _playAll() {
    context.read<PlayerProvider>().playOnlinePlaylist(_displaySongs, 0);
  }

  /// tv: M3E 按钮本身不带焦点节点（m3e_core 的按钮只接管按压手势），TV 下必须
  /// 包成 [DpadFocusable] 才能被遥控选中——写真底缘的「详情/播放全部/关注」
  /// 三键此前完全无法聚焦（2026-10-04）。
  ///
  /// [action] 为 null（按钮置灰）时一并退出遍历，与触屏的禁用语义一致。
  ///
  /// tv: 焦点落在三按钮上时，左右键用来翻写真页（banner 自己的焦点节点已被
  /// 排除出遍历，收不到按键），避免 TV 上写真只能等自动轮播。
  Widget _tvFocusableButton(
    VoidCallback? action,
    Widget child, {
    String? debugLabel,
  }) {
    if (!kTvBuild) return child;
    return DpadFocusable(
      debugLabel: debugLabel,
      onSelect: action,
      enabled: action != null,
      onDirection: (direction) {
        if (direction == TraversalDirection.left) {
          _photoFlipKey.currentState?.flipBy(-1);
          return true;
        }
        if (direction == TraversalDirection.right) {
          _photoFlipKey.currentState?.flipBy(1);
          return true;
        }
        // 上下键必须放行，否则焦点无法离开按钮行走向列表/顶栏。
        return false;
      },
      child: child,
    );
  }

  /// Tab 行：歌曲 / 专辑 / MV。
  /// tv: 段内按钮是否已自带焦点待真机验证，若不可聚焦再包 DpadFocusable
  /// （避免双停点）；刻意不用 _tvFocusableButton——它把左右键吃去翻写真，
  /// 会让遥控无法在三个 Tab 间横向移动。
  Widget _buildTabBarSliver() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: TvScrollRegion(
              memoryKey: 'tv/artist-tab',
              horizontalEdge: DpadEdgeBehavior.leave,
              // 切换器本身按内容宽度居中：M3EToggleButtonGroup 是左对齐的一排，
              // 三栏短文案贴左边会显得整页偏左。
              child: Center(
                child: M3EToggleButtonGroup(
                  actions: [
                    for (final label in _tabLabels)
                      M3EToggleButtonGroupAction(label: Text(label)),
                  ],
                  size: M3EButtonSize.xs,
                  density: M3EButtonGroupDensity.compact,
                  selectedIndex: _tab.index,
                  onSelectedIndexChanged: (index) {
                    if (index == null) return;
                    _onTabChanged(index);
                  },
                ),
              ),
            ),
          ),
        ),
        if (_tab == _ArtistTab.albums && _albumsLoaded)
          _buildMediaCountSliver(
              '专辑', _albumCount > 0 ? _albumCount : _albums.length),
        if (_tab == _ArtistTab.mv && _mvLoaded)
          _buildMediaCountSliver(
              'MV', _mvTotal > 0 ? _mvTotal : _mvs.length),
      ],
    );
  }

  /// 专辑 / MV 的数目行：与歌曲页控制栏同一形态（标题 + 计数徽章）另起一行。
  Widget _buildMediaCountSliver(String label, int count) {
    final colorScheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 占位块的高度：**自身**占满一屏，而不是用 SliverFillRemaining「补满剩余视口」。
  /// 后者会把整页总高算成恰好一屏（真机日志 content=527、max=0），切 Tab 时偏移
  /// 必然归零；前者让总高 = 写真 + 切换器 + 一屏，max ≈ 写真高度，能保住已有偏移。
  double get _mediaPlaceholderHeight {
    if (_scrollController.hasClients) {
      return _scrollController.position.viewportDimension;
    }
    return MediaQuery.sizeOf(context).height;
  }

  /// 专辑 / MV 的整块 loading 与「加载更多」占位（后者小尺寸）。
  Widget _buildLoadingSliver({bool small = false}) {
    if (!small) {
      return SliverToBoxAdapter(
        child: SizedBox(
          height: _mediaPlaceholderHeight,
          child: const Center(child: M3ELoadingIndicator()),
        ),
      );
    }
    return const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: M3ELoadingIndicator(
            constraints: BoxConstraints.tightFor(width: 24, height: 24),
          ),
        ),
      ),
    );
  }

  /// 专辑 / MV 空态：同 [_buildLoadingSliver] 撑一屏，理由一致
  /// （确实没内容的 Tab 也不该把页面高度压塌）。样式沿用歌曲空态：图标 + 一行文案。
  Widget _buildMediaEmptyState(String text, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: _mediaPlaceholderHeight,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 48,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const Gap(AppSpacing.md),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 专辑 Tab 内容。多个 sliver 用 SliverMainAxisGroup 收成一个，
  /// 好让下方「一分支一元素」的 if-else 链不用重排歌曲那三段。
  Widget _buildAlbumsContent() {
    // 未 loaded 覆盖了 loading 与「刚切进来还没发出请求」两种态，
    // 否则会闪一帧「暂无专辑」
    if (!_albumsLoaded) return _buildLoadingSliver();
    final albums = _displayAlbums;
    if (albums.isEmpty) {
      return _buildMediaEmptyState(
        _searchQuery.isEmpty ? '暂无专辑' : '没有找到「$_searchQuery」相关的专辑',
        Icons.album_outlined,
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        ArtistAlbumGridSliver(
          // 喂网格的列表与 onTap 取的必须是同一份：hero tag 与详情页
          // widget.album.id 同源，对不上就是静默不飞
          albums: albums,
          onTap: (index) => AdaptiveNav.openDetail(
            context,
            (_) => AlbumDetailPage(album: albums[index]),
          ),
        ),
        // 加载更多占位只能放在网格之后：PinchableGridView 的 loadingWidget
        // 内部用 Column + Expanded，在无界高度 sliver 里会抛异常
        if (_albumsLoadingMore) _buildLoadingSliver(small: true),
      ],
    );
  }

  /// MV Tab 内容：网格 / loading / 空态 + 触底占位。
  /// 分类筛选在顶栏下拉（见 appBar 的 MV 分类 M3ESortButton）。
  Widget _buildMvContent() {
    // 口径同专辑：未 loaded 即整块 loading，避免闪一帧空态
    if (!_mvLoaded) return _buildLoadingSliver();
    if (_mvs.isEmpty) {
      return _buildMediaEmptyState('暂无 MV', Icons.videocam_outlined);
    }
    return SliverMainAxisGroup(
      slivers: [
        ArtistMvGridSliver(
          mvs: _mvs,
          onTap: (index) => _playMv(_mvs[index]),
        ),
        if (_mvLoadingMore) _buildLoadingSliver(small: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themeProvider = context.watch<ThemeProvider>();
    final bannerH = _bannerH =
        artistBannerHeightFor(MediaQuery.sizeOf(context).height);

    return Scaffold(
      // 写真铺到屏幕顶（y=0）。上轮教训：extendBodyBehindAppBar 只对
      // Scaffold.appBar 生效——顶栏留在 body 的 SliverAppBar 里仍占据
      // 布局高度，写真顶不到状态栏（真机反馈）。改为真正的 appBar 悬浮，
      // 顶部压暗层在 header 内保证图标对比度。
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        centerTitle: false,
        elevation: 0,
        actions: [
          // 屏蔽歌手（内容黑名单）：登录后显示；黑名单内容不出现在推荐场景中。
          // 状态来自 BlacklistProvider（进页已预加载，未拉满时按未屏蔽展示）。
          Consumer2<BlacklistProvider, KugouProvider>(
            builder: (context, blacklist, kugou, _) {
              if (!kugou.isLoggedIn) return const SizedBox.shrink();
              final present =
                  blacklist.statusFor('singer', widget.artistId) ==
                      BlacklistStatus.present;
              return IconButton(
                icon: _isBlacklistToggling
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        present
                            ? Icons.visibility
                            : Icons.visibility_off_outlined,
                      ),
                onPressed: _toggleSingerBlacklist,
                tooltip: present ? '取消屏蔽歌手' : '屏蔽歌手',
              );
            },
          ),
          // 搜索：歌曲 / 专辑两个 Tab 都能开（专辑按名客户端过滤），MV 不显示
          if (_tab != _ArtistTab.mv &&
              (_songs.isNotEmpty || _albums.isNotEmpty))
            IconButton(
              icon: Icon(_isSearching ? Icons.close : Icons.search),
              onPressed: _toggleSearch,
              tooltip: '搜索',
            ),
          // 定位正在播放只对歌曲有意义；排序两个列表各自一套选项
          if (_tab == _ArtistTab.songs && _songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.my_location),
              onPressed: _scrollToPlayingSong,
              tooltip: '定位正在播放',
            ),
          if (_tab == _ArtistTab.songs && _songs.isNotEmpty)
            M3ESortButton<String>(
              tooltip: '排序',
              // 图标随升/降序切换（与歌单页一致）
              icon: _sortAscending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              current: _currentSortOption,
              options: const [
                (value: 'hot', label: '按热度排行'),
                (value: 'new', label: '按发布时间'),
                (value: 'title', label: '按歌曲名称'),
                (value: 'duration', label: '按时长'),
              ],
              onPicked: (value) {
                if (value == 'hot' || value == 'new') {
                  _switchArtistSongSort(value);
                } else {
                  final sortBy = value == 'title'
                      ? ArtistSongSortField.title
                      : ArtistSongSortField.duration;
                  setState(() {
                    // 换字段回到正序；同字段仅刷新（方向由分段控件切换）
                    _sortAscending =
                        _sortBy == sortBy ? _sortAscending : true;
                    _sortBy = sortBy;
                    _invalidateDisplaySongs();
                  });
                }
              },
              ascending: _sortAscending,
              onDirectionChanged: (ascending) {
                setState(() {
                  _sortAscending = ascending;
                  _invalidateDisplaySongs();
                });
              },
            ),
          // 专辑排序：hot/new 走服务端重拉，title 纯客户端。
          // 条件带 _albumsLoading：切服务端排序会把 _albums 清空重拉，
          // 只看 isNotEmpty 会让按钮在请求期间闪没。
          if (_tab == _ArtistTab.albums &&
              (_albums.isNotEmpty || _albumsLoading))
            M3ESortButton<String>(
              tooltip: '专辑排序',
              // 图标随升/降序切换（与歌单页一致）
              icon: _albumSortAscending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              current: _currentAlbumSortOption,
              options: const [
                (value: 'hot', label: '按热度排行'),
                (value: 'new', label: '按发布时间'),
                (value: 'title', label: '按专辑名称'),
              ],
              onPicked: (value) => _switchAlbumSort(value),
              ascending: _albumSortAscending,
              onDirectionChanged: (ascending) {
                setState(() {
                  _albumSortAscending = ascending;
                  _invalidateDisplayAlbums();
                });
              },
            ),
          // MV 分类：与排序钮同一个顶栏下拉控件（M3ESortButton 本身就是
          // 图标 + M3E 下拉面板），不再在网格上方占一行。
          // 只要停在 MV Tab 就恒显示：分类之间数据量差异很大（如「艺人」可能 0 条），
          // 一旦按结果条数隐藏，用户就再也切不回其它分类。
          if (_tab == _ArtistTab.mv)
            M3ESortButton<String>(
              tooltip: 'MV 分类',
              icon: Icons.filter_alt_outlined,
              current: _mvTag,
              options: [
                for (var i = 0; i < _mvTags.length; i++)
                  (value: _mvTags[i], label: _mvTagLabels[i]),
              ],
              // 再点当前分类时 _onMvTagChanged 内部按同值早退，天然不动作
              onPicked: (value) =>
                  _onMvTagChanged(_mvTags.indexOf(value)),
            ),
        ],
        // 顶栏在「banner 底缘即将进入顶栏」前 60px 起从透明渐变到
        // surface，banner 完全滑入顶栏下时已是不透穿底——渐变窗口若
        // 压在 banner 出屏之后，会让列表短暂透在顶栏下显杂乱（真机反馈）。
        backgroundColor: Color.lerp(
          Colors.transparent,
          colorScheme.surface,
          (_scrollOffset - (bannerH - kToolbarHeight - 60))
              .clamp(0.0, 60.0) /
              60,
        )!,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        // 顶栏标题：顶栏变实底后再 fade-in 显示歌手名
        title: Opacity(
          opacity: ((_scrollOffset - (bannerH - kToolbarHeight)) / 60.0)
              .clamp(0.0, 1.0),
          child: Text(
            widget.artistName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      body: SecondaryMiniPlayerHost(
        child: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildError(context, colorScheme)
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(
                      child: ArtistPhotoHeader(
                        photoHash: _photoHash,
                        artistName: widget.artistName,
                        // 写真归属过滤：剔除合作曲响应里其他歌手的写真
                        artistId: widget.artistId,
                        intervalSeconds: themeProvider.artistPhotoInterval,
                        // 无写真时 banner 以歌手头像单页兜底
                        fallbackUrl: _toHttps(_resolvedAvatarUrl),
                        // banner 完全滚出屏幕（顶栏盖住）后停表
                        // tv: 透传翻页 key，左右键由三按钮行驱动（见 _tvFocusableButton）
                        flipKey: _photoFlipKey,
                        active: _scrollOffset < bannerH,
                        // A 方案三按钮行：ⓘ 详情 / ▶ 播放全部 / ☆ 关注。
                        // M3EFilledButton（m3e_core）：默认 elevation 0 无阴影，
                        // 按下圆→方形变（pressedRadius token），取色走主题 token
                        // （tonal=secondaryContainer，主钮=primary）。
                        // 叠加在写真底缘淡出区内（header.actions 槽）。
                        actions: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // tv: onSelect 与 onPressed 取同一个动作（null 时
                            // 两边同时置灰），避免焦点落在点不动的按钮上。
                            _tvFocusableButton(
                              _description != null
                                  ? _showArtistInfoSheet
                                  : null,
                              debugLabel: _description != null
                                  ? 'artist_info'
                                  : 'artist_info_disabled',
                              M3EFilledButton.tonal(
                                onPressed: _description != null
                                    ? _showArtistInfoSheet
                                    : null,
                                tooltip: _description != null
                                    ? '歌手详情'
                                    : '暂无歌手介绍',
                                shape: M3EButtonShape.round,
                                decoration: M3EButtonDecoration(
                                  fixedSize: const Size(56, 56),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: _photoButtonBackground(
                                    colorScheme),
                                  foregroundColor: _photoButtonForeground(
                                    colorScheme),
                                ),
                                child: const Icon(Icons.info_outline),
                              ),
                            ),
                            const Gap(AppSpacing.xl),
                            _tvFocusableButton(
                              _displaySongs.isNotEmpty ? _playAll : null,
                              debugLabel: _displaySongs.isNotEmpty
                                  ? 'artist_play_all'
                                  : 'artist_play_all_disabled',
                              M3EFilledButton(
                                onPressed: _displaySongs.isNotEmpty
                                    ? _playAll
                                    : null,
                              tooltip: '播放全部',
                              shape: M3EButtonShape.round,
                              decoration: M3EButtonDecoration(
                                fixedSize: const Size(80, 80),
                                padding: EdgeInsets.zero,
                                backgroundColor: WidgetStatePropertyAll(
                                  colorScheme.primary,
                                ),
                                foregroundColor: WidgetStatePropertyAll(
                                  colorScheme.onPrimary,
                                ),
                              ),
                                child: const Icon(
                                  Icons.play_arrow,
                                  size: 36,
                                ),
                              ),
                            ),
                            const Gap(AppSpacing.xl),
                            _tvFocusableButton(
                              _isFollowLoading ? null : _toggleFollow,
                              debugLabel: 'artist_follow',
                              M3EFilledButton.tonal(
                                onPressed:
                                    _isFollowLoading ? null : _toggleFollow,
                                tooltip:
                                    _isFollowing ? '取消关注' : '关注歌手',
                                shape: M3EButtonShape.round,
                                decoration: M3EButtonDecoration(
                                  fixedSize: const Size(56, 56),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: _photoButtonBackground(
                                    colorScheme),
                                  foregroundColor: _photoButtonForeground(
                                    colorScheme),
                                ),
                                child: _isFollowLoading
                                    ? const M3ELoadingIndicator(
                                        constraints: BoxConstraints.tightFor(
                                            width: 24, height: 24),
                                      )
                                    : Icon(
                                        _isFollowing
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: _isFollowing
                                            ? colorScheme.error
                                            : null,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Tab 行：歌曲 / 专辑 / MV（专辑与 MV 首次切入才拉第一页）
                    _buildTabBarSliver(),
                    // 歌曲列表控制栏
                    if (_tab == _ArtistTab.songs &&
                        (_songs.isNotEmpty || _isLoading))
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Row(
                            children: [
                              Text(
                                _artistSongSort == 'hot' ? '热门歌曲' : '最新歌曲',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                              ),
                              if (_songs.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${_displaySongs.length}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ],
                              const Spacer(),
                              IconButton(
                                onPressed: _displaySongs.isNotEmpty
                                    ? () {
                                        final shuffled =
                                            List<Song>.from(_displaySongs)
                                              ..shuffle();
                                        context
                                            .read<PlayerProvider>()
                                            .playOnlinePlaylist(shuffled, 0);
                                      }
                                    : null,
                                icon: const Icon(Icons.shuffle),
                                tooltip: '随机播放',
                              ),
                            ],
                          ),
                        ),
                      ),
                    // 搜索栏（MV Tab 不显示：它按分类筛选，无搜索语义）
                    if (_isSearching && _tab != _ArtistTab.mv)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0,
                        ),
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            contextMenuBuilder: buildAppTextContextMenu,
                            decoration: InputDecoration(
                              hintText: _tab == _ArtistTab.albums
                                  ? '搜索专辑名称...'
                                  : '搜索歌手的歌曲...',
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
                    // ── 内容区：按 Tab 分支，歌曲分支保持原样 ──
                    // 搜索无结果
                    if (_tab == _ArtistTab.songs &&
                        _isSearching &&
                        _displaySongs.isEmpty &&
                        _songs.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xxl),
                          child: Column(
                            children: [
                              Icon(Icons.search_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5,
                              ),
                            ),
                              const Gap(AppSpacing.sm),
                              Text(
                                '没有找到「$_searchQuery」相关的歌曲',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant,
                                  ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_tab == _ArtistTab.songs && _songs.isEmpty)
                      SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.xxl),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.music_off,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5,
                                ),
                                ),
                                const Gap(AppSpacing.md),
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
                    else if (_tab == _ArtistTab.songs)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
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
                                  context.read<PlayerProvider>().playOnlinePlaylist(
                                        _displaySongs,
                                        index,
                                      );
                                },
                                onMoreTap: () {},
                              ),
                            );
                          },
                          childCount: _displaySongs.length),
                      )
                    else if (_tab == _ArtistTab.albums)
                      _buildAlbumsContent()
                    else
                      _buildMvContent(),
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
            Icon(
              Icons.cloud_off,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
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
