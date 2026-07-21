import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../providers/downloads_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';
import 'playing_spectrum_indicator.dart';

class SongListItem extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onMoreTap;
  final bool showDuration;
  final bool forceFavorited;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
    this.forceFavorited = false,
  });

  void _showMoreMenu(BuildContext context) {
    final downloadsProvider = context.read<DownloadsProvider>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(song.displayName, style: const TextStyle(fontSize: 14)),
              subtitle: Text(song.artist, style: const TextStyle(fontSize: 12)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _showDownloadDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('下一首播放', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                final player = context.read<PlayerProvider>();
                player.appendPlaylist([song]);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已加入下一首'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            if (downloadsProvider.isDownloaded(song.id))
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除下载', style: TextStyle(fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  downloadsProvider.removeTask(song.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showDownloadDialog(BuildContext context) {
    final downloadsProvider = context.read<DownloadsProvider>();
    final api = KugouApiClient();

    if (!api.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先登录'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载: ${song.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(song.artist, style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text('选择音质', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 8),
            _buildQualityOption(
              ctx,
              '标准音质 (128kbps)',
              '128',
              downloadsProvider,
            ),
            _buildQualityOption(ctx, '高音质 (320kbps)', '320', downloadsProvider),
            _buildQualityOption(ctx, '无损音质 (FLAC)', 'flac', downloadsProvider),
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

  Widget _buildQualityOption(
    BuildContext context,
    String label,
    String quality,
    DownloadsProvider provider,
  ) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.music_note, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: () {
        Navigator.pop(context);
        _triggerDownload(context, provider, quality);
      },
    );
  }

  /// 真正触发下载，并根据 downloadSong 返回值给出 SnackBar 反馈。
  /// 之前直接 fire-and-forget，权限失败时用户看不到任何提示，
  /// 表现为"点了下载什么都不发生"。
  Future<void> _triggerDownload(
    BuildContext context,
    DownloadsProvider provider,
    String quality,
  ) async {
    // 先捕获 messenger 引用，await 之后 BuildContext 可能已失效
    final messenger = ScaffoldMessenger.of(context);
    final songTitle = song.title;
    final started = await provider.downloadSong(song, quality: quality);
    if (started) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('开始下载: $songTitle'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (provider.lastPermissionGranted == false) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('存储权限被拒，请在系统设置中授予后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('无法下载: $songTitle（未获取到下载链接）'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final favoritesProvider = context.watch<FavoritesProvider>();
    context.watch<DownloadsProvider>();
    final isCurrentSong = playerProvider.currentSong?.id == song.id;
    final isFavorited = forceFavorited || favoritesProvider.isFavorite(song.id);
    final colorScheme = Theme.of(context).colorScheme;

    const imgSize = 52.0; // 正方形封面，不被 ListTile 压缩

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // 封面图 —— 固定正方形
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: imgSize,
                height: imgSize,
                child: song.artworkUri != null
                    ? CachedNetworkImage(
                        imageUrl: song.artworkUri!,
                        width: imgSize,
                        height: imgSize,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
                        ),
                        errorWidget: (_, _, _) => Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
                      ),
              ),
            ),
            const SizedBox(width: 12),

            // 标题 + 副标题
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isCurrentSong ? colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} - ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isCurrentSong
                          ? colorScheme.primary.withValues(alpha: 0.7)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // 右侧操作区：时长 / 红心 / 三点
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (isCurrentSong)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    // 频谱动画标识：3 根粒度柱 sin 波动
                    // 暂停时 isPlaying=false → ticker 停止，保留最后一帧
                    // 继续播放时 isPlaying=true → ticker 恢复，动画继续
                    child: PlayingSpectrumIndicator(
                      color: colorScheme.primary,
                      size: 14,
                      isPlaying: playerProvider.isPlaying,
                    ),
                  ),
                if (showDuration)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(song.displayDuration, style: const TextStyle(fontSize: 11)),
                  ),
                GestureDetector(
                  onTap: () => favoritesProvider.toggleFavorite(song),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                    child: Icon(
                      isFavorited ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: isFavorited ? colorScheme.error : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => _showMoreMenu(context),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                    child: Icon(Icons.more_vert, size: 18, color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
