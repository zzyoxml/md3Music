import '../../core/layout/adaptive_content_grid.dart';
import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../player/secondary_mini_player.dart';
import 'purchased_parser.dart';

/// 「已购」页：单曲 / 专辑两个 Tab。
///
/// 数据来自酷狗已购接口（需登录）：
/// - 单曲：/user/purchased/songs
/// - 专辑：/user/purchased/albums
class PurchasedPage extends StatefulWidget {
  const PurchasedPage({super.key});

  @override
  State<PurchasedPage> createState() => _PurchasedPageState();
}

class _PurchasedPageState extends State<PurchasedPage> {
  static const int _tabSongs = 0;
  static const int _tabAlbums = 1;

  int _currentTab = _tabSongs;

  static const int _pageSize = 30;
  static const String _notLoggedIn = 'not_logged_in';

  final _PurchasedTabData<Song> _songs = _PurchasedTabData<Song>();
  final _PurchasedTabData<Album> _albums = _PurchasedTabData<Album>();

  @override
  void initState() {
    super.initState();
    _reloadSongs();
  }

  void _switchTab(int tab) {
    if (_currentTab == tab) return;
    setState(() => _currentTab = tab);
    if (tab == _tabAlbums && !_albums.loaded) {
      _reloadAlbums();
    } else if (tab == _tabSongs && !_songs.loaded) {
      _reloadSongs();
    }
  }

  Future<void> _reloadSongs() =>
      _reload(_songs, _fetchSongs, parsePurchasedSongs, 'songs');

  Future<void> _reloadAlbums() =>
      _reload(_albums, _fetchAlbums, parsePurchasedAlbums, 'albums');

  Future<Map<String, dynamic>?> _fetchSongs(int page) => KugouApiClient()
      .getUserPurchasedSongs(page: page, pagesize: _pageSize, noCache: true);

  Future<Map<String, dynamic>?> _fetchAlbums(int page) => KugouApiClient()
      .getUserPurchasedAlbums(page: page, pagesize: _pageSize, noCache: true);

