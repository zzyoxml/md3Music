import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../data/models/album.dart';
import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/song_list_item.dart';
import '../login/login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isLoading = true;
  String? _error;
  List<KugouPlaylistBrief> _playlists = [];
  List<Album> _rankAlbums = [];
  List<Song> _dailyRecommendations = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final kugouProvider = context.read<KugouProvider>();
    try {
      await Future.wait([
        kugouProvider.getPlaylist(),
        kugouProvider.getRankList(),
        kugouProvider.getRecommendDaily(),
      ]);

      if (mounted) {
        setState(() {
          _playlists = kugouProvider.playlistList;
          _rankAlbums = kugouProvider.rankListAsAlbums;
          _dailyRecommendations = kugouProvider.recommendSongsAsSongs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _navigateToLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LoginPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MD3Music'),
        actions: [
          Consumer<KugouProvider>(
            builder: (context, kugouProvider, child) {
              final userInfo = kugouProvider.userInfo;
              final isLoggedIn = kugouProvider.isLoggedIn;

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: isLoggedIn ? (userInfo?.nickname ?? '用户') : '登录',
                  child: IconButton(
                    icon: _buildUserAvatar(userInfo, isLoggedIn, colorScheme),
                    onPressed: _navigateToLogin,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _getGreeting(),
                      style: textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '发现你喜欢的音乐',
                      style: textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_isLoading)
              const SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(64),
                    child: CircularProgressIndicator(),
                  ),
                ),
              )
            else if (_error != null)
              SliverToBoxAdapter(
                child: _buildErrorState(_error!, _loadData),
              )
            else ...[
              SliverToBoxAdapter(
                child: _SectionTitle(title: '热门歌单'),
              ),
              SliverToBoxAdapter(
                child: _buildPlaylistSection(),
              ),
              SliverToBoxAdapter(
                child: _SectionTitle(title: '排行榜'),
              ),
              SliverToBoxAdapter(
                child: _buildRankSection(),
              ),
              SliverToBoxAdapter(
                child: _SectionTitle(title: '每日推荐'),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: _buildDailyRecommendations(context),
              ),
            ],
            const SliverToBoxAdapter(
              child: SizedBox(height: 80),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserAvatar(
    KugouUserDetail? userInfo,
    bool isLoggedIn,
    ColorScheme colorScheme,
  ) {
    final avatarUrl = userInfo?.avatar;
    final userId = userInfo?.userid ?? 'default';

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        child: Icon(
          isLoggedIn ? Icons.person : Icons.person_outline,
          color: colorScheme.onPrimaryContainer,
        ),
      );
    }

    return CircleAvatar(
      backgroundColor: colorScheme.primaryContainer,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          cacheKey: 'avatar_$userId',
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          placeholder: (context, url) => Icon(
            isLoggedIn ? Icons.person : Icons.person_outline,
            color: colorScheme.onPrimaryContainer,
          ),
          errorWidget: (context, url, error) => Icon(
            isLoggedIn ? Icons.person : Icons.person_outline,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
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
              '加载失败',
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
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistSection() {
    if (_playlists.isEmpty) {
      return _buildEmptySection('暂无数据');
    }
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _playlists.length,
        itemBuilder: (context, index) {
          final pl = _playlists[index];
          return _PlaylistHorizontalCard(
            name: pl.name,
            artworkUri: pl.coverUrl,
            songCount: pl.songCount,
            onTap: () {
              final playlist = pl.toPlaylist();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _PlaylistDetailPage(playlist: playlist),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildRankSection() {
    if (_rankAlbums.isEmpty) {
      return _buildEmptySection('暂无数据');
    }
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _rankAlbums.length,
        itemBuilder: (context, index) {
          final album = _rankAlbums[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 150,
              child: AlbumCard(
                album: album,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _RankDetailPage(rankId: album.id, rankName: album.name),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptySection(String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 100,
      child: Center(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildDailyRecommendations(BuildContext context) {
    if (_dailyRecommendations.isEmpty) {
      return SliverToBoxAdapter(
        child: _buildEmptySection('暂无数据'),
      );
    }

    final screenType = getScreenTypeFromContext(context);
    int crossAxisCount;
    switch (screenType) {
      case ScreenType.compact:
        crossAxisCount = 1;
        break;
      case ScreenType.medium:
        crossAxisCount = 2;
        break;
      case ScreenType.expanded:
        crossAxisCount = 4;
    }

    if (crossAxisCount == 1) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final song = _dailyRecommendations[index];
            return SongListItem(
              song: song,
              onTap: () {
                context.read<PlayerProvider>().playOnlinePlaylist(_dailyRecommendations, index);
              },
              onMoreTap: () {},
            );
          },
          childCount: _dailyRecommendations.length,
        ),
      );
    }

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 3.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 4,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final song = _dailyRecommendations[index];
          return SongListItem(
            song: song,
            onTap: () {
              context.read<PlayerProvider>().playOnlinePlaylist(_dailyRecommendations, index);
            },
            onMoreTap: () {},
          );
        },
        childCount: _dailyRecommendations.length,
      ),
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 14) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          TextButton(
            onPressed: () {},
            child: const Text('查看更多'),
          ),
        ],
      ),
    );
  }
}

class _PlaylistHorizontalCard extends StatelessWidget {
  final String name;
  final String? artworkUri;
  final int songCount;
  final VoidCallback? onTap;

  const _PlaylistHorizontalCard({
    required this.name,
    this.artworkUri,
    this.songCount = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: 150,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: colorScheme.surfaceContainerLow,
            child: InkWell(
              onTap: onTap,
              child: Column(
                children: [
                  Expanded(
                    child: artworkUri != null
                        ? CachedNetworkImage(
                            imageUrl: artworkUri!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            placeholder: (_, _) => Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.queue_music,
                                size: 40,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            errorWidget: (_, _, _) => Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.queue_music,
                                size: 40,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : Container(
                            width: double.infinity,
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.queue_music,
                              size: 40,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;

  const _PlaylistDetailPage({required this.playlist});

  @override
  State<_PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<_PlaylistDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getPlaylistTrackAll(id: widget.playlist.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name)),
      body: Consumer<KugouProvider>(
        builder: (context, kugouProvider, child) {
          if (kugouProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = kugouProvider.currentPlaylistSongs;
          if (songs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('暂无数据'),
                  ElevatedButton(
                    onPressed: () =>
                        context.read<KugouProvider>().getPlaylistTrackAll(id: widget.playlist.id),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index].toSong();
              return SongListItem(
                song: song,
                onTap: () {
                  context.read<PlayerProvider>().playOnlinePlaylist(
                    songs.map((e) => e.toSong()).toList(),
                    index,
                  );
                },
                onMoreTap: () {},
              );
            },
          );
        },
      ),
    );
  }
}

class _RankDetailPage extends StatefulWidget {
  final String rankId;
  final String rankName;

  const _RankDetailPage({required this.rankId, required this.rankName});

  @override
  State<_RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<_RankDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getRankSongs(rankId: widget.rankId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.rankName)),
      body: Consumer<KugouProvider>(
        builder: (context, kugouProvider, child) {
          if (kugouProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = kugouProvider.rankSongs;
          if (songs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('暂无数据'),
                  ElevatedButton(
                    onPressed: () =>
                        context.read<KugouProvider>().getRankSongs(rankId: widget.rankId),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index].toSong();
              return SongListItem(
                song: song,
                onTap: () {
                  context.read<PlayerProvider>().playOnlinePlaylist(
                    songs.map((e) => e.toSong()).toList(),
                    index,
                  );
                },
                onMoreTap: () {},
              );
            },
          );
        },
      ),
    );
  }
}
