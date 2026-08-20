import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/history_repository.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

/// 听歌排行页面（本地实现）
///
/// 展示用户听歌历史排行，支持切换"最近一周"和"全部累计"。
/// 数据来源：本地 HistoryRepository 的播放次数统计。
class ListenRankingPage extends StatefulWidget {
  const ListenRankingPage({super.key});

  @override
  State<ListenRankingPage> createState() => _ListenRankingPageState();
}

class _ListenRankingPageState extends State<ListenRankingPage> {
  List<RankedSong> _rankedSongs = [];
  bool _isLoading = true;
  int _currentType = 0; // 0=最近一周, 1=全部累计

  @override
  void initState() {
    super.initState();
    _loadRanking();
  }

  Future<void> _loadRanking() async {
    setState(() => _isLoading = true);

    final ranked = await HistoryRepository().getRankedSongs(
      recentDays: _currentType == 0 ? 7 : null,
    );

    if (!mounted) return;
    setState(() {
      _rankedSongs = ranked;
      _isLoading = false;
    });
  }

  void _switchType(int type) {
    if (_currentType == type) return;
    setState(() => _currentType = type);
    _loadRanking();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌排行'),
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
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _rankedSongs.isEmpty
              ? _buildEmpty(cs)
              : Column(
                  children: [
                    _buildHeader(cs),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _rankedSongs.length,
                        itemBuilder: (context, index) {
                          return _buildRankingItem(context, index, cs);
                        },
                      ),
                    ),
                    const MiniPlayer(),
                  ],
                ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${_rankedSongs.length} 首',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (_rankedSongs.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                final songs = _rankedSongs.map((r) => r.song).toList();
                context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
        ],
      ),
    );
  }

  Widget _buildRankingItem(BuildContext context, int index, ColorScheme cs) {
    final ranked = _rankedSongs[index];
    final song = ranked.song;
    final rank = index + 1;

    // 前三名使用特殊颜色
    Color? rankColor;
    if (rank == 1) rankColor = Colors.amber;
    if (rank == 2) rankColor = Colors.grey[400];
    if (rank == 3) rankColor = Colors.brown[300];

    return InkWell(
      onTap: () {
        final songs = _rankedSongs.map((r) => r.song).toList();
        context.read<PlayerProvider>().playOnlinePlaylist(songs, index);
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
                  final songs = _rankedSongs.map((r) => r.song).toList();
                  context.read<PlayerProvider>().playOnlinePlaylist(songs, index);
                },
                onMoreTap: () {},
              ),
            ),
            // 播放次数
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
            '播放歌曲后会自动记录',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
