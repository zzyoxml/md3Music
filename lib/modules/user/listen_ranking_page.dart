import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

/// 听歌历史排行页面
///
/// 展示用户听歌历史排行，支持切换"最近一周"和"全部累计"。
class ListenRankingPage extends StatefulWidget {
  const ListenRankingPage({super.key});

  @override
  State<ListenRankingPage> createState() => _ListenRankingPageState();
}

class _ListenRankingPageState extends State<ListenRankingPage> {
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;
  int _currentType = 0; // 0=最近一周, 1=全部累计

  @override
  void initState() {
    super.initState();
    _loadRanking();
  }

  Future<void> _loadRanking() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await KugouApiClient().getUserListenRanking(type: _currentType);
      if (!mounted) return;

      if (result == null) {
        setState(() {
          _error = '获取排行失败';
          _isLoading = false;
        });
        return;
      }

      // 解析返回数据
      final songs = _parseRankingData(result);
      setState(() {
        _songs = songs;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取排行失败: $e';
        _isLoading = false;
      });
    }
  }

  List<Song> _parseRankingData(Map<String, dynamic> data) {
    final songs = <Song>[];

    // 尝试从 data.data.list 或 data.list 获取列表
    final dataList = data['data'] as Map<String, dynamic>?;
    final list = (dataList?['list'] ?? data['list']) as List<dynamic>?;

    if (list == null) return songs;

    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;

      // 解析歌曲信息
      final songName = item['songname'] as String? ?? item['name'] as String? ?? '';
      final singerName = item['singername'] as String? ?? item['singer'] as String? ?? '未知艺术家';
      final hash = item['hash'] as String? ?? '';
      final albumAudioId = item['album_audio_id']?.toString() ?? item['mixsongid']?.toString();
      final albumId = item['album_id']?.toString();
      final albumName = item['album_name'] as String? ?? '';
      final durationMs = item['duration'] as int? ?? item['timelen'] as int? ?? 0;

      if (songName.isEmpty) continue;

      songs.add(Song(
        id: hash.isNotEmpty ? hash : (albumAudioId ?? songName),
        title: songName,
        artist: singerName,
        album: albumName,
        duration: Duration(milliseconds: durationMs * 1000),
        albumAudioId: albumAudioId,
        albumId: albumId,
        isOnline: true,
      ));
    }

    return songs;
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
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('最近一周')),
                ButtonSegment(value: 1, label: Text('全部累计')),
              ],
              selected: {_currentType},
              onSelectionChanged: (v) => _switchType(v.first),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : _error != null
              ? _buildError(cs)
              : _songs.isEmpty
                  ? _buildEmpty(cs)
                  : Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: _songs.length,
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

  Widget _buildRankingItem(BuildContext context, int index, ColorScheme cs) {
    final song = _songs[index];
    final rank = index + 1;

    // 前三名使用特殊颜色
    Color? rankColor;
    if (rank == 1) rankColor = Colors.amber;
    if (rank == 2) rankColor = Colors.grey[400];
    if (rank == 3) rankColor = Colors.brown[300];

    return InkWell(
      onTap: () {
        context.read<PlayerProvider>().playOnlinePlaylist(_songs, index);
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
                  context.read<PlayerProvider>().playOnlinePlaylist(_songs, index);
                },
                onMoreTap: () {},
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: cs.error.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(
            _error ?? '未知错误',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.error),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _loadRanking,
            child: const Text('重试'),
          ),
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
            '暂无听歌记录',
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
