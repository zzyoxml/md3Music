import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/build_flags.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/page_title_alignment.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/tab_snap_physics.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../artist/artist_detail_page.dart';
import '../playlist/playlist_page.dart';
import '../playlist/playlist_songs_loader.dart';
import 'import_playlist_page.dart';
import 'widgets/offline_banner.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 歌单
  List<KugouPlaylistBrief> _playlists = [];
  bool _isLoadingPlaylists = true;
  int _playlistPage = 1;
  bool _hasMorePlaylists = true;
  bool _isLoadingMorePlaylists = false;
  static const int _playlistPageSize = 30;

  // 专辑
  List<KugouPlaylistBrief> _albums = [];
  bool _isLoadingAlbums = true;

  // 歌手
  List<Map<String, dynamic>> _artists = [];
  bool _isLoadingArtists = true;

  // 专辑原始 global_collection_id 映射
  final Map<String, String> _albumOriginalIds = {};

  // 上次成功同步时间（用于 banner 文字与 cache 同步时间）
  DateTime? _lastSyncTime;

  // 网络状态主动探测定时器：兜底用于"用户什么操作都不做、但服务端被关"
  // 的场景。dio 拦截器本身会在任意请求失败时即时更新
  // KugouApiClient.networkReachable，这里只兜底"长时间没有任何 dio 调用"。
  Timer? _networkProbeTimer;
  PlaylistCollectionNotifier? _playlistCollectionNotifier;

  // 分组折叠状态
  bool _createdExpanded = true;
  bool _collectedExpanded = true;

  // 分组手动排序：拖拽产生的歌单 ID 顺序列表（key=globalCollectionId ?? id）。
  // 空列表表示未手动排序，退回默认顺序/「最近点击」。
  List<String> _createdManualOrder = [];
  List<String> _collectedManualOrder = [];

  // 排序模式：0=无分组在排序，1=「我创建的歌单」，2=「我收藏的歌单」。
  // 进入后分组标题右侧按钮变为「完成」，列表项可长按拖拽调整顺序。
  int _reorderingGroup = 0;

  // 歌单访问排序：歌单 ID → 最后访问时间戳（毫秒）
  // 点击歌单后记录时间，列表按最近访问排序（最近访问的排最前）
  Map<String, int> _playlistAccessOrder = {};
  static const _accessOrderKey = 'playlist_access_order';

  // 是否按「最近点击」排序（设置页可开关，默认关闭）
  final SettingsRepository _settingsRepository = SettingsRepository();
  bool _sortByLatestClick = false;

  // 管理模式（批量选择）
  bool _isManaging = false;
  // _managingTab 记录当前批量管理的是哪个 tab（0=歌单, 1=专辑），
  // AppBar 删除按钮按此分发到对应的批量删除逻辑。
  int _managingTab = 0;
  final Set<int> _selectedIndices = {};

  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  ///
  /// `keepScrollOffset: false` —— 关闭跨重建的位置恢复。TabBarView 切换
  /// tab 时非活动 tab 的 ListView 会被 PageView 销毁/重建，默认的
  /// `keepScrollOffset = true` 会让重建后的 ListView 恢复旧 offset，
  /// `extentBefore > 0` 致 M3E 下拉条件（extentBefore == 0）不满足、
  /// 歌单 tab 无法下拉刷新；专辑/歌手 tab 用临时 controller 不受影响。
  final ScrollController _scrollController = ScrollController(keepScrollOffset: false);

  /// 「我喜欢」歌单动态封面：解析出的（歌单接口第一首）专辑封面 URL，
  /// 持久化到 SharedPreferences，离线启动仍可显示（见改版计划四）。
  /// App 内最新点红心的歌由 FavoritesProvider 实时优先，二者都缺失时
  /// 回退歌单接口自带封面。
  String? _myFavoriteCoverUrl;
  static const String _kMyFavoriteCoverKey = 'fav_my_favorite_cover_v1';
  bool _resolvingMyFavoriteCover = false;

  /// 正在「点击封面一键播放」的歌单行下标：封面上显示进度并防重复点击。
  final Set<int> _coverPlayingIndices = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 立即探测一次网络 + 每 30 秒兜底探测（dio 拦截器会同步更新
    // KugouApiClient.networkReachable，banner 自动跟随）。
    unawaited(_probeNetwork());
    _networkProbeTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_probeNetwork()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 先 await 缓存就位（避免 dio 失败先于 SharedPreferences 读到 cache，
      // 导致 banner 在 cache 显示后才被清掉，闪烁）。
      await _loadCachedData();
      await _loadAccessOrder();
      _sortByLatestClick = await _settingsRepository
          .getSortCollectedByLatestClick();
      _createdManualOrder = await _settingsRepository.getCreatedPlaylistOrder();
      _collectedManualOrder = await _settingsRepository
          .getCollectedPlaylistOrder();
      if (!mounted) return;
      setState(() {});
      _loadAllData();
      final notifier = context.read<PlaylistCollectionNotifier>();
      _playlistCollectionNotifier = notifier;
      notifier.addListener(_onCollectionChanged);
    });
  }

  /// 歌单在排序持久化中的稳定 key（与 _playlistAccessOrder 同口径）。
  String _playlistKey(KugouPlaylistBrief p) => p.globalCollectionId ?? p.id;

  /// 轻量级网络探测：用 /server/now 接口。结果通过 dio 拦截器自动
  /// 反映到 KugouApiClient.networkReachable。
  Future<void> _probeNetwork() async {
    try {
      await KugouApiClient().getServerNow();
    } catch (_) {
      // 忽略：dio 拦截器已经处理网络状态
    }
  }

  @override
  void dispose() {
    _networkProbeTimer?.cancel();
    _playlistCollectionNotifier?.removeListener(_onCollectionChanged);
    _playlistCollectionNotifier = null;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 从本地缓存读取上次同步的歌单/专辑/歌手与同步时间，立即渲染。
  /// 不抛异常；任何失败都视为无缓存。
  Future<void> _loadCachedData() async {
    try {
      final cachedPlaylists = await FavoriteListsCache.readPlaylists();
      final cachedAlbums = await FavoriteListsCache.readAlbums();
      final cachedArtists = await FavoriteListsCache.readArtists();
      final lastSync = await FavoriteListsCache.readLastSyncTime();
      // 「我喜欢」缓存封面：离线启动即可显示最近解析出的专辑封面
      String? cachedCover;
      try {
        final prefs = await SharedPreferences.getInstance();
        cachedCover = prefs.getString(_kMyFavoriteCoverKey);
      } catch (_) {}
      if (!mounted) return;
      final hasAny =
          cachedPlaylists.isNotEmpty ||
          cachedAlbums.isNotEmpty ||
          cachedArtists.isNotEmpty;
      if (hasAny) {
        setState(() {
          _playlists = cachedPlaylists;
          _albums = cachedAlbums;
          _artists = cachedArtists;
          _lastSyncTime = lastSync;
          _myFavoriteCoverUrl = cachedCover;
          _isLoadingPlaylists = false;
          _isLoadingAlbums = false;
          _isLoadingArtists = false;
        });
      } else {
        setState(() {
          _lastSyncTime = lastSync;
          _myFavoriteCoverUrl = cachedCover;
        });
      }
    } catch (_) {
      // 缓存读取失败，忽略
    }
  }

  void _onCollectionChanged() {
    if (!mounted || _reorderingGroup != 0) return;
    _loadPlaylists(forceNoCache: true);
    _loadAlbums(noCache: true);
    // 歌单/专辑/歌手收藏变更都走这个 notifier，歌手列表也要一并刷新
    _loadArtists(noCache: true);
  }

  /// 加载歌单访问排序记录
  Future<void> _loadAccessOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_accessOrderKey);
      if (raw != null && raw.isNotEmpty) {
        final parts = raw.split(',');
        final map = <String, int>{};
        for (final part in parts) {
          final kv = part.split(':');
          if (kv.length == 2) {
            final ts = int.tryParse(kv[1]);
            if (ts != null) map[kv[0]] = ts;
          }
        }
        _playlistAccessOrder = map;
      }
    } catch (_) {}
  }

  /// 记录歌单访问时间戳并持久化
  Future<void> _recordPlaylistAccess(KugouPlaylistBrief playlist) async {
    final key = playlist.globalCollectionId ?? playlist.id;
    final now = DateTime.now().millisecondsSinceEpoch;
    _playlistAccessOrder[key] = now;
    setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      final parts = _playlistAccessOrder.entries
          .map((e) => '${e.key}:${e.value}')
          .join(',');
      await prefs.setString(_accessOrderKey, parts);
    } catch (_) {}
  }

  Future<void> _loadAllData() async {
    // 全部走 noCache：绕过本地代理 apicache，收藏/取消收藏后
    // 进入页面即可看到最新数据（否则需手动下拉或重启 App 才生效）
    await Future.wait([
      _loadPlaylists(forceNoCache: true, showLoading: false),
      _loadAlbums(noCache: true, showLoading: false),
      _loadArtists(noCache: true, showLoading: false),
    ]);
    // 歌单就位后解析「我喜欢」动态封面（不阻塞主加载）
    unawaited(_resolveMyFavoriteCover());
  }

  /// 找到收藏页里的「我喜欢」默认歌单（name == 我喜欢）。
  KugouPlaylistBrief? get _myFavoritePlaylist {
    for (final p in _playlists) {
      if (p.name == '我喜欢') return p;
    }
    return null;
  }

  /// 解析「我喜欢」动态封面：取该歌单「最新收藏」的专辑封面（改版计划四）
  /// ——云端歌单接口按收藏时间正序返回，最新在最后，故从**末尾**往前取
  /// 第一首带封面的歌——写入 SharedPreferences 供离线启动显示。
  /// App 内最新红心由 FavoritesProvider 在 tile 里实时优先（最新在前）。
  /// 纯旁路刷新，失败静默，不阻塞任何收藏操作。
  Future<void> _resolveMyFavoriteCover() async {
    if (_resolvingMyFavoriteCover) return;
    final playlist = _myFavoritePlaylist;
    if (playlist == null) return;
    _resolvingMyFavoriteCover = true;
    try {
      final p = playlist.toPlaylist();
      // 复用歌单加载器：缓存优先，缓存为空再拉网络（同详情页接口/缓存）
      var songs = await PlaylistSongsLoader.readCached(
        p,
        isInMyFavorites: true,
      );
      if (songs.isEmpty) {
        if (!mounted) return;
        final r = await PlaylistSongsLoader.fetch(context, p);
        songs = r.songs;
      }
      // 取「最新收藏」的专辑封面。云端「我喜欢」歌单接口按收藏时间
      // **正序**返回（最早在前、最新在最后），所以取最后一首带封面的歌
      // 才是最新收藏（改版计划四：接口无可靠时间字段，以列表顺序为准，
      // 正序取末、倒序取首）；没有则保持回退到歌单自带封面。
      String? cover;
      for (final s in songs.reversed) {
        final art = s.artworkUri;
        if (art != null && art.isNotEmpty) {
          cover = art;
          break;
        }
      }
      if (cover == null || cover == _myFavoriteCoverUrl) return;
      if (mounted) setState(() => _myFavoriteCoverUrl = cover);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kMyFavoriteCoverKey, cover);
      } catch (_) {}
    } catch (_) {
      // 忽略：封面解析失败继续用歌单自带封面
    } finally {
      _resolvingMyFavoriteCover = false;
    }
  }

  /// 点击歌单行左侧封面：加载该歌单并从第一首开始播放（改版计划四）。
  /// 复用歌单加载器（缓存优先），加载中封面显示进度并防重复点击；
  /// 失败保留原队列并提示，不进入空播放。
  Future<void> _playPlaylistFromCover(
    KugouPlaylistBrief playlist,
    int index,
  ) async {
    if (_coverPlayingIndices.contains(index)) return; // 防重复点击
    setState(() => _coverPlayingIndices.add(index));
    try {
      final p = playlist.toPlaylist();
      var songs = await PlaylistSongsLoader.readCached(
        p,
        isInMyFavorites: true,
      );
      if (songs.isEmpty) {
        if (!mounted) return;
        final r = await PlaylistSongsLoader.fetch(context, p);
        songs = r.songs;
      }
      if (!mounted) return;
      if (songs.isEmpty) {
        showToast('歌单加载失败，请检查网络后重试', long: true);
        return;
      }
      await _recordPlaylistAccess(playlist);
      if (!mounted) return;
      // 倒序播放：歌单接口按收藏时间升序返回（最早在前、最新在后），
      // 反转后从最新收藏开始。用户要求所有歌单封面一键播放均倒序。
      final ordered = songs.reversed.toList();
      // 只等到队列构建完成即释放进度环，不等整条 URL 解析/播放链
      // （playOnlinePlaylist 内部自带 try/catch，失败时会链式 next()，
      //  若在此 await 整条链，进度环会长期不消失 → 一直转圈）。
      unawaited(context.read<PlayerProvider>().playOnlinePlaylist(ordered, 0));
      showToast('开始播放「${playlist.name}」');
    } catch (_) {
      if (mounted) showToast('歌单加载失败，请检查网络后重试', long: true);
    } finally {
      if (mounted) {
        setState(() => _coverPlayingIndices.remove(index));
      } else {
        _coverPlayingIndices.remove(index);
      }
    }
  }

  String? get _currentUserId => KugouApiClient().userid;

  bool _isCreated(KugouPlaylistBrief p) {
    final uid = _currentUserId;
    if (uid == null) return false;
    if (p.listCreateUserid != null && p.listCreateUserid!.isNotEmpty) {
      return p.listCreateUserid == uid;
    }
    if (p.type == 0 && p.source != 2) return true;
    if (p.name == '我喜欢' || p.name == '默认收藏') return true;
    if (p.type == 1 || p.source == 2) return false;
    return false;
  }

  int _getAccessTime(KugouPlaylistBrief p) =>
      _playlistAccessOrder[p.globalCollectionId ?? p.id] ?? 0;

  /// 对分组列表应用排序：手动拖拽顺序（manualOrder）优先，
  /// 未列入手动顺序的歌单排在最后且保持相对顺序；
  /// 无手动顺序时退回「最近点击」排序逻辑（_sortByLatestClick）。
  void _applySort(List<KugouPlaylistBrief> list, List<String> manualOrder) {
    if (manualOrder.isNotEmpty) {
      final rank = <String, int>{
        for (var i = 0; i < manualOrder.length; i++) manualOrder[i]: i,
      };
      final originalIndex = <String, int>{
        for (var i = 0; i < list.length; i++) _playlistKey(list[i]): i,
      };
      list.sort((a, b) {
        final fallbackA = manualOrder.length + (originalIndex[_playlistKey(a)] ?? 0);
        final fallbackB = manualOrder.length + (originalIndex[_playlistKey(b)] ?? 0);
        return (rank[_playlistKey(a)] ?? fallbackA).compareTo(
          rank[_playlistKey(b)] ?? fallbackB,
        );
      });
    } else if (_sortByLatestClick) {
      list.sort((a, b) => _getAccessTime(b).compareTo(_getAccessTime(a)));
    }
  }

  List<KugouPlaylistBrief> get _createdPlaylists {
    final list = _playlists.where(_isCreated).toList();
    _applySort(list, _createdManualOrder);
    return list;
  }

  List<KugouPlaylistBrief> get _collectedPlaylists {
    final list = _playlists.where((p) => !_isCreated(p)).toList();
    _applySort(list, _collectedManualOrder);
    return list;
  }

  /// 分组拖拽排序回调：更新内存顺序并立即持久化。
  /// [newIndex] 已由拖拽回调换算为移除后的插入位置，无需再修正。
  void _reorderGroup(int group, int oldIndex, int newIndex) {
    // getter 返回的是已排序的新列表副本，可直接原地调整
    final list = group == 1 ? _createdPlaylists : _collectedPlaylists;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    final order = list.map(_playlistKey).toList();
    setState(() {
      if (group == 1) {
        _createdManualOrder = order;
      } else {
        _collectedManualOrder = order;
      }
    });
    if (group == 1) {
      _settingsRepository.setCreatedPlaylistOrder(order);
    } else {
      _settingsRepository.setCollectedPlaylistOrder(order);
    }
  }

  /// 排序按钮：点击进入该分组的自由排序模式，再次点击（✓）退出。
  void _toggleReorderingGroup(int group) {
    setState(
      () => _reorderingGroup = _reorderingGroup == group ? 0 : group,
    );
  }

  // ==================== 数据加载 ====================

  Future<void> _loadPlaylists({
    bool forceNoCache = false,
    bool showLoading = true,
  }) async {
    // 排序模式下禁止刷新，避免拖动中列表被重建
    if (_reorderingGroup != 0) return;
    if (!mounted) return;
    // 重置分页状态
    _playlistPage = 1;
    _hasMorePlaylists = true;
    // 刷新时重新读取「最近点击排序」开关，使设置改动无需重启即可生效
    _sortByLatestClick = await _settingsRepository
        .getSortCollectedByLatestClick();
    if (showLoading) setState(() => _isLoadingPlaylists = true);

    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(
        page: 1,
        pagesize: _playlistPageSize,
        noCache: forceNoCache,
      );
      if (!mounted) return;

      // KugouApiClient._get 在网络/服务异常时返回 null（吞了 DioException），
      // 不抛异常。把 null 视为离线信号。
      if (result == null) {
        setState(() {
          _isLoadingPlaylists = false;
        });
        return;
      }

      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }

      if (list != null && list.isNotEmpty) {
        final filtered = list!
            .where((e) {
              final json = e as Map<String, dynamic>;
              final type = json['type'] as int? ?? 0;
              final source = json['source'] as int? ?? 0;
              if (type == 1 && source == 2) return false;
              return true;
            })
            .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
            .toList();
        final now = DateTime.now();
        // 判断是否还有更多：返回条数等于请求页大小则可能还有下一页
        _hasMorePlaylists = list!.length >= _playlistPageSize;
        setState(() {
          _playlists = filtered;
          _isLoadingPlaylists = false;
          _lastSyncTime = now;
        });
        // 写入本地缓存（异步，不阻塞 UI）
        FavoriteListsCache.savePlaylists(filtered);
        FavoriteListsCache.saveLastSyncTime(now);
        return;
      }
      // API 返回 200 但 data 列表为空（合法空状态，非网络问题）
      _hasMorePlaylists = false;
      setState(() {
        _isLoadingPlaylists = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingPlaylists = false;
        });
      }
    }
  }

  /// 加载更多歌单（分页追加）
  Future<void> _loadMorePlaylists() async {
    // 排序模式下禁止追加加载，避免拖动中列表变化
    if (_reorderingGroup != 0) return;
    if (!_hasMorePlaylists || _isLoadingMorePlaylists || !mounted) return;
    setState(() => _isLoadingMorePlaylists = true);

    try {
      final api = KugouApiClient();
      final nextPage = _playlistPage + 1;
      final result = await api.getUserPlaylist(
        page: nextPage,
        pagesize: _playlistPageSize,
      );
      if (!mounted) return;

      if (result == null) {
        setState(() => _isLoadingMorePlaylists = false);
        return;
      }

      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }

      if (list != null && list.isNotEmpty) {
        final filtered = list!
            .where((e) {
              final json = e as Map<String, dynamic>;
              final type = json['type'] as int? ?? 0;
              final source = json['source'] as int? ?? 0;
              if (type == 1 && source == 2) return false;
              return true;
            })
            .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
            .toList();
        _playlistPage = nextPage;
        _hasMorePlaylists = list!.length >= _playlistPageSize;
        setState(() {
          _playlists.addAll(filtered);
          _isLoadingMorePlaylists = false;
        });
        // 更新本地缓存
        FavoriteListsCache.savePlaylists(_playlists);
      } else {
        _hasMorePlaylists = false;
        setState(() => _isLoadingMorePlaylists = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMorePlaylists = false);
      }
    }
  }

  Future<void> _loadAlbums({bool noCache = false, bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) setState(() => _isLoadingAlbums = true);

    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(pagesize: 50, noCache: noCache);
      if (!mounted) return;

      if (result == null) {
        setState(() {
          _isLoadingAlbums = false;
        });
        return;
      }

      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }

      if (list != null && list.isNotEmpty) {
        final albums = list!
            .where((e) {
              final json = e as Map<String, dynamic>;
              final type = json['type'] as int? ?? 0;
              final source = json['source'] as int? ?? 0;
              return type == 1 && source == 2;
            })
            .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
            .toList();
        final now = DateTime.now();
        setState(() {
          _albums = albums;
          _isLoadingAlbums = false;
          _lastSyncTime = now;
        });
        FavoriteListsCache.saveAlbums(albums);
        FavoriteListsCache.saveLastSyncTime(now);
        _fetchAlbumGlobalIds(albums);
        return;
      }
      setState(() => _isLoadingAlbums = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAlbums = false;
        });
      }
    }
  }

  /// 通过搜索 API 获取每个专辑的原始数字 album ID
  Future<void> _fetchAlbumGlobalIds(List<KugouPlaylistBrief> albums) async {
    final api = KugouApiClient();
    for (final album in albums) {
      try {
        final searchResult = await api.searchAlbums(album.name);
        if (!mounted) return;
        if (searchResult != null && searchResult.isNotEmpty) {
          for (final found in searchResult) {
            // 匹配专辑名，取 numericId（来自 albumid 字段）
            if (found.name == album.name && found.numericId != null) {
              debugPrint(
                '[AlbumIDs] ${album.name} -> numericId=${found.numericId}',
              );
              if (mounted) {
                setState(() {
                  _albumOriginalIds[album.id] = found.numericId!;
                });
              }
              break;
            }
          }
        }
      } catch (e) {
        // 忽略搜索错误
      }
    }
  }

  Future<void> _loadArtists({bool noCache = false, bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) setState(() => _isLoadingArtists = true);

    try {
      final api = KugouApiClient();
      final result = await api.getUserFollow(noCache: noCache);
      if (!mounted) return;

      if (result == null) {
        setState(() {
          _isLoadingArtists = false;
        });
        return;
      }

      final data = result['data'];
      List<dynamic>? list;

      // API 返回格式: {data: {total: N, lists: [...]}}
      if (data is Map<String, dynamic>) {
        list = data['lists'] as List<dynamic>?;
        list ??= data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
        list ??= data['fans'] as List<dynamic>?;
      } else if (data is List) {
        list = data;
      }

      if (list != null && list.isNotEmpty) {
        final artists = list!.map((e) => e as Map<String, dynamic>).toList();
        final now = DateTime.now();
        setState(() {
          _artists = artists;
          _isLoadingArtists = false;
          _lastSyncTime = now;
        });
        FavoriteListsCache.saveArtists(artists);
        FavoriteListsCache.saveLastSyncTime(now);
        return;
      }
      setState(() {
        _isLoadingArtists = false;
      });
    } catch (e) {
      debugPrint('[Follow] Error: $e');
      if (mounted) {
        setState(() {
          _isLoadingArtists = false;
        });
      }
    }
  }

  // ==================== 歌单操作 ====================

  /// 打开「导入外部歌单」功能页；导入成功返回后刷新歌单列表。
  Future<void> _openImportPlaylistPage() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ImportPlaylistPage()),
    );
    if (changed == true && mounted) {
      _loadPlaylists(forceNoCache: true);
    }
  }

  Future<void> _showCreatePlaylistDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          contextMenuBuilder: buildAppTextContextMenu,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入歌单名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final api = KugouApiClient();
      await api.createPlaylist(result);
      _loadPlaylists(forceNoCache: true);
    }
  }

  void _enterManageMode(int tab) {
    setState(() {
      _isManaging = true;
      _managingTab = tab;
      _selectedIndices.clear();
    });
  }

  void _exitManageMode() {
    setState(() {
      _isManaging = false;
      _managingTab = 0;
      _selectedIndices.clear();
    });
  }

  /// tab 切换完成后自动退出批量管理模式（避免歌单/专辑选中错位）
  void _onTabChanged() {
    if (!_tabController.indexIsChanging && _isManaging) {
      _exitManageMode();
    }
  }

  Future<void> _deleteSelectedPlaylists() async {
    if (_selectedIndices.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 ${_selectedIndices.length} 个歌单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final api = KugouApiClient();
    var okCount = 0;
    var failCount = 0;
    for (final index in _selectedIndices) {
      if (index < 0 || index >= _playlists.length) {
        failCount++;
        continue;
      }
      final playlist = _playlists[index];
      final listId = playlist.listId;
      if (listId.isEmpty) {
        failCount++;
        continue;
      }
      // type 语义（与 JS playlist_del.js 及歌单详情页/专辑页一致）：
      //   type=1 删除自己创建的歌单，type=0 取消收藏别人的歌单。
      // 检查删除结果：status==1 或 error_code==0 视为成功，失败不再静默。
      final type = _isCreated(playlist) ? 1 : 0;
      final r = await api.deletePlaylist(listId, type: type);
      debugPrint(
        '[DeletePlaylist] listid=$listId type=$type result=$r',
      );
      if (r?['status'] == 1 || r?['error_code'] == 0) {
        okCount++;
      } else {
        failCount++;
      }
    }

    _exitManageMode();
    _loadPlaylists(forceNoCache: true);

    // 删除结果用 toast 提示。
    if (mounted) {
      final msg = failCount == 0
          ? '成功删除 $okCount 个歌单'
          : okCount > 0
              ? '成功删除 $okCount 个，$failCount 个失败'
              : '删除失败，请稍后重试';
      showToast(msg, long: true);
    }
  }

  Future<void> _deleteSelectedAlbums() async {
    if (_selectedIndices.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 ${_selectedIndices.length} 个专辑吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final api = KugouApiClient();
    var okCount = 0;
    var failCount = 0;
    for (final index in _selectedIndices) {
      if (index < 0 || index >= _albums.length) {
        failCount++;
        continue;
      }
      final album = _albums[index];
      final listId = album.listId;
      if (listId.isEmpty) {
        failCount++;
        continue;
      }
      // 专辑都是「收藏别人的」，取消收藏固定用 type=0（与专辑详情页一致）。
      final r = await api.deletePlaylist(listId, type: 0);
      debugPrint(
        '[DeleteAlbum] listid=$listId type=0 result=$r',
      );
      if (r?['status'] == 1 || r?['error_code'] == 0) {
        okCount++;
      } else {
        failCount++;
      }
    }

    _exitManageMode();
    _loadAlbums(noCache: true);

    // 删除结果用 toast 提示。
    if (mounted) {
      final msg = failCount == 0
          ? '成功删除 $okCount 个专辑'
          : okCount > 0
              ? '成功删除 $okCount 个，$failCount 个失败'
              : '删除失败，请稍后重试';
      showToast(msg, long: true);
    }
  }

  // ==================== UI构建 ====================

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // 批量管理模式下拦截系统返回：退出管理模式而非退出 App
    return PopScope(
      canPop: !_isManaging,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _exitManageMode();
      },
      child: Scaffold(
        appBar: AppBar(
          // 统一对齐规则：作为底部导航栏一级页面时左对齐，被 push 成二级页面时居中
          centerTitle: centerPageTitle(context, tabId: 'favorites'),
          title: Text(
            '我的收藏',
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          actions: [
            // 新建歌单入口已移到「我创建的歌单」分组标题右侧，
            // 这里只在批量管理模式下保留删除按钮。
            if (_isManaging)
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: _managingTab == 1
                    ? _deleteSelectedAlbums
                    : _deleteSelectedPlaylists,
              ),
          ],
          bottom: TabBar(
            controller: _tabController,
            // 图标与文字都比顶栏标题小一档；分组标题（_GroupSection）再小一档
            labelStyle: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: textTheme.labelMedium,
            labelPadding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            tabs: const [
              Tab(
                height: 52,
                icon: Icon(Icons.queue_music, size: 18),
                text: '歌单',
              ),
              Tab(height: 52, icon: Icon(Icons.album, size: 18), text: '专辑'),
              Tab(height: 52, icon: Icon(Icons.person, size: 18), text: '歌手'),
            ],
          ),
        ),
        body: Column(
          children: [
            // 监听 dio 拦截器维护的全局网络状态：任意 dio 请求失败 → 显示 banner
            ValueListenableBuilder<bool>(
              valueListenable: KugouApiClient.networkReachable,
              builder: (context, reachable, _) {
                if (reachable) return const SizedBox.shrink();
                return OfflineBanner(
                  lastSyncTime: _lastSyncTime,
                  onRetry: _retryFromBanner,
                );
              },
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const TabSnapPhysics(),
                children: [
                  _buildPlaylistsTab(),
                  _buildAlbumsTab(),
                  _buildArtistsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// banner 上的"点击重试"：强制无缓存拉一遍三个 tab。
  /// banner 显示与否已由 dio 拦截器维护的 networkReachable 决定，
  /// 这里无需手动 setState _isOffline。
  Future<void> _retryFromBanner() async {
    await Future.wait([
      _loadPlaylists(forceNoCache: true),
      _loadAlbums(noCache: true),
      _loadArtists(noCache: true),
    ]);
  }

  // ==================== 歌单Tab ====================

  Widget _buildPlaylistsTab() {
    if (_isLoadingPlaylists) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (_playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.queue_music,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const Gap(AppSpacing.lg),
            Text(
              '还没有歌单',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '去发现页找找喜欢的歌单吧',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.lg),
            // 空列表时分组标题不渲染，这里补一个新建歌单入口
            FilledButton.tonalIcon(
              onPressed: _showCreatePlaylistDialog,
              icon: const Icon(Icons.add),
              label: const Text('新建歌单'),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.maxScrollExtent > 0 &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          _loadMorePlaylists();
        }
        return false;
      },
      child: M3EPullToRefreshIndicator(
        onRefresh: () => _loadPlaylists(forceNoCache: true, showLoading: false),
        child: ListView(
          controller: _scrollController,
          // 内容不满一屏时也能下拉（M3EPullToRefreshIndicator 依赖 overscroll）
          physics: const AlwaysScrollableScrollPhysics(),
          // 底部叠加系统手势条（小横条）高度，避免末项被压住
          padding: EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            // 分组标题常驻（即使暂无自建歌单），保证右侧「+」新建入口始终可达
            _GroupSection(
              title: '我创建的歌单',
              expanded: _createdExpanded,
              onToggle: () =>
                  setState(() => _createdExpanded = !_createdExpanded),
              playlists: _createdPlaylists,
              reordering: _reorderingGroup == 1,
              onReorder: (oldIndex, newIndex) =>
                  _reorderGroup(1, oldIndex, newIndex),
              keyFor: _playlistKey,
              onBuildTile: (playlist) =>
                  _buildPlaylistTile(playlist, _playlists.indexOf(playlist)),
              // 新建歌单：原顶栏右上角的 "+" 移到此处；排序按钮靠最右
              trailing: _isManaging
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_reorderingGroup != 1) ...[
                          IconButton(
                            icon: const Icon(Icons.input, size: 20),
                            visualDensity: VisualDensity.compact,
                            tooltip: '导入外部歌单',
                            onPressed: _openImportPlaylistPage,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add, size: 20),
                            visualDensity: VisualDensity.compact,
                            tooltip: '新建歌单',
                            onPressed: _showCreatePlaylistDialog,
                          ),
                        ],
                        _buildPlaylistSortButton(1),
                      ],
                    ),
            ),
            if (_collectedPlaylists.isNotEmpty)
              _GroupSection(
                title: '我收藏的歌单',
                expanded: _collectedExpanded,
                onToggle: () =>
                    setState(() => _collectedExpanded = !_collectedExpanded),
                playlists: _collectedPlaylists,
                reordering: _reorderingGroup == 2,
                onReorder: (oldIndex, newIndex) =>
                    _reorderGroup(2, oldIndex, newIndex),
                keyFor: _playlistKey,
                onBuildTile: (playlist) =>
                    _buildPlaylistTile(playlist, _playlists.indexOf(playlist)),
                trailing: _isManaging
                    ? null
                    : _buildPlaylistSortButton(2),
              ),
            // 底部加载更多指示器
            if (_isLoadingMorePlaylists)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: M3ELoadingIndicator()),
              )
            else if (!_hasMorePlaylists &&
                _playlists.length > _playlistPageSize)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Center(
                  child: Text(
                    '没有更多了',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 分组标题右侧的排序按钮：点击进入自由排序模式（长按拖拽调整顺序），
  /// 排序模式下变为「完成」勾选，点击退出排序模式。
  Widget _buildPlaylistSortButton(int group) {
    final cs = Theme.of(context).colorScheme;
    final reordering = _reorderingGroup == group;
    return IconButton(
      icon: Icon(
        reordering ? Icons.check : Icons.sort,
        size: 20,
        color: reordering ? cs.primary : cs.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
      tooltip: reordering ? '完成排序' : '自由排序',
      onPressed: () => _toggleReorderingGroup(group),
    );
  }

  /// 52×52 圆角封面图（含占位/错误兜底）。
  Widget _coverImage(String? url, ColorScheme cs) {
    final placeholder = Container(
      color: cs.surfaceContainerHighest,
      child: Icon(Icons.queue_music, size: 24, color: cs.onSurfaceVariant),
    );
    if (url == null || url.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: 156,
      memCacheHeight: 156,
      fit: BoxFit.cover,
      // 这份封面会被歌单连贯过渡的飞行层拿去画（`PlaylistCoverHero` 的来源端内容）：
      // OctoImage 默认「图片淡入 500ms + 占位淡出 1s」，飞行层每次都是新建元素，
      // 只要不是同帧同步命中缓存就会带着透明度爬坡 → 飞行途中「暗一下」。
      // 共享元素过渡本身就是动画，这里不再叠加渐变。
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }

  /// 歌单行左侧封面：点击直接从第一首播放（改版计划四）；加载中显示进度环。
  /// 「我喜欢」歌单动态封面 = App 内最新红心歌曲专辑封面（FavoritesProvider
  /// 实时优先），回退解析缓存 [_myFavoriteCoverUrl]，再回退歌单自带封面。
  Widget _buildPlaylistCover(
    KugouPlaylistBrief playlist,
    int index,
    ColorScheme cs,
  ) {
    final isMyFavorite = playlist.name == '我喜欢';
    final reordering = _isCreated(playlist)
        ? _reorderingGroup == 1
        : _reorderingGroup == 2;
    final loading = _coverPlayingIndices.contains(index);

    final Widget cover = isMyFavorite
        ? Selector<FavoritesProvider, String?>(
            // FavoritesProvider.favorites 本地点红心按新增时间**倒序**（最新在前，
            // toggleFavorite insert(0)），取 first 即最新收藏。封面随最新红心实时更新。
            selector: (_, fav) => fav.favorites.isNotEmpty
                ? fav.favorites.first.artworkUri
                : null,
            builder: (context, newestArt, _) {
              final url = (newestArt != null && newestArt.isNotEmpty)
                  ? newestArt
                  : (_myFavoriteCoverUrl ?? playlist.coverUrl);
              return _coverImage(url, cs);
            },
          )
        : _coverImage(playlist.coverUrl, cs);

    final clipped = ClipRRect(
      borderRadius: AppRadius.smAll,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PlaylistCoverHero(
              tag: playlistCoverHeroTag(
                playlist.globalCollectionId ?? playlist.id,
              ),
              radius: AppRadius.smAll,
              child: cover,
            ),
            // 右下角一键播放小三角：提示「点击封面即可从头播放」。
            // 无底色，仅保留白色三角；叠一层轻微阴影保证在浅色封面上可辨识。
            // 加载中（进度环覆盖）或管理/排序模式（封面点击被劫持）时隐藏。
            if (!loading && !_isManaging && !reordering)
              const Positioned(
                right: 2,
                bottom: 2,
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            if (loading)
              Container(
                color: Colors.black.withValues(alpha: 0.45),
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // 管理/排序模式下不劫持封面点击，交给整行的选择/拖拽逻辑
    if (_isManaging || reordering) return clipped;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: loading ? null : () => _playPlaylistFromCover(playlist, index),
      child: clipped,
    );
  }

  Widget _buildPlaylistTile(KugouPlaylistBrief playlist, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = _selectedIndices.contains(index);
    // 排序模式下禁用点击跳转与长按管理，长按留给 M3E 列表的整行拖拽
    final reordering = _isCreated(playlist)
        ? _reorderingGroup == 1
        : _reorderingGroup == 2;

    final VoidCallback? tapAction = reordering
        ? null
        : _isManaging
        ? () {
            setState(() {
              if (isSelected) {
                _selectedIndices.remove(index);
              } else {
                _selectedIndices.add(index);
              }
            });
          }
        : () async {
            await _recordPlaylistAccess(playlist);
            if (!mounted) return;
            AdaptiveNav.openDetail(
              context,
              (_) => PlaylistPage(
                playlist: playlist.toPlaylist(),
                isInMyFavorites: true,
                isUserCreated: _isCreated(playlist),
                isDefaultFavorite: playlist.name == '我喜欢',
              ),
            );
          };
    final VoidCallback? longPressAction = reordering || _isManaging
        ? null
        : () {
            _enterManageMode(0);
            setState(() => _selectedIndices.add(index));
          };

    Widget content = InkWell(
        onTap: tapAction,
        onLongPress: longPressAction,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.3)
              : null,
          child: Row(
            children: [
              if (_isManaging)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.md),
                  child: Icon(
                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 22,
                  ),
                ),
              _buildPlaylistCover(playlist, index, colorScheme),
              const Gap(AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Gap(AppSpacing.xxs),
                    Text(
                      '${playlist.songCount} 首',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 歌单行右侧不再显示箭头（改版计划四）；排序模式保留拖拽把手。
              if (reordering)
                Icon(
                  Icons.drag_indicator,
                  color: colorScheme.onSurfaceVariant,
                  size: 20,
                ),
            ],
          ),
        ),
      );

    // tv: TV 构建下歌单卡单停点（DpadFocusable 默认 excludeChildFocus，
    // 内层 InkWell 不再产生第二个停点）；OK=打开/切换选中，OK 长按=进管理模式并选中。
    // 排序模式（tapAction 为 null）时对遍历不可用，与触屏禁用语义一致。
    if (kTvBuild) {
      content = DpadFocusable(
        onSelect: tapAction,
        onLongSelect: longPressAction,
        enabled: tapAction != null,
        child: content,
      );
    }
    return content;
  }

  // ==================== 专辑Tab ====================

  Widget _buildAlbumsTab() {
    if (_isLoadingAlbums) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (_albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.album,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const Gap(AppSpacing.lg),
            Text(
              '还没有收藏专辑',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Md3PullToRefresh(
      onRefresh: () => _loadAlbums(noCache: true, showLoading: false),
      // 卡片类内容按实宽自适应：手机竖屏（<600）保持单列，横屏 / 平板变宽后
      // 铺成多列横向卡片（计划 ⑥）。歌曲列表不走此组件、始终单列。
      child: AdaptiveContentGrid(
        padding: EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
        ),
        targetExtent: 380,
        childAspectRatio: 3.5,
        spacing: AppSpacing.sm,
        minColumns: 2,
        maxColumns: 3,
        itemCount: _albums.length,
        itemBuilder: (context, index) {
          final album = _albums[index];
          return _buildAlbumTile(album, index);
        },
      ),
    );
  }

  Widget _buildAlbumTile(KugouPlaylistBrief album, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    // 优先使用搜索到的原始数字 album ID
    final originalId = _albumOriginalIds[album.id] ?? album.numericId;
    final isSelected = _selectedIndices.contains(index);
    debugPrint(
      '[AlbumTile] ${album.name}: originalId=$originalId (from map: ${_albumOriginalIds[album.id]}, numericId: ${album.numericId})',
    );

    return InkWell(
      onTap: _isManaging
          ? () {
              setState(() {
                if (isSelected) {
                  _selectedIndices.remove(index);
                } else {
                  _selectedIndices.add(index);
                }
              });
            }
          : () {
              debugPrint(
                '[AlbumTile] tapping ${album.name} -> albumGlobalCollectionId=$originalId',
              );
              AdaptiveNav.openDetail(
                context,
                (_) => PlaylistPage(
                  playlist: album.toPlaylist(),
                  isInMyFavorites: true,
                  isAlbum: true,
                  albumGlobalCollectionId: originalId,
                ),
              );
            },
      onLongPress: _isManaging
          ? null
          : () {
              _enterManageMode(1);
              setState(() => _selectedIndices.add(index));
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        color: isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : null,
        child: Row(
          children: [
            if (_isManaging)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  size: 22,
                ),
              ),
            SizedBox(
              width: 52,
              height: 52,
              child: PlaylistCoverHero(
                tag: playlistCoverHeroTag(album.globalCollectionId ?? album.id),
                radius: AppRadius.smAll,
                child: album.coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: album.coverUrl!,
                        memCacheWidth: 156,
                        memCacheHeight: 156,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.album,
                            size: 24,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        errorWidget: (_, _, _) => Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.album,
                            size: 24,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.album,
                          size: 24,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Gap(AppSpacing.xxs),
                  Text(
                    '${album.songCount} 首',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 歌手Tab ====================

  Widget _buildArtistsTab() {
    if (_isLoadingArtists) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (_artists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const Gap(AppSpacing.lg),
            Text(
              '还没有关注歌手',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Md3PullToRefresh(
      onRefresh: () => _loadArtists(noCache: true, showLoading: false),
      // 卡片类内容按实宽自适应：手机竖屏（<600）保持单列，变宽后铺成多列
      // 横向卡片（计划 ⑥）。
      child: AdaptiveContentGrid(
        padding: EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
        ),
        targetExtent: 380,
        childAspectRatio: 3.5,
        spacing: AppSpacing.sm,
        minColumns: 2,
        maxColumns: 3,
        itemCount: _artists.length,
        itemBuilder: (context, index) {
          final artist = _artists[index];
          return _buildArtistTile(artist);
        },
      ),
    );
  }

  /// 将 http:// URL 转换为 https://
  String? _fixImageUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  Widget _buildArtistTile(Map<String, dynamic> artist) {
    final colorScheme = Theme.of(context).colorScheme;
    final name =
        artist['nickname'] ?? artist['user_name'] ?? artist['name'] ?? '';
    final avatar = _fixImageUrl(
      (artist['pic'] ??
              artist['user_pic'] ??
              artist['user_img'] ??
              artist['avatar'])
          ?.toString(),
    );
    // 使用 singerid 作为歌手 ID（userid 是用户 ID，不是歌手 ID）
    final id =
        artist['singerid']?.toString() ??
        artist['userid']?.toString() ??
        artist['id']?.toString() ??
        '';

    return InkWell(
      onTap: () {
        AdaptiveNav.openDetail(
          context,
          (_) => ArtistDetailPage(
            artistId: id,
            artistName: name.toString(),
            avatarUrl: avatar,
            initialIsFollowed: true,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: colorScheme.surfaceContainerHighest,
              backgroundImage: avatar != null
                  ? CachedNetworkImageProvider(avatar)
                  : null,
              child: avatar == null
                  ? Icon(
                      Icons.person,
                      size: 24,
                      color: colorScheme.onSurfaceVariant,
                    )
                  : null,
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// 可折叠/展开的歌单分组，带有平滑过渡动画。
///
/// 使用 [AnimationController] + [SizeTransition] 实现高度渐变，
/// [AnimatedRotation] 实现箭头图标旋转。
class _GroupSection extends StatefulWidget {
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<KugouPlaylistBrief> playlists;
  final Widget Function(KugouPlaylistBrief) onBuildTile;

  /// 是否处于自由排序模式：分组主体切换为可拖拽的 M3E 列表。
  final bool reordering;

  /// 拖拽调整顺序回调（reordering 为 true 时必填）。
  final void Function(int oldIndex, int newIndex)? onReorder;

  /// 歌单的稳定 key（reordering 为 true 时必填，供拖拽列表去重）。
  final String Function(KugouPlaylistBrief)? keyFor;

  /// 标题行最右侧的附加控件（如「我创建的歌单」的新建按钮）。
  final Widget? trailing;

  const _GroupSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.playlists,
    required this.onBuildTile,
    this.reordering = false,
    this.onReorder,
    this.keyFor,
    this.trailing,
  });

  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
      value: widget.expanded ? 1.0 : 0.0,
    );
    _sizeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
  }

  @override
  void didUpdateWidget(covariant _GroupSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: widget.onToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: widget.expanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        child: Icon(
                          Icons.expand_more,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                      ),
                      const Gap(AppSpacing.xs),
                      // 分组标题：比 TabBar 的「歌单/专辑/歌手」再小一档
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const Gap(AppSpacing.sm),
                      Text(
                        '${widget.playlists.length}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: widget.trailing,
              ),
          ],
        ),
        ClipRect(
          child: SizeTransition(
            sizeFactor: _sizeAnimation,
            alignment: Alignment.topCenter,
            child: widget.reordering
                // 排序模式：嵌套在外层 ListView 内，自适应高度且禁止自滚动；
                // 整行长按（M3E 200ms 延迟拖拽）触发重排
                ? M3EReorderableDismissibleList(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: widget.playlists.length,
                    // key 由 M3E 内部套用（KeyedSubtree），保证重排后行状态稳定
                    keyBuilder: (index) =>
                        ValueKey(widget.keyFor!(widget.playlists[index])),
                    // M3E 的 newIndex 是「移除前」的插入位（等同标准
                    // ReorderableListView.onReorder，源码在 to > from 时补 +1）；
                    // 而 widget.onReorder（_reorderGroup）沿用旧 material_ui
                    // onReorderItem 的「移除后」语义（直接用 newIndex 做 insert），
                    // 故此处补回框架原先自动做的 -1，保证手动顺序的写回逐字不变。
                    onReorder: (oldIndex, newIndex) => widget.onReorder!(
                      oldIndex,
                      newIndex > oldIndex ? newIndex - 1 : newIndex,
                    ),
                    // 置零 M3E 卡片自身的背景/圆角/间距/内边距：行内是自带样式的自绘行；
                    // 同时用 direction: none 关掉滑动（本列表只有拖拽排序，没有删除）
                    style: const M3EDismissibleCardStyle(
                      outerRadius: 0,
                      innerRadius: 0,
                      gap: 0,
                      padding: EdgeInsets.zero,
                      color: Colors.transparent,
                      direction: DismissDirection.none,
                    ),
                    itemBuilder: (context, index) =>
                        widget.onBuildTile(widget.playlists[index]),
                  )
                : Column(
                    children: widget.playlists.map((playlist) {
                      return widget.onBuildTile(playlist);
                    }).toList(),
                  ),
          ),
        ),
      ],
    );
  }
}
