import 'package:material_ui/material_ui.dart';
import '../../widgets/app_empty_state.dart';
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/responsive_layout.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/grid_columns_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/album_card.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

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
      return const AppEmptyState.text(title: '暂无专辑');
    }

    return ContentEntrance(
      child: LayoutBuilder(
      builder: (context, constraints) {
        // Pad 模式取用户捏合调整的列数；非 Pad 模式按屏幕宽度响应式适配
        final isPad = isPadLayout(context);
        // watch 以便列数变化时重建网格
        final gridColumns = context.watch<GridColumnsProvider>().gridColumns;

        // **按目标卡宽算出的列数**才是基准：200dp 是专辑卡舒适宽度，
        // 1936px 窗口可得约 8 列。
        //
        // 原来两条分支都把列数锁死在很小的范围（Pad 走用户偏好、默认 4；
        // 非 Pad 的 expanded 档写死 4），1936px 下每格约 470×650 —— 一张
        // 专辑卡被拉到半屏高，封面里只有一个音符图标、大片空腔。
        // 现在宽度算出的值作为**下限**，用户捏合只允许在此基础上继续细调。
        final widthBased = gridColumnsForWidth(
          constraints.maxWidth,
          targetExtent: 200,
          min: 2,
          max: 12,
        );
        final crossAxisCount = isPad
            // Pad：用户偏好只能 ≥ 宽度基准（否则宽屏会被偏好值拉回 4 列）
            ? (gridColumns > widthBased ? gridColumns : widthBased)
                .clamp(2, 12)
            : widthBased;

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
                // 清除搜索框焦点历史，避免从详情返回时自动弹出输入法。
                FocusManager.instance.primaryFocus?.unfocus();
                FocusManager.instance.applyFocusChangesIfNeeded();
                AdaptiveNav.openDetail(
                  context,
                  (_) => AlbumSongsPage(
                    album: widget.albums[index],
                    songs: songs,
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
      body: SecondaryMiniPlayerHost(
        child: songs.isEmpty
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
      ),
    );
  }
}
