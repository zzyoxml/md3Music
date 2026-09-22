import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_toast.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/history_repository.dart';
import '../../../providers/favorites_provider.dart';
import '../../../providers/listen_together_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../services/kugou_api/kugou_models.dart';
import '../../../services/kugou_api/listen_together_models.dart';
import 'room_cover_image.dart';

/// 点歌来源。
enum _PickerSource { recent, mine, created, favorites, search }

/// 独立点歌/加歌弹窗（对齐 EchoMusic orderSongPicker）：
/// 成员单点即提交（互斥 + 「点歌中」），房主多选批量加入（上限 50）。
class SongPickerSheet extends StatefulWidget {
  const SongPickerSheet({super.key});

  /// 单批加歌上限（对齐 EchoMusic LISTEN_TOGETHER_ADD_BATCH_LIMIT）。
  static const int batchLimit = 50;

  @override
  State<SongPickerSheet> createState() => _SongPickerSheetState();
}

class _SongPickerSheetState extends State<SongPickerSheet> {
  _PickerSource _source = _PickerSource.recent;
  final _searchCtrl = TextEditingController();
  // 最近播放/我喜欢来源的本地过滤词（不发起网络请求）
  final _filterCtrl = TextEditingController();
  String _filter = '';
  List<Song> _recent = [];
  List<Song> _mine = [];
  List<KugouPlaylistBrief> _playlists = [];
  KugouPlaylistBrief? _selectedPlaylist;
  List<Song> _playlistSongs = [];
  List<Song> _searchResults = [];
  final Set<String> _selectedKeys = {};
  bool _loading = false;
  bool _searching = false;
  bool _submitting = false;
  String? _orderingHash;
  bool _isOwner = false;

  bool _eligible(Song s) =>
      s.id.isNotEmpty && s.albumAudioId != null && s.albumAudioId!.isNotEmpty;

  String _keyOf(Song s) => s.id.trim().toLowerCase();

  /// 当前角色可见的来源（自建/收藏歌单仅房主可见）。
  List<_PickerSource> get _visibleSources => _PickerSource.values
      .where((s) => _isOwner || (s != _PickerSource.created && s != _PickerSource.favorites))
      .toList();

  @override
  void initState() {
    super.initState();
    final session = context.read<ListenTogetherProvider>().session;
    _isOwner = session?.isOwner ?? false;
    _loadRecent();
    _loadMine();
  }

  Future<void> _loadRecent() async {
    final list = await HistoryRepository().getHistory();
    if (!mounted) return;
    setState(() => _recent =
        list.where(_eligible).toList().take(SongPickerSheet.batchLimit).toList());
  }

