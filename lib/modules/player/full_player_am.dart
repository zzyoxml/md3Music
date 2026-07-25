import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../data/models/song.dart';
import '../../providers/device_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/downloads_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/flowing_background.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/player_playlist_dialog.dart';
import 'comments_view.dart';
import 'full_player_route.dart';

/// 预加载封面图片到磁盘缓存，防止切换时白屏
void _preloadArtwork(String? url) {
  if (url == null || url.isEmpty) return;
  CachedNetworkImageProvider(url).resolve(const ImageConfiguration());
}

const List<AudioQuality> _audioQualities = [
  AudioQuality.standard,
  AudioQuality.high,
  AudioQuality.flac,
];

class AmStyleFullPlayer extends StatefulWidget {
  const AmStyleFullPlayer({super.key});

  @override
  State<AmStyleFullPlayer> createState() => _AmStyleFullPlayerState();
}

class _AmStyleFullPlayerState extends State<AmStyleFullPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  // Apple Music 风格歌词：已解析的 LyricLine 列表，由 LyricParserChain.parse 产出
  List<LyricLine> _parsedLyrics = const [];
  bool _isLoadingLyrics = false;
  String? _lastSongId;
  // 当前歌词格式（KRC / LRC / plaintext），用于底部标注；null 表示尚未检测
  LyricFormat? _lyricFormat;

  // 封面 + 背景淡入淡出动画
  late final AnimationController _artworkFadeController;
  late final Animation<double> _artworkFadeAnimation;
  String? _previousArtworkUrl;

  // Pad 模式：左侧已有封面，隐藏"封面"Tab，只保留 2 个 Tab
  bool _isPadMode = false;
  int _currentTabLength = 3;
  // 手机横屏模式：保留封面Tab，但隐藏左侧歌曲信息
  bool _isPhoneLandscape = false;
  // 拖动进度条前的播放状态，用于拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  // === 拖拽收起手势：通过驱动路由 AnimationController 实现 ===
  double _dragStartY = 0;
  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _artworkFadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _artworkFadeAnimation = CurvedAnimation(
      parent: _artworkFadeController,
      curve: Curves.easeInOut,
    );
    _artworkFadeController.value = 1.0;
    // 进入播放器时根据当前方向应用沉浸模式
    applyImmersiveForOrientation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPadMode();
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        _fetchLyrics(song);
      }
      context.read<PlayerProvider>().addListener(_onPlayerSongChanged);
    });
  }

  /// 检测是否为 Pad 模式（宽度 >= 600），并动态调整 TabController
  void _checkPadMode() {
    if (!mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    final deviceIsPad = context.read<DeviceProvider>().isPad;
    final shouldBePadMode = deviceIsPad || width >= 600;
    // 手机横屏：宽度 >= 600 但设备不是 Pad
    final shouldBePhoneLandscape = !deviceIsPad && width >= 600;
    final newTabLength = shouldBePadMode ? 2 : 3;

    if (_currentTabLength != newTabLength) {
      // 保存当前 tab 索引
      final currentIndex = _tabController.index.clamp(0, newTabLength - 1);
      _tabController.dispose();
      _currentTabLength = newTabLength;
      _tabController = TabController(
        length: newTabLength,
        vsync: this,
        initialIndex: shouldBePadMode && currentIndex == 0 ? 0 : currentIndex,
      );
      _isPadMode = shouldBePadMode;
      _isPhoneLandscape = shouldBePhoneLandscape;
      setState(() {});
    } else {
      _isPadMode = shouldBePadMode;
      _isPhoneLandscape = shouldBePhoneLandscape;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkPadMode();
  }

  void _onPlayerSongChanged() {
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song != null && song.id != _lastSongId) {
      // 封面 + 背景淡入淡出
      if (_previousArtworkUrl != null && _previousArtworkUrl != song.artworkUri) {
        final newUrl = song.artworkUri;
        _artworkFadeController
          ..reset()
          ..forward().then((_) {
            if (mounted) _previousArtworkUrl = newUrl;
          });
      } else {
        _previousArtworkUrl = song.artworkUri;
      }
      _fetchLyrics(song);
      // 预加载上一首和下一首的封面，防止切换时白屏
      final playlist = player.playlist;
      final idx = player.currentIndex;
      if (idx > 0) _preloadArtwork(playlist[idx - 1].artworkUri);
      if (idx < playlist.length - 1) _preloadArtwork(playlist[idx + 1].artworkUri);
    }
  }

  @override
  void didChangeMetrics() {
    // 延迟一帧再检测方向，确保 physicalSize 已更新为新方向
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) applyImmersiveForOrientation();
    });
  }

  @override
  void didUpdateWidget(covariant AmStyleFullPlayer oldWidget) {
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
    _artworkFadeController.dispose();
    _tabController.dispose();
    // 退出播放器时立即恢复系统栏，确保从横屏沉浸模式正确退出
    restoreSystemUi();
    super.dispose();
  }

  Future<void> _fetchLyrics(dynamic song) async {
    final songId = song.id as String;
    if (songId == _lastSongId) return;
    _lastSongId = songId;

    setState(() {
      _isLoadingLyrics = true;
      _parsedLyrics = const [];
      _lyricFormat = null;
    });

    try {
      final kugouProvider = context.read<KugouProvider>();
      await kugouProvider.getLyric(songId, songName: song.title);

      if (mounted) {
        // 优先取 KRC 明文（逐字），降级 LRC 明文（行级），最后降级 displayLyric
        final lyric = kugouProvider.lyric;
        final lyricText =
            lyric?.displayKrcLyric ??
            lyric?.displayLrcLyric ??
            lyric?.displayLyric ??
            '';
        setState(() {
          _isLoadingLyrics = false;
          // 解析器链自动检测格式（KRC/LRC/纯文本）并输出统一 List<LyricLine>
          _parsedLyrics = LyricParserChain.parse(lyricText);
          // 同步记录格式，用于底部标注
          _lyricFormat = LyricParserChain.detectFormat(lyricText);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _parsedLyrics = const [];
          _lyricFormat = null;
        });
      }
    }
  }

  /// 封面淡入淡出（AM 风格：白色占位）
  Widget _buildCrossfadeArtwork(
    String? artworkUrl,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
  }) {
    return AnimatedBuilder(
      animation: _artworkFadeAnimation,
      builder: (context, _) {
        final oldOpacity = 1.0 - _artworkFadeAnimation.value;
        final newOpacity = _artworkFadeAnimation.value;
        return Stack(
          children: [
            if (_previousArtworkUrl != null && _previousArtworkUrl!.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: oldOpacity,
                  child: CachedNetworkImage(
                    imageUrl: _previousArtworkUrl!,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _artworkPlaceholder(iconSize),
                    errorWidget: (_, _, _) => _artworkPlaceholder(iconSize),
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: artworkUrl != null && artworkUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: artworkUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => _artworkPlaceholder(iconSize),
                        errorWidget: (_, _, _) => _artworkPlaceholder(iconSize),
                      )
                    : _artworkPlaceholder(iconSize),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _artworkPlaceholder(double iconSize) {
    return Container(
      color: Colors.white12,
      child: Center(
        child: Icon(Icons.music_note, size: iconSize, color: Colors.white54),
      ),
    );
  }

  /// 模糊背景淡入淡出
  Widget _buildCrossfadeBlurredBackground(String? artworkUrl) {
    return AnimatedBuilder(
      animation: _artworkFadeAnimation,
      builder: (context, _) {
        final oldOpacity = 1.0 - _artworkFadeAnimation.value;
        final newOpacity = _artworkFadeAnimation.value;
        return Stack(
          children: [
            if (_previousArtworkUrl != null && _previousArtworkUrl!.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: oldOpacity,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                    child: Image.network(
                      _previousArtworkUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: artworkUrl != null && artworkUrl.isNotEmpty
                    ? ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                        child: Image.network(
                          artworkUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
                        ),
                      )
                    : const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        );
      },
    );
  }

  // === 拖拽收起手势：直接驱动路由 AnimationController ===

  /// 获取当前路由的 AnimationController（来自 DraggablePlayerRoute）。
  /// 若当前路由不是 DraggablePlayerRoute（例如从其他入口 push），返回 null。
  AnimationController? get _routeController {
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      return route.controller;
    }
    return null;
  }

  /// 把手拖拽开始：记录起点 y。
  void _onHandleDragStart(DragStartDetails details) {
    _dragStartY = details.globalPosition.dy;
  }

  /// 把手拖拽更新：下拉距离 → controller 反向进度。
  void _onHandleDragUpdate(DragUpdateDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final dy = details.globalPosition.dy - _dragStartY;
    if (dy <= 0) return; // 上拉不触发收起
    final progress = 1.0 - (dy / kPlayerDragThreshold).clamp(0.0, 1.0);
    controller.stop();
    controller.value = progress;
  }

  /// 把手拖拽结束：按进度/速度决定完成收起或回退展开。
  void _onHandleDragEnd(DragEndDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final currentProgress = controller.value;
    final velocity = details.primaryVelocity ?? 0;

    if (currentProgress < 0.5 || velocity > 300) {
      // 收起：用 dismiss() 走统一的 reverse + pop 流程
      _isDismissing = true;
      final route = ModalRoute.of(context);
      if (route is DraggablePlayerRoute) {
        route.dismiss();
      }
    } else {
      // 回退展开：forward 到 1.0
      controller.forward();
    }
  }

  /// 点击下拉按钮直接收起（保留原 _buildTopBar 的 IconButton 行为）。
  void _collapseByButton() {
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
    } else {
      Navigator.of(context).maybePop();
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

    // 初始化封面 URL（首次进入或 null→有值）
    if (_previousArtworkUrl == null && currentSong.artworkUri != null) {
      _previousArtworkUrl = currentSong.artworkUri;
    }

    // 拦截系统返回键：先播放 reverse 动画（mini player 淡入），
    // 动画完成后用 removeRoute 移除路由（绕过 PopScope 避免死循环）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isDismissing) return;
        _collapseByButton();
      },
      child: _buildFullLayout(playerProvider, currentSong, colorScheme),
    );
  }

  /// 全屏 Apple Music 风格布局：模糊封面背景 + 蒙版 + 三套响应式布局。
  /// 对应 spec.md "Requirement: 模糊封面背景"。
  Widget _buildFullLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    // extendBody: true 让内容延伸到系统导航栏后面，实现沉浸效果
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBody: true,
        body: Stack(
          children: [
            // 1. 模糊封面背景层（Apple Music 风格，带淡入淡出）
            _buildCrossfadeBlurredBackground(currentSong.artworkUri),
            // 2. 动态流光背景层（可选，从专辑封面提取色彩流动）
            if (LyricPreferences.instance.useFlowingBackground)
              FlowingBackground(
                artworkUrl: currentSong.artworkUri,
                isPlaying: playerProvider.isPlaying,
              ),
            // 3. 半透明蒙版 rgba(0,0,0,0.35)
            _buildDarkOverlay(),
            // 4. 主体内容（保留原有 compact/landscape/expanded 三套布局）
            ResponsiveLayout(
              compact: (_) =>
                  _buildCompactLayout(playerProvider, currentSong, colorScheme),
              medium: (_) =>
                  _buildLandscapeLayout(playerProvider, currentSong, colorScheme),
              expanded: (_) =>
                  _buildExpandedLayout(playerProvider, currentSong, colorScheme),
            ),
          ],
        ),
      ),
    );
  }

  /// 半透明蒙版层，叠加在模糊封面背景之上。
  ///
  /// 颜色 rgba(0,0,0,0.35) 对应 `Color(0x59000000)`
  /// （0x59 = 89 ≈ 0.35 * 255）。
  Widget _buildDarkOverlay() {
    return const Positioned.fill(child: ColoredBox(color: Color(0x59000000)));
  }

  Widget _buildCompactLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    // 竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    // 使用 viewPadding.bottom 和固定最小值 32 确保控件不被遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 32;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                GestureDetector(
                  onTap: () => _tabController.animateTo(1),
                  behavior: HitTestBehavior.opaque,
                  child: _buildArtworkView(
                    playerProvider,
                    currentSong,
                    colorScheme,
                    isExpanded: true,
                  ),
                ),
                GestureDetector(
                  onTap: () => _tabController.animateTo(0),
                  behavior: HitTestBehavior.translucent,
                  child: _isLoadingLyrics
                      ? const Center(child: CircularProgressIndicator())
                      : AppleLyricsView(
                          lines: _parsedLyrics,
                          currentTimeMs: playerProvider.position.inMilliseconds,
                          isPlaying: playerProvider.isPlaying,
                          onSeek: (ms) =>
                              playerProvider.seek(Duration(milliseconds: ms)),
                        ),
                ),
                CommentsView(
                  songHash: currentSong.id,
                  albumAudioId: currentSong.albumAudioId,
                  artworkUri: currentSong.artworkUri,
                  isAmStyle: true,
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: bottomPadding),
            child: _buildControls(playerProvider, colorScheme),
          ),
        ],
      ),
    );
  }

  /// 手机横屏 / 小尺寸宽屏布局：左侧封面，右侧信息+歌词/评论+控制栏
  Widget _buildLandscapeLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    return SafeArea(
      bottom: false,
      child: Row(
        children: [
          // ── 左侧：封面 + 歌曲信息 ──
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 横屏时封面最大不超过可用宽度，保持正方形
                  final size = constraints.maxWidth.clamp(120.0, 300.0);
                  return Stack(
                    children: [
                      // 封面居中
                      Center(
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: AnimatedScale(
                            scale: playerProvider.isPlaying ? 1.0 : 0.85,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOutBack,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: _buildCrossfadeArtwork(
                                currentSong.artworkUri,
                                colorScheme,
                                iconSize: 48,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 歌曲信息：垂直方向 80% 位置，水平居中（手机横屏时隐藏）
                      if (!_isPhoneLandscape)
                        Positioned(
                        top: constraints.maxHeight * 0.8,
                        left: 0,
                        right: 0,
                        child: Column(
                          children: [
                            Text(
                              currentSong.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              currentSong.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                            Text(
                              currentSong.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.white54),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // ── 右侧：TopBar + Tab + 内容 + 控制 ──
          Expanded(
            flex: 6,
            child: Column(
              children: [
                _buildTopBar(),

                // 内容区（歌词 / 评论 / 封面信息）
                // Pad模式下无封面Tab；手机横屏保留封面Tab
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      if (!_isPadMode || _isPhoneLandscape)
                        GestureDetector(
                          onTap: () => _tabController.animateTo(1),
                          behavior: HitTestBehavior.opaque,
                          child: _buildSongInfo(
                            playerProvider,
                            currentSong,
                            colorScheme,
                          ),
                        ),
                      _isLoadingLyrics
                          ? const Center(child: CircularProgressIndicator())
                          : AppleLyricsView(
                              lines: _parsedLyrics,
                              currentTimeMs:
                                  playerProvider.position.inMilliseconds,
                              isPlaying: playerProvider.isPlaying,
                              onSeek: (ms) => playerProvider.seek(
                                Duration(milliseconds: ms),
                              ),
                            ),
                      CommentsView(
                        songHash: currentSong.id,
                        albumAudioId: currentSong.albumAudioId,
                        artworkUri: currentSong.artworkUri,
                        isAmStyle: true,
                      ),
                    ],
                  ),
                ),

                // 控制区：底部 padding 包含导航栏高度
                Padding(
                  padding: EdgeInsets.only(bottom: bottomPadding),
                  child: _buildControls(
                    playerProvider,
                    colorScheme,
                    isExpanded: true,
                  ),
                ),
              ],
            ),
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
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    return SafeArea(
      bottom: false,
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxSize = (constraints.maxWidth - 32).clamp(0.0, 380.0);
                  return Stack(
                    children: [
                      // 封面居中
                      Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: maxSize,
                            maxHeight: maxSize,
                          ),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: AnimatedScale(
                              scale: playerProvider.isPlaying ? 1.0 : 0.85,
                              duration: const Duration(milliseconds: 500),
                              curve: Curves.easeOutBack,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: _buildCrossfadeArtwork(
                                  currentSong.artworkUri,
                                  colorScheme,
                                  iconSize: 48,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 歌曲信息：垂直方向 80% 位置，水平居中（手机横屏时隐藏）
                      if (!_isPhoneLandscape)
                        Positioned(
                        top: constraints.maxHeight * 0.8,
                        left: 0,
                        right: 0,
                        child: Column(
                          children: [
                            Text(
                              currentSong.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              currentSong.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                            Text(
                              currentSong.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.white54),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
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
                      if (!_isPadMode || _isPhoneLandscape)
                        _buildSongInfo(playerProvider, currentSong, colorScheme),
                      _isLoadingLyrics
                          ? const Center(child: CircularProgressIndicator())
                          : AppleLyricsView(
                              lines: _parsedLyrics,
                              currentTimeMs:
                                  playerProvider.position.inMilliseconds,
                              isPlaying: playerProvider.isPlaying,
                              onSeek: (ms) => playerProvider.seek(
                                Duration(milliseconds: ms),
                              ),
                            ),
                      CommentsView(
                        songHash: currentSong.id,
                        albumAudioId: currentSong.albumAudioId,
                        artworkUri: currentSong.artworkUri,
                        isAmStyle: true,
                      ),
                    ],
                  ),
                ),
                // 控制区：底部 padding 包含导航栏高度
                Padding(
                  padding: EdgeInsets.only(bottom: bottomPadding),
                  child: _buildControls(playerProvider, colorScheme, isExpanded: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    // Apple Music 风格顶部栏：下拉手柄 + 导航行
    // Pad 模式下只显示 2 个 Tab（歌词、评论），手机横屏保留全部 3 个 Tab
    final tabs = _isPadMode && !_isPhoneLandscape
        ? const [Tab(text: '歌词'), Tab(text: '评论')]
        : const [Tab(text: '封面'), Tab(text: '歌词'), Tab(text: '评论')];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部居中下拉手柄：拖拽时驱动路由 controller 反向，淡入淡出与拖拽距离线性绑定
        GestureDetector(
          onVerticalDragStart: _onHandleDragStart,
          onVerticalDragUpdate: _onHandleDragUpdate,
          onVerticalDragEnd: _onHandleDragEnd,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white54,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                ),
                // 点击下拉按钮 → reverse + pop 流程
                onPressed: _collapseByButton,
              ),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: tabs,
                  labelStyle: Theme.of(context).textTheme.labelMedium,
                  // 模糊深色背景下用白色文字与指示器
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  indicatorSize: TabBarIndicatorSize.label,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onPressed: () => _showMoreMenu(context),
              ),
            ],
          ),
        ),
      ],
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
          if (isExpanded) ...[
            const Spacer(),
            LayoutBuilder(
              builder: (context, constraints) {
                final maxSize = (constraints.maxWidth - 32).clamp(0.0, 380.0);
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxSize,
                    maxHeight: maxSize,
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    // 专辑封面缩放动画（grill-me 第三轮）：
                    // 暂停时 scale=0.85，播放时 scale=1.0，带超出回弹效果。
                    // 用 AnimatedScale + easeOutBack 曲线，overshoot 约 1.7，
                    // 暂停→播放：1.0 ← 0.85（中间略超 1.05），营造"放大回弹"感
                    // 播放→暂停：0.85 ← 1.0（中间略低 0.8），营造"缩小回弹"感
                    child: AnimatedScale(
                      scale: playerProvider.isPlaying ? 1.0 : 0.85,
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _buildCrossfadeArtwork(
                          currentSong.artworkUri,
                          colorScheme,
                          iconSize: iconSize,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const Spacer(),
          ] else
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _buildCrossfadeArtwork(
                    currentSong.artworkUri,
                    colorScheme,
                    iconSize: iconSize,
                  ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          Text(
            currentSong.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                (isExpanded
                        ? Theme.of(context).textTheme.titleMedium
                        : Theme.of(context).textTheme.titleLarge)
                    ?.copyWith(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            currentSong.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
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
              currentSong.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              currentSong.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
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
    // Apple Music 风格：深色背景下进度条与时间标签用白色
    final song = playerProvider.currentSong;
    final hasClimax = song?.climaxStart != null &&
        song?.climaxEnd != null &&
        duration.inMilliseconds > 0;

    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(position),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: hasClimax
              ? _buildSliderWithClimaxMarker(
                  playerProvider, position, duration, song!)
              : Slider(
                  value: duration.inMilliseconds > 0
                      ? (position.inMilliseconds / duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : 0.0,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  onChangeStart: (_) {
                    _wasPlayingBeforeDrag = playerProvider.isPlaying;
                    if (playerProvider.isPlaying) {
                      playerProvider.pause();
                    }
                  },
                  onChanged: (value) {
                    final newPosition = Duration(
                      milliseconds:
                          (duration.inMilliseconds * value).round(),
                    );
                    playerProvider.seek(newPosition);
                  },
                  onChangeEnd: (_) {
                    if (_wasPlayingBeforeDrag) {
                      playerProvider.resume();
                    }
                  },
                ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(duration),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  /// AM 风格：构建带有高潮点标记的进度条。
  Widget _buildSliderWithClimaxMarker(
    PlayerProvider playerProvider,
    Duration position,
    Duration duration,
    Song song,
  ) {
    final climaxStart = song.climaxStart!;
    final climaxEnd = song.climaxEnd!;
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return const SizedBox.shrink();

    final climaxStartPos = (climaxStart * 1000 / totalMs).clamp(0.0, 1.0);
    final climaxEndPos = (climaxEnd * 1000 / totalMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final thumbRadius = 10.0;
        final usableWidth = trackWidth - thumbRadius * 2;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Slider(
              value: totalMs > 0
                  ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
                  : 0.0,
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
              onChangeStart: (_) {
                _wasPlayingBeforeDrag = playerProvider.isPlaying;
                if (playerProvider.isPlaying) {
                  playerProvider.pause();
                }
              },
              onChanged: (value) {
                final newPosition = Duration(
                  milliseconds: (totalMs * value).round(),
                );
                playerProvider.seek(newPosition);
              },
              onChangeEnd: (_) {
                if (_wasPlayingBeforeDrag) {
                  playerProvider.resume();
                }
              },
            ),
            // 高潮区域高亮条：与进度条轨道同高、垂直居中对齐
            Positioned(
              left: thumbRadius + usableWidth * climaxStartPos,
              top: 0,
              bottom: 0,
              width: usableWidth * (climaxEndPos - climaxStartPos),
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMainControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    // Apple Music HIG 风格：大按钮居中，白色图标，圆形白色播放按钮
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
            // 深色背景下：启用时纯白，未启用时半透明白
            color: playerProvider.shuffleEnabled
                ? Colors.white
                : Colors.white70,
          ),
          onPressed: () => playerProvider.toggleShuffle(),
        ),
        SizedBox(width: spacing),
        IconButton(
          iconSize: skipIconSize,
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onPressed: () => playerProvider.previous(),
        ),
        SizedBox(width: spacing),
        // Apple Music 标志性白色圆形播放按钮，黑色图标
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
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
          ),
        ),
        SizedBox(width: spacing),
        IconButton(
          iconSize: skipIconSize,
          icon: const Icon(Icons.skip_next, color: Colors.white),
          onPressed: () => playerProvider.next(),
        ),
        SizedBox(width: spacing),
        IconButton(
          icon: Icon(
            _getLoopModeIcon(playerProvider.loopMode),
            color: playerProvider.loopMode != AppLoopMode.off
                ? Colors.white
                : Colors.white70,
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
    // Apple Music 风格：深色背景下副控制栏用白色图标与文字
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(
                isFavorited ? Icons.favorite : Icons.favorite_border,
                color: isFavorited ? Colors.redAccent : Colors.white,
              ),
              onPressed: song != null
                  ? () => context.read<FavoritesProvider>().toggleFavorite(song)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.download, color: Colors.white),
              onPressed: song != null ? () => _downloadSong(song) : null,
            ),
            IconButton(
              icon: const Icon(Icons.volume_up, color: Colors.white),
              onPressed: () => _showVolumeDialog(playerProvider),
            ),
          ],
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => _showSpeedDialog(playerProvider),
                child: Text(
                  '${playerProvider.speed}x',
                  style: TextStyle(
                    fontSize: isExpanded ? 12 : 14,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _showQualityDialog(playerProvider),
                child: Text(
                  playerProvider.audioQualityLabel,
                  style: TextStyle(
                    fontSize: isExpanded ? 12 : 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.playlist_play, color: Colors.white),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
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
                      Icon(
                        icon,
                        size: 32,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        value: volume,
                        onChanged: (value) {
                          playerProvider.setVolume(value);
                          setState(() {});
                        },
                      ),
                      Text(
                        '$percent%',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
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
        return StatefulBuilder(
          builder: (context, setState) {
            // 找到当前速度对应的索引
            int currentIndex = speeds.indexOf(playerProvider.speed);
            if (currentIndex == -1) currentIndex = 3; // 默认 1.0x

            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题 + 当前倍速
                      Text(
                        '播放速度',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${speeds[currentIndex]}x',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 横条滑块
                      Slider(
                        value: currentIndex.toDouble(),
                        min: 0,
                        max: (speeds.length - 1).toDouble(),
                        divisions: speeds.length - 1,
                        label: '${speeds[currentIndex]}x',
                        onChanged: (value) {
                          setState(() {
                            currentIndex = value.round();
                          });
                          playerProvider.setSpeed(speeds[currentIndex]);
                        },
                      ),
                      // 节点标签
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: speeds.map((s) {
                          final isSelected = s == speeds[currentIndex];
                          return Text(
                            s == 1.0 ? '1x' : '${s}x',
                            style: TextStyle(
                              fontSize: 10,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                      // 关闭按钮
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showQualityDialog(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Center(child: Text('音质选择')),
          children: _audioQualities.map((quality) {
            return SimpleDialogOption(
              onPressed: () {
                playerProvider.setAudioQuality(quality);
                Navigator.pop(context);
              },
              child: Text(
                quality.label,
                textAlign: TextAlign.center,
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
        // 不循环：空心箭头
        return Icons.repeat_outlined;
      case AppLoopMode.one:
        // 单曲循环：带数字1
        return Icons.repeat_one;
      case AppLoopMode.all:
        // 列表循环：实心箭头，播完回到第一首
        return Icons.repeat;
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _downloadSong(dynamic song) {
    final downloadsProvider = context.read<DownloadsProvider>();
    final isDownloaded = downloadsProvider.isDownloaded(song.id);
    final isDownloading = downloadsProvider.isDownloading(song.id);

    if (isDownloaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已下载: ${song.title}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('正在下载: ${song.title}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // 弹出音质选择对话框
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载: ${song.displayName ?? song.title}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(song.artist ?? '', style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text('选择音质', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 8),
            _buildDownloadQualityOption(ctx, '标准音质 (128kbps)', '128', song, downloadsProvider),
            _buildDownloadQualityOption(ctx, '高音质 (320kbps)', '320', song, downloadsProvider),
            _buildDownloadQualityOption(ctx, '无损音质 (FLAC)', 'flac', song, downloadsProvider),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadQualityOption(
    BuildContext context,
    String label,
    String quality,
    dynamic song,
    DownloadsProvider provider,
  ) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.music_note, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: () {
        Navigator.pop(context);
        final displayName = song.displayName ?? song.title;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('开始下载: $displayName'),
            duration: const Duration(seconds: 2),
          ),
        );
        provider.downloadSong(song, quality: quality);
      },
    );
  }

  void _showMoreMenu(BuildContext context) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        // 歌词类型标签：KRC / LRC / 静态 / 未加载
        final lyricTypeLabel = switch (_lyricFormat) {
          LyricFormat.krc => 'KRC 逐字歌词',
          LyricFormat.lrc => 'LRC 行级歌词',
          LyricFormat.plaintext => '静态歌词',
          null => _isLoadingLyrics ? '歌词加载中' : '未加载',
        };
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 歌词类型展示（只读，trailing 显示类型，点击无操作）
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('歌词类型'),
                trailing: Text(
                  lyricTypeLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.lyrics),
                title: const Text('歌词显示设置'),
                onTap: () {
                  Navigator.pop(context);
                  _showLyricPreferencesSheet(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('添加到歌单'),
                onTap: () {
                  Navigator.pop(context);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('分享'),
                onTap: () {
                  Navigator.pop(context);
                  // TODO: 实现分享功能
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('分享功能开发中')));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 弹出歌词字号/行间距调节面板（从播放页右上角菜单进入）。
  void _showLyricPreferencesSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(child: const LyricPreferencesPanel()),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, dynamic song) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先登录'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return FutureBuilder<Map<String, dynamic>?>(
          future: api.getUserPlaylist(pagesize: 50),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AlertDialog(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('加载歌单中...'),
                  ],
                ),
              );
            }

            if (snapshot.hasError || snapshot.data == null) {
              return AlertDialog(
                title: const Text('错误'),
                content: const Text('获取歌单失败'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }

            final data = snapshot.data!['data'];
            List<dynamic> rawPlaylists = [];
            if (data is List) {
              rawPlaylists = data;
            } else if (data is Map) {
              rawPlaylists =
                  data['info'] ?? data['list'] ?? data['special_list'] ?? [];
            }

            // 使用 KugouPlaylistBrief 模型解析，确保字段名映射正确
            // 只显示用户自己创建的歌单 (type=0)
            final playlists = <Map<String, dynamic>>[];
            for (final item in rawPlaylists) {
              final json = item as Map<String, dynamic>;
              final brief = KugouPlaylistBrief.fromJson(json);
              if (brief.type != 0) continue;
              // 将模型数据转回 Map 以便 UI 使用（包含正确的字段值）
              playlists.add({
                'name': brief.name,
                'songCount': brief.songCount,
                'listid': brief.listId.isEmpty ? brief.id : brief.listId,
                'specialid': brief.id,
                'global_collection_id': brief.globalCollectionId,
                'type': brief.type,
                // 保留原始 JSON 用于 API 调用
                ...json,
              });
            }

            if (playlists.isEmpty) {
              return AlertDialog(
                title: const Text('我的歌单'),
                content: const Text('暂无歌单，请先创建歌单'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }

            return AlertDialog(
              title: const Text('添加到歌单'),
              content: SizedBox(
                width: 300,
                height: 400,
                child: ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final name =
                        (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
                            .toString();
                    // 优先使用模型解析后的 songCount，再尝试原始字段
                    final songCount =
                        playlist['songCount'] ??
                        playlist['songcount'] ??
                        playlist['song_count'] ??
                        playlist['count'] ??
                        0;

                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(name),
                      subtitle: Text('$songCount 首'),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _addSongToPlaylist(context, song, playlist);
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _addSongToPlaylist(
    BuildContext context,
    dynamic song,
    Map<String, dynamic> playlist,
  ) async {
    final api = KugouApiClient();
    final listid =
        playlist['listid']?.toString() ?? playlist['list_id']?.toString() ?? '';

    if (listid.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('歌单ID无效'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 乐观更新：立即显示成功，后台同步到酷狗服务器
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已添加到「${playlist['name']}」'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    // 构造歌曲数据 — 酷狗API要求的格式：歌名|hash|albumId|albumAudioId
    final songData =
        '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';

    // 后台同步，不阻塞 UI
    api
        .addPlaylistTracks(listid, songData)
        .then((result) {
          // 同步失败时提示用户（静默失败，不影响已显示的乐观更新）
          if (result == null) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('同步到服务器失败，将在下次启动时重试'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          }
        })
        .catchError((_) {
          // 网络错误等，同样静默处理
        });
  }

  void _showPlaylist(PlayerProvider playerProvider) {
    // AM 风格播放页：直接复用 PlayerPlaylistDialog（与 MD3 风格统一）
    // - 圆角 / 背景色 / 拖拽排序 / 左滑删除全部一致
    // - useDisplayName: true 让标题列显示 displayName（AM 风格习惯）
    // - playerProvider 参数保留以匹配调用点签名，内部由 Provider.of 获取
    showDialog(
      context: context,
      builder: (dialogContext) =>
          const PlayerPlaylistDialog(useDisplayName: true),
    );
  }
}
