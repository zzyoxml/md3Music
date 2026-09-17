import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
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
  bool _isLoading = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRankList();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '排行榜',
        // 有壁纸时顶栏完全透明（与发现页一致），无壁纸时恒不透明 surface
        opaque: true,
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
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _isListMode
          ? _buildRankList(context, cs)
          : _buildRankGrid(context, cs),
    );
  }

  Widget _buildRankList(BuildContext context, ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, ranks, _) {
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
                Text(
                  '暂无排行榜数据',
                  style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => context.read<KugouProvider>().getRankList(
                    forceRefresh: true,
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return Md3PullToRefresh(
          onRefresh: () =>
              context.read<KugouProvider>().getRankList(forceRefresh: true),
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: ranks.ranks.length,
            itemBuilder: (context, i) {
              final rank = ranks.ranks[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: cs.surfaceContainerLow,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _RankSongPage(
                          rankId: rank.id,
                          rankName: rank.name,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          // 排名徽章
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < 3
                                  ? cs.primary.withValues(alpha: 0.12)
                                  : cs.surfaceContainerHighest,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${i + 1}',
                              style: tt.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: i < 3
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // 封面
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 52,
                              height: 52,
                              child: rank.coverUrl != null
                                  ? CachedNetworkImage(
                                      imageUrl: rank.coverUrl!,
                                      memCacheWidth: 156,
                                      memCacheHeight: 156,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.album,
                                        color: cs.onSurfaceVariant,
                                        size: 24,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // 标题
                          Expanded(
                            child: Text(
                              rank.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                            size: 22,
                          ),
                        ],
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
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, ranks, _) {
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
                Text(
                  '暂无排行榜数据',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => context.read<KugouProvider>().getRankList(
                    forceRefresh: true,
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return Md3PullToRefresh(
          onRefresh: () =>
              context.read<KugouProvider>().getRankList(forceRefresh: true),
          // 使用 PinchableGridView 替代固定2列 GridView：
          // Pad 模式下双指捏合可动态调整列数，非 Pad 模式仍固定 2 列
          child: PinchableGridView(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            spacing: 12.0,
            childAspectRatio: 0.78,
            itemCount: ranks.ranks.length,
            itemBuilder: (context, i) {
              final rank = ranks.ranks[i];
              return _RankGridCard(
                name: rank.name,
                coverUrl: rank.coverUrl,
                songCount: rank.songCount,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        _RankSongPage(rankId: rank.id, rankName: rank.name),
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
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRankSongs(rankId: widget.rankId);
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.rankName,
          style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.rankSongs,
              builder: (context, songs, _) {
                if (songs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.music_off,
                          size: 48,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无数据',
                          style: tt.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () async {
                            setState(() => _isLoading = true);
                            await context.read<KugouProvider>().getRankSongs(
                              rankId: widget.rankId,
                              forceRefresh: true,
                            );
                            if (mounted) setState(() => _isLoading = false);
                          },
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
                    return SongListItem(
                      song: song,
                      onTap: () =>
                          context.read<PlayerProvider>().playOnlinePlaylist(
                            songs.map((e) => e.toSong()).toList(),
                            i,
                          ),
                      onMoreTap: () {},
                    );
                  },
                );
              },
            ),
    );
  }
}
