import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../data/models/artist.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/artist_tile.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

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
      child: AdaptiveContentGrid(
      targetExtent: 300,
        childAspectRatio: 4,
        itemCount: artists.length,
      itemBuilder: (context, index) {
        return ArtistTile(
          artist: artists[index],
          onTap: () {
            final library = context.read<LibraryProvider>();
            final songs = library.getSongsByArtist(artists[index].name);
            // 清除搜索框焦点历史，避免从详情返回时自动弹出输入法。
            FocusManager.instance.primaryFocus?.unfocus();
            FocusManager.instance.applyFocusChangesIfNeeded();
            AdaptiveNav.openDetail(
              context,
              (_) => ArtistSongsPage(
                artist: artists[index],
                songs: songs),
            );
          },
        );
      },
    ),
    );
  }
}

class ArtistSongsPage extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;

  const ArtistSongsPage({
    super.key,
    required this.artist,
    required this.songs});

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
      body: SecondaryMiniPlayerHost(
        child: songs.isEmpty
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
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8,
                    ),
                  child: Row(
                    children: [
                      Text(
                        '${songs.length} 首歌曲 · ${artist.albumCount} 张专辑',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color:
                                  Theme.of(context,
                                ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.shuffle),
                        tooltip: '随机播放',
                        onPressed: () {
                          final shuffled = List<Song>.from(songs)..shuffle();
                          context.read<PlayerProvider>().playPlaylist(shuffled, 0,
                            );
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
                              .playPlaylist(songs, index,
                            );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
      ),
    );
  }
}
