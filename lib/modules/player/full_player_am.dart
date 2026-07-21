import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/downloads_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/apple_lyrics/animation/spring.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'comments_view.dart';

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

  // === Task 19: 上滑展开 / 下拉收起手势 ===
  // 当前是否处于展开（全屏）状态。默认 true，进入页面即全屏。
  bool _isExpanded = true;
  // 累计垂直拖动距离（px）。正值=下拉，负值=上拉。释放后归零。
  double _dragDistance = 0;
  // 弹簧驱动的展开进度：1.0=全屏，0.0=迷你条。
  // 使用 Spring 类（Task 6 引擎），参数 mass=1, damping=20, stiffness=100（临界阻尼）。
  late final Spring _expansionSpring = Spring(
    mass: 1,
    damping: 20,
    stiffness: 100,
    initialPosition: 1.0,
  );
  // 弹簧动画 ticker，仅在动画期间活跃。
  late final Ticker _springTicker;
  // 上次 tick 时间戳，用于计算真实 dt（避免帧率不同导致动画快慢不一致）。
  Duration? _lastTickElapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    // 创建弹簧驱动 ticker（muted 机制自动处理路由不可见时暂停）
    _springTicker = createTicker(_onSpringTick);
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
    _springTicker.dispose();
    _tabController.dispose();
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
        final lyricText = lyric?.displayKrcLyric ??
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

  // === Task 19: 弹簧驱动方法 ===

  /// 启动弹簧动画（如 ticker 未运行则启动）。
  void _startSpringAnimation() {
    if (!_springTicker.isActive) {
      _lastTickElapsed = null;
      _springTicker.start();
    }
  }

  /// Ticker 每帧回调：用真实 dt 推进 Spring，触发重绘，稳定后停止 ticker。
  void _onSpringTick(Duration elapsed) {
    final last = _lastTickElapsed ?? elapsed;
    // 微秒转秒，做 sanity check（dt > 1s 通常表示首帧或卡顿，跳过避免数值发散）
    final dt = (elapsed - last).inMicroseconds / 1e6;
    _lastTickElapsed = elapsed;
    if (dt > 0 && dt < 1.0) {
      _expansionSpring.tick(dt);
    }
    setState(() {});
    if (_expansionSpring.isSettled) {
      _springTicker.stop();
      _lastTickElapsed = null;
    }
  }

  /// 收起为迷你条：直接 Navigator.pop 退出 FullPlayer 路由，让主页常驻的
  /// MiniPlayer 接管显示。
  ///
  /// 之前用弹簧动画 + 内嵌 _buildMiniBar 的方案，会导致 FullPlayer 不出栈，
  /// 主页 MiniPlayer 与 FullPlayer 内嵌迷你条同时显示（双重 mini player bug）。
  /// 改为直接 pop：简单可靠，符合 Apple Music 下拉直接收起的行为。
  void _collapse() {
    if (!_isExpanded) return;
    Navigator.of(context).maybePop();
  }

  /// 展开为全屏页：弹簧目标设为 1.0。
  void _expand() {
    if (_isExpanded) return;
    _isExpanded = true;
    _expansionSpring.setTarget(1.0);
    _startSpringAnimation();
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

    // Spring 驱动的展开进度：1.0=全屏，0.0=迷你条
    final expansion = _expansionSpring.position.clamp(0.0, 1.0);
    final fullOpacity = expansion;
    final miniOpacity = 1.0 - expansion;

    // 用 Stack 叠加全屏布局与迷你条布局，由弹簧进度驱动透明度交叉淡入淡出。
    // IgnorePointer 防止隐藏层拦截手势。
    // 外层用 Scaffold(backgroundColor: Colors.black) 包裹：
    // 1. 提供稳定不透明背景，避免预测返回手势时透出底层路由
    // 2. 与 _buildFullLayout 内部的 Scaffold(backgroundColor: Colors.black) 一致
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. 全屏 Apple Music 风格布局
          Opacity(
            opacity: fullOpacity,
            child: IgnorePointer(
              ignoring: fullOpacity < 0.5,
              child: _buildFullLayout(playerProvider, currentSong, colorScheme),
            ),
          ),
          // 2. 迷你条布局（底部对齐，其余区域透明，让底层路由可见）
          Opacity(
            opacity: miniOpacity,
            child: IgnorePointer(
              ignoring: miniOpacity < 0.5,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _buildMiniBar(playerProvider, currentSong, colorScheme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 全屏 Apple Music 风格布局：模糊封面背景 + 蒙版 + 三套响应式布局。
  /// 对应 spec.md "Requirement: 模糊封面背景"。
  Widget _buildFullLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. 模糊封面背景层（Apple Music 风格）
          _buildBlurredBackground(currentSong),
          // 2. 半透明蒙版 rgba(0,0,0,0.35)
          _buildDarkOverlay(),
          // 3. 主体内容（保留原有 compact/landscape/expanded 三套布局）
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
    );
  }

  /// Apple Music 风格模糊封面背景层。
  ///
  /// 使用 [ImageFilter.blur]（sigmaX/Y=50）对封面做高斯模糊，
  /// 封面放大填充屏幕并居中裁剪。封面不可用时降级纯黑背景。
  /// 对应 spec.md "Requirement: 模糊封面背景"。
  ///
  /// **性能**：包一层 [RepaintBoundary]，让模糊背景作为独立 Layer 缓存，
  /// 避免上层每帧 setState（歌词逐字动画）触发模糊重算（25fps 卡顿主因）。
  /// RepaintBoundary 在子树不变时复用同一 Layer，Image.network 加载完成
  /// 后模糊结果会被缓存，后续每帧只需合成已有 layer。
  Widget _buildBlurredBackground(dynamic currentSong) {
    final artworkUri = currentSong.artworkUri as String?;
    if (artworkUri == null || artworkUri.isEmpty) {
      return const Positioned.fill(child: ColoredBox(color: Colors.black));
    }
    return Positioned.fill(
      child: RepaintBoundary(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: Image.network(
            artworkUri,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
  }

  /// 半透明蒙版层，叠加在模糊封面背景之上。
  ///
  /// 颜色 rgba(0,0,0,0.35) 对应 `Color(0x59000000)`
  /// （0x59 = 89 ≈ 0.35 * 255）。
  Widget _buildDarkOverlay() {
    return const Positioned.fill(
      child: ColoredBox(color: Color(0x59000000)),
    );
  }

  /// 迷你条布局（Task 19）：封面缩略图 + 标题/艺术家 + 播放/暂停 + 下一首 + 顶部进度条。
  /// 高度约 60px，底部对齐。上滑超过阈值或点击 → 展开为全屏页。
  ///
  /// 对应 spec.md "Requirement: 上滑展开 / 下拉收起" 的迷你状态视图。
  Widget _buildMiniBar(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      // 上滑展开 / 点击展开（与下拉收起对称的阈值：±100 px / ±100 px/s）
      onVerticalDragUpdate: (details) {
        _dragDistance += details.delta.dy;
      },
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        // 迷你状态：上拉速度 < -100 或上拉距离 < -100 → 展开
        if (velocity < -100 || _dragDistance < -100) {
          _expand();
        }
        _dragDistance = 0;
      },
      onTap: () => _expand(),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部进度条（与 mini_player.dart 样式一致）
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: colorScheme.primary,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  // 封面缩略图 44x44
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: currentSong.artworkUri != null
                          ? CachedNetworkImage(
                              imageUrl: currentSong.artworkUri!,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20,
                                    color: colorScheme.onSurfaceVariant),
                              ),
                              errorWidget: (_, _, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20,
                                    color: colorScheme.onSurfaceVariant),
                              ),
                            )
                          : Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.music_note,
                                  size: 20,
                                  color: colorScheme.onSurfaceVariant),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 标题 + 艺术家
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSong.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          currentSong.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  // 播放/暂停按钮（迷你条状态下也要能控制播放）
                  IconButton(
                    icon: Icon(playerProvider.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow),
                    onPressed: () {
                      if (playerProvider.isPlaying) {
                        playerProvider.pause();
                      } else {
                        playerProvider.resume();
                      }
                    },
                  ),
                  // 下一首按钮
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => playerProvider.next(),
                  ),
                ],
              ),
            ),
          ],
        ),
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

  /// 手机横屏 / 小尺寸宽屏布局：左侧封面，右侧信息+歌词/评论+控制栏
  Widget _buildLandscapeLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    return SafeArea(
      child: Row(
        children: [
          // ── 左侧：封面 ──
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 横屏时封面最大不超过可用宽度，保持正方形
                  final size = constraints.maxWidth.clamp(120.0, 300.0);
                  return Center(
                    child: SizedBox(
                    width: size,
                    height: size,
                    // 横屏封面缩放动画（与竖屏一致，暂停 0.85 / 播放 1.0 带回弹）
                    child: AnimatedScale(
                      scale: playerProvider.isPlaying ? 1.0 : 0.85,
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: currentSong.artworkUri != null
                            ? CachedNetworkImage(
                                imageUrl: currentSong.artworkUri!,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => Container(
                                  color: Colors.white12,
                                  child: Icon(Icons.music_note,
                                    size: 48, color: Colors.white54),
                                ),
                                errorWidget: (_, _, _) => Container(
                                  color: Colors.white12,
                                  child: Icon(Icons.music_note,
                                    size: 48, color: Colors.white54),
                                ),
                              )
                            : Container(
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(Icons.music_note,
                                    size: 48, color: Colors.white54),
                              ),
                      ),
                    ),
                  ),
                  );
                },
              ),
            ),
          ),
          // ── 右侧：Tab + 内容 + 控制 ──
          Expanded(
            flex: 6,
            child: Column(
              children: [
                // 标签栏（封面/歌词/评论）
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TabBar(
                    controller: _tabController,
                    tabs: const [Tab(text: '封面'), Tab(text: '歌词'), Tab(text: '评论')],
                    labelStyle: Theme.of(context).textTheme.labelMedium,
                    // 模糊深色背景下用白色文字与指示器（不读 MD3 主题色）
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white70,
                    indicatorColor: Colors.white,
                    indicatorSize: TabBarIndicatorSize.label,
                    isScrollable: false,
                    tabAlignment: TabAlignment.center,
                  ),
                ),

                // 内容区（歌曲信息 / 歌词 / 评论）
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      GestureDetector(
                        onTap: () => _tabController.animateTo(1),
                        behavior: HitTestBehavior.opaque,
                        child: _buildSongInfo(playerProvider, currentSong, colorScheme),
                      ),
                      _isLoadingLyrics
                          ? const Center(child: CircularProgressIndicator())
                          : AppleLyricsView(
                              lines: _parsedLyrics,
                              currentTimeMs: playerProvider.position.inMilliseconds,
                              isPlaying: playerProvider.isPlaying,
                              onSeek: (ms) =>
                                  playerProvider.seek(Duration(milliseconds: ms)),
                            ),
                      CommentsView(
                        songHash: currentSong.id,
                        albumAudioId: currentSong.albumAudioId,
                        artworkUri: currentSong.artworkUri,
                      ),
                    ],
                  ),
                ),

                // 控制区
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildControls(playerProvider, colorScheme, isExpanded: true),
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
                          : AppleLyricsView(
                              lines: _parsedLyrics,
                              currentTimeMs: playerProvider.position.inMilliseconds,
                              isPlaying: playerProvider.isPlaying,
                              onSeek: (ms) =>
                                  playerProvider.seek(Duration(milliseconds: ms)),
                            ),
                      CommentsView(
                        songHash: currentSong.id,
                        albumAudioId: currentSong.albumAudioId,
                        artworkUri: currentSong.artworkUri,
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
    // Apple Music 风格顶部栏：下拉手柄（Task 19 绑定垂直拖动手势）+ 导航行
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部居中下拉手柄：下拉速度 > 100 px/s 或累计下拉距离 > 100 px → 收起为迷你条
        GestureDetector(
          onVerticalDragUpdate: (details) {
            _dragDistance += details.delta.dy;
          },
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            // 全屏状态：下拉速度 > 100 或下拉距离 > 100 → 收起
            if (velocity > 100 || _dragDistance > 100) {
              _collapse();
            }
            _dragDistance = 0;
          },
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
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                // 点击下拉按钮 → 收起为迷你条（Task 19）
                onPressed: _collapse,
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
                        child: currentSong.artworkUri != null
                            ? CachedNetworkImage(
                                imageUrl: currentSong.artworkUri!,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => Container(
                                  color: Colors.white12,
                                  child: Icon(
                                    Icons.music_note,
                                    size: iconSize,
                                    color: Colors.white54,
                                  ),
                                ),
                                errorWidget: (_, _, _) => Container(
                                  color: Colors.white12,
                                  child: Icon(
                                    Icons.music_note,
                                    size: iconSize,
                                    color: Colors.white54,
                                  ),
                                ),
                              )
                            : Container(
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  Icons.music_note,
                                  size: iconSize,
                                  color: Colors.white54,
                                ),
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
                  child: currentSong.artworkUri != null
                      ? CachedNetworkImage(
                          imageUrl: currentSong.artworkUri!,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            color: Colors.white12,
                            child: Icon(
                              Icons.music_note,
                              size: iconSize,
                              color: Colors.white54,
                            ),
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: Colors.white12,
                            child: Icon(
                              Icons.music_note,
                              size: iconSize,
                              color: Colors.white54,
                            ),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.music_note,
                            size: iconSize,
                            color: Colors.white54,
                          ),
                        ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          Text(
            currentSong.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (isExpanded
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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
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
              currentSong.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white70,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              currentSong.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white70,
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
    // Apple Music 风格：深色背景下进度条与时间标签用白色
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(position),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white,
            ),
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
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: (value) {
              final newPosition = Duration(
                milliseconds: (duration.inMilliseconds * value).round(),
              );
              playerProvider.seek(newPosition);
              // AppleLyricsView 内部通过 currentTimeMs 参数自动跟随滚动，无需外部强制
            },
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            _formatDuration(duration),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white,
            ),
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
        return SimpleDialog(
          title: const Center(child: Text('播放速度')),
          children: speeds.map((speed) {
            return SimpleDialogOption(
              onPressed: () {
                playerProvider.setSpeed(speed);
                Navigator.pop(context);
              },
              child: Text(
                speed == 1.0 ? '1.0x (正常)' : '${speed}x',
                textAlign: TextAlign.center,
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

    // 异步触发下载，根据返回值给出反馈。
    // 之前是 fire-and-forget 且提前显示"开始下载"，
    // 权限失败时用户会看到"开始下载"但实际什么都没发生。
    _triggerDownload(downloadsProvider, song);
  }

  Future<void> _triggerDownload(
    DownloadsProvider provider,
    dynamic song,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final songTitle = song.title;
    final started = await provider.downloadSong(song);
    if (started) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('开始下载: $songTitle'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (provider.lastPermissionGranted == false) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('存储权限被拒，请在系统设置中授予后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('无法下载: $songTitle（未获取到下载链接）'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
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
      builder: (context) => SafeArea(
        child: const LyricPreferencesPanel(),
      ),
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
    showDialog(
      context: context,
      builder: (dialogContext) {
        final playlist = playerProvider.playlist;
        return AlertDialog(
          title: const Center(child: Text('播放列表')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              playlist.isEmpty
                  ? const Text('播放列表为空')
                  : SizedBox(
                      width: 300,
                      height: 400,
                      child: ListView.builder(
                        itemCount: playlist.length,
                        itemBuilder: (context, index) {
                          final song = playlist[index];
                          final isCurrent =
                              index == playerProvider.currentIndex;
                          return ListTile(
                            leading: isCurrent
                                ? const Icon(
                                    Icons.play_arrow,
                                    color: Colors.blue,
                                  )
                                : Text('${index + 1}'),
                            title: Text(
                              song.displayName,
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
                              Navigator.pop(dialogContext);
                            },
                          );
                        },
                      ),
                    ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
                  width: 300,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: playlist.isEmpty
                            ? null
                            : () {
                                playerProvider.clearPlaylist();
                                Navigator.pop(dialogContext);
                              },
                        child: const Text('清空'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
