import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/models/artist.dart';

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
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: colorScheme.surfaceContainerHighest,
        backgroundImage: artist.artworkUri != null
            ? CachedNetworkImageProvider(artist.artworkUri!)
            : null,
        child: artist.artworkUri == null
            ? Icon(
                Icons.person,
                color: colorScheme.onSurfaceVariant,
              )
            : null,
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: onTap,
    );
  }
}