  /// 「我喜欢」用云端整表：FavoritesProvider.favorites 只含 App 内点红心的
  /// 几首（云端收藏只同步 id 集合），直接用会表现为「只能加载 N 首」。
  Future<void> _loadMine() async {
    setState(() => _loading = true);
    try {
      final songs =
          await context.read<FavoritesProvider>().loadCloudFavoriteSongs();
      if (!mounted) return;
      setState(() => _mine = songs.where(_eligible).toList());
    } catch (_) {
      if (mounted) showToast('我喜欢加载失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadPlaylists() async {
    setState(() => _loading = true);
    try {
      final result = await KugouApiClient().getUserPlaylist(page: 1, pagesize: 100);
      final data = result?['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>? ?? data['list'] as List<dynamic>?;
      }
      if (!mounted) return;
      _playlists = (list ?? const [])
          .whereType<Map<String, dynamic>>()
          // 过滤「收藏的专辑」类条目（与收藏页口径一致：type==1 && source==2）
          .where((e) => !((e['type'] as int? ?? 0) == 1 && (e['source'] as int? ?? 0) == 2))
          .map(KugouPlaylistBrief.fromJson)
          .where((p) => (_source == _PickerSource.created
              ? p.type == 0
              : p.type == 1))
          .toList();
      _selectedPlaylist = _playlists.isNotEmpty ? _playlists.first : null;
      if (_selectedPlaylist != null) await _loadPlaylistSongs(_selectedPlaylist!);
    } catch (_) {
      showToast('歌单加载失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadPlaylistSongs(KugouPlaylistBrief playlist) async {
    setState(() => _loading = true);
    try {
      final api = KugouApiClient();
      final details = playlist.type == 0 && playlist.listId.isNotEmpty
          ? await api.getPlaylistTrackAllNew(listid: playlist.listId, page: 1, pagesize: 300)
          : await api.getPlaylistTrackAll(id: playlist.id, page: 1, pagesize: 300);
      if (!mounted) return;
      setState(() => _playlistSongs =
          (details ?? const <KugouSongDetail>[]).map((e) => e.toSong()).where(_eligible).toList());
    } catch (_) {
      showToast('歌单歌曲加载失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search() async {
    final keyword = _searchCtrl.text.trim();
    if (keyword.isEmpty || _searching) return;
    setState(() => _searching = true);
    try {
      final result = await KugouApiClient().search(keyword);
      if (!mounted) return;
      setState(() => _searchResults =
          (result?.songs ?? const <KugouSongDetail>[]).map((e) => e.toSong()).where(_eligible).toList());
    } catch (_) {
      showToast('搜索失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  List<Song> get _candidates {
    final List<Song> base;
    switch (_source) {
      case _PickerSource.recent:
        base = _recent;
      case _PickerSource.mine:
        base = _mine.where(_eligible).toList();
      case _PickerSource.created:
      case _PickerSource.favorites:
        base = _playlistSongs;
      case _PickerSource.search:
        base = _searchResults;
    }
    // 最近播放/我喜欢支持本地过滤（歌名/歌手包含，不区分大小写）
    if ((_source == _PickerSource.recent || _source == _PickerSource.mine) &&
        _filter.isNotEmpty) {
      final kw = _filter.toLowerCase();
      return base
          .where((s) =>
              s.displayName.toLowerCase().contains(kw) ||
              s.artist.toLowerCase().contains(kw))
          .toList();
    }
    return base;
  }

  Future<void> _submitOrder(Song song) async {
    if (_orderingHash != null || _submitting) return;
    setState(() => _orderingHash = _keyOf(song));
    try {
      final session = context.read<ListenTogetherProvider>().session;
      await session?.orderSong(RoomSong.fromSong(song));
      if (mounted) Navigator.pop(context);
    } catch (_) {
      // toast 已由 orderSong 给出
    } finally {
      if (mounted) setState(() => _orderingHash = null);
    }
  }

  Future<void> _submitBatch() async {
    if (_submitting || _selectedKeys.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final session = context.read<ListenTogetherProvider>().session;
      final songs = _candidates.where((s) => _selectedKeys.contains(_keyOf(s))).toList();
      await session?.ownerAddSongs(songs.map(RoomSong.fromSong).toList());
      if (mounted) Navigator.pop(context);
    } catch (_) {
      showToast('批量添加失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toggle(Song song) {
    final key = _keyOf(song);
    setState(() {
      if (_selectedKeys.remove(key)) return;
      if (_selectedKeys.length >= SongPickerSheet.batchLimit) {
        showToast('每次最多添加 ${SongPickerSheet.batchLimit} 首歌曲');
        return;
      }
      _selectedKeys.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final candidates = _candidates;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scrollController) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_isOwner ? '添加歌曲' : '点歌',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              // 来源切换（设置页深色模式同款 M3EToggleButtonGroup，带挤压动效）：
              // 房主 5 个来源，成员 3 个（自建/收藏歌单仅房主可见）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: M3EToggleButtonGroup(
                    actions: [
                      for (final s in _visibleSources)
                        M3EToggleButtonGroupAction(
                          label: Text(switch (s) {
                            _PickerSource.recent => '最近播放',
                            _PickerSource.mine => '我喜欢',
                            _PickerSource.created => '自建歌单',
                            _PickerSource.favorites => '收藏歌单',
                            _PickerSource.search => '搜索',
                          }),
                          icon: Icon(switch (s) {
                            _PickerSource.recent => Icons.history,
                            _PickerSource.mine => Icons.favorite_border,
                            _PickerSource.created => Icons.library_music,
                            _PickerSource.favorites => Icons.bookmark_border,
                            _PickerSource.search => Icons.search,
                          }),
                        ),
                    ],
                    selectedIndex: _visibleSources.indexOf(_source),
                    onSelectedIndexChanged: (index) {
                      if (index == null || index < 0 || index >= _visibleSources.length) {
                        return;
                      }
                      final s = _visibleSources[index];
                      if (s == _source) return;
                      setState(() {
                        _source = s;
                        _selectedKeys.clear();
                        _playlistSongs = [];
                        _searchResults = [];
                        _filter = '';
                        _filterCtrl.clear();
                      });
                      if (s == _PickerSource.created || s == _PickerSource.favorites) {
                        _loadPlaylists();
                      }
                    },
                  ),
                ),
              ),
              // 最近播放/我喜欢：本地过滤框（歌名/歌手，不发起网络请求）
              if (_source == _PickerSource.recent || _source == _PickerSource.mine)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: TextField(
                    controller: _filterCtrl,
                    onChanged: (v) => setState(() => _filter = v.trim()),
                    decoration: InputDecoration(
                      hintText: '过滤当前列表（歌名/歌手）',
                      isDense: true,
                      prefixIcon: const Icon(Icons.filter_list),
                      border: const OutlineInputBorder(),
                      suffixIcon: _filter.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _filterCtrl.clear();
                                setState(() => _filter = '');
                              },
                            ),
                    ),
                  ),
                ),
              if (_source == _PickerSource.created || _source == _PickerSource.favorites)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButton<KugouPlaylistBrief>(
                    isExpanded: true,
                    value: _selectedPlaylist,
                    hint: const Text('选择歌单'),
                    items: _playlists
                        .map((p) => DropdownMenuItem(value: p, child: Text(p.name, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (p) {
                      if (p == null) return;
                      setState(() {
                        _selectedPlaylist = p;
                        _selectedKeys.clear();
                      });
                      _loadPlaylistSongs(p);
                    },
                  ),
                ),
              if (_source == _PickerSource.search)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: const InputDecoration(
                            hintText: '搜索歌名或歌手', isDense: true, border: OutlineInputBorder()),
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(onPressed: _searching ? null : _search, icon: const Icon(Icons.search)),
                    ],
                  ),
                ),
              if (_isOwner && candidates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _selectedKeys.length == candidates.length &&
                                candidates.isNotEmpty,
                        tristate: false,
                        onChanged: (v) => setState(() {
                          _selectedKeys.clear();
                          if (v == true) {
                            for (final s in candidates.take(SongPickerSheet.batchLimit)) {
                              _selectedKeys.add(_keyOf(s));
                            }
                          }
                        }),
                      ),
                      Text('${_selectedKeys.length}/${SongPickerSheet.batchLimit}'),
                    ],
                  ),
                ),
              Expanded(
                child: _loading || _searching
                    ? const Center(child: M3ELoadingIndicator())
                    : candidates.isEmpty
                        ? Center(child: Text(
                            _source == _PickerSource.search
                                ? '输入歌名或歌手搜索'
                                : (_filter.isNotEmpty ? '没有匹配的歌曲' : '暂无可选歌曲')))
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: candidates.length,
                            itemBuilder: (context, index) {
                              final song = candidates[index];
                              final key = _keyOf(song);
                              final ordering = _orderingHash == key;
                              return ListTile(
                                // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
                                leading: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: RoomCoverImage(
                                    url: song.artworkUri,
                                    iconSize: 24,
                                  ),
                                ),
                                // displayName：剥离 .mp3/.flac 等文件名后缀
                                title: Text(song.displayName,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(song.artist,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: _isOwner
                                    ? Checkbox(
                                        value: _selectedKeys.contains(key),
                                        onChanged: _submitting ? null : (_) => _toggle(song),
                                      )
                                    : TextButton(
                                        onPressed: ordering ? null : () => _submitOrder(song),
                                        child: Text(ordering ? '点歌中' : '点歌'),
                                      ),
                                onTap: _isOwner
                                    ? (_submitting ? null : () => _toggle(song))
                                    : (ordering ? null : () => _submitOrder(song)),
                              );
                            },
                          ),
              ),
              if (_isOwner)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: M3EFilledButton(
                        onPressed: _selectedKeys.isEmpty || _submitting ? null : _submitBatch,
                        child: Text(_submitting ? '添加中…' : '批量添加（${_selectedKeys.length}）'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }
}
