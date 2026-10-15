import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/music_folder.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/listen_together_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

class FoldersPage extends StatefulWidget {
  final List<MusicFolder> folders;

  const FoldersPage({super.key, required this.folders});

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _removing = false;

  @override
  void didUpdateWidget(covariant FoldersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = widget.folders.map((folder) => folder.path).toSet();
    _selected.removeWhere((path) => !visible.contains(path));
    if (visible.isEmpty) _selecting = false;
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  Future<void> _removeSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除 ${_selected.length} 个文件夹？'),
        content: const Text(
          '仅移除本地音乐索引，文件夹及其歌曲将不再显示，也不会被重新扫描加入。设备上的音频文件会保留，可通过加号重新添加文件夹。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除索引'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    try {
      await context.read<LibraryProvider>().removeFoldersFromIndex(_selected);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      showToast('已移除文件夹索引，音频文件已保留');
    } catch (_) {
      if (mounted) showToast('移除失败，请重试');
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.folders;
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                _selecting
                    ? '已选 ${_selected.length} 个'
                    : '${folders.length} 个文件夹',
              ),
              const Spacer(),
              if (_selecting) ...[
                TextButton(
                  onPressed: _removing
                      ? null
                      : () => setState(() {
                          if (_selected.length == folders.length) {
                            _selected.clear();
                          } else {
                            _selected.addAll(
                              folders.map((folder) => folder.path),
                            );
                          }
                        }),
                  child: Text(
                    _selected.length == folders.length ? '取消全选' : '全选',
                  ),
                ),
                IconButton(
                  tooltip: '移除所选文件夹索引',
                  onPressed: _selected.isEmpty || _removing
                      ? null
                      : _removeSelected,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
              TextButton(
                onPressed: _removing
                    ? null
                    : () => setState(() {
                        _selecting = !_selecting;
                        _selected.clear();
                      }),
                child: Text(_selecting ? '完成' : '多选'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ContentEntrance(
            child: AdaptiveContentGrid(
              targetExtent: 320,
              childAspectRatio: 4,
              itemCount: folders.length,
              itemBuilder: (context, index) {
                final folder = folders[index];
                return ListTile(
                  // tv: 长按进入多选不接 D-pad（TV 多选经顶栏「多选」按钮进入，
                  // ListTile 本身原生可聚焦、OK=打开/切换勾选）
                  leading: _selecting
                      ? Checkbox(
                          value: _selected.contains(folder.path),
                          onChanged: _removing
                              ? null
                              : (_) => _toggle(folder.path),
                        )
                      : const Icon(Icons.folder),
                  title: Text(
                    folder.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${folder.songCount} 首歌曲'),
                  trailing: _selecting ? null : const Icon(Icons.chevron_right),
                  onLongPress: _removing
                      ? null
                      : () => setState(() {
                          _selecting = true;
                          _selected.add(folder.path);
                        }),
                  onTap: _removing
                      ? null
                      : () {
                          if (_selecting) {
                            _toggle(folder.path);
                            return;
                          }
                          // 清除搜索框及其焦点历史，避免详情返回时恢复焦点弹出输入法。
                          FocusManager.instance.primaryFocus?.unfocus();
                          FocusManager.instance.applyFocusChangesIfNeeded();
                          AdaptiveNav.openDetail(
                            context,
                            (_) => FolderSongsPage(folder: folder),
                          );
                        },
                );
              },
            ),
          ),
        ),
      ],
    );
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
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      body: SecondaryMiniPlayerHost(
        child: songs.isEmpty
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${songs.length} 首歌曲',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.shuffle),
                          tooltip: '随机播放',
                          onPressed: () {
                            if (_blockedByRoomOwnership(context)) return;
                            final shuffled = List<Song>.from(songs)..shuffle();
                            context.read<PlayerProvider>().playPlaylist(
                              shuffled,
                              0,
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
                            if (_blockedByRoomOwnership(context)) return;
                            context.read<PlayerProvider>().playPlaylist(
                              songs,
                              index,
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
