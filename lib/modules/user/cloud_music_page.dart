import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadCloudSongs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 内存过滤：根据当前搜索词匹配 title / artist（不区分大小写、子串）。
  List<Song> get _filteredSongs {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _songs;
    return _songs.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q);
    }).toList();
  }

  /// 云盘歌曲加载上限，与服务端实际限制对齐。
  static const int _maxCloudSongs = 6000;

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

      const int pageSize = 100;
      // 向上取整，保证能拉到 _maxCloudSongs 首（100*60=6000）
      const int maxPages = (_maxCloudSongs + pageSize - 1) ~/ pageSize;

      final songs = <Song>[];
      for (int page = 1; page <= maxPages; page++) {
        final result = await api.getUserCloud(page: page, pagesize: pageSize);
        if (!mounted) return;

        if (result == null) {
          // 第一页失败才报错，后续页失败静默停止
          if (page == 1) {
            setState(() {
              _isLoading = false;
              _error = '加载失败，请稍后重试';
            });
            return;
          }
          break;
        }

        final data = result['data'];
        final list = _safeExtractList(data);
        if (list == null || list.isEmpty) break;

        if (page == 1 && list.isNotEmpty && kDebugMode) {
          debugPrint('[CloudMusic] first item keys: ${list.first is Map<String, dynamic> ? (list.first as Map<String, dynamic>).keys.toList() : list.first.runtimeType}');
          debugPrint('[CloudMusic] first item: ${list.first}');
        }

        for (final e in list) {
          if (e is Map<String, dynamic>) {
            final song = mapCloudApiItemToSong(e);
            if (song.id.isNotEmpty) songs.add(song);
          }
        }

        if (songs.length >= _maxCloudSongs) {
          songs.removeRange(_maxCloudSongs, songs.length);
          break;
        }
        if (list.length < pageSize) break;
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

  /// 安全地从响应字段提取歌曲列表。
  /// 兼容以下情况：
  /// 1. 字段本身就是 List（直接返回）。
  /// 2. 字段是 Map 且 info/list 字段本身是 List。
  /// 3. 字段是 Map 且 info/list 字段是 JSON 编码的字符串（酷狗部分接口
  ///    偶发返回 `data = {"info": "[{...},...]"}` 这种格式，
  ///    直接 `as List<dynamic>?` 会抛类型转换异常）。
  /// 4. 字段是 JSON 编码的字符串本身。
  /// 解析失败返回 null（按空列表处理）。
  static List<dynamic>? _safeExtractList(dynamic data) {
    if (data is List) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) return decoded;
        if (decoded is Map) {
          final inner = decoded['info'] ?? decoded['list'];
          if (inner is List) return inner;
          if (inner is String) {
            final innerDecoded = jsonDecode(inner);
            if (innerDecoded is List) return innerDecoded;
          }
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    if (data is Map<String, dynamic>) {
      for (final key in const ['info', 'list']) {
        final inner = data[key];
        if (inner is List) return inner;
        if (inner is String) {
          try {
            final decoded = jsonDecode(inner);
            if (decoded is List) return decoded;
          } catch (_) {
            // 继续尝试下个字段
          }
        }
      }
    }
    return null;
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
                          _buildSearchBar(),
                          Expanded(
                            child: _filteredSongs.isEmpty
                                ? _buildNoMatch()
                                : ListView.builder(
                                    itemCount: _filteredSongs.length,
                                    itemBuilder: (context, index) {
                                      return SongListItem(
                                        song: _filteredSongs[index],
                                        onTap: () {
                                          context
                                              .read<PlayerProvider>()
                                              .playCloudPlaylist(
                                                _filteredSongs,
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

  Widget _buildSearchBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索云盘歌曲',
          hintStyle: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: colorScheme.onSurfaceVariant),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: colorScheme.onSurfaceVariant,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          isDense: true,
        ),
        onChanged: (value) => setState(() => _searchQuery = value),
      ),
    );
  }

  Widget _buildNoMatch() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '没有匹配 "${_searchQuery.trim()}" 的歌曲',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '在酷狗音乐 App 中上传歌曲后即可在此查看',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: _loadCloudSongs,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
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
