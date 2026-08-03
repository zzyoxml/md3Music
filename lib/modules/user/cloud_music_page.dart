import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/media_store_service.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
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
  void _showLocalSongPicker() {
    final library = context.read<LibraryProvider>();
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

  /// 统一的提示条样式：floating 悬浮 + 底部上移避开 MiniPlayer，
  /// 避免上传过程中遮挡播放器控件影响使用。
  /// [progress] 为 true 时显示常驻的转圈进度条。
  SnackBar _snack(String msg, {bool progress = false}) {
    return SnackBar(
      content: progress
          ? Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    msg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          : Text(msg),
      behavior: SnackBarBehavior.floating,
      // bottom: 96 使提示条悬浮在 MiniPlayer（约 70px + 系统手势条）之上
      margin: const EdgeInsets.only(left: 12, right: 12, bottom: 96),
      duration: progress
          ? const Duration(days: 1)
          : const Duration(seconds: 3),
    );
  }

  /// 上传单首本地歌曲到云盘。
  ///
  /// 返回 (ok, reason)：ok 为是否真正上传成功（服务端 add_files 返回
  /// status == 1 才算数，避免把错误响应误判为成功）；reason 为失败原因
  /// （批量上传时用于汇总展示）。不在此处刷新列表，由调用方统一刷新。
  /// [showResult] 为 false 时（批量上传）不弹单首成功/失败提示，只显示进度。
  Future<({bool ok, String? reason})> _uploadSong(
    Song song, {
    ScaffoldMessengerState? messenger,
    bool showResult = true,
  }) async {
    final api = KugouApiClient();
    // await 前捕获 messenger，避免 async gap 后使用 BuildContext
    final msgr = messenger ?? ScaffoldMessenger.of(context);

    try {
      if (!api.isLoggedIn) {
        if (showResult) msgr.showSnackBar(_snack('请先登录'));
        return (ok: false, reason: '未登录');
      }

      final bytes = await _readSongBytes(song);
      if (bytes == null || bytes.isEmpty) {
        if (showResult) {
          msgr.showSnackBar(_snack('读取文件失败：${song.displayName}'));
        }
        return (ok: false, reason: '读取文件失败');
      }

      // 从文件路径推导扩展名（默认 mp3）
      final raw = song.localPath ?? '';
      final dotIdx = raw.lastIndexOf('.');
      final ext = (dotIdx > 0 && dotIdx < raw.length - 1)
          ? raw.substring(dotIdx + 1).toLowerCase()
          : 'mp3';

      // 上传中提示（不阻塞 UI，仅顶部 SnackBar 展示进度）
      // clearSnackBars：清空队列中未显示的 SnackBar，避免进度条堆积导致
      // 批量上传完成后汇总提示排队等待、界面一直停留在"正在上传"
      msgr
        ..clearSnackBars()
        ..showSnackBar(
          _snack(
            '正在上传「${song.displayName}」(${_formatSize(bytes.length)})…',
            progress: true,
          ),
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
      msgr.clearSnackBars();

      // 关键：只有服务端明确返回 status == 1 才算成功。
      // 服务端在授权/分片/完成/添加到云盘任一环节失败时返回 {status: 0, msg: ...}，
      // 此前误把 status == 0 也当作成功，导致「提示成功但云盘里没有」。
      final status = result?['status'];
      if (status == 1) {
        if (showResult) {
          msgr.showSnackBar(_snack('「${song.displayName}」已上传到云盘'));
        }
        return (ok: true, reason: null);
      }
      final msg = (result?['msg'] ?? result?['error_msg'] ?? '未知错误')
          .toString();
      if (showResult) {
        msgr.showSnackBar(_snack('上传失败：$msg'));
      }
      return (ok: false, reason: msg);
    } catch (e) {
      msgr.clearSnackBars();
      if (showResult) {
        msgr.showSnackBar(_snack('上传失败：$e'));
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
    // await 前捕获 messenger，避免 async gap 后使用 BuildContext
    final messenger = ScaffoldMessenger.of(context);

    var ok = 0;
    final failed = <String>[];
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      // clearSnackBars：清空排队中的 SnackBar，保证当前进度条立即显示
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          _snack(
            '正在上传 (${i + 1}/${songs.length})「${song.displayName}」…',
            progress: true,
          ),
        );
      final r = await _uploadSong(song, messenger: messenger, showResult: false);
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
    // clearSnackBars：清掉常驻的"正在上传"进度条与队列残留，确保汇总立即显示
    messenger
      ..clearSnackBars()
      ..showSnackBar(_snack(summary));
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
        title: const Text('云盘音乐'),
        actions: [
          IconButton(
            tooltip: '上传本地音乐',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: _showLocalSongPicker,
          ),
        ],
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
