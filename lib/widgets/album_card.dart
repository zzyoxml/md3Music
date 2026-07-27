import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/models/album.dart';

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
      // M3 Expressive：大卡片用 32dp 圆角（原 16dp）
      borderRadius: BorderRadius.circular(32),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            children: [
              Expanded(
                child: _buildImage(colorScheme),
              ),
              _buildInfo(colorScheme, textTheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(ColorScheme colorScheme) {
    if (album.artworkUri != null) {
      return CachedNetworkImage(
        imageUrl: album.artworkUri!,
        fit: BoxFit.cover,
        width: double.infinity,
        placeholder: (_, _) => _buildPlaceholder(colorScheme),
        errorWidget: (_, _, _) => _buildPlaceholder(colorScheme),
      );
    }
    return _buildPlaceholder(colorScheme);
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.album,
        size: 40,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildInfo(ColorScheme colorScheme, TextTheme textTheme) {
    // M3 Expressive：内边距加大（原 10/6 → 14/10），让信息区更"呼吸"
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // M3 Expressive：专辑名用 titleSmall（14sp w500）替代 labelMedium（12sp w500）
            style: textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            album.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // M3 Expressive：副标题用 labelMedium，色彩稍弱
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
