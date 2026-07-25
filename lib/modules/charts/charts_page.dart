import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';

class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();
  /// 布局模式：true=列表（一行一个），false=网格（一行两个）
  bool _isListMode = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getRankList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '排行榜',
        scrollController: _scrollController,
        actions: [
          IconButton(
            icon: Icon(
              _isListMode ? Icons.grid_view_rounded : Icons.view_list_rounded,
            ),
            tooltip: _isListMode ? '切换为网格布局' : '切换为列表布局',
            onPressed: () => setState(() => _isListMode = !_isListMode),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isListMode
          ? _buildRankList(context, cs)
          : _buildRankGrid(context, cs),
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
                  onPressed: () => kugou.getRankList(forceRefresh: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => kugou.getRankList(forceRefresh: true),
          child: ListView.builder(
            controller: _scrollController,
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

  /// 网格布局：一行两个榜单，类似搜索专辑的卡片样式
  Widget _buildRankGrid(BuildContext context, ColorScheme cs) {
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
                  onPressed: () => kugou.getRankList(forceRefresh: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => kugou.getRankList(forceRefresh: true),
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: ranks.ranks.length,
            itemBuilder: (context, i) {
              final rank = ranks.ranks[i];
              return AnimatedListWrapper(
                index: i,
                child: _RankGridCard(
                  name: rank.name,
                  coverUrl: rank.coverUrl,
                  songCount: rank.songCount,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          _RankSongPage(rankId: rank.id, rankName: rank.name),
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
}

/// 网格布局下的排行榜卡片：封面 + 标题 + 歌曲数
class _RankGridCard extends StatelessWidget {
  final String name;
  final String? coverUrl;
  final int songCount;
  final VoidCallback? onTap;

  const _RankGridCard({
    required this.name,
    this.coverUrl,
    this.songCount = 0,
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
                child: coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: coverUrl!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        placeholder: (_, _) => _buildPlaceholder(colorScheme),
                        errorWidget: (_, _, _) =>
                            _buildPlaceholder(colorScheme),
                      )
                    : _buildPlaceholder(colorScheme),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (songCount > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$songCount 首',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
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
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.trending_up,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      ),
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
                    onPressed: () => kugou.getRankSongs(
                      rankId: widget.rankId,
                      forceRefresh: true,
                    ),
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
