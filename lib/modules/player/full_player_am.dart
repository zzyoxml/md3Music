import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/services/usb_audio_service.dart';
import '../../core/utils/audio_scanner.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/artwork_color_extractor.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../coverflow/coverflow_page.dart';
import '../settings/equalizer_settings_page.dart';
import 'mv_player_page.dart';
import 'song_info_page.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/comment_display_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/flowing_background.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/ai_recommend_sheet.dart';
import '../../widgets/menu_action_cell.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/spectrum_artwork.dart';
import '../../widgets/spectrum_background.dart';
import '../../utils/landscape_immersive.dart';
import '../../utils/playlist_order_utils.dart';
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
  /// 可选扩展：封面长按回调（默认关闭，由私有构建注入，用于下载等旁路操作）。
  static void Function(BuildContext context, dynamic song)?
  coverLongPressCallback;

  const AmStyleFullPlayer({super.key});

  @override
  State<AmStyleFullPlayer> createState() => _AmStyleFullPlayerState();
}

class _AmStyleFullPlayerState extends State<AmStyleFullPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  // 高亮球拖动切换：拖动时上方页面跟随、球放大，松手吸附 & 回缩
  bool _tabDragActive = false;
  double _tabDragBtnW = 0;
  double _tabDragDx = 0;
  int _dragStartIndex = 0;
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

  // 动态字体颜色：从专辑封面提取的主色（歌词当前行「70% 白 + 30% 提取色」混色用）
  Color? _lyricAccentColor;
  String? _lastAccentUrl;

  // Pad 模式：左侧已有封面，隐藏"封面"Tab，只保留 2 个 Tab
  bool _isPadMode = false;
  int _currentTabLength = 4;
  // 手机横屏模式：保留封面Tab，但隐藏左侧歌曲信息
  bool _isPhoneLandscape = false;

  // === 拖拽收起手势：已移除（与 MD 风格统一：无把手单行布局，关闭通过返回按钮） ===
  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  /// 拖拽展开模式下的源路由：展开完成前延迟应用沉浸模式，
  /// 避免拖动过程系统栏提前切换造成闪烁。
  DraggablePlayerRoute? _dragRoute;

  /// 系统栏/沉浸模式初始化是否已完成。
  /// 需在 [didChangeDependencies] 中执行一次（[ModalRoute.of] 依赖
  /// `_ModalScopeStatus` inherited widget，initState 阶段不可用）。
  bool _systemUiInitialized = false;

  /// 是否为拖拽覆盖层（非路由）场景：拖拽期间由 Navigator 之上的
  /// PlayerDragOverlay 渲染，无 ModalRoute；系统栏与收起行为需走覆盖层逻辑。
  bool get _isDragOverlay =>
      ModalRoute.of(context) == null && playerDragActive.value;

  /// 是否已修改过系统栏（沉浸模式）。
  /// 覆盖层（非路由）场景从未修改，dispose 时无需恢复系统栏。
  bool _systemUiModified = false;

  // ── 顶栏向下拖拽收起状态（与上滑展开镜像） ──
  DraggablePlayerRoute? _topBarDragRoute; // 正在拖拽的路由
  double _topBarDragDistance = 0.0; // 向下累计距离（px，≥0）
  double _topBarDragTotal = 0.0; // 完整收起距离（px）
  double? _topBarDragLastY; // 上次 Y（速度估计用）
  Duration? _topBarDragLastTime;
  double _topBarDragVelocity = 0.0; // 向下速度 px/s

  /// 上次的物理尺寸，用于 didChangeMetrics 方向变化防抖。
  /// 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
  /// 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁。
  Size? _lastPhysicalSize;

  // ── Zen Mode：长按专辑封面进入/退出沉浸模式 ──
  bool _zenMode = false;
  late final AnimationController _zenController;
  late final Animation<double> _zenAnimation;

  // ── Zen 长按专辑封面（进入 / 退出）──
  /// 长按封面切换 Zen 模式所需时长（进入与退出一致）。
  static const Duration _zenPressDuration = Duration(milliseconds: 2000);

  /// 提示层开始淡入的进度点（≈500ms，与系统长按识别时机对齐）。
  static const double _zenHintStart = 0.25;

  /// 判定为滑动手势（切 tab / 拖拽）而取消长按的指针位移阈值（px）。
  static const double _zenPressSlop = 18.0;

  /// 按压进度 0→1：驱动封面内缩、提示层淡入与进度环；跑满即切换 Zen 模式。
  late final AnimationController _zenPressController;

  /// 提示层淡入时的轻震是否已触发（每次长按只震一次）。
  bool _zenHintHapticFired = false;

  /// 本次按压是否已进入长按引导阶段：松手不再当作点击（否则封面 tab 的
  /// onTap 会把长按当点击、跳到歌词页）。Listener 不参与手势竞技场，
  /// 只能由封面 tab 的 onTap 主动放弃这一次点击。
  bool _zenPressConsumedTap = false;

  /// 按下时的指针全局位置；null 表示当前没有长按在进行。
  Offset? _zenPressOrigin;

  // 进度条拖动状态：记录拖动前是否正在播放，拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  // ── 音乐频谱环绕显示 ──
  bool _spectrumEnabled = false;
  bool _spectrumStarted = false;
  // 频谱样式：0=柱状图(环绕)，1=曲线(环绕)，2=背景层(条形)
  int _spectrumStyle = 0;
  // 频谱背景层参数（仅 style=2 时使用）
  double _spectrumBgOpacity = 0.4;
  double _spectrumBgHeight = 0.4;
  // 环绕频谱透明度（style 0/1 分开记忆，默认不透明）
  double _spectrumBarOpacity = 1.0;
  double _spectrumCurveOpacity = 1.0;
  // 频谱动态取色独立开关（默认开启）：AM 播放器频谱颜色取封面主色 50/50 混合
  bool _spectrumDynamicColor = true;

  /// 频谱颜色：独立开关「频谱动态取色」开启且已提取到封面主色时，
  /// 用 50% 白 + 50% 取色混合（与歌词动态取色相同的兜底：抬升明度避免深色）；
  /// 否则用 AM 风格白色（动态取色仅 AM 播放器生效）。
  Color get _spectrumColor {
    final accent = _lyricAccentColor;
    if (_spectrumDynamicColor && accent != null) {
      final mixed = Color.lerp(Colors.white, accent, 0.5)!;
      final hsl = HSLColor.fromColor(mixed);
      return hsl.withLightness(math.max(hsl.lightness, 0.78)).toColor();
    }
    return Colors.white;
  }

  /// 当前频谱透明度（按样式分开记忆）
  double get _spectrumOpacity =>
      _spectrumStyle == 1 ? _spectrumCurveOpacity : _spectrumBarOpacity;

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
    // 动态字体颜色开关变化（设置页）时补提取封面主色
    LyricPreferences.instance.addListener(_onLyricPrefsChanged);
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
    _zenPressController = AnimationController(
      duration: _zenPressDuration,
      reverseDuration: const Duration(milliseconds: 220),
      vsync: this,
    )..addListener(_onZenPressProgress);
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
      _loadSpectrumSetting();
    });
  }

  /// 从设置加载频谱开关状态
  Future<void> _loadSpectrumSetting() async {
    final enabled = await SettingsRepository().getSpectrumEnabled();
    final bandCount = await SettingsRepository().getSpectrumBandCount();
    final style = await SettingsRepository().getSpectrumStyle();
    final bgOpacity = await SettingsRepository().getSpectrumBgOpacity();
    final bgHeight = await SettingsRepository().getSpectrumBgHeight();
    final barOpacity = await SettingsRepository().getSpectrumBarOpacity();
    final curveOpacity = await SettingsRepository().getSpectrumCurveOpacity();
    final dynamicColor = await SettingsRepository().getSpectrumDynamicColor();
    if (!mounted) return;
    SpectrumService.instance.bandCount = bandCount;
    setState(() {
      _spectrumEnabled = enabled;
      _spectrumStyle = style;
      _spectrumBgOpacity = bgOpacity;
      _spectrumBgHeight = bgHeight;
      _spectrumBarOpacity = barOpacity;
      _spectrumCurveOpacity = curveOpacity;
      _spectrumDynamicColor = dynamicColor;
    });
    if (enabled) {
      SpectrumService.instance.simulatedNotifier.addListener(
        _onSpectrumSimulated,
      );
      if (_isDragOverlay) {
        // 拖拽覆盖层（非路由）：只显示频谱 UI、不启动服务。
        // 覆盖层销毁时会 dispose 并调用 _stopSpectrum（全局 stop），
        // 若此处启动会与接管路由的频谱冲突，导致频谱卡住/失效
        return;
      }
      if (Platform.isAndroid) {
        await Permission.microphone.request();
      }
      final isPlaying = context.read<PlayerProvider>().isPlaying;
      await _tryStartSpectrum(isPlaying: isPlaying);
    }
    // 频谱动态取色开启时补提取当前歌曲封面主色（歌词开关可能未开）
    if (dynamicColor && _lyricAccentColor == null && mounted) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) _updateLyricAccent(song.artworkUri);
    }
  }

  Future<void> _tryStartSpectrum({bool isPlaying = false}) async {
    if (!Platform.isAndroid) return;
    if (_spectrumStarted) return;
    // 未在播放时不启动（PCM 截取在 AudioSink 层，播放才会产生数据）
    if (!isPlaying) return;
    final sessionId = AudioService().androidAudioSessionId ?? 0;
    final ok = await SpectrumService.instance.start(sessionId);
    if (ok) {
      _spectrumStarted = true;
    }
  }

  Future<void> _stopSpectrum() async {
    if (!_spectrumStarted) return;
    _spectrumStarted = false;
    await SpectrumService.instance.stop();
  }

  Future<void> _toggleSpectrum() async {
    HapticFeedback.lightImpact();
    final newEnabled = !_spectrumEnabled;
    setState(() => _spectrumEnabled = newEnabled);
    await SettingsRepository().setSpectrumEnabled(newEnabled);
    if (newEnabled) {
      if (Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (!status.isGranted && mounted) {
          showToast('未授予录音权限，将使用模拟频谱模式', long: true);
        }
      }
      final isPlaying = context.read<PlayerProvider>().isPlaying;
      await _tryStartSpectrum(isPlaying: isPlaying);
      SpectrumService.instance.simulatedNotifier.addListener(
        _onSpectrumSimulated,
      );
    } else {
      SpectrumService.instance.simulatedNotifier.removeListener(
        _onSpectrumSimulated,
      );
      await _stopSpectrum();
    }
  }

  void _onSpectrumSimulated() {
    if (!mounted) return;
    if (SpectrumService.instance.simulatedNotifier.value) {
      showToast('设备不支持实时频谱，已切换到模拟模式', long: true);
      setState(() {});
    }
  }

  /// 检测是否为 Pad 模式（宽度 >= 600），并动态调整 TabController
  void _checkPadMode() {
    if (!mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    final deviceIsPad = isPadLayout(context);
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
    // 系统栏/沉浸模式初始化：只在首次依赖建立时执行一次。
    // ModalRoute.of 依赖 _ModalScopeStatus（inherited widget），
    // 不能在 initState 中调用，否则报 dependOnInheritedWidgetOfExactType 错误
    if (_systemUiInitialized) return;
    _systemUiInitialized = true;
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute && route.isDragMode) {
      // 拖拽路由：延迟到展开完成后再切换沉浸，避免拖动过程系统栏提前闪烁
      _dragRoute = route;
      route.controller.addStatusListener(_onDragRouteStatus);
    } else if (route == null) {
      // 拖拽覆盖层（非路由）：不切换系统栏，展开后由路由接管
      _dragRoute = null;
      _systemUiModified = false;
    } else {
      // 点击打开 / 普通路由：立即应用沉浸模式
      _dragRoute = null;
      applyImmersiveForOrientation();
      _systemUiModified = true;
    }
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
    // 频谱启停
    if (_spectrumEnabled && player.isPlaying && !_spectrumStarted) {
      _tryStartSpectrum(isPlaying: true);
    }
    SpectrumService.instance.setPlaying(player.isPlaying);
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
    // 未完成展开就收起时，移除拖拽展开的监听（未切换系统栏，无需恢复）
    _dragRoute?.controller.removeStatusListener(_onDragRouteStatus);
    _zenPressController.dispose();
    try {
      context.read<PlayerProvider>().removeListener(_onPlayerSongChanged);
    } catch (_) {}
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
    LyricPreferences.instance.removeListener(_onLyricPrefsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _artworkFadeController.dispose();
    _zenController.dispose();
    _tabController.dispose();
    // 退出播放器时停止频谱采集
    SpectrumService.instance.simulatedNotifier.removeListener(
      _onSpectrumSimulated,
    );
    _stopSpectrum();
    // 退出播放器时恢复系统栏；若仍处于封面流页横屏沉浸（从封面流进入播放器后返回），
    // 则保持沉浸，避免返回后状态栏闪现。
    // 拖拽覆盖层（非路由）从未修改系统栏，无需恢复
    if (_systemUiModified) {
      if (kCoverFlowImmersiveActive.value) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        restoreSystemUi();
      }
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

  /// 长按专辑封面 [_zenPressDuration] 切换 Zen 模式（未进入则进入，已进入则退出）。
  /// 通过 Listener 的 onPointerDown/Move/Up 直接跟踪指针，
  /// 精确实现 2000ms 长按（不依赖系统 500ms 长按识别延迟），
  /// 同时不与 TabBarView 的水平滑动抢手势。
  void _onArtworkPointerDown(PointerDownEvent event) {
    _zenPressOrigin = event.position;
    _zenHintHapticFired = false;
    // 兜底复位：上一次的 tap 可能被竖直拖拽等手势抢走、没走到 onTap
    _zenPressConsumedTap = false;
    _zenPressController.forward(from: 0.0).then((_) {
      // 中途松手/滑动取消时 TickerFuture 同样会完成，用进度判断是否真的按满
      if (!mounted || _zenPressController.value < 1.0) return;
      _zenPressOrigin = null;
      // 中震：确认长按达到 2000ms，切换 Zen 模式
      HapticFeedback.mediumImpact();
      if (_zenMode) {
        _exitZenMode();
      } else {
        _enterZenMode();
      }
      // 提示层与封面内缩随 Zen 转场一起回弹淡出
      _zenPressController.reverse();
    });
  }

  /// 指针位移超过 [_zenPressSlop]：判定为滑动（切 tab / 拖拽），取消长按。
  void _onArtworkPointerMove(PointerMoveEvent event) {
    final origin = _zenPressOrigin;
    if (origin == null) return;
    if ((event.position - origin).distance > _zenPressSlop) {
      _cancelArtworkPress();
    }
  }

  /// 松手 / 手势取消 / 判定为滑动：回弹按压动效并淡出提示层。
  void _cancelArtworkPress() {
    if (_zenPressOrigin == null) return;
    _zenPressOrigin = null;
    _zenHintHapticFired = false;
    if (_zenPressController.value > 0.0) _zenPressController.reverse();
  }

  /// 按压进度回调：跨过 [_zenHintStart]（提示层开始淡入）时轻震一次，
  /// 并标记这次按压已是长按语义、松手不再触发封面 tab 的点击跳转。
  /// 封面内缩与提示层由 AnimatedBuilder 监听 controller 重建，此处只管震动。
  void _onZenPressProgress() {
    if (_zenHintHapticFired || _zenPressController.value < _zenHintStart) {
      return;
    }
    _zenHintHapticFired = true;
    _zenPressConsumedTap = true;
    HapticFeedback.lightImpact();
  }

  /// 封面 tab 的 onTap 入口：本次按压已被 Zen 长按消费则放弃这次点击。
  bool _consumeZenPressTap() {
    if (!_zenPressConsumedTap) return false;
    _zenPressConsumedTap = false;
    return true;
  }

  /// 封面长按包装：指针监听 + 按压内缩动效 + Zen 长按引导提示层。
  /// [child] 为原封面内容（含播放/暂停缩放动画）。
  Widget _wrapArtworkZenPress({required Widget child}) {
    return Listener(
      onPointerDown: _onArtworkPointerDown,
      onPointerMove: _onArtworkPointerMove,
      onPointerUp: (_) => _cancelArtworkPress(),
      onPointerCancel: (_) => _cancelArtworkPress(),
      child: AnimatedBuilder(
        animation: _zenPressController,
        child: child,
        builder: (context, artwork) {
          final progress = _zenPressController.value;
          // 按压时封面轻微内缩（1.0 → 0.94），松手回弹
          final press = Curves.easeOut.transform(progress);
          return Stack(
            children: [
              Transform.scale(scale: 1.0 - 0.06 * press, child: artwork),
              _buildZenPressHint(progress),
            ],
          );
        },
      ),
    );
  }

  /// Zen 长按引导提示层：覆盖在封面上，半透明黑底 + 进度环 + 图标 + 文案。
  /// [progress] 为按压进度（0→1）：跨过 [_zenHintStart] 后淡入，
  /// 进度环显示距切换还差多少。IgnorePointer 避免拦截指针事件。
  Widget _buildZenPressHint(double progress) {
    final opacity = ((progress - _zenHintStart) / 0.15).clamp(0.0, 1.0);
    if (opacity == 0.0) return const SizedBox.shrink();
    final ring = ((progress - _zenHintStart) / (1.0 - _zenHintStart)).clamp(
      0.0,
      1.0,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: ring,
                          strokeWidth: 3,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                        Icon(
                          _zenMode ? Icons.exit_to_app : Icons.self_improvement,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _zenMode ? '继续长按退出 Zen 模式' : '继续长按进入 Zen 模式',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 切歌时异步提取专辑封面主色，供歌词「动态字体颜色」与频谱动态取色混色使用。
  ///
  /// 复用流光背景的提取思路（PaletteGenerator + 过滤 + 饱和度归一化）。
  /// 提取完成后若已切到别的歌（url 变化）则丢弃结果。
  Future<void> _updateLyricAccent(String? url) async {
    // 仅歌词动态取色或频谱动态取色任一开启时才需要提取（默认关闭，避免每次
    // 进播放器都多一次封面下载 + 解码 + PaletteGenerator 分析的无谓开销）
    if (!LyricPreferences.instance.useDynamicLyricColor &&
        !_spectrumDynamicColor) {
      return;
    }
    if (url == _lastAccentUrl) return;
    _lastAccentUrl = url;
    final color = await ArtworkColorExtractor.extract(url);
    if (!mounted || _lastAccentUrl != url) return;
    setState(() => _lyricAccentColor = color);
  }

  /// LyricPreferences 变化回调：播放器存活期间在设置页打开「歌词动态颜色」
  /// 开关时，立即为当前歌曲补提取封面主色（首次打开时 _fetchLyrics 的提取
  /// 因开关关闭已被跳过）。
  void _onLyricPrefsChanged() {
    if ((LyricPreferences.instance.useDynamicLyricColor ||
            _spectrumDynamicColor) &&
        _lyricAccentColor == null &&
        mounted) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) _updateLyricAccent(song.artworkUri);
    }
  }

  Future<void> _fetchLyrics(dynamic song) async {
    final songId = song.id as String;
    if (songId == _lastSongId) return;
    _lastSongId = songId;

    // 切歌时同步提取封面主色（动态字体颜色用，fire-and-forget）
    _updateLyricAccent(song.artworkUri);

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
          debugPrint(
            '[RomaToggle] 歌词加载: translationText=${translationText == null ? 'null' : (translationText!.isEmpty ? '空串' : 'len=${translationText!.length}')} romaText=${romaText == null ? 'null' : (romaText!.isEmpty ? '空串' : 'len=${romaText!.length}')} → hasTranslation=$_hasTranslation hasRoma=$_hasRoma',
          );
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

  /// 构建横屏布局的封面内容：style 0/1 用 SpectrumArtwork（白色），style 2 用原封面
  Widget _buildLandscapeArtworkContent(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    if (_spectrumEnabled && _spectrumStyle < 2) {
      return SpectrumArtwork(
        artworkUri: currentSong.artworkUri,
        fallbackFilePath: currentSong.localPath,
        isPlaying: playerProvider.isPlaying,
        bandCount: SpectrumService.instance.bandCount,
        style: _spectrumStyle,
        barColor: _spectrumColor,
        opacity: _spectrumOpacity,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Selector<PlayerProvider, (String?, String?)>(
        selector: (_, p) =>
            (p.currentSong?.artworkUri, p.currentSong?.localPath),
        builder: (context, data, __) => _buildCrossfadeArtwork(
          data.$1,
          colorScheme,
          iconSize: 48,
          fallbackFilePath: data.$2,
        ),
      ),
    );
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
                    // sigma 30：全屏大图模糊的计算量随 sigma 近似平方增长，
                    // 50→30 显著降低进入播放器时的 GPU 峰值，视觉上同为"重度背景模糊"
                    imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
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
                  imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
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
    } else if (route == null) {
      // 拖拽覆盖层（非路由）：收起覆盖层，回到 MiniPlayer
      _isDismissing = true;
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // ── 顶栏向下拖拽原路返回（与上滑展开镜像） ──

  /// 顶栏向下拖拽开始：接管路由 controller（路由已存在，无 push 事件流风险）。
  /// Zen 模式下禁用拖拽收起（退出需长按专辑图），避免误触直接关闭播放器。
  void _onTopBarDragStart(DragStartDetails details) {
    final route = ModalRoute.of(context);
    if (route is! DraggablePlayerRoute || _zenMode) return;
    _topBarDragRoute = route;
    // 停掉可能仍在进行的松手动画、重置 dismiss 标志，并从全屏开始拖拽：
    // 1) 修复连续拖拽不跟手（手指已移动一段才收到首个 update，若不停动画
    //    播放页会从动画中的位置跳变到拖拽位置）；
    // 2) 修复上一次 dismiss 动画中再拖拽时 _isDismissing=true 残留，
    //    导致松手 settleToFull 被吞掉、动画状态错乱。
    route.beginDrag();
    route.controller.value = 1.0;
    // 完整收起距离：拖拽模式用 MiniPlayer 顶端；tap 模式（点击进入）用全局
    // 记录的 MiniPlayer 顶端，让播放页沿「展开路径」原路下滑（1:1 跟手）
    final total = route.dragOriginTop ?? playerDragOriginTop;
    _topBarDragTotal = total > 0 ? total : MediaQuery.sizeOf(context).height;
    route.topBarDragging = true;
    route.topBarDragTotal = _topBarDragTotal;
    _topBarDragDistance = 0.0;
    _topBarDragLastY = details.globalPosition.dy;
    _topBarDragLastTime = null;
    _topBarDragVelocity = 0.0;
  }

  /// 顶栏向下拖拽：播放页跟随手指原路下滑（向下为正，向上忽略）。
  void _onTopBarDragUpdate(DragUpdateDetails details) {
    final route = _topBarDragRoute;
    if (route == null) return;
    _topBarDragDistance = (_topBarDragDistance + details.delta.dy).clamp(
      0.0,
      double.infinity,
    );
    // 速度估计（按事件时间戳差分，向下为正）
    final ts = details.sourceTimeStamp;
    if (ts != null && _topBarDragLastTime != null && _topBarDragLastY != null) {
      final dt = (ts - _topBarDragLastTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        _topBarDragVelocity =
            (details.globalPosition.dy - _topBarDragLastY!) / dt;
      }
    }
    _topBarDragLastY = details.globalPosition.dy;
    _topBarDragLastTime = ts;
    // 完整收起距离 = MiniPlayer 顶端（与展开镜像）；value 从 1（全屏）→ 0（MiniPlayer）
    final total = _topBarDragTotal;
    if (total <= 0) return;
    final progress = (1.0 - _topBarDragDistance / total).clamp(0.0, 1.0);
    route.controller.stop();
    route.controller.value = progress;
  }

  /// 顶栏向下拖拽松手：下拉达标（距离/速度）收起，否则弹回全屏。
  void _onTopBarDragEnd(DragEndDetails details) {
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    // 注意：不在此处清空 topBarDragTotal —— 松手动画（dismiss/settleToFull）
    // 期间保持「原路返回映射」，由 settleToFull 在动画完成时恢复；dismiss 则
    // 随路由销毁。避免映射切换导致播放页跳变、出现「两次下滑动画」
    final threshold =
        MediaQuery.sizeOf(context).height * kPlayerExpandDistanceRatio;
    final downVelocity = details.primaryVelocity ?? _topBarDragVelocity;
    final collapse =
        _topBarDragDistance >= threshold ||
        downVelocity > kPlayerFlingVelocityThreshold;
    // ignore: avoid_print
    print(
      '[TopBar] end dist=$_topBarDragDistance thr=$threshold vel=$downVelocity collapse=$collapse v=${route.controller.value}',
    );
    if (collapse) {
      route.dismiss(); // 原路返回：reverse 到 0 + removeRoute
    } else {
      route.settleToFull(); // 弹回全屏
    }
  }

  /// 顶栏拖拽被系统取消（来电/手势中断等）：停在半途时弹回全屏，防御状态残留。
  void _onTopBarDragCancel() {
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    if (route.controller.value < 1.0) {
      route.settleToFull(); // 弹回动画结束时由路由恢复映射
    } else {
      route.topBarDragTotal = null; // 没拖，直接恢复原映射
    }
  }

  /// 拖拽展开完成：切换沉浸模式并移除监听。
  void _onDragRouteStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    applyImmersiveForOrientation();
    _systemUiModified = true;
    _dragRoute?.controller.removeStatusListener(_onDragRouteStatus);
    _dragRoute = null;
    if (mounted) setState(() {});
  }

  /// 跳转到当前歌曲所在专辑页。
  /// 若 song.albumId 为空（如本地歌曲缺少元数据），提示用户无专辑信息。
  void _navigateToAlbum(Song song) {
    final albumId = song.albumId;
    if (albumId == null || albumId.isEmpty) {
      showToast('暂无专辑信息', long: true);
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
      showToast('暂无歌手信息', long: true);
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
          const Center(child: M3ELoadingIndicator(color: Colors.white)),
    );
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      if (result == null || result.isEmpty) {
        showToast('未找到歌手「$name」', long: true);
        return;
      }
      final artist = result.first;
      _pushArtistPage(artist.id, artist.name);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      showToast('搜索歌手失败：$e', long: true);
    }
  }

  /// 实际 push 歌手详情页。先 dismiss FullPlayer，再 push。
  void _pushArtistPage(String? artistId, String artistName) {
    if (artistId == null || artistId.isEmpty) {
      showToast('暂无歌手信息', long: true);
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
    return Builder(builder: _buildPlayer);
  }

  Widget _buildPlayer(BuildContext context) {
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
    // 拖拽展开模式下系统栏样式跟随展开进度，避免拖动过程提前切换（见 PlayerSystemUiScope）
    return PlayerSystemUiScope(
      dragRoute: _dragRoute,
      // 拖拽覆盖层（非路由）期间系统栏恒为主页面样式
      forceMainStyle: _isDragOverlay,
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
            // 3.5 频谱背景层：style=2 时显示底部条形频谱图（播放时淡入、暂停时淡出）
            if (_spectrumEnabled && _spectrumStyle == 2)
              SpectrumBackground(
                color: _spectrumColor,
                opacity: _spectrumBgOpacity,
                heightRatio: _spectrumBgHeight,
                visible: playerProvider.isPlaying,
              ),
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
                  onTap: () {
                    // 长按封面切 Zen 模式后松手不再当作点击跳歌词页
                    if (_consumeZenPressTap()) return;
                    _tabController.animateTo(2);
                  },
                  behavior: HitTestBehavior.opaque,
                  // 封面 tab 与顶栏一样支持向下拖拽原路返回关闭播放器
                  onVerticalDragStart: _onTopBarDragStart,
                  onVerticalDragUpdate: _onTopBarDragUpdate,
                  onVerticalDragEnd: _onTopBarDragEnd,
                  onVerticalDragCancel: _onTopBarDragCancel,
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
                            child: M3ELoadingIndicator(color: Colors.white),
                          )
                        // 取词失败/酷狗无词（_parsedLyrics 为空）：给出"暂无歌词"提示，避免空白
                        // 样式与评论区"暂无评论"空状态一致：同字重（titleMedium w500）与同亮度（白 70%）
                        : _parsedLyrics.isEmpty
                        ? _buildAmEmptyLyrics(context)
                        // P0: 用 ListenableBuilder 同时订阅 positionNotifier（高频 200ms）
                        // 与 playerProvider（播放/暂停切换等低频通知）。
                        // 修复：暂停后 positionStream 只发相同值 → ValueNotifier 不通知 →
                        // AppleLyricsView 的 isPlaying 停留旧值 → 内部 Ticker 永不收敛停止 → 120fps。
                        // 监听 provider 后，暂停瞬间 notifyListeners → 重建 → isPlaying 更新。
                        : ListenableBuilder(
                            listenable: Listenable.merge([
                              playerProvider.positionNotifier,
                              playerProvider,
                            ]),
                            builder: (context, _) {
                              // 逐字歌词时间偏移（仅在线音乐生效）：渲染位置 = 播放位置 - 偏移
                              final offset =
                                  (currentSong != null && currentSong.isOnline)
                                  ? SettingsRepository.lyricTimeOffsetMs.value
                                  : 0;
                              final rawMs = playerProvider
                                  .positionNotifier
                                  .value
                                  .inMilliseconds;
                              return AppleLyricsView(
                                lines: _parsedLyrics,
                                currentTimeMs: rawMs > offset
                                    ? rawMs - offset
                                    : 0,
                                isPlaying: playerProvider.isPlaying,
                                forceDarkBackground: true,
                                // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                enableInterludeDots:
                                    !_isLocalLrcLyricWithoutWordTiming(
                                      currentSong,
                                    ),
                                doubleTapToJump: lyricDoubleTap,
                                accentColor: _lyricAccentColor,
                                // 歌曲 BPM（本地标签/接口，可空）：用于快慢歌辉光阈值
                                songBpm: currentSong?.bpm,
                                onSeek: (ms) => playerProvider.seek(
                                  Duration(milliseconds: ms),
                                ),
                              );
                            },
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
                                  // 封面支持向下拖拽原路返回关闭播放器（横屏/pad 与竖屏一致），
                                  // 同时保留长按封面进入/退出 Zen 模式（按压内缩 + 引导提示）
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onVerticalDragStart: _onTopBarDragStart,
                                    onVerticalDragUpdate: _onTopBarDragUpdate,
                                    onVerticalDragEnd: _onTopBarDragEnd,
                                    onVerticalDragCancel: _onTopBarDragCancel,
                                    child: _wrapArtworkZenPress(
                                      child: AnimatedScale(
                                        // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                                        scale:
                                            _spectrumEnabled &&
                                                _spectrumStyle < 2
                                            ? 1.0
                                            : (playerProvider.isPlaying
                                                  ? 1.0
                                                  : 0.85),
                                        duration: const Duration(
                                          milliseconds: 500,
                                        ),
                                        curve: Curves.easeOutBack,
                                        child: _buildLandscapeArtworkContent(
                                          playerProvider,
                                          currentSong,
                                          colorScheme,
                                        ),
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
                            // 封面 tab 与顶栏一样支持向下拖拽原路返回关闭播放器
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragStart: _onTopBarDragStart,
                              onVerticalDragUpdate: _onTopBarDragUpdate,
                              onVerticalDragEnd: _onTopBarDragEnd,
                              onVerticalDragCancel: _onTopBarDragCancel,
                              child: Selector<PlayerProvider, String?>(
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
                            ),
                            _isLoadingLyrics
                                // AM 风格：歌词 loading 改为白色，与深色背景协调
                                ? const Center(
                                    child: M3ELoadingIndicator(
                                      color: Colors.white,
                                    ),
                                  )
                                : RepaintBoundary(
                                    // P0: ListenableBuilder 同时订阅 positionNotifier（高频 200ms）
                                    // 与 playerProvider（播放/暂停切换低频通知），保证暂停时
                                    // AppleLyricsView 的 isPlaying 更新、Ticker 收敛后停止
                                    child: ListenableBuilder(
                                      listenable: Listenable.merge([
                                        playerProvider.positionNotifier,
                                        playerProvider,
                                      ]),
                                      builder: (context, _) => AppleLyricsView(
                                        lines: _parsedLyrics,
                                        currentTimeMs: playerProvider
                                            .positionNotifier
                                            .value
                                            .inMilliseconds,
                                        isPlaying: playerProvider.isPlaying,
                                        forceDarkBackground: true,
                                        // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                        enableInterludeDots:
                                            !_isLocalLrcLyricWithoutWordTiming(
                                              currentSong,
                                            ),
                                        doubleTapToJump: lyricDoubleTap,
                                        accentColor: _lyricAccentColor,
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
                                    // 封面支持向下拖拽原路返回关闭播放器（横屏/pad 与竖屏一致），
                                    // 同时保留长按封面进入/退出 Zen 模式（按压内缩 + 引导提示）
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onVerticalDragStart: _onTopBarDragStart,
                                      onVerticalDragUpdate: _onTopBarDragUpdate,
                                      onVerticalDragEnd: _onTopBarDragEnd,
                                      onVerticalDragCancel: _onTopBarDragCancel,
                                      child: _wrapArtworkZenPress(
                                        child: AnimatedScale(
                                          // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                                          scale:
                                              _spectrumEnabled &&
                                                  _spectrumStyle < 2
                                              ? 1.0
                                              : (playerProvider.isPlaying
                                                    ? 1.0
                                                    : 0.85),
                                          duration: const Duration(
                                            milliseconds: 500,
                                          ),
                                          curve: Curves.easeOutBack,
                                          child: _buildLandscapeArtworkContent(
                                            playerProvider,
                                            currentSong,
                                            colorScheme,
                                          ),
                                        ),
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
                            // 封面 tab 与顶栏一样支持向下拖拽原路返回关闭播放器
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragStart: _onTopBarDragStart,
                              onVerticalDragUpdate: _onTopBarDragUpdate,
                              onVerticalDragEnd: _onTopBarDragEnd,
                              onVerticalDragCancel: _onTopBarDragCancel,
                              child: Selector<PlayerProvider, String?>(
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
                            ),
                            _isLoadingLyrics
                                // AM 风格：歌词 loading 改为白色，与深色背景协调
                                ? const Center(
                                    child: M3ELoadingIndicator(
                                      color: Colors.white,
                                    ),
                                  )
                                : RepaintBoundary(
                                    // P0: ListenableBuilder 同时订阅 positionNotifier（高频 200ms）
                                    // 与 playerProvider（播放/暂停切换低频通知），保证暂停时
                                    // AppleLyricsView 的 isPlaying 更新、Ticker 收敛后停止
                                    child: ListenableBuilder(
                                      listenable: Listenable.merge([
                                        playerProvider.positionNotifier,
                                        playerProvider,
                                      ]),
                                      builder: (context, _) => AppleLyricsView(
                                        lines: _parsedLyrics,
                                        currentTimeMs: playerProvider
                                            .positionNotifier
                                            .value
                                            .inMilliseconds,
                                        isPlaying: playerProvider.isPlaying,
                                        forceDarkBackground: true,
                                        // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                        enableInterludeDots:
                                            !_isLocalLrcLyricWithoutWordTiming(
                                              currentSong,
                                            ),
                                        doubleTapToJump: lyricDoubleTap,
                                        accentColor: _lyricAccentColor,
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
    // 整个顶栏支持向下拖拽原路返回（点击按钮仍由子元素处理，竞技场自动区分）
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onTopBarDragStart,
      onVerticalDragUpdate: _onTopBarDragUpdate,
      onVerticalDragEnd: _onTopBarDragEnd,
      onVerticalDragCancel: _onTopBarDragCancel,
      child: Padding(
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
            // 歌曲信息：频率/位深/码率/声道 + USB 独占开关
            IconButton(
              icon: const Icon(Icons.info_outline, color: Colors.white),
              tooltip: '歌曲信息',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SongInfoPage()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: () => _showMoreMenu(context),
            ),
          ],
        ),
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
                // 长按封面进入/退出 Zen 模式：精确 2000ms + 按压内缩与引导提示
                return _wrapArtworkZenPress(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: maxSize,
                      maxHeight: maxSize,
                    ),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: AnimatedScale(
                        // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                        scale: _spectrumEnabled && _spectrumStyle < 2
                            ? 1.0
                            : (playerProvider.isPlaying ? 1.0 : 0.85),
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutBack,
                        // 频谱模式：style 0/1 白色圆形旋转封面 + 环形频谱
                        child: _spectrumEnabled && _spectrumStyle < 2
                            ? SpectrumArtwork(
                                artworkUri: currentSong.artworkUri,
                                fallbackFilePath: currentSong.localPath,
                                isPlaying: playerProvider.isPlaying,
                                bandCount: SpectrumService.instance.bandCount,
                                style: _spectrumStyle,
                                barColor: _spectrumColor,
                                opacity: _spectrumOpacity,
                              )
                            : ClipRRect(
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
                );
              },
            ),
            const Spacer(),
          ] else
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: _spectrumEnabled && _spectrumStyle < 2
                    ? SpectrumArtwork(
                        artworkUri: currentSong.artworkUri,
                        fallbackFilePath: currentSong.localPath,
                        isPlaying: playerProvider.isPlaying,
                        bandCount: SpectrumService.instance.bandCount,
                        style: _spectrumStyle,
                        barColor: _spectrumColor,
                        opacity: _spectrumOpacity,
                      )
                    : ClipRRect(
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
          // P0: 进度条监听 positionNotifier（高频 200ms）+ provider（duration/切歌等低频），
          // 不再依赖 provider 全量通知更新 position
          ListenableBuilder(
            listenable: Listenable.merge([
              playerProvider.positionNotifier,
              playerProvider,
            ]),
            builder: (context, _) => _buildProgressBar(
              playerProvider,
              playerProvider.position,
              playerProvider.duration ?? Duration.zero,
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
                    AppHaptics.tick();
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
                AppHaptics.tick();
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
          onPressed: () {
            AppHaptics.tick();
            playerProvider.toggleShuffle();
          },
        ),
        SizedBox(width: spacing),
        IconButton(
          iconSize: skipIconSize,
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onPressed: () {
            AppHaptics.click();
            playerProvider.previous();
          },
        ),
        SizedBox(width: spacing),
        // Apple Music 标志性白色圆形播放按钮，黑色图标
        IconButton.filled(
          iconSize: playIconSize,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: () {
            AppHaptics.click();
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
          onPressed: () {
            AppHaptics.click();
            playerProvider.next();
          },
        ),
        SizedBox(width: spacing),
        IconButton(
          icon: Icon(
            _getLoopModeIcon(loopMode),
            color: loopMode != AppLoopMode.off ? Colors.white : Colors.white70,
          ),
          onPressed: () {
            AppHaptics.tick();
            playerProvider.toggleLoopMode();
          },
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
              // 2-5. 页面切换组：播放列表/封面/歌词/评论。
              // 底部「高亮球」随 _tabController 动画值在 4 个按钮间平滑移动，
              // 点击切换（animateTo）与 TabBarView 滑动都驱动该动画，因而同步跟随。
              Expanded(
                flex: 4,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final switchWidth = constraints.maxWidth;
                    final btnW = switchWidth / 4;
                    const capsuleSize = 34.0;
                    _tabDragBtnW = btnW; // 供拖动逻辑换算 offset
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: _onTabDragStart,
                      onHorizontalDragUpdate: _onTabDragUpdate,
                      onHorizontalDragEnd: (_) => _onTabDragEnd(),
                      onHorizontalDragCancel: _onTabDragEnd,
                      child: Stack(
                        children: [
                          AnimatedBuilder(
                            // 必须监听 animation 动画对象本身，而不是 TabController：
                            // _changeIndex 只在动画开始/结束时 notify，动画期间的每帧进度
                            // （点击 animateTo 的 Curves.ease 与手指拖拽的 offset）只在新
                            // value 上体现，监听它才能在拖拽/切换时平滑连贯地跟随滑动。
                            animation:
                                _tabController.animation ??
                                const AlwaysStoppedAnimation<double>(0),
                            builder: (context, _) {
                              final anim =
                                  (_tabController.animation?.value ??
                                          _tabController.index.toDouble())
                                      .clamp(0.0, 3.0);
                              return Positioned(
                                left: anim * btnW + (btnW - capsuleSize) / 2,
                                top: (48 - capsuleSize) / 2,
                                width: capsuleSize,
                                height: capsuleSize,
                                child: IgnorePointer(
                                  child: AnimatedScale(
                                    // 拖动时放大，松手回缩
                                    scale: _tabDragActive ? 1.3 : 1.0,
                                    duration: const Duration(milliseconds: 150),
                                    curve: Curves.easeOut,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withValues(
                                          alpha: 0.25,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          Row(
                            children: [
                              // 播放列表 — 切换到播放列表面板
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_tabController.index != 0) {
                                      _tabController.animateTo(0);
                                    }
                                  },
                                  child: Center(
                                    child: Icon(
                                      Icons.queue_music,
                                      size: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              // 封面 — 短按跳转到封面 tab，长按弹出下载音质选择（本地歌曲屏蔽长按下载）
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_tabController.index != 1) {
                                      _tabController.animateTo(1);
                                    }
                                  },
                                  onLongPress:
                                      song != null &&
                                          isOnline &&
                                          AmStyleFullPlayer
                                                  .coverLongPressCallback !=
                                              null
                                      ? () {
                                          HapticFeedback.lightImpact();
                                          AmStyleFullPlayer
                                              .coverLongPressCallback!(
                                            context,
                                            song,
                                          );
                                        }
                                      : null,
                                  child: Center(
                                    child: Icon(
                                      Icons.album,
                                      size: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              // 歌词 — 短按跳转到歌词 tab，长按开关桌面歌词
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_tabController.index != 2) {
                                      _tabController.animateTo(2);
                                    }
                                  },
                                  onLongPress: () async {
                                    HapticFeedback.lightImpact();
                                    await DesktopLyricService.instance.toggle();
                                    if (mounted) {
                                      // 同步通知栏"桌面歌词"按钮状态
                                      final player = context
                                          .read<PlayerProvider>();
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
                                        duration:
                                            player.duration ?? Duration.zero,
                                        desktopLyricEnabled: DesktopLyricService
                                            .instance
                                            .enabled,
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
                              // 评论 — 跳转到评论 tab
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
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
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // 6. 收藏
              Expanded(
                child: InkWell(
                  onTap: song != null
                      ? () {
                          // 本地歌曲走 LocalFavoritesProvider，在线走 FavoritesProvider
                          if (isFavorited) {
                            AppHaptics.click();
                          } else {
                            AppHaptics.heavy();
                          }
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
                    // 长按在「翻译」与「罗马音」显示模式间切换。
                    // 判定按目标模式的数据可用性：粤语/纯音译歌常只有罗马音
                    // 无翻译（旧逻辑要求两者同时存在，导致有罗马音也切不了）。
                    final next =
                        LyricPreferences.instance.displayMode ==
                            LyricDisplayMode.translation
                        ? LyricDisplayMode.roma
                        : LyricDisplayMode.translation;
                    debugPrint(
                      '[RomaToggle] onLongPress: hasTranslation=$_hasTranslation hasRoma=$_hasRoma showTranslation=${LyricPreferences.instance.showTranslation} displayMode=${LyricPreferences.instance.displayMode} next=$next',
                    );
                    if (next == LyricDisplayMode.roma && !_hasRoma) {
                      debugPrint('[RomaToggle] 无罗马音数据，返回');
                      showToast('当前歌曲暂无罗马音');
                      return;
                    }
                    if (next == LyricDisplayMode.translation &&
                        !_hasTranslation) {
                      debugPrint('[RomaToggle] 无翻译数据，返回');
                      showToast('当前歌曲暂无翻译');
                      return;
                    }
                    // 副行渲染受 showTranslation 开关控制：短按关副行后长按
                    // 切模式仍不显示。切模式时强制打开副行，保证生效。
                    if (!LyricPreferences.instance.showTranslation) {
                      debugPrint('[RomaToggle] 强制打开副行开关 showTranslation');
                      LyricPreferences.instance.setShowTranslation(true);
                    }
                    LyricPreferences.instance.setDisplayMode(next);
                    debugPrint('[RomaToggle] 切换完成: displayMode=$next');
                    showToast(
                      next == LyricDisplayMode.roma ? '已切换到罗马音' : '已切换到翻译',
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

  /// 高亮球拖动开始：记录起始 tab，进入放大态
  void _onTabDragStart(DragStartDetails d) {
    setState(() {
      _tabDragActive = true;
      _tabDragDx = 0;
      _dragStartIndex = _tabController.index;
    });
  }

  /// 高亮球拖动中：跟手拖动，支持一次跨多个 tab。
  /// 手指右移 → 目标下标增加；目标越过整格就切换 index，余量写 offset，
  /// 让上方 TabBarView 页面与高亮球实时跟随。
  void _onTabDragUpdate(DragUpdateDetails d) {
    _tabDragDx += d.delta.dx;
    final len = _tabController.length;
    final target = (_dragStartIndex + _tabDragDx / _tabDragBtnW).clamp(
      0.0,
      len - 1.0,
    );
    final int newIndex = target.floor().clamp(0, len - 1);
    final double off = (target - newIndex).clamp(-1.0, 1.0);
    _tabController.index = newIndex;
    _tabController.offset = off;
  }

  /// 高亮球拖动结束：吸附到最近 tab，球回缩
  void _onTabDragEnd() {
    final current = _tabController.index + _tabController.offset;
    final nearest = current.round().clamp(0, _tabController.length - 1);
    setState(() => _tabDragActive = false);
    if (nearest != _tabController.index) {
      _tabController.animateTo(nearest);
    } else {
      // 吸附回原 tab：清掉 offset 余量，避免高亮球卡在两图标之间
      _tabController.offset = 0;
    }
  }

  /// 歌词为空时的「暂无歌词」空状态（AM 深色背景，白 70% 图标 + 文字）。
  Widget _buildAmEmptyLyrics(BuildContext context) {
    final emptyColor = Colors.white70; // 与评论区深色背景的 secondaryTextColor 一致
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lyrics_outlined, size: 48, color: emptyColor),
          const SizedBox(height: 12),
          Text(
            '暂无歌词',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: emptyColor),
          ),
        ],
      ),
    );
  }

  void _showVolumeDialog(PlayerProvider playerProvider) {
    // 独占开启时控制 USB 独立音量（与设置页同步），否则控制应用音量；带模式标识
    final usbService = UsbAudioService.instance;
    final usbEnabled = usbService.lastStatus['enabled'] == true;
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
                  final volume = usbEnabled
                      ? usbService.usbVolumePercent / 100
                      : playerProvider.volume;
                  final percent = (volume * 100).round();
                  final icon = volume <= 0
                      ? Icons.volume_off
                      : volume < 0.5
                      ? Icons.volume_down
                      : Icons.volume_up;
                  final colorScheme = Theme.of(context).colorScheme;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 模式标识：独占状态 / 普通状态
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (usbEnabled ? Colors.green : colorScheme.primary)
                                  .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          usbEnabled ? 'USB 独占音量' : '应用音量',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: usbEnabled
                                ? Colors.green
                                : colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Icon(icon, size: 32, color: colorScheme.primary),
                      const SizedBox(height: 8),
                      Slider(
                        value: volume,
                        onChanged: (value) {
                          if (usbEnabled) {
                            // 独占：与设置页「USB 音量」同步
                            usbService.setUsbVolume(value * 100);
                          } else {
                            playerProvider.setVolume(value);
                          }
                          setState(() {});
                        },
                      ),
                      Text(
                        '$percent%',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        usbEnabled ? '与设置页「USB 音量」同步' : '普通播放音量（重启后保留）',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
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

  /// 音质简短文本：去掉码率/格式后缀，与设置页默认音质按钮一致。
  String _qualityShortLabel(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.standard:
        return '标准';
      case AudioQuality.high:
        return '高品质';
      case AudioQuality.flac:
        return '无损';
      case AudioQuality.hires:
        return 'Hi-Res 无损';
    }
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
                _qualityShortLabel(quality),
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

  // 下载功能未移植（公开库不包含下载）：原封面长按入口已移除。

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
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 查看 MV：仅在线歌曲显示（原顶栏按钮收纳到菜单，置顶）
                if (song.isOnline == true)
                  ListTile(
                    leading: const Icon(Icons.music_video_outlined),
                    title: const Text('查看 MV'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        rootContext,
                        MaterialPageRoute(
                          builder: (_) => MvPlayerPage(song: song),
                        ),
                      );
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
                // 均衡器 / 定时关闭 / 投屏：同一行三格宫格，上方 icon 下方文字
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      ListenableBuilder(
                        listenable: EqualizerService.instance,
                        builder: (context, _) {
                          final eq = EqualizerService.instance;
                          return MenuActionCell(
                            icon: Icons.graphic_eq,
                            label: '均衡器',
                            active: eq.enabled,
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
                          return MenuActionCell(
                            icon: Icons.timer_outlined,
                            label: '定时关闭',
                            active: player.isSleepTimerActive,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _showSleepTimerSheet(rootContext, player);
                            },
                          );
                        },
                      ),
                      MenuActionCell(
                        icon: Icons.cast,
                        label: '投屏',
                        active: false,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _showDlnaCastSheet(rootContext);
                        },
                      ),
                    ],
                  ),
                ),
                // 置底：界面设置入口 → 打开二级菜单
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('界面设置'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showMoreSettingsSheet(rootContext);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 界面设置：二级菜单弹层（歌词类型 / 歌词显示设置 / 评论设置 / 音乐频谱）。
  void _showMoreSettingsSheet(BuildContext rootContext) {
    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
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
                // MD3E 拖拽把手
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.outline.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '界面设置',
                      style: Theme.of(sheetContext).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
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
                      title: const Text('评论设置'),
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
                // 音乐频谱环绕：仅 Android 显示
                if (Platform.isAndroid)
                  SwitchListTile(
                    title: const Text('音乐频谱环绕'),
                    subtitle: Text(
                      _spectrumEnabled
                          ? SpectrumService.instance.isSimulated
                                ? '已开启 · 模拟模式（设备不支持实时频谱）'
                                : '已开启 · 实时频谱'
                          : '封面裁圆旋转，频谱环绕跳动',
                    ),
                    value: _spectrumEnabled,
                    onChanged: (v) {
                      Navigator.pop(sheetContext);
                      _toggleSpectrum();
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
                    showToast('将在 ${d.inMinutes} 分钟后自动暂停', long: true);
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
                          showToast('请输入 1-240 之间的整数', long: true);
                          return;
                        }
                        final d = Duration(minutes: n);
                        player.setSleepTimer(d);
                        Navigator.pop(dialogCtx);
                        showToast('将在 $n 分钟后自动暂停', long: true);
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
      showToast('请先登录', long: true);
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return FutureBuilder<List<Map<String, dynamic>>?>(
          future: _loadUserPlaylistsSorted(api),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AlertDialog(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // AM 风格：白色 loading，与深色对话框背景协调
                    M3ELoadingIndicator(
                      constraints: BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      color: Colors.white,
                    ),
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

            final playlists = snapshot.data!;

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

  /// 拉取用户歌单并解析为「添加到歌单」对话框所需的 Map 列表，
  /// 再按收藏页「创建的歌单」自定义顺序原地排序后返回。
  /// 返回 null 表示请求失败（与旧逻辑中 snapshot.data == null 等价）。
  Future<List<Map<String, dynamic>>?> _loadUserPlaylistsSorted(
    KugouApiClient api,
  ) async {
    final resp = await api.getUserPlaylist(pagesize: 50);
    if (resp == null) return null;
    final data = resp['data'];
    List<dynamic> rawPlaylists = [];
    if (data is List) {
      rawPlaylists = data;
    } else if (data is Map) {
      rawPlaylists = data['info'] ?? data['list'] ?? data['special_list'] ?? [];
    }

    // 使用 KugouPlaylistBrief 模型解析，确保字段名映射正确
    // 只显示用户自己创建的歌单 (type=0)
    final playlists = <Map<String, dynamic>>[];
    for (final item in rawPlaylists) {
      final json = item as Map<String, dynamic>;
      final brief = KugouPlaylistBrief.fromJson(json);
      if (brief.type != 0) continue;
      // 排除「我喜欢」默认收藏歌单：收藏走红心机制，不走添加到歌单
      // （判定与 FavoritesProvider 一致：name == '我喜欢' || is_def == 2）
      if (brief.name == '我喜欢' || json['is_def'] == 2) continue;
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

    await PlaylistOrderUtils.sortCreatedPlaylistMaps(playlists);
    return playlists;
  }

  Future<void> _addSongToPlaylist(
    BuildContext context,
    dynamic song,
    Map<String, dynamic> playlist,
  ) async {
    final api = KugouApiClient();
    final listid =
        playlist['listid']?.toString() ?? playlist['list_id']?.toString() ?? '';
    final globalCollectionId =
        playlist['global_collection_id']?.toString() ??
        playlist['gid']?.toString() ??
        '';

    if (listid.isEmpty) {
      if (!context.mounted) return;
      showToast('歌单ID无效', long: true);
      return;
    }

    if (!context.mounted) return;
    final name = (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
        .toString();

    // 公开版偏好：添加前先检查歌曲是否已在歌单中，存在则不执行。
    // 用 global_collection_id 拉取歌单歌曲，按歌曲 hash（song.id）判断是否已存在。
    try {
      final gid = globalCollectionId.isNotEmpty ? globalCollectionId : listid;
      final existing = await api.getPlaylistTrackAll(
        id: gid,
        page: 1,
        pagesize: 100,
      );
      if (existing != null) {
        final songHash = song.id?.toString().toLowerCase() ?? '';
        final already = existing.any((s) => s.hash.toLowerCase() == songHash);
        if (already) {
          if (context.mounted) showToast('已在歌单「$name」中');
          return;
        }
      }
    } catch (_) {
      // 查询失败不阻断添加，继续走原逻辑
    }

    // 乐观更新：立即显示成功，后台同步到酷狗服务器
    if (!context.mounted) return;
    showToast('已添加到「$name」');

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
              showToast('同步到服务器失败，将在下次启动时重试', long: true);
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
