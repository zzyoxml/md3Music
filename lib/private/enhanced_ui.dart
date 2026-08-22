import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:md3_download_cache/md3_download_cache.dart';

import '../core/services/folder_picker_service.dart';
import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../modules/player/full_player.dart';
import '../modules/player/full_player_am.dart';
import '../modules/playlist/playlist_page.dart';
import '../modules/settings/settings_page.dart';
import '../modules/user/play_history_page.dart';
import '../modules/user/user_center_page.dart';
import 'private_settings.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import '../widgets/song_list_item.dart';
import 'downloads_page.dart';
import 'downloads_provider.dart';

/// 私有 UI 增强层：把公开基类的「中性扩展点」接到下载/缓存功能 UI 上。
///
/// 本文件仅存在于私有构建（导出公开版本时整体排除）。

/// 安装全部 UI 钩子。由 lib/private/main_private.dart 在 runApp 前调用。
void installUiHooks() {
  SongListItem.extraMenuTilesBuilder = _buildSongMenuExtraTiles;
  FullPlayer.coverLongPressCallback = _showDownloadDialog;
  AmStyleFullPlayer.coverLongPressCallback = _showDownloadDialog;
  SettingsPage.extraCategories = _buildSettingsExtraCategories();
  SettingsPage.extraSearchIndexEntries = _buildSettingsSearchIndexEntries();
  UserCenterPage.extraActionItemsBuilder = _buildUserCenterExtraActions;
  PlaylistPage.extraMultiSelectActions = _buildMultiSelectExtraActions;
  // 可播放（已本地持久化）筛选：歌单页 / 历史页共用一个按页隔离的实现
  PlaylistPage.songFilterHook = _applyPlayableFilter;
  PlaylistPage.songFilterListenable = _filterRevision;
  PlaylistPage.extraAppBarActionsBuilder =
      (context) => const [_PlayableFilterButton('playlist')];
  PlayHistoryPage.songFilterHook = _applyPlayableFilter;
  PlayHistoryPage.songFilterListenable = _filterRevision;
  PlayHistoryPage.extraAppBarActionsBuilder =
      (context) => const [_PlayableFilterButton('history')];
}

// ==================== 可播放（已本地持久化）筛选 ====================

/// 各页面的筛选开关状态，按页面 key 隔离（'playlist' / 'history'）。
final Map<String, bool> _playableFilterEnabled = {};

/// 筛选状态变更信号：公开页面通过 songFilterListenable 监听以触发重建。
final ValueNotifier<int> _filterRevision = ValueNotifier<int>(0);

/// 同步过滤：实时查包内缓存索引（内存索引，开销低）。
List<Song> _applyPlayableFilter(String pageKey, List<Song> songs) {
  if (_playableFilterEnabled[pageKey] != true) return songs;
  final ids = <String>{};
  for (final song in songs) {
    try {
      final entry = StreamCacheRepository.instance.getEntry(song.id);
      if (entry != null && entry.audio.isNotEmpty) {
        ids.add(song.id);
      }
    } catch (_) {}
  }
  return songs.where((s) => ids.contains(s.id)).toList();
}

/// 筛选开关按钮（注入到歌单页/历史页顶栏）。
class _PlayableFilterButton extends StatelessWidget {
  final String pageKey;

  const _PlayableFilterButton(this.pageKey);

  @override
  Widget build(BuildContext context) {
    final enabled = _playableFilterEnabled[pageKey] ?? false;
    return IconButton(
      icon: Icon(
        enabled ? Icons.filter_alt : Icons.filter_alt_outlined,
        color: enabled ? Theme.of(context).colorScheme.primary : null,
      ),
      tooltip: enabled ? '显示全部' : '仅显示已缓存',
      onPressed: () {
        _playableFilterEnabled[pageKey] = !enabled;
        _filterRevision.value++;
      },
    );
  }
}

// ==================== 设置搜索索引：私有分类关键词 ====================

