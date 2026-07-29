import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/artist.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/artist_tile.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';

class ArtistsPage extends StatelessWidget {
  final List<Artist> artists;

  const ArtistsPage({super.key, required this.artists});

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return Center(
        child: Text(
          '暂无歌手',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ContentEntrance(
      child: ListView.builder(
      itemCount: artists.length,
      itemBuilder: (context, index) {
        return ArtistTile(
          artist: artists[index],
          onTap: () {
            final library = context.read<LibraryProvider>();
            final songs = library.getSongsByArtist(artists[index].name);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ArtistSongsPage(
                  artist: artists[index],
                  songs: songs,
                ),
              ),
            );
          },
        );
      },
    ));
  }
}

class ArtistSongsPage extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;

  const ArtistSongsPage({
    super.key,
    required this.artist,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          artist.name,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
      body: songs.isEmpty
          ? Center(
              child: Text(
                '此歌手暂无歌曲',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        '${songs.length} 首歌曲 · ${artist.albumCount} 张专辑',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.shuffle),
                        tooltip: '随机播放',
                        onPressed: () {
                          final shuffled = List<Song>.from(songs)..shuffle();
                          context.read<PlayerProvider>().playPlaylist(shuffled, 0);
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      return SongListItem(
                        song: songs[index],
                        onTap: () {
                          context
                              .read<PlayerProvider>()
                              .playPlaylist(songs, index);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
