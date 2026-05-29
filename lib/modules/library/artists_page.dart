import 'package:flutter/material.dart';

import '../../data/models/artist.dart';
import '../../widgets/artist_tile.dart';

class ArtistsPage extends StatelessWidget {
  final List<Artist> artists;

  const ArtistsPage({super.key, required this.artists});

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return Center(
        child: Text(
          '暂无歌手',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (context, index) {
        return ArtistTile(
          artist: artists[index],
          onTap: () {},
        );
      },
    );
  }
}
