import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../data/models/song.dart';
import 'song_list_item.dart';

/// 与收藏页复用同一个排序组件，在原歌曲页内切换。
class PlaylistTrackOrderList extends StatelessWidget {
  final List<Song> songs;
  final bool enabled;
  final void Function(int from, int to) onReorder;

  const PlaylistTrackOrderList({
    super.key,
    required this.songs,
    required this.onReorder,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: AbsorbPointer(
      absorbing: !enabled,
      child: M3EReorderableDismissibleList(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: songs.length,
        keyBuilder: (index) => ValueKey(songs[index].fileId),
        onReorder: (from, to) {
          if (enabled) onReorder(from, to > from ? to - 1 : to);
        },
        style: M3EDismissibleCardStyle(
          outerRadius: 0,
          innerRadius: 0,
          gap: 0,
          padding: EdgeInsets.zero,
          color: Colors.transparent,
          direction: DismissDirection.none,
        ),
        itemBuilder: (context, index) => IgnorePointer(
          // 鼠标悬停和长按由外层 M3E 卡片处理，行内不响应播放或菜单。
          child: SongListItem(
            song: songs[index],
            trailingOverride: Icon(
              Icons.drag_indicator,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
        ),
      ),
    ),
  );
}
