import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/utils/audio_scanner.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../coverflow/coverflow_page.dart';
import '../settings/equalizer_settings_page.dart';
import 'mv_player_page.dart';
import '../../providers/device_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/comment_display_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/flowing_background.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/ai_recommend_sheet.dart';
import '../../widgets/player_artwork_image.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/player_playlist_view.dart';
import 'comments_view.dart';
import 'dlna_cast_sheet.dart';
import 'full_player_route.dart';

/// 预加载封面图片到磁盘缓存，防止切换时白屏
void _preloadArtwork(String? url) {
  if (url == null || url.isEmpty) return;
  // 仅预加载在线封面，本地封面（content:// / local:// / file://）由组件按需加载
  if (url.startsWith('http://') || url.startsWith('https://')) {
    CachedNetworkImageProvider(url).resolve(const ImageConfiguration());
  }
}

const List<AudioQuality> _audioQualities = [
  AudioQuality.standard,
  AudioQuality.high,
  AudioQuality.flac,
  AudioQuality.hires,
];

/// 定时关闭预定义档位（分钟）。
const List<Duration> _sleepTimerPresets = [
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(minutes: 60),
  Duration(minutes: 90),
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
  // 当前歌曲是否有翻译/罗马音数据，用于 ActionBar 长按切换模式判断
  bool _hasTranslation = false;
  bool _hasRoma = false;

  // 封面 + 背景淡入淡出动画
  late final AnimationController _artworkFadeController;
  late final Animation<double> _artworkFadeAnimation;
  String? _previousArtworkUrl;

  // 桌面歌词状态监听：长按歌词按钮 toggle 后同步 icon
  late final VoidCallback _onDesktopLyricChanged;

  // Pad 模式：左侧已有封面，隐藏"封面"Tab，只保留 2 个 Tab
  bool _isPadMode = false;
  int _currentTabLength = 4;
  // 手机横屏模式：保留封面Tab，但隐藏左侧歌曲信息
  bool _isPhoneLandscape = false;

  // === 拖拽收起手势：已移除（与 MD 风格统一：无把手单行布局，关闭通过返回按钮） ===
  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  /// 上次的物理尺寸，用于 didChangeMetrics 方向变化防抖。
  /// 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
  /// 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁。
  Size? _lastPhysicalSize;

  // ── Zen Mode：长按播放列表按钮进入沉浸模式 ──
  bool _zenMode = false;
  late final AnimationController _zenController;
  late final Animation<double> _zenAnimation;

  // ── Zen 长按专辑图片退出 ──
  Timer? _zenLongPressTimer;
  bool _zenLongPressActive = false;

  // 进度条拖动状态：记录拖动前是否正在播放，拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 默认停在专辑 tab（index 1，播放列表 tab 在左侧）
    _tabController = TabController(length: 4, vsync: this, initialIndex: 1);
    // 桌面歌词状态变化时刷新 UI（同步歌词按钮 icon）
    _onDesktopLyricChanged = () {
      if (mounted) setState(() {});
    };
    DesktopLyricService.instance.addListener(_onDesktopLyricChanged);
    _artworkFadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _artworkFadeAnimation = CurvedAnimation(
      parent: _artworkFadeController,
      curve: Curves.easeInOut,
    );
    _artworkFadeController.value = 1.0;
    _zenController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _zenAnimation = CurvedAnimation(
      parent: _zenController,
      curve: Curves.easeInOut,
    );
    // 进入播放器时根据当前方向应用沉浸模式
    applyImmersiveForOrientation();
    // 记录初始物理尺寸，避免首次 didChangeMetrics 因 _lastPhysicalSize==null 误判方向变化
    _lastPhysicalSize =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
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
    // 与手机端统一：4 个 tab（播放列表 / 封面 / 歌词 / 评论），ActionBar 按钮索引对齐
    const newTabLength = 4;

    // Pad 模式首次进入（从非 pad → pad 且当前停在默认专辑 index 1）
    // 时直接跳到歌词（index 2），无需重建 TabController。
    // 避免每次从 miniplayer 点开都停在专辑 tab。
    // 后续用户手动切换 tab 后保留用户当前选择。
    if (shouldBePadMode && !_isPadMode && _tabController.index == 1) {
      _tabController.index = 2;
    }

    if (_currentTabLength != newTabLength) {
      // 保存当前 tab 索引
      final currentIndex = _tabController.index.clamp(0, newTabLength - 1);
      _tabController.dispose();
      _currentTabLength = newTabLength;
      _tabController = TabController(
        length: newTabLength,
        vsync: this,
        initialIndex: currentIndex,
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
      if (_previousArtworkUrl != null &&
          _previousArtworkUrl != song.artworkUri) {
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
      if (idx < playlist.length - 1)
        _preloadArtwork(playlist[idx + 1].artworkUri);
    }
  }

  @override
  void didChangeMetrics() {
    // 延迟一帧再检测方向，确保 physicalSize 已更新为新方向
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final current = view.physicalSize;
      // 防抖：仅在物理尺寸（方向）真正变化时才重新应用沉浸模式
      // 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
      // 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁
      if (_lastPhysicalSize == current) return;
      _lastPhysicalSize = current;
      if (_zenMode) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        applyImmersiveForOrientation();
      }
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
    _zenLongPressTimer?.cancel();
    try {
      context.read<PlayerProvider>().removeListener(_onPlayerSongChanged);
    } catch (_) {}
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
    WidgetsBinding.instance.removeObserver(this);
    _artworkFadeController.dispose();
    _zenController.dispose();
    _tabController.dispose();
    // 退出播放器时恢复系统栏；若仍处于封面流页横屏沉浸（从封面流进入播放器后返回），
    // 则保持沉浸，避免返回后状态栏闪现。
    if (kCoverFlowImmersiveActive.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      restoreSystemUi();
    }
    super.dispose();
  }

  /// 进入 Zen 沉浸模式：隐藏顶栏、控件、系统栏，拓宽歌词/封面视图。
  void _enterZenMode() {
    if (_zenMode) return;
    setState(() => _zenMode = true);
    _zenController.forward();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 退出 Zen 沉浸模式：恢复所有 UI 元素和系统栏。
  void _exitZenMode() {
    if (!_zenMode) return;
    setState(() => _zenMode = false);
    _zenController.reverse();
    applyImmersiveForOrientation();
  }

  /// Zen 模式下长按专辑图片 2000ms 退出，期间显示文字提示。
  /// 通过 Listener 的 onPointerDown/Up 直接监听指针事件，
  /// 精确实现 2000ms 长按（不依赖系统 500ms 长按识别延迟），
  /// 同时不影响 TabBarView 水平滑动手势。
  void _onArtworkLongPressStart() {
    if (!_zenMode) return;
    _zenLongPressActive = true;
    setState(() {}); // 触发文字提示显示
    _zenLongPressTimer = Timer(const Duration(milliseconds: 2000), () {
      if (_zenLongPressActive && _zenMode) {
        _zenLongPressActive = false;
        _exitZenMode();
      }
    });
  }

  void _onArtworkLongPressEnd() {
    _zenLongPressTimer?.cancel();
    _zenLongPressTimer = null;
    if (_zenLongPressActive) {
      _zenLongPressActive = false;
      setState(() {}); // 隐藏文字提示
    }
  }

  /// Zen 模式长按退出提示层：覆盖在封面上，半透明黑色背景 + 文字提示。
  /// 仅在长按激活时显示，IgnorePointer 避免拦截指针事件。
  Widget _buildZenLongPressHint() {
    if (!_zenLongPressActive) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: Colors.black.withValues(alpha: 0.6),
            alignment: Alignment.center,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.exit_to_app, color: Colors.white, size: 32),
                SizedBox(height: 8),
                Text(
                  '继续长按退出 Zen 模式',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
      String lyricText = '';
      String? translationText;
      String? romaText;

      // 本地歌曲优先读取内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）
      if (song is Song && !song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          // file:// URI 或 content:// 需要提取真实路径
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = readEmbeddedLyrics(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            lyricText = embedded;
          }
        }
      }

      // 内嵌歌词为空时回退到酷狗 API
      if (lyricText.isEmpty) {
        final kugouProvider = context.read<KugouProvider>();
        // 本地歌曲的 songId 是 'local_<path>'，不是酷狗 hash，
        // 传空 hash 让酷狗 API 完全基于 songName 搜索歌词
        final lyricHash = (song is Song && !song.isOnline) ? '' : songId;
        // 搜索关键词用"歌名 艺术家"提高匹配准确度
        final searchName = (song is Song && song.artist != '未知艺术家')
            ? '${song.title} ${song.artist}'
            : song.title;
        await kugouProvider.getLyric(lyricHash, songName: searchName);

        if (mounted) {
          final lyric = kugouProvider.lyric;
          lyricText =
              lyric?.displayKrcLyric ??
              lyric?.displayLrcLyric ??
              lyric?.displayLyric ??
              '';
          translationText = lyric?.translatedContent;
          romaText = lyric?.romaContent;
        }
      }

      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _hasTranslation =
              translationText != null && translationText.isNotEmpty;
          _hasRoma = romaText != null && romaText.isNotEmpty;
          _parsedLyrics = LyricParserChain.parse(
            lyricText,
            translationText: translationText,
            romaText: romaText,
          );
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

  /// 判断当前歌曲是否为本地歌曲且歌词为 LRC 逐行格式（无字级时间戳）。
  ///
  /// 这种情况禁用 AppleLyricsView 的间奏点（节奏点）动画：
  /// LRC 逐行没有逐字时间戳，行间节奏点与真实节拍不易对齐，
  /// 本地歌曲的 LRC 又常常缺少精确时间戳，体验较差，禁用后更干净。
  ///
  /// 若是字级 LRC（含逐字时间戳），行起始时间戳精确到毫秒，
  /// 间奏点可以正常对齐节拍，应保留。
  /// 在线歌曲 / KRC 逐字歌词 / 静态歌词不受影响。
  bool _isLocalLrcLyricWithoutWordTiming(dynamic currentSong) {
    if (currentSong is! Song || currentSong.isOnline) return false;
    if (_lyricFormat != LyricFormat.lrc) return false;
    // 任意一行有字级时间戳即视为字级 LRC（混合场景按字级处理）
    return !_parsedLyrics.any((line) => line.hasWordTiming);
  }

  /// 封面淡入淡出（AM 风格：白色占位）
  Widget _buildCrossfadeArtwork(
    String? artworkUrl,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
    String? fallbackFilePath,
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
                  child: PlayerArtworkImage(
                    artworkUri: _previousArtworkUrl,
                    fallbackFilePath: fallbackFilePath,
                    fit: BoxFit.cover,
                    iconSize: iconSize,
                    backgroundColor: Colors.white12,
                    iconColor: Colors.white54,
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: PlayerArtworkImage(
                  artworkUri: artworkUrl,
                  fallbackFilePath: fallbackFilePath,
                  fit: BoxFit.cover,
                  iconSize: iconSize,
                  backgroundColor: Colors.white12,
                  iconColor: Colors.white54,
                ),
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

  /// 模糊背景淡入淡出（无 alpha 渐变；渐变移到 AppleLyricsView 歌词界面边界）
  Widget _buildCrossfadeBlurredBackground(
    String? artworkUrl, {
    String? fallbackFilePath,
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
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                    child: PlayerArtworkImage(
                      artworkUri: _previousArtworkUrl,
                      fallbackFilePath: fallbackFilePath,
                      isFill: true,
                      fit: BoxFit.cover,
                      backgroundColor: Colors.black,
                      iconColor: Colors.white24,
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                  child: PlayerArtworkImage(
                    artworkUri: artworkUrl,
                    fallbackFilePath: fallbackFilePath,
                    isFill: true,
                    fit: BoxFit.cover,
                    backgroundColor: Colors.black,
                    iconColor: Colors.white24,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // === 拖拽收起手势已移除（与 MD 风格统一：仅通过返回按钮 / 系统返回键收起） ===

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

  /// 跳转到当前歌曲所在专辑页。
  /// 若 song.albumId 为空（如本地歌曲缺少元数据），提示用户无专辑信息。
  void _navigateToAlbum(Song song) {
    final albumId = song.albumId;
    if (albumId == null || albumId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂无专辑信息'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final album = Album(
      id: albumId,
      name: song.album,
      artist: song.artist,
      artworkUri: song.artworkUri,
      songCount: 0,
    );
    // 先 dismiss FullPlayer，再 push 专辑页。
    // 注意：必须在 dismiss 之前捕获 navigatorState 引用，因为 dismiss 后
    // widget 会被 dispose，State.mounted 变为 false，原来的 if (mounted) 检查会失败。
    final navigatorState = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState.push(
          MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
        );
      });
    } else {
      navigatorState.push(
        MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
      );
    }
  }

  /// 拆分歌手名列表。
  /// 酷狗 API 返回的 artist 字段多位歌手用「、」「;」「/」「&」「，」等分隔符连接。
  List<String> _splitArtistNames(String artist) {
    if (artist.isEmpty) return const [];
    return artist
        .split(RegExp(r'[、;；/,，&]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 跳转到当前歌曲所在歌手页。
  /// 若 song.artistId 为空（如本地歌曲缺少元数据），提示用户无歌手信息。
  /// 跳转前先 dismiss FullPlayer，让 MiniPlayer 恢复显示。
  /// 若有多位歌手，弹出二级菜单让用户选择具体某位歌手。
  void _navigateToArtist(Song song) {
    final artists = _splitArtistNames(song.artist);
    if (artists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂无歌手信息'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // 单歌手：直接跳转
    if (artists.length == 1) {
      _pushArtistPage(song.artistId, artists.first);
      return;
    }
    // 多位歌手：弹出二级菜单让用户选择
    _showArtistSelector(context, song, artists);
  }

  /// 弹出歌手选择 BottomSheet（多位歌手场景）。
  /// 第一位歌手直接使用 song.artistId 跳转；
  /// 其他歌手通过 searchArtists 接口查询 ID 后跳转。
  void _showArtistSelector(
    BuildContext context,
    Song song,
    List<String> artists,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择歌手',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...artists.map((name) {
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(name),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    // 第一位歌手直接用 song.artistId（数据已存在）
                    if (name == artists.first) {
                      _pushArtistPage(song.artistId, name);
                    } else {
                      // 其他歌手需要先搜索查询 ID
                      _pushArtistPageByName(name);
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  /// 通过歌手名搜索后跳转歌手详情页。
  /// 显示 loading → 调用 searchArtists → 取第一个匹配 → 跳转
  Future<void> _pushArtistPageByName(String name) async {
    // 显示 loading（AM 风格：白色，与深色模糊背景协调）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: MD3ELoadingIndicator(color: Colors.white)),
    );
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      if (result == null || result.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('未找到歌手「$name」')));
        return;
      }
      final artist = result.first;
      _pushArtistPage(artist.id, artist.name);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('搜索歌手失败：$e')));
    }
  }

  /// 实际 push 歌手详情页。先 dismiss FullPlayer，再 push。
  void _pushArtistPage(String? artistId, String artistName) {
    if (artistId == null || artistId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂无歌手信息'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // 注意：必须在 dismiss 之前捕获 navigatorState 引用，因为 dismiss 后
    // widget 会被 dispose，State.mounted 变为 false，原来的 if (mounted) 检查会失败。
    final navigatorState = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState.push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailPage(
              artistId: artistId,
              artistName: artistName,
              avatarUrl: null,
            ),
          ),
        );
      });
    } else {
      navigatorState.push(
        MaterialPageRoute(
          builder: (_) => ArtistDetailPage(
            artistId: artistId,
            artistName: artistName,
            avatarUrl: null,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // v4 优化：父级 build 只在切歌（currentSong.id 变化）或播放/暂停（isPlaying）时执行。
    // position 更新（200ms）通过 AppleLyricsView 与进度条自身的 Selector 注入，不触发父级重建。
    return Selector<
      PlayerProvider,
      ({String? songId, bool isPlaying, AudioQuality audioQuality})
    >(
      selector: (_, p) => (
        songId: p.currentSong?.id,
        isPlaying: p.isPlaying,
        audioQuality: p.audioQuality,
      ),
      builder: (context, _, __) {
        final playerProvider = context.read<PlayerProvider>();
        final lyricDoubleTap = context
            .watch<ThemeProvider>()
            .lyricDoubleTapToJump;
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
            if (_zenMode) {
              _exitZenMode();
              return;
            }
            _collapseByButton();
          },
          child: _buildFullLayout(
            playerProvider,
            currentSong,
            colorScheme,
            lyricDoubleTap,
          ),
        );
      },
    );
  }

  /// 全屏 Apple Music 风格布局：模糊封面背景 + 蒙版 + 三套响应式布局。
  /// 对应 spec.md "Requirement: 模糊封面背景"。
  Widget _buildFullLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // extendBody: true 让内容延伸到系统导航栏后面，实现沉浸效果
    // 引用 kPlayerOverlayStyle 与 applyImmersiveForOrientation 共用同一 const 实例
    // 避免 SystemUiOverlayStyle 引用不等触发平台 channel 真实调用导致闪烁
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: kPlayerOverlayStyle,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBody: true,
        body: Stack(
          children: [
            // 1. 模糊封面背景层（Apple Music 风格，带淡入淡出）
            _buildCrossfadeBlurredBackground(
              currentSong.artworkUri,
              fallbackFilePath: currentSong.localPath,
            ),
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
              compact: (_) => _buildCompactLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
              medium: (_) => _buildLandscapeLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
              expanded: (_) => _buildExpandedLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
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
    bool lyricDoubleTap,
  ) {
    // 竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    // 使用 viewPadding.bottom 和固定最小值 32 确保控件不被遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 32;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _ZenFade(
            animation: _zenAnimation,
            child: _buildTopBar(playerProvider),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 播放列表面板（index 0，专辑封面 tab 左侧）
                const PlayerPlaylistView(useDisplayName: true),
                GestureDetector(
                  onTap: () => _tabController.animateTo(2),
                  behavior: HitTestBehavior.opaque,
                  // Selector 让 _buildArtworkView 仅在 currentSong / isPlaying 变化时重建，
                  // 不再每 200ms 因 position 变化重建（封面 AnimatedScale 是隐式动画，需要 isPlaying 触发）
                  child:
                      Selector<
                        PlayerProvider,
                        ({String? songId, bool isPlaying})
                      >(
                        selector: (_, p) =>
                            (songId: p.currentSong?.id, isPlaying: p.isPlaying),
                        builder: (context, _, __) => _buildArtworkView(
                          playerProvider,
                          currentSong,
                          colorScheme,
                          isExpanded: true,
                        ),
                      ),
                ),
                GestureDetector(
                  onTap: () => _tabController.animateTo(1),
                  behavior: HitTestBehavior.translucent,
                  // RepaintBoundary 隔离 AppleLyricsView 每帧 setState 的重绘范围，
                  // 避免父级 TabBarView/Column 被牵连重建
                  child: RepaintBoundary(
                    child: _isLoadingLyrics
                        // AM 风格：歌词 loading 改为白色，与深色背景协调
                        ? const Center(
                            child: MD3ELoadingIndicator(color: Colors.white),
                          )
                        // v4 优化：用 Selector 注入 position，避免父级每 200ms 重建
                        : Selector<PlayerProvider, int>(
                            selector: (_, p) => p.position.inMilliseconds,
                            builder: (context, positionMs, _) =>
                                AppleLyricsView(
                                  lines: _parsedLyrics,
                                  currentTimeMs: positionMs,
                                  isPlaying: playerProvider.isPlaying,
                                  forceDarkBackground: true,
                                  // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                  enableInterludeDots:
                                      !_isLocalLrcLyricWithoutWordTiming(
                                        currentSong,
                                      ),
                                  doubleTapToJump: lyricDoubleTap,
                                  onSeek: (ms) => playerProvider.seek(
                                    Duration(milliseconds: ms),
                                  ),
                                ),
                          ),
                  ),
                ),
                // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                Selector<PlayerProvider, String?>(
                  selector: (_, p) => p.currentSong?.id,
                  builder: (_, _, __) => CommentsView(
                    songHash: currentSong.id,
                    albumAudioId: currentSong.albumAudioId,
                    artworkUri: currentSong.artworkUri,
                    isAmStyle: true,
                  ),
                ),
              ],
            ),
          ),
          _ZenFade(
            animation: _zenAnimation,
            child: Padding(
              padding: EdgeInsets.only(bottom: _zenMode ? 16 : bottomPadding),
              child: _buildControls(playerProvider, colorScheme),
            ),
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
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
          _ZenFade(
            animation: _zenAnimation,
            child: _buildTopBar(playerProvider),
          ),
          Expanded(
            child: Row(
              children: [
                // ── 左侧：封面 + 歌曲信息 ──
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 横屏时封面为正方形，需同时受可用宽度与高度约束：
                        // 减去 56 顶栏补偿后的可用高度，避免高度不足时正方形上下被裁切
                        final availableHeight = constraints.maxHeight - 56;
                        final size =
                            (constraints.maxWidth < availableHeight
                                    ? constraints.maxWidth
                                    : availableHeight)
                                .clamp(120.0, 300.0);
                        return Stack(
                          children: [
                            // 封面居中：补偿顶栏高度，使封面在整个屏幕垂直方向居中
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: _zenMode ? 0.0 : 56.0,
                              ),
                              child: Center(
                                child: SizedBox(
                                  width: size,
                                  height: size,
                                  // Listener 包裹封面：Zen 模式下监听长按手势
                                  child: Listener(
                                    onPointerDown: (_) =>
                                        _onArtworkLongPressStart(),
                                    onPointerUp: (_) =>
                                        _onArtworkLongPressEnd(),
                                    onPointerCancel: (_) =>
                                        _onArtworkLongPressEnd(),
                                    child: Stack(
                                      children: [
                                        AnimatedScale(
                                          scale: playerProvider.isPlaying
                                              ? 1.0
                                              : 0.85,
                                          duration: const Duration(
                                            milliseconds: 500,
                                          ),
                                          curve: Curves.easeOutBack,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            // Selector 让封面仅在 artworkUri 变化时重建
                                            child:
                                                Selector<
                                                  PlayerProvider,
                                                  (String?, String?)
                                                >(
                                                  selector: (_, p) => (
                                                    p.currentSong?.artworkUri,
                                                    p.currentSong?.localPath,
                                                  ),
                                                  builder: (context, data, __) =>
                                                      _buildCrossfadeArtwork(
                                                        data.$1,
                                                        colorScheme,
                                                        iconSize: 48,
                                                        fallbackFilePath:
                                                            data.$2,
                                                      ),
                                                ),
                                          ),
                                        ),
                                        _buildZenLongPressHint(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 歌曲信息：垂直方向 80% 位置，水平居中（手机横屏时隐藏）
                            // 与手机端 _buildArtworkView 一致：标题用 titleLarge
                            if (!_isPhoneLandscape)
                              Positioned(
                                top: constraints.maxHeight * 0.8,
                                left: 0,
                                right: 0,
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(color: Colors.white),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.white70),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.album,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.white54),
                                        textAlign: TextAlign.center,
                                      ),
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
                // ── 右侧：Tab + 内容 + 控制 ──
                Expanded(
                  flex: 6,
                  child: Column(
                    children: [
                      // 内容区（播放列表 / 封面信息 / 歌词 / 评论）
                      // 与手机端统一：4 个 tab，ActionBar 按钮索引对齐
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // 播放列表面板（index 0，封面信息 tab 左侧）
                            const PlayerPlaylistView(useDisplayName: true),
                            Selector<PlayerProvider, String?>(
                              selector: (_, p) => p.currentSong?.id,
                              builder: (context, songId, __) {
                                final song = playerProvider.currentSong;
                                if (song == null)
                                  return const SizedBox.shrink();
                                return _buildSongInfo(
                                  playerProvider,
                                  song,
                                  colorScheme,
                                );
                              },
                            ),
                            _isLoadingLyrics
                                // AM 风格：歌词 loading 改为白色，与深色背景协调
                                ? const Center(
                                    child: MD3ELoadingIndicator(
                                      color: Colors.white,
                                    ),
                                  )
                                : RepaintBoundary(
                                    // v4 优化：用 Selector 注入 position，避免父级每 200ms 重建
                                    child: Selector<PlayerProvider, int>(
                                      selector: (_, p) =>
                                          p.position.inMilliseconds,
                                      builder: (context, positionMs, _) =>
                                          AppleLyricsView(
                                            lines: _parsedLyrics,
                                            currentTimeMs: positionMs,
                                            isPlaying: playerProvider.isPlaying,
                                            forceDarkBackground: true,
                                            // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                            enableInterludeDots:
                                                !_isLocalLrcLyricWithoutWordTiming(
                                                  currentSong,
                                                ),
                                            doubleTapToJump: lyricDoubleTap,
                                            onSeek: (ms) => playerProvider.seek(
                                              Duration(milliseconds: ms),
                                            ),
                                          ),
                                    ),
                                  ),
                            // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                            Selector<PlayerProvider, String?>(
                              selector: (_, p) => p.currentSong?.id,
                              builder: (_, _, __) => CommentsView(
                                songHash: currentSong.id,
                                albumAudioId: currentSong.albumAudioId,
                                artworkUri: currentSong.artworkUri,
                                isAmStyle: true,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 控制区：底部 padding 包含导航栏高度
                      _ZenFade(
                        animation: _zenAnimation,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: _zenMode ? 8 : bottomPadding,
                          ),
                          child: _buildControls(
                            playerProvider,
                            colorScheme,
                            isExpanded: true,
                          ),
                        ),
                      ),
                    ],
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
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
          _ZenFade(
            animation: _zenAnimation,
            child: _buildTopBar(playerProvider),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final maxSize = (constraints.maxWidth - 32).clamp(
                          0.0,
                          380.0,
                        );
                        return Stack(
                          children: [
                            // 封面居中：补偿顶栏高度，使封面在整个屏幕垂直方向居中
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: _zenMode ? 0.0 : 56.0,
                              ),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: maxSize,
                                    maxHeight: maxSize,
                                  ),
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    // Listener 包裹封面：Zen 模式下监听长按手势
                                    child: Listener(
                                      onPointerDown: (_) =>
                                          _onArtworkLongPressStart(),
                                      onPointerUp: (_) =>
                                          _onArtworkLongPressEnd(),
                                      onPointerCancel: (_) =>
                                          _onArtworkLongPressEnd(),
                                      child: Stack(
                                        children: [
                                          AnimatedScale(
                                            scale: playerProvider.isPlaying
                                                ? 1.0
                                                : 0.85,
                                            duration: const Duration(
                                              milliseconds: 500,
                                            ),
                                            curve: Curves.easeOutBack,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              // Selector 让封面仅在 artworkUri 变化时重建
                                              child:
                                                  Selector<
                                                    PlayerProvider,
                                                    (String?, String?)
                                                  >(
                                                    selector: (_, p) => (
                                                      p.currentSong?.artworkUri,
                                                      p.currentSong?.localPath,
                                                    ),
                                                    builder: (context, data, __) =>
                                                        _buildCrossfadeArtwork(
                                                          data.$1,
                                                          colorScheme,
                                                          iconSize: 48,
                                                          fallbackFilePath:
                                                              data.$2,
                                                        ),
                                                  ),
                                            ),
                                          ),
                                          _buildZenLongPressHint(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 歌曲信息：垂直方向 80% 位置，水平居中（手机横屏时隐藏）
                            // 与手机端 _buildArtworkView 一致：标题用 titleLarge
                            if (!_isPhoneLandscape)
                              Positioned(
                                top: constraints.maxHeight * 0.8,
                                left: 0,
                                right: 0,
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(color: Colors.white),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.white70),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.album,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.white54),
                                        textAlign: TextAlign.center,
                                      ),
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
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // 播放列表面板（index 0，封面信息 tab 左侧）
                            const PlayerPlaylistView(useDisplayName: true),
                            // 与手机端统一：4 个 tab（播放列表 / 封面 / 歌词 / 评论），
                            // ActionBar 按钮 tab 索引对齐。
                            // Pad 模式左侧已有封面，但 ActionBar 仍依赖标准 tab 顺序。
                            Selector<PlayerProvider, String?>(
                              selector: (_, p) => p.currentSong?.id,
                              builder: (context, songId, __) {
                                final song = playerProvider.currentSong;
                                if (song == null)
                                  return const SizedBox.shrink();
                                return _buildSongInfo(
                                  playerProvider,
                                  song,
                                  colorScheme,
                                );
                              },
                            ),
                            _isLoadingLyrics
                                // AM 风格：歌词 loading 改为白色，与深色背景协调
                                ? const Center(
                                    child: MD3ELoadingIndicator(
                                      color: Colors.white,
                                    ),
                                  )
                                : RepaintBoundary(
                                    // v4 优化：用 Selector 注入 position，避免父级每 200ms 重建
                                    child: Selector<PlayerProvider, int>(
                                      selector: (_, p) =>
                                          p.position.inMilliseconds,
                                      builder: (context, positionMs, _) =>
                                          AppleLyricsView(
                                            lines: _parsedLyrics,
                                            currentTimeMs: positionMs,
                                            isPlaying: playerProvider.isPlaying,
                                            forceDarkBackground: true,
                                            // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                            enableInterludeDots:
                                                !_isLocalLrcLyricWithoutWordTiming(
                                                  currentSong,
                                                ),
                                            doubleTapToJump: lyricDoubleTap,
                                            onSeek: (ms) => playerProvider.seek(
                                              Duration(milliseconds: ms),
                                            ),
                                          ),
                                    ),
                                  ),
                            // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                            Selector<PlayerProvider, String?>(
                              selector: (_, p) => p.currentSong?.id,
                              builder: (_, _, __) => CommentsView(
                                songHash: currentSong.id,
                                albumAudioId: currentSong.albumAudioId,
                                artworkUri: currentSong.artworkUri,
                                isAmStyle: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 控制区：底部 padding 包含导航栏高度
                      _ZenFade(
                        animation: _zenAnimation,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: _zenMode ? 8 : bottomPadding,
                          ),
                          child: _buildControls(
                            playerProvider,
                            colorScheme,
                            isExpanded: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(PlayerProvider playerProvider) {
    // AM 风格顶部栏：返回 / 质量徽章 / 菜单分列两侧，无把手、无 TabBar
    // 颜色：白色 + 透明度区分（与 MD 风格的莫奈色对应）
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
            onPressed: _collapseByButton,
          ),
          const Spacer(),
          // AM v2: 顶部栏右侧 FLAC 质量徽章，点击复用 _showQualityDialog，
          // 长按呼出 _showVolumeDialog（与 MD 风格统一）
          _buildQualityPill(playerProvider),
          // 睡眠药丸：用 ListenableBuilder 独立监听，确保每秒走字
          ListenableBuilder(
            listenable: playerProvider,
            builder: (context, _) {
              if (!playerProvider.isSleepTimerActive) {
                return const SizedBox.shrink();
              }
              return _buildSleepTimerPill(playerProvider);
            },
          ),
          if (playerProvider.currentSong?.isOnline == true)
            IconButton(
              icon: const Icon(Icons.music_video_outlined, color: Colors.white),
              tooltip: '查看 MV',
              onPressed: () {
                final song = playerProvider.currentSong;
                if (song == null) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () => _showMoreMenu(context),
          ),
        ],
      ),
    );
  }

  /// AM v2 质量徽章 — 白色 15% 透明度背景 + StadiumBorder + 图标 + 文字。
  /// 本地歌曲：只读显示码率推断的音质，禁用点击切换。
  /// 在线歌曲：点击复用 _showQualityDialog，长按复用 _showVolumeDialog。
  Widget _buildQualityPill(PlayerProvider playerProvider) {
    final textTheme = Theme.of(context).textTheme;
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    // AM 风格：深色背景蒙版（0.35 黑色）上用白色 15% 透明度作 pill 底
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      shape: const StadiumBorder(),
      child: InkWell(
        // 本地歌曲屏蔽音质选择
        onTap: isLocal ? null : () => _showQualityDialog(playerProvider),
        onLongPress: () => _showVolumeDialog(playerProvider),
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.music_note, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                // 本地歌曲显示基于码率推断的音质标签
                playerProvider.currentQualityLabel,
                style: textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
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
          if (isExpanded) ...[
            const Spacer(),
            LayoutBuilder(
              builder: (context, constraints) {
                final maxSize = (constraints.maxWidth - 32).clamp(0.0, 380.0);
                // Listener 包裹封面：Zen 模式下监听长按手势，精确 2000ms 退出
                return Listener(
                  onPointerDown: (_) => _onArtworkLongPressStart(),
                  onPointerUp: (_) => _onArtworkLongPressEnd(),
                  onPointerCancel: (_) => _onArtworkLongPressEnd(),
                  child: Stack(
                    children: [
                      ConstrainedBox(
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
                                fallbackFilePath: currentSong.localPath,
                              ),
                            ),
                          ),
                        ),
                      ),
                      _buildZenLongPressHint(),
                    ],
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
                    fallbackFilePath: currentSong.localPath,
                  ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          InkWell(
            onTap: () => _navigateToAlbum(currentSong as Song),
            borderRadius: BorderRadius.circular(4),
            child: Text(
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
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => _navigateToAlbum(currentSong as Song),
            borderRadius: BorderRadius.circular(4),
            child: Text(
              currentSong.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 2),
          InkWell(
            onTap: () => _navigateToAlbum(currentSong as Song),
            borderRadius: BorderRadius.circular(4),
            child: Text(
              currentSong.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
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
            InkWell(
              onTap: () => _navigateToAlbum(currentSong as Song),
              borderRadius: BorderRadius.circular(4),
              child: Text(
                currentSong.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => _navigateToAlbum(currentSong as Song),
              borderRadius: BorderRadius.circular(4),
              child: Text(
                currentSong.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 2),
            InkWell(
              onTap: () => _navigateToAlbum(currentSong as Song),
              borderRadius: BorderRadius.circular(4),
              child: Text(
                currentSong.album,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
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
    final horizontalPadding = isExpanded ? 16.0 : 24.0;
    final verticalSpacing = isExpanded ? 4.0 : 8.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // v4 优化：进度条用 Selector 注入 position + duration，
          // 避免父级每 200ms position 更新触发 _buildControls 整体重建。
          Selector<PlayerProvider, ({Duration position, Duration? duration})>(
            selector: (_, p) => (position: p.position, duration: p.duration),
            builder: (context, state, _) => _buildProgressBar(
              playerProvider,
              state.position,
              state.duration ?? Duration.zero,
              colorScheme,
            ),
          ),
          SizedBox(height: verticalSpacing),
          // Selector 让主控制按钮仅在 isPlaying / loopMode / shuffle 变化时重建
          // 不再每 200ms 因 position 变化重建
          Selector<
            PlayerProvider,
            ({bool isPlaying, AppLoopMode loopMode, bool shuffleEnabled})
          >(
            selector: (_, p) => (
              isPlaying: p.isPlaying,
              loopMode: p.loopMode,
              shuffleEnabled: p.shuffleEnabled,
            ),
            builder: (context, state, __) => _buildMainControls(
              playerProvider,
              colorScheme,
              isExpanded: isExpanded,
              isPlaying: state.isPlaying,
              loopMode: state.loopMode,
              shuffleEnabled: state.shuffleEnabled,
            ),
          ),
          SizedBox(height: verticalSpacing),
          // Selector 让副控制按钮在 currentSong / speed / 音质标签变化时重建
          Selector<
            PlayerProvider,
            ({String? songId, double speed, String currentQualityLabel})
          >(
            selector: (_, p) => (
              songId: p.currentSong?.id,
              speed: p.speed,
              currentQualityLabel: p.currentQualityLabel,
            ),
            builder: (context, _, __) => _buildSecondaryControls(
              playerProvider,
              colorScheme,
              isExpanded: isExpanded,
            ),
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
    final hasClimax =
        song?.climaxStart != null &&
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
                  playerProvider,
                  position,
                  duration,
                  song!,
                )
              : Slider(
                  value: duration.inMilliseconds > 0
                      ? (position.inMilliseconds / duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                      : 0.0,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  onChangeStart: (value) {
                    _wasPlayingBeforeDrag = playerProvider.isPlaying;
                    if (_wasPlayingBeforeDrag) {
                      playerProvider.pauseForSeek();
                    }
                  },
                  onChanged: (value) {
                    final newPosition = Duration(
                      milliseconds: (duration.inMilliseconds * value).round(),
                    );
                    playerProvider.seek(newPosition);
                  },
                  onChangeEnd: (value) async {
                    final newPosition = Duration(
                      milliseconds: (duration.inMilliseconds * value).round(),
                    );
                    await playerProvider.seek(newPosition);
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
              onChangeStart: (value) {
                _wasPlayingBeforeDrag = playerProvider.isPlaying;
                if (_wasPlayingBeforeDrag) {
                  playerProvider.pauseForSeek();
                }
              },
              onChanged: (value) {
                final newPosition = Duration(
                  milliseconds: (totalMs * value).round(),
                );
                playerProvider.seek(newPosition);
              },
              onChangeEnd: (value) async {
                final newPosition = Duration(
                  milliseconds: (totalMs * value).round(),
                );
                await playerProvider.seek(newPosition);
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
    required bool isPlaying,
    required AppLoopMode loopMode,
    required bool shuffleEnabled,
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
            shuffleEnabled ? Icons.shuffle : Icons.shuffle_outlined,
            // 深色背景下：启用时纯白，未启用时半透明白
            color: shuffleEnabled ? Colors.white : Colors.white70,
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
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: () {
            if (isPlaying) {
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
            _getLoopModeIcon(loopMode),
            color: loopMode != AppLoopMode.off ? Colors.white : Colors.white70,
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
    // 根据歌曲来源（本地/在线）选择对应的收藏 Provider
    final isOnline = song is Song && song.isOnline;
    final isFavorited =
        song != null &&
        (isOnline
            ? context.watch<FavoritesProvider>().isFavorite(song.id)
            : context.watch<LocalFavoritesProvider>().isFavorite(song.id));
    final textTheme = Theme.of(context).textTheme;
    // AM 风格：深色蒙版背景上用 15% 透明度白色作 pill 底，图标纯白，
    // 桌面歌词开启时用实心 icon（与 mini_player 一致）。
    // ListenableBuilder 监听 LyricPreferences：翻译开关 toggle 时刷新按钮颜色
    return ListenableBuilder(
      listenable: LyricPreferences.instance,
      builder: (context, _) => Material(
        color: Colors.white.withValues(alpha: 0.15),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              // 1. 倍速指示（纯文字）
              Expanded(
                child: InkWell(
                  onTap: () => _showSpeedDialog(playerProvider),
                  child: Center(
                    child: Text(
                      '${playerProvider.speed}x',
                      style: textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              // 2. 播放列表 — 切换到播放列表面板（长按进 Zen 模式）
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (_tabController.index != 0) {
                      _tabController.animateTo(0);
                    }
                  },
                  onLongPress: _enterZenMode,
                  child: Center(
                    child: Icon(
                      Icons.queue_music,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              // 3. 封面 — 短按跳转到封面 tab，长按弹出下载音质选择（本地歌曲屏蔽长按下载）
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (_tabController.index != 1) {
                      _tabController.animateTo(1);
                    }
                  },
                  onLongPress: song != null && isOnline
                      ? () => _downloadSong(song)
                      : null,
                  child: Center(
                    child: Icon(Icons.album, size: 22, color: Colors.white),
                  ),
                ),
              ),
              // 4. 歌词 — 短按跳转到歌词 tab，长按开关桌面歌词
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (_tabController.index != 2) {
                      _tabController.animateTo(2);
                    }
                  },
                  onLongPress: () async {
                    await DesktopLyricService.instance.toggle();
                    if (mounted) {
                      // 同步通知栏"桌面歌词"按钮状态
                      final player = context.read<PlayerProvider>();
                      final curSong = player.currentSong;
                      // 收藏状态需实时查询，避免暂停时显示为未收藏
                      bool isFavorited = false;
                      if (curSong != null) {
                        try {
                          isFavorited = context
                              .read<FavoritesProvider>()
                              .isFavorite(curSong.id);
                        } catch (_) {}
                      }
                      await MediaNotificationService.updateNotification(
                        // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
                        title: curSong?.displayName ?? '',
                        artist: curSong?.artist ?? '',
                        artUrl: curSong?.artworkUri,
                        isPlaying: player.isPlaying,
                        position: player.position,
                        duration: player.duration ?? Duration.zero,
                        desktopLyricEnabled:
                            DesktopLyricService.instance.enabled,
                        isFavorited: isFavorited,
                      );
                    }
                  },
                  child: Center(
                    child: Icon(
                      // 桌面歌词开启时用实心 icon + 纯白，与 mini_player 一致
                      DesktopLyricService.instance.enabled
                          ? Icons.lyrics
                          : Icons.lyrics_outlined,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              // 5. 评论 — 跳转到评论 tab
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (_tabController.index != 3) {
                      _tabController.animateTo(3);
                    }
                  },
                  child: Center(
                    child: Icon(
                      Icons.comment_outlined,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              // 6. 收藏
              Expanded(
                child: InkWell(
                  onTap: song != null
                      ? () {
                          // 本地歌曲走 LocalFavoritesProvider，在线走 FavoritesProvider
                          if (isOnline) {
                            context.read<FavoritesProvider>().toggleFavorite(
                              song,
                            );
                          } else {
                            context
                                .read<LocalFavoritesProvider>()
                                .toggleFavorite(song.id);
                          }
                        }
                      : null,
                  // 长按：在线歌曲弹出 AI 推荐歌曲面板
                  onLongPress: song != null && isOnline
                      ? () => showAiRecommendSheet(context, song)
                      : null,
                  child: Center(
                    child: Icon(
                      isFavorited ? Icons.favorite : Icons.favorite_border,
                      size: 22,
                      // 收藏激活时用红色强调（与 MD 风格一致）
                      color: isFavorited ? Colors.redAccent : Colors.white,
                    ),
                  ),
                ),
              ),
              // 7. 翻译/罗马音开关 — 短按 toggle 副行显示，长按切换模式
              Expanded(
                child: InkWell(
                  onTap: () {
                    LyricPreferences.instance.setShowTranslation(
                      !LyricPreferences.instance.showTranslation,
                    );
                  },
                  onLongPress: () {
                    // 仅当歌曲同时有翻译和罗马音时才切换模式
                    if (!_hasTranslation || !_hasRoma) return;
                    final next =
                        LyricPreferences.instance.displayMode ==
                            LyricDisplayMode.translation
                        ? LyricDisplayMode.roma
                        : LyricDisplayMode.translation;
                    LyricPreferences.instance.setDisplayMode(next);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          next == LyricDisplayMode.roma ? '已切换到罗马音' : '已切换到翻译',
                        ),
                        duration: const Duration(milliseconds: 800),
                      ),
                    );
                  },
                  child: Center(
                    child: Icon(
                      // 罗马音模式用 Icons.abc 区分，翻译模式用 Icons.translate
                      LyricPreferences.instance.displayMode ==
                              LyricDisplayMode.roma
                          ? Icons.abc
                          : Icons.translate,
                      size: 22,
                      // 开启时纯白，关闭时 50% 白（视觉上与其它按钮激活态一致）
                      color: LyricPreferences.instance.showTranslation
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
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
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
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
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : null,
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
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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

  void _downloadSong(dynamic song) async {
    final downloadsProvider = context.read<DownloadsProvider>();
    final isDownloaded = downloadsProvider.isDownloaded(song.id);
    final isDownloading = downloadsProvider.isDownloading(song.id);

    if (isDownloaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已下载: ${song.displayName}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('正在下载: ${song.displayName}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // 查询歌曲实际可用音质
    final api = KugouApiClient();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在查询可用音质...'),
        duration: Duration(seconds: 3),
      ),
    );
    final available = await api.getAvailableQualities(
      song.id,
      albumId: song.albumId,
      albumAudioId: song.albumAudioId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

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
            _buildDownloadQualityOption(
              ctx,
              '标准音质 (128kbps)',
              '128',
              song,
              downloadsProvider,
              enabled: available.contains('128'),
            ),
            _buildDownloadQualityOption(
              ctx,
              '高音质 (320kbps)',
              'hq',
              song,
              downloadsProvider,
              enabled: available.contains('hq'),
            ),
            _buildDownloadQualityOption(
              ctx,
              '无损音质 (FLAC)',
              'flac',
              song,
              downloadsProvider,
              enabled: available.contains('flac'),
            ),
            _buildDownloadQualityOption(
              ctx,
              'Hi-Res 无损',
              'high',
              song,
              downloadsProvider,
              enabled: available.contains('high'),
            ),
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
    DownloadsProvider provider, {
    bool enabled = true,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.music_note,
        size: 20,
        color: enabled ? null : Theme.of(context).disabledColor,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: enabled ? null : Theme.of(context).disabledColor,
        ),
      ),
      trailing: enabled
          ? null
          : Text(
              '需要VIP',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).disabledColor,
              ),
            ),
      onTap: enabled
          ? () async {
              Navigator.pop(context);
              final displayName = song.displayName ?? song.title;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('开始下载: $displayName'),
                  duration: const Duration(seconds: 2),
                ),
              );
              final actual = await provider.downloadSong(
                song,
                quality: quality,
              );
              if (actual == 'trial_blocked') {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('你的账号已被kugou风控,请等待kugou解除风控后再试'),
                      duration: Duration(seconds: 4),
                    ),
                  );
                }
              } else if (actual != null &&
                  actual != quality &&
                  context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${KugouQuality.labelOf(quality)}不可用，已降级为${KugouQuality.labelOf(actual)}',
                    ),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            }
          : null,
    );
  }

  void _showMoreMenu(BuildContext rootContext) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;

    // 动态标题：显示专辑名/歌手名（截断处理）
    final albumTitle = song.album.isEmpty ? '查看专辑' : '查看专辑：${song.album}';
    final artistTitle = song.artist.isEmpty ? '查看歌手' : '查看歌手：${song.artist}';

    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      builder: (sheetContext) {
        // 歌词类型标签：KRC / LRC 逐字 / LRC 行级 / 静态 / 未加载
        // LRC 内部细分：任意一行含字级时间戳即视为"逐字"，否则为"行级"
        final hasWordTiming = _parsedLyrics.any((line) => line.hasWordTiming);
        final lyricTypeLabel = switch (_lyricFormat) {
          LyricFormat.krc => 'KRC 逐字歌词',
          LyricFormat.lrc => hasWordTiming ? 'LRC 逐字歌词' : 'LRC 行级歌词',
          LyricFormat.plaintext => '静态歌词',
          null => _isLoadingLyrics ? '歌词加载中' : '未加载',
        };
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 歌词类型展示（只读，trailing 显示类型，点击无操作）
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('歌词类型'),
                  trailing: Text(
                    lyricTypeLabel,
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(
                          color: Theme.of(sheetContext).colorScheme.primary,
                        ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lyrics),
                  title: const Text('歌词显示设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showLyricPreferencesSheet(rootContext);
                  },
                ),
                ListenableBuilder(
                  listenable: context.read<CommentDisplayProvider>(),
                  builder: (context, _) {
                    final display = context.read<CommentDisplayProvider>();
                    return ListTile(
                      leading: const Icon(Icons.comment_outlined),
                      title: const Text('评论显示设置'),
                      subtitle: Text(
                        '楼主 ${display.commentFontSize.toStringAsFixed(0)} 号 · 楼中楼 ${display.commentReplyFontSize.toStringAsFixed(0)} 号',
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _showCommentDisplaySheet(rootContext);
                      },
                    );
                  },
                ),
                ListenableBuilder(
                  listenable: EqualizerService.instance,
                  builder: (context, _) {
                    final eq = EqualizerService.instance;
                    return ListTile(
                      leading: Icon(
                        Icons.graphic_eq,
                        color: eq.enabled
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: const Text('均衡器'),
                      subtitle: Text(
                        eq.enabled ? '已开启 · ${eq.currentPreset}' : '未开启',
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        Navigator.push(
                          rootContext,
                          MaterialPageRoute(
                            builder: (_) => const EqualizerSettingsPage(),
                          ),
                        );
                      },
                    );
                  },
                ),
                ListenableBuilder(
                  listenable: context.read<PlayerProvider>(),
                  builder: (context, _) {
                    final player = context.read<PlayerProvider>();
                    final remaining = player.sleepTimerRemaining;
                    return ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('定时关闭'),
                      subtitle: Text(
                        remaining == null
                            ? '未设置'
                            : '还剩 ${_formatSleepTime(remaining)}',
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _showSleepTimerSheet(rootContext, player);
                      },
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cast),
                  title: const Text('投屏'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showDlnaCastSheet(rootContext);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.album),
                  title: Text(
                    albumTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _navigateToAlbum(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(
                    artistTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _navigateToArtist(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('添加到歌单'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showAddToPlaylistDialog(rootContext, song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('分享'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    // TODO: 实现分享功能
                    ScaffoldMessenger.of(
                      rootContext,
                    ).showSnackBar(const SnackBar(content: Text('分享功能开发中')));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 评论显示设置：调节楼主 / 楼中楼字体大小。
  /// 与 MD 风格面板保持一致：全部使用主题标准色（onSurface / onSurfaceVariant /
  /// primary），由主题自动适配深色/浅色模式，不再硬编码白色文字。
  void _showCommentDisplaySheet(BuildContext rootContext) {
    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Consumer<CommentDisplayProvider>(
            builder: (context, display, _) {
              final colorScheme = Theme.of(context).colorScheme;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.outline.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      '评论显示设置',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '楼中楼回复字号 = 楼主 − 3',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text(
                          '楼主',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${display.commentFontSize.toStringAsFixed(0)} 号',
                          style: TextStyle(
                            fontSize: display.commentFontSize,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: display.commentFontSize,
                      min: 10.0,
                      max: 24.0,
                      divisions: 14,
                      label: display.commentFontSize.toStringAsFixed(0),
                      onChanged: (v) => display.setCommentFontSize(v),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundColor: colorScheme.primary.withValues(
                                  alpha: 0.15,
                                ),
                                child: const Icon(
                                  Icons.person,
                                  size: 14,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '楼主',
                                      style: TextStyle(
                                        fontSize: display.commentFontSize - 2,
                                        color: colorScheme.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '这是一条楼主评论的内容示例。',
                                      style: TextStyle(
                                        fontSize: display.commentFontSize,
                                        height: 1.3,
                                        color: colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 10,
                                  backgroundColor: colorScheme.primary
                                      .withValues(alpha: 0.15),
                                  child: const Icon(
                                    Icons.person,
                                    size: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '楼中楼',
                                        style: TextStyle(
                                          fontSize:
                                              display.commentReplyFontSize - 2,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        '这是一条楼中楼回复示例。',
                                        style: TextStyle(
                                          fontSize:
                                              display.commentReplyFontSize,
                                          height: 1.3,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => display.resetToDefault(),
                          child: const Text('恢复默认'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// AM v2 睡眠定时药丸 — 复用 _buildQualityPill 样式（白色 15% 背景）。
  Widget _buildSleepTimerPill(PlayerProvider playerProvider) {
    final textTheme = Theme.of(context).textTheme;
    final remaining = playerProvider.sleepTimerRemaining ?? Duration.zero;
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: () => _showSleepTimerSheet(context, playerProvider),
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timer_outlined, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                _formatSleepTime(remaining),
                style: textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// AM v2 定时关闭选择面板。
  void _showSleepTimerSheet(BuildContext rootContext, PlayerProvider player) {
    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '定时关闭',
                  style: Theme.of(rootContext).textTheme.titleMedium,
                ),
              ),
              ..._sleepTimerPresets.map((d) {
                final r = player.sleepTimerRemaining;
                final active =
                    r != null && (r.inSeconds - d.inSeconds).abs() < 2;
                return ListTile(
                  leading: Icon(
                    active
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text('${d.inMinutes} 分钟'),
                  onTap: () {
                    player.setSleepTimer(d);
                    Navigator.pop(sheetCtx);
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      SnackBar(
                        content: Text('将在 ${d.inMinutes} 分钟后自动暂停'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                );
              }),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('自定义…'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _showCustomSleepTimerDialog(rootContext, player);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: const Text('关闭定时'),
                onTap: () {
                  player.setSleepTimer(null);
                  Navigator.pop(sheetCtx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// AM v2 自定义分钟数对话框。
  void _showCustomSleepTimerDialog(
    BuildContext rootContext,
    PlayerProvider player,
  ) {
    final controller = TextEditingController();
    showDialog(
      context: rootContext,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_outlined, size: 32),
                const SizedBox(height: 8),
                const Text('自定义定时关闭', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '分钟',
                    hintText: '1-240',
                    border: OutlineInputBorder(),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        controller.dispose();
                        Navigator.pop(dialogCtx);
                      },
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final n = int.tryParse(controller.text);
                        controller.dispose();
                        if (n == null || n < 1 || n > 240) {
                          ScaffoldMessenger.of(rootContext).showSnackBar(
                            const SnackBar(
                              content: Text('请输入 1-240 之间的整数'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          return;
                        }
                        final d = Duration(minutes: n);
                        player.setSleepTimer(d);
                        Navigator.pop(dialogCtx);
                        ScaffoldMessenger.of(rootContext).showSnackBar(
                          SnackBar(
                            content: Text('将在 $n 分钟后自动暂停'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// AM v2 睡眠定时剩余时间格式：>=1h 显示 `XhYYm`，否则 `mm:ss`。
  String _formatSleepTime(Duration d) {
    if (d.inHours >= 1) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60);
      return '${h}h${m.toString().padLeft(2, '0')}m';
    }
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 弹出 DLNA 投屏二级菜单（设备选择 + 传输控制）。
  void _showDlnaCastSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => const DlnaCastSheet(),
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
                    // AM 风格：白色 loading，与深色对话框背景协调
                    MD3ELoadingIndicator(size: 32, color: Colors.white),
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

}

/// Zen 模式淡出/折叠组件。
///
/// 当 [_zenAnimation] 为 0（正常模式）时完全显示子组件；
/// 为 1（Zen 模式）时淡出并折叠高度为 0，释放垂直空间给歌词/封面视图。
class _ZenFade extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;

  const _ZenFade({required this.animation, required this.child});

  @override
  State<_ZenFade> createState() => _ZenFadeState();
}

class _ZenFadeState extends State<_ZenFade> {
  late final Animation<double> _reverse;

  @override
  void initState() {
    super.initState();
    _reverse = Tween<double>(begin: 1.0, end: 0.0).animate(widget.animation);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _reverse,
      builder: (context, _) {
        return SizeTransition(
          sizeFactor: _reverse,
          alignment: Alignment.topCenter,
          child: Opacity(
            opacity: _reverse.value.clamp(0.0, 1.0),
            child: widget.child,
          ),
        );
      },
    );
  }
}
