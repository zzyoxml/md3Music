import '../../core/layout/page_layout.dart';
import '../../core/layout/adaptive_navigator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/listen_stats_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';
import 'listen_stats_page.dart';

/// 听歌排行页面（云端实现）。
///
/// 数据来源：**云端播放历史 `/user/history` 聚合派生**（见 [ListenStatsProvider]）
/// —— 最近一周 = 历史中 7 天窗口内曲目按累计次数排序；全部累计 = 全部历史
/// 曲目按累计次数排序。[type] 与既有 UI 的「最近一周 / 全部累计」切换一一对应。
///
/// 不再使用 listenservice 榜单（`/user/listen`）：2026-10-11 实机核对确认其
/// 不消费 `/playhistory/upload` 上传（周榜恒空、快照停在 2024 年），
/// 而播放历史为同一写入路径、天然含官方 App 的跨设备收听记录。
class ListenRankingPage extends StatefulWidget {
  const ListenRankingPage({super.key});

  @override
  State<ListenRankingPage> createState() => _ListenRankingPageState();
}

class _ListenRankingPageState extends State<ListenRankingPage> {
  int _currentType = 0; // 0=最近一周, 1=全部累计

  @override
  void initState() {
    super.initState();
    // postFrame 延迟（同 PlayHistoryPage）：避免 loadRanking 首个
    // notifyListeners 落在首帧 build 期间。
    // force：进页强制刷新（排行由历史聚合派生，provider 缓存不 force 会看到旧数据）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ignore: discarded_futures
      context.read<ListenStatsProvider>().loadRanking(_currentType, force: true);
    });
  }

  void _switchType(int type) {
    if (_currentType == type) return;
    setState(() => _currentType = type);
    // ignore: discarded_futures
    context.read<ListenStatsProvider>().loadRanking(type);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌排行'),
        actions: [
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: '听歌统计',
            onPressed: () {
              AdaptiveNav.openDetail(context, (_) => const ListenStatsPage());
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('最近一周')),
                M3EToggleButtonGroupAction(label: Text('全部累计')),
              ],
              selectedIndex: _currentType,
              onSelectedIndexChanged: (index) {
                if (index != null) _switchType(index);
              },
            ),
          ),
        ),
      ),
      body: ContentWidth(
        child: SecondaryMiniPlayerHost(
          child: _buildBody(cs),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    final loggedIn = context.watch<KugouProvider>().isLoggedIn;
    final stats = context.watch<ListenStatsProvider>();
    if (!loggedIn) return _buildNotLoggedIn(cs);
    if (!stats.isRankingLoaded(_currentType) &&
        stats.isLoadingRanking(_currentType)) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (stats.rankingError(_currentType) != null &&
        stats.rankingSongs(_currentType).isEmpty) {
      return _buildErrorRetry(
        cs,
        () => stats.loadRanking(_currentType, force: true),
      );
    }
    final songs = stats.rankingSongs(_currentType);
    if (songs.isEmpty) return _buildEmpty(cs);
    return Column(
      children: [
        _buildHeader(cs, songs),
        Expanded(
          child: Md3PullToRefresh(
            onRefresh: () => stats.loadRanking(_currentType, force: true),
            child: ListView.builder(
              // 内容不满一屏时也能下拉（M3E 指示器依赖 overscroll）
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                return _buildRankingItem(context, songs, index, cs);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme cs, List<KugouRankedSong> songs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${songs.length} 首',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (songs.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                final list = songs.map((r) => r.song).toList();
                context.read<PlayerProvider>().playOnlinePlaylist(list, 0);
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
        ],
      ),
    );
  }

  Widget _buildRankingItem(
    BuildContext context,
    List<KugouRankedSong> songs,
    int index,
    ColorScheme cs,
  ) {
    final ranked = songs[index];
    final song = ranked.song;
    final rank = index + 1;

    // 前三名使用特殊颜色
    Color? rankColor;
    if (rank == 1) rankColor = Colors.amber;
    if (rank == 2) rankColor = Colors.grey[400];
    if (rank == 3) rankColor = Colors.brown[300];

    return InkWell(
      onTap: () {
        final list = songs.map((r) => r.song).toList();
        context.read<PlayerProvider>().playOnlinePlaylist(list, index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // 排名
            SizedBox(
              width: 40,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: rank <= 3 ? 18 : 14,
                  fontWeight: rank <= 3 ? FontWeight.bold : FontWeight.normal,
                  color: rankColor ?? cs.onSurfaceVariant,
                ),
              ),
            ),
            // 歌曲信息
            Expanded(
              child: SongListItem(
                song: song,
                onTap: () {
                  final list = songs.map((r) => r.song).toList();
                  context.read<PlayerProvider>().playOnlinePlaylist(list, index);
                },
                onMoreTap: () {},
              ),
            ),
            // 云端播放次数（响应未提供时不显示）
            if (ranked.playCount != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${ranked.playCount}次',
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

  Widget _buildNotLoggedIn(ColorScheme cs) {
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
            '登录后可查看云端听歌排行',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorRetry(ColorScheme cs, VoidCallback onRetry) {
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
            '排行加载失败',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bar_chart,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            _currentType == 0 ? '最近一周暂无听歌记录' : '暂无听歌记录',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
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
}
