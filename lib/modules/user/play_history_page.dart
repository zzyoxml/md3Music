import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../data/repositories/history_repository.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class PlayHistoryPage extends StatefulWidget {
  const PlayHistoryPage({super.key});

  @override
  State<PlayHistoryPage> createState() => _PlayHistoryPageState();
}

class _PlayHistoryPageState extends State<PlayHistoryPage> {
  List<Song> _songs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await HistoryRepository().getHistory();
    if (!mounted) return;
    setState(() {
      _songs = history;
      _isLoading = false;
    });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空播放历史'),
        content: const Text('确定要清空所有播放历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await HistoryRepository().clearHistory();
      await _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放历史'),
        actions: [
          if (_songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? _buildEmpty()
              : Column(
                  children: [
                    _buildHeader(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _songs.length,
                        itemBuilder: (context, index) {
                          return SongListItem(
                            song: _songs[index],
                            onTap: () {
                              context
                                  .read<PlayerProvider>()
                                  .playOnlinePlaylist(_songs, index);
                            },
                            onMoreTap: () {},
                          );
                        },
                      ),
                    ),
                    const MiniPlayer(),
                  ],
                ),
    );
  }

  Widget _buildEmpty() {
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
            '暂无播放历史',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${_songs.length} 首',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              if (_songs.isNotEmpty) {
                context
                    .read<PlayerProvider>()
                    .playOnlinePlaylist(_songs, 0);
              }
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }
}
