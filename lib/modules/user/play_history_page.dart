import '../../core/layout/page_layout.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../data/repositories/history_repository.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/listen_stats_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';

/// 播放历史页：双数据源 Tab。
///
/// - **云端历史**（默认）：/user/history 拉取的云端播放记录（跨设备同步，
///   由 PlayHistorySyncService 在播放在线歌曲时写入），支持 bp 游标翻页；
/// - **本地歌曲**：本机 HistoryRepository 中「无云端身份」的本地文件歌曲
///   播放记录（在线歌曲的记录已统一走云端，这里不再重复展示）。
///
/// 私有构建注入的筛选/扩展钩子仅作用于本地 Tab（云端列表是只读的服务端记录）。
class PlayHistoryPage extends StatefulWidget {
  /// 可选扩展：对本地显示列表应用变换（默认关闭，由私有构建注入，用于筛选等）。
  /// [pageKey] 为页面标识（'history'），供私有状态按页隔离。
  static List<Song> Function(String pageKey, List<Song> songs)? songFilterHook;
  /// 可选扩展：筛选状态变更的监听信号（默认关闭，由私有构建注入，
  /// 用于筛选按钮切换后触发本页重建）。
  static Listenable? songFilterListenable;
  /// 可选扩展：顶栏额外操作按钮（默认关闭，由私有构建注入；仅本地 Tab 显示）。
  static List<Widget> Function(BuildContext context)? extraAppBarActionsBuilder;

  const PlayHistoryPage({super.key});

  @override
  State<PlayHistoryPage> createState() => _PlayHistoryPageState();
}

class _PlayHistoryPageState extends State<PlayHistoryPage> {
  /// 数据源：0 = 云端历史（默认），1 = 本地歌曲。
  int _source = 0;

  // ---- 本地列表（HistoryRepository，仅本地歌曲）----
  List<Song> _localSongs = [];
  Map<String, int> _localPlayCounts = const {};
  bool _localLoading = true;

  /// 多选编辑模式（仅本地 Tab；与播放列表页/歌单页同一套心智模型）：
  /// 进入后顶栏变为「✕ / 已选 N 首 / 全选 / 删除」，歌曲项显示圆形复选框。
  bool _editMode = false;
  final Set<String> _selectedIds = {};

  List<Song> get _displayLocalSongs {
    final filter = PlayHistoryPage.songFilterHook;
    if (filter == null) return _localSongs;
    return filter('history', _localSongs);
  }

