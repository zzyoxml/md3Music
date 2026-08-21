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

import '../../core/services/background_image_loader.dart';
import '../../core/services/custom_font_loader.dart';
import '../../core/utils/app_toast.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/folder_picker_service.dart';
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
import '../../services/stream_cache_manager.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/seed_color_picker.dart';
import '../../widgets/usb_exclusive_section.dart';
import '../player/mini_player.dart';
import 'equalizer_settings_page.dart';

/// CI compile-time version injection via --dart-define=APP_VERSION=X
/// Fallback display when runtime PackageInfo read fails.
const String kBuildAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '4.0.0',
);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  final SettingsRepository _settingsRepository = SettingsRepository();
  String _defaultQuality = '128';
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
  String _appVersion = '';
  // 实时歌词推送协议选择（三选一 + 关闭）
  String _lyricPushProtocol = 'none';
  // 共用偏好：翻译 / 罗马音 / 优先翻译（同时存在时）
  bool _lyricPushTranslation = true;
  bool _lyricPushRoma = false;
  bool _lyricPushPreferTranslation = true;
  // 设备 Android SDK 版本（SuperLyricApi 3.4 要求 API 26+，低于此禁用该协议选项）
  int? _androidSdkVersion;
  /// SuperLyric 是否受支持：API 26+（Android 8.0+）。未知时默认放行，避免误禁用。
  bool get _superLyricSupported =>
      _androidSdkVersion == null || _androidSdkVersion! >= 26;
  // 蓝牙歌词开关：通过 MediaSession 元数据替换在车机等设备显示歌词
  bool _bluetoothLyricEnabled = false;
  // 锁屏歌词开关：锁屏时全屏显示逐字歌词（覆盖在系统锁屏上方），默认关闭
  bool _lockScreenLyricEnabled = false;
  // 锁屏歌词独立字号/粗细（默认跟随 AM 歌词偏好）
  double _lockScreenLyricFontSize = 22;
  int _lockScreenLyricFontWeight = 400;
  // 自定义下载目录：null/空 表示使用默认目录
  String? _downloadDir;
  // 下载时内嵌字级 LRC 歌词（逐字），关闭则嵌入行级 LRC
  bool _downloadWordLevelLyrics = true;
  double _uiScale = 1.0;
  // 暂停淡入淡出开关
  bool _pauseFadeEnabled = false;
  // 播放时保持屏幕常亮开关
  bool _keepScreenOn = false;
  // MiniPlayer 滑动切歌开关（默认开启）
  bool _miniPlayerSwipeSwitch = true;
  // 收藏歌单按「最近点击」排序（默认开启）
  bool _sortCollectedByLatestClick = true;
  // 歌词双击跳转开关（默认关闭，开启后需双击歌词才能跳转位置）
  bool _lyricDoubleTapToJump = false;
  // 自定义背景图片（全局界面背景）
  bool _useBackgroundImage = false;
  String? _backgroundImagePath;
  double _backgroundBlur = 12.0;
  double _backgroundOpacity = 0.7;
  // 按背景图莫奈取色（默认开启）
  bool _useBackgroundMonet = true;
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
    final quality = await _settingsRepository.getDefaultQuality();
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
    // 读取自定义下载目录
    final downloadDir = await _settingsRepository.getDownloadDir();
    // 从 ThemeProvider 同步 UI 缩放
    final uiScale = context.read<ThemeProvider>().uiScale;
    // 读取蓝牙歌词开关
    final bluetoothLyricEnabled = await _settingsRepository
        .getBluetoothLyricEnabled();
    // 读取锁屏歌词开关
    final lockScreenLyricEnabled = await _settingsRepository
        .getLockScreenLyricEnabled();
    // 读取锁屏歌词独立字号/粗细
    final lockScreenLyricFontSize = await _settingsRepository
        .getLockScreenLyricFontSize();
    final lockScreenLyricFontWeight = await _settingsRepository
        .getLockScreenLyricFontWeight();
    final downloadWordLevelLyrics = await _settingsRepository
        .getDownloadWordLevelLyrics();
    final pauseFadeEnabled = await _settingsRepository.getPauseFadeEnabled();
    final keepScreenOn = await _settingsRepository.getKeepScreenOn();
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
      _defaultQuality = quality;
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
      _useGaussianBlur = LyricPreferences.instance.useGaussianBlur;
      _useGlowEffect = LyricPreferences.instance.useGlowEffect;
      _useFlowingBackground = LyricPreferences.instance.useFlowingBackground;
      _useDuetLayout = LyricPreferences.instance.useDuetLayout;
      _lyricEcoMode = LyricPreferences.instance.ecoMode;
      _lyricDynamicColor = LyricPreferences.instance.useDynamicLyricColor;
      _downloadDir = downloadDir;
      _downloadWordLevelLyrics = downloadWordLevelLyrics;
      _uiScale = uiScale;
      _bluetoothLyricEnabled = bluetoothLyricEnabled;
      _lockScreenLyricEnabled = lockScreenLyricEnabled;
      _lockScreenLyricFontSize = lockScreenLyricFontSize;
      _lockScreenLyricFontWeight = lockScreenLyricFontWeight;
      _pauseFadeEnabled = pauseFadeEnabled;
      _keepScreenOn = keepScreenOn;
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
        ('边听边存', Icons.download_outlined, _buildStreamCacheSection),
        ('下载', Icons.file_download_outlined, _buildDownloadSection),
        ('在线音乐', Icons.cloud_outlined, _buildOnlineMusicSection),
        ('缓存与数据', Icons.storage_outlined, _buildCacheSection),
        ('关于', Icons.info_outline, _buildAboutSection),
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

  /// 设置搜索索引：label 为展示名，aliases 为补充匹配词。
  /// 命中后在总览页展示对应设置项，点击进入所属分类。
  static const List<({String label, String category, String aliases})> _searchIndex = [
    // 歌词
    (label: '翻译歌词', category: '歌词', aliases: '翻译'),
    (label: '罗马音歌词', category: '歌词', aliases: '罗马音 拼音'),
    (label: '优先翻译', category: '歌词', aliases: '优先'),
    (label: '解锁桌面歌词', category: '歌词', aliases: '桌面歌词 桌面'),
    (label: '蓝牙歌词', category: '歌词', aliases: '蓝牙'),
    (label: '锁屏歌词', category: '歌词', aliases: '锁屏'),
    (label: '锁屏歌词字号', category: '歌词', aliases: '字号 大小'),
    (label: '锁屏歌词粗细', category: '歌词', aliases: '粗细 加粗'),
    (label: '歌词字体', category: '歌词', aliases: '字体'),
    // 外观
    (label: 'app 全局字体', category: '外观', aliases: '字体'),
    (label: '主题色', category: '外观', aliases: '主题 颜色 换肤'),
    (label: '使用系统主题色', category: '外观', aliases: '系统主题 壁纸 莫奈'),
    (label: '封面动态取色', category: '外观', aliases: '动态取色 封面'),
    (label: 'OLED 纯黑深色', category: '外观', aliases: 'oled 纯黑 深色 黑色'),
    (label: '启用自定义背景图片', category: '外观', aliases: '背景 图片 壁纸'),
    (label: '选择背景图片', category: '外观', aliases: '背景 图片 选择 更换'),
    (label: '清除背景图片', category: '外观', aliases: '背景 图片 清除 移除'),
    (label: '背景图片模糊', category: '外观', aliases: '模糊 高斯模糊 背景'),
    (label: '背景图片透明度', category: '外观', aliases: '透明度 背景'),
    (label: '背景图片莫奈取色', category: '外观', aliases: '莫奈 取色 动态取色 背景'),
    // 播放页样式
    (label: '歌词双击跳转', category: '播放页样式', aliases: '双击 跳转'),
    (label: '歌手写真背景轮播', category: '播放页样式', aliases: '写真 背景 轮播'),
    (label: '写真背景透明度', category: '播放页样式', aliases: '写真 透明度'),
    (label: '歌词高斯模糊', category: '播放页样式', aliases: '高斯模糊 模糊'),
    (label: '歌词辉光效果', category: '播放页样式', aliases: '辉光 发光'),
    (label: '背景动态流光', category: '播放页样式', aliases: '流光 背景'),
    (label: '男女对唱歌词优化', category: '播放页样式', aliases: '对唱 男女'),
    (label: '歌词省电模式', category: '播放页样式', aliases: '省电 限帧'),
    (label: '歌词动态颜色', category: '播放页样式', aliases: '动态颜色 混色'),
    (label: '音乐频谱环绕', category: '播放页样式', aliases: '频谱 环绕 可视化'),
    (label: '频谱柱数量', category: '播放页样式', aliases: '频谱'),
    (label: '频谱动态取色', category: '播放页样式', aliases: '频谱'),
    (label: '频谱透明度', category: '播放页样式', aliases: '频谱'),
    // 播放
    (label: '默认音质', category: '播放', aliases: '音质 清晰度'),
    (label: '均衡器', category: '播放', aliases: 'eq 均衡'),
    (label: '自动领取 VIP', category: '播放', aliases: 'vip 会员 自动领取'),
    (label: '暂停淡入淡出', category: '播放', aliases: '淡入淡出 渐变 音量'),
    (label: '播放时保持屏幕常亮', category: '播放', aliases: '屏幕常亮 常亮 息屏'),
    (label: '播放 MV 时自动画中画', category: '播放', aliases: '画中画 pip 悬浮'),
    (label: 'MiniPlayer 滑动切歌', category: '播放', aliases: 'miniplaer 迷你播放条 滑动切歌 切歌'),
    (label: '收藏歌单按最近点击排序', category: '播放', aliases: '收藏 歌单 排序 最近点击 顺序'),
    // 主页管理
    (label: '主页 Tab 管理', category: '主页管理', aliases: 'tab 标签页 主页'),
    // 桌面快捷方式
    (label: '桌面快捷方式', category: '桌面快捷方式', aliases: '快捷方式 快捷 长按'),
    // USB 独占
    (label: 'USB 独占输出', category: 'USB 独占', aliases: 'usb dac 独占 音频'),
    // 边听边存
    (label: '启用边听边存', category: '边听边存', aliases: '边听边存 缓存 流量'),
    (label: '缓存上限', category: '边听边存', aliases: '缓存 上限 大小'),
    (label: '清理缓存', category: '边听边存', aliases: '缓存 清理'),
    // 下载
    (label: '下载目录', category: '下载', aliases: '下载 目录 路径'),
    (label: '下载内嵌逐字歌词', category: '下载', aliases: '逐字歌词 歌词 内嵌'),
    // 在线音乐
    (label: '本地数据接口', category: '在线音乐', aliases: '接口 本地服务器 api 在线音乐'),
    // 缓存与数据
    (label: '清除缓存', category: '缓存与数据', aliases: '缓存 清除'),
    (label: '数据迁移', category: '缓存与数据', aliases: '迁移 数据 修复'),
    // 关于
    (label: '新手教程', category: '关于', aliases: '教程 引导'),
    (label: '用户协议', category: '关于', aliases: '协议 条款'),
    (label: '免责声明', category: '关于', aliases: '免责'),
    (label: '应用版本', category: '关于', aliases: '版本 检查更新'),
    (label: '更新最新版本', category: '关于', aliases: '更新'),
    (label: '开源许可', category: '关于', aliases: '开源 license 许可'),
  ];

  /// 按查询词过滤搜索索引（label + aliases 包含匹配）。
  List<({String label, String category, String aliases})> _searchResults(
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _searchIndex
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

  /// 歌词设置 section：MD3 与 Apple Music 两种风格播放页的歌词
  /// （字号/行间距/字体）均已移入播放页右上角菜单的"歌词显示设置"入口，
  /// 设置页不再保留独立入口。
  Widget _buildLyricSection(ColorScheme colorScheme) {
    final protocolActive = _lyricPushProtocol != 'none';
    return Column(
      children: [
        // 实时歌词推送：Lyricon / SuperLyric / LyricInfo 三选一 + 关闭
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '歌词推送',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
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
        // 解锁桌面歌词：悬浮窗锁定后点击穿透（无法点击自身解锁），
        // 且无法下拉通知栏时，可在此一键解锁悬浮窗。
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
        // 蓝牙歌词（独立开关）：通过 MediaSession 元数据替换在车机等设备显示歌词
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
        // 锁屏歌词（独立开关）：锁屏时全屏显示逐字歌词
        SwitchListTile(
          title: const Text('锁屏歌词'),
          subtitle: const Text('锁屏时全屏显示逐字歌词（熄灭屏幕后点亮，覆盖在系统锁屏上方；解锁自动关闭）'),
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
        // 逐字歌词时间偏移（仅在线音乐生效）
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

  /// 歌词字体来源中文标签（用于"歌词字体"ListTile 的 subtitle）。
  String _lyricFontSourceLabel(LyricFontSource source) {
    switch (source) {
      case LyricFontSource.system:
        return '系统默认（手机字体优先）';
      case LyricFontSource.bundled:
        return '内置 SimHei';
      case LyricFontSource.custom:
        return '自定义字体';
    }
  }

  /// 弹出歌词字体来源选择面板。
  /// 与全局字体选择解耦：歌词字体独立配置，仅作用于歌词渲染路径。
  /// 切换字体会触发 LyricPreferences.notifyListeners，
  /// AppleLyricsView 监听到后会失效行高缓存 + 模糊图片缓存并重算。
  void _showLyricFontSourceSheet(LyricPreferences prefs) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = prefs.fontSource;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '歌词字体来源',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.system
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('系统默认'),
                subtitle: const Text('使用手机系统字体（推荐）'),
                onTap: () async {
                  await prefs.setFontSource(LyricFontSource.system);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.bundled
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('内置 SimHei'),
                subtitle: const Text('使用打包的黑体字体'),
                onTap: () async {
                  await prefs.setFontSource(LyricFontSource.bundled);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.custom
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('自定义字体'),
                subtitle: Text(
                  prefs.customFontPath == null
                      ? '点击从设备选择 .ttf / .otf 文件'
                      : '已加载：${prefs.customFontPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  // 立即关闭面板，避免文件选择器与 BottomSheet 重叠
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _pickAndApplyLyricCustomFont(prefs);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 调用原生 SAF 文件选择器为歌词选字体文件，成功后保存并应用。
  Future<void> _pickAndApplyLyricCustomFont(LyricPreferences prefs) async {
    final path = await CustomFontLoader.pickFontFile();
    if (path == null) {
      // 用户取消
      if (!mounted) return;
      showToast('未选择字体文件', long: true);
      return;
    }
    // 先保存路径并加载字体（_tryLoadCustomFont 内部会注册 FontLoader）
    await prefs.setCustomFontPath(path);
    // 再切换来源为 custom（即使加载失败也切换，UI 自然降级为系统字体）
    await prefs.setFontSource(LyricFontSource.custom);
    if (!mounted) return;
    final loaded = prefs.effectiveFontFamily != null;
    showToast(loaded ? '已应用自定义字体到歌词' : '字体加载失败，已降级为系统字体', long: true);
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '主题模式',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
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
        // app全局字体入口：点击弹出三选一面板（系统 / 内置 SimHei / 自定义 TTF）
        // 选择"自定义"时打开 Android SAF 文件选择器选 .ttf/.otf 文件
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('app全局字体'),
          subtitle: Text(_getFontSourceLabel(themeProvider.fontSource)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showFontSourceSheet(themeProvider),
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
        // OLED 纯黑开关：light 模式禁用；dark 与 system 可勾选。
        // system 模式下勾选后，系统切深色时自动生效，切浅色时不影响 lightTheme。
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
        const Divider(),
        // UI 缩放滑块
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Icon(Icons.format_size, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: M3ESlider(
                  decoration: const M3ESliderDecoration(haptic: M3EHapticFeedback.medium),
                  value: _uiScale,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: '${_uiScale.toStringAsFixed(1)}x',
                  onChanged: (v) {
                    setState(() => _uiScale = v);
                  },
                  onChangeEnd: (v) {
                    context.read<ThemeProvider>().setUiScale(v);
                  },
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${_uiScale.toStringAsFixed(1)}x',
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
            '调整全局界面大小（歌词界面不受影响）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 16),
        // 底部导航栏文字显示行为：始终显示 / 仅当前页 / 始终不显示
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '底部导航栏文字',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
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
        const Divider(height: 32),
        // 界面背景：独立子区块（保留与外观其他条目分隔的独立包裹）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '界面背景',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ),
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
        SwitchListTile(
          title: const Text('启用自定义背景图片（实验性）'),
          value: _useBackgroundImage,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            setState(() => _useBackgroundImage = v);
            // ignore: discarded_futures
            themeProvider.setUseBackgroundImage(v);
          },
        ),
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
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(hasImage ? '更换背景图片' : '选择背景图片'),
          subtitle: Text(hasImage ? '已选择图片，点击更换' : '从系统文件选择器选择一张图片'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _pickBackgroundImage,
        ),
        if (hasImage) ...[
          // 实时预览：按当前模糊 / 透明度渲染
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
                    child: Image.file(
                      File(_backgroundImagePath!),
                      fit: BoxFit.cover,
                      // 限制解码宽度，避免选高分辨率照片时全尺寸解码导致内存峰值闪退
                      cacheWidth: 800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              Icons.cleaning_services_outlined,
              color: colorScheme.error,
            ),
            title: const Text('清除背景图片'),
            onTap: _clearBackgroundImage,
          ),
        ],
        // 模糊程度滑块
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

  /// 清除背景图片：删除本地文件并清空配置（同时关闭开关）。
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
      _useBackgroundImage = false;
    });
    final themeProvider = context.read<ThemeProvider>();
    await themeProvider.setBackgroundImagePath(null);
    await themeProvider.setUseBackgroundImage(false);
    showToast('已清除背景图片', long: true);
  }

  /// 播放页样式 section：播放器风格卡片选择 + 视觉特效开关。
  Widget _buildPlayerStyleSection(ColorScheme colorScheme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _buildStyleCards(colorScheme),
        ),
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
        // 歌词省电模式：AM 播放器歌词界面锁定 60fps，上下滑动歌词时临时解锁
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
        // 歌词动态字体颜色：当前行按「85% 白 + 15% 封面提取色」混色（仅 AM 播放器）
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
        // 音乐频谱环绕：仅在 Android 生效；其他平台开关置灰
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
        // 频谱柱数量滑块：仅开关开启且 Android 时显示
        if (_spectrumEnabled && Platform.isAndroid)
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
        // 频谱样式切换（3选1）：柱状图(环绕) / 曲线(环绕) / 背景层(条形)
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
        // 频谱动态取色：AM 播放器频谱颜色取封面主色（50% 白 + 50% 取色混合）
        if (_spectrumEnabled && Platform.isAndroid)
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

  Widget _buildPlaybackSection(ColorScheme colorScheme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '默认音质',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              // M3E 按钮组：去掉码率/格式后缀（高亮为小圆角）
              M3EToggleButtonGroup(
                actions: const [
                  M3EToggleButtonGroupAction(label: Text('标准')),
                  M3EToggleButtonGroupAction(label: Text('高品质')),
                  M3EToggleButtonGroupAction(label: Text('无损')),
                  M3EToggleButtonGroupAction(label: Text('Hi-Res 无损')),
                ],
                selectedIndex: const ['128', 'hq', 'flac', 'high'].indexOf(_defaultQuality),
                onSelectedIndexChanged: (index) {
                  if (index == null) return;
                  const q = ['128', 'hq', 'flac', 'high'];
                  setState(() {
                    _defaultQuality = q[index];
                  });
                  _settingsRepository.setDefaultQuality(q[index]);
                },
              ),
            ],
          ),
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

  /// 边听边存 section：开关、容量上限、缓存可视化、清理按钮
  Widget _buildStreamCacheSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 启用开关
        FutureBuilder<bool>(
          future: SettingsRepository().getStreamCacheEnabled(),
          builder: (context, snapshot) {
            final enabled = snapshot.data ?? true;
            return SwitchListTile(
              title: const Text('启用边听边存'),
              subtitle: const Text('播放时自动缓存音频、歌词和封面，减少流量消耗'),
              value: enabled,
              onChanged: (v) async {
                HapticFeedback.lightImpact();
                await SettingsRepository().setStreamCacheEnabled(v);
                setState(() {}); // 刷新整个页面
              },
            );
          },
        ),
        // 2. 缓存上限选择
        FutureBuilder<int>(
          future: SettingsRepository().getStreamCacheLimitMb(),
          builder: (context, snapshot) {
            final limitMb = snapshot.data ?? 2048;
            final label = limitMb == 0 ? '无限制' : _formatLimit(limitMb);
            return ListTile(
              leading: const Icon(Icons.storage),
              title: const Text('缓存上限'),
              subtitle: Text(label),
              onTap: () => _showCacheLimitDialog(limitMb),
            );
          },
        ),
        // 3. 缓存可视化
        _buildCacheStatsWidget(colorScheme),
        // 4. 清理缓存按钮
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('清理缓存'),
          onTap: () => _showClearCacheConfirmDialog(),
        ),
      ],
    );
  }

  /// 格式化缓存上限：MB → GB 显示（1024 MB = 1 GB）
  String _formatLimit(int mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB';
    }
    return '$mb MB';
  }

  /// 缓存上限选择对话框：1GB / 2GB / 4GB / 8GB / 无限制
  void _showCacheLimitDialog(int currentMb) {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('缓存上限'),
          children: [
            _buildLimitOption(1024, currentMb, '1 GB'),
            _buildLimitOption(2048, currentMb, '2 GB'),
            _buildLimitOption(4096, currentMb, '4 GB'),
            _buildLimitOption(8192, currentMb, '8 GB'),
            _buildLimitOption(0, currentMb, '无限制'),
          ],
        );
      },
    );
  }

  /// 单个上限选项：选中项左侧显示勾号
  Widget _buildLimitOption(int value, int currentMb, String label) {
    return SimpleDialogOption(
      onPressed: () async {
        await SettingsRepository().setStreamCacheLimitMb(value);
        if (context.mounted) Navigator.pop(context);
        setState(() {});
      },
      child: Row(
        children: [
          if (value == currentMb)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          else
            const SizedBox(width: 24),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  /// 缓存可视化组件：进度条 + 各分类占用明细
  /// 嵌套 FutureBuilder 同时获取缓存统计与上限
  Widget _buildCacheStatsWidget(ColorScheme colorScheme) {
    return FutureBuilder<CacheStats>(
      future: StreamCacheManager.instance.getCacheStats(),
      builder: (context, snapshot) {
        final stats = snapshot.data;
        final totalBytes = stats?.totalBytes ?? 0;
        final audioBytes = stats?.audioBytes ?? 0;
        final lyricsBytes = stats?.lyricsBytes ?? 0;
        final artworkBytes = stats?.artworkBytes ?? 0;
        final songCount = stats?.songCount ?? 0;

        // 再获取上限计算进度
        return FutureBuilder<int>(
          future: SettingsRepository().getStreamCacheLimitMb(),
          builder: (context, limitSnapshot) {
            final limitMb = limitSnapshot.data ?? 2048;
            final limitBytes = limitMb * 1024 * 1024;
            final progress = limitBytes > 0
                ? (totalBytes / limitBytes).clamp(0.0, 1.0)
                : 0.0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '已使用 ${_formatBytes(totalBytes)} / '
                    '${limitMb == 0 ? "无限制" : _formatBytes(limitBytes)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  M3ELinearProgressIndicator(
                    value: progress,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '音频 ${_formatBytes(audioBytes)} · '
                    '歌词 ${_formatBytes(lyricsBytes)} · '
                    '封面 ${_formatBytes(artworkBytes)} · '
                    '$songCount 首',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 文件大小格式化：B / KB / MB / GB
  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// 清理边听边存缓存确认对话框
  void _showClearCacheConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清理缓存'),
          content: const Text('确定要清理所有边听边存的缓存吗？此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                await StreamCacheManager.instance.clearCache();
                if (context.mounted) Navigator.pop(context);
                setState(() {}); // 刷新显示
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  /// 下载 section：自定义下载目录
  ///
  /// 使用 Android 原生 SAF 文件夹选择器。
  Widget _buildDownloadSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('下载目录'),
          subtitle: Text(
            _downloadDir?.isNotEmpty == true
                ? _downloadDir!
                : '默认（Android/data/包名）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showDownloadDirDialog(),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.lyrics),
          title: const Text('下载内嵌逐字歌词'),
          subtitle: const Text('开启后嵌入字级 LRC 歌词，关闭则嵌入行级 LRC。无逐字数据时自动降级为行级'),
          value: _downloadWordLevelLyrics,
          onChanged: (value) async {
            HapticFeedback.lightImpact();
            setState(() => _downloadWordLevelLyrics = value);
            await _settingsRepository.setDownloadWordLevelLyrics(value);
          },
        ),
      ],
    );
  }

  /// 打开 Android 原生文件夹选择器。
  ///
  /// 使用 SAF (Storage Access Framework) 打开系统目录选择界面，
  /// 用户选择的目录路径会直接保存用于下载。
  Future<void> _showDownloadDirDialog() async {
    final path = await FolderPickerService.pickFolder();
    if (path == null) return; // 用户取消

    setState(() {
      _downloadDir = path;
    });
    await _settingsRepository.setDownloadDir(_downloadDir);
    if (!mounted) return;
    showToast('下载目录已设置为：$path', long: true);
  }

  Widget _buildOnlineMusicSection(ColorScheme colorScheme) {
    return Column(
      children: [
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
        ListTile(
          title: const Text('清除缓存'),
          leading: Icon(Icons.delete_outline, color: colorScheme.error),
          onTap: () => _showClearCacheDialog(),
        ),
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

  Widget _buildAboutSection(ColorScheme colorScheme) {
    return Column(
      children: [
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
        ListTile(
          title: const Text('免责声明'),
          subtitle: const Text('查看本软件免责声明'),
          leading: const Icon(Icons.gavel_outlined),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => UserAgreementPage.showDisclaimerDialog(context),
        ),
        ListTile(
          title: const Text('应用版本'),
          subtitle: Text(_appVersion.isEmpty ? kBuildAppVersion : _appVersion),
          leading: const Icon(Icons.info_outline),
        ),
        ListTile(
          title: const Text('更新最新版本'),
          subtitle: const Text('https://github.com/zzyoxml/md3Music/releases'),
          leading: const Icon(Icons.system_update_outlined),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openReleasesUrl(),
        ),
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
        ListTile(
          title: const Text('Miuix 发现页测试（开发）'),
          subtitle: const Text('MIUI 风格重新排版的发现页信息呈现'),
          leading: const Icon(Icons.explore_outlined),
          onTap: _openMiuixDiscover,
        ),
      ],
    );
  }

  /// 打开原生 Miuix 发现页测试：通过 MethodChannel 启动 MiuixDiscoverActivity，
  /// 并把本地 Rust API 服务器当前端口传过去（原生页据此直连取数）。
  Future<void> _openMiuixDiscover() async {
    const channel = MethodChannel('com.md3music.premium/miuix_discover');
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
                  child: preview,
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
