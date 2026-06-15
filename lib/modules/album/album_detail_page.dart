import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchAlbum());
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
                        slivers: [
                          SliverAppBar(
                            expandedHeight: 280,
                            pinned: true,
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