List<({String label, String category, String aliases})>
    _buildSettingsSearchIndexEntries() {
  return [
    (label: '启用边听边存', category: '边听边存', aliases: '边听边存 缓存 流量'),
    (label: '缓存上限', category: '边听边存', aliases: '缓存 上限 大小'),
    (label: '清理缓存', category: '边听边存', aliases: '缓存 清理'),
    (label: '下载目录', category: '下载', aliases: '下载 目录 路径'),
    (label: '下载内嵌逐字歌词', category: '下载', aliases: '逐字歌词 歌词 内嵌'),
  ];
}

// ==================== 歌曲更多菜单：下载 / 删除下载 ====================

List<Widget> _buildSongMenuExtraTiles(BuildContext ctx, Song song) {
  if (!song.isOnline) return const [];
  final downloadsProvider = ctx.read<DownloadsProvider>();
  return [
    ListTile(
      leading: const Icon(Icons.download),
      title: const Text('下载'),
      onTap: () {
        Navigator.pop(ctx);
        _showDownloadDialog(ctx, song);
      },
    ),
    if (downloadsProvider.isDownloaded(song.id))
      ListTile(
        leading: const Icon(Icons.delete_outline),
        title: const Text('删除下载'),
        onTap: () {
          Navigator.pop(ctx);
          downloadsProvider.removeTask(song.id);
        },
      ),
  ];
}

// ==================== 下载音质选择对话框（歌曲菜单 / 播放页封面长按共用） ====================

void _showDownloadDialog(BuildContext context, dynamic song) async {
  final downloadsProvider = context.read<DownloadsProvider>();
  final isDownloaded = downloadsProvider.isDownloaded(song.id);
  final isDownloading = downloadsProvider.isDownloading(song.id);

  if (isDownloaded) {
    showToast('已下载: ${song.displayName ?? song.title}');
    return;
  }
  if (isDownloading) {
    showToast('正在下载: ${song.displayName ?? song.title}');
    return;
  }

  final api = KugouApiClient();
  if (!api.isLoggedIn) {
    showToast('请先登录', long: true);
    return;
  }

  showToast('正在查询可用音质...', long: true);
  final available = await api.getAvailableQualities(
    song.id,
    albumId: song.albumId,
    albumAudioId: song.albumAudioId,
  );
  if (!context.mounted) return;

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('下载: ${song.displayName ?? song.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(song.artist ?? '', style: Theme.of(ctx).textTheme.bodyMedium),
          const SizedBox(height: 16),
          Text('选择音质', style: Theme.of(ctx).textTheme.titleSmall),
          const SizedBox(height: 8),
          _qualityOption(
            ctx,
            '标准音质 (128kbps)',
            '128',
            song,
            downloadsProvider,
            enabled: available.contains('128'),
          ),
          _qualityOption(
            ctx,
            '高音质 (320kbps)',
            'hq',
            song,
            downloadsProvider,
            enabled: available.contains('hq'),
          ),
          _qualityOption(
            ctx,
            '无损音质 (FLAC)',
            'flac',
            song,
            downloadsProvider,
            enabled: available.contains('flac'),
          ),
          _qualityOption(
            ctx,
            'Hi-Res 无损',
            'high',
            song,
            downloadsProvider,
            enabled: available.contains('high'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

Widget _qualityOption(
  BuildContext context,
  String label,
  String quality,
  dynamic song,
  DownloadsProvider provider, {
  bool enabled = true,
}) {
  return ListTile(
    dense: true,
    leading: Icon(
      Icons.music_note,
      size: 20,
      color: enabled ? null : Theme.of(context).disabledColor,
    ),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 14,
        color: enabled ? null : Theme.of(context).disabledColor,
      ),
    ),
    trailing: enabled
        ? null
        : Text(
            '需要VIP',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).disabledColor,
            ),
          ),
    onTap: enabled
        ? () async {
            Navigator.pop(context);
            final displayName = song.displayName ?? song.title;
            showToast('开始下载: $displayName');
            final actual = await provider.downloadSong(song, quality: quality);
            if (actual == 'trial_blocked') {
              if (context.mounted) {
                showToast(
                  '你的账号已被kugou风控,请等待kugou解除风控后再试',
                  long: true,
                );
              }
            } else if (actual != null &&
                actual != quality &&
                context.mounted) {
              showToast(
                '${KugouQuality.labelOf(quality)}不可用，已降级为${KugouQuality.labelOf(actual)}',
                long: true,
              );
            }
          }
        : null,
  );
}

