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
  // 定位目标项的索引与 GlobalKey：滚到位后用 ensureVisible 精确对齐。
  GlobalKey? _targetItemKey;
  int _targetScrollIndex = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 定位当前播放歌曲并在视口中居中。
  ///
  /// 行高不是常量：SongListItem 的高度取封面（52）与文字列（随 uiScale
  /// 0.5~2.0 变化）中较高者，故不能用固定值换算偏移。这里改为从
  /// ScrollPosition 反推实测行高——本列表所有项等高，此时 Flutter 对
  /// SliverChildBuilderDelegate 的 extent 估算恰好精确——再用 GlobalKey +
  /// ensureVisible 做最终对齐，消除任何残余偏差。
  Future<void> _scrollToCurrentSong(int index) async {
    if (!_scrollController.hasClients) return;

    setState(() {
      // 每次定位新建 GlobalKey，避免旧 key 残留导致重复 GlobalKey 冲突
      _targetItemKey = GlobalKey();
      _targetScrollIndex = index;
    });
    // 等一帧让 GlobalKey 挂到目标项上（目标项已在视口内时可直接命中）
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;

    final pos = _scrollController.position;
    final viewport = pos.viewportDimension;
    // 实测行高：内容总高 ÷ 项数（ListView 无 padding，所有项等高）
    final rowHeight = (pos.maxScrollExtent + viewport) / widget.songs.length;
    // 让目标项落在视口正中，而非按屏幕高度取比例
    final target = index * rowHeight - (viewport - rowHeight) / 2;
    await _scrollController.animateTo(
      target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;

    // 滚动后目标项已构建：精确居中
    final targetContext = _targetItemKey?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    }
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
    // hasClients 在首帧 build 时必为 false，不能作为按钮可用性的依据，
    // 否则定位按钮会先显示为禁用；该检查已移入 _scrollToCurrentSong。
    final canLocate = currentIndex >= 0;

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
                    ? () => _scrollToCurrentSong(currentIndex)
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
                // 定位目标项挂 GlobalKey，供 ensureVisible 精确对齐
                key: index == _targetScrollIndex ? _targetItemKey : null,
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
