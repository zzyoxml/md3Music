import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class ArtistDetailPage extends StatefulWidget {
  final String artistId;
  final String artistName;
  final String? avatarUrl;

  const ArtistDetailPage({
    super.key,
    required this.artistId,
    required this.artistName,
    this.avatarUrl,
  });

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;
  bool _isFollowing = false;
  String? _description;
  bool _isDescriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchArtistSongs();
    });
  }

  Future<void> _fetchArtistSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = KugouApiClient();
      final artistId = widget.artistId;
      final artistName = widget.artistName;

      // 并行获取歌手详情和第一页歌曲，避免首次加载等待
      const batchSize = 30;
      const maxPages = 200;
      final detailFuture = api.getArtistDetail(artistId);
      final firstPageFuture = api.getArtistAudios(
        artistId,
        page: 1,
        pagesize: batchSize,
        noCache: true,
      );

      final initial = await Future.wait([detailFuture, firstPageFuture]);
      if (!mounted) return;

      final detail = initial[0] as KugouArtistDetail?;
      final firstPage = initial[1] as KugouArtistAudios?;

      // 获取歌手简介
      if (detail != null &&
          detail.description != null &&
          detail.description!.isNotEmpty) {
        _description = detail.description;
      }

      // 自动分页拉取该歌手全部歌曲
      final allSongs = <KugouSongDetail>[];
      if (firstPage != null && firstPage.songs.isNotEmpty) {
        allSongs.addAll(firstPage.songs);
        final total = firstPage.total;

        // 如果API返回了有效的total，使用它；否则持续拉取直到没有更多数据
        final targetTotal = (total > 0) ? total : 999999;

        // 继续拉取后续页面
        int currentPage = 2;
        while (allSongs.length < targetTotal && currentPage <= maxPages) {
          final pageResult = await api.getArtistAudios(
            artistId,
            page: currentPage,
            pagesize: batchSize,
            noCache: true,
          );

          // 如果返回空或出错，停止拉取
          if (pageResult == null || pageResult.songs.isEmpty) break;

          allSongs.addAll(pageResult.songs);

          // 如果返回的歌曲数少于请求的数量，说明已经是最后一页
          if (pageResult.songs.length < batchSize) break;

          currentPage++;
        }
      }

      // 如果API返回的歌曲数量明显少于预期（可能是分页失效），用搜索补充
      final apiSongCount = allSongs.length;
      final expectedTotal = (firstPage?.total ?? 0);
      final needSearchSupplement =
          apiSongCount == 0 || (expectedTotal > 0 && apiSongCount < expectedTotal);

      if (needSearchSupplement) {
        // 通过搜索补充该歌手的歌曲，用 artistId 精确匹配
        final searchSongs = await _searchArtistSongs(
          api,
          artistId,
          artistName,
        );
        if (!mounted) return;

        if (searchSongs.isNotEmpty) {
          // 用 hash 去重，合并搜索结果
          final existingHashes = allSongs.map((s) => s.hash).toSet();
          for (final song in searchSongs) {
            if (!existingHashes.contains(song.hash)) {
              allSongs.add(song);
              existingHashes.add(song.hash);
            }
          }
        }
      }

      setState(() {
        _songs = allSongs.map((s) => s.toSong()).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
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

  /// 将 http:// URL 转换为 https://
  String? _fixImageUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final avatarUrl = _fixImageUrl(widget.avatarUrl);

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError(context, colorScheme)
              : CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 200,
                      pinned: true,
                      centerTitle: true,
                      flexibleSpace: FlexibleSpaceBar(
                        centerTitle: true,
                        title: Text(
                          widget.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        background: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colorScheme.primaryContainer,
                                colorScheme.surface,
                              ],
                            ),
                          ),
                          child: Center(
                            child: avatarUrl != null
                                ? ClipOval(
                                    child: CachedNetworkImage(
                                      imageUrl: avatarUrl,
                                      width: 120,
                                      height: 120,
                                      fit: BoxFit.cover,
                                      placeholder: (_, _) => Container(
                                        width: 120,
                                        height: 120,
                                        color: colorScheme.surfaceContainerHighest,
                                        child: Icon(
                                          Icons.person,
                                          size: 48,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      errorWidget: (_, _, _) => Container(
                                        width: 120,
                                        height: 120,
                                        color: colorScheme.surfaceContainerHighest,
                                        child: Icon(
                                          Icons.person,
                                          size: 48,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  )
                                : Container(
                                    width: 120,
                                    height: 120,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colorScheme.surfaceContainerHighest,
                                    ),
                                    child: Icon(
                                      Icons.person,
                                      size: 48,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _songs.isNotEmpty
                                    ? () {
                                        context
                                            .read<PlayerProvider>()
                                            .playOnlinePlaylist(_songs, 0);
                                      }
                                    : null,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('播放全部'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _songs.isNotEmpty
                                    ? () {
                                        final shuffled = List<Song>.from(_songs)
                                          ..shuffle();
                                        context
                                            .read<PlayerProvider>()
                                            .playOnlinePlaylist(shuffled, 0);
                                      }
                                    : null,
                                icon: const Icon(Icons.shuffle),
                                label: const Text('随机播放'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 歌手介绍（默认折叠，带动画）
                    if (_description != null && _description!.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _isDescriptionExpanded = !_isDescriptionExpanded;
                              });
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.info_outline,
                                        size: 16,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '歌手介绍',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge
                                            ?.copyWith(
                                              color: colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                      const Spacer(),
                                      AnimatedRotation(
                                        turns: _isDescriptionExpanded ? 0.5 : 0,
                                        duration: const Duration(milliseconds: 200),
                                        child: Icon(
                                          Icons.keyboard_arrow_down,
                                          size: 20,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeInOut,
                                    alignment: Alignment.topCenter,
                                    clipBehavior: Clip.hardEdge,
                                    child: Text(
                                      _description!,
                                      maxLines: _isDescriptionExpanded ? null : 2,
                                      overflow: _isDescriptionExpanded
                                          ? null
                                          : TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                            height: 1.5,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_songs.isEmpty)
                      SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.music_off,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无歌曲',
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            return SongListItem(
                              song: _songs[index],
                              onTap: () {
                                context.read<PlayerProvider>().playOnlinePlaylist(
                                      _songs,
                                      index,
                                    );
                              },
                              onMoreTap: () {},
                            );
                          },
                          childCount: _songs.length,
                        ),
                      ),
                  ],
                ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
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
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
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
