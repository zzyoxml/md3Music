import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';

class PlaylistPage extends StatelessWidget {
  final Playlist playlist;

  const PlaylistPage({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: CustomScrollView(
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
                            child: playlist.artworkUri != null
                                ? CachedNetworkImage(
                                    imageUrl: playlist.artworkUri!,
                                    fit: BoxFit.cover,
                                    placeholder: (_, _) => Container(
                                      color: colorScheme.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.queue_music,
                                        size: 48,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    errorWidget: (_, _, _) => Container(
                                      color: colorScheme.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.queue_music,
                                        size: 48,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: colorScheme.surfaceContainerHighest,
                                    child: Icon(
                                      Icons.queue_music,
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
                                playlist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (playlist.description != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  playlist.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                '${playlist.creator ?? ''} · ${playlist.songCount} 首',
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
                        if (playlist.songs.isNotEmpty) {
                          context
                              .read<PlayerProvider>()
                              .playPlaylist(playlist.songs, 0);
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
                        if (playlist.songs.isNotEmpty) {
                          final shuffled = List<Song>.from(playlist.songs)
                            ..shuffle();
                          context
                              .read<PlayerProvider>()
                              .playPlaylist(shuffled, 0);
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
                  song: playlist.songs[index],
                  onTap: () {
                    context
                        .read<PlayerProvider>()
                        .playPlaylist(playlist.songs, index);
                  },
                  onMoreTap: () {},
                );
              },
              childCount: playlist.songs.length,
            ),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: 80),
          ),
        ],
      ),
    );
  }
}
