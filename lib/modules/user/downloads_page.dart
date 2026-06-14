import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/download_task.dart';
import '../../data/models/song.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/player_provider.dart';
import '../player/mini_player.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DownloadsProvider>().loadTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
      ),
      body: Consumer<DownloadsProvider>(
        builder: (context, downloads, _) {
          if (downloads.tasks.isEmpty) {
            return _buildEmpty();
          }
          return Column(
            children: [
              if (downloads.activeTasks.isNotEmpty) ...[
                _buildSectionHeader('下载中', downloads.activeTasks.length),
                ...downloads.activeTasks.map((task) => _buildDownloadingItem(task)),
              ],
              if (downloads.completedTasks.isNotEmpty) ...[
                _buildSectionHeader('已完成', downloads.completedTasks.length),
                Expanded(
                  child: ListView.builder(
                    itemCount: downloads.completedTasks.length,
                    itemBuilder: (context, index) {
                      return _buildCompletedItem(downloads.completedTasks[index]);
                    },
                  ),
                ),
              ] else if (downloads.activeTasks.isEmpty)
                Expanded(child: _buildEmpty()),
              const MiniPlayer(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '$title ($count)',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadingItem(DownloadTask task) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _buildArtwork(task.artworkUri, cs),
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: task.progress,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => context.read<DownloadsProvider>().cancelDownload(task.songId),
      ),
    );
  }

  Widget _buildCompletedItem(DownloadTask task) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _buildArtwork(task.artworkUri, cs),
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        task.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            onPressed: () {
              if (task.localPath != null) {
                context.read<PlayerProvider>().playSong(
                      Song(
                        id: task.songId,
                        title: task.title,
                        artist: task.artist,
                        album: '',
                        duration: Duration.zero,
                        localPath: task.localPath,
                        artworkUri: task.artworkUri,
                      ),
                    );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _confirmDelete(task),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork(String? artworkUri, ColorScheme cs) {
    if (artworkUri == null) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: artworkUri,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
      ),
    );
  }

  void _confirmDelete(DownloadTask task) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('确定要删除 "${task.title}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<DownloadsProvider>().removeTask(task.songId);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_done,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无下载',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
