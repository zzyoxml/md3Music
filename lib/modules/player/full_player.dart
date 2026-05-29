import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';

class FullPlayer extends StatefulWidget {
  const FullPlayer({super.key});

  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _lyrics = '';
  bool _isLoadingLyrics = false;
  String? _lastSongId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        _fetchLyrics(song);
      }
    });
  }

  @override
  void didUpdateWidget(covariant FullPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _lastSongId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchLyrics(song);
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _fetchLyrics(dynamic song) async {
    final songId = song.id as String;
    if (songId == _lastSongId) return;
    _lastSongId = songId;

    setState(() {
      _isLoadingLyrics = true;
      _lyrics = '';
    });

    try {
      final kugouProvider = context.read<KugouProvider>();
      await kugouProvider.getLyric(songId, songName: song.title);

      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          final lyric = kugouProvider.lyric;
          _lyrics = lyric?.displayLyric ?? '';
        });
      }
    } catch (e) {
      debugPrint('_fetchLyrics error: $e');
      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyrics = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;
    final colorScheme = Theme.of(context).colorScheme;

    if (currentSong == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('暂无播放')),
      );
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: ResponsiveLayout(
        compact: (_) => _buildCompactLayout(playerProvider, currentSong, colorScheme),
        expanded: (_) => _buildExpandedLayout(playerProvider, currentSong, colorScheme),
      ),
    );
  }

  Widget _buildCompactLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildArtworkView(playerProvider, currentSong, colorScheme),
                _isLoadingLyrics
                    ? const Center(child: CircularProgressIndicator())
                    : LyricsView(
                        lyrics: _lyrics,
                        position: playerProvider.position,
                        onSeek: (position) {
                          playerProvider.seek(position);
                        },
                      ),
                CommentsView(songHash: currentSong.id, albumAudioId: currentSong.albumAudioId),
              ],
            ),
          ),
          _buildControls(playerProvider, colorScheme),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildExpandedLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return SafeArea(
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Center(
              child: _buildArtworkView(playerProvider, currentSong, colorScheme),
            ),
          ),
          Expanded(
            flex: 5,
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildSongInfo(playerProvider, currentSong, colorScheme),
                      _isLoadingLyrics
                          ? const Center(child: CircularProgressIndicator())
                          : LyricsView(
                              lyrics: _lyrics,
                              position: playerProvider.position,
                              onSeek: (position) {
                                playerProvider.seek(position);
                              },
                            ),
                      CommentsView(songHash: currentSong.id, albumAudioId: currentSong.albumAudioId),
                    ],
                  ),
                ),
                _buildControls(playerProvider, colorScheme),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: '封面'),
                Tab(text: '歌词'),
                Tab(text: '评论'),
              ],
              labelStyle: Theme.of(context).textTheme.labelMedium,
              indicatorSize: TabBarIndicatorSize.label,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildArtworkView(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: currentSong.artworkUri != null
                  ? CachedNetworkImage(
                      imageUrl: currentSong.artworkUri!,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          size: 64,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      errorWidget: (_, _, _) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          size: 64,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.music_note,
                        size: 64,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            currentSong.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            currentSong.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildSongInfo(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              currentSong.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              currentSong.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(PlayerProvider playerProvider, ColorScheme colorScheme) {
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildProgressBar(playerProvider, position, duration, colorScheme),
          const SizedBox(height: 8),
          _buildMainControls(playerProvider, colorScheme),
          const SizedBox(height: 8),
          _buildSecondaryControls(playerProvider, colorScheme),
        ],
      ),
    );
  }

  Widget _buildProgressBar(
    PlayerProvider playerProvider,
    Duration position,
    Duration duration,
    ColorScheme colorScheme,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(position),
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: Slider(
            value: duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0,
            onChanged: (value) {
              final newPosition = Duration(
                milliseconds: (duration.inMilliseconds * value).round(),
              );
              playerProvider.seek(newPosition);
            },
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(duration),
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildMainControls(PlayerProvider playerProvider, ColorScheme colorScheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: Icon(
            playerProvider.shuffleEnabled
                ? Icons.shuffle
                : Icons.shuffle_outlined,
            color: playerProvider.shuffleEnabled
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          onPressed: () => playerProvider.toggleShuffle(),
        ),
        const SizedBox(width: 8),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_previous),
          onPressed: () => playerProvider.previous(),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          iconSize: 48,
          icon: Icon(
            playerProvider.isPlaying ? Icons.pause : Icons.play_arrow,
          ),
          onPressed: () {
            if (playerProvider.isPlaying) {
              playerProvider.pause();
            } else {
              playerProvider.resume();
            }
          },
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_next),
          onPressed: () => playerProvider.next(),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(
            _getLoopModeIcon(playerProvider.loopMode),
            color: playerProvider.loopMode != AppLoopMode.off
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          onPressed: () => playerProvider.toggleLoopMode(),
        ),
      ],
    );
  }

  Widget _buildSecondaryControls(PlayerProvider playerProvider, ColorScheme colorScheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.volume_up),
          onPressed: () => _showVolumeDialog(playerProvider),
        ),
        TextButton(
          onPressed: () => _showSpeedDialog(playerProvider),
          child: Text('${playerProvider.speed}x'),
        ),
        IconButton(
          icon: const Icon(Icons.playlist_play),
          onPressed: () {},
        ),
      ],
    );
  }

  void _showVolumeDialog(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('音量'),
          content: StatefulBuilder(
            builder: (context, setState) {
              return Slider(
                value: playerProvider.volume,
                onChanged: (value) {
                  playerProvider.setVolume(value);
                  setState(() {});
                },
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        );
      },
    );
  }

  void _showSpeedDialog(PlayerProvider playerProvider) {
    final speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('播放速度'),
          children: speeds.map((speed) {
            return SimpleDialogOption(
              onPressed: () {
                playerProvider.setSpeed(speed);
                Navigator.pop(context);
              },
              child: Text(
                speed == 1.0 ? '1.0x (正常)' : '${speed}x',
                style: TextStyle(
                  color: playerProvider.speed == speed
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  IconData _getLoopModeIcon(AppLoopMode mode) {
    switch (mode) {
      case AppLoopMode.off:
        return Icons.repeat;
      case AppLoopMode.one:
        return Icons.repeat_one;
      case AppLoopMode.all:
        return Icons.repeat;
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
