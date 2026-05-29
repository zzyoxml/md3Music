import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';

enum SongSortBy { title, artist, dateAdded }

class SongsPage extends StatefulWidget {
  final List<Song> songs;

  const SongsPage({super.key, required this.songs});

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  SongSortBy _sortBy = SongSortBy.title;

  List<Song> get _sortedSongs {
    final songs = List<Song>.from(widget.songs);
    switch (_sortBy) {
      case SongSortBy.title:
        songs.sort((a, b) => a.title.compareTo(b.title));
        break;
      case SongSortBy.artist:
        songs.sort((a, b) => a.artist.compareTo(b.artist));
        break;
      case SongSortBy.dateAdded:
        break;
    }
    return songs;
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('排序方式'),
          children: [
            SimpleDialogOption(
              onPressed: () {
                setState(() => _sortBy = SongSortBy.title);
                Navigator.pop(context);
              },
              child: Row(
                children: [
                  Icon(
                    Icons.sort_by_alpha,
                    color: _sortBy == SongSortBy.title
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '按标题',
                    style: TextStyle(
                      color: _sortBy == SongSortBy.title
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                setState(() => _sortBy = SongSortBy.artist);
                Navigator.pop(context);
              },
              child: Row(
                children: [
                  Icon(
                    Icons.person,
                    color: _sortBy == SongSortBy.artist
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '按歌手',
                    style: TextStyle(
                      color: _sortBy == SongSortBy.artist
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                setState(() => _sortBy = SongSortBy.dateAdded);
                Navigator.pop(context);
              },
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    color: _sortBy == SongSortBy.dateAdded
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '按添加时间',
                    style: TextStyle(
                      color: _sortBy == SongSortBy.dateAdded
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = _sortedSongs;

    if (songs.isEmpty) {
      return Center(
        child: Text(
          '暂无歌曲',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${songs.length} 首歌曲',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.shuffle),
                tooltip: '随机播放',
                onPressed: () {
                  if (songs.isNotEmpty) {
                    final shuffled = List<Song>.from(songs)..shuffle();
                    context.read<PlayerProvider>().playPlaylist(shuffled, 0);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.sort),
                tooltip: '排序',
                onPressed: _showSortDialog,
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
                  context.read<PlayerProvider>().playPlaylist(songs, index);
                },
                onMoreTap: () {},
              );
            },
          ),
        ),
      ],
    );
  }
}