// ==================== 设置页：边听边存 / 下载 分类 ====================

List<(String, IconData, Widget Function(ColorScheme))>
    _buildSettingsExtraCategories() {
  return [
    ('边听边存', Icons.download_outlined, (cs) => const _StreamCacheSection()),
    ('下载', Icons.file_download_outlined, (cs) => const _DownloadSection()),
  ];
}

/// 边听边存 section：开关、容量上限、缓存可视化、清理按钮（由设置页分类注入）。
class _StreamCacheSection extends StatefulWidget {
  const _StreamCacheSection();

  @override
  State<_StreamCacheSection> createState() => _StreamCacheSectionState();
}

class _StreamCacheSectionState extends State<_StreamCacheSection> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 启用开关
        FutureBuilder<bool>(
          future: PrivateSettings().getStreamCacheEnabled(),
          builder: (context, snapshot) {
            final enabled = snapshot.data ?? true;
            return SwitchListTile(
              title: const Text('启用边听边存'),
              subtitle: const Text('播放时自动缓存音频、歌词和封面，减少流量消耗'),
              value: enabled,
              onChanged: (v) async {
                HapticFeedback.lightImpact();
                await PrivateSettings().setStreamCacheEnabled(v);
                setState(() {}); // 刷新整个页面
              },
            );
          },
        ),
        // 2. 缓存上限选择
        FutureBuilder<int>(
          future: PrivateSettings().getStreamCacheLimitMb(),
          builder: (context, snapshot) {
            final limitMb = snapshot.data ?? 2048;
            final label = limitMb == 0 ? '无限制' : _formatLimit(limitMb);
            return ListTile(
              leading: const Icon(Icons.storage),
              title: const Text('缓存上限'),
              subtitle: Text(label),
              onTap: () => _showCacheLimitDialog(limitMb),
            );
          },
        ),
        // 3. 缓存可视化
        _buildCacheStatsWidget(colorScheme),
        // 4. 清理缓存按钮
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('清理缓存'),
          onTap: () => _showClearCacheConfirmDialog(),
        ),
      ],
    );
  }

  /// 格式化缓存上限：MB → GB 显示（1024 MB = 1 GB）
  String _formatLimit(int mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB';
    }
    return '$mb MB';
  }

  /// 缓存上限选择对话框：1GB / 2GB / 4GB / 8GB / 无限制
  void _showCacheLimitDialog(int currentMb) {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('缓存上限'),
          children: [
            _buildLimitOption(1024, currentMb, '1 GB'),
            _buildLimitOption(2048, currentMb, '2 GB'),
            _buildLimitOption(4096, currentMb, '4 GB'),
            _buildLimitOption(8192, currentMb, '8 GB'),
            _buildLimitOption(0, currentMb, '无限制'),
          ],
        );
      },
    );
  }

  /// 单个上限选项：选中项左侧显示勾号
  Widget _buildLimitOption(int value, int currentMb, String label) {
    return SimpleDialogOption(
      onPressed: () async {
        await PrivateSettings().setStreamCacheLimitMb(value);
        if (context.mounted) Navigator.pop(context);
        setState(() {});
      },
      child: Row(
        children: [
          if (value == currentMb)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          else
            const SizedBox(width: 24),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  /// 缓存可视化组件：进度条 + 各分类占用明细
  Widget _buildCacheStatsWidget(ColorScheme colorScheme) {
    return FutureBuilder<CacheStats>(
      future: StreamCacheManager.instance.getCacheStats(),
      builder: (context, snapshot) {
        final stats = snapshot.data;
        final totalBytes = stats?.totalBytes ?? 0;
        final audioBytes = stats?.audioBytes ?? 0;
        final lyricsBytes = stats?.lyricsBytes ?? 0;
        final artworkBytes = stats?.artworkBytes ?? 0;
        final songCount = stats?.songCount ?? 0;

        return FutureBuilder<int>(
          future: PrivateSettings().getStreamCacheLimitMb(),
          builder: (context, limitSnapshot) {
            final limitMb = limitSnapshot.data ?? 2048;
            final limitBytes = limitMb * 1024 * 1024;
            final progress = limitBytes > 0
                ? (totalBytes / limitBytes).clamp(0.0, 1.0)
                : 0.0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '已使用 ${_formatBytes(totalBytes)} / '
                    '${limitMb == 0 ? "无限制" : _formatBytes(limitBytes)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  M3ELinearProgressIndicator(
                    value: progress,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '音频 ${_formatBytes(audioBytes)} · '
                    '歌词 ${_formatBytes(lyricsBytes)} · '
                    '封面 ${_formatBytes(artworkBytes)} · '
                    '$songCount 首',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 文件大小格式化：B / KB / MB / GB
  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// 清理边听边存缓存确认对话框
  void _showClearCacheConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清理缓存'),
          content: const Text('确定要清理所有边听边存的缓存吗？此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                await StreamCacheManager.instance.clearCache();
                if (context.mounted) Navigator.pop(context);
                setState(() {}); // 刷新显示
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}

/// 下载 section：自定义下载目录 + 内嵌逐字歌词开关（由设置页分类注入）。
class _DownloadSection extends StatefulWidget {
  const _DownloadSection();

  @override
  State<_DownloadSection> createState() => _DownloadSectionState();
}

class _DownloadSectionState extends State<_DownloadSection> {
  String? _downloadDir;

  @override
  void initState() {
    super.initState();
    _loadDir();
  }

  Future<void> _loadDir() async {
    final dir = await PrivateSettings().getDownloadDir();
    if (!mounted) return;
    setState(() => _downloadDir = dir);
  }

  /// 打开 Android 原生文件夹选择器（SAF）。
  Future<void> _showDownloadDirDialog() async {
    final path = await FolderPickerService.pickFolder();
    if (path == null) return; // 用户取消
    setState(() => _downloadDir = path);
    await PrivateSettings().setDownloadDir(_downloadDir);
    if (!mounted) return;
    showToast('下载目录已设置为：$path', long: true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('下载目录'),
          subtitle: Text(
            _downloadDir?.isNotEmpty == true
                ? _downloadDir!
                : '默认（Android/data/包名）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showDownloadDirDialog(),
        ),
        FutureBuilder<bool>(
          future: PrivateSettings().getDownloadWordLevelLyrics(),
          builder: (context, snapshot) {
            final value = snapshot.data ?? true;
            return SwitchListTile(
              secondary: const Icon(Icons.lyrics),
              title: const Text('下载内嵌逐字歌词'),
              subtitle: const Text('开启后嵌入字级 LRC 歌词，关闭则嵌入行级 LRC。无逐字数据时自动降级为行级'),
              value: value,
              onChanged: (v) async {
                HapticFeedback.lightImpact();
                await PrivateSettings().setDownloadWordLevelLyrics(v);
                setState(() {});
              },
            );
          },
        ),
      ],
    );
  }
}

// ==================== 用户中心：下载入口 ====================

List<Widget> _buildUserCenterExtraActions(BuildContext context, ColorScheme cs) {
  return [
    GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DownloadsPage()),
        );
      },
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.download, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text('下载', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    ),
  ];
}

// ==================== 歌单多选栏：批量下载 ====================

List<Widget> _buildMultiSelectExtraActions(
  BuildContext context,
  ColorScheme colorScheme,
  int selectedCount,
  List<Song> selectedSongs,
) {
  return [
    IconButton(
      icon: Icon(
        Icons.download_outlined,
        color: selectedCount > 0 ? colorScheme.primary : null,
      ),
      onPressed: selectedCount > 0
          ? () => _showBatchDownloadDialog(context, selectedSongs)
          : null,
      tooltip: '下载',
    ),
  ];
}

void _showBatchDownloadDialog(BuildContext context, List<Song> selectedSongs) {
  final api = KugouApiClient();
  if (!api.isLoggedIn) {
    showToast('请先登录', long: true);
    return;
  }

  if (selectedSongs.isEmpty) return;

  final qualityOptions = [
    ('标准音质 (128kbps)', '128'),
    ('高音质 (320kbps)', 'hq'),
    ('无损音质 (FLAC)', 'flac'),
    ('Hi-Res 无损', 'high'),
  ];

  showDialog(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Column(
        children: [
          const Text('批量下载'),
          Text(
            '已选 ${selectedSongs.length} 首歌曲',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '部分歌曲不支持所选音质时将自动降级',
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      children: qualityOptions.map((opt) {
        final (label, quality) = opt;
        return SimpleDialogOption(
          onPressed: () {
            Navigator.pop(ctx);
            _startBatchDownload(context, selectedSongs, quality);
          },
          child: Row(
            children: [
              Icon(Icons.music_note,
                  size: 20, color: Theme.of(ctx).colorScheme.primary),
              const SizedBox(width: 12),
              Text(label),
            ],
          ),
        );
      }).toList(),
    ),
  );
}

Future<void> _startBatchDownload(
  BuildContext context,
  List<Song> songs,
  String quality,
) async {
  final downloadsProvider = context.read<DownloadsProvider>();
  final total = songs.length;
  final progress = ValueNotifier<int>(0);
  final currentTitle = ValueNotifier<String?>(null);
  final downgraded = ValueNotifier<int>(0);
  bool dialogActive = true;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AnimatedBuilder(
      animation: Listenable.merge([progress, currentTitle, downgraded]),
      builder: (ctx, _) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            M3ELinearProgressIndicator(
              value: total > 0 ? progress.value / total : 0,
            ),
            const SizedBox(height: 16),
            Text('正在处理 ${progress.value} / $total'),
            if (currentTitle.value != null) ...[
              const SizedBox(height: 8),
              Text(
                currentTitle.value!,
                style: Theme.of(ctx).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (downgraded.value > 0) ...[
              const SizedBox(height: 4),
              Text(
                '已降级 ${downgraded.value} 首',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              dialogActive = false;
              Navigator.pop(ctx);
            },
            child: const Text('后台下载'),
          ),
        ],
      ),
    ),
  ).then((_) => dialogActive = false);

  final result = await downloadsProvider.downloadMultipleSongs(
    songs,
    quality: quality,
    onProgress: (c, t, title, d) {
      if (!dialogActive) return;
      progress.value = c;
      currentTitle.value = title;
      downgraded.value = d;
    },
  );

  if (dialogActive && context.mounted) {
    Navigator.pop(context);
  }

  if (dialogActive && context.mounted) {
    _showBatchDownloadResult(context, result);
  }

  progress.dispose();
  currentTitle.dispose();
  downgraded.dispose();
}

void _showBatchDownloadResult(BuildContext context, Map<String, int> result) {
  final success = result['success'] ?? 0;
  final failed = result['failed'] ?? 0;
  final skipped = result['skipped'] ?? 0;
  final downgraded = result['downgraded'] ?? 0;
  final blocked = result['blocked'] ?? 0;

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('批量下载完成'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('已加入下载: $success 首'),
          if (failed > 0)
            Text('失败: $failed 首',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          if (skipped > 0) Text('跳过（已下载）: $skipped 首'),
          if (downgraded > 0) Text('音质自动降级: $downgraded 首'),
          if (blocked > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '风控拦截: $blocked 首\n你的账号已被kugou风控,请等待kugou解除风控后再试',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
