import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/playlist_comments_view.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class AlbumDetailPage extends StatefulWidget {
  final Album album;

  const AlbumDetailPage({super.key, required this.album});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  bool _isLoading = true;
  List<Song> _songs = [];
  String? _error;
  KugouAlbumDetail? _albumDetail;

  // 顶栏 fade-in 用的滚动监听：与 playlist_page.dart 保持一致的实现风格
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchAlbum());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：阈值 0.5px 防抖，避免过度 setState。
  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _scrollOffset).abs() > 0.5) {
      setState(() => _scrollOffset = offset);
    }
  }

  Future<void> _fetchAlbum() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = KugouApiClient();
      final detailFuture = api.getAlbumDetail(widget.album.id);
      final songsFuture = api.getAlbumSongs(widget.album.id);

      final results = await Future.wait([detailFuture, songsFuture]);

      final detail = results[0] as KugouAlbumDetail?;
      final songsResult = results[1] as KugouAlbumSongs?;

      setState(() {
        _albumDetail = detail;
        _songs = songsResult?.songs.map((e) => e.toSong()).toList() ?? [];
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
    setState(() {
      _isLoading = false;
    });
  }

  void _showCommentsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          final colorScheme = Theme.of(context).colorScheme;
          return Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                // 拖动手柄
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 标题栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.comment_outlined,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '评论',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
                // 评论列表
                Expanded(
                  child: PlaylistCommentsView(
                    specialId: widget.album.id,
                    commentType: 'album',
                    scrollController: scrollController,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final displayAlbum = _albumDetail?.toAlbum() ?? widget.album;

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError(context, colorScheme)
              : Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        controller: _scrollController,
                        slivers: [
                          SliverAppBar(
                            expandedHeight: 280,
                            pinned: true,
                            // pinned 后顶栏背景色：滚动到 expandedHeight - kToolbarHeight
                            // 之后从透明渐变到 surface（与 playlist_page 一致）
                            backgroundColor: Color.lerp(
                              Colors.transparent,
                              colorScheme.surface,
                              (_scrollOffset - (280 - kToolbarHeight))
                                  .clamp(0.0, 60.0) / 60,
                            )!,
                            surfaceTintColor: Colors.transparent,
                            scrolledUnderElevation: 0,
                            actions: [
                              IconButton(
                                icon: const Icon(Icons.comment_outlined),
                                onPressed: () => _showCommentsSheet(context),
                                tooltip: '评论',
                              ),
                            ],
                            // pinned 后顶栏标题：滚动超过阈值后 fade-in 显示专辑名称
                            title: Opacity(
                              opacity: ((_scrollOffset - (280 - kToolbarHeight)) /
                                      60.0)
                                  .clamp(0.0, 1.0),
                              child: Text(
                                displayAlbum.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
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
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: SizedBox(
                                            width: 140,
                                            height: 140,
                                            child: displayAlbum.artworkUri != null
                                                ? CachedNetworkImage(
                                                    imageUrl: displayAlbum.artworkUri!,
                                                    fit: BoxFit.cover,
                                                    placeholder: (_, _) => Container(
                                                      color: colorScheme.surfaceContainerHighest,
                                                      child: Icon(
                                                        Icons.album,
                                                        size: 48,
                                                        color: colorScheme.onSurfaceVariant,
                                                      ),
                                                    ),
                                                    errorWidget: (_, _, _) => Container(
                                                      color: colorScheme.surfaceContainerHighest,
                                                      child: Icon(
                                                        Icons.album,
                                                        size: 48,
                                                        color: colorScheme.onSurfaceVariant,
                                                      ),
                                                    ),
                                                  )
                                                : Container(
                                                    color: colorScheme.surfaceContainerHighest,
                                                    child: Icon(
                                                      Icons.album,
                                                      size: 48,
                                                      color: colorScheme.onSurfaceVariant,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 20),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisAlignment: MainAxisAlignment.end,
                                            children: [
                                              Text(
                                                displayAlbum.name,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: textTheme.headlineSmall?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              if (displayAlbum.artist.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  displayAlbum.artist,
                                                  style: textTheme.bodyMedium?.copyWith(
                                                    color: colorScheme.onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 4),
                                              Text(
                                                '${_songs.length} 首歌曲',
                                                style: textTheme.labelMedium?.copyWith(
                                                  color: colorScheme.onSurfaceVariant,
                                                ),
                                              ),
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
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () {
                                        if (_songs.isNotEmpty) {
                                          context
                                              .read<PlayerProvider>()
                                              .playOnlinePlaylist(_songs, 0);
                                        }
                                      },
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('播放全部'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        if (_songs.isNotEmpty) {
                                          final shuffled = List<Song>.from(_songs)..shuffle();
                                          context
                                              .read<PlayerProvider>()
                                              .playOnlinePlaylist(shuffled, 0);
                                        }
                                      },
                                      icon: const Icon(Icons.shuffle),
                                      label: const Text('随机播放'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                return SongListItem(
                                  song: _songs[index],
                                  onTap: () {
                                    context
                                        .read<PlayerProvider>()
                                        .playOnlinePlaylist(_songs, index);
                                  },
                                  onMoreTap: () {},
                                );
                              },
                              childCount: _songs.length,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const MiniPlayer(),
                  ],
                ),
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
              onPressed: _fetchAlbum,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
