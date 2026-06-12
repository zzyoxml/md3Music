import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';

class PersonalFmPage extends StatefulWidget {
  const PersonalFmPage({super.key});

  @override
  State<PersonalFmPage> createState() => _PersonalFmPageState();
}

class _PersonalFmPageState extends State<PersonalFmPage>
    with TickerProviderStateMixin {
  bool _isLoading = false;
  bool _isAppending = false;
  String _selectedMode = 'normal';
  int _selectedSongPoolId = 0;
  final int _visibleSideCount = 3;
  late AnimationController _vinylRotationController;
  late AnimationController _slideController;

  final List<Map<String, dynamic>> _modeOptions = [
    {'value': 'normal', 'label': '红心'},
    {'value': 'small', 'label': '小众'},
    {'value': 'peak', 'label': '速览'},
  ];

  final List<Map<String, dynamic>> _songPoolOptions = [
    {'value': 0, 'label': '根据口味'},
    {'value': 1, 'label': '根据风格'},
    {'value': 2, 'label': '探索'},
  ];

  @override
  void initState() {
    super.initState();
    _vinylRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final player = Provider.of<PlayerProvider>(context, listen: false);
      player.addListener(_onPlayerChanged);
      _loadPersonalFm();
    });
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    _syncFmListToPlayer(player);
  }

  @override
  void dispose() {
    try {
      final player = Provider.of<PlayerProvider>(context, listen: false);
      player.removeListener(_onPlayerChanged);
    } catch (_) {}
    _vinylRotationController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _loadPersonalFm() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await Provider.of<KugouProvider>(
        context,
        listen: false,
      ).getPersonalFm(mode: _selectedMode, songPoolId: _selectedSongPoolId);
      if (!mounted) return;
      final kugou = Provider.of<KugouProvider>(context, listen: false);
      if (kugou.personalFmSongs.isNotEmpty) {
        final player = Provider.of<PlayerProvider>(context, listen: false);
        player.onPlaylistEnd = _onPlaylistEnd;
        await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
        if (!mounted) return;
        _updateVinylAnimation(player.isPlaying);
      }
    } catch (e) {
      debugPrint('load personal fm error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    if (mounted) {
      _appendFmSongs();
    }
  }

  Future<void> _onPlaylistEnd() async {
    await _appendFmSongs();
    if (!mounted) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    await player.next();
    if (!mounted) return;
    _updateVinylAnimation(player.isPlaying);
  }

  Future<void> _appendFmSongs() async {
    if (_isAppending) return;
    setState(() => _isAppending = true);
    try {
      final kugou = Provider.of<KugouProvider>(context, listen: false);
      final currentSongs = kugou.personalFmSongs;
      final lastSong = currentSongs.isNotEmpty ? currentSongs.last : null;

      final result = await kugou.apiClient.getPersonalFm(
        mode: _selectedMode,
        songPoolId: _selectedSongPoolId,
        hash: lastSong?.hash,
        songId: lastSong?.songId,
        action: 'play',
      );
      if (!mounted) return;

      if (result != null && result.isNotEmpty) {
        final newSongs = result
            .where((s) => !currentSongs.any((c) => c.hash == s.hash))
            .toList();
        if (newSongs.isNotEmpty) {
          kugou.appendFmSongs(newSongs);
          final player = Provider.of<PlayerProvider>(context, listen: false);
          final newSongList = newSongs.map((e) => e.toSong()).toList();
          await player.appendPlaylist(newSongList);
        }
      }
    } catch (e) {
      debugPrint('append fm songs error: $e');
    } finally {
      if (mounted) {
        setState(() => _isAppending = false);
      }
    }
  }

  Future<void> _playSong(KugouSongDetail song) async {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final songs = kugou.personalFmSongs;

    final index = songs.indexWhere((s) => s.hash == song.hash);
    if (index == -1) return;

    _slideController.forward(from: 0).then((_) async {
      if (!mounted) return;
      kugou.moveToFirst(song);
      _slideController.reset();

      await _appendFmSongs();
      if (!mounted) return;

      await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
      if (!mounted) return;
      _updateVinylAnimation(player.isPlaying);
    });
  }

  Future<void> _togglePlay() async {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.resume();
    }
    _updateVinylAnimation(player.isPlaying);
  }

  void _syncFmListToPlayer(PlayerProvider player) {
    final kugou = Provider.of<KugouProvider>(context, listen: false);
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty || player.playlist.isEmpty) return;

    final currentSong = player.currentSong;
    if (currentSong == null) return;

    final index = songs.indexWhere((s) => s.hash == currentSong.id);
    if (index > 0) {
      kugou.moveToFirst(songs[index]);
    }
  }

  void _updateVinylAnimation(bool isPlaying) {
    if (isPlaying) {
      _vinylRotationController.repeat();
    } else {
      _vinylRotationController.stop();
    }
  }

  Future<void> _handleDislike(KugouSongDetail track) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await Provider.of<KugouProvider>(context, listen: false).getPersonalFm();
    } catch (e) {
      debugPrint('dislike error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatDuration(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _getModeLabel(String mode) {
    switch (mode) {
      case 'normal':
        return '红心';
      case 'small':
        return '小众';
      case 'peak':
        return '速览';
      default:
        return '红心';
    }
  }

  @override
  Widget build(BuildContext context) {
    final kugou = Provider.of<KugouProvider>(context);
    final player = Provider.of<PlayerProvider>(context);
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isLoggedIn = kugou.isLoggedIn;
    final songs = kugou.personalFmSongs;
    final currentTrack = songs.isNotEmpty ? songs[0] : null;
    final isPlaying =
        player.currentSong?.id == currentTrack?.hash && player.isPlaying;

    List<KugouSongDetail> sideTracks = [];
    if (songs.length > 1) {
      sideTracks = songs.sublist(1).take(_visibleSideCount).toList();
    }

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(textTheme, cs),
            const SizedBox(height: 20),
            if (isLoggedIn) _buildToolbar(cs, textTheme),
            const SizedBox(height: 18),
            isLoggedIn
                ? _buildRadioHero(
                    cs,
                    textTheme,
                    currentTrack,
                    isPlaying,
                    sideTracks,
                  )
                : _buildEmptyState(cs, textTheme),
            if (isLoggedIn && currentTrack != null) const SizedBox(height: 28),
            if (isLoggedIn)
              _buildNowPanel(cs, textTheme, currentTrack, isPlaying),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(TextTheme textTheme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '私人 FM',
          style: textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.04,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '实时推荐会根据你的反馈持续更新',
          style: textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant.withValues(alpha: 0.58),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme cs, TextTheme textTheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: cs.primary.withValues(alpha: 0.1),
              ),
              child: Icon(Icons.favorite, size: 32, color: cs.primary),
            ),
            const SizedBox(height: 20),
            Text(
              '登录后查看私人 FM',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '猜你喜欢和实时推荐需要登录状态',
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(ColorScheme cs, TextTheme textTheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isSmallScreen = constraints.maxWidth < 375;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 12 : 16,
            vertical: isSmallScreen ? 10 : 14,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: cs.onSurfaceVariant.withValues(alpha: 0.06),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.onSurfaceVariant.withValues(alpha: 0.025),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '推荐方式',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.08,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.54),
                      fontSize: isSmallScreen ? 10 : null,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${_getModeLabel(_selectedMode)} · ${_songPoolOptions.firstWhere((o) => o['value'] == _selectedSongPoolId)['label']}',
                      style: textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.64),
                        fontSize: isSmallScreen ? 10 : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
              SizedBox(height: isSmallScreen ? 8 : 10),
              _buildStrategySwitch(cs, isSmallScreen),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStrategySwitch(ColorScheme cs, bool isSmallScreen) {
    return Container(
      padding: EdgeInsets.all(isSmallScreen ? 3 : 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.onSurfaceVariant.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            cs.onSurfaceVariant.withValues(alpha: 0.018),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _songPoolOptions.map((option) {
          final isActive = _selectedSongPoolId == option['value'];
          return InkWell(
            onTap: () {
              setState(() => _selectedSongPoolId = option['value']);
              _loadPersonalFm();
            },
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: isSmallScreen ? 10 : 14,
                vertical: isSmallScreen ? 6 : 8,
              ),
              decoration: isActive
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0d8fff), Color(0xFF2fb4ff)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF0d8fff,
                          ).withValues(alpha: 0.22),
                          blurRadius: 10,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    )
                  : null,
              child: Text(
                option['label'],
                style: TextStyle(
                  fontSize: isSmallScreen ? 11 : 12,
                  fontWeight: FontWeight.w700,
                  color: isActive
                      ? Colors.white
                      : cs.onSurfaceVariant.withValues(alpha: 0.62),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRadioHero(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    bool isPlaying,
    List<KugouSongDetail> sideTracks,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final isSmallScreen = screenWidth < 375;
        final isMediumScreen = screenWidth >= 375 && screenWidth < 450;

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        double cardWidth, vinylSize;
        if (isLandscape) {
          cardWidth = 140.0;
          vinylSize = 120.0;
        } else if (isSmallScreen) {
          cardWidth = 120.0;
          vinylSize = 110.0;
        } else if (isMediumScreen) {
          cardWidth = 140.0;
          vinylSize = 125.0;
        } else {
          cardWidth = 160.0;
          vinylSize = 140.0;
        }

        final cardHeight = cardWidth * 1.25;

        final mainVinylLeftOffset = cardWidth * 0.55;
        final mainVinylTopOffset = (cardHeight - vinylSize) / 2;
        final sideVinylLeftPadding = cardWidth - vinylSize * 0.55;
        final sideVinylSpacing = isSmallScreen
            ? 8.0
            : (isMediumScreen ? 10.0 : 14.0);

        final maxSideVinyls = isLandscape
            ? 2
            : (isSmallScreen ? 2 : (isMediumScreen ? 3 : 4));
        final displaySideTracks = sideTracks.take(maxSideVinyls).toList();

        return SizedBox(
          height: cardHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: mainVinylLeftOffset,
                top: mainVinylTopOffset,
                child: SizedBox(
                  width: vinylSize,
                  height: vinylSize,
                  child: _buildCurrentVinyl(
                    cs,
                    currentTrack,
                    isPlaying,
                    vinylSize,
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildRadioCard(
                    cs,
                    textTheme,
                    currentTrack,
                    isPlaying,
                    cardWidth,
                  ),
                  Expanded(
                    child: SizedBox(
                      height: cardHeight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: _buildVinyls(
                          cs,
                          displaySideTracks,
                          vinylSize,
                          sideVinylLeftPadding,
                          sideVinylSpacing,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRadioCard(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? currentTrack,
    bool isPlaying,
    double width,
  ) {
    final height = width;
    final isVerySmall = width < 130;
    final isUltraSmall = width < 120;
    final textSizeMultiplier = isUltraSmall ? 0.75 : (isVerySmall ? 0.85 : 1.0);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF0d3951), Color(0xFF0f5a7a), Color(0xFF0b1620)],
          begin: Alignment(-0.84, -0.82),
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        isUltraSmall ? 6 : (isVerySmall ? 8 : 10),
        isUltraSmall ? 5 : (isVerySmall ? 6 : 8),
        isUltraSmall ? 6 : (isVerySmall ? 8 : 10),
        isUltraSmall ? 5 : (isVerySmall ? 6 : 8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeSwitch(
            cs,
            isSmall: isVerySmall,
            isUltraSmall: isUltraSmall,
          ),
          SizedBox(height: isUltraSmall ? 2 : (isVerySmall ? 3 : 4)),
          Text(
            _getModeLabel(_selectedMode),
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: -0.04,
              fontSize:
                  (isUltraSmall
                      ? 11
                      : (isVerySmall ? 12 : (width < 180 ? 14 : 16))) *
                  textSizeMultiplier,
            ),
          ),
          SizedBox(height: isUltraSmall ? 0.5 : (isVerySmall ? 1 : 2)),
          Text(
            currentTrack != null ? currentTrack.songName : '暂无推荐',
            style: textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
              fontSize: 9 * textSizeMultiplier,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: isUltraSmall ? 0.3 : (isVerySmall ? 0.5 : 1)),
          Text(
            currentTrack?.artistName ?? '',
            style: textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
              fontSize: 8 * textSizeMultiplier,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          Row(
            children: [
              _buildAudioBars(isSmall: isVerySmall, isUltraSmall: isUltraSmall),
              const Spacer(),
              _buildRadioActions(
                cs,
                isPlaying,
                currentTrack,
                isSmall: isVerySmall,
                isUltraSmall: isUltraSmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeSwitch(
    ColorScheme cs, {
    bool isSmall = false,
    bool isUltraSmall = false,
  }) {
    final padding = isUltraSmall
        ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5)
        : (isSmall
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
              : const EdgeInsets.symmetric(horizontal: 8, vertical: 4));
    final fontSize = isUltraSmall ? 8.0 : (isSmall ? 9.0 : 10.0);

    return Container(
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _modeOptions.map((option) {
          final isActive = _selectedMode == option['value'];
          return InkWell(
            onTap: () {
              setState(() => _selectedMode = option['value']);
              _loadPersonalFm();
            },
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: padding,
              decoration: isActive
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: Colors.white.withValues(alpha: 0.22),
                    )
                  : null,
              child: Text(
                option['label'],
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  color: isActive
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.74),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAudioBars({bool isSmall = false, bool isUltraSmall = false}) {
    final scale = isUltraSmall ? 0.6 : (isSmall ? 0.75 : 1.0);
    final heights = [6, 9, 5, 11, 8].map((h) => h * scale).toList();
    final width = isUltraSmall ? 1.2 : (isSmall ? 1.5 : 2.0);
    final margin = isUltraSmall
        ? const EdgeInsets.symmetric(horizontal: 0.8)
        : (isSmall
              ? const EdgeInsets.symmetric(horizontal: 1.0)
              : const EdgeInsets.symmetric(horizontal: 1.5));

    return Row(
      children: List.generate(5, (index) {
        return Container(
          width: width,
          height: heights[index].toDouble(),
          margin: margin,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Colors.white.withValues(alpha: 0.4),
          ),
        );
      }),
    );
  }

  Widget _buildRadioActions(
    ColorScheme cs,
    bool isPlaying,
    KugouSongDetail? currentTrack, {
    bool isSmall = false,
    bool isUltraSmall = false,
  }) {
    final likeButtonSize = isUltraSmall ? 24.0 : (isSmall ? 26.0 : 30.0);
    final playButtonSize = isUltraSmall ? 28.0 : (isSmall ? 32.0 : 36.0);
    final likeIconSize = isUltraSmall ? 11.0 : (isSmall ? 12.0 : 14.0);
    final playIconSize = isUltraSmall ? 14.0 : (isSmall ? 16.0 : 18.0);
    final spacing = isUltraSmall ? 3.0 : (isSmall ? 4.0 : 6.0);

    return Row(
      children: [
        InkWell(
          onTap: currentTrack != null
              ? () => _handleDislike(currentTrack)
              : null,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: likeButtonSize,
            height: likeButtonSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Colors.white.withValues(alpha: 0.12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Icon(
              Icons.favorite_border,
              color: Colors.white.withValues(alpha: 0.86),
              size: likeIconSize,
            ),
          ),
        ),
        SizedBox(width: spacing),
        InkWell(
          onTap: currentTrack != null
              ? () => _handlePlayPersonalFm(currentTrack, isPlaying)
              : null,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: playButtonSize,
            height: playButtonSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                colors: [Color(0xFF0d8fff), Color(0xFF2fb4ff)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0276c6).withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: _isLoading
                ? const CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  )
                : Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: playIconSize,
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _handlePlayPersonalFm(
    KugouSongDetail track,
    bool isPlaying,
  ) async {
    if (_isLoading) return;

    if (isPlaying) {
      await _togglePlay();
    } else {
      await _playSong(track);
    }
  }

  Widget _buildCurrentVinyl(
    ColorScheme cs,
    KugouSongDetail? track,
    bool isPlaying,
    double size,
  ) {
    if (track == null) return const SizedBox();

    final borderWidth = size * 0.05;
    return InkWell(
      onTap: () => _handlePlayPersonalFm(track, isPlaying),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF482E35),
            width: borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32),
              blurRadius: size * 0.12,
              offset: Offset(0, size * 0.09),
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: _vinylRotationController,
          builder: (context, child) {
            return Transform.rotate(
              angle: _vinylRotationController.value * 2 * 3.14159,
              child: ClipOval(child: _buildVinylCover(track, cs)),
            );
          },
        ),
      ),
    );
  }

  Widget _buildVinylCover(KugouSongDetail track, ColorScheme cs) {
    return Image.network(
      track.artworkUri ?? '',
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _buildVinyls(
    ColorScheme cs,
    List<KugouSongDetail> tracks,
    double vinylSize,
    double leftPadding,
    double spacing,
  ) {
    return AnimatedBuilder(
      animation: _slideController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(
            -(_slideController.value * vinylSize * 1.4) + leftPadding,
            0,
          ),
          child: SizedBox(
            height: vinylSize,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: tracks.asMap().entries.map((entry) {
                final track = entry.value;
                final index = entry.key;
                return _buildSideVinyl(cs, track, index, vinylSize, spacing);
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSideVinyl(
    ColorScheme cs,
    KugouSongDetail track,
    int index,
    double size,
    double spacing,
  ) {
    final borderWidth = size * 0.05;
    return Padding(
      padding: index == 0 ? EdgeInsets.zero : EdgeInsets.only(left: spacing),
      child: InkWell(
        onTap: () => _playSong(track),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF482E35),
              width: borderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: size * 0.13,
                offset: Offset(0, size * 0.1),
              ),
            ],
          ),
          child: ClipOval(child: _buildVinylCover(track, cs)),
        ),
      ),
    );
  }

  Widget _buildNowPanel(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail? track,
    bool isPlaying,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isSmallScreen = constraints.maxWidth < 375;

        return Container(
          padding: EdgeInsets.all(isSmallScreen ? 14 : 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: cs.onSurfaceVariant.withValues(alpha: 0.07),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.onSurfaceVariant.withValues(alpha: 0.022),
                Colors.transparent,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 14,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '当前播放',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: isSmallScreen ? 13 : null,
                    ),
                  ),
                  if (track != null)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8 : 10,
                        vertical: isSmallScreen ? 3 : 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.white,
                      ),
                      child: Text(
                        '${_getModeLabel(_selectedMode)} 实时推荐',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1677ff),
                          fontSize: isSmallScreen ? 11 : 12,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: isSmallScreen ? 12 : 16),
              track != null
                  ? _buildNowCard(cs, textTheme, track, isSmallScreen)
                  : _buildNowEmpty(cs),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNowCard(
    ColorScheme cs,
    TextTheme textTheme,
    KugouSongDetail track,
    bool isSmallScreen,
  ) {
    final coverSize = isSmallScreen ? 100.0 : 120.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            track.artworkUri ?? '',
            width: coverSize,
            height: coverSize,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: coverSize,
              height: coverSize,
              color: cs.surfaceContainerHighest,
              child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
            ),
          ),
        ),
        SizedBox(width: isSmallScreen ? 14 : 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track.songName,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.03,
                  fontSize: isSmallScreen ? 15 : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: isSmallScreen ? 3 : 4),
              Text(
                track.artistName ?? '',
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.74),
                  fontSize: isSmallScreen ? 12 : 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (track.albumName != null && track.albumName!.isNotEmpty)
                Text(
                  track.albumName!,
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.56),
                    fontSize: isSmallScreen ? 10 : 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              SizedBox(height: isSmallScreen ? 4 : 6),
              Text(
                '${_getModeLabel(_selectedMode)} 实时推荐',
                style: textTheme.bodySmall?.copyWith(
                  color: cs.primary,
                  fontSize: isSmallScreen ? 10 : 11,
                ),
              ),
              SizedBox(height: isSmallScreen ? 4 : 6),
              _buildInfoChips(cs, track, isSmallScreen),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChips(
    ColorScheme cs,
    KugouSongDetail track,
    bool isSmallScreen,
  ) {
    final chips = <String>[];
    chips.add(_formatDuration(track.duration));
    chips.add('Hi-Res');
    if (track.songName.contains('国')) {
      chips.add('国语');
    }
    chips.add('相似度高');

    return Wrap(
      spacing: isSmallScreen ? 6 : 8,
      runSpacing: isSmallScreen ? 3 : 4,
      children: chips.map((chip) {
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 8 : 10,
            vertical: isSmallScreen ? 3 : 4,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: cs.onSurfaceVariant.withValues(alpha: 0.06),
            ),
            color: cs.onSurfaceVariant.withValues(alpha: 0.022),
          ),
          child: Text(
            chip,
            style: TextStyle(
              fontSize: isSmallScreen ? 10 : 11,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant.withValues(alpha: 0.68),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildNowEmpty(ColorScheme cs) {
    return Container(
      height: 130,
      alignment: Alignment.center,
      child: Text(
        _isLoading ? '正在获取推荐内容...' : '暂时没有可展示的推荐内容。',
        style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.58)),
      ),
    );
  }
}
