import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';

const List<AudioQuality> _audioQualities = [
  AudioQuality.standard,
  AudioQuality.high,
  AudioQuality.flac,
];

class FullPlayer extends StatefulWidget {
  const FullPlayer({super.key});

  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final GlobalKey<LyricsViewState> _lyricsKey = GlobalKey<LyricsViewState>();
  String _lyrics = '';
  bool _isLoadingLyrics = false;
  String? _lastSongId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        _fetchLyrics(song);
      }
      context.read<PlayerProvider>().addListener(_onPlayerSongChanged);
    });
  }

  void _onPlayerSongChanged() {
    if (!mounted) return;
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _lastSongId) {
      _fetchLyrics(song);
    }
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
    try {
      context.read<PlayerProvider>().removeListener(_onPlayerSongChanged);
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
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
        compact: (_) =>
            _buildCompactLayout(playerProvider, currentSong, colorScheme),
        expanded: (_) =>
            _buildExpandedLayout(playerProvider, currentSong, colorScheme),
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
                        key: _lyricsKey,
                        lyrics: _lyrics,
                        position: playerProvider.position,
                        onSeek: (position) {
                          playerProvider.seek(position);
                        },
                      ),
                CommentsView(
                  songHash: currentSong.id,
                  albumAudioId: currentSong.albumAudioId,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _buildControls(playerProvider, colorScheme),
          ),
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
            flex: 4,
            child: Center(
              child: _buildArtworkView(
                playerProvider,
                currentSong,
                colorScheme,
                isExpanded: true,
              ),
            ),
          ),
          Expanded(
            flex: 6,
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
                      CommentsView(
                        songHash: currentSong.id,
                        albumAudioId: currentSong.albumAudioId,
                      ),
                    ],
                  ),
                ),
                _buildControls(playerProvider, colorScheme, isExpanded: true),
                const SizedBox(height: 8),
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
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
    );
  }

  Widget _buildArtworkView(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final horizontalPadding = isExpanded ? 16.0 : 32.0;
    final verticalPadding = isExpanded ? 8.0 : 16.0;
    final textSpacing = isExpanded ? 8.0 : 24.0;
    final iconSize = isExpanded ? 48.0 : 64.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!isExpanded) const Spacer(),
          if (isExpanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
              child: AspectRatio(
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
                              size: iconSize,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.music_note,
                              size: iconSize,
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
                            size: iconSize,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            )
          else
            Expanded(
              child: AspectRatio(
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
                              size: iconSize,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.music_note,
                              size: iconSize,
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
                            size: iconSize,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          Text(
            currentSong.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isExpanded
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            currentSong.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (!isExpanded) const Spacer(),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              currentSong.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              currentSong.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;
    final horizontalPadding = isExpanded ? 16.0 : 24.0;
    final verticalSpacing = isExpanded ? 4.0 : 8.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildProgressBar(playerProvider, position, duration, colorScheme),
          SizedBox(height: verticalSpacing),
          _buildMainControls(
            playerProvider,
            colorScheme,
            isExpanded: isExpanded,
          ),
          SizedBox(height: verticalSpacing),
          _buildSecondaryControls(
            playerProvider,
            colorScheme,
            isExpanded: isExpanded,
          ),
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
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  )
                : 0.0,
            onChanged: (value) {
              final newPosition = Duration(
                milliseconds: (duration.inMilliseconds * value).round(),
              );
              playerProvider.seek(newPosition);
              _lyricsKey.currentState?.forceScrollToPosition(newPosition);
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

  Widget _buildMainControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final spacing = isExpanded ? 4.0 : 8.0;
    final skipIconSize = isExpanded ? 28.0 : 36.0;
    final playIconSize = isExpanded ? 40.0 : 48.0;

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
        SizedBox(width: spacing),
        IconButton(
          iconSize: skipIconSize,
          icon: const Icon(Icons.skip_previous),
          onPressed: () => playerProvider.previous(),
        ),
        SizedBox(width: spacing),
        IconButton.filled(
          iconSize: playIconSize,
          icon: Icon(playerProvider.isPlaying ? Icons.pause : Icons.play_arrow),
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
        SizedBox(width: spacing),
        IconButton(
          iconSize: skipIconSize,
          icon: const Icon(Icons.skip_next),
          onPressed: () => playerProvider.next(),
        ),
        SizedBox(width: spacing),
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

  Widget _buildSecondaryControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final song = playerProvider.currentSong;
    final isFavorited =
        song != null && context.watch<FavoritesProvider>().isFavorite(song.id);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: Icon(
            isFavorited ? Icons.favorite : Icons.favorite_border,
            color: isFavorited ? colorScheme.error : colorScheme.onSurfaceVariant,
          ),
          onPressed: song != null
              ? () => context.read<FavoritesProvider>().toggleFavorite(song)
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.volume_up),
          onPressed: () => _showVolumeDialog(playerProvider),
        ),
        TextButton(
          onPressed: () => _showSpeedDialog(playerProvider),
          child: Text(
            '${playerProvider.speed}x',
            style: TextStyle(fontSize: isExpanded ? 12 : 14),
          ),
        ),
        TextButton(
          onPressed: () => _showQualityDialog(playerProvider),
          child: Text(
            playerProvider.audioQualityLabel,
            style: TextStyle(fontSize: isExpanded ? 12 : 14),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.playlist_play),
          onPressed: () => _showPlaylist(playerProvider),
        ),
      ],
    );
  }

  void _showVolumeDialog(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: StatefulBuilder(
                builder: (context, setState) {
                  final volume = playerProvider.volume;
                  final percent = (volume * 100).round();
                  final icon = volume <= 0
                      ? Icons.volume_off
                      : volume < 0.5
                          ? Icons.volume_down
                          : Icons.volume_up;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 8),
                      Slider(
                        value: volume,
                        onChanged: (value) {
                          playerProvider.setVolume(value);
                          setState(() {});
                        },
                      ),
                      Text('$percent%', style: Theme.of(context).textTheme.labelMedium),
                    ],
                  );
                },
              ),
            ),
          ),
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

  void _showQualityDialog(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('音质选择'),
          children: _audioQualities.map((quality) {
            return SimpleDialogOption(
              onPressed: () {
                playerProvider.setAudioQuality(quality);
                Navigator.pop(context);
              },
              child: Text(
                quality.label,
                style: TextStyle(
                  color: playerProvider.audioQuality == quality
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  fontWeight: playerProvider.audioQuality == quality
                      ? FontWeight.bold
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

  void _showPlaylist(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      builder: (context) {
        final playlist = playerProvider.playlist;
        return AlertDialog(
          title: const Text('播放列表'),
          content: playlist.isEmpty
              ? const Text('播放列表为空')
              : SizedBox(
                  width: 300,
                  height: 400,
                  child: ListView.builder(
                    itemCount: playlist.length,
                    itemBuilder: (context, index) {
                      final song = playlist[index];
                      final isCurrent = index == playerProvider.currentIndex;
                      return ListTile(
                        leading: isCurrent
                            ? const Icon(Icons.play_arrow, color: Colors.blue)
                            : Text('${index + 1}'),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : null,
                            color: isCurrent ? Colors.blue : null,
                          ),
                        ),
                        subtitle: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          playerProvider.playSongAt(index);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