  /// 重新加载某一 Tab 的第 1 页。
  Future<void> _reload<T>(
    _PurchasedTabData<T> state,
    Future<Map<String, dynamic>?> Function(int page) fetch,
    PurchasedList<T> Function(Map<String, dynamic>) parse,
    String tag,
  ) async {
    if (!mounted) return;
    setState(() {
      state.loading = true;
      state.error = null;
    });
    if (!KugouApiClient().isLoggedIn) {
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.error = _notLoggedIn;
        state.items.clear();
        state.page = 0;
        state.total = 0;
      });
      return;
    }
    final raw = await fetch(1);
    if (!mounted) return;
    final parsed = _unwrap<T>(raw, parse, tag);
    setState(() {
      state.loading = false;
      state.error = parsed.error;
      state.items
        ..clear()
        ..addAll(parsed.items);
      state.total = parsed.total;
      state.page = parsed.error == null ? 1 : 0;
    });
  }

  /// 加载下一页；无更多 / 在途时直接返回。
  Future<void> _loadMore<T>(
    _PurchasedTabData<T> state,
    Future<Map<String, dynamic>?> Function(int page) fetch,
    PurchasedList<T> Function(Map<String, dynamic>) parse,
    String tag,
  ) async {
    if (!state.hasMore || state.loadingMore || state.loading) return;
    if (!mounted) return;
    setState(() => state.loadingMore = true);
    final next = state.page + 1;
    final raw = await fetch(next);
    if (!mounted) return;
    final parsed = _unwrap<T>(raw, parse, tag);
    setState(() {
      state.loadingMore = false;
      if (parsed.error != null) return;
      state.items.addAll(parsed.items);
      state.page = next;
      if (parsed.total > 0) state.total = parsed.total;
      // 空页即到底：把 total 收敛到已取条数，避免继续空转请求。
      if (parsed.items.isEmpty) state.total = state.items.length;
    });
  }

  /// 统一判空 / 判错 / 打日志。
  ///
  /// 原实现把「上游 502」「登录过期」「真空列表」全部折叠成「暂无歌曲」，
  /// 且没有任何日志（违反项目铁律 7：判状态以日志为准）。
  ({List<T> items, int total, String? error}) _unwrap<T>(
    Map<String, dynamic>? raw,
    PurchasedList<T> Function(Map<String, dynamic>) parse,
    String tag,
  ) {
    if (raw == null) {
      debugPrint('[Purchased] $tag raw=null（本地服务不可达或上游 transport 失败）');
      return (items: <T>[], total: 0, error: '加载失败，请下拉重试');
    }
    final code = raw['error_code'] ?? raw['errcode'] ?? raw['err_code'];
    if (code is num && code != 0) {
      debugPrint(
        '[Purchased] $tag error_code=$code msg=${raw['error_msg'] ?? raw['msg']}',
      );
      return (items: <T>[], total: 0, error: '加载失败（$code）');
    }
    final list = parse(raw);
    debugPrint(
      '[Purchased] $tag total=${list.total} parsed=${list.items.length}',
    );
    return (items: list.items, total: list.total, error: null);
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已购'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: M3EToggleButtonGroup(
              actions: [
                M3EToggleButtonGroupAction(label: Text('单曲 ${_songs.total}')),
                M3EToggleButtonGroupAction(label: Text('专辑 ${_albums.total}')),
              ],
              selectedIndex: _currentTab,
              onSelectedIndexChanged: (index) {
                if (index != null) _switchTab(index);
              },
            ),
          ),
        ),
      ),
      body: SecondaryMiniPlayerHost(child: _buildBody(cs)),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    // 未登录：不渲染 error 图标，改为引导态（与原「错误」态区分开）
    if (_songs.error == _notLoggedIn || _albums.error == _notLoggedIn) {
      if (_currentTab == _tabSongs && _songs.error != _notLoggedIn) {
        // 另一 Tab 已登录失败但当前 Tab 有数据时不进入引导态
      } else {
        return _buildMessage(cs, '登录后查看已购音乐', Icons.shopping_bag_outlined);
      }
    }
    if (_currentTab == _tabSongs) return _buildSongsTab(cs);
    return _buildAlbumsTab(cs);
  }

  Widget _buildSongsTab(ColorScheme cs) {
    final state = _songs;
    if (state.loading && state.items.isEmpty) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return _buildMessage(
        cs,
        state.error == _notLoggedIn ? '登录后查看已购音乐' : state.error!,
        state.error == _notLoggedIn
            ? Icons.shopping_bag_outlined
            : Icons.error_outline,
      );
    }
    if (state.items.isEmpty) {
      return _buildMessage(cs, '暂无已购单曲', Icons.music_note);
    }
    return Column(
      children: [
        _buildSongsHeader(cs),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollEndNotification &&
                  notification.metrics.maxScrollExtent > 0 &&
                  notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 200) {
                _loadMore<Song>(
                  _songs,
                  _fetchSongs,
                  parsePurchasedSongs,
                  'songs',
                );
              }
              return false;
            },
            child: M3EPullToRefreshIndicator(
              onRefresh: () => _reloadSongs(),
              child: ListView.builder(
                // 内容不满一屏时也能下拉（M3EPullToRefreshIndicator 依赖 overscroll）
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: 8 + MediaQuery.paddingOf(context).bottom,
                ),
                itemCount: state.items.length + (state.loadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= state.items.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: M3ELoadingIndicator()),
                    );
                  }
                  return SongListItem(
                    song: state.items[index],
                    onTap: () => _playAt(index),
                    onMoreTap: () {},
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsTab(ColorScheme cs) {
    final state = _albums;
    final heroFirstIndex = firstIndexById(state.items.map((a) => a.id));
    if (state.loading && state.items.isEmpty) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return _buildMessage(
        cs,
        state.error == _notLoggedIn ? '登录后查看已购音乐' : state.error!,
        state.error == _notLoggedIn
            ? Icons.shopping_bag_outlined
            : Icons.error_outline,
      );
    }
    if (state.items.isEmpty) {
      return _buildMessage(cs, '暂无已购专辑', Icons.album_outlined);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.maxScrollExtent > 0 &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          _loadMore<Album>(
            _albums,
            _fetchAlbums,
            parsePurchasedAlbums,
            'albums',
          );
        }
        return false;
      },
      child: M3EPullToRefreshIndicator(
        onRefresh: () => _reloadAlbums(),
        child: AdaptiveContentGrid(
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            top: 12,
            bottom: 12 + MediaQuery.paddingOf(context).bottom,
          ),
          singleColumnBelow: 0,
          childAspectRatio: 0.78,
          itemCount: state.items.length,
          itemBuilder: (context, i) {
            final album = state.items[i];
            return _buildAlbumCard(
              cs,
              i,
              // 该 id 首次出现的卡才参与飞行（避免同子树重复 tag）。
              heroTag: heroFirstIndex[album.id] == i
                  ? albumCoverHeroTag(album.id)
                  : null,
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongsHeader(ColorScheme cs) {
    final total = _songs.total > 0 ? _songs.total : _songs.items.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 $total 首',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          if (_songs.items.isNotEmpty)
            TextButton.icon(
              onPressed: () => _playAt(0),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
        ],
      ),
    );
  }

  Widget _buildAlbumCard(ColorScheme cs, int i, {String? heroTag}) {
    final album = _albums.items[i];
    final cover = album.artworkUri != null
        ? CachedNetworkImage(
            imageUrl: album.artworkUri!,
            memCacheWidth: 540,
            memCacheHeight: 540,
            fit: BoxFit.cover,
            width: double.infinity,
            errorWidget: (_, _, _) => _coverPlaceholder(cs),
          )
        : _coverPlaceholder(cs);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: () => AdaptiveNav.openDetail(
            context,
            (_) => AlbumDetailPage(album: album),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // 卡外层 ClipRRect 全圆 12，封面只占上部 → 可见圆角仅上两角；
                // child 保持未裁剪（圆角由 PlaylistCoverHero 自己施加）。
                child: heroTag == null
                    ? cover
                    : PlaylistCoverHero(
                        tag: heroTag,
                        radius: const BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                        child: cover,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Text(
                  album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.album, size: 48)),
    );
  }

  Widget _buildMessage(ColorScheme cs, String text, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  void _playAt(int index) {
    if (_songs.items.isEmpty) return;
    context.read<PlayerProvider>().playOnlinePlaylist(_songs.items, index);
  }
}

/// 单个 Tab 的加载状态。
///
/// 原实现两个 Tab 共用一个 `_isLoading`，切 Tab 时会互相覆盖；
/// 这里每个 Tab 各自持有 items/page/total/loading/error。
class _PurchasedTabData<T> {
  final List<T> items = <T>[];
  int page = 0;
  int total = 0;
  bool loading = false;
  bool loadingMore = false;
  String? error;

  bool get hasMore => total > 0 && items.length < total;
  bool get loaded => page > 0;
}
