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
                child: _buildImage(colorScheme),
              ),
              _buildInfo(colorScheme),
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

  Widget _buildInfo(ColorScheme colorScheme) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              album.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
