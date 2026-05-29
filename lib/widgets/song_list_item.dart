import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../providers/player_provider.dart';

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

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final isCurrentSong = playerProvider.currentSong?.id == song.id;
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
