import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/services/usb_audio_service.dart';

import '../../core/build_flags.dart';
import '../../core/platform_capabilities.dart';
import '../../core/layout/page_title_alignment.dart';
import '../../core/layout/ui_density.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/services/audio_service_io.dart';
import '../../core/services/volume_normalization_service.dart';
import '../../core/services/background_image_loader.dart';
import '../../core/widgets/app_background.dart' show kDefaultWallpaperAsset;
import '../../core/services/custom_font_loader.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/viper_master_service.dart';
import '../../core/services/listen_report_service.dart';
import '../../core/services/play_history_sync_service.dart';
import '../../core/services/lyricon_provider_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/services/media_store_service.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/services/startup_auto_play.dart';
import '../../core/services/wakelock_service.dart';
import '../../core/services/diagnostic_exporter.dart';
import '../../core/layout/responsive_layout.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/tv_dropdown_menu.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion_constants.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../providers/song_match_provider.dart';
import '../coverflow/coverflow_source.dart';
import '../onboarding/onboarding_page.dart';
import '../onboarding/user_agreement_page.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/remote_control_provider.dart';
import '../../providers/shortcut_config_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_server.dart';
import '../../services/depth_cover_service.dart';
import '../../core/services/depth_cover_feature.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/player_top_bar_actions.dart';
import '../../widgets/player_top_bar_tab_dots.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/md3_lyric_preferences.dart';
import 'lyric_animation_settings_page.dart';
import '../../widgets/seed_color_picker.dart';
import '../../widgets/usb_exclusive_section.dart';
import '../player/mini_player.dart';
import '../player/car_mode_layout.dart';
import '../player/car_mode_panel.dart';
import '../player/player_cover_shadow.dart';
import '../../providers/car_mode_provider.dart';
import '../sound/sounds_page.dart';
import 'equalizer_settings_page.dart';
import 'desktop_lyric_settings_panel.dart';
import 'settings_group_heading.dart';
import 'settings_navigation.dart';
import 'settings_two_pane.dart';
import '../../core/layout/adaptive_navigator.dart' show DetailEmptyState;
import 'home_tab_manager.dart';
import 'mcp_agent_section.dart';
import 'settings_search_index.g.dart';

/// CI compile-time version injection via --dart-define=APP_VERSION=X
/// Fallback display when runtime PackageInfo read fails.
const String kBuildAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '4.0.0',
);

/// 设置类滑块统一的触感配置：**档位式**（discrete）而非连续式。
///
/// M3ESlider 在 `divisions == null` 时默认取 `M3EHapticConfig.continuous()`
/// （10ms 最小间隔 + 2% 阈值），拖动中会以最高约 100 次/秒走 MethodChannel
/// 触发 vibrate —— 真机上马达饱和且通道洪泛。凡是带 divisions 的设置滑块
/// 都要显式声明本配置。
const M3ESliderDecoration kSettingsSliderDecoration = M3ESliderDecoration(
  haptic: M3EHapticFeedback.medium,
  hapticConfig: M3EHapticConfig.discrete(),
);

/// 无极（无节点）滑块的触感配置：保留拖动中的连续反馈，但限流到约 16 次/秒
/// （`minimumDragInterval` 60ms + `deltaProgressForDragThreshold` 5%）。
/// 直接用 `M3EHapticConfig.continuous()` 是 10ms + 2%，即最高约 100 次/秒
/// 走 MethodChannel 触发 vibrate —— 与 discrete 档同一个马达饱和/通道洪泛坑。
const M3ESliderDecoration kFreeSliderDecoration = M3ESliderDecoration(
  haptic: M3EHapticFeedback.medium,
  hapticConfig: M3EHapticConfig(
    enableContinuousDrag: true,
    deltaProgressForDragThreshold: 0.05,
    minimumDragInterval: Duration(milliseconds: 60),
  ),
);

class SettingsPage extends StatefulWidget {
  /// 可选扩展：设置页分类列表的额外分类（默认关闭，由私有构建注入，
  /// 用于补充私有功能设置项）。
  static List<(String, IconData, Widget Function(ColorScheme))>?
  extraCategories;

  /// 可选扩展：设置搜索索引的额外条目（默认关闭，由私有构建注入，
  /// 与 [extraCategories] 配套，保证私有分类可被搜索命中）。
  static List<({String label, String category, String aliases})>?
  extraSearchIndexEntries;

  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin, CarModePanelSuppressor<SettingsPage> {
  bool _holdsCarModePanelSuppression = false;
  final SettingsRepository _settingsRepository = SettingsRepository();
  static const MethodChannel _appIconChannel = MethodChannel(
    'com.md3music.md3music/app_icon',
  );
  String _wifiQuality = '128';
  String _mobileQuality = '128';
  // 蝰蛇母带处理（10 段 EQ + 限幅母带链，默认关闭）
  bool _viperMasterEnabled = false;
  // 蝰蛇母带音源档位（实验功能，默认关闭）
  bool _viperTapeQualityEnabled = false;
  bool _autoReceiveVip = true;
  // 「听歌数据云同步」开关（默认开启：云端播放历史上传 + CSCC 真实播放上报
  // + 听歌等级累计，一个开关总控；显式关闭过的用户保持关闭）
  bool _uploadListeningDuration = true;
  // 新版本提醒开关（默认开启，关闭后启动时不再查询 GitHub Release）
  bool _updateReminderEnabled = true;
  // 还原旧版桌面图标（默认沿用当前图标，仅 Android 提供）
  bool _legacyAppIconEnabled = false;
  // 上次已提醒的新版本号（形如 5.6.5，空串=无）。用于「更新最新版本」副标题提示。
  String _pendingUpdateVersion = '';
  // 本地 API 服务器重启中（在线音乐区块显示加载态）
  bool _isRestarting = false;
  // 诊断日志导出进行中（关于区块显示加载态，防重复点击）
  bool _isExportingLogs = false;
  bool _useDynamicColor = false;
  // 封面动态取色开关（与系统主题色独立、可叠加；开启时封面优先）
  bool _useCoverSeedColor = false;
  // Apple Music 风格播放页开关（默认关闭，开启后用 AM 风格 FullPlayer）
  bool _useAmStylePlayer = false;
  bool _useGaussianBlur = true;
  bool _useArtistPhotoBackground = false;
  int _artistPhotoInterval = 15;
  double _artistPhotoOpacity = 0.55;
  bool _useGlowEffect = true;
  bool _useFlowingBackground = false;
  bool _useDuetLayout = true;
  // 歌词省电模式开关（默认开启，开启后歌词界面锁定 60fps，滑动时解锁）
  bool _lyricEcoMode = true;
  // 歌词动态字体颜色开关（默认开启，仅 AM 播放器生效）
  bool _lyricDynamicColor = true;
  // 平衡行换行：AM / MD 各一套独立偏好（key 不同，互不影响）
  bool _lyricLineBalanceAm = true;
  bool _lyricLineBalanceMd3 = true;
  String _appVersion = '';
  // 实时歌词推送协议选择（三选一 + 关闭）
  String _lyricPushProtocol = 'none';
  // LyricInfo 协议下的 ColorOS Bridge 兼容模式（默认开启）
  bool _lyricInfoColorOs = true;
  // 共用偏好：翻译 / 罗马音 / 优先翻译（同时存在时）
  bool _lyricPushTranslation = true;
  bool _lyricPushRoma = false;
  bool _lyricPushPreferTranslation = true;
  // 32bit 播放支持开关（默认关闭）。开启后无损(24/32bit)走高解析 float 输出；
  // 部分设备 float 播放可能变速/变调，若不适应可在设置里关闭。
  bool _enable32bitOutput = false;
  // 长按封面进入/退出 Zen 模式开关（默认开启）
  bool _zenCoverLongPress = true;
  // 专辑动态封面开关（主开关默认开启；移动网络子开关默认关闭）
  bool _dynamicAlbumCover = true;
  bool _dynamicAlbumCoverOnMobile = false;
  // 全屏播放器横屏自动隐藏系统栏开关（默认开启）
  bool _landscapeImmersiveEnabled = true;
  // 宽屏（横屏/平板）播放详情页「横屏控制面板独立页」开关（默认关闭 = 常驻控制带）
  bool _landscapeDetachedControls = false;
  // 顶栏「胶囊按钮收缩」开关（默认开启）：竖屏把睡眠定时 / 一起听与 ⋯ 合成一颗
  // 只露图标的胶囊。与上面的宽屏开关无关，两个方向各自独立生效。
  bool _topBarPillCollapse = true;
  // 页签圆点位置开关（默认关闭）：关闭 = 圆点留在底部页签条（原形态），
  // 开启 = 竖屏顶栏中央那排圆点。只影响竖屏，宽屏圆点恒在右栏底部。
  bool _topBarTabDots = false;
  // 音质降级提示开关（默认关闭）：所选音质不可用自动降级时弹出提示
  bool _showQualityDowngradeToast = false;
  // 记忆播放状态开关（默认开启）：冷启动恢复上次播放的歌曲与进度
  bool _restoreMemoryEnabled = true;
  // 启动时自动播放（默认关闭）。后两项仅在它打开时才有意义，故一并收在这里。
  // 音源下拉直接用 StartupAutoPlaySource.values，保证与启动流程的解析口径
  // 只有一份来源；持久化走它的 value 字符串。
  bool _startupAutoPlayEnabled = false;
  String _startupAutoPlaySource = 'resume';
  // 起播后连带推起完整播放页（默认开启）
  bool _startupAutoPlayOpenPage = true;
  // 设备 Android SDK 版本（SuperLyricApi 3.4 要求 API 26+，低于此禁用该协议选项）
  int? _androidSdkVersion;

  /// SuperLyric 是否受支持：API 26+（Android 8.0+）。未知时默认放行，避免误禁用。
  bool get _superLyricSupported =>
      _androidSdkVersion == null || _androidSdkVersion! >= 26;
  // 蓝牙歌词开关：通过 MediaSession 元数据替换在车机等设备显示歌词
  bool _bluetoothLyricEnabled = false;
  // 蓝牙歌词封面压缩开关：默认关闭（不压缩，保持原始封面质量）
  bool _bluetoothLyricCompressArt = false;
  // 全屏播放器封面的投影强度：0 = 关闭，1 = 最浓。
  // 缺省值与 PlayerCoverShadow.defaultIntensity 一致（两边各存一份是本仓惯例）。
  double _coverShadowStrength = 0.7;
  // 3D 封面（深度视差）总开关：默认关闭（模型需在设置页导入）
  bool _depthCoverEnabled = false;
  // 3D 封面视差强度：背景层最大平移像素，0 = 不动
  double _depthCoverStrength = 9.0;
  // 3D 封面 AI 背景修补（MI-GAN 神经细化）：默认开启，关闭则仅用金字塔修补
  bool _depthCoverNeuralInpaint = true;
  // 深度图缓存占用（字节，仅统计可重建的分层/深度图）
  int _depthCacheBytes = 0;
  // 魅族 Flyme 状态栏歌词：仅 Flyme 设备显示（原生把歌词贴到媒体通知 tickerText 上）
  bool _flymeStatusBarLyricEnabled = false;
  bool _flymeStatusBarLyricSupported = false;

  static const _flymeChannel = MethodChannel(
    'com.md3music.md3music/flyme_status_bar_lyric',
  );

  /// 查询本机是否 Flyme，并回读已保存的开关。非 Flyme 时整项隐藏，
  /// 避免用户在别的品牌上打开却完全看不到效果。
  Future<void> _loadFlymeStatusBarLyric() async {
    bool supported = false;
    try {
      supported =
          await _flymeChannel.invokeMethod<bool>(
            'isFlymeStatusBarLyricSupported',
          ) ??
          false;
    } catch (_) {
      supported = false;
    }
    if (!supported) {
      if (mounted) setState(() => _flymeStatusBarLyricSupported = false);
      return;
    }
    final enabled = await _settingsRepository.getFlymeStatusBarLyricEnabled();
    if (mounted) {
      setState(() {
        _flymeStatusBarLyricSupported = true;
        _flymeStatusBarLyricEnabled = enabled;
      });
    }
  }

  // 样式（字号/行距/字重/字体等）全部跟随 AM 歌词偏好，与播放页 Zen 模式一致
  // 锁屏歌词开关：锁屏时全屏显示滚动歌词（覆盖在系统锁屏上方），默认关闭
  bool _lockScreenLyricEnabled = false;
  // 禁用本应用挂载的 Android 系统音效链，避免与手机厂商音效叠加后播放音乐炸音
  bool _disableSystemAudioEffects = false;
  // 暂停淡入淡出开关
  bool _pauseFadeEnabled = false;
  // 交叉淡化（自动切歌时上一首渐出与下一首渐入叠加）
  bool _crossfadeEnabled = false;
  int _crossfadeSeconds = SettingsRepository.kCrossfadeDefaultSeconds;
  // 自动混音（AutoMix）：交叉淡化开启时按节拍对齐过渡点，由 Task 12 的播放器侧实现消费
  bool _automixEnabled = false;
  // 音量均衡（响度归一）
  bool _volumeNormalizationEnabled = false;
  double _volumeNormalizationLufs =
      VolumeNormalizationService.defaultReferenceLufs;
  // 播放时保持屏幕常亮开关
  bool _keepScreenOn = false;

  /// MV 弹幕开关（设置页与播放页浮层按钮共用同一个持久化 key）。
  bool _mvDanmakuEnabled = false;

  /// 歌曲弹幕开关（播放页弹幕层总开关，默认关闭）。
  bool _songDanmakuEnabled = false;

  /// MV 弹幕透明度（0.1–1.0）。用状态字段而非 FutureBuilder：
  /// FutureBuilder 每次 setState 都会新建 Future → 拖动时值会被旧快照覆盖（回弹）。
  double _mvDanmakuOpacity = 1.0;
  // 忽略音频焦点开关（默认开启：允许与其他应用同时播放音频）
  bool _ignoreAudioFocus = true;
  // 音频焦点中断策略（默认：保持播放）
  AudioFocusInterruptionMode _audioFocusInterruptionMode =
      AudioFocusInterruptionMode.keepPlaying;
  // MiniPlayer 滑动切歌开关（默认开启）
  bool _miniPlayerSwipeSwitch = true;
  // 收藏歌单按「最近点击」排序（默认关闭）
  bool _sortCollectedByLatestClick = false;
  // 「关闭本地音乐评论区」开关（默认开启）：开启后本地歌曲不显示评论 tab，
  // 也不提供「看评论」入口
  bool _closeLocalMusicComments = true;
  // 「自动匹配在线信息」开关（默认开启）：开启后为本地歌曲自动搜索匹配
  // 在线歌曲，补充封面兜底/歌词精确检索/评论区
  bool _autoMatchOnlineInfo = true;
  // 歌词双击跳转开关（默认关闭，开启后需双击歌词才能跳转位置）
  bool _lyricDoubleTapToJump = false;
  // 桌面布局（侧栏外壳）总开关不再走本页本地字段：设置 tile 直读全局判定源
  // kDesktopModeEnabled（唯一真值），与悬浮播放器同一模式。
  //
  // 此前保留本地 `_desktopModeEnabled`，导致它与全局源各自独立：
  // app.dart 冷启动写全局源、本页 _loadSettings 写本地字段，任一路径只更新
  // 其中一个，开关就会与实际生效状态相反（用户实际开着桌面布局、
  // 设置页却显示为关），且没有任何机制把两者拉回一致。
  // 预测性返回手势（predictive back）总开关：默认关闭
  bool _predictiveBackEnabled = false;
  // 歌单封面连贯过渡（列表卡片封面飞向详情页头）总开关：默认开启
  bool _playlistCoverTransition = true;
  // 悬浮播放器的进度指示（沿胶囊内缘包边一圈）：默认开启
  bool _secondaryPlayerProgress = true;
  // 一级页面是否也用悬浮底栏（false = 一级页面退回底部常驻条）：默认开启
  bool _secondaryPlayerOnPrimary = true;
  // 二级页面（及以后）是否收起底部导航栏：默认开启（隐藏底栏）
  bool _hideNavBarOnSecondary = true;
  // 封面流歌单源下拉条目。**必须是稳定实例**：M3EDropdownMenu.didUpdateWidget
  // 以列表同一性判断是否 setItems，每次 build 新建列表会触发 build 期间回调
  // 互递归（真机 ANR，2026-09-29，同类注释见 comments_view）；选中态由菜单
  // 内部维护，此列表只提供初始选中——外部改源（启动载入）发生在本页可交互前。
  late final List<M3EDropdownItem<CoverFlowSource>> _coverFlowSourceItems = [
    for (final source in CoverFlowSource.values)
      M3EDropdownItem(
        label: source.label,
        value: source,
        selected: source == kCoverFlowSource.value,
      ),
  ];
  // 自定义背景图片（全局界面背景）；默认关闭，未选择图片时回落到内置默认壁纸
  bool _useBackgroundImage = false;
  String? _backgroundImagePath;
  double _backgroundBlur = 20.0;
  // AM 播放页背景模糊（sigma 0~200，默认 30；仅动态流光关闭时渲染/显示）
  double _amPlayerBlur = 30.0;
  double _backgroundOpacity = 0.2;
  // 按背景图莫奈取色（默认开启）
  bool _useBackgroundMonet = true;
  // 文字阴影（默认关闭，仅在启用自定义背景图片时生效）
  bool _useTextShadow = false;
  // 文字阴影磅数（阴影模糊半径）
  double _textShadowBlur = AppTheme.defaultTextShadowBlur;
  // 播放页进度条波浪起伏开关（默认开启；关闭即回退到直线形态）
  bool _seekBarWaveEnabled = true;
  // 音乐频谱环绕显示开关（默认关闭，仅 Android 生效）
  bool _spectrumEnabled = false;
  // Visualizer 兜底（默认关闭，仅 Android 生效）：见 SettingsRepository 注释
  bool _spectrumVisualizerFallback = false;
  // 频谱柱数量（20~80，默认 40）
  int _spectrumBandCount = 40;
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
  // 音乐节奏震动（默认关闭）
  bool _musicHapticsEnabled = false;
  double _musicHapticsStrength = 0.8;
  double _musicHapticsSensitivity = 1.0;
  String _musicHapticsWaveform = 'auto';
  bool _musicHapticsSnare = true;
  int _musicHapticsOffset = 580;
  String _musicHapticsScope = 'playerPage';
  // 设置搜索：输入框控制器 + 当前查询词
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // 本页不显示车机模式常驻播放器面板
    _setCarModePanelSuppressed(true);
    // 页面切换过渡控制器：fade 0→1。切换流程 = 先 reverse 淡出旧页 →
    // 完成回调中切换内容 → 再 forward 淡入新页（严格串行，不重叠）。
    // 每段 120ms（总 ~240ms），过渡轻快。
    _sectionTransition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      value: 1.0,
    );
    _loadSettings();
    _loadVersion();
    if (!kTvBuild) _loadLyricPushSettings();
    _loadAndroidSdkVersion();
    _loadFlymeStatusBarLyric();
    _initEnable32bit();
    if (!kTvBuild) {
      LyriconProviderService.instance.addListener(_onLyriconStateChanged);
    }
    // 桌面歌词状态变化（设置页开关 / 播放器长按 / 通知栏按钮）→ 刷新 UI
    DesktopLyricService.instance.addListener(_onDesktopLyricChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Windows 桌面标签页由 IndexedStack 保活，切走时不会 dispose。
    // TickerMode 与标签页激活状态同步，隐藏设置页时释放抑制，回来时再恢复；
    // Android 保持原有「只在页面 dispose 时释放」行为。
    if (Platform.isWindows) {
      _setCarModePanelSuppressed(TickerMode.valuesOf(context).enabled);
    }
  }

  void _setCarModePanelSuppressed(bool suppressed) {
    if (_holdsCarModePanelSuppression == suppressed) return;
    if (suppressed) {
      suppressCarModePanel();
    } else {
      releaseCarModePanel();
    }
    _holdsCarModePanelSuppression = suppressed;
  }

  @override
  void dispose() {
    _sectionTransition.dispose();
    _searchController.dispose();
    if (!kTvBuild) {
      LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    }
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
    if (_holdsCarModePanelSuppression) {
      releaseCarModePanel();
      _holdsCarModePanelSuppression = false;
    }
    super.dispose();
  }

