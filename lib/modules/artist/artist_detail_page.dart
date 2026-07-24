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

  /// 滚动监听：用于 SliverAppBar pinned 后 fade-in 显示歌手名
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchArtistSongs();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：减少无意义 setState，仅在偏移变化超过 1px 时更新
  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _lastReportedOffset).abs() > 1.0) {
      _lastReportedOffset = offset;
      _scrollOffset = offset;
      setState(() {});
    }
  }

  Future<void> _fetchArtistSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = KugouApiClient();

      // 并行获取歌手详情和歌曲
      final detailFuture = api.getArtistDetail(widget.artistId);
      final songsFuture = api.getArtistAudios(widget.artistId);

      final results = await Future.wait([detailFuture, songsFuture]);
      if (!mounted) return;

      final detail = results[0] as KugouArtistDetail?;
      final songsResult = results[1] as KugouArtistAudios?;

      // 获取歌手简介
      if (detail != null && detail.description != null && detail.description!.isNotEmpty) {
        _description = detail.description;
      }

      if (songsResult != null && songsResult.songs.isNotEmpty) {
        setState(() {
          _songs = songsResult.songs.map((s) => s.toSong()).toList();
          _isLoading = false;
        });
        return;
      }

      // API 返回空或失败，尝试通过搜索获取该歌手的歌曲
      final searchResult = await api.search(widget.artistName, type: 'song');
      if (!mounted) return;

      if (searchResult != null && searchResult.songs.isNotEmpty) {
        final artistNameLower = widget.artistName.toLowerCase();
        final artistSongs = searchResult.songs.where((s) {
          final songArtist = s.artistName?.toLowerCase() ?? '';
          return songArtist.contains(artistNameLower) ||
              artistNameLower.contains(songArtist);
        }).toList();
        setState(() {
          _songs = artistSongs.map((s) => s.toSong()).toList();
          _isLoading = false;
        });
      } else {
        setState(() {
          _songs = [];
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
                  controller: _scrollController,
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 180,
                      pinned: true,
                      centerTitle: false,
                      // pinned 后顶栏背景色：滚动到 expandedHeight - kToolbarHeight
                      // 之后从透明渐变到 surface
                      backgroundColor: Color.lerp(
                        Colors.transparent,
                        colorScheme.surface,
                        (_scrollOffset - (180 - kToolbarHeight))
                            .clamp(0.0, 60.0) / 60,
                      )!,
                      surfaceTintColor: Colors.transparent,
                      scrolledUnderElevation: 0,
                      // pinned 后顶栏标题：滚动超过阈值后 fade-in 显示歌手名
                      title: Opacity(
                        opacity: ((_scrollOffset - (180 - kToolbarHeight)) /
                                60.0)
                            .clamp(0.0, 1.0),
                        child: Text(
                          widget.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      flexibleSpace: FlexibleSpaceBar(
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
                          child: SafeArea(
                            bottom: false,
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: Row(
                                children: [
                                  avatarUrl != null
                                      ? ClipOval(
                                          child: CachedNetworkImage(
                                            imageUrl: avatarUrl,
                                            width: 100,
                                            height: 100,
                                            fit: BoxFit.cover,
                                            placeholder: (_, _) => Container(
                                              width: 100,
                                              height: 100,
                                              color: colorScheme.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.person,
                                                size: 40,
                                                color: colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                            errorWidget: (_, _, _) => Container(
                                              width: 100,
                                              height: 100,
                                              color: colorScheme.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.person,
                                                size: 40,
                                                color: colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        )
                                      : Container(
                                          width: 100,
                                          height: 100,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: colorScheme.surfaceContainerHighest,
                                          ),
                                          child: Icon(
                                            Icons.person,
                                            size: 40,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.artistName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (_songs.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            '${_songs.length} 首歌曲',
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
