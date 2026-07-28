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
  // 排序方向：true=倒序(Z→A)，false=正序(A→Z)
  bool _sortDescending = false;
  final ScrollController _scrollController = ScrollController();
  // SongListItem 行高安全估计：封面 52 + padding(6+6)=12 + 行间留白 ≈ 76。
  // 这里使用 const 而不是 const 表达式，避免运行时计算。
  static const double _itemHeight = 76.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<Song> get _sortedSongs {
    final songs = List<Song>.from(widget.songs);
    // 统一的方向比较器：升序返回 a 与 b 的差；降序取反即可。
    int compare<T>(T a, T b, int Function(T, T) asc) {
      final result = asc(a, b);
      return _sortDescending ? -result : result;
    }

    switch (_sortBy) {
      case SongSortBy.title:
        songs.sort(
            (a, b) => compare(a.title, b.title, (x, y) => x.compareTo(y)));
        break;
      case SongSortBy.artist:
        songs.sort(
            (a, b) => compare(a.artist, b.artist, (x, y) => x.compareTo(y)));
        break;
      case SongSortBy.dateAdded:
        // 添加时间排序：原列表顺序视为添加顺序，倒序时整体反转
        if (_sortDescending) {
          return songs.reversed.toList();
        }
        break;
    }
    return songs;
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) {
        // 共用的单行选项组件：当前选中且方向匹配时显示箭头。
        Widget buildOption({
          required IconData icon,
          required String label,
          required SongSortBy type,
        }) {
          final isSelected = _sortBy == type;
          // 二次点击同一排序项：切换升/降序。
          return SimpleDialogOption(
            onPressed: () {
              setState(() {
                if (isSelected) {
                  // 同一排序项再次点击 → 切换方向
                  _sortDescending = !_sortDescending;
                } else {
                  // 切换到新的排序项 → 重置为正序
                  _sortBy = type;
                  _sortDescending = false;
                }
              });
              Navigator.pop(context);
            },
            child: Row(
              children: [
                Icon(
                  icon,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                  ),
                ),
                if (isSelected)
                  Icon(
                    _sortDescending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 18,
                  ),
              ],
            ),
          );
        }

        return SimpleDialog(
          title: const Text('排序方式'),
          children: [
            buildOption(
              icon: Icons.sort_by_alpha,
              label: '按标题',
              type: SongSortBy.title,
            ),
            buildOption(
              icon: Icons.person,
              label: '按歌手',
              type: SongSortBy.artist,
            ),
            buildOption(
              icon: Icons.schedule,
              label: '按添加时间',
              type: SongSortBy.dateAdded,
            ),
            // 提示：再次点击当前项可切换方向
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                '再次点击当前选项可切换升序/降序',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
    final player = context.watch<PlayerProvider>();
    final currentId = player.currentSong?.id;
    final currentIndex = (currentId == null || songs.isEmpty)
        ? -1
        : songs.indexWhere((s) => s.id == currentId);
    final canLocate =
        currentIndex >= 0 && _scrollController.hasClients;

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
                icon: const Icon(Icons.my_location),
                tooltip: '定位当前播放',
                onPressed: canLocate
                    ? () {
                        final target = (currentIndex * _itemHeight) -
                            MediaQuery.of(context).size.height * 0.4;
                        _scrollController.animateTo(
                          target.clamp(
                              0.0,
                              _scrollController.position
                                  .maxScrollExtent),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    : null,
              ),
              IconButton(
                icon: Icon(
                  // 排序按钮上根据当前方向显示箭头标识
                  _sortDescending
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                ),
                tooltip: '排序',
                onPressed: _showSortDialog,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
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
