import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../data/repositories/history_repository.dart';
import '../../data/repositories/stream_cache_repository.dart';
import '../../providers/player_provider.dart';
import '../../services/stream_cache_manager.dart';
import '../../widgets/md3e_loading_indicator.dart';
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
  bool _showOnlyPlayable = false;
  bool _checkingPlayable = false;
  Set<String> _playableIds = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  List<Song> get _displaySongs {
    if (!_showOnlyPlayable) return _songs;
    return _songs.where((s) => _playableIds.contains(s.id)).toList();
  }

  Future<void> _loadHistory() async {
    final history = await HistoryRepository().getHistory();
    if (!mounted) return;
    setState(() {
      _songs = history;
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPlayableSongs();
    });
  }

  Future<void> _checkPlayableSongs() async {
    if (_songs.isEmpty) return;
    setState(() => _checkingPlayable = true);

    try {
      await StreamCacheManager.instance.ensureInitialized();
    } catch (_) {}

    final ids = <String>{};

    for (final song in _songs) {
      // 仅保留边听边存已自动缓存的歌曲
      try {
        final entry = StreamCacheRepository.instance.getEntry(song.id);
        if (entry != null && entry.audio.isNotEmpty) {
          ids.add(song.id);
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _playableIds = ids;
      _checkingPlayable = false;
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

  void _toggleFilter() {
    setState(() {
      _showOnlyPlayable = !_showOnlyPlayable;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displaySongs = _displaySongs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放历史'),
        actions: [
          if (_songs.isNotEmpty && !_checkingPlayable)
            IconButton(
              icon: Icon(
                _showOnlyPlayable
                    ? Icons.filter_alt
                    : Icons.filter_alt_outlined,
                color: _showOnlyPlayable ? cs.primary : null,
              ),
              tooltip: _showOnlyPlayable ? '显示全部' : '仅显示已缓存',
              onPressed: _toggleFilter,
            ),
          if (_songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : _songs.isEmpty
          ? _buildEmpty()
          : _showOnlyPlayable && displaySongs.isEmpty && !_checkingPlayable
          ? _buildNoPlayable()
          : Column(
              children: [
                _buildHeader(displaySongs),
                Expanded(
                  child: ListView.builder(
                    itemCount: displaySongs.length,
                    itemBuilder: (context, index) {
                      return SongListItem(
                        song: displaySongs[index],
                        onTap: () {
                          context.read<PlayerProvider>().playOnlinePlaylist(
                            displaySongs,
                            index,
                          );
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
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildNoPlayable() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '没有已缓存的歌曲',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '播放歌曲时会自动缓存',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
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
            _showOnlyPlayable
                ? '已缓存 ${displaySongs.length}/${_songs.length} 首'
                : '共 ${_songs.length} 首',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          if (_checkingPlayable)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.onSurfaceVariant,
              ),
            ),
          if (!_checkingPlayable && displaySongs.isNotEmpty)
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
