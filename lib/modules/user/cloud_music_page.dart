import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/services/folder_picker_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/audio_scanner.dart';
import '../../core/utils/permissions.dart';
import '../../data/models/song.dart';
import '../../providers/cloud_upload_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import '../../widgets/song_list_item.dart';
import '../player/secondary_mini_player.dart';
import 'cloud_capacity_card.dart';
import 'cloud_upload_queue_sheet.dart';

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

  /// 云盘已用容量（按列表条目 filesize 求和）与云端歌曲总数。
  int _usedBytes = 0;
  int _cloudTotal = 0;
  /// 云盘总配额（get_list 响应内嵌配额字段时才有值；未见字段则只显示已用）。
  int? _quotaBytes;

  /// 上传队列空闲且有新增成功 → 去抖刷新云盘列表。
  Timer? _refreshDebounce;
  int _lastUploadGeneration = -1;
  late final CloudUploadProvider _uploadProvider;

  @override
  void initState() {
    super.initState();
    _loadCloudSongs();
    _uploadProvider = context.read<CloudUploadProvider>();
    _lastUploadGeneration = _uploadProvider.completedGeneration;
    _uploadProvider.addListener(_onUploadQueueChanged);
  }

  @override
  void dispose() {
    _uploadProvider.removeListener(_onUploadQueueChanged);
    _refreshDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 上传队列代次变化：空闲且新增成功后 2s 去抖刷新列表（覆盖批量连传）。
  void _onUploadQueueChanged() {
    if (_uploadProvider.completedGeneration == _lastUploadGeneration) return;
    _lastUploadGeneration = _uploadProvider.completedGeneration;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(seconds: 2), () {
      if (mounted) _loadCloudSongs(showLoading: false);
    });
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
      var summedBytes = 0;
      int? serverUsed;
      int? serverMax;
      int? serverCount;
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

        // 容量/总数取响应权威字段（2026-10-11 真机实证 data 内含
        // used_size / max_size / availble_size / list_count；缺字段时
        // 回退本地求和与列表长度）
        if (page == 1) {
          final dm = _asMap(data);
          serverUsed = _intOf(dm?['used_size']);
          serverMax = _intOf(dm?['max_size']);
          serverCount =
              _intOf(dm?['list_count']) ?? _intOf(dm?['total']);
        }

        for (final e in list) {
          if (e is Map<String, dynamic>) {
            final song = mapCloudApiItemToSong(e);
            if (song.id.isNotEmpty) songs.add(song);
            // 求和兜底：响应缺 used_size 时按条目文件大小相加
            summedBytes += _itemSizeBytes(e);
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
        _usedBytes = serverUsed ?? summedBytes;
        _quotaBytes = serverMax;
        _cloudTotal = serverCount ?? _songs.length;
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
  /// 单击歌曲 = 加入上传队列；长按 = 进入多选模式，可勾选多首批量入队。
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
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, AppSpacing.sm),
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
                          const Gap(AppSpacing.sm),
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
                                  const Gap(AppSpacing.md),
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
                                           _enqueueSongs([song]);
                                         },
                                  onLongPress: inSelectMode
                                      ? null
                                      : () {
                                          setSheetState(() {
                                            selected.add(index);
                                          });
                                        },
                                  // tv: 遥控 OK 长按 = 长按语义（选中该行进多选），
                                  // 与 onLongPress 同一动作；SongListItem 的整行
                                  // DpadFocusable 接线由 widgets/song_list_item.dart
                                  // 承担（仅 kTvBuild 编入）。
                                  onContextMenuOverride: kTvBuild
                                      ? (inSelectMode
                                            ? null
                                            : () {
                                                setSheetState(() {
                                                  selected.add(index);
                                                });
                                              })
                                      : null,
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
                          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () {
                                final batch = selected.map(
                                  (i) => localSongs[i],
                                ).toList();
                                Navigator.of(sheetContext).pop();
                                _enqueueSongs(batch);
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

  /// 上传入口菜单：从音乐库选择 / 上传文件夹，并内联「匹配官方曲库」开关
  /// （实时生效并持久化，对未开始的上传任务生效）。
  void _showUploadMenu() {
    _uploadProvider.ensureMatchLoaded();
    showM3EModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Consumer<CloudUploadProvider>(
            builder: (context, up, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.library_music_outlined),
                    title: const Text('从音乐库选择'),
                    subtitle: const Text('上传已扫描的本地歌曲，支持多选'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showLocalSongPicker();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_open),
                    title: const Text('上传文件夹'),
                    subtitle: const Text('选择文件夹，音频文件全部加入上传队列'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _uploadFromFolder();
                    },
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: up.matchEnabled,
                    onChanged: (v) => up.setMatchEnabled(v),
                    title: const Text('匹配官方曲库'),
                    subtitle: const Text(
                      '上传前按文件哈希匹配，命中后显示官方歌名、歌手与歌词',
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 把所选歌曲加入上传队列（队列由 CloudUploadProvider 常驻处理，
  /// 页面退出不中断），并打开队列面板展示进度。
  void _enqueueSongs(List<Song> batch) {
    if (batch.isEmpty) return;
    final added = _uploadProvider.enqueueSongs(batch);
    if (added > 0) {
      final skipped = batch.length - added;
      showToast(
        skipped > 0 ? '已加入 $added 首，$skipped 首已在队列中' : '已加入上传队列 $added 首',
      );
      showCloudUploadQueueSheet(context);
    } else {
      showToast('所选歌曲已在队列中');
    }
  }

  /// 文件夹上传：SAF 目录选择 → 递归扫描音频（扩展名白名单 +
  /// isolate 读取标签元数据）→ 确认对话框 → 加入上传队列。
  Future<void> _uploadFromFolder() async {
    final granted = await requestStoragePermission();
    if (!mounted) return;
    if (!granted) {
      showToast('需要存储权限才能读取本地文件', long: true);
      return;
    }
    final dir = await FolderPickerService.pickFolder();
    if (!mounted) return;
    if (dir == null) return; // 用户取消
    // 目录选择服务只换算主存储（primary:）路径；SD 卡/OTG 等非主存储
    // 换算结果不会是真实存在的目录，在此拦截并说明。
    if (!Directory(dir).existsSync()) {
      showToast('该存储位置暂不支持，请选择内部存储中的文件夹', long: true);
      return;
    }
    showToast('正在扫描文件夹…');
    final files = collectAudioFiles([dir]);
    if (!mounted) return;
    if (files.isEmpty) {
      showToast('该文件夹内没有音频文件');
      return;
    }
    final metas = await compute(scanAudioFilesInIsolate, files);
    if (!mounted) return;
    if (metas.isEmpty) {
      showToast('没有可读取的音频文件');
      return;
    }
    var totalBytes = 0;
    for (final m in metas) {
      try {
        totalBytes += File((m['filePath'] as String?) ?? '').lengthSync();
      } catch (_) {}
    }
    final dirName = dir.split('/').where((s) => s.isNotEmpty).last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('上传「$dirName」？'),
        content: Text(
          '共找到 ${metas.length} 个音频文件（约 ${_formatSize(totalBytes)}），'
          '将加入上传队列逐个上传。\n'
          '匹配官方曲库：${_uploadProvider.matchEnabled ? '开' : '关'}'
          '（可在上传菜单或队列面板中切换）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('加入队列'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final added = _uploadProvider.enqueueScannedFiles(metas);
    if (added > 0) {
      showToast('已加入上传队列 $added 首');
      showCloudUploadQueueSheet(context);
    } else {
      showToast('音频文件已在队列中');
    }
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
  }

  /// 云盘列表条目的文件大小（filesize/fileSize/size 任一，缺失返回 0）。
  static int _itemSizeBytes(Map<String, dynamic> item) {
    for (final key in const ['filesize', 'fileSize', 'size']) {
      final v = item[key];
      if (v is num && v > 0) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null && n > 0) return n;
      }
    }
    return 0;
  }

  /// 安全读取响应中的整数字段（num 或数字字符串；缺失/非法返回 null）。
  static int? _intOf(dynamic v) {
    if (v is num && v >= 0) return v.toInt();
    if (v is String) {
      final n = int.tryParse(v);
      if (n != null && n >= 0) return n;
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is String) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
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
                  tooltip: '上传音乐',
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: _showUploadMenu,
                ),
              ],
      ),
      body: ContentWidth(
        child: SecondaryMiniPlayerHost(
        child: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildError()
              : _songs.isEmpty
                  ? Md3PullToRefresh(
                      onRefresh: () => _loadCloudSongs(showLoading: false),
                      child: ListView(
                        children: [_buildEmpty()]),
                    )
                  : Md3PullToRefresh(
                      onRefresh: () => _loadCloudSongs(showLoading: false),
                      child: Column(
                        children: [
                          if (!_isSelectMode) const CloudUploadBanner(),
                          if (!_isSelectMode)
                            CloudCapacityCard(
                              usedBytes: _usedBytes,
                              quotaBytes: _quotaBytes,
                              songCount:
                                  _cloudTotal > 0 ? _cloudTotal : _songs.length,
                            ),
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
                                            _selectedIndices.contains(index,
                                    ),
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
                        ],
                  ),
                      ),
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
    showM3EModalBottomSheet<void>(
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
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.sm),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '共 ${_songs.length} 首'
              '${_cloudTotal > _songs.length ? '（云端共 $_cloudTotal 首）' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      child: TextField(
        controller: _searchController,
        contextMenuBuilder: buildAppTextContextMenu,
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
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.none),
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
          const Gap(AppSpacing.md),
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
          const Gap(AppSpacing.md),
          Text(
            '云盘暂无音乐',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          const Gap(AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
            child: Text(
              '在酷狗音乐 App 中上传歌曲后即可在此查看',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const Gap(AppSpacing.lg),
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
          const Gap(AppSpacing.md),
          Text(
            _error!,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const Gap(AppSpacing.lg),
          FilledButton.tonal(
            onPressed: _loadCloudSongs,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
