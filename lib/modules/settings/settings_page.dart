import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/services/usb_audio_service.dart';

import '../../core/layout/page_title_alignment.dart';
import '../../core/layout/ui_density.dart';
import '../../core/services/audio_service_io.dart';
import '../../core/services/background_image_loader.dart';
import '../../core/widgets/app_background.dart' show kDefaultWallpaperAsset;
import '../../core/services/custom_font_loader.dart';
import '../../core/utils/app_toast.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/lyricon_provider_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/services/media_store_service.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/services/wakelock_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion_constants.dart';
import '../../data/repositories/settings_repository.dart';
import '../onboarding/onboarding_page.dart';
import '../onboarding/user_agreement_page.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/shortcut_config_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_server.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/seed_color_picker.dart';
import '../../widgets/usb_exclusive_section.dart';
import '../player/mini_player.dart';
import 'equalizer_settings_page.dart';
import 'settings_search_index.g.dart';

/// CI compile-time version injection via --dart-define=APP_VERSION=X
/// Fallback display when runtime PackageInfo read fails.
const String kBuildAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '4.0.0',
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
    with SingleTickerProviderStateMixin {
  final SettingsRepository _settingsRepository = SettingsRepository();
  String _wifiQuality = '128';
  String _mobileQuality = '128';
  bool _autoReceiveVip = true;
  // 本地 API 服务器重启中（在线音乐区块显示加载态）
  bool _isRestarting = false;
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
  // 辉光触发阈值系数（默认 1.4，范围 1.0~2.0）：触发阈值 = 歌词字长中位数 × 该系数
  double _glowThresholdFactor = 1.4;
  String _appVersion = '';
  // 实时歌词推送协议选择（三选一 + 关闭）
  String _lyricPushProtocol = 'none';
  // 共用偏好：翻译 / 罗马音 / 优先翻译（同时存在时）
  bool _lyricPushTranslation = true;
  bool _lyricPushRoma = false;
  bool _lyricPushPreferTranslation = true;
  // 32bit 播放支持开关（默认关闭）。开启后无损(24/32bit)走高解析 float 输出；
  // 部分设备 float 播放可能变速/变调，故默认关闭，需用户主动开启。
  bool _enable32bitOutput = false;
  // 设备 Android SDK 版本（SuperLyricApi 3.4 要求 API 26+，低于此禁用该协议选项）
  int? _androidSdkVersion;
  /// SuperLyric 是否受支持：API 26+（Android 8.0+）。未知时默认放行，避免误禁用。
  bool get _superLyricSupported =>
      _androidSdkVersion == null || _androidSdkVersion! >= 26;
  // 蓝牙歌词开关：通过 MediaSession 元数据替换在车机等设备显示歌词
  bool _bluetoothLyricEnabled = false;
  // 蓝牙歌词封面压缩开关：默认关闭（不压缩，保持原始封面质量）
  bool _bluetoothLyricCompressArt = false;
  // 锁屏歌词开关：锁屏时全屏显示逐字歌词（覆盖在系统锁屏上方），默认关闭
  bool _lockScreenLyricEnabled = false;
  // 锁屏歌词独立字号/粗细（默认跟随 AM 歌词偏好）
  double _lockScreenLyricFontSize = 22;
  int _lockScreenLyricFontWeight = 400;
  // 暂停淡入淡出开关
  bool _pauseFadeEnabled = false;
  // 播放时保持屏幕常亮开关
  bool _keepScreenOn = false;
  // 忽略音频焦点开关（默认开启：允许与其他应用同时播放音频）
  bool _ignoreAudioFocus = true;
  // 音频焦点中断策略（默认：暂停后自动恢复）
  AudioFocusInterruptionMode _audioFocusInterruptionMode =
      AudioFocusInterruptionMode.pauseAndResume;
  // MiniPlayer 滑动切歌开关（默认开启）
  bool _miniPlayerSwipeSwitch = true;
  // 收藏歌单按「最近点击」排序（默认关闭）
  bool _sortCollectedByLatestClick = false;
  // 歌词双击跳转开关（默认关闭，开启后需双击歌词才能跳转位置）
  bool _lyricDoubleTapToJump = false;
  // 自定义背景图片（全局界面背景）；默认开启，未选择图片时回落到内置默认壁纸
  bool _useBackgroundImage = true;
  String? _backgroundImagePath;
  double _backgroundBlur = 20.0;
  double _backgroundOpacity = 0.4;
  // 按背景图莫奈取色（默认开启）
  bool _useBackgroundMonet = true;
  // 文字阴影（默认关闭，仅在启用自定义背景图片时生效）
  bool _useTextShadow = false;
  // 文字阴影磅数（阴影模糊半径）
  double _textShadowBlur = AppTheme.defaultTextShadowBlur;
  // 音乐频谱环绕显示开关（默认关闭，仅 Android 生效）
  bool _spectrumEnabled = false;
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
  // 设置搜索：输入框控制器 + 当前查询词
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
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
    _loadLyricPushSettings();
    _loadAndroidSdkVersion();
    _initEnable32bit();
    LyriconProviderService.instance.addListener(_onLyriconStateChanged);
    // 桌面歌词状态变化（设置页开关 / 播放器长按 / 通知栏按钮）→ 刷新 UI
    DesktopLyricService.instance.addListener(_onDesktopLyricChanged);
  }

  @override
  void dispose() {
    _sectionTransition.dispose();
    _searchController.dispose();
    LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
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
        await LyriconProviderService.instance.setDisplayTranslation(translation);
        await LyriconProviderService.instance.setDisplayRoma(roma);
      } catch (_) {}
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
    // 从 ThemeProvider 同步自定义背景图片配置
    final useBackgroundImage = context.read<ThemeProvider>().useBackgroundImage;
    final backgroundImagePath = context
        .read<ThemeProvider>()
        .backgroundImagePath;
    final backgroundBlur = context.read<ThemeProvider>().backgroundBlur;
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
    // 读取锁屏歌词开关
    final lockScreenLyricEnabled = await _settingsRepository
        .getLockScreenLyricEnabled();
    // 读取锁屏歌词独立字号/粗细
    final lockScreenLyricFontSize = await _settingsRepository
        .getLockScreenLyricFontSize();
    final lockScreenLyricFontWeight = await _settingsRepository
        .getLockScreenLyricFontWeight();
    final pauseFadeEnabled = await _settingsRepository.getPauseFadeEnabled();
    final keepScreenOn = await _settingsRepository.getKeepScreenOn();
    final ignoreAudioFocus = await _settingsRepository.getIgnoreAudioFocus();
    final audioFocusInterruptionMode = await _settingsRepository
        .getAudioFocusInterruptionMode();
    final spectrumEnabled = await _settingsRepository.getSpectrumEnabled();
    final spectrumBandCount = await _settingsRepository.getSpectrumBandCount();
    final spectrumStyle = await _settingsRepository.getSpectrumStyle();
    final spectrumBgOpacity = await _settingsRepository.getSpectrumBgOpacity();
    final spectrumBgHeight = await _settingsRepository.getSpectrumBgHeight();
    final spectrumBarOpacity = await _settingsRepository.getSpectrumBarOpacity();
    final spectrumCurveOpacity = await _settingsRepository.getSpectrumCurveOpacity();
    final spectrumDynamicColor = await _settingsRepository.getSpectrumDynamicColor();
    final miniPlayerSwipeSwitch = await _settingsRepository
        .getMiniPlayerSwipeSwitchEnabled();
    final sortCollectedByLatestClick = await _settingsRepository
        .getSortCollectedByLatestClick();

    setState(() {
      _wifiQuality = wifiQuality;
      _mobileQuality = mobileQuality;
      _autoReceiveVip = autoReceiveVip;
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
      _glowThresholdFactor = LyricPreferences.instance.glowThresholdFactor;
      _bluetoothLyricEnabled = bluetoothLyricEnabled;
      _bluetoothLyricCompressArt = bluetoothLyricCompressArt;
      _lockScreenLyricEnabled = lockScreenLyricEnabled;
      _lockScreenLyricFontSize = lockScreenLyricFontSize;
      _lockScreenLyricFontWeight = lockScreenLyricFontWeight;
      _pauseFadeEnabled = pauseFadeEnabled;
      _keepScreenOn = keepScreenOn;
      _ignoreAudioFocus = ignoreAudioFocus;
      _audioFocusInterruptionMode = audioFocusInterruptionMode;
      _spectrumEnabled = spectrumEnabled;
      _spectrumBandCount = spectrumBandCount;
      _spectrumStyle = spectrumStyle;
      _spectrumBgOpacity = spectrumBgOpacity;
      _spectrumBgHeight = spectrumBgHeight;
      _spectrumBarOpacity = spectrumBarOpacity;
      _spectrumCurveOpacity = spectrumCurveOpacity;
      _spectrumDynamicColor = spectrumDynamicColor;
      _miniPlayerSwipeSwitch = miniPlayerSwipeSwitch;
      _sortCollectedByLatestClick = sortCollectedByLatestClick;
    });
    // 同步到全局开关，让已挂载的 MiniPlayer 实例实时响应
    miniPlayerSwipeSwitchEnabled.value = miniPlayerSwipeSwitch;
  }

  void _onAudioFocusModeChanged(AudioFocusInterruptionMode mode) {
    HapticFeedback.lightImpact();
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
    // 是否处于二级页面（分类详情）
    final inSubpage = _activeSection != null;

    return PopScope(
      // 二级页面时拦截系统返回键：先回到分类总览，而非直接退出设置页
      canPop: !inSubpage,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _closeSection();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: inSubpage
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _closeSection,
                )
              : null,
          title: Text(inSubpage ? _activeSection! : '设置'),
          // 统一对齐规则：设置页内部的分类详情本身即二级页面，一律居中；
          // 总览页则按「是否为底部导航栏可直达的一级页面」判定
          centerTitle: inSubpage || centerPageTitle(context, tabId: 'settings'),
        ),
        // 页面切换过渡：先淡出旧页 → 切换内容 → 再淡入新页（严格串行）。
        // 淡入方向按页面层级区分：进入二级页自右侧推进、返回总览自左侧退回。
        body: FadeTransition(
          opacity: _sectionTransition,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(inSubpage ? 0.03 : -0.03, 0),
              end: Offset.zero,
            ).animate(_sectionTransition),
            child: inSubpage
                ? ListView(
                    children: [
                      _buildSettingsCard(_buildActiveSectionContent(colorScheme)),
                      const SizedBox(height: 32),
                    ],
                  )
                : ListView(
                    children: [
                      _buildSearchField(colorScheme),
                      if (_searchQuery.trim().isNotEmpty)
                        ..._buildSearchResults(colorScheme)
                      else
                        ..._buildCategoryEntries(colorScheme),
                      const SizedBox(height: 32),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 当前激活的二级页面标题；null 表示分类总览页
  String? _activeSection;

  /// 页面切换过渡控制器（fade 0→1，见 initState）
  late AnimationController _sectionTransition;

  /// 进入分类二级页面：先快速淡出总览，切换内容后再淡入（严格串行）
  void _openSection(String title) {
    if (_sectionTransition.isAnimating || _activeSection == title) return;
    // 已在二级页面（理论上不会发生，防御性处理）：直接切换内容
    if (_activeSection != null) {
      setState(() => _activeSection = title);
      return;
    }
    // 淡出更快（90ms），淡入稍长（160ms）带层次，整体跟手
    _sectionTransition.duration = const Duration(milliseconds: 90);
    _sectionTransition.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _activeSection = title);
      _sectionTransition.duration = const Duration(milliseconds: 160);
      _sectionTransition.forward();
    });
  }

  /// 返回分类总览：先快速淡出二级页，切换回总览后再淡入（严格串行）
  void _closeSection() {
    if (_sectionTransition.isAnimating || _activeSection == null) return;
    _sectionTransition.duration = const Duration(milliseconds: 90);
    _sectionTransition.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _activeSection = null);
      _sectionTransition.duration = const Duration(milliseconds: 160);
      _sectionTransition.forward();
    });
  }

  /// 分类条目：图标 + 标题 + 二级页面内容构建器
  List<(String, IconData, Widget Function(ColorScheme))> get _categories => [
        ('外观', Icons.palette_outlined, _buildAppearanceSection),
        ('播放页样式', Icons.music_note_outlined, _buildPlayerStyleSection),
        ('歌词', Icons.lyrics_outlined, _buildLyricSection),
        ('播放', Icons.play_circle_outline, _buildPlaybackSection),
        (
          'USB 独占',
          Icons.usb,
          (colorScheme) => UsbExclusiveSection(
            onAutoPause: () => context.read<PlayerProvider>().pause(),
          ),
        ),
        ('主页管理', Icons.tab_outlined, _buildTabManagementSection),
        (
          '桌面快捷方式',
          Icons.bolt_outlined,
          _buildDesktopShortcutSection,
        ),
        ('在线音乐', Icons.cloud_outlined, _buildOnlineMusicSection),
        ('缓存与数据', Icons.storage_outlined, _buildCacheSection),
        ('关于', Icons.info_outline, _buildAboutSection),
        // 可选扩展：私有构建注入的额外分类（默认无）
        ...?SettingsPage.extraCategories,
      ];

  /// 二级页面内容：根据 _activeSection 匹配分类构建器
  Widget _buildActiveSectionContent(ColorScheme colorScheme) {
    for (final (title, _, builder) in _categories) {
      if (title == _activeSection) {
        return builder(colorScheme);
      }
    }
    return const SizedBox.shrink();
  }

  /// 分类总览条目列表
  List<Widget> _buildCategoryEntries(ColorScheme colorScheme) {
    return [
      for (final (title, icon, _) in _categories)
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _openSection(title),
        ),
    ];
  }

  /// 按查询词过滤搜索索引（label + aliases 包含匹配）。
  /// 索引由 scripts/tools/gen_settings_search_index.dart 从本文件源码生成，
  /// 新增/改名设置项后重新生成即可，无需手工维护条目。
  List<({String label, String category, String aliases})> _searchResults(
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    // 合并私有构建注入的额外索引条目（默认无）
    final entries = [
      ...kSettingsSearchIndex,
      ...?SettingsPage.extraSearchIndexEntries,
    ];
    return entries
        .where((e) => '${e.label} ${e.aliases}'.toLowerCase().contains(q))
        .toList();
  }

  /// 总览页顶部搜索框。
  Widget _buildSearchField(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
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
            borderRadius: BorderRadius.circular(28),
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
          padding: const EdgeInsets.symmetric(vertical: 48),
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
          subtitle: Text('${r.category} ›'),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () {
            // 清空搜索后进入对应分类
            _searchController.clear();
            setState(() => _searchQuery = '');
            _openSection(r.category);
          },
        ),
    ];
  }

  /// 将 section 内容包裹在圆角矩形卡片内，提升视觉分组。
  /// 卡片背景使用 surfaceContainerLow，与播放器风格卡片保持一致。
  Widget _buildSettingsCard(Widget child) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// 区块内的分组小标题：把语义相关的设置项聚成一组。
  /// [first] 为区块内第一个分组（顶部留白小一些，避免与卡片上沿脱开）。
  Widget _buildGroupLabel(
    String text,
    ColorScheme colorScheme, {
    bool first = false,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 12 : 20, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 歌词设置 section：MD3 与 Apple Music 两种风格播放页的歌词
  /// （字号/行间距/字体）均已移入播放页右上角菜单的"歌词显示设置"入口，
  /// 设置页不再保留独立入口。
  Widget _buildLyricSection(ColorScheme colorScheme) {
    final protocolActive = _lyricPushProtocol != 'none';
    return Column(
      children: [
        // ① 歌词推送：先选推送协议，再调该协议下的共用文本偏好
        _buildGroupLabel('歌词推送', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: DropdownButtonFormField<String>(
            initialValue: _lyricPushProtocol,
            // 按钮占满可用宽度，选中文本过长时省略号截断，避免 right overflowed
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                value: 'none',
                child: Text('关闭'),
              ),
              const DropdownMenuItem(
                value: 'lyricon',
                child: Text('Lyricon 词幕'),
              ),
              DropdownMenuItem(
                value: 'super_lyric',
                enabled: _superLyricSupported,
                child: Text(
                  _superLyricSupported
                      ? 'SuperLyric（系统级，需 Android 8.0+）'
                      : 'SuperLyric（需 Android 8.0+）',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const DropdownMenuItem(
                value: 'lyric_info',
                child: Text('LyricInfo'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                // ignore: discarded_futures
                _setLyricPushProtocol(value);
              }
            },
          ),
        ),
        // 选中 Lyricon 时显示连接状态
        if (_lyricPushProtocol == 'lyricon')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
          subtitle: const Text('向所选推送目标显示翻译文本'),
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
          subtitle: Text(
            _lyricPushProtocol == 'lyric_info'
                ? 'LyricInfo 仅支持翻译，不支持罗马音'
                : '向所选推送目标显示罗马音/音译文本',
          ),
          value: _lyricPushRoma,
          onChanged:
              protocolActive && _lyricPushProtocol != 'lyric_info'
                  ? (value) {
                      // ignore: discarded_futures
                      _setLyricPushRoma(value);
                    }
                  : null,
        ),
        // search: 优先 翻译
        SwitchListTile(
          title: const Text('优先翻译（同时存在时）'),
          subtitle: Text(
            _lyricPushProtocol == 'lyric_info'
                ? 'LyricInfo 仅支持翻译，无罗马音可选'
                : '一行同时有翻译和罗马音时，开启推送翻译、关闭推送罗马音',
          ),
          value: _lyricPushPreferTranslation,
          onChanged:
              protocolActive && _lyricPushProtocol != 'lyric_info'
                  ? (value) {
                      // ignore: discarded_futures
                      _setLyricPushPreferTranslation(value);
                    }
                  : null,
        ),
        // ② 桌面歌词：悬浮窗锁定后点击穿透（无法点击自身解锁），
        // 且无法下拉通知栏时，可在此一键解锁悬浮窗。
        _buildGroupLabel('桌面歌词', colorScheme),
        // search: 桌面歌词 桌面
        SwitchListTile(
          title: const Text('解锁桌面歌词'),
          subtitle: Text(
            DesktopLyricService.instance.locked
                ? '悬浮窗已锁定（点击穿透），点按此开关解除锁定'
                : '悬浮窗未锁定，此开关用于锁定后无法点击时解除锁定',
          ),
          value: DesktopLyricService.instance.locked,
          onChanged: (_) async {
            HapticFeedback.lightImpact();
            await DesktopLyricService.instance.unlock();
          },
        ),
        // ③ 蓝牙歌词：主开关 + 从属的封面压缩
        _buildGroupLabel('蓝牙歌词', colorScheme),
        // search: 蓝牙
        SwitchListTile(
          title: const Text('蓝牙歌词'),
          subtitle: const Text('通过蓝牙在汽车主机等设备显示当前歌词（标题显示歌词，作者显示「作者 - 标题」）'),
          value: _bluetoothLyricEnabled,
          onChanged: (value) async {
            HapticFeedback.lightImpact();
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
          subtitle: const Text('开启后蓝牙歌词刷新使用 256px 压缩封面，降低系统负载；关闭保持原始封面质量'),
          value: _bluetoothLyricCompressArt,
          onChanged: (value) async {
            HapticFeedback.lightImpact();
            setState(() => _bluetoothLyricCompressArt = value);
            await _settingsRepository.setBluetoothLyricCompressArt(value);
          },
        ),
        // ④ 锁屏歌词：主开关 + 从属的字号 / 粗细
        _buildGroupLabel('锁屏歌词', colorScheme),
        // search: 锁屏
        SwitchListTile(
          title: const Text('锁屏歌词（实验性）'),
          subtitle: const Text('锁屏时全屏显示逐字歌词（熄灭屏幕后点亮，覆盖在系统锁屏上方；解锁自动关闭；需要在权限管理同时开启锁屏通知和后台弹出界面以及显示悬浮窗权限才能显示）'),
          value: _lockScreenLyricEnabled,
          onChanged: (value) async {
            HapticFeedback.lightImpact();
            setState(() => _lockScreenLyricEnabled = value);
            await _settingsRepository.setLockScreenLyricEnabled(value);
            // 同步到歌词服务（启停定时器）与原生端（开关状态/关闭界面）
            await DesktopLyricService.instance.setLockScreenLyricEnabled(value);
          },
        ),
        // 锁屏歌词字号（独立于 App 内歌词）
        // search: 字号 大小
        ListTile(
          title: const Text('锁屏歌词字号'),
          subtitle: M3ESlider(
            value: _lockScreenLyricFontSize,
            min: 14,
            max: 50,
            // 节点数过多(>30)不显示节点，连续调节
            label: '${_lockScreenLyricFontSize.round()}',
            onChanged: (v) {
              setState(() => _lockScreenLyricFontSize = v);
            },
            onChangeEnd: (v) {
              final size = v.roundToDouble();
              setState(() => _lockScreenLyricFontSize = size);
              _settingsRepository.setLockScreenLyricFontSize(size);
              DesktopLyricService.instance.setLockScreenLyricFontSize(size);
            },
          ),
          trailing: Text('${_lockScreenLyricFontSize.round()}'),
        ),
        // 锁屏歌词粗细（独立于 App 内歌词）
        // search: 粗细 加粗
        ListTile(
          title: const Text('锁屏歌词粗细'),
          subtitle: M3ESlider(
            decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
            value: _lockScreenLyricFontWeight.toDouble(),
            min: 300,
            max: 900,
            divisions: 6,
            label: '$_lockScreenLyricFontWeight',
            onChanged: (v) {
              setState(() => _lockScreenLyricFontWeight = v.round());
            },
            onChangeEnd: (v) {
              final w = v.round();
              setState(() => _lockScreenLyricFontWeight = w);
              _settingsRepository.setLockScreenLyricFontWeight(w);
              DesktopLyricService.instance.setLockScreenLyricFontWeight(w);
            },
          ),
          trailing: Text('$_lockScreenLyricFontWeight'),
        ),
        // ⑤ 歌词同步：逐字歌词时间偏移（仅在线音乐生效）
        _buildGroupLabel('歌词同步', colorScheme),
        const _LyricTimeOffsetTile(),
      ],
    );
  }

  /// 切换实时歌词推送协议（三选一 + 关闭）：先全部关闭，再启用选中协议。
  Future<void> _setLyricPushProtocol(String protocol) async {
    if (protocol == _lyricPushProtocol) return;
    HapticFeedback.lightImpact();
    setState(() => _lyricPushProtocol = protocol);
    await _settingsRepository.setLyricPushProtocol(protocol);
    await _applyLyricPushProtocol(protocol);
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
    HapticFeedback.lightImpact();
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
    HapticFeedback.lightImpact();
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
    HapticFeedback.lightImpact();
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


  Widget _buildAppearanceSection(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    // 仅 ThemeMode.light 时禁用 OLED 开关；dark 与 system 均可勾选。
    // system 模式下勾选后，等系统切到深色时 darkTheme 自动应用纯黑（MaterialApp 机制）。
    // 以 ThemeProvider 为准（单一数据源），避免与本地 _themeMode 双份不同步
    final canToggleOled =
        context.watch<ThemeProvider>().themeMode != ThemeMode.light;
    return Column(
      children: [
        // ① 明暗：主题模式 + 其从属的 OLED 纯黑（仅深色生效）
        _buildGroupLabel('主题模式', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
          subtitle: const Text('将深色背景改为纯黑（仅深色模式生效，节省 OLED 电量）'),
          value: themeProvider.useOledBlack,
          onChanged: canToggleOled
              ? (v) {
                  HapticFeedback.lightImpact();
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
          subtitle: const Text('跟随系统壁纸取色（Android 12+ 莫奈色，HCT 多点量化）'),
          value: _useDynamicColor,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            setState(() => _useDynamicColor = v);
            context.read<ThemeProvider>().setUseDynamicColor(v);
          },
        ),
        // search: 动态取色 封面
        SwitchListTile(
          title: const Text('封面动态取色'),
          subtitle: const Text('根据当前播放歌曲封面动态改变主题色（可叠加系统主题色，封面优先）'),
          value: _useCoverSeedColor,
          onChanged: (v) {
            HapticFeedback.lightImpact();
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
              (themeProvider.useBackgroundImage &&
                  themeProvider.useBackgroundMonet),
          // search: 主题 颜色 换肤
          child: ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('主题色'),
            subtitle: Text(
              themeProvider.useCoverSeedColor
                  ? '跟随歌曲封面取色'
                  : ((themeProvider.useBackgroundImage &&
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
        // ③ 字体与显示：全局字体来源 + 显示大小，两者都直接改变文字/界面尺寸
        _buildGroupLabel('字体与显示', colorScheme),
        // app全局字体入口：点击弹出三选一面板（系统 / 内置 SimHei / 自定义 TTF）
        // 选择"自定义"时打开 Android SAF 文件选择器选 .ttf/.otf 文件
        // search: 字体
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('app全局字体'),
          subtitle: Text(_getFontSourceLabel(themeProvider.fontSource)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showFontSourceSheet(themeProvider),
        ),
        // 「显示大小」滑块单独抽成 StatefulWidget：拖动中的中间值只重建这一小块。
        // 若放在设置页里用 setState 承接，每个 drag update 都会重建整页三千余行的
        // 元素树，滑块自身的手势识别器可能被连带重建 → 拖动中途"断触"、
        // onChangeEnd 提前触发（手还没抬就应用并弹确认框）。
        const _DisplayScaleTile(),
        // ④ 导航栏：底部导航栏文字显示行为（始终显示 / 仅当前页 / 始终不显示）
        _buildGroupLabel('底部导航栏', colorScheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
            ].indexOf(
              context.watch<ThemeProvider>().navLabelBehavior,
            ),
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
        // ⑤ 界面背景：全局背景图及其衍生的取色 / 可读性设置
        _buildGroupLabel('界面背景', colorScheme),
        _buildBackgroundSection(colorScheme),
      ],
    );
  }

  /// 界面背景子区块（嵌套于外观 section）：全局自定义背景图片
  /// （开关 / 选图 / 清除 / 预览 / 模糊 / 透明度）。
  ///
  /// 启用后全局页面表面的 Scaffold/AppBar 等变为透明，底层模糊背景图透出；
  /// 同时自动按背景图提取主色作为莫奈取色种子（封面动态取色开启时仍优先）。
  Widget _buildBackgroundSection(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    final hasImage =
        _backgroundImagePath != null &&
        _backgroundImagePath!.isNotEmpty &&
        File(_backgroundImagePath!).existsSync();
    return Column(
      children: [
        // search: 背景 图片 壁纸
        SwitchListTile(
          title: const Text('启用自定义背景图片'),
          subtitle: const Text('关闭后恢复纯色主题背景；开启且未选图时用内置默认壁纸'),
          value: _useBackgroundImage,
          onChanged: (v) {
            HapticFeedback.lightImpact();
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
          subtitle: Text(hasImage ? '已选择图片，点击更换' : '从系统文件选择器选择一张图片'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _pickBackgroundImage,
        ),
        // 实时预览：按当前模糊 / 透明度渲染（无用户图片时显示内置默认壁纸）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 120,
              width: double.infinity,
              child: Opacity(
                opacity: _backgroundOpacity,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: _backgroundBlur,
                    sigmaY: _backgroundBlur,
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
            subtitle: const Text('清除后使用内置默认壁纸'),
            onTap: _clearBackgroundImage,
          ),
        // 模糊程度滑块
        // search-item: 背景图片模糊 | 模糊 高斯模糊 背景
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Icon(Icons.blur_on, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: M3ESlider(
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Icon(Icons.opacity, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: M3ESlider(
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
            HapticFeedback.lightImpact();
            setState(() => _useBackgroundMonet = v);
            // ignore: discarded_futures
            themeProvider.setUseBackgroundMonet(v);
          },
        ),
        // 文字阴影：只有启用背景图时才可用（关闭背景图时开关置灰，保留用户选择）
        // search: 阴影 文字 可读性 背景 壁纸
        SwitchListTile(
          title: const Text('文字阴影'),
          subtitle: Text(
            _useBackgroundImage
                ? '给全局文字加阴影，改善背景图上的可读性；下方滑块调阴影磅数'
                : '需先启用自定义背景图片',
          ),
          value: _useTextShadow,
          onChanged: _useBackgroundImage
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useTextShadow = v);
                  // ignore: discarded_futures
                  themeProvider.setUseTextShadow(v);
                }
              : null,
        ),
        // 阴影磅数：阴影本身没生效时置灰（与「文字阴影」开关同一套约定，
        // 保留用户已选的磅数）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                child: M3ESlider(
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
    setState(() => _backgroundImagePath = path);
    await context.read<ThemeProvider>().setBackgroundImagePath(path);
    showToast('背景图片已设置，已自动莫奈取色', long: true);
  }

  /// 清除背景图片：删除本地文件并回到内置默认壁纸（开关保持开启，
  /// 避免进入"无背景"状态导致浅色模式配色异常）。
  Future<void> _clearBackgroundImage() async {
    final path = _backgroundImagePath;
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
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

  /// 播放页样式 section：播放器风格卡片选择 + 视觉特效开关。
  ///
  /// 排列逻辑：先选风格 → 两种风格通用项 → MD3 专属 → Apple Music 专属 →
  /// 两种风格均支持的频谱。专属项按其生效风格聚拢，避免灰显开关散落在各处。
  Widget _buildPlayerStyleSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // ① 风格选择：决定下方哪些专属项可用
        _buildGroupLabel('播放页风格', colorScheme, first: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _buildStyleCards(colorScheme),
        ),
        // ② 两种风格通用
        _buildGroupLabel('通用', colorScheme),
        // search: 双击 跳转
        SwitchListTile(
          title: const Text('歌词双击跳转'),
          subtitle: const Text('开启后需双击歌词行才能跳转播放位置'),
          value: _lyricDoubleTapToJump,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            setState(() => _lyricDoubleTapToJump = v);
            context.read<ThemeProvider>().setLyricDoubleTapToJump(v);
          },
        ),
        // ③ MD3 风格专属：歌手写真背景 + 其从属的间隔 / 透明度
        _buildGroupLabel('MD3Music 风格', colorScheme),
        // search: 写真 背景 轮播
        SwitchListTile(
          title: const Text('歌手写真背景轮播'),
          subtitle: const Text('MD3 风格播放页显示歌手写真背景（仅在线歌曲）'),
          value: _useArtistPhotoBackground,
          onChanged: !_useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useArtistPhotoBackground = v);
                  context.read<ThemeProvider>().setUseArtistPhotoBackground(v);
                }
              : null,
        ),
        if (_useArtistPhotoBackground && !_useAmStylePlayer)
          // search: 写真 轮播 间隔
          ListTile(
            title: const Text('轮播间隔'),
            subtitle: Text('每 $_artistPhotoInterval 秒切换'),
            trailing: DropdownButton<int>(
              value: _artistPhotoInterval,
              items: [5, 10, 15, 20, 30, 45, 60]
                  .map((s) => DropdownMenuItem(value: s, child: Text('$s 秒')))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _artistPhotoInterval = v);
                context.read<ThemeProvider>().setArtistPhotoInterval(v);
              },
            ),
          ),
        if (_useArtistPhotoBackground && !_useAmStylePlayer)
          // search: 写真 透明度
          ListTile(
            title: const Text('写真背景透明度'),
            subtitle: M3ESlider(
              decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
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
            trailing: Text('${(_artistPhotoOpacity * 100).round()}%'),
          ),
        // ④ Apple Music 风格专属：先歌词内容/排版，再颜色，再特效，最后性能兜底
        _buildGroupLabel('Apple Music 风格', colorScheme),
        // search: 对唱 男女
        SwitchListTile(
          title: const Text('男女对唱歌词优化'),
          subtitle: const Text('剔除「男/女/合」标记，男左女右、合唱居中'),
          value: _useDuetLayout,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useDuetLayout = v);
                  LyricPreferences.instance.setUseDuetLayout(v);
                }
              : null,
        ),
        // 歌词动态字体颜色：当前行按「85% 白 + 15% 封面提取色」混色（仅 AM 播放器）
        // search: 动态颜色 混色
        SwitchListTile(
          title: const Text('歌词动态颜色'),
          subtitle: const Text('当前行歌词根据专辑封面取色混色（85% 白 + 15% 提取色）'),
          value: _lyricDynamicColor,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _lyricDynamicColor = v);
                  LyricPreferences.instance.setUseDynamicLyricColor(v);
                }
              : null,
        ),
        // search: 高斯模糊 模糊
        SwitchListTile(
          title: const Text('歌词高斯模糊'),
          subtitle: const Text('开启为高斯模糊渐变，高功耗，关闭为 alpha 淡出'),
          value: _useGaussianBlur,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useGaussianBlur = v);
                  LyricPreferences.instance.setUseGaussianBlur(v);
                }
              : null,
        ),
        // search: 辉光 发光
        SwitchListTile(
          title: const Text('歌词辉光效果'),
          subtitle: const Text('持续时间较长的字触发发光缩放效果'),
          value: _useGlowEffect,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useGlowEffect = v);
                  LyricPreferences.instance.setUseGlowEffect(v);
                }
              : null,
        ),
        // 辉光触发阈值系数：触发阈值 = 歌词字长中位数 × 该系数（越小越易触发）
        // search: 辉光 发光 阈值 灵敏度
        ListTile(
          title: const Text('辉光触发阈值'),
          subtitle: const Text('触发阈值 = 歌词字长中位数 × 系数，越小越容易触发'),
          trailing: Text(_glowThresholdFactor.toStringAsFixed(1)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: M3ESlider(
            decoration: const M3ESliderDecoration(
                haptic: M3EHapticFeedback.medium),
            value: _glowThresholdFactor,
            min: LyricPreferences.minGlowThresholdFactor,
            max: LyricPreferences.maxGlowThresholdFactor,
            divisions: 10,
            label: _glowThresholdFactor.toStringAsFixed(1),
            onChanged: _useAmStylePlayer
                ? (v) {
                    setState(() => _glowThresholdFactor = v);
                  }
                : null,
            onChangeEnd: _useAmStylePlayer
                ? (v) {
                    setState(() => _glowThresholdFactor = v);
                    LyricPreferences.instance.setGlowThresholdFactor(v);
                  }
                : null,
          ),
        ),
        // search: 流光 背景
        SwitchListTile(
          title: const Text('背景动态流光'),
          subtitle: const Text('专辑封面色彩流动效果,高功耗 '),
          value: _useFlowingBackground,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _useFlowingBackground = v);
                  LyricPreferences.instance.setUseFlowingBackground(v);
                }
              : null,
        ),
        // 歌词省电模式：AM 播放器歌词界面锁定 60fps，上下滑动歌词时临时解锁。
        // 排在特效末尾：它是上面几项高功耗特效的性能兜底。
        // search: 省电 限帧
        SwitchListTile(
          title: const Text('歌词省电模式'),
          subtitle: const Text('歌词界面锁定 60fps 更省电，上下滑动歌词时自动解除限帧'),
          value: _lyricEcoMode,
          onChanged: _useAmStylePlayer
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _lyricEcoMode = v);
                  LyricPreferences.instance.setEcoMode(v);
                }
              : null,
        ),
        // ⑤ 音乐频谱：两种风格均支持。开关 → 样式（决定下方哪些参数有效）
        // → 柱数量 → 取色 → 该样式的透明度/高度
        _buildGroupLabel('音乐频谱', colorScheme),
        // 音乐频谱环绕：仅在 Android 生效；其他平台开关置灰
        // search: 频谱 环绕 可视化
        SwitchListTile(
          title: const Text('音乐频谱环绕'),
          subtitle: Text(
            Platform.isAndroid
                ? '封面裁圆旋转，环形频谱柱随音频跳动（MD3 / AM 风格均支持）'
                : '仅 Android 设备支持',
          ),
          value: _spectrumEnabled,
          onChanged: Platform.isAndroid
              ? (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _spectrumEnabled = v);
                  _settingsRepository.setSpectrumEnabled(v);
                }
              : null,
        ),
        // 频谱样式切换（3选1）：柱状图(环绕) / 曲线(环绕) / 背景层(条形)。
        // 先定样式，再调该样式下的参数。
        if (_spectrumEnabled && Platform.isAndroid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('频谱样式'),
                const SizedBox(width: 16),
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
                      HapticFeedback.lightImpact();
                      setState(() => _spectrumStyle = index);
                      _settingsRepository.setSpectrumStyle(index);
                    },
                  ),
                ),
              ],
            ),
          ),
        // 频谱柱数量滑块：仅开关开启且 Android 时显示
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 频谱
          ListTile(
            title: const Text('频谱柱数量'),
            subtitle: M3ESlider(
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
            trailing: Text('$_spectrumBandCount 根'),
          ),
        // 频谱动态取色：AM 播放器频谱颜色取封面主色（50% 白 + 50% 取色混合）
        if (_spectrumEnabled && Platform.isAndroid)
          // search: 频谱 取色
          SwitchListTile(
            title: const Text('频谱动态取色'),
            subtitle: const Text('AM 播放器频谱颜色取自封面主色（白色与取色各半混合，深色自动提亮）'),
            value: _spectrumDynamicColor,
            onChanged: (v) {
              HapticFeedback.selectionClick();
              setState(() => _spectrumDynamicColor = v);
              _settingsRepository.setSpectrumDynamicColor(v);
            },
          ),
        // 频谱透明度滑块：按当前样式显示对应项（三个分开记忆）
        if (_spectrumEnabled && Platform.isAndroid)
          // style 0：柱状图透明度；style 1：曲线透明度
          if (_spectrumStyle == 0)
            // search: 频谱 透明度
            ListTile(
              title: const Text('频谱柱状图透明度'),
              subtitle: M3ESlider(
                decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
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
              trailing: Text('${(_spectrumBarOpacity * 100).round()}%'),
            )
          else if (_spectrumStyle == 1)
            // search: 频谱 透明度
            ListTile(
              title: const Text('频谱曲线透明度'),
              subtitle: M3ESlider(
                decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
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
              trailing: Text('${(_spectrumCurveOpacity * 100).round()}%'),
            ),
        // 背景层参数：仅 style=2 时显示
        if (_spectrumEnabled && _spectrumStyle == 2 && Platform.isAndroid) ...[
          // search: 频谱 透明度
          ListTile(
            title: const Text('频谱背景透明度'),
            subtitle: M3ESlider(
              decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
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
            trailing: Text('${(_spectrumBgOpacity * 100).round()}%'),
          ),
          // search: 频谱 高度
          ListTile(
            title: const Text('频谱背景高度'),
            subtitle: M3ESlider(
              decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
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
            trailing: Text('${(_spectrumBgHeight * 100).round()}%'),
          ),
        ],
      ],
    );
  }

  /// 弹出 8 色预设种子色选择面板。
  /// 选择后调用 ThemeProvider.setManualSeedColor 持久化并立即生效。
  void _showSeedColorPicker(ThemeProvider themeProvider) {
    showModalBottomSheet(
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
        return '系统默认（手机字体优先）';
      case FontSource.bundled:
        return '内置 SimHei';
      case FontSource.custom:
        return '自定义字体';
    }
  }

  /// 弹出字体来源选择面板。
  ///
  /// 三个选项：
  /// - 系统默认：UI 走系统字体链（Roboto + Noto Sans CJK 等）
  /// - 内置 SimHei：使用打包的 assets/fonts/simhei.ttf
  /// - 自定义字体：通过 Android SAF 选择 .ttf/.otf 文件，
  ///   原生端拷贝到 filesDir/fonts/user_custom.ttf，Dart 端用 FontLoader 注册
  void _showFontSourceSheet(ThemeProvider themeProvider) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = themeProvider.fontSource;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                subtitle: const Text('使用手机系统字体（推荐）'),
                onTap: () async {
                  await themeProvider.setFontSource(FontSource.system);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == FontSource.bundled
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('内置 SimHei'),
                subtitle: const Text('使用打包的黑体字体'),
                onTap: () async {
                  await themeProvider.setFontSource(FontSource.bundled);
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
                subtitle: Text(
                  themeProvider.customFontPath == null
                      ? '点击从设备选择 .ttf / .otf 文件'
                      : '已加载：${themeProvider.customFontPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  // 立即关闭面板，避免文件选择器与 BottomSheet 重叠
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _pickAndApplyCustomFont(themeProvider);
                },
              ),
              const SizedBox(height: 8),
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
    return M3EToggleButtonGroup(
      actions: const [
        M3EToggleButtonGroupAction(label: Text('标准')),
        M3EToggleButtonGroupAction(label: Text('高品质')),
        M3EToggleButtonGroupAction(label: Text('无损')),
        M3EToggleButtonGroupAction(label: Text('Hi-Res 无损')),
      ],
      // 高音质码是 '320'（KuGou 合法值）；遗留 'hq' 归一化到 '320'
      selectedIndex: const ['128', '320', 'flac', 'high'].indexOf(
        value == 'hq' ? '320' : value,
      ),
      onSelectedIndexChanged: (index) {
        if (index == null) return;
        const q = ['128', '320', 'flac', 'high'];
        onPick(q[index]);
      },
    );
  }

  /// 网络音质分组选择回调：写对应网络的音质键，并让播放器按当前网络刷新，
  /// 新音质下一首播放生效（不打断当前播放）。
  void _onNetworkQualityPicked(bool isWifi, String? quality) {
    if (quality == null) return;
    HapticFeedback.lightImpact();
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

  /// 播放 section。
  ///
  /// 排列逻辑：音质与音效（音质 → 解锁高音质的 VIP → 输出音效）→ 播放行为
  /// （淡入淡出 / 音频焦点及其从属策略）→ 屏幕与视频 → 列表与交互。
  Widget _buildPlaybackSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // ① 音质与音效
        _buildGroupLabel('音质与音效', colorScheme, first: true),
        // 标题与按钮组分离（非 ListTile），索引条目手写声明
        // search-item: 网络音质 | 音质 清晰度 wifi 移动
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '网络音质',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '分别设置 WiFi 与移动网络下的播放音质，随当前网络自动生效',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              Text(
                'WiFi 网络下',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              _buildNetworkQualityGroup(
                _wifiQuality,
                (q) => _onNetworkQualityPicked(true, q),
              ),
              const SizedBox(height: 16),
              Text(
                '移动网络下',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
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
          subtitle: const Text('每次启动自动领取每日VIP（需要登录）'),
          value: _autoReceiveVip,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() {
              _autoReceiveVip = value;
            });
            _settingsRepository.setAutoReceiveVip(value);
          },
        ),
        // search: 32bit 无损 高解析 音质 float
        SwitchListTile(
          title: const Text('32bit 播放支持'),
          subtitle: const Text('无损(24/32bit)走高解析输出；部分设备开启后可能出现变调/变速，请在同一设备确认后可开启'),
          value: _enable32bitOutput,
          onChanged: (value) => _setEnable32bitOutput(value),
        ),
        ListenableBuilder(
          listenable: EqualizerService.instance,
          builder: (context, _) {
            final eq = EqualizerService.instance;
            // search: eq 均衡
            return ListTile(
              leading: Icon(
                Icons.graphic_eq,
                color: eq.enabled
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: const Text('均衡器'),
              subtitle: Text(eq.enabled ? '已开启 · ${eq.currentPreset}' : '未开启'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const EqualizerSettingsPage(),
                ),
              ),
            );
          },
        ),
        // ② 播放行为：音量过渡 → 与其他应用共存策略
        _buildGroupLabel('播放行为', colorScheme),
        // search: 淡入淡出 渐变 音量
        SwitchListTile(
          title: const Text('暂停淡入淡出'),
          subtitle: const Text('暂停/播放时音量平滑过渡，避免突然出声'),
          value: _pauseFadeEnabled,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() {
              _pauseFadeEnabled = value;
            });
            _settingsRepository.setPauseFadeEnabled(value);
          },
        ),
        // 「失去音频焦点时」是下面这个开关的从属策略：忽略焦点关闭时才有意义
        // search: 音频焦点 忽略焦点 同时播放 共存 不被打断 焦点
        SwitchListTile(
          title: const Text('允许与其他应用同时播放音频'),
          subtitle: const Text('忽略音频焦点请求，打开其他 App 时音乐不被打断',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          value: _ignoreAudioFocus,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() {
              _ignoreAudioFocus = value;
            });
            context.read<PlayerProvider>().setIgnoreAudioFocus(value);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 与「默认音质」一致的标题排版
              Text(
                '失去音频焦点时',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
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
                selectedIndex: AudioFocusInterruptionMode.values
                    .indexOf(_audioFocusInterruptionMode),
                onSelectedIndexChanged: (index) {
                  if (index == null) return;
                  _onAudioFocusModeChanged(
                      AudioFocusInterruptionMode.values[index]);
                },
              ),
              const SizedBox(height: 8),
              Text(
                _audioFocusModeDescription(_audioFocusInterruptionMode),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        // ③ 屏幕与视频：都与「播放时的屏幕表现」相关
        _buildGroupLabel('屏幕与视频', colorScheme),
        // search: 屏幕常亮 常亮 息屏
        SwitchListTile(
          title: const Text('播放时保持屏幕常亮'),
          subtitle: const Text('播放歌曲或 MV 时屏幕不会自动息屏'),
          value: _keepScreenOn,
          onChanged: (value) {
            HapticFeedback.lightImpact();
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
              secondary: Icon(Icons.picture_in_picture_alt, color: colorScheme.primary),
              title: const Text('播放 MV 时自动画中画'),
              subtitle: const Text('播放 MV 视频时按 Home 键自动进入画中画，默认关闭'),
              value: enabled,
              onChanged: (v) async {
                HapticFeedback.lightImpact();
                await SettingsRepository().setAutoPipEnabled(v);
                setState(() {});
              },
            );
          },
        ),
        // ④ 列表与交互：不改变音频本身，只影响操作手势与列表排序
        _buildGroupLabel('列表与交互', colorScheme),
        // search: miniplayer 迷你播放条 滑动切歌 切歌
        SwitchListTile(
          title: const Text('MiniPlayer 滑动切歌'),
          subtitle: const Text('在迷你播放条上左右滑动切换上一首/下一首'),
          value: _miniPlayerSwipeSwitch,
          onChanged: (value) {
            HapticFeedback.lightImpact();
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
          subtitle: const Text('最近点击的歌单排在前面；关闭后按收藏顺序排列'),
          value: _sortCollectedByLatestClick,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() {
              _sortCollectedByLatestClick = value;
            });
            _settingsRepository.setSortCollectedByLatestClick(value);
          },
        ),
      ],
    );
  }

  /// 主页管理 section：Tab 显示/隐藏开关 + 拖拽排序
  Widget _buildTabManagementSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // search: tab 标签页 主页
        ListTile(
          leading: const Icon(Icons.tab),
          title: const Text('主页 Tab 管理'),
          subtitle: const Text('显示/隐藏、拖拽排序'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showTabManagementSheet(),
        ),
      ],
    );
  }

  /// 弹出 Tab 管理面板：支持拖拽排序 + 显示/隐藏开关。
  void _showTabManagementSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _TabManagementPanel(),
    );
  }

  /// 桌面快捷方式 section：Android 长按应用图标快捷入口的显示/隐藏、排序
  Widget _buildDesktopShortcutSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // search: 快捷方式 快捷 长按
        ListTile(
          leading: const Icon(Icons.bolt),
          title: const Text('桌面快捷方式'),
          subtitle: const Text('长按应用图标的快捷入口，显示/隐藏、拖拽排序'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showDesktopShortcutSheet(),
        ),
      ],
    );
  }

  /// 弹出桌面快捷方式管理面板：支持拖拽排序 + 显示/隐藏开关。
  void _showDesktopShortcutSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _DesktopShortcutPanel(),
    );
  }

  /// 本地持久化音频管理 section 未包含在公开版本中。

  /// 恢复 32bit 播放开关并同步到字段（从 UsbAudioService 缓存读取，已持久化+下发原生）。
  Future<void> _initEnable32bit() async {
    await UsbAudioService.instance.initEnable32bit();
    if (!mounted) return;
    setState(() => _enable32bitOutput = UsbAudioService.instance.enable32bit);
  }

  Future<void> _setEnable32bitOutput(bool value) async {
    HapticFeedback.lightImpact();
    setState(() => _enable32bitOutput = value);
    await UsbAudioService.instance.setEnable32bit(value);
  }

  Widget _buildOnlineMusicSection(ColorScheme colorScheme) {
    return Column(
      children: [
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '本地 Rust 服务器运行中，推荐/排行/搜索/播放/登录等数据接口均通过本地处理（点击上方可重启）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 询问是否重启本地 API 服务器，确认后重启并更新端口展示。
  Future<void> _confirmRestartServer() async {
    final port = KugouApiServer.currentPort;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重启本地 API 服务器'),
        content: Text('确定要重启本地 Rust API 服务器吗？\n当前端口：$port\n重启后将重新分配随机端口。\n如果你遇到了玄学问题，那就重启一下试试吧（）'),
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
      showToast(ok
          ? '已重启，新端口：${KugouApiServer.currentPort}'
          : '重启失败，服务器未就绪',
          long: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {});
      showToast('重启失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _isRestarting = false);
    }
  }

  Widget _buildCacheSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // search: 缓存 清除
        ListTile(
          title: const Text('清除缓存'),
          leading: Icon(Icons.delete_outline, color: colorScheme.error),
          onTap: () => _showClearCacheDialog(),
        ),
        // search: 迁移 数据 修复
        ListTile(
          title: const Text('数据迁移（修复数据混乱）'),
          subtitle: const Text('如果看到其他用户的信息，执行此操作'),
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

  /// 关于 section：版本 → 帮助 → 法律与许可。
  Widget _buildAboutSection(ColorScheme colorScheme) {
    return Column(
      children: [
        // ① 版本：先看当前版本，再去更新
        _buildGroupLabel('版本', colorScheme, first: true),
        // search: 版本 检查更新
        ListTile(
          title: const Text('应用版本'),
          subtitle: Text(_appVersion.isEmpty ? kBuildAppVersion : _appVersion),
          leading: const Icon(Icons.info_outline),
        ),
        // search: 更新
        ListTile(
          title: const Text('更新最新版本'),
          subtitle: const Text('https://github.com/zzyoxml/md3Music/releases'),
          leading: const Icon(Icons.system_update_outlined),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openReleasesUrl(),
        ),
        // ② 帮助
        _buildGroupLabel('帮助', colorScheme),
        // search: 教程 引导
        ListTile(
          title: const Text('新手教程'),
          subtitle: const Text('重新查看功能引导'),
          leading: const Icon(Icons.school_outlined),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => OnboardingPage(isReview: true)),
            );
          },
        ),
        // ③ 法律与许可：协议 → 免责 → 开源许可
        _buildGroupLabel('法律与许可', colorScheme),
        // search: 协议 条款
        ListTile(
          title: const Text('用户协议'),
          subtitle: const Text('查看用户协议全文'),
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
          subtitle: const Text('查看本软件免责声明'),
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
        // 开发者入口：Miuix（MIUI 风格组件库）发现页移植测试页（原生 Kotlin + Compose）
        // 已隐藏：仅保留入口数据与跳转方法，可在需要时取消注释恢复
        // ListTile(
        //   title: const Text('Miuix 发现页测试（开发）'),
        //   subtitle: const Text('MIUI 风格重新排版的发现页信息呈现'),
        //   leading: const Icon(Icons.explore_outlined),
        //   onTap: _openMiuixDiscover,
        // ),
      ],
    );
  }

  /// 打开原生 Miuix 发现页测试：通过 MethodChannel 启动 MiuixDiscoverActivity，
  /// 并把本地 Rust API 服务器当前端口传过去（原生页据此直连取数）。
  // ignore: unused_element
  Future<void> _openMiuixDiscover() async {
    const channel = MethodChannel('com.md3music.md3music/miuix_discover');
    try {
      await channel.invokeMethod('open', {'port': KugouApiServer.currentPort});
    } catch (e) {
      if (!mounted) return;
      showToast('无法打开原生测试页：$e', long: true);
    }
  }

  Future<void> _openReleasesUrl() async {
    const url = 'https://github.com/zzyoxml/md3Music/releases';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
            HapticFeedback.lightImpact();
            setState(() => _useAmStylePlayer = false);
            context.read<ThemeProvider>().setUseAmStylePlayer(false);
          },
          preview: _SettingsMd3StylePreview(colorScheme: colorScheme),
        ),
        const SizedBox(width: 16),
        _buildStyleCard(
          colorScheme: colorScheme,
          title: 'Apple Music',
          subtitle: '模糊封面 + 逐字歌词',
          isSelected: _useAmStylePlayer,
          onTap: () {
            HapticFeedback.lightImpact();
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
class _TabManagementPanel extends StatelessWidget {
  const _TabManagementPanel();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tabConfig = context.watch<TabConfigProvider>();
    final allTabs = tabConfig.allTabs;
    final hiddenTabs = tabConfig.hiddenTabs;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '主页 Tab 管理',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => tabConfig.resetToDefault(),
                    child: const Text('重置'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '拖拽排序、开关显示/隐藏（“我的”不可隐藏）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: allTabs.length,
                onReorder: (oldIndex, newIndex) {
                  tabConfig.reorderTabs(oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  final tab = allTabs[index];
                  final isHidden = hiddenTabs.contains(tab.id);
                  return ListTile(
                    key: ValueKey(tab.id),
                    leading: Icon(
                      _tabIconForId(tab.id),
                      color: isHidden
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.primary,
                    ),
                    title: Text(
                      tab.label,
                      style: TextStyle(
                        color: isHidden ? colorScheme.onSurfaceVariant : null,
                      ),
                    ),
                    subtitle: !tab.isRemovable
                        ? Text(
                            '必显示',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tab.isRemovable)
                          Switch(
                            value: !isHidden,
                            onChanged: (_) {
                              HapticFeedback.lightImpact();
                              tabConfig.toggleTabVisibility(tab.id);
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
            ),
          ],
        ),
      ),
    );
  }
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
class _DesktopShortcutPanel extends StatelessWidget {
  const _DesktopShortcutPanel();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shortcutConfig = context.watch<ShortcutConfigProvider>();
    final allShortcuts = shortcutConfig.allShortcuts;
    final hiddenIds = shortcutConfig.hiddenIds;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '长按应用图标弹出；拖拽排序、开关显示/隐藏',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: allShortcuts.length,
                onReorder: (oldIndex, newIndex) {
                  shortcutConfig.reorderShortcuts(oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  final shortcut = allShortcuts[index];
                  final isHidden = hiddenIds.contains(shortcut.id);
                  return ListTile(
                    key: ValueKey(shortcut.id),
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
                            HapticFeedback.lightImpact();
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
            ),
          ],
        ),
      ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.av_timer, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
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
          M3ESlider(
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
          const SizedBox(height: 4),
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
    final value = (_pending ?? applied).clamp(kMinDisplayScale, kMaxDisplayScale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Icon(Icons.fit_screen, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                // Listener 在 GestureDetector 之上，指针事件按 hit-test 路径原样
                // 送达、不参与手势竞技场，所以 up / cancel 是可靠的「抬手」信号。
                child: Listener(
                  onPointerDown: (_) => _pointerDown = true,
                  onPointerUp: (_) => _commit(),
                  onPointerCancel: (_) => _commit(),
                  child: M3ESlider(
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
