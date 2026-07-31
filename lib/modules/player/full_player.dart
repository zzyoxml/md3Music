import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/utils/audio_scanner.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import 'artist_photo_background.dart';
import 'mv_player_page.dart';
import '../../providers/device_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/md3_lyric_preferences_panel.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/md3e_transport_row.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/player_playlist_dialog.dart';
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

class FullPlayer extends StatefulWidget {
  const FullPlayer({super.key});

  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  String _lyrics = '';
  bool _isLoadingLyrics = false;
  String? _lastSongId;

  // 封面淡入淡出动画
  late final AnimationController _artworkFadeController;

  // 桌面歌词状态监听：长按歌词按钮 toggle 后同步 icon
  late final VoidCallback _onDesktopLyricChanged;
  late final Animation<double> _artworkFadeAnimation;
  String? _previousArtworkUrl;

  // Pad 模式：左侧已有封面，隐藏"封面"Tab，只保留 2 个 Tab
  bool _isPadMode = false;
  int _currentTabLength = 3;
  // 手机横屏模式：保留封面Tab，但隐藏左侧歌曲信息
  bool _isPhoneLandscape = false;
  // 拖动进度条前的播放状态，用于拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  /// 上次的物理尺寸，用于 didChangeMetrics 方向变化防抖。
  /// 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
  /// 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁。
  Size? _lastPhysicalSize;

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
  /// 跳转前先 dismiss FullPlayer，让 MiniPlayer 恢复显示。
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
      // 等待 FullPlayer 淡出动画完成（约 250ms）后再 push 专辑页
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
    // 显示 loading
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: MD3ELoadingIndicator()),
    );
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      if (result == null || result.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('未找到歌手「$name」')),
        );
        return;
      }
      final artist = result.first;
      _pushArtistPage(artist.id, artist.name);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('搜索歌手失败：$e')),
      );
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
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
    final newTabLength = shouldBePadMode ? 2 : 3;

    if (_currentTabLength != newTabLength) {
      final currentIndex = _tabController.index.clamp(0, newTabLength - 1);
      _tabController.dispose();
      _currentTabLength = newTabLength;
      // Pad 模式首次进入时（从 3 tab 切到 2 tab）默认打开歌词。
      // 注意：children 列表在 pad 模式被 `if (!_isPadMode)` 跳过 SongInfo，
      // 所以 children 实际只有 2 个：index 0 = LyricsView, index 1 = CommentsView。
      // 因此歌词在 pad 模式下的 index 是 0，不是 1。
      // 后续用户手动切换 tab 后不强制重置，保留用户当前选择。
      final isFirstEnterPad = shouldBePadMode && newTabLength == 2;
      _tabController = TabController(
        length: newTabLength,
        vsync: this,
        initialIndex:
            isFirstEnterPad ? 0 : currentIndex,
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
      applyImmersiveForOrientation();
    });
  }

  void _onPlayerSongChanged() {
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song != null && song.id != _lastSongId) {
      // 封面淡入淡出：song 已经是新歌，_previousArtworkUrl 是上一首的封面
      if (_previousArtworkUrl != null && _previousArtworkUrl != song.artworkUri) {
        final newUrl = song.artworkUri;
        _artworkFadeController
          ..reset()
          ..forward().then((_) {
            // 动画结束后才更新，确保淡出期间旧封面引用不丢失
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
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
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
      _lyrics = '';
    });

    try {
      String lyricText = '';

      // 本地歌曲优先读取内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）
      if (song is Song && !song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
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
          lyricText = lyric?.displayKrcLyric ??
              lyric?.displayLrcLyric ??
              lyric?.displayLyric ??
              '';
        }
      }

      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyrics = lyricText;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyrics = '';
        });
      }
    }
  }

  /// 封面淡入淡出：旧封面淡出 + 新封面淡入，400ms easeInOut。
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
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    iconColor: colorScheme.onSurfaceVariant,
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
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  iconColor: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _artworkPlaceholder(ColorScheme colorScheme, double iconSize) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.music_note, size: iconSize, color: colorScheme.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final usePhotoBg = themeProvider.useArtistPhotoBackground;
    final lyricDoubleTap = themeProvider.lyricDoubleTapToJump;
    final currentSong = playerProvider.currentSong;
    final colorScheme = Theme.of(context).colorScheme;

    // 初始化封面 URL（首次进入或 null→有值）
    if (_previousArtworkUrl == null && currentSong?.artworkUri != null) {
      _previousArtworkUrl = currentSong!.artworkUri;
    }

    if (currentSong == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('暂无播放')),
      );
    }

    // 拦截系统返回键：先播放 reverse 动画（mini player 淡入），
    // 动画完成后用 removeRoute 移除路由（绕过 PopScope 避免死循环）。
    // 引用 kPlayerOverlayStyle 与 applyImmersiveForOrientation 共用同一 const 实例
    // 避免 SystemUiOverlayStyle 引用不等触发平台 channel 真实调用导致闪烁
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: kPlayerOverlayStyle,
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isDismissing) return;
        _collapseByButton();
      },
      child: Scaffold(
      backgroundColor: colorScheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 歌手写真背景轮播（开关开启 + 在线歌曲时显示）
          if (usePhotoBg && currentSong!.isOnline)
            ArtistPhotoBackground(hash: currentSong.id),
          ResponsiveLayout(
            compact: (_) =>
                _buildCompactLayout(playerProvider, currentSong, colorScheme, lyricDoubleTap),
            medium: (_) =>
                _buildLandscapeLayout(playerProvider, currentSong, colorScheme, lyricDoubleTap),
            expanded: (_) =>
                _buildExpandedLayout(playerProvider, currentSong, colorScheme, lyricDoubleTap),
          ),
        ],
      ),
    ),
    ),
    ); // AnnotatedRegion
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
          _buildTopBar(playerProvider),
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
                      ? const Center(child: MD3ELoadingIndicator())
                      : LyricsView(
                          lyrics: _lyrics,
                          position: playerProvider.position,
                          doubleTapToJump: lyricDoubleTap,
                          onSeek: (duration) {
                            playerProvider.seek(duration);
                          },
                        ),
                ),
                CommentsView(
                  songHash: currentSong.id,
                  albumAudioId: currentSong.albumAudioId,
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

  /// 手机横屏 / Pad 竖屏布局：左侧封面，右侧信息+歌词/评论+控制栏。
  /// 顶部栏放在最外层 Column，使返回按钮真正位于屏幕最左上角。
  Widget _buildLandscapeLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;
    // 横屏 + 写真背景开启时，写真已铺满全屏作为背景，隐藏左侧封面避免视觉重复。
    // 关闭写真背景时恢复显示封面。
    final usePhotoBg = context.watch<ThemeProvider>().useArtistPhotoBackground;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final hideArtworkForPhotoBg =
        isLandscape && usePhotoBg && currentSong.isOnline;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
          _buildTopBar(playerProvider),
          Expanded(
            child: Row(
              children: [
                // ── 左侧：封面 + 歌曲信息 ──
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 横屏时封面为正方形，需同时受可用宽度与高度约束：
                        // 减去 56 顶栏补偿后的可用高度，避免高度不足时正方形上下被裁切
                        final availableHeight = constraints.maxHeight - 56;
                        final size = (constraints.maxWidth < availableHeight
                                ? constraints.maxWidth
                                : availableHeight)
                            .clamp(120.0, 300.0);
                        return Stack(
                          children: [
                            // 封面：横屏 + 写真背景开启时隐藏（避免与背景写真重复）
                            if (!hideArtworkForPhotoBg)
                              // 封面居中：补偿顶栏高度（IconButton 48 + Padding 4×2 = 56），
                              // 使封面在整个屏幕垂直方向居中，而非画布（去除顶栏后的空间）居中
                              Padding(
                                padding: const EdgeInsets.only(bottom: 56),
                                child: Center(
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
                                          fallbackFilePath: currentSong.localPath,
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
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleMedium,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.album,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                        ),
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
                                child: _buildSongInfo(playerProvider, currentSong, colorScheme),
                              ),
                            _isLoadingLyrics
                                ? const Center(child: MD3ELoadingIndicator())
                                : LyricsView(
                                    lyrics: _lyrics,
                                    position: playerProvider.position,
                                    doubleTapToJump: lyricDoubleTap,
                                    onSeek: (duration) {
                                      playerProvider.seek(duration);
                                    },
                                  ),
                            CommentsView(
                              songHash: currentSong.id,
                              albumAudioId: currentSong.albumAudioId,
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
    // 横屏 + 写真背景开启时，写真已铺满全屏作为背景，隐藏左侧封面避免视觉重复。
    // 关闭写真背景时恢复显示封面。
    final usePhotoBg = context.watch<ThemeProvider>().useArtistPhotoBackground;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final hideArtworkForPhotoBg =
        isLandscape && usePhotoBg && currentSong.isOnline;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
          _buildTopBar(playerProvider),
          Expanded(
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
                            // 封面：横屏 + 写真背景开启时隐藏（避免与背景写真重复）
                            if (!hideArtworkForPhotoBg)
                              // 封面居中：补偿顶栏高度，使封面在整个屏幕垂直方向居中
                              Padding(
                                padding: const EdgeInsets.only(bottom: 56),
                                child: Center(
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
                                            fallbackFilePath: currentSong.localPath,
                                          ),
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
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleMedium,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => _navigateToAlbum(currentSong as Song),
                                      child: Text(
                                        currentSong.album,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                        ),
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
                            if (!_isPadMode || _isPhoneLandscape)
                              _buildSongInfo(playerProvider, currentSong, colorScheme),
                            _isLoadingLyrics
                                ? const Center(child: MD3ELoadingIndicator())
                                : LyricsView(
                                    lyrics: _lyrics,
                                    position: playerProvider.position,
                                    doubleTapToJump: lyricDoubleTap,
                                    onSeek: (duration) {
                                      playerProvider.seek(duration);
                                    },
                                  ),
                            CommentsView(
                              songHash: currentSong.id,
                              albumAudioId: currentSong.albumAudioId,
                            ),
                          ],
                        ),
                      ),
                      // 底部 padding 包含导航栏高度
                      Padding(
                        padding: EdgeInsets.only(bottom: bottomPadding),
                        child: _buildControls(playerProvider, colorScheme, isExpanded: true),
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
    // 顶部栏：返回/音质/菜单分列两侧，无把手
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: _collapseByButton,
          ),
          const Spacer(),
          // MD3E v2: 顶部栏右侧 FLAC 质量徽章，点击复用 _showQualityDialog
          _buildQualityPill(playerProvider),
          if (playerProvider.currentSong?.isOnline == true)
            IconButton(
              icon: const Icon(Icons.music_video_outlined),
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
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showMoreMenu(context),
          ),
        ],
      ),
    );
  }

  /// MD3E v2 质量徽章 — primaryContainer 背景 + StadiumBorder + 图标 + 文字。
  /// 本地歌曲：只读显示码率推断的音质，禁用点击切换。
  /// 在线歌曲：点击复用 _showQualityDialog。
  Widget _buildQualityPill(PlayerProvider playerProvider) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    return Material(
      color: colorScheme.primaryContainer,
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
              Icon(
                Icons.music_note,
                size: 14,
                color: colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                // 本地歌曲显示基于码率推断的音质标签
                playerProvider.currentQualityLabel,
                style: textTheme.labelMedium?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCrossfadeArtworkWrapper(
    dynamic currentSong,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: _buildCrossfadeArtwork(
        currentSong.artworkUri,
        colorScheme,
        iconSize: iconSize,
        fallbackFilePath: currentSong.localPath,
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
                return ConstrainedBox(
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
                      child: _buildCrossfadeArtworkWrapper(
                        currentSong, colorScheme, iconSize: iconSize,
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
                child: AnimatedScale(
                  scale: playerProvider.isPlaying ? 1.0 : 0.85,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutBack,
                  child: _buildCrossfadeArtworkWrapper(
                    currentSong, colorScheme, iconSize: iconSize,
                  ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          InkWell(
            onTap: () => _navigateToAlbum(currentSong as Song),
            borderRadius: BorderRadius.circular(4),
            child: Text(
              currentSong.displayName.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // MD3E v2: 大写 + 粗体 w700 + 字间距 1.5 + 标题更大
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                height: 1.2,
              ),
              textAlign: TextAlign.left,
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500, // MD3E v2: 提升字重
              ),
              textAlign: TextAlign.left,
            ),
          ),
          const SizedBox(height: 2),
          InkWell(
            onTap: () => _navigateToAlbum(currentSong as Song),
            borderRadius: BorderRadius.circular(4),
            child: Text(
              currentSong.album.toUpperCase(), // MD3E v2: 专辑名大写
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                letterSpacing: 0.8, // MD3E v2: 大写配字间距
              ),
              textAlign: TextAlign.left,
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
                currentSong.displayName.toUpperCase(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // MD3E v2: 大写 + 粗体 w700 + 字间距 1.5
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
                textAlign: TextAlign.left,
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500, // MD3E v2: 提升字重
                ),
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(height: 2),
            InkWell(
              onTap: () => _navigateToAlbum(currentSong as Song),
              borderRadius: BorderRadius.circular(4),
              child: Text(
                currentSong.album.toUpperCase(), // MD3E v2: 专辑名大写
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  letterSpacing: 0.8, // MD3E v2: 大写配字间距
                ),
                textAlign: TextAlign.left,
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
          _buildActionBar(
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
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: hasClimax
              ? _buildSliderWithClimaxMarker(
                  playerProvider, position, duration, colorScheme, song!)
              : Slider(
                  value: duration.inMilliseconds > 0
                      ? (position.inMilliseconds / duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : 0.0,
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
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  /// 构建带有高潮点标记的进度条 Slider。
  ///
  /// 在 Slider 上方叠加一个小三角标记，指示高潮部分的起始位置。
  Widget _buildSliderWithClimaxMarker(
    PlayerProvider playerProvider,
    Duration position,
    Duration duration,
    ColorScheme colorScheme,
    Song song,
  ) {
    final climaxStart = song.climaxStart!;
    final climaxEnd = song.climaxEnd!;
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return const SizedBox.shrink();

    // 高潮起止在进度条上的归一化位置 (0~1)
    final climaxStartPos = (climaxStart * 1000 / totalMs).clamp(0.0, 1.0);
    final climaxEndPos = (climaxEnd * 1000 / totalMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Slider 的有效轨道宽度约为约束宽度减去左右 thumb 半径（各 10px）
        final trackWidth = constraints.maxWidth;
        final thumbRadius = 10.0;
        final usableWidth = trackWidth - thumbRadius * 2;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Slider 本体
            Slider(
              value: totalMs > 0
                  ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
                  : 0.0,
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
                      color: colorScheme.primary.withValues(alpha: 0.5),
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
    final spacing = isExpanded ? 4.0 : 8.0;
    final sideButtonSize = isExpanded ? 48.0 : 56.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // shuffle — 保留原 IconButton，不参与动画
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
        // Phase 5: 上一曲/暂停/下一曲联合动画控件（替代中间 3 个 IconButton）
        MD3ETransportRow(
          isPlaying: playerProvider.isPlaying,
          sideButtonSize: sideButtonSize,
          playButtonSize: isExpanded ? 64.0 : 72.0,
          spacing: spacing,
          onPrevious: () => playerProvider.previous(),
          onPlayPause: () {
            if (playerProvider.isPlaying) {
              playerProvider.pause();
            } else {
              playerProvider.resume();
            }
          },
          onNext: () => playerProvider.next(),
        ),
        SizedBox(width: spacing),
        // loop — 保留原 IconButton，不参与动画
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

  /// MD3E v2 底部操作条 — 6 个常用动作收纳在单条长 pill 内。
  ///
  /// 替代原 `_buildSecondaryControls` 的 9 个独立按钮。
  /// 不在 ActionBar 中的动作（下载/音量/音质/歌单）通过 more_vert 菜单访问。
  Widget _buildActionBar(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final song = playerProvider.currentSong;
    // 根据歌曲来源（本地/在线）选择对应的收藏 Provider
    final isOnline = song is Song && song.isOnline;
    final isFavorited = song != null &&
        (isOnline
            ? context.watch<FavoritesProvider>().isFavorite(song.id)
            : context.watch<LocalFavoritesProvider>().isFavorite(song.id));
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.primaryContainer,
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
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            // 2. 播放列表 — 弹出播放队列
            Expanded(
              child: InkWell(
                onTap: () => _showPlaylist(playerProvider),
                child: Center(
                  child: Icon(
                    Icons.queue_music,
                    size: 22,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            // 3. 封面 — 短按跳转到封面 tab，长按弹出下载音质选择（本地歌曲屏蔽长按下载）
            Expanded(
              child: InkWell(
                onTap: () {
                  if (_tabController.index != 0) {
                    _tabController.animateTo(0);
                  }
                },
                onLongPress: song != null && isOnline
                    ? () => _downloadSong(song)
                    : null,
                child: Center(
                  child: Icon(
                    Icons.album,
                    size: 22,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            // 4. 歌词 — 短按跳转到歌词 tab，长按开关桌面歌词
            Expanded(
              child: InkWell(
                onTap: () {
                  if (_tabController.index != 1) {
                    _tabController.animateTo(1);
                  }
                },
                onLongPress: () async {
                  await DesktopLyricService.instance.toggle();
                  if (mounted) {
                    // 同步通知栏"桌面歌词"按钮状态
                    final player = context.read<PlayerProvider>();
                    final song = player.currentSong;
                    // 收藏状态需实时查询，避免暂停时显示为未收藏
                    bool isFavorited = false;
                    if (song != null) {
                      try {
                        isFavorited = context
                            .read<FavoritesProvider>()
                            .isFavorite(song.id);
                      } catch (_) {}
                    }
                    await MediaNotificationService.updateNotification(
                      // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
                      title: song?.displayName ?? '',
                      artist: song?.artist ?? '',
                      artUrl: song?.artworkUri,
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
                    // 桌面歌词开启时用实心 icon + primary 色，与 mini_player 一致
                    DesktopLyricService.instance.enabled
                        ? Icons.lyrics
                        : Icons.lyrics_outlined,
                    size: 22,
                    color: DesktopLyricService.instance.enabled
                        ? colorScheme.primary
                        : colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            // 5. 评论 — 跳转到评论 tab
            Expanded(
              child: InkWell(
                onTap: () {
                  if (_tabController.index != 2) {
                    _tabController.animateTo(2);
                  }
                },
                child: Center(
                  child: Icon(
                    Icons.comment_outlined,
                    size: 22,
                    color: colorScheme.onPrimaryContainer,
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
                          context.read<FavoritesProvider>().toggleFavorite(song);
                        } else {
                          context.read<LocalFavoritesProvider>().toggleFavorite(song.id);
                        }
                      }
                    : null,
                child: Center(
                  child: Icon(
                    isFavorited ? Icons.favorite : Icons.favorite_border,
                    size: 22,
                    color: isFavorited
                        ? colorScheme.error
                        : colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // MD3E v2: 音量调节改为右上角长按音质徽章呼出。
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
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: isSelected ? FontWeight.bold : null,
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

  // MD3E v2: 下方 ActionBar 第 3 个按钮（封面）长按触发。
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
            _buildDownloadQualityOption(ctx, '标准音质 (128kbps)', '128', song, downloadsProvider, enabled: available.contains('128')),
            _buildDownloadQualityOption(ctx, '高音质 (320kbps)', '320', song, downloadsProvider, enabled: available.contains('320')),
            _buildDownloadQualityOption(ctx, '无损音质 (FLAC)', 'flac', song, downloadsProvider, enabled: available.contains('flac')),
            _buildDownloadQualityOption(ctx, 'Hi-Res 无损', 'high', song, downloadsProvider, enabled: available.contains('high')),
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
          : Text('需要VIP', style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).disabledColor,
            )),
      onTap: enabled ? () async {
        Navigator.pop(context);
        final displayName = song.displayName ?? song.title;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('开始下载: $displayName'),
            duration: const Duration(seconds: 2),
          ),
        );
        final actual = await provider.downloadSong(song, quality: quality);
        if (actual != null && actual != quality && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${KugouQuality.labelOf(quality)}不可用，已降级为${KugouQuality.labelOf(actual)}'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } : null,
    );
  }

  void _showMoreMenu(BuildContext context) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;

    // 动态标题：显示专辑名/歌手名（截断处理）
    final albumTitle = song.album.isEmpty ? '查看专辑' : '查看专辑：${song.album}';
    final artistTitle = song.artist.isEmpty ? '查看歌手' : '查看歌手：${song.artist}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.lyrics),
                  title: const Text('歌词显示设置'),
                  onTap: () {
                    Navigator.pop(context);
                    _showLyricPreferencesSheet(context);
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
                    Navigator.pop(context);
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
                    Navigator.pop(context);
                    _navigateToArtist(song);
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
                SwitchListTile(
                  title: const Text('歌手写真背景'),
                  value: context.read<ThemeProvider>().useArtistPhotoBackground,
                  onChanged: (v) {
                    context.read<ThemeProvider>().setUseArtistPhotoBackground(v);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 弹出 MD3 风格播放页的歌词显示设置面板（字号/行间距/字体）。
  /// 与 Apple Music 风格的 `LyricPreferences` 完全独立。
  void _showLyricPreferencesSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(child: const Md3LyricPreferencesPanel()),
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
                    MD3ELoadingIndicator(size: 32),
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

  // MD3E v2: 原 _buildSecondaryControls 已替换为 _buildActionBar，
  // 此方法现在由 ActionBar 第2位"播放列表"按钮调用。
  void _showPlaylist(PlayerProvider playerProvider) {
    showDialog(
      context: context,
      // 透明 barrier：横屏时点击左半边不关闭对话框（仍可操作播放器）
      barrierColor: Colors.transparent,
      builder: (dialogContext) => const PlayerPlaylistDialog(
        useDisplayName: true,
      ),
    );
  }
}
