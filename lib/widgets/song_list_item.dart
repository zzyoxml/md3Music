import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../providers/downloads_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_favorites_provider.dart';
import '../providers/player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import 'playing_spectrum_indicator.dart';
import 'smart_artwork_image.dart';

class SongListItem extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onMoreTap;
  final bool showDuration;
  final bool forceFavorited;

  /// 多选模式：显示圆形复选框替代封面，点击切换选中而非播放。
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectToggle;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
    this.forceFavorited = false,
    this.isSelectMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onSelectToggle,
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
              title: Text(song.displayName),
              subtitle: Text(song.artist),
            ),
            const Divider(height: 1),
            if (song.isOnline) ...[
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('下载'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showDownloadDialog(context);
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
            ],
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('下一首播放'),
              onTap: () {
                Navigator.pop(ctx);
                final player = context.read<PlayerProvider>();
                player.insertAfterCurrent([song]);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已加入下一首'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDownloadDialog(BuildContext context) async {
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

    // 查询歌曲实际可用音质
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在查询可用音质...'),
        duration: Duration(seconds: 3),
      ),
    );
    final available = await api.getAvailableQualities(
      song.id,
      albumId: song.albumId,
      albumAudioId: song.albumAudioId,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

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
            _buildQualityOption(ctx, '标准音质 (128kbps)', '128', downloadsProvider, enabled: available.contains('128')),
            _buildQualityOption(ctx, '高音质 (320kbps)', '320', downloadsProvider, enabled: available.contains('320')),
            _buildQualityOption(ctx, '无损音质 (FLAC)', 'flac', downloadsProvider, enabled: available.contains('flac')),
            _buildQualityOption(ctx, 'Hi-Res 无损', 'high', downloadsProvider, enabled: available.contains('high')),
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
          color: enabled ? null : Theme.of(context).disabledColor,
        ),
      ),
      trailing: enabled
          ? null
          : Text('需要VIP', style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).disabledColor,
            )),
      onTap: enabled ? () async {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('开始下载: ${song.displayName}'),
            duration: const Duration(seconds: 2),
          ),
        );
        final actual = await provider.downloadSong(song, quality: quality);
        if (actual != null && actual != quality && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${KugouQuality.labelOf(quality)}不可用，已降级为${KugouQuality.labelOf(actual)}'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final favoritesProvider = context.watch<FavoritesProvider>();
    final localFavoritesProvider = context.watch<LocalFavoritesProvider>();
    context.watch<DownloadsProvider>();
    final isCurrentSong = playerProvider.currentSong?.id == song.id;
    final isFavorited = forceFavorited
        ? true
        : (song.isOnline
            ? favoritesProvider.isFavorite(song.id)
            : localFavoritesProvider.isFavorite(song.id));
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    const imgSize = 52.0; // 正方形封面，不被 ListTile 压缩

    return InkWell(
      onTap: isSelectMode ? onSelectToggle : onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelectMode && isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // 多选模式：圆形复选框；普通模式：封面图
            if (isSelectMode)
              _buildCheckbox(colorScheme, imgSize)
            else
              // 封面图：智能选择 Image.network（在线/content://）或 LocalArtworkImage（文件路径）
              SmartArtworkImage(
                artworkUri: song.artworkUri,
                fallbackFilePath: song.localPath,
                songId: song.id,
                size: imgSize,
                borderRadius: 8,
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
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: isCurrentSong ? colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} - ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: isCurrentSong
                          ? colorScheme.primary.withValues(alpha: 0.7)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // 右侧操作区：多选模式下不显示
            if (!isSelectMode)
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
                      child: Text(song.displayDuration, style: textTheme.labelSmall),
                    ),
                  GestureDetector(
                    onTap: () => song.isOnline
                        ? favoritesProvider.toggleFavorite(song)
                        : localFavoritesProvider.toggleFavorite(song.id),
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

  /// 多选模式下的圆形复选框，与封面同等大小。
  Widget _buildCheckbox(ColorScheme colorScheme, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: isSelected
            ? Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary,
                ),
                child: Icon(
                  Icons.check,
                  color: colorScheme.onPrimary,
                  size: 28,
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
              ),
      ),
    );
  }
}
