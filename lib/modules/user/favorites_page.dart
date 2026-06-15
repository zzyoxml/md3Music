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

  // 分组折叠状态
  bool _createdExpanded = true;
  bool _collectedExpanded = true;

  // 管理模式（批量选择）
  bool _isManaging = false;
  final Set<int> _selectedIndices = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPlaylists();
      context.read<FavoritesProvider>().addListener(_onFavoritesChanged);
    });
  }

  @override
  void dispose() {
    context.read<FavoritesProvider>().removeListener(_onFavoritesChanged);
    super.dispose();
  }

  String? get _currentUserId => KugouApiClient().userid;

  /// 判断歌单是否为用户自己创建的
  bool _isCreated(KugouPlaylistBrief p) {
    if (_currentUserId == null) return false;
    return p.listCreateUserid == _currentUserId;
  }

  List<KugouPlaylistBrief> get _createdPlaylists =>
      _playlists.where(_isCreated).toList();

  List<KugouPlaylistBrief> get _collectedPlaylists =>
      _playlists.where((p) => !_isCreated(p)).toList();

  void _onFavoritesChanged() {
    if (!mounted) return;
    final selected = _selectedPlaylist;
    if (selected != null) {
      // 统一重新加载，让 _loadPlaylistSongs 内部处理"我喜欢"的逻辑
      _loadPlaylistSongs(selected, noCache: true);
    }
  }

  Future<void> _loadPlaylists() async {
    if (!mounted) return;
    setState(() => _isLoadingPlaylists = true);

    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(pagesize: 50);
      if (!mounted) return;

      if (result != null) {
        final data = result['data'];
        List<dynamic>? list;
        if (data is List) {
          list = data;
        } else if (data is Map<String, dynamic>) {
          list = data['info'] as List<dynamic>?;
          list ??= data['list'] as List<dynamic>?;
        }

        if (list != null && list.isNotEmpty) {
          final uid = _currentUserId;
          setState(() {
            _playlists = list!
                .where((e) {
                  // 过滤掉收藏的专辑：type=1 && source=2
                  final json = e as Map<String, dynamic>;
                  final type = json['type'] as int? ?? 0;
                  final source = json['source'] as int? ?? 0;
                  if (type == 1 && source == 2) return false;
                  return true;
                })
                .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
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

  bool _isMyFavoritePlaylist(KugouPlaylistBrief playlist) {
    final gid = playlist.globalCollectionId ?? playlist.id;
    return gid.contains('_2_') || playlist.name == '我喜欢';
  }

  Future<void> _loadPlaylistSongs(KugouPlaylistBrief playlist, {bool noCache = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoadingSongs = true;
      _selectedPlaylist = playlist;
      _currentPlaylistSongs = [];
    });

    // "我喜欢"歌单：始终从 API 加载完整列表，本地 favorites 只用于红心状态
    final isMyFav = _isMyFavoritePlaylist(playlist);

    try {
      final api = KugouApiClient();
      final globalId = playlist.globalCollectionId ?? playlist.id;
      debugPrint('Loading songs for: ${playlist.name}, gid=$globalId, listId=${playlist.listId}');

      KugouPlaylistSongs? result;
      // 自己创建的歌单（包括"我喜欢"）：用 listid 接口（返回 data.info）
      // 收藏的别人歌单：用 globalCollectionId 接口（返回 data.songs）
      final isCreated = _isCreated(playlist);
      if (isCreated && playlist.listId.isNotEmpty) {
        result = await api.getPlaylistSongsByListid(
          listid: playlist.listId,
          pagesize: 200,
          noCache: noCache,
        );
      } else {
        // 收藏的歌单：用原歌单的 globalCollectionId（listCreateGid）
        // 因为用户的订阅版本（globalId）可能 count=0，需要用原歌单 ID
        final targetGid = playlist.listCreateGid ?? globalId;
        debugPrint('Loading collected playlist with gid: $targetGid (listCreateGid=${playlist.listCreateGid})');
        result = await api.getPlaylistSongs(
          targetGid,
          pagesize: 200,
          noCache: noCache,
        );
      }
      if (!mounted) return;

      if (result != null && result.songs.isNotEmpty) {
        final songs = result.songs.map((s) => s.toSong()).toList();
        // 同步"我喜欢"歌单的歌曲 ID 到 FavoritesProvider
        if (isMyFav && mounted) {
          final favProvider = context.read<FavoritesProvider>();
          favProvider.syncFavoriteIds(songs.map((s) => s.id).toSet());
        }
        setState(() {
          _currentPlaylistSongs = songs;
          _isLoadingSongs = false;
        });
      } else {
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
          decoration: const InputDecoration(hintText: '输入歌单名称', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final fav = context.read<FavoritesProvider>();
      final resp = await fav.createPlaylist(result);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(resp != null ? '创建成功' : '创建失败，请重试'),
          behavior: SnackBarBehavior.floating,
        ));
        _loadPlaylists();
      }
    }
    controller.dispose();
  }

  // ---- 批量管理 ----

  void _toggleManageMode(bool value) {
    setState(() {
      _isManaging = value;
      _selectedIndices.clear();
    });
  }

  void _toggleSelection(int index, int totalCreatedCount) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  Future<void> _batchDeleteSelected(List<KugouPlaylistBrief> targetList) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除选中的 ${_selectedIndices.length} 个歌单？\n（收藏的歌单将取消收藏）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final fav = context.read<FavoritesProvider>();
    final sortedIndices = _selectedIndices.toList()..sort((a, b) => b.compareTo(a));

    for (final idx in sortedIndices) {
      if (idx < targetList.length) {
        final p = targetList[idx];
        try {
          if (_isCreated(p)) {
            await fav.deletePlaylist(p.listId);
          } else {
            // 收藏的歌单：取消收藏，传 type=0
            await fav.deletePlaylist(p.listId, type: 0);
          }
        } catch (e) {
          debugPrint('Delete playlist ${p.name} failed: $e');
        }
      }
    }

    _toggleManageMode(false);
    _loadPlaylists();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('操作完成'),
        behavior: SnackBarBehavior.floating,
      ));
    }
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
              tooltip: '返回',
              onPressed: () => setState(() => _selectedPlaylist = null),
            ),
          if (_selectedPlaylist == null && !_isManaging)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新建歌单',
              onPressed: _showCreatePlaylistDialog,
            ),
          if (_selectedPlaylist == null && _isManaging) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '批量删除',
              onPressed: _selectedIndices.isEmpty ? null : () => _batchDeleteSelected([..._createdPlaylists, ..._collectedPlaylists]),
            ),
            TextButton(
              onPressed: () => _toggleManageMode(false),
              child: const Text('取消'),
            ),
          ],
        ],
      ),
      body: _selectedPlaylist != null ? _buildSongList() : _buildGroupedPlaylistList(),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  // ==================== 歌单列表（分组折叠式）====================

  Widget _buildGroupedPlaylistList() {
    if (_isLoadingPlaylists) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_playlists.isEmpty) return _buildEmpty();

    final created = _createdPlaylists;
    final collected = _collectedPlaylists;

    return RefreshIndicator(
      onRefresh: _loadPlaylists,
      child: ListView(
        children: [
          // 我创建的歌单
          if (created.isNotEmpty)
            _buildGroupSection(
              title: '我创建的歌单',
              count: created.length,
              isExpanded: _createdExpanded,
              onToggle: (v) => setState(() => _createdExpanded = v),
              playlists: created,
              baseIndex: 0,
              showAdd: true,
            ),

          // 我收藏的歌单
          if (collected.isNotEmpty)
            _buildGroupSection(
              title: '我收藏的歌单',
              count: collected.length,
              isExpanded: _collectedExpanded,
              onToggle: (v) => setState(() => _collectedExpanded = v),
              playlists: collected,
              baseIndex: created.length,
              showAdd: false,
            ),
        ],
      ),
    );
  }

  Widget _buildGroupSection({
    required String title,
    required int count,
    required bool isExpanded,
    required ValueChanged<bool> onToggle,
    required List<KugouPlaylistBrief> playlists,
    required int baseIndex,
    required bool showAdd,
  }) {
    final displayCount = isExpanded ? playlists.length : (count > 5 ? 5 : count);

    return Column(
      children: [
        // 分组头部
        InkWell(
          onTap: () => onToggle(!isExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                Text('$count', style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
                const SizedBox(width: 8),
                if (showAdd)
                  IconButton(icon: const Icon(Icons.add, size: 20), onPressed: _showCreatePlaylistDialog)
                else if (_isManaging)
                  IconButton(
                    icon: const Icon(Icons.sort, size: 20),
                    tooltip: '管理模式',
                    onPressed: () {}, // 已在管理中，无额外操作
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.sort, size: 20),
                    tooltip: '管理歌单',
                    onPressed: () => _toggleManageMode(true),
                  ),
              ],
            ),
          ),
        ),
        Divider(height: 1, indent: 44, color: Theme.of(context).colorScheme.outlineVariant),

        // 展开时显示列表
        if (isExpanded)
          ...List.generate(displayCount, (i) {
            final playlist = playlists[i];
            final idx = baseIndex + i;
            final isSelected = _selectedIndices.contains(idx);
            return _buildPlaylistTile(playlist, isSelected, idx, baseIndex);
          }),

        // 折叠且超过显示数量时，底部展开按钮
        if (!isExpanded && count > 5)
          Center(
            child: TextButton.icon(
              onPressed: () => onToggle(true),
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              label: const Text('展开', style: TextStyle(fontSize: 13)),
            ),
          ),
      ],
    );
  }

  Widget _buildPlaylistTile(KugouPlaylistBrief playlist, bool isSelected, int index, int baseIndex) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isManaging)
            Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelection(index, baseIndex),
            )
          else
            const SizedBox(width: 0),
          ClipRRect(
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
        ],
      ),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${playlist.songCount} 首', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      trailing: _isManaging ? null : const Icon(Icons.chevron_right),
      onTap: _isManaging ? () => _toggleSelection(index, baseIndex) : () => _loadPlaylistSongs(playlist),
      onLongPress: _isManaging ? null : () => _toggleManageMode(true),
    );
  }

  // ==================== 歌曲列表 ====================

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
            Text('歌单暂无歌曲', style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
                onPressed: () => context.read<PlayerProvider>().playOnlinePlaylist(_currentPlaylistSongs, 0),
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
                forceFavorited: _isMyFavoritePlaylist(_selectedPlaylist!),
                onTap: () => context.read<PlayerProvider>().playOnlinePlaylist(_currentPlaylistSongs, index),
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
          Icon(Icons.favorite_border, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text('暂无歌单', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text('点击右上角 + 创建新歌单',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}
