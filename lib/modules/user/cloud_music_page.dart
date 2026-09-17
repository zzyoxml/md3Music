import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../core/services/media_store_service.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
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
  /// 批量删除多选模式：true 时列表进入勾选态（按当前过滤列表下标选中）。
  bool _isSelectMode = false;
  final Set<int> _selectedIndices = {};

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

  /// 加载云盘歌曲列表。
  ///
  /// [showLoading] 为 true 时（首次进入/重试/上传删除后）显示全屏 loading；
  /// 下拉刷新传 false，保持列表可见，避免松手瞬间闪现全屏 loading。
  Future<void> _loadCloudSongs({bool showLoading = true}) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      if (showLoading) _isLoading = true;
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
        final result =
            await api.getUserCloud(page: page, pagesize: pageSize, noCache: true);
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

  /// 从本地音乐库弹出选歌面板（复用 LibraryProvider，无文件选择器）。
  ///
  /// 单击歌曲 = 立即上传；长按 = 进入多选模式，可勾选多首批量上传。
  Future<void> _showLocalSongPicker() async {
    final library = context.read<LibraryProvider>();
    // 尚未加载过本地音乐时先恢复上次扫描的缓存歌曲：
    // 修复「必须先切换到本地音乐 tab 加载过一次才能上传」的问题。
    if (library.allSongs.isEmpty) {
      await library.loadSavedSongs();
      if (!mounted) return;
    }
    final localSongs = library.allSongs.where((s) => !s.isOnline).toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            // 多选模式选中集合（按列表下标）；非空即处于多选模式
            final selected = <int>{};
            return StatefulBuilder(
              builder: (context, setSheetState) {
                final inSelectMode = selected.isNotEmpty;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Row(
                        children: [
                          Text(
                            '选择本地歌曲上传',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          if (inSelectMode)
                            TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  if (selected.length == localSongs.length) {
                                    selected.clear();
                                  } else {
                                    selected.addAll(
                                      List.generate(
                                          localSongs.length, (i) => i),
                                    );
                                  }
                                });
                              },
                              child: Text(
                                selected.length == localSongs.length
                                    ? '取消全选'
                                    : '全选',
                              ),
                            )
                          else
                            Text(
                              '长按可多选',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            inSelectMode
                                ? '已选 ${selected.length} 首'
                                : '${localSongs.length} 首',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: localSongs.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.library_music_outlined,
                                    size: 48,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '本地音乐库暂无歌曲\n请先到「我的音乐」扫描本地歌曲',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: localSongs.length,
                              itemBuilder: (context, index) {
                                final song = localSongs[index];
                                return SongListItem(
                                  song: song,
                                  // 多选模式：点击切换选中；普通模式：点击直接上传
                                  onTap: inSelectMode
                                      ? () {
                                          setSheetState(() {
                                            if (!selected.remove(index)) {
                                              selected.add(index);
                                            }
                                          });
                                        }
                                      : () {
                                           Navigator.of(sheetContext).pop();
                                           _uploadSingle(song);
                                         },
                                  onLongPress: inSelectMode
                                      ? null
                                      : () {
                                          setSheetState(() {
                                            selected.add(index);
                                          });
                                        },
                                  isSelectMode: inSelectMode,
                                  isSelected: selected.contains(index),
                                  onSelectToggle: () {
                                    setSheetState(() {
                                      if (!selected.remove(index)) {
                                        selected.add(index);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                    // 多选模式底部：批量上传按钮
                    if (inSelectMode)
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () {
                                final batch = selected.map(
                                  (i) => localSongs[i],
                                ).toList();
                                Navigator.of(sheetContext).pop();
                                _uploadBatch(batch);
                              },
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text('上传已选 ${selected.length} 首'),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// 读取本地歌曲文件二进制。
  /// 兼容 file:// URI、content:// URI（经 MediaStore 解析）与裸绝对路径。
  /// 加 30 秒超时：content:// 的原生解析/拷贝若挂起，不会拖死批量上传。
  Future<Uint8List?> _readSongBytes(Song song) async {
    final raw = song.localPath;
    if (raw == null || raw.isEmpty) return null;
    try {
      Future<Uint8List> read;
      if (raw.startsWith('content://')) {
        read = () async {
          final resolved = await MediaStoreService.resolveLocalPath(raw);
          if (resolved == null || resolved.isEmpty) {
            throw Exception('content URI 解析失败');
          }
          return File(resolved).readAsBytes();
        }();
      } else if (raw.startsWith('file://')) {
        read = File(Uri.parse(raw).toFilePath()).readAsBytes();
      } else {
        read = File(raw).readAsBytes();
      }
      return await read.timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('[CloudMusic] 读取文件失败: $raw -> $e');
      return null;
    }
  }

  /// 上传单首本地歌曲到云盘。
  ///
  /// 返回 (ok, reason)：ok 为是否真正上传成功（服务端 add_files 返回
  /// status == 1 才算数，避免把错误响应误判为成功）；reason 为失败原因
  /// （批量上传时用于汇总展示）。不在此处刷新列表，由调用方统一刷新。
  /// [showResult] 为 false 时（批量上传）不弹单首成功/失败提示，只显示进度。
  Future<({bool ok, String? reason})> _uploadSong(
    Song song, {
    bool showResult = true,
  }) async {
    final api = KugouApiClient();

    try {
      if (!api.isLoggedIn) {
        if (showResult) showToast('请先登录', long: true);
        return (ok: false, reason: '未登录');
      }

      final bytes = await _readSongBytes(song);
      if (bytes == null || bytes.isEmpty) {
        if (showResult) {
          showToast('读取文件失败：${song.displayName}', long: true);
        }
        return (ok: false, reason: '读取文件失败');
      }

      // 从文件路径推导扩展名（默认 mp3）
      final raw = song.localPath ?? '';
      final dotIdx = raw.lastIndexOf('.');
      final ext = (dotIdx > 0 && dotIdx < raw.length - 1)
          ? raw.substring(dotIdx + 1).toLowerCase()
          : 'mp3';

      // 上传中提示（toast 展示进行中的歌曲）
      showToast(
        '正在上传「${song.displayName}」(${_formatSize(bytes.length)})…',
        long: true,
      );

      final result = await api.uploadCloudSong(
        bytes,
        extendname: ext,
        name: song.displayName,
        authorName: song.artist,
        timelen: song.duration.inMilliseconds > 0
            ? song.duration.inMilliseconds
            : null,
      );

      // 关键：只有服务端明确返回 status == 1 才算成功。
      // 服务端在授权/分片/完成/添加到云盘任一环节失败时返回 {status: 0, msg: ...}，
      // 此前误把 status == 0 也当作成功，导致「提示成功但云盘里没有」。
      final status = result?['status'];
      if (status == 1) {
        if (showResult) {
          showToast('「${song.displayName}」已上传到云盘', long: true);
        }
        return (ok: true, reason: null);
      }
      final msg = (result?['msg'] ?? result?['error_msg'] ?? '未知错误')
          .toString();
      if (showResult) {
        showToast('上传失败：$msg', long: true);
      }
      return (ok: false, reason: msg);
    } catch (e) {
      if (showResult) {
        showToast('上传失败：$e', long: true);
      }
      return (ok: false, reason: '$e');
    }
  }

  /// 单首上传：成功后刷新云盘列表。
  Future<void> _uploadSingle(Song song) async {
    final r = await _uploadSong(song);
    if (r.ok && mounted) {
      await _loadCloudSongs();
    }
  }

  /// 批量上传多首本地歌曲，逐首调用 [_uploadSong]。
  ///
  /// 每首上传前显示「正在上传 (i/n)」进度条（常驻，直到该首返回）；
  /// 单首结果不单独弹窗（避免误导），结束后统一汇总成功/失败数量与失败原因，
  /// 成功数 > 0 时刷新云盘列表。
  Future<void> _uploadBatch(List<Song> songs) async {
    if (songs.isEmpty) return;

    var ok = 0;
    final failed = <String>[];
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      // toast 展示当前上传进度（toast 自动消失，无需手动清理队列）
      showToast(
        '正在上传 (${i + 1}/${songs.length})「${song.displayName}」…',
        long: true,
      );
      final r = await _uploadSong(song, showResult: false);
      if (r.ok) {
        ok++;
      } else if (r.reason != null && r.reason!.isNotEmpty) {
        failed.add('${song.displayName}：${r.reason}');
      }
    }

    final summary = ok == songs.length
        ? '全部上传成功（$ok 首）'
        : '上传完成：成功 $ok 首，失败 ${songs.length - ok} 首'
            '${failed.isEmpty ? '' : '\n${failed.take(3).join('\n')}'}';
    showToast(summary, long: true);
    if (ok > 0) {
      await _loadCloudSongs();
    }
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
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
        title: Text(
          _isSelectMode ? '已选 ${_selectedIndices.length} 首' : '云盘音乐',
        ),
        actions: _isSelectMode
            ? [
                IconButton(
                  tooltip: '全选',
                  icon: const Icon(Icons.select_all),
                  onPressed: _toggleSelectAll,
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelectMode,
                ),
              ]
            : [
                IconButton(
                  tooltip: '多选删除',
                  icon: const Icon(Icons.checklist),
                  onPressed: _enterSelectMode,
                ),
                IconButton(
                  tooltip: '上传本地音乐',
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: _showLocalSongPicker,
                ),
              ],
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildError()
              : _songs.isEmpty
                  ? Md3PullToRefresh(
                      onRefresh: () => _loadCloudSongs(showLoading: false),
                      child: ListView(
                        children: [_buildEmpty()],
                      ),
                    )
                  : Md3PullToRefresh(
                      onRefresh: () => _loadCloudSongs(showLoading: false),
                      child: Column(
                        children: [
                          if (!_isSelectMode) _buildHeader(),
                          if (!_isSelectMode) _buildSearchBar(),
                          Expanded(
                            child: _filteredSongs.isEmpty
                                ? _buildNoMatch()
                                : ListView.builder(
                                    itemCount: _filteredSongs.length,
                                    itemBuilder: (context, index) {
                                      final song = _filteredSongs[index];
                                      return SongListItem(
                                        song: song,
                                        onTap: () {
                                          context
                                              .read<PlayerProvider>()
                                              .playCloudPlaylist(
                                                _filteredSongs,
                                                index,
                                              );
                                        },
                                        onMoreTap: _isSelectMode
                                            ? null
                                            : () => _showSongMoreMenu(song),
                                        isSelectMode: _isSelectMode,
                                        isSelected:
                                            _selectedIndices.contains(index),
                                        onSelectToggle: () =>
                                            _toggleSelect(index),
                                        onLongPress: _isSelectMode
                                            ? _toggleSelectAll
                                            : null,
                                      );
                                    },
                                  ),
                          ),
                          if (_isSelectMode) _buildSelectActionBar(),
                          const MiniPlayer(),
                        ],
                      ),
                    ),
    );
  }

  /// 进入批量删除多选模式。
  void _enterSelectMode() {
    setState(() {
      _isSelectMode = true;
      _selectedIndices.clear();
    });
  }

  /// 退出多选模式并清空选中。
  void _exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedIndices.clear();
    });
  }

  /// 切换某一下标的选中状态。
  void _toggleSelect(int index) {
    setState(() {
      if (!_selectedIndices.remove(index)) {
        _selectedIndices.add(index);
      }
    });
  }

  /// 全选 / 取消全选（作用于当前过滤后的可见列表）。
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIndices.length == _filteredSongs.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices
            .addAll(List.generate(_filteredSongs.length, (i) => i));
      }
    });
  }

  /// 列表项三点菜单：单曲删除入口。
  void _showSongMoreMenu(Song song) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(song.displayName),
              subtitle: Text(song.artist),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colorScheme.error),
              title: Text(
                '删除',
                style: TextStyle(color: colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete([song]);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 多选模式底部操作栏：删除所选。
  Widget _buildSelectActionBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed: _selectedIndices.isEmpty
                ? null
                : () {
                    final songs = _selectedIndices
                        .map((i) => _filteredSongs[i])
                        .toList();
                    _confirmDelete(songs);
                  },
            icon: const Icon(Icons.delete_outline),
            label: Text('删除所选 ${_selectedIndices.length} 首'),
          ),
        ),
      ),
    );
  }

  /// 删除确认对话框，确认后调用 [_deleteCloudSongs] 并刷新列表。
  Future<void> _confirmDelete(List<Song> songs) async {
    if (songs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          songs.length > 1 ? '删除所选 ${songs.length} 首歌曲？' : '删除这首歌曲？',
        ),
        content: const Text('删除后云端文件不可恢复，请谨慎操作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final r = await _deleteCloudSongs(songs);
    if (!mounted) return;
    if (r.ok) {
      if (_isSelectMode) _exitSelectMode();
      showToast('已删除 ${songs.length} 首', long: true);
      await _loadCloudSongs();
    } else {
      showToast('删除失败：${r.reason ?? '未知错误'}', long: true);
    }
  }

  /// 删除云盘歌曲（单首/批量共用）。
  ///
  /// 优先用 fileid(kv_id)+album_audio_id（服务端精确删除），
  /// fileId 缺失（旧数据）时回退 hash。返回 (ok, reason)。
  Future<({bool ok, String? reason})> _deleteCloudSongs(
    List<Song> songs,
  ) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return (ok: false, reason: '未登录');
    final fileids = <String>[];
    final albumAudioIds = <String>[];
    final hashes = <String>[];
    for (final s in songs) {
      if (s.fileId != null) {
        fileids.add(s.fileId.toString());
        albumAudioIds.add(s.albumAudioId ?? '0');
      } else {
        hashes.add(s.id);
      }
    }
    final result = await api.deleteCloudSongs(
      fileids: fileids.isEmpty ? null : fileids,
      albumAudioIds: albumAudioIds.isEmpty ? null : albumAudioIds,
      hashes: hashes.isEmpty ? null : hashes,
    );
    if (result?['status'] == 1) return (ok: true, reason: null);
    return (ok: false, reason: (result?['msg'] ?? '未知错误').toString());
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
