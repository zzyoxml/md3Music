import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<KugouPlaylistBrief> _playlists = [];
  List<Song> _currentPlaylistSongs = [];
  KugouPlaylistBrief? _selectedPlaylist;
  bool _isLoadingPlaylists = true;
  bool _isLoadingSongs = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPlaylists();
    });
  }

  Future<void> _loadPlaylists() async {
    if (!mounted) return;
    setState(() => _isLoadingPlaylists = true);

    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(pagesize: 50);
      if (!mounted) return;

      debugPrint('getUserPlaylist result: $result');

      if (result != null) {
        final data = result['data'];
        debugPrint('getUserPlaylist data: $data');

        List<dynamic>? list;
        if (data is List) {
          list = data;
        } else if (data is Map<String, dynamic>) {
          list = data['info'] as List<dynamic>?;
          list ??= data['list'] as List<dynamic>?;
        }

        if (list != null && list.isNotEmpty) {
          setState(() {
            _playlists = list!
                .map((e) {
                  debugPrint('Playlist item: $e');
                  return KugouPlaylistBrief.fromJson(e as Map<String, dynamic>);
                })
                .toList();
            _isLoadingPlaylists = false;
          });
          return;
        }
      }
      setState(() => _isLoadingPlaylists = false);
    } catch (e) {
      debugPrint('Load playlists error: $e');
      if (mounted) setState(() => _isLoadingPlaylists = false);
    }
  }

  Future<void> _loadPlaylistSongs(KugouPlaylistBrief playlist) async {
    if (!mounted) return;
    setState(() {
      _isLoadingSongs = true;
      _selectedPlaylist = playlist;
      _currentPlaylistSongs = [];
    });

    try {
      final api = KugouApiClient();
      final globalId = playlist.globalCollectionId ?? playlist.id;
      debugPrint('Loading playlist songs for: ${playlist.name}, globalId: $globalId');
      final result = await api.getPlaylistSongs(
        globalId,
        pagesize: 200,
      );
      if (!mounted) return;

      debugPrint('getPlaylistSongs result: $result');

      if (result != null && result.songs.isNotEmpty) {
        setState(() {
          _currentPlaylistSongs = result.songs.map((s) => s.toSong()).toList();
          _isLoadingSongs = false;
        });
      } else {
        debugPrint('No songs found in playlist');
        setState(() => _isLoadingSongs = false);
      }
    } catch (e) {
      debugPrint('Load playlist songs error: $e');
      if (mounted) setState(() => _isLoadingSongs = false);
    }
  }

  Future<void> _showCreatePlaylistDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入歌单名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final fav = context.read<FavoritesProvider>();
      final resp = await fav.createPlaylist(result);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resp != null ? '歌单创建成功' : '创建失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        _loadPlaylists();
      }
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedPlaylist?.name ?? '我的收藏'),
        actions: [
          if (_selectedPlaylist != null)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回歌单列表',
              onPressed: () {
                setState(() {
                  _selectedPlaylist = null;
                  _currentPlaylistSongs = [];
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建歌单',
            onPressed: _showCreatePlaylistDialog,
          ),
        ],
      ),
      body: _selectedPlaylist != null ? _buildSongList() : _buildPlaylistList(),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _buildPlaylistList() {
    if (_isLoadingPlaylists) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_playlists.isEmpty) {
      return _buildEmpty();
    }
    return RefreshIndicator(
      onRefresh: _loadPlaylists,
      child: ListView.builder(
        itemCount: _playlists.length,
        itemBuilder: (context, index) {
          final playlist = _playlists[index];
          return ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 48,
                height: 48,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: playlist.coverUrl != null
                    ? Image.network(playlist.coverUrl!, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(Icons.queue_music,
                            color: Theme.of(context).colorScheme.onSurfaceVariant))
                    : Icon(Icons.queue_music,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${playlist.songCount} 首',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _loadPlaylistSongs(playlist),
          );
        },
      ),
    );
  }

  Widget _buildSongList() {
    if (_isLoadingSongs) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_currentPlaylistSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note, size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text('歌单暂无歌曲',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('共 ${_currentPlaylistSongs.length} 首',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  context.read<PlayerProvider>().playOnlinePlaylist(_currentPlaylistSongs, 0);
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放全部'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _currentPlaylistSongs.length,
            itemBuilder: (context, index) {
              final song = _currentPlaylistSongs[index];
              return SongListItem(
                song: song,
                onTap: () {
                  context.read<PlayerProvider>().playOnlinePlaylist(_currentPlaylistSongs, index);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 64,
              color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text('暂无歌单', style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text('点击右上角 + 创建新歌单',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}
