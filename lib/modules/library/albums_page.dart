import 'package:flutter/material.dart';

import '../../core/layout/responsive_layout.dart';
import '../../data/models/album.dart';
import '../../widgets/album_card.dart';

class AlbumsPage extends StatelessWidget {
  final List<Album> albums;

  const AlbumsPage({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return Center(
        child: Text(
          '暂无专辑',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenType = getScreenType(constraints.maxWidth);
        int crossAxisCount;
        switch (screenType) {
          case ScreenType.compact:
            crossAxisCount = 2;
            break;
          case ScreenType.medium:
            crossAxisCount = 3;
            break;
          case ScreenType.expanded:
            crossAxisCount = 4;
        }

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.72,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: albums.length,
          itemBuilder: (context, index) {
            return AlbumCard(
              album: albums[index],
              onTap: () {},
            );
          },
        );
      },
    );
  }
}
