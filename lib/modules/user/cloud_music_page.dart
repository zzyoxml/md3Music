import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/md3e_refresh_indicator.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class CloudMusicPage extends StatefulWidget {
  const CloudMusicPage({super.key});

  @override
  State<CloudMusicPage> createState() => _CloudMusicPageState();
}

class _CloudMusicPageState extends State<CloudMusicPage> {
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCloudSongs();
  }

  Future<void> _loadCloudSongs() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = '请先登录';
          });
        }
        return;
      }

      final result = await api.getUserCloud(pagesize: 100);
      if (!mounted) return;

      if (result == null) {
        setState(() {
          _isLoading = false;
          _error = '加载失败，请稍后重试';
        });
        return;
      }

      // 响应结构兼容：data 可能是 List 或 Map，列表字段可能是 info/list
      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }

      final songs = <Song>[];
      if (list != null) {
        for (final e in list) {
          if (e is Map<String, dynamic>) {
            final song = _cloudItemToSong(e);
            if (song.id.isNotEmpty) songs.add(song);
          }
        }
      }

      setState(() {
        _songs = songs;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = '加载失败：$e';
        });
      }
    }
  }

  /// 将云盘列表项 JSON 映射为 Song 对象。
  /// 字段兼容酷狗云盘接口返回的多种命名。
  Song _cloudItemToSong(Map<String, dynamic> item) {
    final hash = (item['hash'] ?? '').toString();
    final songname = (item['songname'] ??
            item['FileName'] ??
            item['filename'] ??
            item['name'] ??
            '未知歌曲')
        .toString();
    final singer = (item['singername'] ??
            item['singer'] ??
            item['artist'] ??
            '未知歌手')
        .toString();
    final albumId = item['album_id']?.toString();
    final albumAudioId = item['album_audio_id']?.toString();
    // 时长字段可能不存在或为 0，缺省 0
    final durationMs = (item['duration'] is num)
        ? (item['duration'] as num).toInt()
        : 0;
    return Song(
      id: hash,
      title: songname,
      artist: singer,
      album: '',
      duration: Duration(milliseconds: durationMs),
      isOnline: true,
      albumId: albumId,
      albumAudioId: albumAudioId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('云盘音乐'),
      ),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : _error != null
              ? _buildError()
              : _songs.isEmpty
                  ? MD3ERefreshIndicator(
                      onRefresh: _loadCloudSongs,
                      child: ListView(
                        children: [_buildEmpty()],
                      ),
                    )
                  : MD3ERefreshIndicator(
                      onRefresh: _loadCloudSongs,
                      child: Column(
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
                                        .playCloudPlaylist(_songs, index);
                                  },
                                  onMoreTap: () {},
                                );
                              },
                            ),
                          ),
                          const MiniPlayer(),
                        ],
                      ),
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
                    .playCloudPlaylist(_songs, 0);
              }
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('播放全部'),
          ),
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
            Icons.cloud_off,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '云盘暂无音乐',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '下拉刷新重试',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: cs.error.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _error!,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _loadCloudSongs,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