  @override
  void initState() {
    super.initState();
    _loadLocalHistory();
    // 云端历史首拉（未登录时 provider 内部仍会请求失败，页面有未登录空态兜底）。
    // postFrame 延迟：loadHistory 首个 notifyListeners 同步发生，直接在
    // initState 调会在首帧 build 期间 markNeedsBuild 抛异常。
    // force：进页强制刷新——provider 会缓存结果，不强制的话上传了新的
    // 播放记录再进页也看不到（历史页语义要求「进来即最新」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ignore: discarded_futures
      context.read<ListenStatsProvider>().loadHistory(force: true);
    });
  }

  Future<void> _loadLocalHistory() async {
    final repo = HistoryRepository();
    final results = await Future.wait([
      repo.getHistory(),
      repo.getPlayCounts(),
    ]);
    if (!mounted) return;
    setState(() {
      // 本地 Tab 仅显示本地歌曲（在线歌曲的播放记录统一走云端历史）
      final all = results[0] as List<Song>;
      _localSongs = all.where((s) => !s.isOnline).toList();
      _localPlayCounts = results[1] as Map<String, int>;
      _localLoading = false;
    });
  }

  void _switchSource(int index) {
    if (index == _source) return;
    setState(() {
      _source = index;
      // 退出编辑模式：多选只属于本地 Tab
      _editMode = false;
      _selectedIds.clear();
    });
    if (index == 1) {
      // 每次切回本地都重读：期间可能有新的本地歌曲播放记录
      _loadLocalHistory();
    }
  }

  void _enterEditMode([String? songId]) {
    setState(() {
      _editMode = true;
      if (songId != null) _selectedIds.add(songId);
    });
  }

  void _exitEditMode() {
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String songId) {
    setState(() {
      if (!_selectedIds.remove(songId)) _selectedIds.add(songId);
    });
  }

  void _toggleSelectAll(List<Song> songs) {
    setState(() {
      if (_selectedIds.length == songs.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(songs.map((s) => s.id));
      }
    });
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌曲'),
        content: Text('确定从播放历史中删除选中的 $count 首歌曲吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await HistoryRepository().removeIds(Set.of(_selectedIds));
      if (mounted) _exitEditMode();
      await _loadLocalHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 可选扩展：筛选/变换状态变更时重建本页（默认监听空信号，无额外开销）
    return ListenableBuilder(
      listenable: PlayHistoryPage.songFilterListenable ??
          const AlwaysStoppedAnimation<Object?>(null),
      builder: (context, _) {
        // 在 builder 内计算：筛选状态变化时重新过滤（build 外计算会被闭包捕获旧值）
        final displaySongs = _displayLocalSongs;
        final editingLocal = _editMode && _source == 1;
        final allSelected =
            displaySongs.isNotEmpty &&
            _selectedIds.length == displaySongs.length;
        return Scaffold(
      appBar: AppBar(
        leading: editingLocal
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitEditMode,
              )
            : null,
        title: Text(editingLocal ? '已选 ${_selectedIds.length} 首' : '播放历史'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('云端历史')),
                M3EToggleButtonGroupAction(label: Text('本地歌曲')),
              ],
              selectedIndex: _source,
              onSelectedIndexChanged: (index) {
                if (index != null) _switchSource(index);
              },
            ),
          ),
        ),
        actions: editingLocal
            // 编辑模式顶栏：全选 / 删除（与播放列表页、歌单页多选顶栏一致）
            ? [
                TextButton(
                  onPressed: displaySongs.isEmpty
                      ? null
                      : () => _toggleSelectAll(displaySongs),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                TextButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : _confirmDeleteSelected,
                  child: Text(
                    '删除',
                    style: TextStyle(
                      color: _selectedIds.isEmpty
                          ? Theme.of(context).disabledColor
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ]
            : _source == 1
            ? [
                // 可选扩展：私有构建注入的额外操作按钮（仅本地 Tab，默认无）
                ...?PlayHistoryPage.extraAppBarActionsBuilder?.call(context),
                // 批量删除入口：进入多选编辑模式（保留「全选→删除」即清空全部）
                if (_localSongs.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: '批量删除',
                    onPressed: () => _enterEditMode(),
                  ),
              ]
            : const <Widget>[],
      ),
      body: ContentWidth(
            child: SecondaryMiniPlayerHost(
              child: _source == 0 ? _buildCloudBody() : _buildLocalBody(displaySongs),
            ),
        ),
        );
      },
    );
  }

  // ---- 云端历史 Tab ----

  Widget _buildCloudBody() {
    final loggedIn = context.watch<KugouProvider>().isLoggedIn;
    final stats = context.watch<ListenStatsProvider>();
    if (!loggedIn) return _buildCloudNotLoggedIn();
    if (!stats.historyLoaded && stats.historyLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (stats.historyError != null && stats.historyEntries.isEmpty) {
      return _buildErrorRetry(
        message: '云端历史加载失败',
        onRetry: () => stats.loadHistory(force: true),
      );
    }
    final entries = stats.historyEntries;
    if (entries.isEmpty) return _buildCloudEmpty();
    final itemCount = entries.length + (stats.historyHasMore ? 1 : 0);
    return Column(
      children: [
        _buildCloudHeader(entries.length, stats.historyHasMore),
        Expanded(
          child: Md3PullToRefresh(
            onRefresh: () => stats.loadHistory(force: true),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                // 滚动到接近底部时预取下一页（bp 游标翻页）
                if (notification.metrics.pixels >=
                        notification.metrics.maxScrollExtent - 400 &&
                    stats.historyHasMore &&
                    !stats.historyLoading) {
                  // ignore: discarded_futures
                  context.read<ListenStatsProvider>().loadMoreHistory();
                }
                return false;
              },
              child: ListView.builder(
                // 内容不满一屏时也能下拉（M3E 指示器依赖 overscroll）
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (index >= entries.length) {
                    return const Padding(
                      key: ValueKey('history-load-more'),
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: M3ELoadingIndicator(),
                        ),
                      ),
                    );
                  }
                  return _buildCloudItem(context, entries, index);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCloudHeader(int count, bool hasMore) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            hasMore ? '已加载 $count 条' : '共 $count 条',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            '播放记录已云端同步',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudItem(
    BuildContext context,
    List<KugouHistoryEntry> entries,
    int index,
  ) {
    final cs = Theme.of(context).colorScheme;
    final entry = entries[index];
    return InkWell(
      onTap: () {
        final songs = entries.map((e) => e.song).toList();
        context.read<PlayerProvider>().playOnlinePlaylist(songs, index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: SongListItem(
                song: entry.song,
                onTap: () {
                  final songs = entries.map((e) => e.song).toList();
                  context
                      .read<PlayerProvider>()
                      .playOnlinePlaylist(songs, index);
                },
                onMoreTap: () {},
              ),
            ),
            if (entry.timestampSec > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  _relativeTimeText(entry.timestampSec),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudNotLoggedIn() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '登录后可查看云端听歌历史',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '播放记录将自动同步，其他设备也可查看',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '云端暂无听歌记录',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '播放在线歌曲后会自动同步到云端',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 本地歌曲 Tab ----

  Widget _buildLocalBody(List<Song> displaySongs) {
    if (_localLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (displaySongs.isEmpty) return _buildLocalEmpty();
    return Column(
      children: [
        _buildHeader(displaySongs),
        Expanded(
          child: ListView.builder(
            itemCount: displaySongs.length,
            itemBuilder: (context, index) {
              final song = displaySongs[index];
              final playCount = _localPlayCounts[song.id] ?? 0;
              final cs = Theme.of(context).colorScheme;
              return Row(
                children: [
                  Expanded(
                    child: SongListItem(
                      song: song,
                      isSelectMode: _editMode,
                      isSelected: _selectedIds.contains(song.id),
                      onSelectToggle: () => _toggleSelect(song.id),
                      onLongPress: _editMode
                          ? null
                          : () => _enterEditMode(song.id),
                      onTap: () {
                        context.read<PlayerProvider>().playOnlinePlaylist(
                          displaySongs,
                          index);
                      },
                      onMoreTap: () {},
                    ),
                  ),
                  // 本地播放次数（本地歌曲不参与云端排行，这里补齐次数信息）
                  if (!_editMode && playCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '$playCount次',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLocalEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无本地歌曲播放记录',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '在线歌曲的播放记录请查看「云端历史」',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorRetry({
    required String message,
    required VoidCallback onRetry,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildHeader(List<Song> displaySongs) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${displaySongs.length} 首',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          if (displaySongs.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                context.read<PlayerProvider>().playOnlinePlaylist(
                  displaySongs,
                  0,
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
        ],
      ),
    );
  }
}

/// 相对时间展示（云端历史条目）：刚刚 / N 分钟前 / N 小时前 / 昨天 / 日期。
String _relativeTimeText(int timestampSec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampSec * 1000);
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24 && dt.day == now.day) return '${diff.inHours}小时前';
  final yesterday = now.subtract(const Duration(days: 1));
  if (dt.year == yesterday.year &&
      dt.month == yesterday.month &&
      dt.day == yesterday.day) {
    return '昨天';
  }
  if (dt.year == now.year) return '${dt.month}月${dt.day}日';
  return '${dt.year}年${dt.month}月${dt.day}日';
}
