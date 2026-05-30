import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';

class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getRankList();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('排行榜'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '排行榜单'),
            Tab(text: '巅峰榜'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildRankList(context, cs), _buildTopList(context, cs)],
      ),
    );
  }

  Widget _buildRankList(BuildContext context, ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        if (kugou.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final ranks = kugou.rankList;
        if (ranks == null || ranks.ranks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.trending_up,
                  size: 48,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text('暂无排行榜数据', style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => kugou.getRankList(),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => kugou.getRankList(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: ranks.ranks.length,
            itemBuilder: (context, i) {
              final rank = ranks.ranks[i];
              return AnimatedListWrapper(
                index: i,
                child: Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: rank.coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: rank.coverUrl!,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                color: cs.surfaceContainerHighest,
                                child: Icon(
                                  Icons.album,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                    title: Text(
                      rank.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            _RankSongPage(rankId: rank.id, rankName: rank.name),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTopList(BuildContext context, ColorScheme cs) {
    return Consumer<KugouProvider>(
      builder: (context, kugou, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: cs.primaryContainer,
                  ),
                  child: Icon(Icons.album, color: cs.onPrimaryContainer),
                ),
                title: const Text('新歌榜'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => kugou.getTopSong(),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: cs.tertiaryContainer,
                  ),
                  child: Icon(Icons.album, color: cs.onTertiaryContainer),
                ),
                title: const Text('专辑榜'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => kugou.getTopAlbum(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RankSongPage extends StatefulWidget {
  final String rankId;
  final String rankName;
  const _RankSongPage({required this.rankId, required this.rankName});
  @override
  State<_RankSongPage> createState() => _RankSongPageState();
}

class _RankSongPageState extends State<_RankSongPage> {
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
                  const SizedBox(height: 16),
                  FilledButton.tonal(
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
