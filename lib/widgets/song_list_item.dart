import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../providers/downloads_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';

class SongListItem extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onMoreTap;
  final bool showDuration;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
  });

  void _showDownloadDialog(BuildContext context) {
    final downloadsProvider = context.read<DownloadsProvider>();
    final api = KugouApiClient();

    if (!api.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载: ${song.title}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(song.artist, style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text('选择音质', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 8),
            _buildQualityOption(ctx, '标准音质 (128kbps)', '128', downloadsProvider),
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

  Widget _buildQualityOption(BuildContext context, String label, String quality, DownloadsProvider provider) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.music_note, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: () {
        Navigator.pop(context);
        provider.downloadSong(song, quality: quality);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final favoritesProvider = context.watch<FavoritesProvider>();
    final downloadsProvider = context.watch<DownloadsProvider>();
    final isCurrentSong = playerProvider.currentSong?.id == song.id;
    final isFavorited = favoritesProvider.isFavorite(song.id);
    final isDownloaded = downloadsProvider.isDownloaded(song.id);
    final isDownloading = downloadsProvider.isDownloading(song.id);
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: song.artworkUri != null
            ? CachedNetworkImage(
                imageUrl: song.artworkUri!,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(
                  width: 48,
                  height: 48,
                  color: colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.music_note,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                errorWidget: (_, _, _) => Container(
                  width: 48,
                  height: 48,
                  color: colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.music_note,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.music_note,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrentSong
            ? TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w600)
            : null,
      ),
      subtitle: Text(
        '${song.artist} - ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrentSong
            ? TextStyle(color: colorScheme.primary.withValues(alpha: 0.7))
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrentSong && playerProvider.isPlaying)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
            )
          else if (isCurrentSong)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.equalizer,
                size: 16,
                color: colorScheme.primary,
              ),
            ),
          if (showDuration)
            Text(
              song.displayDuration,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          IconButton(
            icon: Icon(
              isFavorited ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: isFavorited ? colorScheme.error : colorScheme.onSurfaceVariant,
            ),
            onPressed: () => favoritesProvider.toggleFavorite(song),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: Icon(
              isDownloaded ? Icons.download_done : (isDownloading ? Icons.downloading : Icons.download),
              size: 20,
              color: isDownloaded ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            onPressed: isDownloaded || isDownloading
                ? null
                : () => _showDownloadDialog(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          if (onMoreTap != null)
            IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              onPressed: onMoreTap,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
      onTap: onTap,
      selected: isCurrentSong,
    );
  }
}
