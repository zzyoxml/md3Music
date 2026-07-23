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
      // 尝试使用 artistId 获取歌曲
      final result = await api.getArtistAudios(widget.artistId);
      if (!mounted) return;

      if (result != null && result.songs.isNotEmpty) {
        setState(() {
          _songs = result.songs.map((s) => s.toSong()).toList();
          _isLoading = false;
        });
        return;
      }

      // API 返回空或失败，尝试通过搜索获取该歌手的歌曲
      final searchResult = await api.search(widget.artistName, type: 'song');
      if (!mounted) return;

      if (searchResult != null && searchResult.songs.isNotEmpty) {
        // 过滤出该歌手的歌曲
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
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 200,
                      pinned: true,
                      flexibleSpace: FlexibleSpaceBar(
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
