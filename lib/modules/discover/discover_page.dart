import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/album_card.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';
import '../login/login_page.dart';
import '../charts/charts_page.dart';
import '../playlist/playlist_page.dart';
import '../search/search_page.dart';

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAllData());
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final kugou = context.read<KugouProvider>();
    try {
      await Future.wait([
        kugou.getPlaylist(),
        kugou.getRankList(),
        kugou.getRecommendDaily(),
        kugou.getYuekuBanner(),
        kugou.getSceneMusic(),
        kugou.getThemeMusic(),
        kugou.getThemePlaylist(),
        kugou.getIpHome(),
        kugou.getPersonalFm(),
      ]);
    } catch (e) {
      _error = e.toString();
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'MD3Music',
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          Consumer<KugouProvider>(
            builder: (context, kugou, _) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                icon: kugou.userInfo?.avatar != null
                    ? CircleAvatar(
                        backgroundImage: CachedNetworkImageProvider(
                          kugou.userInfo!.avatar!,
                        ),
                        radius: 16,
                      )
                    : CircleAvatar(
                        backgroundColor: colorScheme.primaryContainer,
                        radius: 16,
                        child: Icon(
                          kugou.isLoggedIn
                              ? Icons.person
                              : Icons.person_outline,
                          size: 18,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const LoginPage())),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAllData,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _buildError(colorScheme)
            : CustomScrollView(
                slivers: [
                  _buildBannerSection(colorScheme),
                  _buildPersonalFmSection(colorScheme),
                  _buildDailySection(colorScheme),
                  _buildThemeMusicSection(colorScheme),
                  _buildSceneSection(colorScheme),
                  _buildPlaylistSection(colorScheme),
                  _buildRankSection(colorScheme),
                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              ),
      ),
    );
  }

  String _getGreeting() {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadAllData,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBannerSection(ColorScheme cs) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        child: Container(
          height: 160,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [cs.primaryContainer, cs.tertiaryContainer],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -20,
                top: -20,
                child: Icon(
                  Icons.music_note,
                  size: 120,
                  color: cs.onPrimaryContainer.withValues(alpha: 0.15),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _getGreeting(),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '发现你喜欢的音乐',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                    ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPersonalFmSection(ColorScheme cs) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: InkWell(
            onTap: () => Navigator.pushNamed(context, '/personal_fm'),
            borderRadius: BorderRadius.circular(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.favorite, size: 16, color: cs.onPrimary),
                      const SizedBox(width: 6),
                      Text(
                        '私人 FM',
                        style: TextStyle(
                          color: cs.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDailySection(ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        final songs = kugou.recommendSongs;
        if (songs.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '每日推荐',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const _DailyRecommendDetailPage(),
                            ),
                          );
                        },
                        child: const Text('查看更多'),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 64,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: songs.length > 5 ? 5 : songs.length,
                    itemBuilder: (context, i) {
                      final s = songs[i];
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          avatar: CircleAvatar(
                            backgroundColor: cs.primaryContainer,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                          ),
                          label: Text(
                            s.songName,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () =>
                              context.read<PlayerProvider>().playOnlinePlaylist(
                                songs.map((e) => e.toSong()).toList(),
                                i,
                              ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildThemeMusicSection(ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        final themes = kugou.themePlaylistData;
        if (themes.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '主题歌单',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(onPressed: () {}, child: const Text('查看更多')),
                    ],
                  ),
                ),
                SizedBox(
                  height: 170,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: themes.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ScaleIn(
                        delayMs: i * 30,
                        child: SizedBox(
                          width: 130,
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: CachedNetworkImage(
                                    imageUrl: themes[i].coverUrl ?? '',
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    placeholder: (_, _) => Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.music_note,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                    errorWidget: (_, _, _) => Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.music_note,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                themes[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: cs.onSurface,
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
        );
      },
    );
  }

  Widget _buildSceneSection(ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        final scenes = kugou.sceneData;
        if (scenes == null) return const SliverToBoxAdapter(child: SizedBox());
        final data = scenes['data'] as Map<String, dynamic>? ?? scenes;
        final list = data['list'] ?? data['info'] ?? [];
        if (list is! List || list.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        final items = list;
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '场景音乐',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  height: 100,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i] as Map<String, dynamic>;
                      return Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Container(
                          width: 90,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: cs.surfaceContainerLow,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.headphones,
                                color: cs.primary,
                                size: 28,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item['name']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistSection(ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        final plist = kugou.playlistList;
        if (plist.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '热门歌单',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const _PlaylistBrowsePage(),
                          ),
                        ),
                        child: const Text('查看更多'),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 200,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: plist.length,
                    itemBuilder: (context, i) => ScaleIn(
                      delayMs: i * 30,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 150,
                          child: AlbumCard(
                            album: Album(
                              id: plist[i].id,
                              name: plist[i].name,
                              artist: '',
                              artworkUri: plist[i].coverUrl,
                              songCount: plist[i].songCount,
                            ),
                            onTap: () {
                              final playlist = plist[i].toPlaylist();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      PlaylistPage(playlist: playlist),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRankSection(ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        final ranks = kugou.rankListAsAlbums;
        if (ranks.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 350,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '排行榜',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ChartsPage()),
                        ),
                        child: const Text('查看更多'),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 200,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: ranks.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 150,
                        child: AlbumCard(
                          album: ranks[i],
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _RankDetailPage(
                                  rankId: kugou.rankList!.ranks[i].id,
                                  rankName: ranks[i].name,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistBrowsePage extends StatefulWidget {
  const _PlaylistBrowsePage();
  @override
  State<_PlaylistBrowsePage> createState() => _PlaylistBrowsePageState();
}

class _PlaylistBrowsePageState extends State<_PlaylistBrowsePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getPlaylist();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('热门歌单')),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          if (kugou.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = kugou.playlistList;
          if (list.isEmpty) return const Center(child: Text('暂无数据'));
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.85,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) => AlbumCard(
              album: Album(
                id: list[i].id,
                name: list[i].name,
                artist: '',
                artworkUri: list[i].coverUrl,
                songCount: list[i].songCount,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaylistPage(playlist: list[i].toPlaylist()),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DailyRecommendDetailPage extends StatefulWidget {
  const _DailyRecommendDetailPage();

  @override
  State<_DailyRecommendDetailPage> createState() => _DailyRecommendDetailPageState();
}

class _DailyRecommendDetailPageState extends State<_DailyRecommendDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getRecommendDaily();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          if (kugou.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = kugou.recommendSongsAsSongs;
          if (songs.isEmpty) return const Center(child: Text('暂无数据'));
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              return SongListItem(
                song: song,
                onTap: () {
                  context.read<PlayerProvider>().playOnlinePlaylist(songs, index);
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
        builder: (context, kugou, _) {
          if (kugou.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = kugou.rankSongs;
          if (songs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('暂无数据'),
                  ElevatedButton(
                    onPressed: () => kugou.getRankSongs(rankId: widget.rankId),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: songs.length,
            itemBuilder: (context, i) {
              final song = songs[i].toSong();
              return AnimatedListWrapper(
                index: i,
                child: SongListItem(
                  song: song,
                  onTap: () =>
                      context.read<PlayerProvider>().playOnlinePlaylist(
                        songs.map((e) => e.toSong()).toList(),
                        i,
                      ),
                  onMoreTap: () {},
                ),
              );
            },
          );
        },
      ),
    );
  }
}
