import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/library_provider.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'songs_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = context.watch<LibraryProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final hasMusic = libraryProvider.songs.isNotEmpty ||
        libraryProvider.albums.isNotEmpty ||
        libraryProvider.artists.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐库'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '歌曲'),
            Tab(text: '专辑'),
            Tab(text: '歌手'),
          ],
        ),
      ),
      body: !hasMusic && !libraryProvider.isLoading
          ? _buildEmptyState(colorScheme)
          : TabBarView(
              controller: _tabController,
              children: [
                SongsPage(songs: libraryProvider.songs),
                AlbumsPage(albums: libraryProvider.albums),
                ArtistsPage(artists: libraryProvider.artists),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          context.read<LibraryProvider>().loadLocalMusic();
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有本地音乐',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击扫描按钮添加本地音乐',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () {
              context.read<LibraryProvider>().loadLocalMusic();
            },
            child: const Text('扫描音乐'),
          ),
        ],
      ),
    );
  }
}
