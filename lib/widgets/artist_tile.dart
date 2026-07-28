import 'package:flutter/material.dart';

import '../data/models/artist.dart';
import 'smart_artwork_image.dart';

class ArtistTile extends StatelessWidget {
  final Artist artist;
  final VoidCallback? onTap;

  const ArtistTile({
    super.key,
    required this.artist,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: SmartArtworkImage(
          artworkUri: artist.artworkUri,
          size: 48,
          borderRadius: 24,
        ),
      ),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${artist.songCount} 首歌曲 · ${artist.albumCount} 张专辑',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: onTap,
    );
  }
}
