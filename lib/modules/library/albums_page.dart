import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/grid_columns_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/album_card.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';

class AlbumsPage extends StatefulWidget {
  final List<Album> albums;

  const AlbumsPage({super.key, required this.albums});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  // 捏合手势的缩放基准：onScaleStart 时重置为 1.0，
  // 触发阈值后重置为当前 scale，避免一次捏合连续多次触发。
  double _scaleStart = 1.0;

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStart = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final ratio = details.scale / _scaleStart;
    if (ratio <= 0.8) {
      // 向内捏合（缩小）：增加列数
      context.read<GridColumnsProvider>().increment();
      _scaleStart = details.scale;
    } else if (ratio >= 1.2) {
      // 向外捏合（放大）：减少列数
      context.read<GridColumnsProvider>().decrement();
      _scaleStart = details.scale;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.albums.isEmpty) {
      return Center(
        child: Text(
          '暂无专辑',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ContentEntrance(
      child: LayoutBuilder(
      builder: (context, constraints) {
        // Pad 模式取用户捏合调整的列数；非 Pad 模式按屏幕宽度响应式适配
        final isPad = isPadLayout(context);
        // watch 以便列数变化时重建网格
        final gridColumns = context.watch<GridColumnsProvider>().gridColumns;

        int crossAxisCount;
        if (isPad) {
          // Pad 模式：使用用户捏合手势调整的列数偏好
          crossAxisCount = gridColumns;
        } else {
          // 手机端：保留原有屏幕宽度响应式逻辑
          final screenType = getScreenType(constraints.maxWidth);
          switch (screenType) {
            case ScreenType.compact:
              crossAxisCount = 2;
              break;
            case ScreenType.medium:
              crossAxisCount = 3;
              break;
            case ScreenType.expanded:
              crossAxisCount = 4;
          }
        }

        final gridView = GridView.builder(
          // 列数变化时让 AnimatedSwitcher 识别为新 child，触发淡入淡出过渡
          key: ValueKey(crossAxisCount),
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.72,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: widget.albums.length,
          itemBuilder: (context, index) {
            return AlbumCard(
              album: widget.albums[index],
              onTap: () {
                final library = context.read<LibraryProvider>();
                final songs = library.getSongsInAlbum(widget.albums[index].name);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AlbumSongsPage(
                      album: widget.albums[index],
                      songs: songs,
                    ),
                  ),
                );
              },
            );
          },
        );

        // 列数变化时淡入淡出过渡（约 250ms）
        final gridContent = AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: gridView,
        );

        // 非 Pad 模式不挂载捏合手势
        if (!isPad) {
          return gridContent;
        }

        // Pad 模式包裹捏合手势
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: gridContent,
        );
      },
    ));
  }
}

class AlbumSongsPage extends StatelessWidget {
  final Album album;
  final List<Song> songs;

  const AlbumSongsPage({
    super.key,
    required this.album,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          album.name,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
      body: songs.isEmpty
          ? Center(
              child: Text(
                '此专辑暂无歌曲',
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