  /// Lyricon 服务状态变化回调：触发 UI 刷新
  void _onLyriconStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 桌面歌词开关状态变化回调：触发 UI 刷新
  void _onDesktopLyricChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 从 SettingsRepository 加载实时歌词推送协议与共用偏好。
  Future<void> _loadLyricPushSettings() async {
    final protocol = await _settingsRepository.getLyricPushProtocol();
    final translation = await _settingsRepository.getLyricPushTranslation();
    final roma = await _settingsRepository.getLyricPushRoma();
    final preferTranslation = await _settingsRepository
        .getLyricPushPreferTranslation();
    final colorOs = await _settingsRepository.getLyricInfoColorOs();
    if (mounted) {
      setState(() {
        _lyricPushProtocol = protocol;
        _lyricPushTranslation = translation;
        _lyricPushRoma = roma;
        _lyricPushPreferTranslation = preferTranslation;
      });
    }
    // 应用共用偏好到当前启用的推送服务（协议的实际启停由 main.dart 启动恢复处理）
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: translation,
      roma: roma,
      preferTranslation: preferTranslation,
    );
    if (protocol == 'lyricon') {
      try {
        await LyriconProviderService.instance.setDisplayTranslation(
          translation,
        );
        await LyriconProviderService.instance.setDisplayRoma(roma);
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _lyricInfoColorOs = colorOs);
    }
  }

  /// 加载设备 Android SDK 版本，用于判断 SuperLyric（要求 API 26+）是否可用。
  Future<void> _loadAndroidSdkVersion() async {
    final sdk = await MediaStoreService.getSdkVersion();
    if (mounted && sdk != null) {
      setState(() {
        _androidSdkVersion = sdk;
      });
    }
  }

  /// Lyricon 连接状态 → 中文文案
  String _getLyriconStateText() {
    switch (LyriconProviderService.instance.state) {
      case LyriconConnectionState.disabled:
        return '未启用';
      case LyriconConnectionState.connecting:
        return '连接中...';
      case LyriconConnectionState.connected:
        return '已连接';
      case LyriconConnectionState.disconnected:
        return '已断开';
      case LyriconConnectionState.timeout:
        return '连接超时，请检查 Lyricon / LSPosed 配置';
    }
  }

  Future<void> _loadSettings() async {
    // 两套网络音质：从未单独设置过的网络回退到旧全局默认音质
    final wifiQuality = await _settingsRepository.getWifiQuality();
    final mobileQuality = await _settingsRepository.getMobileQuality();
    final autoReceiveVip = await _settingsRepository.getAutoReceiveVip();
    // 从 ThemeProvider 同步「使用系统主题色」开关状态
    final useDynamicColor = context.read<ThemeProvider>().useDynamicColor;
    // 从 ThemeProvider 同步「封面动态取色」开关状态
    final useCoverSeedColor = context.read<ThemeProvider>().useCoverSeedColor;
    // 从 ThemeProvider 同步「Apple Music 风格播放页」开关状态
    final useAmStylePlayer = context.read<ThemeProvider>().useAmStylePlayer;
    final lyricDoubleTapToJump = context
        .read<ThemeProvider>()
        .lyricDoubleTapToJump;
    final useArtistPhotoBackground = context
        .read<ThemeProvider>()
        .useArtistPhotoBackground;
    final artistPhotoInterval = context
        .read<ThemeProvider>()
        .artistPhotoInterval;
    final artistPhotoOpacity = context.read<ThemeProvider>().artistPhotoOpacity;
    // 本页「启用自定义背景图片」开关的状态，必须读**用户开关本身**
    // （useBackgroundImage），不能读 isBackgroundImageEffective。
    //
    // 两者语义不同：后者额外要求"用户图片文件真实存在"。用户开着开关但还没
    // 选图时它为 false —— 若拿它驱动开关，开关会被显示成"关"，
    // 且下方依赖 _useBackgroundImage 的文字阴影 / 自动校准等从属项一并失效。
    // 2026-10-11误改此处，导致默认壁纸预览不显示。
    final useBackgroundImage = context.read<ThemeProvider>().useBackgroundImage;
    final backgroundImagePath = context
        .read<ThemeProvider>()
        .backgroundImagePath;
    final backgroundBlur = context.read<ThemeProvider>().backgroundBlur;
    final amPlayerBlur = context.read<ThemeProvider>().amPlayerBlur;
    final backgroundOpacity = context.read<ThemeProvider>().backgroundOpacity;
    final useBackgroundMonet = context.read<ThemeProvider>().useBackgroundMonet;
    final useTextShadow = context.read<ThemeProvider>().useTextShadow;
    final textShadowBlur = context.read<ThemeProvider>().textShadowBlur;
    // 读取蓝牙歌词开关
    final bluetoothLyricEnabled = await _settingsRepository
        .getBluetoothLyricEnabled();
    // 读取蓝牙歌词封面压缩开关
    final bluetoothLyricCompressArt = await _settingsRepository
        .getBluetoothLyricCompressArt();
    // 读取 3D 封面（深度视差）总开关
    final depthCoverEnabled = await _settingsRepository.getDepthCoverEnabled();
    final depthCoverStrength = await _settingsRepository
        .getDepthCoverStrength();
    // 读取封面投影强度（0 = 关闭）
    final coverShadowStrength = await _settingsRepository
        .getCoverShadowStrength();
    // 读取 3D 封面 AI 背景修补开关（MI-GAN 神经细化）
    final depthCoverNeuralInpaint = await _settingsRepository
        .getDepthCoverNeuralInpaint();
    // 读取 3D 封面深度图缓存占用
    final depthCacheBytes = await DepthCoverService.instance.cache
        .cacheSizeBytes();
    // 读取锁屏歌词开关
    final lockScreenLyricEnabled = await _settingsRepository
        .getLockScreenLyricEnabled();
    final disableSystemAudioEffects = await _settingsRepository
        .getDisableSystemAudioEffects();
    final pauseFadeEnabled = await _settingsRepository.getPauseFadeEnabled();
    final crossfadeEnabled = await _settingsRepository.getCrossfadeEnabled();
    final crossfadeSeconds = await _settingsRepository.getCrossfadeSeconds();
    final automixEnabled = await _settingsRepository.getAutomixEnabled();
    final volumeNormalizationEnabled = await _settingsRepository
        .getVolumeNormalizationEnabled();
    final volumeNormalizationLufs = await _settingsRepository
        .getVolumeNormalizationReferenceLufs();
    final keepScreenOn = await _settingsRepository.getKeepScreenOn();
    final ignoreAudioFocus = await _settingsRepository.getIgnoreAudioFocus();
    final audioFocusInterruptionMode = await _settingsRepository
        .getAudioFocusInterruptionMode();
    final seekBarWaveEnabled = await _settingsRepository
        .getSeekBarWaveEnabled();
    final spectrumEnabled = await _settingsRepository.getSpectrumEnabled();
    final spectrumVisualizerFallback =
        await _settingsRepository.getSpectrumVisualizerFallback();
    final spectrumBandCount = await _settingsRepository.getSpectrumBandCount();
    final spectrumStyle = await _settingsRepository.getSpectrumStyle();
    final spectrumBgOpacity = await _settingsRepository.getSpectrumBgOpacity();
    final spectrumBgHeight = await _settingsRepository.getSpectrumBgHeight();
    final spectrumBarOpacity = await _settingsRepository
        .getSpectrumBarOpacity();
    final spectrumCurveOpacity = await _settingsRepository
        .getSpectrumCurveOpacity();
    final spectrumDynamicColor = await _settingsRepository
        .getSpectrumDynamicColor();
    final musicHapticsEnabled = await _settingsRepository
        .getMusicHapticsEnabled();
    final musicHapticsStrength = await _settingsRepository
        .getMusicHapticsStrength();
    final musicHapticsSensitivity = await _settingsRepository
        .getMusicHapticsSensitivity();
    final musicHapticsWaveform = await _settingsRepository
        .getMusicHapticsWaveform();
    final musicHapticsSnare = await _settingsRepository.getMusicHapticsSnare();
    final musicHapticsOffset = await _settingsRepository.getMusicHapticsOffset();
    final musicHapticsScope = await _settingsRepository
        .getMusicHapticsScope();
    final miniPlayerSwipeSwitch = await _settingsRepository
        .getMiniPlayerSwipeSwitchEnabled();
    final sortCollectedByLatestClick = await _settingsRepository
        .getSortCollectedByLatestClick();
    final uploadListeningDuration = await _settingsRepository
        .getUploadListeningDuration();
    final zenCoverLongPress = await _settingsRepository.getZenCoverLongPress();
    final dynamicAlbumCover = await _settingsRepository.getDynamicAlbumCover();
    final dynamicAlbumCoverOnMobile = await _settingsRepository
        .getDynamicAlbumCoverOnMobile();
    final landscapeImmersiveEnabled = await _settingsRepository
        .getLandscapeImmersiveEnabled();
    final landscapeDetachedControls = await _settingsRepository
        .getLandscapeDetachedControls();
    final topBarPillCollapse = await _settingsRepository
        .getTopBarPillCollapse();
    final topBarTabDots = await _settingsRepository.getTopBarTabDots();
    final showQualityDowngradeToast = await _settingsRepository
        .getShowQualityDowngradeToast();
    final restoreMemoryEnabled = await _settingsRepository
        .getRestoreMemoryEnabled();
    final startupAutoPlayEnabled = await _settingsRepository
        .getStartupAutoPlayEnabled();
    final startupAutoPlaySource = await _settingsRepository
        .getStartupAutoPlaySource();
    final startupAutoPlayOpenPage = await _settingsRepository
        .getStartupAutoPlayOpenPage();
    final closeLocalMusicComments = await _settingsRepository
        .getCloseLocalMusicComments();
    final autoMatchOnlineInfo = await _settingsRepository
        .getAutoMatchOnlineInfo();
    final mvDanmakuEnabled = await _settingsRepository.getMvDanmakuEnabled();
    final mvDanmakuOpacity = await _settingsRepository.getMvDanmakuOpacity();
    final songDanmakuEnabled =
        await _settingsRepository.getSongDanmakuEnabled();
    final updateReminderEnabled = await _settingsRepository
        .getUpdateReminderEnabled();
    final legacyAppIconEnabled = await _settingsRepository
        .getLegacyAppIconEnabled();
    final pendingUpdateVersion = await _settingsRepository
        .getUpdateLastNotifiedVersion();
    final desktopModeEnabled = await _settingsRepository
        .getDesktopModeEnabled();
    final predictiveBackEnabled = await _settingsRepository
        .getPredictiveBackEnabled();
    final playlistCoverTransition = await _settingsRepository
        .getPlaylistCoverTransitionEnabled();
    final secondaryPlayerProgress = await _settingsRepository
        .getSecondaryPlayerProgress();
    final secondaryPlayerOnPrimary = await _settingsRepository
        .getSecondaryPlayerOnPrimary();
    final hideNavBarOnSecondary = await _settingsRepository
        .getHideNavBarOnSecondaryPages();
    final viperMasterEnabled = await _settingsRepository
        .getViperMasterEnabled();
    final viperTapeQualityEnabled = await _settingsRepository
        .getViperTapeQualityEnabled();

    setState(() {
      _wifiQuality = wifiQuality;
      _mobileQuality = mobileQuality;
      _viperMasterEnabled = viperMasterEnabled;
      _viperTapeQualityEnabled = viperTapeQualityEnabled;
      _autoReceiveVip = autoReceiveVip;
      _uploadListeningDuration = uploadListeningDuration;
      _updateReminderEnabled = updateReminderEnabled;
      _legacyAppIconEnabled = legacyAppIconEnabled;
      _pendingUpdateVersion = pendingUpdateVersion;
      // 桌面布局改为直读全局判定源，这里同步全局值而非本地字段。
      // 写全局源而不是仅记日志：app.dart 的启动同步可能尚未跑到
      // （或被其它入口抢先写过），本页读到持久化值时顺手校正一次，
      // 保证「唯一真值」名副其实。
      if (kDesktopModeEnabled.value != desktopModeEnabled) {
        kDesktopModeEnabled.value = desktopModeEnabled;
      }
      debugPrint(
        '[SettingsPage] desktopModeEnabled=$desktopModeEnabled '
        '(global=${kDesktopModeEnabled.value})',
      );
      _predictiveBackEnabled = predictiveBackEnabled;
      _playlistCoverTransition = playlistCoverTransition;
      _secondaryPlayerProgress = secondaryPlayerProgress;
      _secondaryPlayerOnPrimary = secondaryPlayerOnPrimary;
      _hideNavBarOnSecondary = hideNavBarOnSecondary;
      _useDynamicColor = useDynamicColor;
      _useCoverSeedColor = useCoverSeedColor;
      _useAmStylePlayer = useAmStylePlayer;
      _lyricDoubleTapToJump = lyricDoubleTapToJump;
      _useArtistPhotoBackground = useArtistPhotoBackground;
      _artistPhotoInterval = artistPhotoInterval;
      _artistPhotoOpacity = artistPhotoOpacity;
      _useBackgroundImage = useBackgroundImage;
      _backgroundImagePath = backgroundImagePath;
      _backgroundBlur = backgroundBlur;
      _amPlayerBlur = amPlayerBlur;
      _backgroundOpacity = backgroundOpacity;
      _useBackgroundMonet = useBackgroundMonet;
      _useTextShadow = useTextShadow;
      _textShadowBlur = textShadowBlur;
      _useGaussianBlur = LyricPreferences.instance.useGaussianBlur;
      _useGlowEffect = LyricPreferences.instance.useGlowEffect;
      _useFlowingBackground = LyricPreferences.instance.useFlowingBackground;
      _useDuetLayout = LyricPreferences.instance.useDuetLayout;
      _lyricEcoMode = LyricPreferences.instance.ecoMode;
      _lyricDynamicColor = LyricPreferences.instance.useDynamicLyricColor;
      _lyricLineBalanceAm = LyricPreferences.instance.lineBalance;
      _lyricLineBalanceMd3 = Md3LyricPreferences.instance.lineBalance;
      _bluetoothLyricEnabled = bluetoothLyricEnabled;
      _bluetoothLyricCompressArt = bluetoothLyricCompressArt;
      _depthCoverEnabled = depthCoverEnabled;
      _depthCoverStrength = depthCoverStrength;
      _coverShadowStrength = coverShadowStrength;
      _depthCoverNeuralInpaint = depthCoverNeuralInpaint;
      _depthCacheBytes = depthCacheBytes;
      // 同步全局开关信号（播放页若在场即时响应；播放页 host 首次加载也读它）
      DepthCoverService.enabledSignal.value = depthCoverEnabled;
      _lockScreenLyricEnabled = lockScreenLyricEnabled;
      _disableSystemAudioEffects = disableSystemAudioEffects;
      _pauseFadeEnabled = pauseFadeEnabled;
      _crossfadeEnabled = crossfadeEnabled;
      _crossfadeSeconds = crossfadeSeconds;
      _automixEnabled = automixEnabled;
      _volumeNormalizationEnabled = volumeNormalizationEnabled;
      _volumeNormalizationLufs = volumeNormalizationLufs;
      _keepScreenOn = keepScreenOn;
      _ignoreAudioFocus = ignoreAudioFocus;
      _audioFocusInterruptionMode = audioFocusInterruptionMode;
      _zenCoverLongPress = zenCoverLongPress;
      _dynamicAlbumCover = dynamicAlbumCover;
      _dynamicAlbumCoverOnMobile = dynamicAlbumCoverOnMobile;
      _landscapeImmersiveEnabled = landscapeImmersiveEnabled;
      _landscapeDetachedControls = landscapeDetachedControls;
      _topBarPillCollapse = topBarPillCollapse;
      _topBarTabDots = topBarTabDots;
      _showQualityDowngradeToast = showQualityDowngradeToast;
      _restoreMemoryEnabled = restoreMemoryEnabled;
      _startupAutoPlayEnabled = startupAutoPlayEnabled;
      _startupAutoPlaySource = startupAutoPlaySource;
      _startupAutoPlayOpenPage = startupAutoPlayOpenPage;
      _closeLocalMusicComments = closeLocalMusicComments;
      _autoMatchOnlineInfo = autoMatchOnlineInfo;
      _mvDanmakuEnabled = mvDanmakuEnabled;
      _mvDanmakuOpacity = mvDanmakuOpacity;
      _songDanmakuEnabled = songDanmakuEnabled;
      // 启动时把音量均衡设置同步给播放器（当前曲目若已加载会自动重算）
      AudioService().setVolumeNormalization(
        enabled: volumeNormalizationEnabled,
        referenceLufs: volumeNormalizationLufs,
      );
      _seekBarWaveEnabled = seekBarWaveEnabled;
      _spectrumEnabled = spectrumEnabled;
      _spectrumVisualizerFallback = spectrumVisualizerFallback;
      _spectrumBandCount = spectrumBandCount;
      _spectrumStyle = spectrumStyle;
      _spectrumBgOpacity = spectrumBgOpacity;
      _spectrumBgHeight = spectrumBgHeight;
      _spectrumBarOpacity = spectrumBarOpacity;
      _spectrumCurveOpacity = spectrumCurveOpacity;
      _spectrumDynamicColor = spectrumDynamicColor;
      _musicHapticsEnabled = musicHapticsEnabled;
      _musicHapticsStrength = musicHapticsStrength;
      _musicHapticsSensitivity = musicHapticsSensitivity;
      _musicHapticsWaveform = musicHapticsWaveform;
      _musicHapticsSnare = musicHapticsSnare;
      _musicHapticsOffset = musicHapticsOffset;
      _musicHapticsScope = musicHapticsScope;
      _miniPlayerSwipeSwitch = miniPlayerSwipeSwitch;
      _sortCollectedByLatestClick = sortCollectedByLatestClick;
    });
    // 同步到全局开关，让已挂载的 MiniPlayer 实例实时响应
    miniPlayerSwipeSwitchEnabled.value = miniPlayerSwipeSwitch;
  }

  void _onAudioFocusModeChanged(AudioFocusInterruptionMode mode) {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() {
      _audioFocusInterruptionMode = mode;
    });
    context.read<PlayerProvider>().setAudioFocusInterruptionMode(mode);
  }

  /// 音频焦点三选一的当前模式说明文字（跟随选中项）。
  String _audioFocusModeDescription(AudioFocusInterruptionMode mode) {
    switch (mode) {
      case AudioFocusInterruptionMode.keepPlaying:
        return '中断时保持播放状态、音量不变（受系统限制可能无声）';
      case AudioFocusInterruptionMode.pauseAndResume:
        return '中断时暂停播放，结束后自动恢复';
      case AudioFocusInterruptionMode.duckAndRestore:
        return '中断时降低音量，结束后恢复原音量';
    }
  }

  /// 新版本提醒开关：写入后下次启动生效（本次运行已排期的检查不撤销）。
  Future<void> _setUpdateReminderEnabled(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() {
      _updateReminderEnabled = value;
    });
    await _settingsRepository.setUpdateReminderEnabled(value);
  }

  /// 通过 Android activity-alias 切换桌面图标；失败时保持开关原值。
  Future<void> _setLegacyAppIconEnabled(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    try {
      await _appIconChannel.invokeMethod<void>('setLegacyIcon', value);
      await _settingsRepository.setLegacyAppIconEnabled(value);
      if (mounted) setState(() => _legacyAppIconEnabled = value);
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('切换应用图标失败：${error.message ?? error.code}')),
      );
    } on MissingPluginException {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('当前 Android 构建不支持切换应用图标')));
    }
  }

  /// 清理 3D 封面深度图缓存（确认后执行；模型文件不受影响）。
  Future<void> _clearDepthCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理深度图缓存'),
        content: const Text('将删除所有 3D 封面的分层/深度图缓存，\n各封面下次打开时会自动重新生成。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DepthCoverService.instance.cache.clearCache();
    if (!mounted) return;
    setState(() => _depthCacheBytes = 0);
    showToast('深度图缓存已清理');
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _appVersion = kBuildAppVersion;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final level = _level;
    final category = _categoryNamed(_activeSection);

    return PopScope(
      // 非总览页时拦截系统返回键：逐级回退（三级→二级→总览），而非直接退出设置页
      canPop: level == SettingsLevel.overview,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBackInvoked();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: level == SettingsLevel.overview
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: level == SettingsLevel.subpage
                      ? _closeSubpage
                      : _closeSection,
                ),
          title: _buildAppBarTitle(level, category),
          // 统一对齐规则：设置页内部的一/二/三级页面一律居中；
          // 总览页则按「是否为底部导航栏可直达的一级页面」判定
          centerTitle:
              level != SettingsLevel.overview ||
              centerPageTitle(context, tabId: 'settings'),
        ),
        // 页面切换过渡：先淡出旧层 → 切换内容 → 再淡入新层（严格串行）。
        // 淡入方向按层级方向区分：下钻自右侧推进、返回自左侧退回。
        //
        // 大屏「重组而非拉伸」：设置项是单栏内容，宽屏下约束到
        // [AppLayout.maxContentWidth] 并居中，多余宽度留白，避免整行 ListTile
        // 被无脑拉长（手机 <840dp 不触发，等同全宽，无回归）。
        body: _useTwoPane
            ? _buildTwoPaneBody(colorScheme, level, category)
            : _buildSinglePaneBody(colorScheme, level, category),
      ),
    );
  }

  /// 是否使用 Pad 双列布局（build 内求值一次，两个 body 方法共用）。
  bool get _useTwoPane => settingsUseTwoPaneLayout(
    padLayout: isPadLayout(context),
    width: MediaQuery.sizeOf(context).width,
    desktopLayout: isDesktopLayout(context),
  );

  /// 层级切换过渡包裹：淡出旧层 → 切内容 → 淡入新层（方向 _navForward）。
  Widget _transitioned(Widget child) {
    final direction = _navForward ? 1.0 : -1.0;
    return FadeTransition(
      opacity: _sectionTransition,
      child: SlideTransition(
        position: Tween<Offset>(
          // 退出与进入来自相反侧：下钻时旧页向左退，新页从右进；返回时反过来。
          begin: Offset((_sectionExiting ? -direction : direction) * 0.03, 0),
          end: Offset.zero,
        ).animate(_sectionTransition),
        child: child,
      ),
    );
  }

  /// 单列 body（手机 / 窄屏 / 桌面外壳）：与改造前完全一致。
  Widget _buildSinglePaneBody(
    ColorScheme colorScheme,
    SettingsLevel level,
    SettingsCategory? category,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppLayout.maxContentWidth,
        ),
        child: _transitioned(
          level == SettingsLevel.overview
              ? ListView(
                  key: _sectionListKey(level),
                  children: [
                    // 桌面布局：设置页以分类树导航为主，搜索框在此布局下
                    // 既冗余又会把整页背景切成两块（用户反馈"背景不一致"），
                    // 故隐藏。
                    if (!kDesktopModeEnabled.value) _buildSearchField(colorScheme),
                    if (!kDesktopModeEnabled.value &&
                        _searchQuery.trim().isNotEmpty)
                      ..._buildSearchResults(colorScheme)
                    else
                      ..._buildCategoryEntries(colorScheme),
                    const Gap(AppSpacing.xxl),
                  ],
                )
              : ListView(
                  key: _sectionListKey(level),
                  children: [
                    ListTileTheme(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      minVerticalPadding: AppSpacing.sm,
                      iconColor: colorScheme.onSurfaceVariant,
                      child: _buildSectionContent(
                        level: level,
                        category: category,
                        colorScheme: colorScheme,
                      ),
                    ),
                    const Gap(AppSpacing.xxl),
                  ],
                ),
        ),
      ),
    );
  }

  /// Pad 双列 body：左列分类/搜索列表常驻，右列显示当前选中层内容。
  /// 总览态右列复用 DetailEmptyState（transparent：不遮挡壁纸背景）；
  /// 过渡动画只作用于右列（左列静态）。
  Widget _buildTwoPaneBody(
    ColorScheme colorScheme,
    SettingsLevel level,
    SettingsCategory? category,
  ) {
    return SettingsTwoPaneBody(
      master: ListView(
        children: [
          // 同单栏：桌面布局下不显示搜索框（见 _buildPaneBody 内的说明）
          if (!kDesktopModeEnabled.value) _buildSearchField(colorScheme),
          if (!kDesktopModeEnabled.value && _searchQuery.trim().isNotEmpty)
            ..._buildSearchResults(colorScheme)
          else
            ..._buildCategoryEntries(colorScheme),
          const Gap(AppSpacing.xxl),
        ],
      ),
      detail: _transitioned(
        level == SettingsLevel.overview
            ? const DetailEmptyState(
                icon: Icons.tune,
                text: '从左侧选择分类进行配置',
                color: Colors.transparent,
              )
            : ListView(
                key: _sectionListKey(level),
                children: [
                  ListTileTheme(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    minVerticalPadding: AppSpacing.sm,
                    iconColor: colorScheme.onSurfaceVariant,
                    child: _buildSectionContent(
                      level: level,
                      category: category,
                      colorScheme: colorScheme,
                    ),
                  ),
                  const Gap(AppSpacing.xxl),
                ],
              ),
      ),
    );
  }

  /// 当前激活的二级分类标题；null 表示分类总览页
  String? _activeSection;

  /// 当前激活的三级子页标题；null 表示停留在二级页
  String? _activeSubpage;

  /// 本次层级切换的过渡方向：true = 下钻（新页自右侧推进），false = 返回
  bool _navForward = true;

  /// 当前是否处于旧页面淡出阶段。
  bool _sectionExiting = false;

  /// 页面切换过渡控制器（fade 0→1，见 initState）
  late AnimationController _sectionTransition;

  /// 当前所在层级
  SettingsLevel get _level => resolveSettingsLevel(
    category: _activeSection,
    subpage: _activeSubpage,
  );

  /// 层级内容列表的滚动位置标识。
  ///
  /// 一/二/三级共用同一个 Scaffold 与同一个列表插槽：不加 key 时 Flutter 按
  /// runtimeType+key 复用同一 Element 及其 ScrollPosition，滑动进度会跨页继承
  /// （且被短页 clamp 后反过来污染长页）。PageStorageKey 让每层拿到全新
  /// position（互不继承），同时各自在 PageStorage 里存自己的偏移（返回时回到
  /// 上次位置）。
  PageStorageKey<String> _sectionListKey(SettingsLevel level) =>
      PageStorageKey<String>(
        switch (level) {
          SettingsLevel.overview => 'settings|overview',
          SettingsLevel.category => 'settings|category|$_activeSection',
          SettingsLevel.subpage =>
            'settings|subpage|$_activeSection|$_activeSubpage',
        },
      );

  /// 按标题取分类；未命中返回 null（状态与模型不同步时降级为空内容）
  SettingsCategory? _categoryNamed(String? title) {
    if (title == null) return null;
    for (final category in _categories) {
      if (category.title == title) return category;
    }
    return null;
  }

  /// 设置页内层级切换：先快速淡出当前层，替换内容后再淡入（严格串行）。
  /// [forward] 决定淡入时的滑动方向：下钻自右侧推进、返回自左侧退回。
  void _navigateTo({
    required String? category,
    required String? subpage,
    required bool forward,
  }) {
    if (_sectionTransition.isAnimating) return;
    if (_activeSection == category && _activeSubpage == subpage) return;
    setState(() {
      _navForward = forward;
      _sectionExiting = true;
    });
    // 淡出更快（90ms），淡入稍长（160ms）带层次，整体跟手
    _sectionTransition.duration = const Duration(milliseconds: 90);
    _sectionTransition.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _activeSection = category;
        _activeSubpage = subpage;
        _sectionExiting = false;
      });
      _sectionTransition.duration = const Duration(milliseconds: 160);
      _sectionTransition.forward();
    });
  }

  /// 进入分类二级页面
  void _openSection(String title) =>
      _navigateTo(category: title, subpage: null, forward: true);

  /// 进入三级子页（保留当前分类）
  void _openSubpage(String title) =>
      _navigateTo(category: _activeSection, subpage: title, forward: true);

  /// 三级子页返回二级页
  void _closeSubpage() =>
      _navigateTo(category: _activeSection, subpage: null, forward: false);

  /// 返回分类总览
  void _closeSection() =>
      _navigateTo(category: null, subpage: null, forward: false);

  /// 系统返回键：按层级逐级回退（三级→二级→总览）；总览页交还系统处理
  void _onBackInvoked() {
    final target = settingsBackTarget(
      category: _activeSection,
      subpage: _activeSubpage,
    );
    if (target == null) return;
    _navigateTo(
      category: target.category,
      subpage: target.subpage,
      forward: false,
    );
  }

  /// 分类条目：图标 + 标题 + 副标题 + 三级子页 + 内容构建器
  List<SettingsCategory> get _categories => [
    SettingsCategory(
      title: '外观',
      icon: Icons.palette_outlined,
      description: '主题、字体与界面背景',
      subpages: [
        SettingsSubpage(
          title: '主题与配色',
          icon: Icons.brightness_6_outlined,
          description: '明暗模式、OLED 纯黑与主题色来源',
          builder: _buildThemeSubpage,
        ),
        SettingsSubpage(
          title: '字体与显示',
          icon: Icons.text_fields,
          description: '全局字体与显示大小',
          builder: _buildFontDisplaySubpage,
        ),
        SettingsSubpage(
          title: '导航与布局',
          icon: Icons.dashboard_outlined,
          description: '底部导航栏标签、桌面布局与悬浮播放条',
          builder: _buildShellLayoutSubpage,
        ),
        SettingsSubpage(
          title: '车机模式',
          icon: Icons.directions_car_outlined,
          description: '常驻播放器面板、面板尺寸与停靠位置',
          builder: _buildCarModeSubpage,
        ),
        SettingsSubpage(
          title: '界面背景',
          icon: Icons.wallpaper_outlined,
          description: '自定义背景图、模糊与文字可读性',
          builder: _buildBackgroundSubpage,
        ),
      ],
    ),
    SettingsCategory(
      title: '播放页样式',
      icon: Icons.music_note_outlined,
      description: '播放页风格与视觉效果',
      leading: _buildPlayerStyleLeading,
      body: _buildPlayerStyleTail,
      subpages: [
        // 播放页 chrome 的形态与位置：宽屏控制带、顶栏尾部胶囊、页签条落在哪一栏。
        // search-sub: 顶栏 页签 圆点 胶囊 收缩 控制带 控制面板 独立页 横屏 平板 布局
        SettingsSubpage(
          title: '顶栏与页签',
          icon: Icons.tab,
          description: '横屏控制带、顶栏胶囊收缩与页签圆点位置',
          builder: _buildPlayerChromeSubpage,
        ),
        SettingsSubpage(
          title: '封面与动态',
          icon: Icons.album_outlined,
          description: kDepthCoverAvailable
              ? '专辑动态封面、移动网络加载与 3D 深度封面'
              : '专辑动态封面与移动网络加载',
          builder: _buildCoverDynamicSubpage,
        ),
        SettingsSubpage(
          title: '歌词效果',
          icon: Icons.auto_awesome_outlined,
          description: '对唱优化、动态颜色、模糊、辉光与省电模式',
          builder: _buildLyricEffectSubpage,
        ),
        // 音乐频谱：依赖 Android Visualizer 采集 PCM 波形，桌面端无此数据源
        if (supportsMusicSpectrum)
          SettingsSubpage(
            title: '音乐频谱',
            icon: Icons.graphic_eq,
            description: '频谱样式、柱数量、取色与各层透明度',
            builder: _buildSpectrumSubpage,
          ),
        // search-sub: 进度条 波浪 起伏 回退 直线
        SettingsSubpage(
          title: '进度条',
          icon: Icons.linear_scale,
          description: '播放页进度条的波浪起伏',
          builder: _buildProgressBarSubpage,
        ),
        SettingsSubpage(
          title: '播放页背景',
          icon: Icons.wallpaper_outlined,
          description: '歌手写真轮播、背景流光与背景模糊',
          builder: _buildPlayerBackgroundSubpage,
        ),
      ],
    ),
    SettingsCategory(
      title: '歌词',
      icon: Icons.lyrics_outlined,
      description: '歌词推送与设备显示',
      body: _buildLyricTail,
      subpages: [
        if (!kTvBuild) ...[
          SettingsSubpage(
            title: '歌词推送',
            icon: Icons.push_pin_outlined,
            description: '推送协议与翻译 / 罗马音偏好',
            builder: _buildLyricPushSubpage,
          ),
        ],
        SettingsSubpage(
          title: '设备歌词',
          icon: Icons.devices_outlined,
          description: '桌面、蓝牙、锁屏与状态栏歌词',
          builder: _buildDeviceLyricSubpage,
        ),
      ],
    ),
    SettingsCategory(
      title: '播放',
      icon: Icons.play_circle_outline,
      description: '音质、音效与播放行为',
      subpages: [
        SettingsSubpage(
          title: '音质与输出',
          icon: Icons.high_quality_outlined,
          description: '网络音质、VIP 领取与 32bit 输出',
          builder: _buildAudioQualitySubpage,
        ),
        // 桌面端隐藏整个「音效与音量」分类：它下面所有子项（均衡器 / 音效库 /
        // 蝰蛇母带 / 音量均衡 / 参考响度）都依赖 Android AudioSession 绑定，
        // 全部已按supportsSystemAudioEffects 等门控隐藏。分类留着只会让用户
        // 点进一个**整页空白**的页面。
        if (supportsSystemAudioEffects)
          SettingsSubpage(
            title: '音效与音量',
            icon: Icons.equalizer_outlined,
            description: '均衡器、蝰蛇母带与音量均衡',
            builder: _buildAudioEffectsSubpage,
          ),
        SettingsSubpage(
          title: '播放行为',
          icon: Icons.play_circle_outline,
          description: '记忆播放、淡入淡出与音频焦点策略',
          builder: _buildPlaybackBehaviorSubpage,
        ),
        SettingsSubpage(
          title: '屏幕与视频',
          icon: Icons.movie_outlined,
          description: '屏幕常亮、横屏沉浸、MV 画中画与弹幕',
          builder: _buildScreenVideoSubpage,
        ),
        SettingsSubpage(
          title: '列表与交互',
          icon: Icons.list_alt_outlined,
          description: '评论区显示、滑动切歌与歌单排序',
          builder: _buildListInteractionSubpage,
        ),
      ],
    ),
    // 震动反馈：依赖 Android Vibrator，桌面端无对应硬件能力
    if (supportsHaptics)
      SettingsCategory(
        title: '震动反馈',
        icon: Icons.vibration,
        description: '总开关与各交互类别的震动细分，以及跟随鼓点的音乐节奏震动',
        body: _buildHapticsSection,
      ),
    // USB 独占输出：依赖 Android USB Host + native cpp（UAC1 DAC 直写 usbdevfs）
    if (supportsUsbExclusive)
      SettingsCategory(
        title: 'USB 独占',
        icon: Icons.usb,
        description: '独占输出与设备状态',
        body: (colorScheme) => UsbExclusiveSection(
          onAutoPause: () => context.read<PlayerProvider>().pause(),
        ),
      ),
    // TV 构建：遥控器模式（正常构建不编入）
    if (kTvBuild) ...[
      // search: 遥控 D-pad 焦点 电视
      SettingsCategory(
        title: '遥控器',
        icon: Icons.settings_remote_outlined,
        description: 'D-pad 导航与按键操作',
        body: _buildRemoteControlSection,
      ),
    ],
    SettingsCategory(
      title: '主页管理',
      icon: Icons.tab_outlined,
      description: '主页标签显示与排序',
      body: _buildTabManagementSection,
    ),
    // 桌面快捷方式：Android 应用图标长按快捷入口（quick_actions_android）
    if (supportsDesktopShortcut)
      SettingsCategory(
        title: '桌面快捷方式',
        icon: Icons.bolt_outlined,
        description: '应用图标长按快捷入口',
        body: _buildDesktopShortcutSection,
      ),
    SettingsCategory(
      title: 'AI 代理',
      icon: Icons.smart_toy_outlined,
      description: 'MCP 接口、访问令牌与只读模式',
      body: _buildAiAgentSection,
    ),
    SettingsCategory(
      title: '缓存与数据',
      icon: Icons.storage_outlined,
      description: '本地服务与数据维护',
      body: _buildCacheSection,
    ),
    SettingsCategory(
      title: '关于',
      icon: Icons.info_outline,
      description: '版本、帮助与许可',
      body: _buildAboutSection,
    ),
    // 可选扩展：私有构建注入的额外分类（默认无）。扩展点类型与语义保持不变，
    // 转换后无三级子页，二级页直接渲染其内容。
    ...?(SettingsPage.extraCategories?.map(settingsCategoryFromLegacy)),
  ];

  /// 二级/三级页面内容。
  /// 三级：直接渲染子页构建器；二级：leading → 三级入口列表 → body。
  Widget _buildSectionContent({
    required SettingsLevel level,
    required SettingsCategory? category,
    required ColorScheme colorScheme,
  }) {
    if (category == null) return const SizedBox.shrink();
    if (level == SettingsLevel.subpage) {
      final subpage = category.subpageNamed(_activeSubpage);
      if (subpage != null) return subpage.builder(colorScheme);
    }
    final leading = category.leading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (leading != null) leading(colorScheme),
        for (var i = 0; i < category.subpages.length; i++)
          _buildSubpageEntry(
            category.subpages[i],
            colorScheme,
            first: leading == null && i == 0,
          ),
        if (category.body != null) category.body!(colorScheme),
      ],
    );
  }

  /// 分类总览条目列表
  List<Widget> _buildCategoryEntries(ColorScheme colorScheme) {
    final categories = _categories;
    return [
      _buildGroupLabel('界面与显示', colorScheme, first: true),
      for (final c in categories.take(3)) _buildCategoryEntry(c, colorScheme),
      _buildGroupLabel('播放与音频', colorScheme),
      for (final c in categories.skip(3).take(2))
        _buildCategoryEntry(c, colorScheme),
      _buildGroupLabel('应用与管理', colorScheme),
      for (final c in categories.skip(5).take(5))
        _buildCategoryEntry(c, colorScheme),
      if (categories.length > 10) ...[
        _buildGroupLabel('更多设置', colorScheme),
        for (final c in categories.skip(10)) _buildCategoryEntry(c, colorScheme),
      ],
    ];
  }

  /// 分类条目（一级 → 二级）
  Widget _buildCategoryEntry(
    SettingsCategory category,
    ColorScheme colorScheme,
  ) {
    return _buildNavEntryTile(
      icon: category.icon,
      title: category.title,
      subtitle: category.description.isEmpty ? null : category.description,
      colorScheme: colorScheme,
      onTap: () => _openSection(category.title),
    );
  }

  /// 三级子页入口条目（二级 → 三级）
  Widget _buildSubpageEntry(
    SettingsSubpage subpage,
    ColorScheme colorScheme, {
    required bool first,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: first ? AppSpacing.sm : 0),
      child: _buildNavEntryTile(
        icon: subpage.icon,
        title: subpage.title,
        subtitle: subpage.description,
        colorScheme: colorScheme,
        onTap: () => _openSubpage(subpage.title),
      ),
    );
  }

  /// 导航条目共用外观：图标 + 标题 + 副标题 + 右侧箭头（分类/子页入口一致）。
  /// MD3：触控目标由 ListTile 保证 ≥48dp；间距走 AppSpacing（4dp 网格）。
  Widget _buildNavEntryTile({
    required IconData icon,
    required String title,
    required String? subtitle,
    required ColorScheme colorScheme,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      minVerticalPadding: AppSpacing.md,
      leading: Icon(icon, color: colorScheme.primary),
      title: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }

  /// AppBar 标题：总览固定「设置」；二级为分类名；三级只显示当前子页名。
  Widget _buildAppBarTitle(SettingsLevel level, SettingsCategory? category) {
    if (level == SettingsLevel.overview) return const Text('设置');
    final title = category?.title ?? _activeSection ?? '';
    final subpage = category?.subpageNamed(_activeSubpage);
    if (level != SettingsLevel.subpage || subpage == null) {
      return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final theme = Theme.of(context);
    return Text(
      subpage.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 搜索索引里属于 Android 系统音效链的条目 label。
///
/// 这些项在桌面端已整块隐藏（见 `_buildAudioEffectsSubpage` 的
/// `supportsSystemAudioEffects` 门控），但索引是编译期常量、
/// 看不穿运行时门控，故在 `_searchResults()` 里按 label 过滤，
/// 否则搜「均衡器 / 蝰蛇 / 响度」会跳到一个空白的「音效与音量」页。
///
/// 「应用功能」与「旁路效果链」不在此列：前者是 MCP 能力说明，
/// 后者是音效链内部的调试开关（已在页面内一并隐藏）。
static const Set<String> _kAndroidOnlyAudioLabels = {
  '均衡器',
  '禁用App均衡器和音效',
  '音效库',
  '蝰蛇母带处理',
  '蝰蛇母带音源',
  '音量均衡',
  '参考响度',
  '参考响度 LUFS',
};

/// 按查询词过滤搜索索引（label + aliases 包含匹配）。
  /// 索引由 scripts/tools/gen_settings_search_index.dart 从本文件源码生成，
  /// 新增/改名/下钻设置项后重新生成即可，无需手工维护条目。
  List<({String label, String category, String subpage, String aliases})>
  _searchResults(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    // 合并私有构建注入的额外索引条目（默认无）：老三元组没有三级页，补空串
    final entries =
        <({String label, String category, String subpage, String aliases})>[
          // 过滤掉当前平台**不存在对应 UI** 的条目，否则搜索会跳到空分类：
          //  · 3D 封面：标准包不带深度模型（kDepthCoverAvailable）
          //  · USB 独占：桌面端整块隐藏（依赖 Android USB Host + native cpp）
          //  · 音效链：桌面端隐藏（依赖 Android AudioSession 绑定音效）
          //
          // 索引本身是**编译期**常量：生成器只认 kTvBuild 这类 const 旗标，
          // 看不穿运行时平台判定，故只能在这里按能力过滤。
          for (final e in kSettingsSearchIndex)
            if ((kDepthCoverAvailable ||
                    !const {
                      '3D 封面',
                      '3D 封面强度',
                      'AI 背景修补',
                      '清理深度图缓存',
                    }.contains(e.label)) &&
                (supportsUsbExclusive || e.category != 'USB 独占') &&
                (supportsSystemAudioEffects || !_kAndroidOnlyAudioLabels.contains(e.label)))
              e,
          for (final e in SettingsPage.extraSearchIndexEntries ?? const [])
            (
              label: e.label,
              category: e.category,
              subpage: '',
              aliases: e.aliases,
            ),
        ];
    return entries
        .where((e) => '${e.label} ${e.aliases}'.toLowerCase().contains(q))
        .toList();
  }

  /// 总览页顶部搜索框。
  Widget _buildSearchField(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: TextField(
        controller: _searchController,
        contextMenuBuilder: buildAppTextContextMenu,
        onChanged: (v) => setState(() => _searchQuery = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索设置项',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: AppRadius.xlAll,
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// 搜索结果的设置项列表；无结果显示空态提示。
  List<Widget> _buildSearchResults(ColorScheme colorScheme) {
    final results = _searchResults(_searchQuery);
    if (results.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxxl),
          child: Center(
            child: Text(
              '未找到「${_searchQuery.trim()}」相关设置',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ];
    }
    return [
      for (final r in results)
        ListTile(
          leading: const Icon(Icons.search, size: 20),
          title: Text(r.label),
          subtitle: Text(
            r.subpage.isEmpty ? '${r.category} ›' : '${r.category} › ${r.subpage}',
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _openSearchResult(r),
        ),
    ];
  }

  /// 点击搜索结果：清空搜索并直达对应层级。
  /// 条目带三级页归属时直接落到三级子页，否则落到二级页。
  void _openSearchResult(
    ({String label, String category, String subpage, String aliases}) entry,
  ) {
    _searchController.clear();
    setState(() => _searchQuery = '');
    _navigateTo(
      category: entry.category,
      subpage: entry.subpage.isEmpty ? null : entry.subpage,
      forward: true,
    );
  }

  /// 「预测性返回手势」与「封面连贯过渡」互斥，两个开关的 onChanged 都走这里。
  ///
  /// 裁决集中在 `resolveCoverBackExclusivity`（封面连贯过渡优先），本方法只负责把
  /// 结果同时落到**本地 state / 全局 notifier / 持久化**三处，避免出现「两个都开着
  /// 但其中一个实际没生效」的口径分裂。
  /// 两个开关的 onChanged 共用，裁决只有一份 `resolveCoverBackExclusivity`
  /// （**永远封面连贯过渡优先**，与 `lib/app.dart` 冷启动收敛存量同开用的是同一个
  /// 函数，不会出现「设置页与启动后行为不一致」）。
  ///
  /// 因此两种连带情况要分开告知，否则都会被当成开关失灵：
  /// - 想开预测性返回但封面连贯过渡开着 → 本项被**拒绝**（弹回关闭）；
  /// - 开封面连贯过渡 → 预测性返回被**连带关闭**。
  /// 关掉任何一个不连带改动另一个。
  void _applyCoverBackExclusivity({
    required bool coverTransition,
    required bool predictiveBack,
  }) {
    final bool wantedBackOn = predictiveBack && !_predictiveBackEnabled;
    final bool wantedCoverOn = coverTransition && !_playlistCoverTransition;
    final resolved = resolveCoverBackExclusivity(
      coverTransition: coverTransition,
      predictiveBack: predictiveBack,
    );
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() {
      _predictiveBackEnabled = resolved.predictiveBack;
      _playlistCoverTransition = resolved.coverTransition;
    });
    _settingsRepository.setPredictiveBackEnabled(resolved.predictiveBack);
    _settingsRepository.setPlaylistCoverTransitionEnabled(
      resolved.coverTransition,
    );
    // 立即生效：MaterialApp 按前者切 pageTransitionsTheme，
    // PlaylistCoverHero 按后者决定是否登记来源与起飞。
    kPredictiveBackEnabled.value = resolved.predictiveBack;
    kPlaylistCoverTransitionEnabled.value = resolved.coverTransition;
    if (wantedBackOn && !resolved.predictiveBack) {
      showToast(
        '「封面连贯过渡」开启时无法使用预测性返回，请先关闭封面连贯过渡',
        long: true,
      );
    } else if (wantedCoverOn && resolved.predictiveBack != predictiveBack) {
      showToast('已同时关闭「预测性返回手势」：两者互斥', long: true);
    }
  }

  /// 分组标题统一承担定位与分隔作用；不使用多张独立卡片。
  Widget _buildGroupLabel(
    String text,
    ColorScheme colorScheme, {
    bool first = false,
  }) {
    return SettingsGroupHeading(text, first: first);
  }

  /// 设置行尾部的状态数值（如「3 秒」「85%」「-14 LUFS」）统一弱化：
  /// labelLarge + onSurfaceVariant，与行标题拉开层级、不与之争夺注意力。
  Widget _statusText(String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 偏移控件下方的「实测值 + 自动校准」行（两处共用）。
  ///
  /// 实测值来自 AudioTrack 的「已写入 vs 已播放」帧差；播放中没有 AudioTrack
  /// （USB 独占 / Direct PCM）时显示"不可用"，此时自动校准按钮会提示而不是静默。
  Widget _offsetAutoRow() {
    final service = MusicHapticsService.instance;
    final measured = service.measuredLatencyMs;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          measured == null ? '实测：不可用（当前输出路径无 AudioTrack）' : '实测：$measured ms',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton(
          onPressed: () async {
            final ok = await service.applyAutoOffset();
            if (!mounted) return;
            final msg = ok
                ? '已按实测 ${service.measuredLatencyMs}ms 校准'
                : '测量失败：请在播放中重试（USB 独占/Direct PCM 路径无此测量）';
            showToast(msg, long: !ok);
            if (ok) setState(() => _musicHapticsOffset = service.offsetMs);
          },
          child: const Text('自动校准'),
        ),
      ],
    );
  }

  /// 「遥控器」分类体：三态模式选择（仅 TV 构建存在）。
  Widget _buildRemoteControlSection(ColorScheme colorScheme) {
    final provider = context.watch<RemoteControlProvider>();
    return Column(
      children: [
        RadioListTile<String>(
          title: const Text('自动（TV 设备开启）'),
          value: 'auto',
          groupValue: provider.mode,
          onChanged: (v) {
            if (v != null) {
              // ignore: discarded_futures
              provider.setMode(v);
            }
          },
        ),
        RadioListTile<String>(
          title: const Text('始终开启'),
          value: 'always_on',
          groupValue: provider.mode,
          onChanged: (v) {
            if (v != null) {
              // ignore: discarded_futures
              provider.setMode(v);
            }
          },
        ),
        RadioListTile<String>(
          title: const Text('始终关闭'),
          value: 'always_off',
          groupValue: provider.mode,
          onChanged: (v) {
            if (v != null) {
              // ignore: discarded_futures
              provider.setMode(v);
            }
          },
        ),
      ],
    );
  }

  /// 「歌词推送」三级子页：推送协议 + 共用文本偏好（翻译 / 罗马音 / 优先翻译）。
  Widget _buildLyricPushSubpage(ColorScheme colorScheme) {
    final protocolActive = _lyricPushProtocol != 'none';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          // M3E 字段式下拉：初始选中值由 M3EDropdownItem.selected 表达
          // （M3EDropdownMenu 没有 initialSelection 参数），每次 build 按当前
          // 状态重建 item，控制器 setItems 后即显示正确的当前值。
          child: M3EDropdownMenu<String>(
            items: [
              M3EDropdownItem(
                label: '关闭',
                value: 'none',
                selected: _lyricPushProtocol == 'none',
              ),
              M3EDropdownItem(
                label: 'Lyricon 词幕',
                value: 'lyricon',
                selected: _lyricPushProtocol == 'lyricon',
              ),
              M3EDropdownItem(
                label: _superLyricSupported
                    ? 'SuperLyric（系统级，需 Android 8.0+）'
                    : 'SuperLyric（需 Android 8.0+）',
                value: 'super_lyric',
                selected: _lyricPushProtocol == 'super_lyric',
                disabled: !_superLyricSupported,
              ),
              M3EDropdownItem(
                label: 'LyricInfo',
                value: 'lyric_info',
                selected: _lyricPushProtocol == 'lyric_info',
              ),
            ],
            singleSelect: true,
            // 单选下关闭 chip 动画，当前值才会渲染为可省略的纯文本
            showChipAnimation: false,
            fieldStyle: const M3EDropdownFieldStyle(
              hintText: '选择歌词推送方式',
              // 对应原 isDense + contentPadding
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onSelectionChanged: (selected) {
              // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
              if (selected.isEmpty) {
                setState(() {});
                return;
              }
              final value = selected.first.value;
              if (value == _lyricPushProtocol) return;
              // ignore: discarded_futures
              _setLyricPushProtocol(value);
            },
          ),
        ),
        // 仅 LyricInfo 协议下显示：ColorOS Bridge 兼容字段开关
        if (_lyricPushProtocol == 'lyric_info')
          SwitchListTile(
            title: const Text('ColorOS Bridge 兼容字段'),
            value: _lyricInfoColorOs,
            onChanged: (v) {
              // ignore: discarded_futures
              _setLyricInfoColorOs(v);
            },
          ),
        // 选中 Lyricon 时显示连接状态
        if (_lyricPushProtocol == 'lyricon')
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _getLyriconStateText(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        // 共用偏好：翻译 / 罗马音 / 优先翻译（关闭或无协议时禁用）
        // search: 翻译
        SwitchListTile(
          title: const Text('翻译歌词'),
          value: _lyricPushTranslation,
          onChanged: protocolActive
              ? (value) {
                  // ignore: discarded_futures
                  _setLyricPushTranslation(value);
                }
              : null,
        ),
        // search: 罗马音 拼音
        SwitchListTile(
          title: const Text('罗马音歌词'),
          // 只在协议确实不支持时提示约束，其余情况标题已足够表意。
          // LyricInfo 规范下 roma 是独立 lane，已支持（需歌词源提供罗马音）。
          value: _lyricPushRoma,
          onChanged: protocolActive
              ? (value) {
                  // ignore: discarded_futures
                  _setLyricPushRoma(value);
                }
              : null,
        ),
        // search: 优先 翻译
        SwitchListTile(
          title: const Text('优先翻译（同时存在时）'),
          subtitle: _lyricPushProtocol == 'lyric_info'
              ? const Text('LyricInfo 翻译与罗马音为独立通道，无需取舍')
              : null,
          value: _lyricPushPreferTranslation,
          onChanged: protocolActive && _lyricPushProtocol != 'lyric_info'
              ? (value) {
                  // ignore: discarded_futures
                  _setLyricPushPreferTranslation(value);
                }
              : null,
        ),
      ],
    );
  }

  /// 「设备歌词」三级子页：桌面悬浮歌词、蓝牙歌词、锁屏歌词与魅族状态栏歌词。
  Widget _buildDeviceLyricSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('桌面歌词', colorScheme, first: true),
        // 外观六项配置：字号 / 行式 / 不透明度 / 已唱渐变 / 未唱色 / 锁定。
        // 悬浮窗内的原生面板改配置会经 desktopLyricConfigChanged 回灌到这里，
        // 两端共用 DesktopLyricService 的同一份状态。
        //
        // 这是一个自定义 widget（不是 ListTile 系），不会被 `_tileTypes` 自动收录，
        // 因此用 search-item 手写索引条目 —— 否则搜索框找不到这块配置。
        // search-item: 桌面歌词外观 | 桌面歌词 悬浮窗 悬浮歌词 字号 字体大小 文字大小
        // search-item: 桌面歌词外观 | 双行 单行 行数 透明度 不透明度 背景 黑底
        // search-item: 桌面歌词外观 | 渐变 配色 颜色 已唱 未唱 预设 锁定 解锁 点击穿透
        const DesktopLyricSettingsPanel(),
        _buildGroupLabel('蓝牙歌词', colorScheme),
        // search: 蓝牙
        SwitchListTile(
          title: const Text('蓝牙歌词'),
          value: _bluetoothLyricEnabled,
          onChanged: (value) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _bluetoothLyricEnabled = value);
            await _settingsRepository.setBluetoothLyricEnabled(value);
            // 同步到歌词服务（启停定时器）和原生端（元数据替换开关）
            DesktopLyricService.instance.setBluetoothLyricEnabled(value);
            MediaNotificationService.setBluetoothLyricEnabled(value);
          },
        ),
        // 蓝牙歌词封面压缩：默认关闭。开启后原生刷新用 256px 缩略图，降低系统负载
        // search: 蓝牙 封面 压缩
        SwitchListTile(
          title: const Text('压缩封面图'),
          value: _bluetoothLyricCompressArt,
          onChanged: (value) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _bluetoothLyricCompressArt = value);
            await _settingsRepository.setBluetoothLyricCompressArt(value);
          },
        ),
        _buildGroupLabel('锁屏歌词', colorScheme),
        // search: 锁屏
        SwitchListTile(
          title: const Text('锁屏歌词（实验性）'),
          // 缺权限就完全不生效，属于必要前提；其余行为说明删除
          subtitle: const Text('需开启悬浮窗、后台弹出界面与锁屏通知权限'),
          value: _lockScreenLyricEnabled,
          onChanged: (value) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _lockScreenLyricEnabled = value);
            await _settingsRepository.setLockScreenLyricEnabled(value);
            // 同步到歌词服务（启停定时器）与原生端（开关状态/关闭界面）
            await DesktopLyricService.instance.setLockScreenLyricEnabled(value);
          },
        ),
        if (_flymeStatusBarLyricSupported) ...[
          _buildGroupLabel('魅族状态栏歌词', colorScheme),
          // search: 魅族 flyme 状态栏
          SwitchListTile(
            title: const Text('状态栏歌词'),
            subtitle: const Text('歌词显示在状态栏时钟旁，由 Flyme 系统渲染'),
            value: _flymeStatusBarLyricEnabled,
            onChanged: (value) async {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _flymeStatusBarLyricEnabled = value);
              await _settingsRepository.setFlymeStatusBarLyricEnabled(value);
              // 启停歌词定时器，并把开关与当前行同步到原生
              await DesktopLyricService.instance.setFlymeStatusBarLyricEnabled(
                value,
              );
            },
          ),
          // search: 状态栏 提前 提前量 快 慢
          if (_flymeStatusBarLyricEnabled) const _FlymeLyricAdvanceTile(),
        ],
      ],
    );
  }

  /// 「歌词」二级页尾部：歌词同步。
  /// 仅 1 项，按 R2「短分组内联」原则留在二级页，不产生只有一行的三级页。
  Widget _buildLyricTail(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('歌词同步', colorScheme),
        const _LyricTimeOffsetTile(),
      ],
    );
  }

  /// 切换实时歌词推送协议（三选一 + 关闭）：先全部关闭，再启用选中协议。
  Future<void> _setLyricPushProtocol(String protocol) async {
    if (protocol == _lyricPushProtocol) return;
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _lyricPushProtocol = protocol);
    await _settingsRepository.setLyricPushProtocol(protocol);
    await _applyLyricPushProtocol(protocol);
  }

  /// LyricInfo 的 ColorOS Bridge 兼容模式开关：持久化 + 同步到歌词服务（即时重推）。
  Future<void> _setLyricInfoColorOs(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _lyricInfoColorOs = value);
    await _settingsRepository.setLyricInfoColorOs(value);
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricInfoColorOs(value);
  }

  /// 应用协议选择：关闭所有协议，启用选中协议，并同步偏好到各协议。
  Future<void> _applyLyricPushProtocol(String protocol) async {
    // 先全部关闭（幂等）
    try {
      LyriconProviderService.instance.setEnabled(false);
    } catch (_) {}
    // ignore: discarded_futures
    DesktopLyricService.instance.setSuperLyricEnabled(false);
    // ignore: discarded_futures
    await DesktopLyricService.instance.setLyricInfoEnabled(false);
    // 记录各协议 enabled 状态（兼容 Kotlin restoreLyricon 读 lyricon_enabled）
    await _settingsRepository.setLyriconEnabled(protocol == 'lyricon');
    await _settingsRepository.setSuperLyricEnabled(protocol == 'super_lyric');
    await _settingsRepository.setLyricInfoEnabled(protocol == 'lyric_info');

    if (protocol == 'none') return;

    // 启用选中协议并应用共用偏好
    if (protocol == 'lyricon') {
      try {
        await LyriconProviderService.instance.setDisplayTranslation(
          _lyricPushTranslation,
        );
        await LyriconProviderService.instance.setDisplayRoma(_lyricPushRoma);
        await LyriconProviderService.instance.setEnabled(true);
      } catch (_) {}
    } else if (protocol == 'super_lyric') {
      if (_superLyricSupported) {
        // ignore: discarded_futures
        DesktopLyricService.instance.setSuperLyricEnabled(true);
      }
    } else if (protocol == 'lyric_info') {
      // 先同步 ColorOS 模式再启用推送，避免启动瞬间先推旧格式
      // ignore: discarded_futures
      DesktopLyricService.instance.setLyricInfoColorOs(_lyricInfoColorOs);
      // ignore: discarded_futures
      await DesktopLyricService.instance.setLyricInfoEnabled(true);
    }
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: _lyricPushTranslation,
      roma: _lyricPushRoma,
      preferTranslation: _lyricPushPreferTranslation,
    );
  }

  Future<void> _setLyricPushTranslation(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _lyricPushTranslation = value);
    await _settingsRepository.setLyricPushTranslation(value);
    // 同步到 Lyricon 偏好（兼容 Kotlin 端 restore 读取）
    await _settingsRepository.setLyriconDisplayTranslation(value);
    if (_lyricPushProtocol == 'lyricon') {
      try {
        await LyriconProviderService.instance.setDisplayTranslation(value);
      } catch (_) {}
    }
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: value,
      roma: _lyricPushRoma,
      preferTranslation: _lyricPushPreferTranslation,
    );
  }

  Future<void> _setLyricPushRoma(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _lyricPushRoma = value);
    await _settingsRepository.setLyricPushRoma(value);
    await _settingsRepository.setLyriconDisplayRoma(value);
    if (_lyricPushProtocol == 'lyricon') {
      try {
        await LyriconProviderService.instance.setDisplayRoma(value);
      } catch (_) {}
    }
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: _lyricPushTranslation,
      roma: value,
      preferTranslation: _lyricPushPreferTranslation,
    );
  }

  Future<void> _setLyricPushPreferTranslation(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _lyricPushPreferTranslation = value);
    await _settingsRepository.setLyricPushPreferTranslation(value);
    // 同步到各协议偏好 key
    await _settingsRepository.setLyriconPreferTranslation(value);
    await _settingsRepository.setSuperLyricPreferTranslation(value);
    if (_lyricPushProtocol == 'lyricon') {
      // 偏好变化后重新推送当前歌曲，让过滤逻辑立即生效
      try {
        await LyriconProviderService.instance.repushLastSong();
      } catch (_) {}
    }
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: _lyricPushTranslation,
      roma: _lyricPushRoma,
      preferTranslation: value,
    );
  }

  /// 「车机模式」三级子页：总开关 + 自动检测 + 面板宽/高 + Dock 避让 + 面板位置。
  Widget _buildCarModeSubpage(ColorScheme colorScheme) {
    final carMode = context.watch<CarModeProvider>();
    // 滑条下限随布局切换：底部（竖屏/近方屏车机）10%，侧边 20%。
    // 显示值同样按布局夹取：侧边布局下存量 0.12 若直接喂给滑条会触发
    // value < min 断言。
    final sliderMinRatio = carMode.useBottomLayout
        ? kCarModePanelMinRatioBottom
        : kCarModePanelMinRatio;
    final ratioPercent =
        (carMode.panelRatio.clamp(sliderMinRatio, kCarModePanelMaxRatio) * 100)
            .round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 独立总开关：默认关闭。开启后任何界面（设置页 / 登录页 / 引导页 /
        // 用户协议页除外）常驻一块播放器面板，且不再显示 MiniPlayer。
        // 这是**强制开启**开关：无论屏幕类型都启用。
        // search: 车机 车载 常驻 面板 大屏 副屏 副驾 miniplayer 迷你条
        SwitchListTile(
          title: const Text('车机模式'),
          subtitle: const Text('任何界面常驻播放器面板，不再显示 MiniPlayer'),
          value: carMode.enabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            context.read<CarModeProvider>().setEnabled(value);
          },
        ),
        // 自动检测开关：独立于上面的强制开关。开启后按屏幕长比自动判断，
        // 命中车机屏（短边/长边 ≥ 0.55，常见 16:9 车机即满足）即自动启用。
        // search: 车机 车载 自动 检测 屏幕 分辨率 识别 竖屏 方屏
        SwitchListTile(
          title: const Text('检测到车机屏幕时自动开启'),
          subtitle: const Text('匹配竖屏或方屏车机等车载屏幕时自动启用车机模式'),
          value: carMode.autoScreenEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            context.read<CarModeProvider>().setAutoScreenEnabled(value);
          },
        ),
        _buildGroupLabel(
          carMode.useBottomLayout ? '面板高度' : '面板宽度',
          colorScheme,
          first: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题随布局切换：侧边 =「面板宽度」（横贯左侧/右侧、只调宽），
              // 底部 =「面板高度」（横贯全宽、只调高）。两者共用同一个占比值
              // （panelRatio），通过 resolveCarModePanelWidth / Height 换算成
              // 不同的物理尺寸。search: 面板宽度 面板高度 车机 底部
              Row(
                children: [
                  Expanded(
                    child: Text(
                      carMode.useBottomLayout ? '面板高度' : '面板宽度',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  Text(
                    '$ratioPercent%',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 滑条始终显示（两布局共用），拖动只改内存，松手落盘。
              // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞四方向键；
              // TV 分支丢 M3ESliderDecoration 触觉参数（P-C，下同）
              kTvBuild
                  ? RemoteSlider(
                      value:
                          carMode.panelRatio.clamp(
                            sliderMinRatio,
                            kCarModePanelMaxRatio,
                          ) *
                          100,
                      // 底部布局（竖屏/近方屏车机）下限 10%，侧边保持 20%。
                      min: sliderMinRatio * 100,
                      max: kCarModePanelMaxRatio * 100,
                      label: '$ratioPercent%',
                      onChanged: (value) => context
                          .read<CarModeProvider>()
                          .setPanelRatio(value / 100, persist: false),
                      onChangeEnd: (value) => context
                          .read<CarModeProvider>()
                          .setPanelRatio(value / 100),
                    )
                  : M3ESlider(
                      decoration: const M3ESliderDecoration(
                        // 显式给 hapticConfig：M3ESlider 在 divisions == null 时默认取
                        // M3EHapticConfig.continuous()（10ms 最小间隔 + 2% 阈值），
                        // 拖动中会以最高约 100 次/秒走 MethodChannel 触发 vibrate，
                        // 真机上马达饱和 + 通道洪泛。
                        haptic: M3EHapticFeedback.medium,
                        hapticConfig: M3EHapticConfig.discrete(),
                      ),
                      value:
                          carMode.panelRatio.clamp(
                            sliderMinRatio,
                            kCarModePanelMaxRatio,
                          ) *
                          100,
                      // 底部布局（竖屏/近方屏车机）下限 10%，侧边保持 20%。
                      min: sliderMinRatio * 100,
                      max: kCarModePanelMaxRatio * 100,
                      // 不传 divisions = 无级调节（M3ESlider.divisions 为 int?），
                      // 有档位吸附会破坏「无级」手感。
                      label: '$ratioPercent%',
                      // 拖动中只改内存（persist: false），松手才落盘。
                      // 注意：divisions == null 时 M3ESlider 的 onChangeEnd 可能在
                      // 按下超过 100ms 后被 tap-cancel 提前触发一次（见
                      // _DisplayScaleTile 的注释）。这里提前落盘的只是一个 double，
                      // 不影响手感，真正的终值会在拖动结束时再落一次。
                      onChanged: (value) => context
                          .read<CarModeProvider>()
                          .setPanelRatio(value / 100, persist: false),
                      onChangeEnd: (value) =>
                          context.read<CarModeProvider>().setPanelRatio(value / 100),
                    ),
            ],
          ),
        ),
        // Dock 避让高度校准：仅底部布局（面板贴屏幕下缘）有意义 —— 车联
        // dock 栏是系统悬浮窗、不产生 WindowInsets，SafeArea 挡不住，只能
        // 由用户按 dock 实际高度校准（见 kCarModeBottomDockClearance 注释）。
        // search-item: dock 避让高度 | 车机 车联 dock 避让 底部 空隙 高度
        if (carMode.useBottomLayout) ...[
          _buildGroupLabel('Dock 避让高度', colorScheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '底部面板与屏幕下缘留出的空隙，用于避开车联 dock 栏；0 为不避让',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    // tv: TV 构建换 RemoteSlider（P-C）
                    Expanded(
                      child: kTvBuild
                          ? RemoteSlider(
                              value: carMode.dockClearanceDp,
                              min: 0,
                              max: kCarModeDockClearanceMax,
                              divisions: kCarModeDockClearanceMax.round(),
                              label: '${carMode.dockClearanceDp.round()}dp',
                              onChanged: (value) => context
                                  .read<CarModeProvider>()
                                  .setDockClearance(value, persist: false),
                              onChangeEnd: (value) => context
                                  .read<CarModeProvider>()
                                  .setDockClearance(value),
                            )
                          : M3ESlider(
                              decoration: const M3ESliderDecoration(
                                haptic: M3EHapticFeedback.medium,
                                hapticConfig: M3EHapticConfig.discrete(),
                              ),
                              value: carMode.dockClearanceDp,
                              min: 0,
                              max: kCarModeDockClearanceMax,
                              // 1dp 一档：整数值好读好记，档位 haptic 也与
                              // M3EHapticConfig.discrete() 匹配。
                              divisions: kCarModeDockClearanceMax.round(),
                              label: '${carMode.dockClearanceDp.round()}dp',
                              onChanged: (value) => context
                                  .read<CarModeProvider>()
                                  .setDockClearance(value, persist: false),
                              onChangeEnd: (value) => context
                                  .read<CarModeProvider>()
                                  .setDockClearance(value),
                            ),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        carMode.dockClearanceDp <= 0
                            ? '不避让'
                            : '${carMode.dockClearanceDp.round()}dp',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        // 面板位置仅在侧边布局下有意义（底部布局面板横贯全宽）。
        if (!carMode.useBottomLayout) _buildGroupLabel('面板位置', colorScheme),
        if (!carMode.useBottomLayout)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            // search-item: 面板位置 | 车机 面板 左侧 右侧 停靠 位置
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(
                  label: Text('左侧'),
                  icon: Icon(Icons.align_horizontal_left),
                ),
                M3EToggleButtonGroupAction(
                  label: Text('右侧'),
                  icon: Icon(Icons.align_horizontal_right),
                ),
              ],
              selectedIndex: carMode.panelSide == CarModePanelSide.left ? 0 : 1,
              onSelectedIndexChanged: (index) {
                if (index == null || !carMode.active) return;
                AppHaptics.lightImpact(HapticCategory.control);
                context.read<CarModeProvider>().setPanelSide(
                  index == 0 ? CarModePanelSide.left : CarModePanelSide.right,
                );
              },
            ),
          ),
        if (!carMode.active)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Text(
              '开启车机模式或检测到车机屏幕后生效',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          const Gap(AppSpacing.lg),
      ],
    );
  }

  /// 「主题与配色」三级子页：明暗模式 + 主题色来源。
  Widget _buildThemeSubpage(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    // 仅 ThemeMode.light 时禁用 OLED 开关；dark 与 system 均可勾选。
    // system 模式下勾选后，等系统切到深色时 darkTheme 自动应用纯黑（MaterialApp 机制）。
    // 以 ThemeProvider 为准（单一数据源），避免与本地 _themeMode 双份不同步
    final canToggleOled =
        context.watch<ThemeProvider>().themeMode != ThemeMode.light;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('主题模式', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          // 注意：按钮顺序(浅色/深色/跟随系统)与 ThemeMode.index(system=0,light=1,dark=2)
          // 不一致，必须用显式映射，不能直接 ThemeMode.values[index]，否则切换错位。
          child: M3EToggleButtonGroup(
            actions: const [
              M3EToggleButtonGroupAction(
                label: Text('浅色'),
                icon: Icon(Icons.light_mode),
              ),
              M3EToggleButtonGroupAction(
                label: Text('深色'),
                icon: Icon(Icons.dark_mode),
              ),
              M3EToggleButtonGroupAction(
                label: Text('跟随系统'),
                icon: Icon(Icons.brightness_auto),
              ),
            ],
            selectedIndex: const [
              ThemeMode.light,
              ThemeMode.dark,
              ThemeMode.system,
            ].indexOf(context.watch<ThemeProvider>().themeMode),
            onSelectedIndexChanged: (index) {
              if (index == null) return;
              const modes = [ThemeMode.light, ThemeMode.dark, ThemeMode.system];
              // 单源：以 ThemeProvider 为准（即时生效 + 自行持久化）
              context.read<ThemeProvider>().setThemeMode(modes[index]);
            },
          ),
        ),
        // OLED 纯黑开关：light 模式禁用；dark 与 system 可勾选。
        // system 模式下勾选后，系统切深色时自动生效，切浅色时不影响 lightTheme。
        // search: oled 纯黑 深色 黑色
        SwitchListTile(
          title: const Text('OLED 纯黑深色'),
          value: themeProvider.useOledBlack,
          onChanged: canToggleOled
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  themeProvider.setUseOledBlack(v);
                }
              : null,
        ),
        // ② 配色来源：自动取色（系统壁纸 / 封面）优先，两者都关闭时才用手动
        // 种子色，因此「主题色」排在两个自动来源之后，作为兜底项。
        _buildGroupLabel('主题配色', colorScheme),
        // search: 系统主题 壁纸 莫奈
        SwitchListTile(
          title: const Text('使用系统主题色'),
          value: _useDynamicColor,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useDynamicColor = v);
            context.read<ThemeProvider>().setUseDynamicColor(v);
          },
        ),
        // search: 动态取色 封面
        SwitchListTile(
          title: const Text('封面动态取色'),
          value: _useCoverSeedColor,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useCoverSeedColor = v);
            context.read<ThemeProvider>().setUseCoverSeedColor(v);
          },
        ),
        // 主题色入口：点击弹出 8 色预设面板。
        // 系统主题色 / 封面动态取色 / 背景莫奈取色开启时用 IgnorePointer 禁用点击
        // （不灰显，色块仍显示当前 effectiveSeedColor）。
        IgnorePointer(
          ignoring:
              themeProvider.useDynamicColor ||
              themeProvider.useCoverSeedColor ||
              (themeProvider.isBackgroundImageEffective &&
                  themeProvider.useBackgroundMonet),
          // search: 主题 颜色 换肤 hex 十六进制 色号 取色
          child: ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('主题色'),
            subtitle: Text(
              themeProvider.useCoverSeedColor
                  ? '跟随歌曲封面取色'
                  : ((themeProvider.isBackgroundImageEffective &&
                            themeProvider.useBackgroundMonet)
                        ? '跟随背景图片取色'
                        : (themeProvider.useDynamicColor
                              ? '跟随系统壁纸取色'
                              : '手动选择种子色')),
            ),
            trailing: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: themeProvider.effectiveSeedColor,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.outline, width: 1.5),
              ),
            ),
            onTap: () => _showSeedColorPicker(themeProvider),
          ),
        ),
      ],
    );
  }

  /// 「字体与显示」三级子页：全局字体来源 + 强调排版 + 显示大小。
  Widget _buildFontDisplaySubpage(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // app全局字体入口：点击弹出两选一面板（系统 / 自定义 TTF）
        // 选择"自定义"时打开 Android SAF 文件选择器选 .ttf/.otf 文件
        // search: 字体
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('app全局字体'),
          subtitle: Text(_getFontSourceLabel(themeProvider.fontSource)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showFontSourceSheet(themeProvider),
        ),
        // 「强调排版」开关（默认开启）：M3E 排版，统一提升标题与正文字重。
        // 关闭后回退常规字重，用于对字体观感敏感时的回退。
        // search: 强调排版 m3e 字重 typography
        SwitchListTile(
          title: const Text('强调排版'),
          subtitle: const Text('M3E 排版：提升标题与正文字重，突出层级'),
          value: themeProvider.emphasizedTypographyEnabled,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            context.read<ThemeProvider>().setEmphasizedTypographyEnabled(v);
          },
        ),
        // 「显示大小」滑块单独抽成 StatefulWidget：拖动中的中间值只重建这一小块。
        // 若放在设置页里用 setState 承接，每个 drag update 都会重建整页三千余行的
        // 元素树，滑块自身的手势识别器可能被连带重建 → 拖动中途"断触"、
        // onChangeEnd 提前触发（手还没抬就应用并弹确认框）。
        const _DisplayScaleTile(),
      ],
    );
  }

  /// 「导航与布局」三级子页：底部导航栏标签行为 + 桌面布局外壳 + 悬浮播放器 + 预测性返回手势。
  Widget _buildShellLayoutSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('底部导航栏', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: M3EToggleButtonGroup(
            actions: const [
              M3EToggleButtonGroupAction(
                label: Text('始终显示'),
                icon: Icon(Icons.label),
              ),
              M3EToggleButtonGroupAction(
                label: Text('仅当前页'),
                icon: Icon(Icons.tab_unselected),
              ),
              M3EToggleButtonGroupAction(
                label: Text('始终不显示'),
                icon: Icon(Icons.label_off),
              ),
            ],
            selectedIndex: const [
              NavigationDestinationLabelBehavior.alwaysShow,
              NavigationDestinationLabelBehavior.onlyShowSelected,
              NavigationDestinationLabelBehavior.alwaysHide,
            ].indexOf(context.watch<ThemeProvider>().navLabelBehavior),
            onSelectedIndexChanged: (index) {
              if (index == null) return;
              const behaviors = [
                NavigationDestinationLabelBehavior.alwaysShow,
                NavigationDestinationLabelBehavior.onlyShowSelected,
                NavigationDestinationLabelBehavior.alwaysHide,
              ];
              context.read<ThemeProvider>().setNavLabelBehavior(
                behaviors[index],
              );
            },
          ),
        ),
        // search: 二级页面 详情页 隐藏底栏 收起导航栏 菜单底栏 底部导航栏 保留导航栏 secondary page hide navigation bar
        SwitchListTile(
          title: const Text('二级页面隐藏菜单底栏'),
          subtitle: const Text(
            '停在二级页面（及以后）时收起底部导航栏；关闭后始终保留。'
            '仅影响竖屏底栏，横屏侧栏仍在二级页面收起',
          ),
          value: _hideNavBarOnSecondary,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _hideNavBarOnSecondary = value);
            _settingsRepository.setHideNavBarOnSecondaryPages(value);
            // 立即生效：主布局订阅该判定源重算底栏显隐。
            kHideNavBarOnSecondaryPages.value = value;
          },
        ),
        // ⑤ 桌面布局：侧栏外壳总开关（默认关，开启后横竖屏皆用）
        _buildGroupLabel('桌面布局', colorScheme),
        // search: 桌面布局 侧栏 大屏 平板 横屏 双栏 工具栏 desktop
        // value 直读全局判定源 kDesktopModeEnabled（唯一真值），用
        // ValueListenableBuilder 订阅 —— 与下方「悬浮播放器」同一模式。
        //
        // 此前用本页本地字段，导致开关与实际生效状态可以相反：
        // app.dart 冷启动写全局源、本页 _loadSettings 写本地字段，
        // 两条路径互不知情，用户会看到"实际开着桌面布局、开关却是关的"。
        ValueListenableBuilder<bool>(
          valueListenable: kDesktopModeEnabled,
          builder: (context, desktopEnabled, _) => SwitchListTile(
            title: const Text('桌面布局'),
            subtitle: Text(
              desktopEnabled
                  ? '正在使用侧栏界面，关闭后恢复为底部导航栏'
                  : '开启后无论横屏竖屏都使用侧栏界面',
            ),
            value: desktopEnabled,
            onChanged: (value) {
              AppHaptics.lightImpact(HapticCategory.control);
              // 立即切换外壳：驱动全局判定源，触发主布局重建。
              kDesktopModeEnabled.value = value;
              _settingsRepository.setDesktopModeEnabled(value);
            },
          ),
        ),
        // ⑥ 悬浮播放器：形态总开关 + 两项从属设置，就地成组
        _buildGroupLabel('悬浮播放器', colorScheme),
        // search: 悬浮播放器 悬浮迷你播放器 迷你播放器 二级页面 播放栏 圆盘 浮动 关闭 secondary mini player
        // 总开关 value 直读全局判定源 kSecondaryPlayerEnabled（唯一真值，取代旧的
        // 本页本地字段双份真值）；局部 ValueListenableBuilder 订阅，不新增 setState 源。
        // TV 构建下 notifier 被装载处强制 false（app.dart / main.dart 两处门控），
        // 本开关置灰不可点：既不写持久化也不写 notifier，切回手机版不丢设置。
        ValueListenableBuilder<bool>(
          valueListenable: kSecondaryPlayerEnabled,
          builder: (context, secondaryEnabled, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                title: const Text('悬浮迷你播放器'),
                subtitle: Text(
                  kTvBuild
                      ? 'TV 版固定使用常驻播放条，悬浮形态在电视上不可用'
                      : secondaryEnabled
                      ? '正在使用悬浮播放条，下面两项决定它的形态'
                      : '关闭后所有页面统一使用底部常驻播放条',
                ),
                value: secondaryEnabled,
                onChanged: kTvBuild
                    ? null
                    : (value) {
                        AppHaptics.lightImpact(HapticCategory.control);
                        _settingsRepository.setSecondaryPlayerEnabled(value);
                        // 立即生效：驱动全局判定源，各页宿主随 ValueListenableBuilder 重建。
                        kSecondaryPlayerEnabled.value = value;
                      },
              ),
              // 从属项：总开关关闭时同时给 enabled=false 与 onChanged=null ——
              // 前者置灰整行、后者真正禁用开关，避免"看着能点、点了没反应"。
              // TV 下 secondaryEnabled 恒为 false，两项自然置灰，无需另加门控。
              // search: 一级页面 主页 首页 标签页 底部常驻 退回常驻条 分级 悬浮底栏 primary page tab
              SwitchListTile(
                title: const Text('一级页面使用悬浮底栏'),
                subtitle: const Text('关闭后主页各标签页退回底部常驻播放条（贴在导航栏上方），只有二级页面用悬浮条'),
                value: _secondaryPlayerOnPrimary,
                onChanged: secondaryEnabled
                    ? (value) {
                        AppHaptics.lightImpact(HapticCategory.control);
                        setState(() => _secondaryPlayerOnPrimary = value);
                        _settingsRepository.setSecondaryPlayerOnPrimary(value);
                        // 立即生效：宿主与 shell 的常驻条都订阅了这个判定源。
                        kSecondaryPlayerOnPrimaryPages.value = value;
                      }
                    : null,
              ),
              // search: 进度条 进度 悬浮进度 播放进度 包边 外圈进度环 胶囊进度 secondary player progress
              SwitchListTile(
                title: const Text('显示播放进度'),
                subtitle: const Text('沿播放条内缘包边一圈显示进度；收起成圆盘时即为其外圈进度环'),
                value: _secondaryPlayerProgress,
                onChanged: secondaryEnabled
                    ? (value) {
                        AppHaptics.lightImpact(HapticCategory.control);
                        setState(() => _secondaryPlayerProgress = value);
                        _settingsRepository.setSecondaryPlayerProgress(value);
                        kSecondaryPlayerProgressEnabled.value = value;
                      }
                    : null,
              ),
            ],
          ),
        ),
        // ⑦ 预测性返回手势：系统返回手势期间预览上一页（仅 Android 14+ 手势导航生效）
        //桌面端（Windows/macOS/Linux）没有 Android 的系统返回手势导航，
        // 该开关永远不生效，整块隐藏而不是显示"仅 Android 支持"的死开关。
        if (supportsPredictiveGesture) ...[
          _buildGroupLabel('预测性返回手势', colorScheme),
          // search: 预测性返回 预测返回 返回手势 手势导航 系统返回 返回预览 predictive back 互斥
          SwitchListTile(
            title: const Text('预测性返回手势'),
            subtitle: const Text(
              '系统返回手势期间实时预览上一页（需 Android 14 及以上、手势导航模式；'
              '播放页等使用自定义返回动画的页面不受影响）。'
              '与「封面连贯过渡」互斥，且封面连贯过渡优先：后者开着时本项开不了，'
              '需先关闭封面连贯过渡',
            ),
            value: _predictiveBackEnabled,
            onChanged: (value) => _applyCoverBackExclusivity(
              coverTransition: _playlistCoverTransition,
              predictiveBack: value,
            ),
          ),
        ],
        // ⑧ 封面连贯过渡：列表卡片封面飞进详情页头（共享元素，歌单/专辑共用）
        _buildGroupLabel('封面连贯过渡', colorScheme),
        // search: 封面过渡 连贯过渡 共享元素 封面动画 卡片放大 歌单详情封面 专辑封面 大封面 hero flight 互斥
        SwitchListTile(
          title: const Text('封面连贯过渡'),
          subtitle: const Text(
            '从歌单/专辑/听书列表进入详情页时，卡片封面平滑放大飞入页头（返回时原路飞回）；'
            '关闭后只保留页面自身的转场。与「预测性返回手势」互斥：'
            '开启本项会自动关闭预测性返回',
          ),
          value: _playlistCoverTransition,
          onChanged: (value) => _applyCoverBackExclusivity(
            coverTransition: value,
            predictiveBack: _predictiveBackEnabled,
          ),
        ),
      ],
    );
  }

  /// 界面背景三级子页：全局自定义背景图片
  /// （开关 / 选图 / 清除 / 预览 / 模糊 / 透明度）。
  ///
  /// 启用后全局页面表面的 Scaffold/AppBar 等变为透明，底层模糊背景图透出；
  /// 同时自动按背景图提取主色作为莫奈取色种子（封面动态取色开启时仍优先）。
  Widget _buildBackgroundSubpage(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    final hasImage =
        _backgroundImagePath != null &&
        _backgroundImagePath!.isNotEmpty &&
        File(_backgroundImagePath!).existsSync();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 背景 图片 壁纸
        SwitchListTile(
          title: const Text('启用自定义背景图片'),
          value: _useBackgroundImage,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useBackgroundImage = v);
            // ignore: discarded_futures
            themeProvider.setUseBackgroundImage(v);
          },
        ),
        // 图片本身：选图 → 预览 → 清除 → 模糊 → 透明度（先有图，再调图）
        // 标题随是否已选图切换，索引固定按「选择背景图片」登记
        // search-item: 选择背景图片 | 背景 图片 选择 更换
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(hasImage ? '更换背景图片' : '选择背景图片'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _pickBackgroundImage,
        ),
        // 实时预览：按当前模糊 / 透明度渲染（无用户图片时显示内置默认壁纸）
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: ClipRRect(
            borderRadius: AppRadius.mdAll,
            child: SizedBox(
              height: 120,
              width: double.infinity,
              child: Opacity(
                opacity: _backgroundOpacity,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: tvBlurSigma(_backgroundBlur),
                    sigmaY: tvBlurSigma(_backgroundBlur),
                  ),
                  child: hasImage
                      ? Image.file(
                          File(_backgroundImagePath!),
                          fit: BoxFit.cover,
                          // 限制解码宽度，避免选高分辨率照片时全尺寸解码导致内存峰值闪退
                          cacheWidth: 800,
                        )
                      : Image.asset(
                          kDefaultWallpaperAsset,
                          fit: BoxFit.cover,
                          cacheWidth: 800,
                        ),
                ),
              ),
            ),
          ),
        ),
        if (hasImage)
          // search: 背景 图片 清除 移除
          ListTile(
            leading: Icon(
              Icons.cleaning_services_outlined,
              color: colorScheme.error,
            ),
            title: const Text('清除背景图片'),
            onTap: _clearBackgroundImage,
          ),
        // 模糊程度滑块
        // search-item: 背景图片模糊 | 模糊 高斯模糊 背景
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.blur_on, color: colorScheme.onSurfaceVariant),
              const Gap(AppSpacing.md),
              Expanded(
                // tv: TV 构建换 RemoteSlider（P-C）
                child: kTvBuild
                    ? RemoteSlider(
                        value: _backgroundBlur,
                        min: 0,
                        max: 30,
                        label: '${_backgroundBlur.round()}',
                        onChanged: (v) => setState(() => _backgroundBlur = v),
                        onChangeEnd: (v) => themeProvider.setBackgroundBlur(v),
                      )
                    : M3ESlider(
                        value: _backgroundBlur,
                        min: 0,
                        max: 30,
                        // 界面背景控件不显示节点
                        label: '${_backgroundBlur.round()}',
                        onChanged: (v) => setState(() => _backgroundBlur = v),
                        onChangeEnd: (v) => themeProvider.setBackgroundBlur(v),
                      ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${_backgroundBlur.round()}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 透明度滑块
        // search-item: 背景图片透明度 | 透明度 背景
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.opacity, color: colorScheme.onSurfaceVariant),
              const Gap(AppSpacing.md),
              Expanded(
                // tv: TV 构建换 RemoteSlider（P-C）
                child: kTvBuild
                    ? RemoteSlider(
                        value: _backgroundOpacity,
                        min: 0.2,
                        max: 1.0,
                        label: '${(_backgroundOpacity * 100).round()}%',
                        onChanged: (v) {
                          setState(() => _backgroundOpacity = v);
                          // 实时同步到全局背景（ThemeProvider notify → AppBackgroundLayer 重建）
                          // ignore: discarded_futures
                          themeProvider.setBackgroundOpacity(v);
                        },
                      )
                    : M3ESlider(
                        value: _backgroundOpacity,
                        min: 0.2,
                        max: 1.0,
                        // 界面背景控件不显示节点
                        label: '${(_backgroundOpacity * 100).round()}%',
                        onChanged: (v) {
                          setState(() => _backgroundOpacity = v);
                          // 实时同步到全局背景（ThemeProvider notify → AppBackgroundLayer 重建）
                          // ignore: discarded_futures
                          themeProvider.setBackgroundOpacity(v);
                        },
                      ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${(_backgroundOpacity * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 图片的衍生效果：先取色，再管背景图上的文字可读性
        // search: 莫奈 取色 动态取色 背景
        SwitchListTile(
          title: const Text('按背景图莫奈取色'),
          value: _useBackgroundMonet,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useBackgroundMonet = v);
            // ignore: discarded_futures
            themeProvider.setUseBackgroundMonet(v);
          },
        ),
        // 文字阴影：只有启用背景图时才可用（关闭背景图时开关置灰，保留用户选择）
        // search: 阴影 文字 可读性 背景 壁纸
        SwitchListTile(
          title: const Text('文字阴影'),
          // 开关被置灰时才说明原因，可用状态下标题已表意
          subtitle: _useBackgroundImage ? null : const Text('需先启用自定义背景图片'),
          value: _useTextShadow,
          onChanged: _useBackgroundImage
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _useTextShadow = v);
                  // ignore: discarded_futures
                  themeProvider.setUseTextShadow(v);
                }
              : null,
        ),
        // 阴影磅数：阴影本身没生效时置灰（与「文字阴影」开关同一套约定，
        // 保留用户已选的磅数）
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                Icons.text_fields,
                color: (_useBackgroundImage && _useTextShadow)
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
              ),
              const SizedBox(width: 50),
              Expanded(
                // tv: TV 构建换 RemoteSlider——置灰态（M3ESlider.enabled=false
                // 不参与焦点）仍走 M3ESlider，可调态才换 RemoteSlider（P-C）
                child: (_useBackgroundImage && _useTextShadow)
                    ? (kTvBuild
                        ? RemoteSlider(
                            value: _textShadowBlur,
                            min: AppTheme.minTextShadowBlur,
                            max: AppTheme.maxTextShadowBlur,
                            label: _textShadowBlur.toStringAsFixed(1),
                            // 拖动只动滑块，松手才提交：改磅数要整棵主题树重建
                            onChanged: (v) => setState(() => _textShadowBlur = v),
                            onChangeEnd: (v) => themeProvider.setTextShadowBlur(v),
                          )
                        : M3ESlider(
                            value: _textShadowBlur,
                            min: AppTheme.minTextShadowBlur,
                            max: AppTheme.maxTextShadowBlur,
                            // 不传 divisions：磅数无极（连续）调节
                            enabled: _useBackgroundImage && _useTextShadow,
                            label: _textShadowBlur.toStringAsFixed(1),
                            // 拖动只动滑块，松手才提交：改磅数要整棵主题树重建
                            onChanged: (v) => setState(() => _textShadowBlur = v),
                            onChangeEnd: (v) => themeProvider.setTextShadowBlur(v),
                          ))
                    : M3ESlider(
                        value: _textShadowBlur,
                        min: AppTheme.minTextShadowBlur,
                        max: AppTheme.maxTextShadowBlur,
                        // 不传 divisions：磅数无极（连续）调节
                        enabled: _useBackgroundImage && _useTextShadow,
                        label: _textShadowBlur.toStringAsFixed(1),
                        // 拖动只动滑块，松手才提交：改磅数要整棵主题树重建
                        onChanged: (v) => setState(() => _textShadowBlur = v),
                        onChangeEnd: (v) => themeProvider.setTextShadowBlur(v),
                      ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  _textShadowBlur.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: (_useBackgroundImage && _useTextShadow)
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 打开系统图片选择器选择背景图；选中后应用路径（app.dart 桥接自动莫奈取色）。
  Future<void> _pickBackgroundImage() async {
    final path = await BackgroundImageLoader.pickBackgroundImage();
    if (path == null || path.isEmpty || !mounted) return;
    // 换图时清掉上一张残留（Windows 端按时间戳命名，会越攒越多）
    // ignore: discarded_futures
    BackgroundImageLoader.cleanUpExcept(path);
    setState(() => _backgroundImagePath = path);
    await context.read<ThemeProvider>().setBackgroundImagePath(path);
    showToast('背景图片已设置，已自动莫奈取色', long: true);
  }

  /// 清除背景图片：删除本地文件并回到内置默认壁纸（开关保持开启，
  /// 避免进入"无背景"状态导致浅色模式配色异常）。
  Future<void> _clearBackgroundImage() async {
    final path = _backgroundImagePath;
    // Windows 端每次换图都写新的时间戳文件，只删当前这张会让旧图全部残留
    // （换N 次留下 N-1 张高分辨率照片，磁盘很容易上 GB）。
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    // 兜底清一遍目录里其余残留
    // ignore: discarded_futures
    BackgroundImageLoader.cleanUpExcept(null);
    if (!mounted) return;
    setState(() {
      _backgroundImagePath = null;
      _useBackgroundImage = true;
    });
    final themeProvider = context.read<ThemeProvider>();
    await themeProvider.setBackgroundImagePath(null);
    await themeProvider.setUseBackgroundImage(true);
    showToast('已清除背景图片，使用默认壁纸', long: true);
  }

  /// 「播放页样式」二级页置顶内容：风格选择卡。
  /// 风格决定各子页内专属项的可用性，按 R3 必须常驻可见、不下钻。
  Widget _buildPlayerStyleLeading(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('播放页风格', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: _buildStyleCards(colorScheme),
        ),
      ],
    );
  }

  /// 「播放页样式」二级页尾部内容：歌词动画入口。
  /// 歌词动画已是独立整屏页（LyricAnimationSettingsPage），若再挂到
  /// 「歌词效果」子页下会形成四级导航，故按 R5 保留在二级页。
  Widget _buildPlayerStyleTail(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 歌词动画子页内的设置项在本页没有对应 tile，用手写条目补索引。
        // 必须挂在非 tile 节点上：生成器遇到 search-item 注释所在的 tile 会
        // 走手写分支、跳过该 tile 的标题自动收集（丢「歌词动画」自身条目）。
        // search-item: 歌词模糊强度 | 歌词 模糊 强度 程度 高斯模糊
        // search-item: 辉光触发阈值 | 辉光 发光 阈值 灵敏度
        _buildGroupLabel('歌词动效调节', colorScheme),
        // 歌词动画入口：动画参数、歌词模糊强度、辉光触发阈值统一在独立子页无极调节，
        // 排在歌词省电模式（特效兜底开关）之后、音乐频谱分组之前。
        // search: 歌词 动画 当前行 上浮 非当前行 缩放 位置 错峰 步长 衰减
        ListTile(
          leading: const Icon(Icons.animation),
          title: const Text('歌词动画'),
          subtitle: const Text('动画细节 · 模糊强度 · 辉光阈值'),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const LyricAnimationSettingsPage(),
            ),
          ),
        ),
      ],
    );
  }

  /// 「顶栏与页签」三级子页：播放页 chrome 的三个形态开关。
  ///
  /// 三者共同决定「控制带在哪、顶栏尾部长什么样、页签条落在哪一栏」，所以放在同一页；
  /// 都只改形态不改播放链路，默认值见 `test/data/player_switch_defaults_test.dart`。
  Widget _buildPlayerChromeSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 宽屏（横屏/平板）下把进度/传输控制移入独立「控制」页签，歌词/歌单占满整栏；
        // 默认关闭 = 控制带常驻右栏底部
        // search: 控制面板 独立页 控制页 横屏 平板 控制带
        SwitchListTile(
          title: const Text('横屏控制面板独立页'),
          subtitle: const Text('宽屏下播放控制移入独立页签'),
          value: _landscapeDetachedControls,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _landscapeDetachedControls = value);
            _settingsRepository.setLandscapeDetachedControls(value);
            kLandscapeDetachedControlsEnabled.value = value;
          },
        ),
        // 竖屏顶栏尾部：睡眠定时 / 一起听与 ⋯ 合成一颗只露图标的胶囊，点一下展开、
        // 停留 3 秒自动收回；关闭后这两格文案常显、点一下直接执行，背景仍是同一颗胶囊。
        // 音质格不归本开关管：它只看旁边还有没有别的格（邻居在就收，没邻居就常显）。
        // search: 胶囊 收缩 顶栏 音质 一起听 睡眠 定时 更多 图标
        SwitchListTile(
          title: const Text('胶囊按钮收缩'),
          subtitle: const Text('顶栏尾部的定时与一起听收进图标胶囊，点击展开（音质按邻居自行收放）'),
          value: _topBarPillCollapse,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _topBarPillCollapse = value);
            _settingsRepository.setTopBarPillCollapse(value);
            // 全局标志即时同步：播放器顶栏订阅它，改完回到播放页就是新形态
            kTopBarPillCollapseEnabled.value = value;
          },
        ),
        // 页签条位置与形态（竖屏、横屏同源）：默认关闭 = 竖屏留在底部、横屏留在右栏
        // 底部，且都是原 icon + 指示线形态；开启 = 竖屏底部那条取消、改为顶栏中央的
        // 一排圆点，横屏右栏底部同时改为圆点
        // search: 圆点 页签 顶栏 底部 图标 标签 tab 切换页面 播放页
        SwitchListTile(
          title: const Text('顶栏页签圆点'),
          subtitle: const Text('页签条默认用图标（竖屏在底部、横屏在右栏底部）；开启后改用圆点，竖屏移到顶栏中央'),
          value: _topBarTabDots,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _topBarTabDots = value);
            _settingsRepository.setTopBarTabDots(value);
            // 全局标志即时同步：播放器顶栏与底部控制列各自订阅它
            kTopBarTabDotsEnabled.value = value;
          },
        ),
      ],
    );
  }

  /// 「封面与动态」三级子页：歌词双击跳转 + 专辑动态封面 + 3D 深度封面。
  Widget _buildCoverDynamicSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 双击 跳转
        SwitchListTile(
          title: const Text('歌词双击跳转'),
          value: _lyricDoubleTapToJump,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _lyricDoubleTapToJump = v);
            context.read<ThemeProvider>().setLyricDoubleTapToJump(v);
          },
        ),
        // 全屏播放器专辑封面播放专辑动态封面短视频（MD/AM 两种风格通用）
        // search: 动态封面 专辑封面 短视频 全屏播放器 封面动画
        SwitchListTile(
          title: const Text('专辑动态封面'),
          subtitle: const Text('全屏播放器封面播放专辑动态封面短视频'),
          value: _dynamicAlbumCover,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _dynamicAlbumCover = value);
            _settingsRepository.setDynamicAlbumCover(value);
          },
        ),
        // 动态封面单首约 9.5MB，默认仅 Wi-Fi 自动加载；开启后移动网络也会加载
        // search: 动态封面 移动网络 流量 蜂窝 wifi
        SwitchListTile(
          title: const Text('移动网络下加载动态封面'),
          subtitle: const Text('动态封面单首约 9.5MB，开启后移动网络也会加载'),
          value: _dynamicAlbumCoverOnMobile,
          // 主开关关闭时禁用子开关（此 Flutter 版本的 SwitchListTile 无 enabled
          // 参数，故用 null onChanged 实现等价禁用外观与交互）
          onChanged: _dynamicAlbumCover
              ? (value) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _dynamicAlbumCoverOnMobile = value);
                  _settingsRepository.setDynamicAlbumCoverOnMobile(value);
                }
              : null,
        ),
        // 3D 封面（深度视差）：仅 depth3d 全量包启用；standard 包整体隐藏。
        // 封面投影强度：0 关掉整层投影。播放页读的是全局
        // kCoverShadowIntensity（PlayerCoverShadow.wrap 订阅它），所以这里必须同时
        // 写盘与同步 notifier，否则调节后要么不动、要么重启回到旧值。
        // search: 封面 阴影 投影 立体 悬浮 层次感
        ListTile(
          title: const Text('封面阴影强度'),
          // tv: TV 构建换 RemoteSlider（P-C）
          subtitle: kTvBuild
              ? RemoteSlider(
                  value: _coverShadowStrength,
                  min: 0,
                  max: 1,
                  label: '${(_coverShadowStrength * 100).round()}%',
                  onChanged: (value) {
                    setState(() => _coverShadowStrength = value);
                    kCoverShadowIntensity.value = value;
                    unawaited(
                      _settingsRepository.setCoverShadowStrength(value),
                    );
                  },
                )
              : M3ESlider(
                  decoration: const M3ESliderDecoration(
                    haptic: M3EHapticFeedback.medium,
                    hapticConfig: M3EHapticConfig.discrete(),
                  ),
                  value: _coverShadowStrength,
                  min: 0,
                  max: 1,
                  label: '${(_coverShadowStrength * 100).round()}%',
                  onChanged: (value) {
                    setState(() => _coverShadowStrength = value);
                    kCoverShadowIntensity.value = value;
                    unawaited(
                      _settingsRepository.setCoverShadowStrength(value),
                    );
                  },
                ),
        ),
        // 开启后陀螺仪驱动封面深度视差（模型内置，亦可导入更新）
        if (kDepthCoverAvailable) ...[
          // search: 3D 封面;深度;视差;立体;封面
          SwitchListTile(
            title: const Text('3D 封面'),
            value: _depthCoverEnabled,
            onChanged: (value) async {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _depthCoverEnabled = value);
              await _settingsRepository.setDepthCoverEnabled(value);
              DepthCoverService.enabledSignal.value = value;
            },
          ),
          // 开关关闭时隐藏以下三项（强度 / 导入模型 / 清理缓存）
          if (_depthCoverEnabled) ...[
            // search: 3D 封面 强度;视差 灵敏度;陀螺仪 灵敏度;深度 幅度
            ListTile(
              title: const Text('3D 封面强度'),
              // tv: TV 构建换 RemoteSlider（P-C）
              subtitle: kTvBuild
                  ? RemoteSlider(
                      value: _depthCoverStrength,
                      min: 0,
                      max: 40,
                      label: '${_depthCoverStrength.round()}',
                      onChanged: (value) {
                        setState(() => _depthCoverStrength = value);
                        unawaited(_settingsRepository.setDepthCoverStrength(value));
                      },
                    )
                  : M3ESlider(
                      decoration: const M3ESliderDecoration(
                        haptic: M3EHapticFeedback.medium,
                        hapticConfig: M3EHapticConfig.discrete(),
                      ),
                      value: _depthCoverStrength,
                      min: 0,
                      max: 40,
                      label: '${_depthCoverStrength.round()}',
                      onChanged: (value) {
                        setState(() => _depthCoverStrength = value);
                        unawaited(_settingsRepository.setDepthCoverStrength(value));
                      },
                    ),
            ),
            // search: 3D 封面 AI 修补;背景 修补;神经网络;模型 修补;智能 填充
            SwitchListTile(
              title: const Text('AI 背景修补'),
              subtitle: const Text('神经网络细化背景填充质量，关闭后用快速算法'),
              value: _depthCoverNeuralInpaint,
              onChanged: (value) async {
                AppHaptics.lightImpact(HapticCategory.control);
                setState(() => _depthCoverNeuralInpaint = value);
                await _settingsRepository.setDepthCoverNeuralInpaint(value);
                // 关闭→开启切换后，清缓存让新封面用神经修补重新生成
                if (value) {
                  await DepthCoverService.instance.cache.clearCache();
                  if (mounted) {
                    setState(() => _depthCacheBytes = 0);
                  }
                }
              },
            ),
            // search: 3D 封面 缓存;清理 缓存;深度 缓存
            ListTile(
              title: const Text('清理深度图缓存'),
              subtitle: Text(
                '当前占用 ${(_depthCacheBytes / 1048576).toStringAsFixed(1)} MB',
              ),
              onTap: _depthCacheBytes > 0 ? _clearDepthCache : null,
            ),
          ],
        ],
      ],
    );
  }

  /// 「歌词效果」三级子页：AM 歌词的对唱 / 取色 / 模糊 / 辉光 / 省电模式。
  Widget _buildLyricEffectSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 对唱 男女
        SwitchListTile(
          title: const Text('男女对唱歌词优化'),
          value: _useDuetLayout,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _useDuetLayout = v);
                  LyricPreferences.instance.setUseDuetLayout(v);
                }
              : null,
        ),
        // 歌词动态字体颜色：当前行按「85% 白 + 15% 封面提取色」混色（仅 AM 播放器）
        // search: 动态颜色 混色
        SwitchListTile(
          title: const Text('歌词动态颜色'),
          value: _lyricDynamicColor,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _lyricDynamicColor = v);
                  LyricPreferences.instance.setUseDynamicLyricColor(v);
                }
              : null,
        ),
        // search: 高斯模糊 模糊
        SwitchListTile(
          title: const Text('歌词高斯模糊'),
          // 标题说明了是什么，副标题只留影响决策的功耗代价
          subtitle: const Text('高功耗'),
          value: _useGaussianBlur,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _useGaussianBlur = v);
                  LyricPreferences.instance.setUseGaussianBlur(v);
                }
              : null,
        ),
        // search: 辉光 发光
        SwitchListTile(
          title: const Text('歌词辉光效果'),
          value: _useGlowEffect,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _useGlowEffect = v);
                  LyricPreferences.instance.setUseGlowEffect(v);
                }
              : null,
        ),
        // 平衡行换行：长歌词行的断点由 DP 求「各行宽度最均匀」的方案，
        // 替代旧的「累加宽度超宽即换行」（后者会出现「第二行只剩两三个字」）。
        // 两套播放器各一个开关：两套歌词的换行实现不同，问题不共用。
        // search: 平衡 平衡行 换行 断行 折行
        SwitchListTile(
          title: const Text('平衡行换行（Apple 风格）'),
          subtitle: const Text('长歌词换行时让每行长度更均匀'),
          value: _lyricLineBalanceAm,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _lyricLineBalanceAm = v);
                  LyricPreferences.instance.setLineBalance(v);
                }
              : null,
        ),
        // search: 平衡 平衡行 换行 断行 折行
        SwitchListTile(
          title: const Text('平衡行换行（Material 风格）'),
          subtitle: const Text('长歌词换行时让每行长度更均匀'),
          value: _lyricLineBalanceMd3,
          onChanged: _useAmStylePlayer
              ? null
              : (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _lyricLineBalanceMd3 = v);
                  Md3LyricPreferences.instance.setLineBalance(v);
                },
        ),
        // 歌词省电模式：AM 播放器歌词界面锁定 60fps，上下滑动歌词时临时解锁。
        // 排在特效末尾：它是上面几项高功耗特效的性能兜底。
        // search: 省电 限帧
        SwitchListTile(
          title: const Text('歌词省电模式'),
          value: _lyricEcoMode,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _lyricEcoMode = v);
                  LyricPreferences.instance.setEcoMode(v);
                }
              : null,
        ),
      ],
    );
  }

  /// 「播放页背景」三级子页：写真背景轮播（MD3 + AM 共用）+ AM 流光与背景模糊。
  Widget _buildPlayerBackgroundSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 写真 背景 轮播
        SwitchListTile(
          title: const Text('歌手写真背景轮播'),
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useArtistPhotoBackground = v);
            context.read<ThemeProvider>().setUseArtistPhotoBackground(v);
          },
          value: _useArtistPhotoBackground,
        ),
        if (_useArtistPhotoBackground)
          // search: 写真 轮播 间隔
          // 原 trailing 的紧凑 DropdownButton 换成字段式 M3EDropdownMenu：
          // 控件下沉到 subtitle，与下方「写真背景透明度」的 subtitle 控件行
          // 保持同一节奏（行高、左右留白、取值文本尺寸均靠拢该行）。
          ListTile(
            title: const Text('轮播间隔'),
            subtitle: TvDropdownMenu<int>(
              items: [
                for (final s in const [5, 10, 15, 20, 30, 45, 60])
                  M3EDropdownItem(
                    label: '$s 秒',
                    value: s,
                    selected: _artistPhotoInterval == s,
                  ),
              ],
              singleSelect: true,
              showChipAnimation: false,
              fieldStyle: M3EDropdownFieldStyle(
                hintText: '选择轮播间隔',
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                selectedTextStyle: Theme.of(context).textTheme.bodyMedium,
              ),
              onSelectionChanged: (selected) {
                // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
                if (selected.isEmpty) {
                  setState(() {});
                  return;
                }
                final v = selected.first.value;
                if (v == _artistPhotoInterval) return;
                setState(() => _artistPhotoInterval = v);
                context.read<ThemeProvider>().setArtistPhotoInterval(v);
              },
            ),
          ),
        if (_useArtistPhotoBackground)
          // search: 写真 透明度
          ListTile(
            title: const Text('写真背景透明度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _artistPhotoOpacity,
                    min: 0.0,
                    max: 0.95,
                    divisions: 19,
                    label: '${(_artistPhotoOpacity * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _artistPhotoOpacity = v);
                      context.read<ThemeProvider>().setArtistPhotoOpacity(v);
                    },
                  )
                : M3ESlider(
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                    ),
                    value: _artistPhotoOpacity,
                    min: 0.0,
                    max: 0.95,
                    divisions: 19,
                    label: '${(_artistPhotoOpacity * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _artistPhotoOpacity = v);
                      context.read<ThemeProvider>().setArtistPhotoOpacity(v);
                    },
                  ),
            trailing: _statusText('${(_artistPhotoOpacity * 100).round()}%'),
          ),
        // search: 流光 背景
        SwitchListTile(
          title: const Text('背景动态流光'),
          subtitle: const Text('高功耗'),
          value: _useFlowingBackground,
          onChanged: _useAmStylePlayer
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _useFlowingBackground = v);
                  LyricPreferences.instance.setUseFlowingBackground(v);
                }
              : null,
        ),
        // 播放页背景模糊：仅 AM 风格 + 动态流光关闭时渲染此模糊层，
        // 两种条件任一不满足即隐藏（流光开启时滑块无意义）
        // search: 模糊 背景 播放器 毛玻璃 封面
        if (_useAmStylePlayer && !_useFlowingBackground)
          ListTile(
            title: const Text('播放页背景模糊'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _amPlayerBlur,
                    min: 0,
                    max: 200,
                    // 不传 divisions = 无级调节（无节点）
                    label: '${_amPlayerBlur.round()}',
                    onChanged: (v) {
                      setState(() => _amPlayerBlur = v);
                    },
                    onChangeEnd: (v) {
                      context.read<ThemeProvider>().setAmPlayerBlur(v);
                    },
                  )
                : M3ESlider(
                    // 控件统一用 md3e_core 的无节点 M3ESlider（不传 divisions）。
                    // 显式给 hapticConfig：divisions == null 时 M3ESlider 默认取
                    // continuous（10ms 间隔 + 2% 阈值），拖动会以最高约 100 次/秒
                    // 走 MethodChannel 触发 vibrate，真机马达饱和 + 通道洪泛
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                      hapticConfig: M3EHapticConfig.discrete(),
                    ),
                    value: _amPlayerBlur,
                    min: 0,
                    max: 200,
                    // 不传 divisions = 无级调节（无节点）
                    label: '${_amPlayerBlur.round()}',
                    onChanged: (v) {
                      setState(() => _amPlayerBlur = v);
                    },
                    onChangeEnd: (v) {
                      context.read<ThemeProvider>().setAmPlayerBlur(v);
                    },
                  ),
            trailing: Text('${_amPlayerBlur.round()}'),
          ),
      ],
    );
  }

  /// 「进度条」三级子页：波浪起伏总开关（关闭即回退到直线形态）。
  Widget _buildProgressBarSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 进度条 波浪 起伏 回退 直线
        SwitchListTile(
          title: const Text('进度条波浪起伏'),
          subtitle: const Text('关闭后播放页进度条回到直线样式'),
          value: _seekBarWaveEnabled,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() => _seekBarWaveEnabled = value);
            _settingsRepository.setSeekBarWaveEnabled(value);
            // 立即生效：驱动 MD3 播放页的 Listenable.merge 重建
            kSeekBarWaveEnabled.value = value;
          },
        ),
      ],
    );
  }

  /// 「音乐频谱」三级子页：环绕开关 + 样式 + 柱数量 + 取色 + 各透明度/高度。
  Widget _buildSpectrumSubpage(ColorScheme colorScheme) {
    // 进入时刷新一次实测输出延迟（探针只在播放中有意义）
    // ignore: discarded_futures
    MusicHapticsService.instance.refreshMeasuredLatency();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 音乐频谱环绕：仅在 Android 生效；其他平台开关置灰
        // search: 频谱 环绕 可视化
        SwitchListTile(
          title: const Text('音乐频谱环绕'),
          // 平台不支持导致开关置灰时才提示，支持时无需额外说明
          subtitle: Platform.isAndroid ? null : const Text('仅 Android 设备支持'),
          value: _spectrumEnabled,
          onChanged: Platform.isAndroid
              ? (v) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  setState(() => _spectrumEnabled = v);
                  _settingsRepository.setSpectrumEnabled(v);
                }
              : null,
        ),
        // 频谱样式切换（3选1）：柱状图(环绕) / 曲线(环绕) / 背景层(条形)。
        // 先定样式，再调该样式下的参数。
        if (_spectrumEnabled && Platform.isAndroid)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                const Text('频谱样式'),
                const Gap(AppSpacing.lg),
                Expanded(
                  child: M3EToggleButtonGroup(
                    actions: const [
                      M3EToggleButtonGroupAction(label: Text('柱状图')),
                      M3EToggleButtonGroupAction(label: Text('曲线')),
                      M3EToggleButtonGroupAction(label: Text('背景层')),
                    ],
                    selectedIndex: _spectrumStyle,
                    onSelectedIndexChanged: (index) {
                      if (index == null) return;
                      AppHaptics.lightImpact(HapticCategory.control);
                      setState(() => _spectrumStyle = index);
                      _settingsRepository.setSpectrumStyle(index);
                    },
                  ),
                ),
              ],
            ),
          ),
        // 节奏偏移：频谱显示/节奏震动共用的**链路延迟补偿**，与「音乐节奏震动」分组里的
        // 同名控件写同一个键（_keyMusicHapticsOffset）、调同一个服务方法，两处实时同步。
        // 放这里是因为它本质属于"频谱采集链路"的参数：PCM 在写进输出缓冲那一刻就被
        // 分析，比听到早一整个缓冲深度；震动靠延后点火补，频谱柱的发布也按同一
        // 数值延后（kSpectrumVisualOffsetMs），两处同时补才同相。
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 偏移 延迟 补偿 对齐 滞后 提前 offset 拍点
          ListTile(
            title: const Text('节奏偏移'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // tv: TV 构建换 RemoteSlider（P-C）
                kTvBuild
                    ? RemoteSlider(
                        value: _musicHapticsOffset.toDouble(),
                        min: 0,
                        max: MusicHapticsService.maxOffsetMs.toDouble(),
                        // 无极连续调节，与「音乐节奏震动」分组里的同名控件完全一致
                        label: '+${_musicHapticsOffset}ms',
                        onChanged: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          MusicHapticsService.instance.previewOffset(ms);
                        },
                        onChangeEnd: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          _settingsRepository.setMusicHapticsOffset(ms);
                          MusicHapticsService.instance.setOffset(ms);
                        },
                      )
                    : M3ESlider(
                        decoration: kFreeSliderDecoration,
                        value: _musicHapticsOffset.toDouble(),
                        min: 0,
                        max: MusicHapticsService.maxOffsetMs.toDouble(),
                        // 无极连续调节，与「音乐节奏震动」分组里的同名控件完全一致
                        label: '+${_musicHapticsOffset}ms',
                        onChanged: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          MusicHapticsService.instance.previewOffset(ms);
                        },
                        onChangeEnd: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          _settingsRepository.setMusicHapticsOffset(ms);
                          MusicHapticsService.instance.setOffset(ms);
                        },
                      ),
                Center(child: _statusText('+${_musicHapticsOffset}ms')),
                _offsetAutoRow(),
              ],
            ),
          ),
        // 频谱柱数量滑块：仅开关开启且 Android 时显示
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 频谱
          ListTile(
            title: const Text('频谱柱数量'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _spectrumBandCount.toDouble(),
                    min: 20,
                    max: 80,
                    label: '$_spectrumBandCount 根',
                    onChanged: (v) {
                      setState(() => _spectrumBandCount = v.round());
                    },
                    onChangeEnd: (v) {
                      final count = v.round();
                      _settingsRepository.setSpectrumBandCount(count);
                      SpectrumService.instance.bandCount = count;
                    },
                  )
                : M3ESlider(
                    value: _spectrumBandCount.toDouble(),
                    min: 20,
                    max: 80,
                    // 频谱柱数量不显示节点
                    label: '$_spectrumBandCount 根',
                    onChanged: (v) {
                      setState(() => _spectrumBandCount = v.round());
                    },
                    onChangeEnd: (v) {
                      final count = v.round();
                      _settingsRepository.setSpectrumBandCount(count);
                      SpectrumService.instance.bandCount = count;
                    },
                  ),
            trailing: _statusText('$_spectrumBandCount 根'),
          ),
        // 频谱动态取色：AM 播放器频谱颜色取封面主色（50% 白 + 50% 取色混合）
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 频谱 取色
          SwitchListTile(
            title: const Text('频谱动态取色'),
            value: _spectrumDynamicColor,
            onChanged: (v) {
              AppHaptics.selectionClick(HapticCategory.control);
              setState(() => _spectrumDynamicColor = v);
              _settingsRepository.setSpectrumDynamicColor(v);
            },
          ),
        // Visualizer 兜底：默认关闭。开启后允许在 PCM 通路无数据时改用系统采集，
        // 代价是需要录音权限，且会把输出轨道从 fast track 降级（部分机型爆音）。
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 频谱 兜底 Visualizer 兼容
          SwitchListTile(
            title: const Text('Visualizer 兜底'),
            subtitle: const Text('PCM 无数据时改用系统采集；可能造成爆音，非必要勿开'),
            value: _spectrumVisualizerFallback,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _spectrumVisualizerFallback = v);
              _settingsRepository.setSpectrumVisualizerFallback(v);
            },
          ),
        // 频谱透明度滑块：按当前样式显示对应项（三个分开记忆）
        if (_spectrumEnabled && Platform.isAndroid)
          // style 0：柱状图透明度；style 1：曲线透明度
          if (_spectrumStyle == 0)
            // search: 频谱 透明度
            ListTile(
              title: const Text('频谱柱状图透明度'),
              // tv: TV 构建换 RemoteSlider（P-C）
              subtitle: kTvBuild
                  ? RemoteSlider(
                      value: _spectrumBarOpacity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: '${(_spectrumBarOpacity * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _spectrumBarOpacity = v);
                      },
                      onChangeEnd: (v) {
                        _settingsRepository.setSpectrumBarOpacity(v);
                      },
                    )
                  : M3ESlider(
                      decoration: const M3ESliderDecoration(
                        haptic: M3EHapticFeedback.medium,
                      ),
                      value: _spectrumBarOpacity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: '${(_spectrumBarOpacity * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _spectrumBarOpacity = v);
                      },
                      onChangeEnd: (v) {
                        _settingsRepository.setSpectrumBarOpacity(v);
                      },
                    ),
              trailing: _statusText('${(_spectrumBarOpacity * 100).round()}%'),
            )
          else if (_spectrumStyle == 1)
            // search: 频谱 透明度
            ListTile(
              title: const Text('频谱曲线透明度'),
              // tv: TV 构建换 RemoteSlider（P-C）
              subtitle: kTvBuild
                  ? RemoteSlider(
                      value: _spectrumCurveOpacity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: '${(_spectrumCurveOpacity * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _spectrumCurveOpacity = v);
                      },
                      onChangeEnd: (v) {
                        _settingsRepository.setSpectrumCurveOpacity(v);
                      },
                    )
                  : M3ESlider(
                      decoration: const M3ESliderDecoration(
                        haptic: M3EHapticFeedback.medium,
                      ),
                      value: _spectrumCurveOpacity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: '${(_spectrumCurveOpacity * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _spectrumCurveOpacity = v);
                      },
                      onChangeEnd: (v) {
                        _settingsRepository.setSpectrumCurveOpacity(v);
                      },
                    ),
              trailing: _statusText(
                '${(_spectrumCurveOpacity * 100).round()}%',
              ),
            ),
        // 背景层参数：仅 style=2 时显示
        if (_spectrumEnabled && _spectrumStyle == 2 && Platform.isAndroid) ...[
          // search: 频谱 透明度
          ListTile(
            title: const Text('频谱背景透明度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _spectrumBgOpacity,
                    min: 0.1,
                    max: 0.8,
                    divisions: 14,
                    label: '${(_spectrumBgOpacity * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _spectrumBgOpacity = v);
                    },
                    onChangeEnd: (v) {
                      _settingsRepository.setSpectrumBgOpacity(v);
                    },
                  )
                : M3ESlider(
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                    ),
                    value: _spectrumBgOpacity,
                    min: 0.1,
                    max: 0.8,
                    divisions: 14,
                    label: '${(_spectrumBgOpacity * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _spectrumBgOpacity = v);
                    },
                    onChangeEnd: (v) {
                      _settingsRepository.setSpectrumBgOpacity(v);
                    },
                  ),
            trailing: _statusText('${(_spectrumBgOpacity * 100).round()}%'),
          ),
          // search: 频谱 高度
          ListTile(
            title: const Text('频谱背景高度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _spectrumBgHeight,
                    min: 0.2,
                    max: 0.8,
                    divisions: 12,
                    label: '${(_spectrumBgHeight * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _spectrumBgHeight = v);
                    },
                    onChangeEnd: (v) {
                      _settingsRepository.setSpectrumBgHeight(v);
                    },
                  )
                : M3ESlider(
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                    ),
                    value: _spectrumBgHeight,
                    min: 0.2,
                    max: 0.8,
                    divisions: 12,
                    label: '${(_spectrumBgHeight * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _spectrumBgHeight = v);
                    },
                    onChangeEnd: (v) {
                      _settingsRepository.setSpectrumBgHeight(v);
                    },
                  ),
            trailing: _statusText('${(_spectrumBgHeight * 100).round()}%'),
          ),
        ],
      ],
    );
  }

  /// 弹出 8 色预设种子色选择面板。
  /// 选择后调用 ThemeProvider.setManualSeedColor 持久化并立即生效。
  void _showSeedColorPicker(ThemeProvider themeProvider) {
    showM3EModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SeedColorPicker(
        currentColor:
            themeProvider.manualSeedColor ?? AppTheme.defaultSeedColor,
        onSelected: (color) {
          themeProvider.setManualSeedColor(color);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  /// 字体来源中文标签。
  String _getFontSourceLabel(FontSource source) {
    switch (source) {
      case FontSource.system:
      case FontSource.bundled: // 已废弃（内置 SimHei 已移除），等同 system
        return '系统默认（手机字体优先）';
      case FontSource.custom:
        return '自定义字体';
    }
  }

  /// 弹出字体来源选择面板。
  ///
  /// 两个选项：
  /// - 系统默认：UI 走系统字体链（Roboto + Noto Sans CJK 等）
  /// - 自定义字体：通过 Android SAF 选择 .ttf/.otf 文件，
  ///   原生端拷贝到 filesDir/fonts/user_custom.ttf，Dart 端用 FontLoader 注册
  void _showFontSourceSheet(ThemeProvider themeProvider) {
    showM3EModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = themeProvider.fontSource;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'app全局字体来源',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  current == FontSource.system
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('系统默认'),
                onTap: () async {
                  await themeProvider.setFontSource(FontSource.system);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == FontSource.custom
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('自定义字体'),
                // 只在已加载字体时回显路径，未加载时点击即触发选择器
                subtitle: themeProvider.customFontPath == null
                    ? null
                    : Text(
                        '已加载：${themeProvider.customFontPath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () async {
                  // 立即关闭面板，避免文件选择器与 BottomSheet 重叠
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _pickAndApplyCustomFont(themeProvider);
                },
              ),
              const Gap(AppSpacing.sm),
            ],
          ),
        );
      },
    );
  }

  /// 调用原生 SAF 文件选择器让用户选择字体文件，成功后保存并应用。
  ///
  /// 选择流程：
  /// 1. CustomFontLoader.pickFontFile() 打开系统文件选择器
  /// 2. 原生端把选中文件拷贝到 filesDir/fonts/user_custom.ttf，返回路径
  /// 3. themeProvider.setCustomFontPath(path) 持久化路径 + 立即 FontLoader 注册
  /// 4. themeProvider.setFontSource(FontSource.custom) 切换为 custom 模式
  ///
  /// 失败处理：用户取消（path=null）→ 不切换，弹提示；
  /// 加载失败 → effectiveFontFamily 自动降级为 null（system 行为），弹错误提示。
  Future<void> _pickAndApplyCustomFont(ThemeProvider themeProvider) async {
    final path = await CustomFontLoader.pickFontFile();
    if (path == null) {
      // 用户取消
      if (!mounted) return;
      showToast('未选择字体文件', long: true);
      return;
    }
    // 先保存路径并加载字体（_tryLoadCustomFont 内部会注册 FontLoader）
    await themeProvider.setCustomFontPath(path);
    // 再切换来源为 custom（即使加载失败也切换，UI 自然降级为系统字体）
    await themeProvider.setFontSource(FontSource.custom);
    if (!mounted) return;
    final loaded = themeProvider.effectiveFontFamily != null;
    showToast(loaded ? '已应用自定义字体' : '字体加载失败，已降级为系统字体', long: true);
  }

  /// 单个网络的音质四选一按钮组（WiFi / 移动网络共用）。
  /// 加载时把遗留 'hq' 归一化到 '320'（高音质 API 码为 '320'）。
  Widget _buildNetworkQualityGroup(String value, ValueChanged<String?> onPick) {
    // 五档；「蝰蛇母带」仅在实验开关开启时出现。
    // 遗留值归一化：'hq'→'320'；开关关闭时 'viper_tape' 按 'high' 显示
    // （与 PlayerProvider 请求侧的钳制一致，不改写存储值）。
    const all = ['128', '320', 'flac', 'high', 'viper_tape'];
    final codes = _viperTapeQualityEnabled ? all : all.sublist(0, 4);
    var normalized = value == 'hq' ? '320' : value;
    if (!_viperTapeQualityEnabled && normalized == 'viper_tape') {
      normalized = 'high';
    }
    return M3EToggleButtonGroup(
      actions: [
        M3EToggleButtonGroupAction(label: Text('标准')),
        M3EToggleButtonGroupAction(label: Text('高品质')),
        M3EToggleButtonGroupAction(label: Text('无损')),
        M3EToggleButtonGroupAction(label: Text('Hi-Res')),
        if (_viperTapeQualityEnabled)
          M3EToggleButtonGroupAction(label: Text('蝰蛇母带')),
      ],
      selectedIndex: codes.indexOf(normalized),
      onSelectedIndexChanged: (index) {
        if (index == null) return;
        onPick(codes[index]);
      },
    );
  }

  /// 网络音质分组选择回调：写对应网络的音质键，并让播放器按当前网络刷新，
  /// 新音质下一首播放生效（不打断当前播放）。
  void _onNetworkQualityPicked(bool isWifi, String? quality) {
    if (quality == null) return;
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() {
      if (isWifi) {
        _wifiQuality = quality;
        _settingsRepository.setWifiQuality(quality);
      } else {
        _mobileQuality = quality;
        _settingsRepository.setMobileQuality(quality);
      }
    });
    context.read<PlayerProvider>().refreshQualityForNetwork();
  }

  /// 从原生侧读取当前构建实际生效的渲染引擎（'skia' | 'impeller'）。
  Future<String> _readCurrentRenderEngine() async {
    try {
      const channel = MethodChannel('com.md3music.md3music/render_engine');
      final v = await channel.invokeMethod<String>('getCurrent');
      return v == 'impeller' ? 'impeller' : 'skia';
    } catch (_) {
      return 'skia';
    }
  }

  /// 「音质与输出」三级子页：网络音质（WiFi / 移动）+ VIP 领取 + 32bit + 降级提示。
  Widget _buildAudioQualitySubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 标题与按钮组分离（非 ListTile），索引条目手写声明
        // search-item: 网络音质 | 音质 清晰度 wifi 移动
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SettingsSubGroupLabel('网络音质'),
              const Gap(AppSpacing.xs),
              Text(
                '分别设置 WiFi 与移动网络下的播放音质，随当前网络自动生效',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Gap(AppSpacing.lg),
              Text('WiFi 网络下', style: Theme.of(context).textTheme.bodyMedium),
              const Gap(AppSpacing.sm),
              _buildNetworkQualityGroup(
                _wifiQuality,
                (q) => _onNetworkQualityPicked(true, q),
              ),
              const Gap(AppSpacing.lg),
              Text('移动网络下', style: Theme.of(context).textTheme.bodyMedium),
              const Gap(AppSpacing.sm),
              _buildNetworkQualityGroup(
                _mobileQuality,
                (q) => _onNetworkQualityPicked(false, q),
              ),
            ],
          ),
        ),
        // 自动领取 VIP 紧随音质：它决定高音质/无损是否真的可播
        // search: vip 会员 自动领取
        SwitchListTile(
          title: const Text('自动领取VIP'),
          value: _autoReceiveVip,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _autoReceiveVip = value;
            });
            _settingsRepository.setAutoReceiveVip(value);
          },
        ),
        // search: 32bit 无损 高解析 音质 float
        SwitchListTile(
          title: const Text('32bit 播放支持'),
          // 只保留可能出问题的风险提醒，实现细节说明删除
          subtitle: const Text('部分设备开启后可能出现变调/变速'),
          value: _enable32bitOutput,
          onChanged: (value) => _setEnable32bitOutput(value),
        ),
        // search: 音质 降级 提示 toast vip 网络限制
        SwitchListTile(
          title: const Text('音质降级提示'),
          value: _showQualityDowngradeToast,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _showQualityDowngradeToast = value);
            context.read<PlayerProvider>().setShowQualityDowngradeToast(value);
          },
        ),
      ],
    );
  }

  /// 「音效与音量」三级子页：均衡器 / 音效库入口 + 蝰蛇母带链 + 音量均衡。
  Widget _buildAudioEffectsSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 桌面端隐藏整条系统音效链：均衡器 / 音效库 / 音量均衡 / 参考响度
        // 都挂在 EqualizerService 的 AudioSession 绑定上（Android 专属），
        // 桌面端 tryBind() 直接 return false —— 开关照样能开、能存盘，
        // 但没有任何音效被挂载，是"假成功"（详见 platform_capabilities）。
        if (supportsSystemAudioEffects) ...[
          ListenableBuilder(
            listenable: EqualizerService.instance,
            builder: (context, _) {
              final eq = EqualizerService.instance;
              final effectsDisabled =
                  _disableSystemAudioEffects || eq.systemEffectsDisabled;
              // search: eq 均衡
              return ListTile(
                enabled: !effectsDisabled,
                leading: Icon(
                  Icons.graphic_eq,
                  color: effectsDisabled
                      ? Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.38)
                      : (eq.enabled
                            ? Theme.of(context).colorScheme.primary
                            : null),
                ),
                title: const Text('均衡器'),
                subtitle: Text(
                  eq.systemEffectsDisabled
                      ? '系统音效已禁用'
                      : (eq.enabled ? '已开启 · ${eq.currentPreset}' : '未开启'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: effectsDisabled
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const EqualizerSettingsPage(),
                        ),
                      ),
              );
            },
          ),
          // search: 禁用系统音效 手机厂商 音效叠加 爆音 均衡器
          SwitchListTile(
            title: const Text('禁用App均衡器和音效'),
            subtitle: const Text('避免与手机厂商音效叠加后播放音乐炸音；会停用本应用均衡器和音效库'),
            value: _disableSystemAudioEffects,
            onChanged: (value) {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _disableSystemAudioEffects = value);
              EqualizerService.instance.setSystemEffectsDisabled(value);
            },
          ),
          // —— 蝰蛇/社区音效（浏览与下载 .irs 音效文件）——
          // search: 蝰蛇 音效 社区音效 sound model irs
          ListTile(
            enabled: !_disableSystemAudioEffects,
            leading: Icon(
              Icons.spatial_audio_off,
              color: _disableSystemAudioEffects
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.38)
                  : null,
            ),
            title: const Text('音效库'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _disableSystemAudioEffects
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SoundsPage()),
                  ),
          ),
          // search: 蝰蛇 母带 母带处理 限幅 削波 均衡 viper master
          if (supportsViperMaster)
            SwitchListTile(
              title: const Text('蝰蛇母带处理'),
              subtitle: const Text('10 段均衡 + 限幅的母带级处理链，仅 Android；关闭时输出逐字节透传'),
              value: _viperMasterEnabled,
              onChanged: (value) {
                AppHaptics.lightImpact(HapticCategory.control);
                setState(() => _viperMasterEnabled = value);
                _settingsRepository.setViperMasterEnabled(value);
                ViperMasterService.instance.setEnabled(value);
              },
            ),
          // search: 蝰蛇母带 音源 母带音质 viper tape VPT
          if (supportsViperMaster)
            SwitchListTile(
              title: const Text('蝰蛇母带音源'),
              subtitle: const Text('实验功能 · 开启后音质选择出现「蝰蛇母带」档，需要 VIP'),
              value: _viperTapeQualityEnabled,
              onChanged: (value) {
                AppHaptics.lightImpact(HapticCategory.control);
                setState(() => _viperTapeQualityEnabled = value);
                _settingsRepository.setViperTapeQualityEnabled(value);
              },
            ),
          // —— 音量均衡（响度归一）——
          // search: 音量均衡 响度归一 响度 均衡 参考响度 LUFS 安静歌 放大 峰值
          if (supportsLoudnessNormalization) ...[
            SwitchListTile(
              title: const Text('音量均衡'),
              value: _volumeNormalizationEnabled,
              onChanged: (value) {
                AppHaptics.lightImpact(HapticCategory.control);
                setState(() => _volumeNormalizationEnabled = value);
                _settingsRepository.setVolumeNormalizationEnabled(value);
                // 开关变化即时对当前曲目重算并应用增益
                AudioService().setVolumeNormalization(enabled: value);
              },
            ),
            // 参考响度只在均衡开启时才有意义
            // search-item: 参考响度 LUFS | 音量均衡 参考响度 响度 归一 均衡
            if (_volumeNormalizationEnabled)
              ListTile(
                title: const Text('参考响度'),
                // tv: TV 构建换 RemoteSlider（P-C）
                subtitle: kTvBuild
                    ? RemoteSlider(
                        value: _volumeNormalizationLufs,
                        min: -20,
                        max: -8,
                        divisions: 12,
                        label: '${_volumeNormalizationLufs.round()} LUFS',
                        onChanged: (v) {
                          setState(() => _volumeNormalizationLufs = v.roundToDouble());
                        },
                        onChangeEnd: (v) {
                          final lufs = v.roundToDouble();
                          setState(() => _volumeNormalizationLufs = lufs);
                          _settingsRepository.setVolumeNormalizationReferenceLufs(lufs);
                          AudioService().setVolumeNormalization(referenceLufs: lufs);
                        },
                      )
                    : M3ESlider(
                        decoration: const M3ESliderDecoration(
                          haptic: M3EHapticFeedback.medium,
                        ),
                        value: _volumeNormalizationLufs,
                        min: -20,
                        max: -8,
                        divisions: 12,
                        label: '${_volumeNormalizationLufs.round()} LUFS',
                        onChanged: (v) {
                          setState(() => _volumeNormalizationLufs = v.roundToDouble());
                        },
                        onChangeEnd: (v) {
                          final lufs = v.roundToDouble();
                          setState(() => _volumeNormalizationLufs = lufs);
                          _settingsRepository.setVolumeNormalizationReferenceLufs(lufs);
                          AudioService().setVolumeNormalization(referenceLufs: lufs);
                        },
                      ),
                trailing: _statusText('${_volumeNormalizationLufs.round()} LUFS'),
              ),
          ],
        ],
      ],
    );
  }

  /// 「播放行为」三级子页：记忆播放 + 淡入淡出 / 交叉淡化 + 音频焦点策略。
  Widget _buildPlaybackBehaviorSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 记忆 播放状态 恢复 上次播放 播放进度 断点 续播 冷启动
        SwitchListTile(
          title: const Text('记忆播放状态'),
          subtitle: const Text('冷启动恢复上次播放的歌曲与进度；关闭后不再记忆'),
          value: _restoreMemoryEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _restoreMemoryEnabled = value);
            context.read<PlayerProvider>().setRestoreMemoryEnabled(value);
          },
        ),
        // search: 自动播放 启动 开机 冷启动 一进来 就播
        SwitchListTile(
          title: const Text('启动时自动播放'),
          subtitle: const Text('打开应用后自动开始播放音乐；默认关闭'),
          value: _startupAutoPlayEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _startupAutoPlayEnabled = value);
            _settingsRepository.setStartupAutoPlayEnabled(value);
          },
        ),
        // 以下两项是上面那个开关的从属项：关着时它们没有意义，直接隐藏
        if (_startupAutoPlayEnabled) ...[
          // search: 播放内容 音源 每日推荐 私人FM 红心 探索 小众 刷歌推荐 继续上次 续播 电台
          ListTile(
            title: const Text('播放内容'),
            subtitle: TvDropdownMenu<String>(
              items: [
                for (final s in StartupAutoPlaySource.values)
                  M3EDropdownItem(
                    label: s.label,
                    value: s.value,
                    selected: _startupAutoPlaySource == s.value,
                    // 「继续上次播放」靠记忆播放状态才有记录可续，关着它
                    // 选了也只会静默不动 —— 置灰并说明原因，别让用户白等
                    disabled: s.value == 'resume' && !_restoreMemoryEnabled,
                  ),
              ],
              singleSelect: true,
              // 单选下关闭 chip 动画，当前值才会渲染为可省略的纯文本
              showChipAnimation: false,
              fieldStyle: const M3EDropdownFieldStyle(
                hintText: '选择启动时播放的内容',
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onSelectionChanged: (selected) {
                // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
                if (selected.isEmpty) {
                  setState(() {});
                  return;
                }
                final value = selected.first.value;
                if (value == _startupAutoPlaySource) return;
                AppHaptics.lightImpact(HapticCategory.control);
                setState(() => _startupAutoPlaySource = value);
                _settingsRepository.setStartupAutoPlaySource(value);
              },
            ),
            trailing: _startupAutoPlaySource == 'resume' && !_restoreMemoryEnabled
                ? _statusText('需开启记忆播放状态')
                : null,
          ),
          // search: 自动打开 播放页 全屏 推起 进播放页 启动
          SwitchListTile(
            title: const Text('自动打开播放页'),
            subtitle: const Text('开始播放后自动进入完整播放页'),
            value: _startupAutoPlayOpenPage,
            onChanged: (value) {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _startupAutoPlayOpenPage = value);
              _settingsRepository.setStartupAutoPlayOpenPage(value);
            },
          ),
        ],
        // search: 淡入淡出 渐变 音量
        SwitchListTile(
          title: const Text('暂停淡入淡出'),
          value: _pauseFadeEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _pauseFadeEnabled = value;
            });
            _settingsRepository.setPauseFadeEnabled(value);
          },
        ),
        // search: 歌曲淡入淡出 交叉淡化 crossfade 渐入渐出 叠加 衔接 无缝 过渡
        SwitchListTile(
          title: const Text('歌曲淡入淡出'),
          value: _crossfadeEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _crossfadeEnabled = value;
            });
            _settingsRepository.setCrossfadeEnabled(value);
            // PlayerProvider 把设置缓存在字段里（判定在 ~200ms 的高频路径上），
            // 改完必须通知它重新读取，否则本次运行内不生效
            context.read<PlayerProvider>().refreshCrossfadeSettings();
          },
        ),
        // 时长只在开关打开时才有意义，关闭时隐藏
        if (_crossfadeEnabled)
          // search-item: 淡出时长 | 交叉淡化时长 淡化 时长 秒数 crossfade 叠加
          ListTile(
            title: const Text('淡出时长'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _crossfadeSeconds.toDouble(),
                    min: SettingsRepository.kCrossfadeMinSeconds.toDouble(),
                    max: SettingsRepository.kCrossfadeMaxSeconds.toDouble(),
                    divisions:
                        SettingsRepository.kCrossfadeMaxSeconds -
                        SettingsRepository.kCrossfadeMinSeconds,
                    label: '$_crossfadeSeconds 秒',
                    onChanged: (v) {
                      setState(() => _crossfadeSeconds = v.round());
                    },
                    onChangeEnd: (v) {
                      final seconds = v.round();
                      setState(() => _crossfadeSeconds = seconds);
                      _settingsRepository.setCrossfadeSeconds(seconds);
                      context.read<PlayerProvider>().refreshCrossfadeSettings();
                    },
                  )
                : M3ESlider(
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                    ),
                    value: _crossfadeSeconds.toDouble(),
                    min: SettingsRepository.kCrossfadeMinSeconds.toDouble(),
                    max: SettingsRepository.kCrossfadeMaxSeconds.toDouble(),
                    divisions:
                        SettingsRepository.kCrossfadeMaxSeconds -
                        SettingsRepository.kCrossfadeMinSeconds,
                    label: '$_crossfadeSeconds 秒',
                    onChanged: (v) {
                      setState(() => _crossfadeSeconds = v.round());
                    },
                    onChangeEnd: (v) {
                      final seconds = v.round();
                      setState(() => _crossfadeSeconds = seconds);
                      _settingsRepository.setCrossfadeSeconds(seconds);
                      context.read<PlayerProvider>().refreshCrossfadeSettings();
                    },
                  ),
            trailing: _statusText('$_crossfadeSeconds 秒'),
          ),
        // search: 自动混音 AutoMix 无缝过渡 对拍 节拍 变速 混音 DJ
        if (_crossfadeEnabled)
          SwitchListTile(
            title: const Text('自动混音（AutoMix）'),
            subtitle: const Text(
              '按节拍对齐过渡点、按节奏自适应时长，BPM 接近时自动对拍',
            ),
            value: _automixEnabled,
            onChanged: (value) {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() {
                _automixEnabled = value;
              });
              _settingsRepository.setAutomixEnabled(value);
              // ignore: use_build_context_synchronously
              // refreshAutomixSettings() 由 Task 12 在 PlayerProvider 中提供
              context.read<PlayerProvider>().refreshAutomixSettings();
            },
          ),
        // 「失去音频焦点时」是下面这个开关的从属策略：忽略焦点关闭时才有意义
        // search: 音频焦点 忽略焦点 同时播放 共存 不被打断 焦点
        SwitchListTile(
          title: const Text('允许与其他应用同时播放音频'),
          value: _ignoreAudioFocus,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _ignoreAudioFocus = value;
            });
            context.read<PlayerProvider>().setIgnoreAudioFocus(value);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 与「默认音质」一致的标题排版
              const SettingsSubGroupLabel('失去音频焦点时'),
              const Gap(AppSpacing.sm),
              // 与「默认音质」同款 M3E 按钮组；横排 + xs 尺寸 + 紧凑密度，文字过长省略
              M3EToggleButtonGroup(
                actions: const [
                  M3EToggleButtonGroupAction(
                    label: Text(
                      '保持播放',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                  M3EToggleButtonGroupAction(
                    label: Text(
                      '暂停后恢复',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                  M3EToggleButtonGroupAction(
                    label: Text(
                      '降音量恢复',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ],
                direction: Axis.horizontal,
                size: M3EButtonSize.xs,
                density: M3EButtonGroupDensity.compact,
                selectedIndex: AudioFocusInterruptionMode.values.indexOf(
                  _audioFocusInterruptionMode,
                ),
                onSelectedIndexChanged: (index) {
                  if (index == null) return;
                  _onAudioFocusModeChanged(
                    AudioFocusInterruptionMode.values[index],
                  );
                },
              ),
              const Gap(AppSpacing.sm),
              Text(
                _audioFocusModeDescription(_audioFocusInterruptionMode),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // search: 听歌数据云同步 听歌 云同步 上传 历史 时长 等级 上报 播放历史 排行
        SwitchListTile(
          title: const Text('听歌数据云同步'),
          subtitle: const Text('云端播放历史、听歌排行与听歌时长/等级'),
          value: _uploadListeningDuration,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _uploadListeningDuration = value;
            });
            _settingsRepository.setUploadListeningDuration(value);
            // 关闭时立刻丢弃两个上报服务的当前计时段：否则 tracker 会继续累计，
            // 重新打开后这段「关闭期间」的时长会被补记上报 —— 违背用户意愿。
            // 已累计的部分同样不上报（用户关闭开关的意图优先）。
            if (!value) {
              ListenReportService.instance.discard();
              PlayHistorySyncService.instance.discard();
            }
          },
        ),
      ],
    );
  }

  /// 「屏幕与视频」三级子页：Zen 长按、横屏沉浸、常亮、MV 画中画与弹幕。
  Widget _buildScreenVideoSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: zen 沉浸 长按封面 沉浸模式
        SwitchListTile(
          title: const Text('长按封面进入 Zen 模式'),
          value: _zenCoverLongPress,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _zenCoverLongPress = value);
            _settingsRepository.setZenCoverLongPress(value);
          },
        ),
        // 横屏进播放器自动隐藏状态栏/导航栏；关闭后横屏保持系统栏可见
        // search: 横屏 沉浸 状态栏 导航栏 隐藏 全屏播放器
        SwitchListTile(
          title: const Text('横屏隐藏状态栏'),
          value: _landscapeImmersiveEnabled,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _landscapeImmersiveEnabled = value);
            _settingsRepository.setLandscapeImmersiveEnabled(value);
            // 全局标志即时同步：再次进入播放器或旋转屏幕即按新值应用系统栏
            kLandscapeImmersiveEnabled = value;
          },
        ),
        // search: 屏幕常亮 常亮 息屏
        SwitchListTile(
          title: const Text('播放时保持屏幕常亮'),
          value: _keepScreenOn,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _keepScreenOn = value;
            });
            _settingsRepository.setKeepScreenOn(value);
            WakelockService.instance.setSettingEnabled(value);
          },
        ),
        // MV 画中画：按 Home 自动进入（手动按钮始终可用）
        FutureBuilder<bool>(
          future: SettingsRepository().getAutoPipEnabled(),
          builder: (context, snapshot) {
            final enabled = snapshot.data ?? false;
            // search: 画中画 pip 悬浮
            return SwitchListTile(
              secondary: Icon(
                Icons.picture_in_picture_alt,
                color: colorScheme.primary,
              ),
              title: const Text('播放 MV 时自动画中画'),
              value: enabled,
              onChanged: (v) async {
                AppHaptics.lightImpact(HapticCategory.control);
                await SettingsRepository().setAutoPipEnabled(v);
                setState(() {});
              },
            );
          },
        ),
        // MV 弹幕：控制是否在 MV 播放页叠加弹幕层
        // search: MV 弹幕 弹幕 视频 滚动
        SwitchListTile(
          secondary: Icon(Icons.subtitles_outlined, color: colorScheme.primary),
          title: const Text('显示 MV 弹幕'),
          subtitle: const Text('在 MV 播放页叠加弹幕'),
          value: _mvDanmakuEnabled,
          onChanged: (v) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _mvDanmakuEnabled = v);
            await _settingsRepository.setMvDanmakuEnabled(v);
          },
        ),
        // 歌曲弹幕：控制是否在播放页叠加弹幕层（TV 无文本输入能力，不编入 TV 包）
        // search: 歌曲 弹幕 播放页 封面 滚动
        if (!kTvBuild)
          SwitchListTile(
            secondary: Icon(
              Icons.subtitles_outlined,
              color: colorScheme.primary,
            ),
            title: const Text('显示歌曲弹幕'),
            subtitle: const Text('在播放页叠加歌曲弹幕'),
            value: _songDanmakuEnabled,
            onChanged: (v) async {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _songDanmakuEnabled = v);
              await _settingsRepository.setSongDanmakuEnabled(v);
            },
          ),
        // MV 弹幕透明度：弹幕关闭时不显示（无可调对象）
        if (_mvDanmakuEnabled)
          // search: 弹幕透明度 弹幕 浓度
          ListTile(
            leading: Icon(Icons.opacity_outlined, color: colorScheme.primary),
            title: const Text('弹幕透明度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _mvDanmakuOpacity,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    label: '${(_mvDanmakuOpacity * 100).round()}%',
                    onChanged: (v) => setState(() => _mvDanmakuOpacity = v),
                    onChangeEnd: (v) => _settingsRepository.setMvDanmakuOpacity(v),
                  )
                : M3ESlider(
                    decoration: const M3ESliderDecoration(
                      haptic: M3EHapticFeedback.medium,
                    ),
                    value: _mvDanmakuOpacity,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    label: '${(_mvDanmakuOpacity * 100).round()}%',
                    // 拖动只改本地状态；松手才落盘，避免拖动过程中反复写 SharedPreferences
                    onChanged: (v) => setState(() => _mvDanmakuOpacity = v),
                    onChangeEnd: (v) => _settingsRepository.setMvDanmakuOpacity(v),
                  ),
            trailing: _statusText('${(_mvDanmakuOpacity * 100).round()}%'),
          ),
      ],
    );
  }

  /// 「列表与交互」三级子页：本地音乐评论区、MiniPlayer 滑动切歌、歌单排序、
  /// 封面流歌单源与 FM 电台。
  Widget _buildListInteractionSubpage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // 本地歌曲没有在线评论：默认关闭评论 tab 与「看评论」入口；
        // 关掉该开关后本地歌曲恢复显示，在线歌曲不受影响
        // search: 本地音乐 评论区 评论 tab 看评论 关闭评论 本地歌曲
        SwitchListTile(
          title: const Text('关闭本地音乐评论区'),
          value: _closeLocalMusicComments,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _closeLocalMusicComments = value;
            });
            // 播放器把该开关缓存在 PlayerProvider 字段里（切歌判定路径上读取），
            // 改完必须通知它，否则已挂载的全屏播放器本次运行内不重建 tab 结构
            context.read<PlayerProvider>().setCloseLocalMusicComments(value);
          },
        ),
        // 本地歌曲在线信息匹配：自动匹配开关（关闭时终止进行中的轮次）
        // search: 自动匹配 在线信息 匹配 封面 歌词 评论 本地歌曲
        SwitchListTile(
          title: const Text('自动匹配在线信息'),
          subtitle: const Text('为本地歌曲搜索匹配在线歌曲，补充封面、歌词与评论区'),
          value: _autoMatchOnlineInfo,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _autoMatchOnlineInfo = value);
            _settingsRepository.setAutoMatchOnlineInfo(value);
            if (!value) context.read<SongMatchProvider>().cancelAutoMatch();
          },
        ),
        // 立即匹配：忽略开关与冷却手动触发一轮；进度经 Provider 实时刷新
        Consumer<SongMatchProvider>(
          builder: (ctx, match, _) {
            final running = match.autoMatching;
            return ListTile(
              leading:
                  Icon(Icons.manage_search, color: colorScheme.primary),
              title: const Text('立即匹配未匹配歌曲'),
              subtitle: Text(
                running
                    ? '匹配中 ${match.autoMatchDone}/${match.autoMatchTotal}'
                    : '手动触发一轮全库匹配（忽略开关与冷却）',
              ),
              enabled: !running,
              onTap: () {
                AppHaptics.lightImpact(HapticCategory.control);
                unawaited(
                  ctx.read<SongMatchProvider>().runAutoMatch(force: true),
                );
                showToast('开始匹配未匹配的本地歌曲');
              },
            );
          },
        ),
        ListTile(
          leading: Icon(Icons.clear_all, color: colorScheme.primary),
          title: const Text('清除全部匹配记录'),
          subtitle: const Text('清空后自动匹配将重新搜索所有本地歌曲'),
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogCtx) => AlertDialog(
                title: const Text('清除全部匹配记录'),
                content: const Text(
                    '已匹配歌曲的封面兜底、歌词精确检索与评论区将回退到未匹配状态。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: const Text('清除'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            await SongMatchRepository().clearAll();
            if (!context.mounted) return;
            context.read<SongMatchProvider>().notifyChanged();
            showToast('已清除全部匹配记录');
          },
        ),
        // search: miniplayer 迷你播放条 滑动切歌 切歌
        SwitchListTile(
          title: const Text('MiniPlayer 滑动切歌'),
          subtitle: const Text('浮动迷你播放器暂不支持滑动切歌'),
          value: _miniPlayerSwipeSwitch,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _miniPlayerSwipeSwitch = value;
            });
            // 同步到全局开关，让已挂载的 MiniPlayer 实例实时生效
            miniPlayerSwipeSwitchEnabled.value = value;
            _settingsRepository.setMiniPlayerSwipeSwitchEnabled(value);
          },
        ),
        // search: 收藏 歌单 排序 最近点击 顺序
        SwitchListTile(
          title: const Text('收藏歌单按最近点击排序'),
          value: _sortCollectedByLatestClick,
          onChanged: (value) {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() {
              _sortCollectedByLatestClick = value;
            });
            _settingsRepository.setSortCollectedByLatestClick(value);
          },
        ),
        const Gap(AppSpacing.sm),
        _buildGroupLabel('封面流', colorScheme),
        // search-item: 封面流歌单源 | 封面流 数据源 歌单源 每日推荐 私人FM 红心 探索 小众 刷歌推荐 source
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_motion,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              const Expanded(child: Text('歌单源')),
              SizedBox(
                width: 150,
                child: TvDropdownMenu<CoverFlowSource>(
                  items: _coverFlowSourceItems,
                  singleSelect: true,
                  // 关闭 chip 动画：当前值渲染为可省略的纯文本
                  showChipAnimation: false,
                  fieldStyle: M3EDropdownFieldStyle(
                    hintText: '选择歌单源',
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  onSelectionChanged: (selected) {
                    // 单选下再次点击已选中项会被取消选中：强制重建恢复原值
                    if (selected.isEmpty) {
                      setState(() {});
                      return;
                    }
                    final next = selected.first.value;
                    if (next == kCoverFlowSource.value) return;
                    AppHaptics.lightImpact(HapticCategory.control);
                    // ignore: discarded_futures
                    SettingsRepository().setCoverFlowSourceRaw(next.rawValue);
                    kCoverFlowSource.value = next;
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 主页管理 section：Tab 显示/隐藏开关 + 拖拽排序（直接内嵌，免二次点击）
  Widget _buildTabManagementSection(ColorScheme colorScheme) {
    // search-item: 主页 Tab 管理 | tab 标签页 主页
    return const _TabManagementPanel();
  }

  /// 桌面快捷方式 section：Android 长按应用图标快捷入口的显示/隐藏、排序（直接内嵌，免二次点击）
  /// 震动反馈：总开关 + 七个交互类别细分。
  ///
  /// 状态直接读 [AppHaptics] 的内存态（调用点在判定瞬间读取，改完立即全站生效），
  /// 持久化也由它负责——若在这里另存一份 bool 字段，设置页与全站 150+ 个调用点
  /// 就会各持一份真相，重启后谁覆盖谁都不确定。
  /// 七个类别的 tile 逐个手写而非循环生成：设置搜索索引只能提取字面量 title。
  Widget _buildHapticsSection(ColorScheme colorScheme) {
    // 进入时刷新一次实测输出延迟（探针只在播放中有意义）
    // ignore: discarded_futures
    MusicHapticsService.instance.refreshMeasuredLatency();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Gap(AppSpacing.sm),
        // search: 震动 振动 马达 触觉 haptic 反馈 手感 震感 不震动 关闭震动
        SwitchListTile(
          title: const Text('震动反馈'),
          subtitle: const Text('总开关。关闭后全站按钮、滑块与手势都不再震动'),
          value: AppHaptics.enabled,
          onChanged: (value) {
            // 先给本次操作留一点手感，再落盘：关总开关时这次仍会震动，
            // 与全站「开关改动即反馈」的既有约定一致。
            AppHaptics.lightImpact(HapticCategory.control);
            AppHaptics.setEnabled(value);
            // 总开关也参与震动服务的采集判定：关掉后立刻拆掉频谱采集，
            // 不让 FFT 为一个永远不点火的震动空转。
            MusicHapticsService.instance.refreshCapture();
            setState(() {});
          },
        ),
        // 以下七项是总开关的从属项：关着时类别细分没有意义，直接隐藏
        if (AppHaptics.enabled) ...[
          const SettingsGroupHeading('按类别控制'),
          // search: 播放控制 播放键 暂停 上一首 下一首 切歌 播放模式 收藏 红心 进度条
          SwitchListTile(
            title: const Text('播放控制按钮'),
            subtitle: const Text('播放/暂停、上一首/下一首、播放模式、收藏、进度条落点'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.transport),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.transport, value),
          ),
          // 下面七个开关保持常驻，只把「震动类型」按类别开条件：类型是关着时选
          // 哪种都不震动，但开关本身一旦跟着条件消失就没有入口能再把它打开。
          // search: 播放控制 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.transport))
            ListTile(
              title: const Text('播放控制的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.transport),
            ),
          // search: 列表 歌曲行 歌单行 条目 点击 长按 更多菜单 评论行
          SwitchListTile(
            title: const Text('列表条目'),
            subtitle: const Text('歌曲行、歌单行的点击与长按，评论行的点击'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.listItem),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.listItem, value),
          ),
          // search: 列表条目 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.listItem))
            ListTile(
              title: const Text('列表条目的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.listItem),
            ),
          // search: 导航 底部导航栏 标签 切换 分段控件 侧边栏 tab
          SwitchListTile(
            title: const Text('导航切换'),
            subtitle: const Text('底部导航栏与侧边栏、分段控件、播放页标签条'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.navigation),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.navigation, value),
          ),
          // search: 导航切换 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.navigation))
            ListTile(
              title: const Text('导航切换的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.navigation),
            ),
          // search: 开关 按钮 下拉菜单 复选 单选 按压 设置项
          SwitchListTile(
            title: const Text('开关与按钮'),
            subtitle: const Text('设置项开关、下拉菜单与各类按钮的按压反馈'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.control),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.control, value),
          ),
          // search: 开关与按钮 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.control))
            ListTile(
              title: const Text('开关与按钮的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.control),
            ),
          // search: 滑块 拖动 音量条 进度条 刻度 吸附 滑条
          SwitchListTile(
            title: const Text('滑块调节'),
            subtitle: const Text('音量、进度条与设置类滑块的拖动与吸附（含 m3e 滑条）'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.slider),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.slider, value),
          ),
          // search: 滑块调节 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.slider))
            ListTile(
              title: const Text('滑块调节的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.slider),
            ),
          // search: 手势 长按 封面 滑动切歌 歌词行 下拉刷新 拖拽
          SwitchListTile(
            title: const Text('手势与长按'),
            subtitle: const Text('长按封面、滑动切歌、点击歌词行、下拉刷新'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.gesture),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.gesture, value),
          ),
          // search: 手势与长按 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.gesture))
            ListTile(
              title: const Text('手势与长按的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.gesture),
            ),
          // search: 悬浮 迷你播放器 播放条 悬浮条 圆盘 拖拽 拖动 长按 secondary mini player
          SwitchListTile(
            title: const Text('悬浮播放器拖拽'),
            subtitle: const Text('拖动或长按拾起悬浮圆盘时的震动；浮起动效不受本开关影响'),
            value: AppHaptics.isCategoryEnabled(HapticCategory.floatingPlayer),
            onChanged: (value) =>
                _setHapticCategoryEnabled(HapticCategory.floatingPlayer, value),
          ),
          // search: 悬浮播放器拖拽 震动类型 类型 强度 效果 预定义 轻点 刻度 重击 双击 长按
          if (AppHaptics.isCategoryEnabled(HapticCategory.floatingPlayer))
            ListTile(
              title: const Text('悬浮播放器拖拽的震动类型'),
              subtitle: _hapticTypeDropdown(HapticCategory.floatingPlayer),
            ),
        ],
        const SettingsGroupHeading('音乐节奏震动'),
        // search: 音乐 节奏 鼓点 节拍 震动 低音 马达 踩点 律动
        SwitchListTile(
          title: const Text('音乐节奏震动'),
          subtitle: const Text('跟着鼓点震动。默认关闭；播放中生效，无需开启频谱显示，范围可在下方选择'),
          value: _musicHapticsEnabled,
          onChanged: (value) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _musicHapticsEnabled = value);
            await _settingsRepository.setMusicHapticsEnabled(value);
            await MusicHapticsService.instance.setEnabled(value);
          },
        ),
        if (_musicHapticsEnabled) ...[
          // search: 生效范围 范围 播放页 应用内 后台 始终 什么时候震 震动范围
          ListTile(
            title: const Text('生效范围'),
            subtitle: _musicHapticsScopeDropdown(),
          ),
          // search: 强度 力度 震感 振幅
          ListTile(
            title: const Text('震动强度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _musicHapticsStrength,
                    min: 0.2,
                    max: 1.0,
                    divisions: 8,
                    label: '${(_musicHapticsStrength * 100).round()}%',
                    onChanged: (v) async {
                      setState(() => _musicHapticsStrength = v);
                      await _settingsRepository.setMusicHapticsStrength(v);
                      await MusicHapticsService.instance.setStrength(v);
                    },
                  )
                : M3ESlider(
                    decoration: kSettingsSliderDecoration,
                    value: _musicHapticsStrength,
                    min: 0.2,
                    max: 1.0,
                    divisions: 8,
                    label: '${(_musicHapticsStrength * 100).round()}%',
                    onChanged: (v) async {
                      setState(() => _musicHapticsStrength = v);
                      await _settingsRepository.setMusicHapticsStrength(v);
                      await MusicHapticsService.instance.setStrength(v);
                    },
                  ),
            trailing: _statusText('${(_musicHapticsStrength * 100).round()}%'),
          ),
          // search: 灵敏度 敏感 阈值 漏拍 误触发
          ListTile(
            title: const Text('检测灵敏度'),
            // tv: TV 构建换 RemoteSlider（P-C）
            subtitle: kTvBuild
                ? RemoteSlider(
                    value: _musicHapticsSensitivity,
                    min: 0.3,
                    max: 3.0,
                    // 无极连续调节：阈值是模拟量，27 档的节点反而限制手感
                    label: _musicHapticsSensitivity.toStringAsFixed(2),
                    onChanged: (v) async {
                      setState(() => _musicHapticsSensitivity = v);
                      await _settingsRepository.setMusicHapticsSensitivity(v);
                      await MusicHapticsService.instance.setSensitivity(v);
                    },
                  )
                : M3ESlider(
                    decoration: kFreeSliderDecoration,
                    value: _musicHapticsSensitivity,
                    min: 0.3,
                    max: 3.0,
                    // 无极连续调节：阈值是模拟量，27 档的节点反而限制手感
                    label: _musicHapticsSensitivity.toStringAsFixed(2),
                    onChanged: (v) async {
                      setState(() => _musicHapticsSensitivity = v);
                      await _settingsRepository.setMusicHapticsSensitivity(v);
                      await MusicHapticsService.instance.setSensitivity(v);
                    },
                  ),
            trailing: _statusText(_musicHapticsSensitivity.toStringAsFixed(2)),
          ),
          // search: 波形 触感 清脆 脉冲 平滑 手感 包络 衰减
          ListTile(
            title: const Text('触感波形'),
            subtitle: M3EToggleButtonGroup(
              actions: [
                // 清脆 = 交互开关同款的系统预定义触感（createPredefined），无拖尾
                const M3EToggleButtonGroupAction(label: Text('清脆')),
                const M3EToggleButtonGroupAction(label: Text('脉冲')),
                M3EToggleButtonGroupAction(
                  label: const Text('平滑'),
                  // 无振幅控制的设备上平滑波形会退化成二值振动，比脉冲更差（见计划 D2）
                  enabled: MusicHapticsService.instance.hasAmplitudeControl,
                ),
              ],
              selectedIndex: switch (_musicHapticsWaveform) {
                'pulse' => 1,
                'smooth' => 2,
                _ => 0,
              },
              onSelectedIndexChanged: (index) async {
                if (index == null) return;
                const values = ['auto', 'pulse', 'smooth'];
                final value = values[index];
                setState(() => _musicHapticsWaveform = value);
                await _settingsRepository.setMusicHapticsWaveform(value);
                await MusicHapticsService.instance.setWaveform(
                  MusicHapticsWaveform.fromNativeName(value),
                );
              },
            ),
          ),
          // search: 偏移 延迟 补偿 对齐 滞后 提前 offset 拍点
          ListTile(
            title: const Text('节奏偏移'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // tv: TV 构建换 RemoteSlider（P-C）
                kTvBuild
                    ? RemoteSlider(
                        value: _musicHapticsOffset.toDouble(),
                        min: 0,
                        max: MusicHapticsService.maxOffsetMs.toDouble(),
                        // 无极连续调节：偏移本质是模拟量，10ms 一档的节点反而限制手感
                        label: '+${_musicHapticsOffset}ms',
                        onChanged: (v) {
                          // 拖动中只预览（内存态 + 下发原生），松手才落盘
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          MusicHapticsService.instance.previewOffset(ms);
                        },
                        onChangeEnd: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          _settingsRepository.setMusicHapticsOffset(ms);
                          MusicHapticsService.instance.setOffset(ms);
                        },
                      )
                    : M3ESlider(
                        decoration: kFreeSliderDecoration,
                        value: _musicHapticsOffset.toDouble(),
                        min: 0,
                        max: MusicHapticsService.maxOffsetMs.toDouble(),
                        // 无极连续调节：偏移本质是模拟量，10ms 一档的节点反而限制手感
                        label: '+${_musicHapticsOffset}ms',
                        onChanged: (v) {
                          // 拖动中只预览（内存态 + 下发原生），松手才落盘
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          MusicHapticsService.instance.previewOffset(ms);
                        },
                        onChangeEnd: (v) {
                          final ms = v.round();
                          setState(() => _musicHapticsOffset = ms);
                          _settingsRepository.setMusicHapticsOffset(ms);
                          MusicHapticsService.instance.setOffset(ms);
                        },
                      ),
                Center(child: _statusText('+${_musicHapticsOffset}ms')),
                _offsetAutoRow(),
              ],
            ),
          ),
          // search: 高频 军鼓 踩镲 镲片 细节
          SwitchListTile(
            title: const Text('高频触发'),
            subtitle: const Text('让军鼓、踩镲这类高频瞬态也震一下。关掉只剩低音鼓'),
            value: _musicHapticsSnare,
            onChanged: (value) async {
              AppHaptics.lightImpact(HapticCategory.control);
              setState(() => _musicHapticsSnare = value);
              await _settingsRepository.setMusicHapticsSnare(value);
              await MusicHapticsService.instance.setSnareEnabled(value);
            },
          ),
          // search: 设备 能力 马达 状态 阈值 振幅 排障
          ListTile(
            title: const Text('设备能力与当前阈值'),
            subtitle: Text(
              '${MusicHapticsService.instance.nativeAvailable ? (MusicHapticsService.instance.hasAmplitudeControl ? '马达可用，支持振幅控制（平滑波形可用）' : '马达可用，不支持振幅控制（平滑波形置灰）') : '未检测到可用马达，本功能不会生效'}'
              '\n低频阈值 ${MusicHapticsService.instance.kickThreshold.toStringAsFixed(4)}'
              ' / 高频阈值 ${MusicHapticsService.instance.snareThreshold.toStringAsFixed(4)}',
            ),
          ),
        ],
      ],
    );
  }

  void _setHapticCategoryEnabled(HapticCategory category, bool value) {
    AppHaptics.lightImpact(HapticCategory.control);
    AppHaptics.setCategoryEnabled(category, value);
    setState(() {});
  }

  /// 单个类别的震动类型下拉：七类共用一份配置，避免把同样的菜单复制七遍。
  ///
  /// 选项里首项「默认」对应 `null`，即回到「各触点保持自身强度」；其余项直接把
  /// [HapticType] 的预定义效果套到整类上。持久化与闸门都在 [AppHaptics] 内。
  Widget _hapticTypeDropdown(HapticCategory category) {
    final current = AppHaptics.typeFor(category);
    return TvDropdownMenu<String>(
      items: [
        M3EDropdownItem(label: '默认', value: '', selected: current == null),
        for (final type in HapticType.values)
          M3EDropdownItem(
            label: type.label,
            value: type.nativeName,
            selected: current == type,
          ),
      ],
      singleSelect: true,
      // 单选下关闭 chip 动画，当前值才会渲染为可省略的纯文本
      showChipAnimation: false,
      fieldStyle: const M3EDropdownFieldStyle(
        hintText: '选择该类别的震动类型',
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      onSelectionChanged: (selected) {
        // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
        if (selected.isEmpty) {
          setState(() {});
          return;
        }
        // 空串解析为 null = 回到「默认（各触点自身强度）」
        final resolved = HapticType.fromNativeName(selected.first.value);
        // 同值必须直接返回，不能只靠 setCategoryType 内部的幂等：
        // M3EDropdownController.setItems 末尾会同步回调 onSelectionChanged，
        // 而本 tile 的 items 每次 build 都是新列表（引用不等），didUpdateWidget 必然
        // 再走一次 setItems —— 于是 setState → 重建 → setItems → 回调 → setState 会
        // 无限回环（真机表现为选完类型直接卡死，且每圈还多震一下）。
        // 上面 selected.isEmpty 分支不会成环：重建后控制器回传的是当前选中项，
        // 走到这里就被本守卫拦住。与既有「播放内容」tile 同一手法。
        if (resolved == AppHaptics.typeFor(category)) return;
        AppHaptics.setCategoryType(category, resolved);
        setState(() {});
        // 预览用 click 是刻意的：本类别一旦指定了类型，AppHaptics 会优先解析该
        // 覆盖，所以这一次调用发出来的正是用户刚选中的那个效果（选「默认」时
        // 无覆盖，click 回落为轻点，等价于「恢复原本的轻点」）。
        AppHaptics.click(category);
      },
    );
  }

  /// 震动生效范围下拉：播放页 / App 内 / 始终 三档。
  ///
  /// 结构与 [_hapticTypeDropdown] 一致（含同值防回环守卫，原因见其注释）。
  Widget _musicHapticsScopeDropdown() {
    return TvDropdownMenu<String>(
      items: [
        for (final scope in MusicHapticsScope.values)
          M3EDropdownItem(
            label: scope.label,
            value: scope.persistKey,
            selected: _musicHapticsScope == scope.persistKey,
          ),
      ],
      singleSelect: true,
      // 单选下关闭 chip 动画，当前值才会渲染为可省略的纯文本
      showChipAnimation: false,
      fieldStyle: const M3EDropdownFieldStyle(
        hintText: '选择震动的生效范围',
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      onSelectionChanged: (selected) {
        // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
        if (selected.isEmpty) {
          setState(() {});
          return;
        }
        // 防回环守卫：setItems 的同步回传会带着当前值再进来一次
        final value = selected.first.value;
        if (value == _musicHapticsScope) return;
        setState(() => _musicHapticsScope = value);
        // ignore: discarded_futures
        _settingsRepository.setMusicHapticsScope(value);
        // ignore: discarded_futures
        MusicHapticsService.instance
            .setScope(MusicHapticsScope.fromPersistKey(value));
      },
    );
  }

  Widget _buildDesktopShortcutSection(ColorScheme colorScheme) {
    // search-item: 桌面快捷方式 | 快捷方式 快捷 长按
    return const _DesktopShortcutPanel();
  }

  /// AI 代理接口（MCP）section：外部 AI 客户端经 MCP 调用播放器的全部设置。
  /// 独立一栏而非并入「缓存与数据」：能力面与风险面都独立，需要单独可见/可控。
  Widget _buildAiAgentSection(ColorScheme colorScheme) {
    // search-item: AI 代理接口 | AI 代理 mcp 大模型 智能体 claude 调用
    return const McpAgentSection();
  }

  /// 本地持久化音频管理 section 未包含在公开版本中。

  /// 恢复 32bit 播放开关并同步到字段（从 UsbAudioService 缓存读取，已持久化+下发原生）。
  Future<void> _initEnable32bit() async {
    await UsbAudioService.instance.initEnable32bit();
    if (!mounted) return;
    setState(() => _enable32bitOutput = UsbAudioService.instance.enable32bit);
  }

  Future<void> _setEnable32bitOutput(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() => _enable32bitOutput = value);
    await UsbAudioService.instance.setEnable32bit(value);
  }

  /// 询问是否重启本地 API 服务器，确认后重启并更新端口展示。
  Future<void> _confirmRestartServer() async {
    final port = KugouApiServer.currentPort;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重启本地 API 服务器'),
        content: Text(
          '确定要重启本地 Rust API 服务器吗？\n当前端口：$port\n重启后将重新分配随机端口。\n如果你遇到了玄学问题，那就重启一下试试吧（）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重启'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRestarting = true);
    try {
      final ok = await KugouApiServer.restart();
      if (!mounted) return;
      setState(() {});
      showToast(
        ok ? '已重启，新端口：${KugouApiServer.currentPort}' : '重启失败，服务器未就绪',
        long: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {});
      showToast('重启失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _isRestarting = false);
    }
  }

  /// 缓存与数据（已并入原「在线音乐」二级页的内容）。
  Widget _buildCacheSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupLabel('本地服务', colorScheme, first: true),
        // 原「在线音乐」页内容：本地 Rust 服务器状态与重启入口
        // search: 接口 本地服务器 api 在线音乐
        ListTile(
          leading: Icon(Icons.dns, color: colorScheme.primary),
          title: const Text('本地数据接口'),
          subtitle: Text('端口：${KugouApiServer.currentPort}'),
          trailing: _isRestarting
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: M3ECircularProgressIndicator(
                    size: 20,
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                )
              : Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: AppRadius.mdAll,
                  ),
                  child: Text(
                    '运行中',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
          onTap: _isRestarting ? null : _confirmRestartServer,
        ),
        _settingsDescription(
          context,
          '本地 Rust 服务器运行中，推荐/排行/搜索/播放/登录等数据接口均通过本地处理（点击上方可重启）',
          colorScheme,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
        ),
        _buildGroupLabel('存储维护', colorScheme),
        // search: 缓存 清除
        ListTile(
          title: const Text('清除缓存'),
          leading: Icon(Icons.delete_outline, color: colorScheme.error),
          onTap: () => _showClearCacheDialog(),
        ),
        // search: 迁移 数据 修复
        ListTile(
          title: const Text('数据迁移（修复数据混乱）'),
          leading: Icon(Icons.bug_report, color: colorScheme.tertiary),
          onTap: () => _showDataMigrationDialog(),
        ),
      ],
    );
  }

  Future<void> _showDataMigrationDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔧 数据迁移'),
        content: const Text(
          '此操作将清除旧版本的登录数据，修复可能的数据混乱问题。\n\n'
          '执行后需要重新登录。\n\n'
          '是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('执行'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final prefs = await SharedPreferences.getInstance();

        // 清除旧版本的全局键
        await prefs.remove('kugou_token');
        await prefs.remove('kugou_userid');
        await prefs.remove('kugou_vip_token');
        await prefs.remove('kugou_dfid');
        await prefs.remove('kugou_current_userid');

        if (!mounted) return;

        showToast('✅ 数据迁移完成，请重新登录', long: true);

        // 退出登录
        context.read<KugouProvider>().logout();

        // 返回上一页
        Navigator.of(context).pop();
      } catch (e) {
        if (!mounted) return;
        showToast('❌ 数据迁移失败: $e', long: true);
      }
    }
  }

  /// 关于 section：版本（含构建期渲染引擎）→ 帮助 → 法律与许可。
  Widget _buildAboutSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ① 版本：先看当前版本，再去更新
        _buildGroupLabel('版本', colorScheme, first: true),
        // search: 版本 检查更新
        ListTile(
          title: const Text('应用版本'),
          subtitle: Text(_appVersion.isEmpty ? kBuildAppVersion : _appVersion),
          leading: const Icon(Icons.info_outline),
        ),
        // search: 更新 新版本 升级 upgrade 提醒
        SwitchListTile(
          title: const Text('新版本提醒'),
          subtitle: const Text('启动时检查 GitHub 发布的新版本，发现后提示一次'),
          value: _updateReminderEnabled,
          onChanged: (value) {
            // ignore: discarded_futures
            _setUpdateReminderEnabled(value);
          },
        ),
        if (Platform.isAndroid) ...[
          // search: 图标 旧版 桌面图标 恢复
          SwitchListTile(
            title: const Text('还原旧版本 App 图标'),
            subtitle: const Text('将桌面图标切换为旧版渐变音符图标'),
            value: _legacyAppIconEnabled,
            onChanged: (value) {
              // ignore: discarded_futures
              _setLegacyAppIconEnabled(value);
            },
          ),
        ],
        // search: 更新
        ListTile(
          title: const Text('更新最新版本'),
          subtitle: Text(
            _pendingUpdateVersion.isEmpty
                ? 'https://github.com/zzyoxml/md3Music/releases'
                : '有新版 v$_pendingUpdateVersion 可用，点击前往下载',
          ),
          leading: const Icon(Icons.system_update_outlined),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openReleasesUrl(),
        ),
        // 渲染引擎与版本号同属"当前构建的事实"，故并入版本组：
        // 由构建期 flavor 决定（skia / impeller），运行时不可切换，只读展示。
        // search: 渲染引擎 渲染 引擎 图形 兼容 skia impeller 构建
        FutureBuilder<String>(
          future: _readCurrentRenderEngine(),
          builder: (context, snap) {
            final engine = snap.data == null
                ? 'skia'
                : (snap.data == 'impeller' ? 'Impeller' : 'Skia');
            return ListTile(
              leading: Icon(
                Icons.high_quality_outlined,
                color: colorScheme.primary,
              ),
              title: const Text('当前渲染引擎'),
              subtitle: Text(engine),
            );
          },
        ),
        _settingsDescription(
          context,
          '渲染引擎在应用构建时确定，运行中无法切换。· Skia 版：兼容性优先，适用于 32 位/老旧设备；· Impeller 版：图形更流畅，适用于新设备。如需切换，请安装对应构建版本。',
          colorScheme,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          singleLineLandscape: true,
        ),
        // ② 帮助
        _buildGroupLabel('帮助', colorScheme),
        // search: 教程 引导
        ListTile(
          title: const Text('新手教程'),
          leading: const Icon(Icons.school_outlined),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => OnboardingPage(isReview: true)),
            );
          },
        ),
        // search: 日志 诊断 导出 反馈 bug log
        ListTile(
          title: const Text('导出诊断日志'),
          leading: const Icon(Icons.bug_report_outlined),
          trailing: _isExportingLogs
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.share_outlined, size: 18),
          onTap: _isExportingLogs ? null : _exportDiagnosticLogs,
        ),
        // search: 清空日志 删除日志
        ListTile(
          title: const Text('清空诊断日志'),
          leading: const Icon(Icons.delete_outline),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _showClearDiagnosticLogsDialog,
        ),
        // ③ 法律与许可：协议 → 免责 → 开源许可
        _buildGroupLabel('法律与许可', colorScheme),
        // search: 协议 条款
        ListTile(
          title: const Text('用户协议'),
          leading: const Icon(Icons.handshake_outlined),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserAgreementPage(
                  isFirstLaunch: false,
                  isReview: true,
                  onAgreed: () => Navigator.of(context).pop(),
                ),
              ),
            );
          },
        ),
        // search: 免责
        ListTile(
          title: const Text('免责声明'),
          leading: const Icon(Icons.gavel_outlined),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => UserAgreementPage.showDisclaimerDialog(context),
        ),
        // search: 开源 license 许可
        ListTile(
          title: const Text('开源许可'),
          leading: const Icon(Icons.description_outlined),
          onTap: () {
            showLicensePage(
              context: context,
              applicationName: 'MD3Music',
              applicationVersion: _appVersion.isEmpty
                  ? kBuildAppVersion
                  : _appVersion,
            );
          },
        ),
      ],
    );
  }

  Future<void> _openReleasesUrl() async {
    const url = 'https://github.com/zzyoxml/md3Music/releases';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 导出诊断日志：构建 zip 报告 → 打开系统分享面板。
  Future<void> _exportDiagnosticLogs() async {
    if (_isExportingLogs) return;
    setState(() => _isExportingLogs = true);
    try {
      await DiagnosticExporter.shareReport();
    } catch (e) {
      // debugPrint 已被诊断日志服务捕获，错误会自动留痕
      debugPrint('导出诊断日志失败: $e');
      if (mounted) showToast('导出失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _isExportingLogs = false);
    }
  }

  /// 清空诊断日志：二次确认后删除。
  void _showClearDiagnosticLogsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清空诊断日志'),
          content: const Text('确定要删除本机记录的所有诊断日志吗？此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await DiagnosticExporter.clearLogs();
                  if (mounted) showToast('已清空诊断日志');
                } catch (e) {
                  if (mounted) showToast('清空失败：$e', long: true);
                }
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showClearCacheDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清除缓存'),
          content: const Text('确定要清除所有缓存数据吗？此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _doClearCache();
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _doClearCache() async {
    try {
      // 1. 清图片缓存
      await DefaultCacheManager().emptyCache();
      // 2. 清 app 临时目录（Android 系统设置里的"清除缓存"也指这个）
      try {
        final dir = await getTemporaryDirectory();
        if (dir.existsSync()) {
          for (final entity in dir.listSync()) {
            try {
              if (entity is Directory) {
                entity.deleteSync(recursive: true);
              } else {
                entity.deleteSync();
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      // 3. 清 KugouProvider 内存
      if (mounted) {
        context.read<KugouProvider>().clearMemoryCache();
      }
      // 4. 重置发现页日期标志
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('discover_last_date');
      _settingsRepository.setCacheSize(0);
    } catch (e) {
      debugPrint('Clear cache error: $e');
    }
    if (mounted) {
      showToast('已清除缓存', long: true);
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 播放器风格卡片选择
  // ─────────────────────────────────────────────────────────────────────

  Widget _buildStyleCards(ColorScheme colorScheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildStyleCard(
          colorScheme: colorScheme,
          title: 'MD3Music',
          subtitle: 'Material 3 风格',
          isSelected: !_useAmStylePlayer,
          onTap: () {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useAmStylePlayer = false);
            context.read<ThemeProvider>().setUseAmStylePlayer(false);
          },
          preview: _SettingsMd3StylePreview(colorScheme: colorScheme),
        ),
        const Gap(AppSpacing.lg),
        _buildStyleCard(
          colorScheme: colorScheme,
          title: 'Apple Music',
          subtitle: '模糊封面 + 逐字歌词',
          isSelected: _useAmStylePlayer,
          onTap: () {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _useAmStylePlayer = true);
            context.read<ThemeProvider>().setUseAmStylePlayer(true);
          },
          preview: _SettingsAmStylePreview(colorScheme: colorScheme),
        ),
      ],
    );
  }

  Widget _buildStyleCard({
    required ColorScheme colorScheme,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    required Widget preview,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: M3ExpressiveMotion.defaultDuration,
          curve: M3ExpressiveMotion.expressiveEasing,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
              width: isSelected ? 2.5 : 1,
            ),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  height: 140,
                  width: double.infinity,
                  // 迷你界面示意图：高度固定 140、宽度受 Expanded 约束，
                  // 内部元素（28dp 顶栏、24dp 图标块）没有余量跟随系统字号，
                  // 字一放大就撑破。这里豁免系统字号，让预览恒按真实比例呈现。
                  // 「显示大小」不在此列 —— 它整页等比变化，预览随之整体缩放。
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.noScaling),
                    child: preview,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (isSelected) ...[
                const SizedBox(height: 6),
                Icon(Icons.check_circle, size: 20, color: colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Tab 管理面板：支持拖拽排序 + 显示/隐藏开关。
///
/// “我的”页面不允许隐藏（保证用户始终有入口进入设置/登录）。
/// 主页 Tab 管理面板：支持拖拽排序 + 显示/隐藏开关。
///
/// 直接内嵌于设置页「主页管理」二级卡片；外层已是 ListView，
/// 故 ReorderableListView 以 shrinkWrap + 不滚动方式布局。
class _TabManagementPanel extends StatelessWidget {
  const _TabManagementPanel();

  @override
  Widget build(BuildContext context) {
    // 与 LaunchPad 编辑托盘共用同一套主页管理组件（见 home_tab_manager.dart）。
    // 内嵌于设置页 ListView，故 embedded: true（shrinkWrap + 不滚动）。
    return const HomeTabManagerList(embedded: true);
  }
}

/// 设置页说明文字：始终占满可用横向空间，并从内容区左侧开始排版。
///
/// 横屏时如果只使用 Padding + Text，父级 Column 的默认居中布局会让
/// Text 按自身内容宽度整体居中；这里用 stretch/Align 固定说明文字的
/// 布局边界，避免不同设置区重复出现同类问题。
Widget _settingsDescription(
  BuildContext context,
  String text,
  ColorScheme colorScheme, {
  EdgeInsets padding = const EdgeInsets.fromLTRB(
    AppSpacing.lg,
    AppSpacing.xs,
    AppSpacing.lg,
    AppSpacing.md,
  ),
  bool singleLineLandscape = false,
}) {
  final singleLine =
      singleLineLandscape &&
      MediaQuery.of(context).orientation == Orientation.landscape;
  final textWidget = Text(
    text,
    maxLines: singleLine ? 1 : null,
    softWrap: !singleLine,
    textAlign: TextAlign.start,
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
  );
  return SizedBox(
    width: double.infinity,
    child: Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: singleLine
            ? FittedBox(
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
                child: textWidget,
              )
            : textWidget,
      ),
    ),
  );
}

/// 主页 tab / 桌面快捷方式的图标映射（与 app.dart / launchpad 保持一致）。
IconData _tabIconForId(String tabId) {
  switch (tabId) {
    case 'launchpad':
      // 与主页 tab 图标保持一致（见 app.dart 的 launchpad case）
      return Icons.grid_view;
    case 'discover':
      return Icons.explore;
    case 'coverflow':
      // 与主页 tab 图标保持一致（见 app.dart 的 coverflow case）
      return Icons.album;
    case 'library':
      return Icons.library_music;
    case 'favorites':
      return Icons.favorite;
    case 'fm':
      return Icons.radio;
    case 'search':
      return Icons.search;
    case 'charts':
      return Icons.leaderboard;
    case 'ip':
      return Icons.edit_note;
    case 'recognition':
      return Icons.mic;
    case 'audiobook':
      return Icons.auto_stories;
    case 'scene':
      // 与主页 tab 图标保持一致（见 app.dart 的 scene case）
      return Icons.landscape;
    case 'channel':
      // 与主页 tab 图标保持一致（见 app.dart 的 channel case）
      return Icons.dynamic_feed;
    case 'brush':
      // 与主页 tab 图标保持一致（见 app.dart 的 brush case）
      return Icons.swipe;
    case 'settings':
      // 与主页 tab 图标保持一致（见 app.dart 的 settings case）
      return Icons.settings;
    case 'user':
      return Icons.person;
    default:
      return Icons.circle;
  }
}

/// 桌面快捷方式管理面板：支持拖拽排序 + 显示/隐藏开关。
///
/// 配置持久化由 [ShortcutConfigProvider] 负责，变更后 _AppView 会重新
/// 注册 Android 长按应用图标快捷入口。
/// 直接内嵌于设置页「桌面快捷方式」二级卡片；外层已是 ListView，
/// 故 ReorderableListView 以 shrinkWrap + 不滚动方式布局。
class _DesktopShortcutPanel extends StatelessWidget {
  const _DesktopShortcutPanel();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shortcutConfig = context.watch<ShortcutConfigProvider>();
    final allShortcuts = shortcutConfig.allShortcuts;
    final hiddenIds = shortcutConfig.hiddenIds;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '桌面快捷方式',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => shortcutConfig.resetToDefault(),
                child: const Text('重置'),
              ),
            ],
          ),
        ),
        _settingsDescription(
          context,
          '长按应用图标弹出；拖拽排序、开关显示/隐藏',
          colorScheme,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        ),
        const Gap(AppSpacing.sm),
        M3EReorderableDismissibleList(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          listPadding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: allShortcuts.length,
          // key 由 M3E 内部套用（KeyedSubtree），保证重排后行状态稳定
          keyBuilder: (index) => ValueKey(allShortcuts[index].id),
          // 索引语义与 ReorderableListView 一致（M3E 内部已在 to > from 时补 +1），
          // 因此 provider 侧不需要任何换算
          onReorder: (oldIndex, newIndex) {
            shortcutConfig.reorderShortcuts(oldIndex, newIndex);
          },
          // 置零卡片自身样式 + 关掉滑动（本列表只有显示/隐藏，没有删除）
          style: const M3EDismissibleCardStyle(
            outerRadius: 0,
            innerRadius: 0,
            gap: 0,
            padding: EdgeInsets.zero,
            color: Colors.transparent,
            direction: DismissDirection.none,
          ),
          itemBuilder: (context, index) {
            final shortcut = allShortcuts[index];
            final isHidden = hiddenIds.contains(shortcut.id);
            // search: -
            return ListTile(
              leading: Icon(
                _tabIconForId(shortcut.id),
                color: isHidden
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.primary,
              ),
              title: Text(
                shortcut.label,
                style: TextStyle(
                  color: isHidden ? colorScheme.onSurfaceVariant : null,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: !isHidden,
                    onChanged: (_) {
                      AppHaptics.lightImpact(HapticCategory.control);
                      shortcutConfig.toggleShortcutVisibility(shortcut.id);
                    },
                  ),
                  Icon(
                    Icons.drag_handle,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// 播放器风格预览组件
// ─────────────────────────────────────────────────────────────────────

/// MD3Music 风格播放器预览：简洁的 Material 3 卡片布局。
class _SettingsMd3StylePreview extends StatelessWidget {
  final ColorScheme colorScheme;

  const _SettingsMd3StylePreview({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // 顶栏
          Container(
            height: 28,
            color: colorScheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const Spacer(),
                Icon(
                  Icons.more_horiz,
                  size: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          // 封面
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  Expanded(
                    flex: 3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.music_note,
                          size: 32,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    height: 5,
                    width: 55,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurface,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    height: 4,
                    width: 36,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(
                        Icons.skip_previous,
                        size: 16,
                        color: colorScheme.onSurface,
                      ),
                      Icon(
                        Icons.play_arrow,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      Icon(
                        Icons.skip_next,
                        size: 16,
                        color: colorScheme.onSurface,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Apple Music 风格播放器预览：模糊封面背景 + 逐字歌词。
class _SettingsAmStylePreview extends StatelessWidget {
  final ColorScheme colorScheme;

  const _SettingsAmStylePreview({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colorScheme.primary.withValues(alpha: 0.6),
            colorScheme.surface,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: colorScheme.onSurface,
                ),
                const Spacer(),
                Icon(Icons.more_horiz, size: 12, color: colorScheme.onSurface),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLyricBar(45, colorScheme.onSurface, 0.2),
                  const SizedBox(height: 5),
                  _buildLyricBar(70, colorScheme.primary, 1.0),
                  const SizedBox(height: 5),
                  _buildLyricBar(40, colorScheme.onSurface, 0.2),
                  const SizedBox(height: 5),
                  _buildLyricBar(30, colorScheme.onSurface, 0.1),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.music_note,
                    size: 12,
                    color: colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 4,
                        width: 40,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: 3,
                        width: 26,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.play_arrow, size: 16, color: colorScheme.onSurface),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricBar(double width, Color color, double opacity) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 6,
        width: width,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// 逐字歌词时间偏移设置（仅在线音乐生效）。
///
/// 滑块精调 ±1500ms，输入框支持 ±10000ms；正值 = 歌词延后显示。
/// 修改即时写入 [SettingsRepository.lyricTimeOffsetMs] 内存缓存并持久化，
/// 播放页每帧读取该缓存，无需重启即可生效。
class _LyricTimeOffsetTile extends StatefulWidget {
  const _LyricTimeOffsetTile();

  @override
  State<_LyricTimeOffsetTile> createState() => _LyricTimeOffsetTileState();
}

class _LyricTimeOffsetTileState extends State<_LyricTimeOffsetTile> {
  static const int _sliderMin = -1500;
  static const int _sliderMax = 1500;
  static const int _limit = 10000;

  final TextEditingController _controller = TextEditingController();
  late int _offset;

  @override
  void initState() {
    super.initState();
    _offset = SettingsRepository.lyricTimeOffsetMs.value;
    _controller.text = _offset.toString();
    _load();
  }

  Future<void> _load() async {
    final v = await SettingsRepository().getLyricTimeOffset();
    if (!mounted) return;
    setState(() {
      _offset = v;
      _controller.text = v.toString();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 应用新偏移：更新 UI + 写内存缓存 + 持久化。
  void _apply(int v) {
    final clamped = v.clamp(-_limit, _limit);
    setState(() {
      _offset = clamped;
      _controller.text = clamped.toString();
    });
    // ignore: discarded_futures
    SettingsRepository().setLyricTimeOffset(clamped);
  }

  /// 从输入框提交：非法输入回退为当前值。
  void _submitFromField() {
    final v = int.tryParse(_controller.text.trim());
    if (v == null) {
      _controller.text = _offset.toString();
      return;
    }
    _apply(v);
  }

  String _fmt(int v) => v > 0 ? '+$v ms' : '$v ms';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.av_timer, size: 20, color: colorScheme.primary),
              const Gap(AppSpacing.sm),
              Text(
                '逐字歌词时间偏移',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _fmt(_offset),
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
          // tv: TV 构建换 RemoteSlider（P-C）
          kTvBuild
              ? RemoteSlider(
                  value: _offset.clamp(_sliderMin, _sliderMax).toDouble(),
                  min: _sliderMin.toDouble(),
                  max: _sliderMax.toDouble(),
                  // 节点数过多(>30)不显示节点，连续调节
                  label: _fmt(_offset),
                  onChanged: (v) => _apply(v.round()),
                )
              : M3ESlider(
                  value: _offset.clamp(_sliderMin, _sliderMax).toDouble(),
                  min: _sliderMin.toDouble(),
                  max: _sliderMax.toDouble(),
                  // 节点数过多(>30)不显示节点，连续调节
                  label: _fmt(_offset),
                  onChanged: (v) => _apply(v.round()),
                ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '滑块精调 ±1500ms',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _controller,
                  contextMenuBuilder: buildAppTextContextMenu,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  textAlign: TextAlign.end,
                  style: textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'ms',
                    hintText: '0',
                  ),
                  onSubmitted: (_) => _submitFromField(),
                ),
              ),
            ],
          ),
          const Gap(AppSpacing.xs),
          Text(
            '输入框支持 ±10000ms；正值 = 歌词延后显示，仅在线音乐生效',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「显示大小」设置项：无极滑块 + 抬手应用 + 10 秒超时自动还原。
///
/// 单独成 widget 而非留在设置页里：拖动过程中的中间值只需要重建这一小块，
/// 放在设置页会让每个 drag update 重建整页元素树，进而在拖动中途打断手势。
class _DisplayScaleTile extends StatefulWidget {
  const _DisplayScaleTile();

  @override
  State<_DisplayScaleTile> createState() => _DisplayScaleTileState();
}

class _DisplayScaleTileState extends State<_DisplayScaleTile> {
  /// 拖动中的临时值；null 表示显示 [ThemeProvider.displayScale] 的已应用档位。
  double? _pending;

  /// 手指是否还按在滑块上。
  ///
  /// **不能把 M3ESlider 的 onChangeEnd 当作「抬手」信号**：它的 GestureDetector
  /// 同时挂了 tap 与 horizontalDrag。手指按下停留超过 kPressTimeout(100ms) 会先
  /// 触发 onTapDown（值跳到触点），随后一移动 tap 就输掉手势竞技场 → onTapCancel；
  /// 而 onTapCancel 的守卫是 `if (!_isDragging)`，竞技场是「先 reject 其他成员、
  /// 再 accept 胜者」，此刻 _isDragging 仍为 false，于是在 divisions == null
  /// （无极，无吸附动画）下 onChangeEnd 被立即调用 —— 手还没抬就应用了档位并弹出
  /// 模态确认框，弹窗吃掉后续指针事件，手感就是拖动途中"断触"。
  /// 因此提交时机改由 Listener 的真实 pointer up / cancel 决定。
  bool _pointerDown = false;

  /// 抬手提交：值真的变了才应用，否则只清掉临时值。
  void _commit() {
    _pointerDown = false;
    final pending = _pending;
    final applied = context.read<ThemeProvider>().displayScale;
    if (pending == null || pending == applied) {
      if (pending != null) setState(() => _pending = null);
      return;
    }
    // ignore: discarded_futures
    _apply(pending, applied);
  }

  /// 应用档位：落盘后弹确认框，10 秒内不点「保留」自动还原。
  /// 极端档位下滑块与按钮自身也被放大/缩小，可能已无法再操作，必须留一条
  /// 不依赖用户交互的退路。
  Future<void> _apply(double value, double previous) async {
    final theme = context.read<ThemeProvider>();
    await theme.setDisplayScale(value);
    if (!mounted) return;
    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DisplayScaleConfirmDialog(),
    );
    if (!mounted) return;
    if (keep != true) {
      await theme.setDisplayScale(previous);
      if (!mounted) return;
    }
    setState(() => _pending = null);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final applied = context.watch<ThemeProvider>().displayScale;
    final value = (_pending ?? applied).clamp(
      kMinDisplayScale,
      kMaxDisplayScale,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Icon(Icons.fit_screen, color: colorScheme.onSurfaceVariant),
              const Gap(AppSpacing.md),
              Expanded(
                // Listener 在 GestureDetector 之上，指针事件按 hit-test 路径原样
                // 送达、不参与手势竞技场，所以 up / cancel 是可靠的「抬手」信号。
                // tv: TV 构建换 RemoteSlider（P-C，丢触觉装饰参数）
                child: Listener(
                  onPointerDown: (_) => _pointerDown = true,
                  onPointerUp: (_) => _commit(),
                  onPointerCancel: (_) => _commit(),
                  child: kTvBuild
                      ? RemoteSlider(
                          value: value,
                          min: kMinDisplayScale,
                          max: kMaxDisplayScale,
                          // divisions 不传 = 无极调节（M3ESlider.divisions 为 int?）
                          label: '${value.toStringAsFixed(2)}x',
                          // 拖动中只更新本地值，界面不缩放
                          onChanged: (v) => setState(() => _pending = v),
                          // 指针交互一律等 Listener 的 pointer up（见 _pointerDown 注释）；
                          // 这里只兜住键盘方向键那条没有指针的路径。
                          onChangeEnd: (_) {
                            if (!_pointerDown) _commit();
                          },
                        )
                      : M3ESlider(
                          // 显式给 hapticConfig：M3ESlider 在 divisions == null 时默认取
                          // M3EHapticConfig.continuous()（minimumDragInterval 10ms +
                          // 2% 阈值），拖动中会以最高约 100 次/秒走 MethodChannel 触发
                          // vibrate，真机上马达饱和 + 通道洪泛。discrete() 关掉
                          // dragTexture，只保留首尾端点反馈。
                          decoration: const M3ESliderDecoration(
                            haptic: M3EHapticFeedback.medium,
                            hapticConfig: M3EHapticConfig.discrete(),
                          ),
                          value: value,
                          min: kMinDisplayScale,
                          max: kMaxDisplayScale,
                          // divisions 不传 = 无极调节（M3ESlider.divisions 为 int?）
                          label: '${value.toStringAsFixed(2)}x',
                          // 拖动中只更新本地值，界面不缩放
                          onChanged: (v) => setState(() => _pending = v),
                          // 指针交互一律等 Listener 的 pointer up（见 _pointerDown 注释）；
                          // 这里只兜住键盘方向键那条没有指针的路径。
                          onChangeEnd: (_) {
                            if (!_pointerDown) _commit();
                          },
                        ),
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${value.toStringAsFixed(2)}x',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            '显示大小：与系统同名设置一致，整体等比放大或缩小界面，一屏能显示的内容随之增减',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 「显示大小」确认弹窗：显示剩余秒数，超时自动返回 false（= 还原）。
///
/// 返回值：true = 保留新档位，false / null = 还原。
class _DisplayScaleConfirmDialog extends StatefulWidget {
  const _DisplayScaleConfirmDialog();

  @override
  State<_DisplayScaleConfirmDialog> createState() =>
      _DisplayScaleConfirmDialogState();
}

class _DisplayScaleConfirmDialogState
    extends State<_DisplayScaleConfirmDialog> {
  static const int _timeoutSeconds = 10;

  int _remaining = _timeoutSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) {
        _timer?.cancel();
        Navigator.of(context).pop(false);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保留此显示大小？'),
      content: Text('若界面已难以操作，$_remaining 秒后将自动还原。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('还原'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('保留'),
        ),
      ],
    );
  }
}

/// 魅族状态栏歌词「提前量」。只影响状态栏这一路，不动播放页/悬浮窗/蓝牙的时间轴。
class _FlymeLyricAdvanceTile extends StatefulWidget {
  const _FlymeLyricAdvanceTile();

  @override
  State<_FlymeLyricAdvanceTile> createState() => _FlymeLyricAdvanceTileState();
}

class _FlymeLyricAdvanceTileState extends State<_FlymeLyricAdvanceTile> {
  static const int _sliderMax = SettingsRepository.kFlymeLyricAdvanceMaxMs;
  // 上限取自仓库常量而非本地字面量：UI 钳位与持久化钳位必须同源，
  // 否则改一处就会出现"滑块能拖到 600、存进去被截到 300"这类不一致。

  final TextEditingController _controller = TextEditingController();
  late int _advance;

  @override
  void initState() {
    super.initState();
    _advance = SettingsRepository.kFlymeLyricAdvanceDefaultMs;
    // 先用默认值占位再异步读持久化值：SharedPreferences 是异步的，
    // 直接 await 会让这一行首帧空白。与 _LyricTimeOffsetTile 同一写法。
    _controller.text = _advance.toString();
    _load();
  }

  Future<void> _load() async {
    final v = await SettingsRepository().getFlymeLyricAdvanceMs();
    if (!mounted) return;
    setState(() {
      _advance = v;
      _controller.text = v.toString();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(int v) {
    final clamped = v.clamp(0, _sliderMax);
    setState(() {
      _advance = clamped;
      _controller.text = clamped.toString();
    });
    final repo = SettingsRepository();
    // ignore: discarded_futures
    repo.setFlymeLyricAdvanceMs(clamped);
    // 即时生效：不重推的话要等到下一行才看得出变化
    // ignore: discarded_futures
    DesktopLyricService.instance.setFlymeAdvanceMs(clamped);
  }

  void _submitFromField() {
    final v = int.tryParse(_controller.text.trim());
    if (v == null) {
      _controller.text = _advance.toString();
      return;
    }
    _apply(v);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fast_rewind, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '状态栏歌词提前量',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${_advance}ms',
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
          // tv: TV 构建换 RemoteSlider（P-C）
          kTvBuild
              ? RemoteSlider(
                  value: _advance.clamp(0, _sliderMax).toDouble(),
                  min: 0,
                  max: _sliderMax.toDouble(),
                  label: '${_advance}ms',
                  onChanged: (v) => _apply(v.round()),
                )
              : M3ESlider(
                  value: _advance.clamp(0, _sliderMax).toDouble(),
                  min: 0,
                  max: _sliderMax.toDouble(),
                  label: '${_advance}ms',
                  onChanged: (v) => _apply(v.round()),
                ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '滑块 0–$_sliderMax ms',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _controller,
                  contextMenuBuilder: buildAppTextContextMenu,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: false,
                  ),
                  textAlign: TextAlign.end,
                  style: textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'ms',
                    hintText: '0',
                  ),
                  onSubmitted: (_) => _submitFromField(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '状态栏歌词是通知驱动的，系统渲染有约 100ms 延迟，所以默认提前 120ms 抵消它。'
            '觉得字出太早就调小，太晚就调大；只影响状态栏，不影响播放页与悬浮窗。',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
