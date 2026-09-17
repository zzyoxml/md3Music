import 'package:flutter/material.dart';

import '../data/models/album.dart';
import 'smart_artwork_image.dart';

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;

  const AlbumCard({
    super.key,
    required this.album,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            children: [
              Expanded(
                child: SmartArtworkImage(
                  artworkUri: album.artworkUri,
                  size: double.infinity,
                  borderRadius: 0,
                ),
              ),
              _buildInfo(colorScheme, textTheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo(ColorScheme colorScheme, TextTheme textTheme) {
    final hasArtist = album.artist.isNotEmpty;
    return Container(
      // 文字信息块在卡片下方区域内垂直居中（minHeight 兜住单行标题）
      constraints: const BoxConstraints(minHeight: 40),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            // 无副标题（如热门歌单 artist 为空）时不渲染空行，避免文字下方留大片空白
            if (hasArtist) ...[
              const SizedBox(height: 2),
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
