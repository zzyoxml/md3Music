import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../playlist/playlist_page.dart';
import '../player/mini_player.dart';

class SearchPage extends StatefulWidget {
  /// 是否在页面底部显示 MiniPlayer。
  /// 作为独立路由打开时为 true（页面自带 MiniPlayer）；
  /// 作为主页 Tab 显示时为 false（由 _MainLayout 统一提供全局 MiniPlayer，避免重复）。
  final bool showMiniPlayer;

  const SearchPage({super.key, this.showMiniPlayer = true});

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
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadSearchHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHotSearch();
    });
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
    final types = ['song', 'album', 'artist', 'special', 'cloud', 'lyric'];
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

  Future<void> _loadHotSearch() async {
    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.getHotSearch();
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

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  SliverAppBar(
                    floating: true,
                    pinned: true,
                    title: SizedBox(
                      height: 40,
                      child: TextField(
                        controller: _searchController,
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
                            vertical: 0,
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
                        TabBar(
                          controller: _tabController,
                          tabs: const [
                            Tab(text: '歌曲'),
                            Tab(text: '专辑'),
                            Tab(text: '歌手'),
                            Tab(text: '歌单'),
                            Tab(text: '云盘'),
                            Tab(text: '歌词'),
                          ],
                        ),
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
          if (widget.showMiniPlayer) const MiniPlayer(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;
    final kugouProvider = context.watch<KugouProvider>();
    final hotKeywords = kugouProvider.hotSearchKeywords;

    if (_searchHistory.isEmpty && hotKeywords.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              '搜索你喜欢的音乐',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (_searchHistory.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('搜索历史', style: Theme.of(context).textTheme.titleLarge),
              TextButton(
                onPressed: _clearSearchHistory,
                child: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
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
          const SizedBox(height: 16),
        ],
        if (hotKeywords.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('热门搜索', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: hotKeywords.take(15).map((keyword) {
              return ActionChip(
                label: Text(keyword),
                onPressed: () {
                  _searchController.text = keyword;
                  _performSearch(keyword);
                },
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchResults() {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildSongResults(),
        _buildAlbumResults(),
        _buildArtistResults(),
        _buildPlaylistResults(),
        _buildCloudResults(),
        _buildLyricResults(),
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

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            _performSearch(suggestion);
          },
        );
      },
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
              padding: EdgeInsets.all(12),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final detail = results[index];
                return _LyricSearchResultItem(
                  song: detail.toSong(),
                  lyricSnippet: detail.lyrics ?? '',
                  onTap: () {
                    final songs = results
                        .map((e) => e.toSong())
                        .toList();
                    context.read<PlayerProvider>().playOnlinePlaylist(songs, index);
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  void _showAlbumDetail(Album album) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)));
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
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式仍固定 2 列
            child: PinchableGridView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  onTap: () => _showAlbumDetail(album),
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
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
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArtistDetailPage(
                          artistId: artist.id,
                          artistName: artist.name,
                          avatarUrl: artist.avatarUrl,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
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
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式仍固定 2 列
            child: PinchableGridView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              // 原 childAspectRatio 0.75、spacing 12 保持不变
              childAspectRatio: 0.75,
              spacing: 12,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final pl = results[index];
                final cleanName = pl.name.replaceAll(RegExp(r'<[^>]*>'), '');
                return _SearchAlbumCard(
                  name: cleanName,
                  artist: pl.songCount > 0 ? '${pl.songCount} 首歌曲' : '',
                  artworkUri: pl.coverUrl,
                  icon: Icons.queue_music,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistPage(playlist: pl.toPlaylist()),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(12),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '搜索失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
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
          const SizedBox(height: 12),
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

  const _SearchAlbumCard({
    required this.name,
    required this.artist,
    this.artworkUri,
    this.icon = Icons.album,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: artworkUri != null
                    ? CachedNetworkImage(
                        imageUrl: artworkUri!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        placeholder: (_, _) => _buildPlaceholder(colorScheme),
                        errorWidget: (_, _, _) =>
                            _buildPlaceholder(colorScheme),
                      )
                    : _buildPlaceholder(colorScheme),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
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
                      const SizedBox(height: 2),
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
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
    );
  }
}

/// 歌词搜索结果项：封面 + 歌名/歌手 + 匹配的歌词片段，点击播放。
class _LyricSearchResultItem extends StatelessWidget {
  final Song song;
  final String lyricSnippet;
  final VoidCallback? onTap;

  const _LyricSearchResultItem({
    required this.song,
    required this.lyricSnippet,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    const imgSize = 52.0;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: song.artworkUri != null
                  ? CachedNetworkImage(
                      imageUrl: song.artworkUri!,
                      memCacheWidth: 144,
                      memCacheHeight: 144,
                      width: imgSize,
                      height: imgSize,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => _buildPlaceholder(colorScheme),
                      errorWidget: (_, _, _) => _buildPlaceholder(colorScheme),
                    )
                  : _buildPlaceholder(colorScheme),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lyricSnippet.isNotEmpty
                        ? lyricSnippet
                        : song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: lyricSnippet.isNotEmpty
                          ? colorScheme.primary.withValues(alpha: 0.85)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Icon(Icons.play_arrow, size: 22, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.music_note, size: 26, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _TabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: tabBar,
    );
  }
}
