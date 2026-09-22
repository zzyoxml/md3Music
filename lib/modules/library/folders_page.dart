import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/music_folder.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/listen_together_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';

class FoldersPage extends StatelessWidget {
  final List<MusicFolder> folders;

  const FoldersPage({super.key, required this.folders});

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return Center(
        child: Text(
          '暂无文件夹',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ContentEntrance(
      child: ListView.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return ListTile(
          leading: const Icon(Icons.folder),
          title: Text(
            folder.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${folder.songCount} 首歌曲'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FolderSongsPage(folder: folder),
              ),
            );
          },
        );
      },
    ));
  }
}

class FolderSongsPage extends StatelessWidget {
  final MusicFolder folder;

  const FolderSongsPage({super.key, required this.folder});

  /// 一起听房主在房间里：本地音乐不能本地起播（与 SongsPage 同口径）。
  bool _blockedByRoomOwnership(BuildContext context) {
    final session = context.read<ListenTogetherProvider>().session;
    if (session == null || !session.isOwner) return false;
    showToast('当前是「一起听」房主，房间里只能播放房间歌单中的在线歌曲', long: true);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final songs = library.getSongsInFolder(folder.path);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          folder.displayName,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
      body: songs.isEmpty
          ? Center(
              child: Text(
                '此文件夹暂无歌曲',
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
                        '${songs.length} 首歌曲',
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
                          if (_blockedByRoomOwnership(context)) return;
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
                          if (_blockedByRoomOwnership(context)) return;
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
