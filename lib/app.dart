import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:quick_actions/quick_actions.dart';

import 'core/layout/responsive_layout.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/motion_constants.dart';
import 'core/utils/artwork_color_extractor.dart';
import 'data/models/playlist.dart';
import 'main.dart'
    show
        appNavigatorKey,
        handleShortcut,
        pendingShortcutType,
        shortcutTabRequest;
import 'modules/discover/discover_page.dart';
import 'modules/coverflow/coverflow_page.dart';
import 'modules/charts/charts_page.dart';
import 'modules/ip/ip_page.dart';
import 'modules/user/user_center_page.dart';
import 'modules/user/favorites_page.dart';

import 'modules/player/full_player.dart';
import 'modules/player/full_player_route.dart';
import 'modules/player/mini_player.dart';
import 'modules/player/player_drag_overlay.dart';
import 'modules/playlist/playlist_page.dart';
import 'modules/search/search_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/library/library_page.dart';
import 'modules/launchpad/launchpad_page.dart';
import 'modules/login/login_page.dart';
import 'widgets/app_animation.dart';
import 'modules/onboarding/onboarding_page.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'modules/personal_fm/personal_fm_page.dart';
import 'modules/audiobook/audiobook_page.dart';
import 'modules/recognition/song_recognition_page.dart';
import 'modules/scene/scene_page.dart';
import 'modules/channel/channel_page.dart';
import 'providers/downloads_provider.dart';
import 'providers/dlna_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/kugou_provider.dart';
import 'providers/library_provider.dart';
// ignore: unused_import  // 类型用于 ChangeNotifierProvider(create: ...) 的 T 推断
import 'providers/local_favorites_provider.dart';
import 'providers/player_provider.dart';
import 'providers/playlist_collection_notifier.dart';
import 'providers/device_provider.dart';
import 'providers/grid_columns_provider.dart';
import 'providers/shortcut_config_provider.dart';
import 'providers/tab_config_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/comment_display_provider.dart';
import 'services/kugou_server.dart';
import 'widgets/dlna_casting_overlay.dart';

/// 主页（`/`）专用的 [MaterialPageRoute] 子类。
///
/// 重写 [buildTransitions]：当 FullPlayer 在栈顶（[playerExpansion] > 0.5）
/// 且 [secondaryAnimation] 驱动时，让 _MainLayout 向上偏移 15% + 淡出
/// （Apple Music 经典效果）；其他路由 push 时走默认 transitions。
///
/// 通过全局 [playerExpansion] 限制只对 FullPlayer 生效，
/// 避免 /search /settings /playlist 等也触发 up-fade。
class _UpFadeMainRoute<T> extends MaterialPageRoute<T> {
  _UpFadeMainRoute({required super.builder});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 入场动画走默认（_MainLayout 是 initialRoute，入场无动画）
    // 离场动画（被覆盖）：监听 playerExpansion，> 0.5 时 up-fade，否则默认
    return AnimatedBuilder(
      animation: Listenable.merge([secondaryAnimation, playerExpansion]),
      builder: (context, _) {
        if (playerExpansion.value <= 0.5) {
          return super.buildTransitions(
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        // FullPlayer 在栈顶：_MainLayout 向上偏移 15% + 淡出
        final offset =
            Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(0, -0.15),
            ).animate(
              CurvedAnimation(
                parent: secondaryAnimation,
                curve: Curves.easeOutCubic,
              ),
            );
        final fade = Tween<double>(begin: 1.0, end: 0.0).animate(
          CurvedAnimation(
            parent: secondaryAnimation,
            curve: Curves.easeOutCubic,
          ),
        );
        return FadeTransition(
          opacity: fade,
          child: SlideTransition(position: offset, child: child),
        );
      },
    );
  }
}

class MyApp extends StatelessWidget {
  final bool showOnboarding;
  final bool showUserAgreement;

  const MyApp({
    super.key,
    this.showOnboarding = false,
    this.showUserAgreement = false,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => DownloadsProvider()),
        // 跨页面广播「收藏的歌单」变更（详情页 → 我的收藏 tab 立即刷新）
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
        // 主页 Tab 配置（显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        // 桌面快捷方式配置（Android 长按图标入口的显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => ShortcutConfigProvider()),
        // DLNA 投屏
        ChangeNotifierProvider(create: (_) => DlnaProvider()),
        // 评论显示设置（字号等）
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
      ],
      child: _AppView(
        showOnboarding: showOnboarding,
        showUserAgreement: showUserAgreement,
      ),
    );
  }
}

class _AppView extends StatefulWidget {
  final bool showOnboarding;
  final bool showUserAgreement;

  const _AppView({this.showOnboarding = false, this.showUserAgreement = false});

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  // 封面动态取色桥接：监听 PlayerProvider 切歌 → 提取封面主色 → 注入 ThemeProvider。
  // 持有引用以便 dispose 时移除 listener（provider 销毁顺序晚于 _AppViewState）。
  PlayerProvider? _playerProvider;
  // 上一次已提取/正在提取的封面 url：同一首歌反复 notify 不重复提取，
  // 且异步提取期间切歌时丢弃过期结果（参考 AM 歌词动态取色 _lastAccentUrl 模式）。
  String? _lastCoverUrl;
  // 桌面快捷方式配置：监听变更 → 重新注册 Android 长按图标快捷入口。
  ShortcutConfigProvider? _shortcutConfig;

  @override
  void initState() {
    super.initState();
    // 桌面快捷方式由 ShortcutConfigProvider 配置驱动（支持排序+开关），
    // 监听其变更并重新注册 Android 长按应用图标 Shortcut items。
    // 冷启动时 provider 可能尚未异步加载完成，先按默认配置应用一次，
    // 加载完成后 notifyListeners 会再次触发重应用。
    _shortcutConfig = context.read<ShortcutConfigProvider>();
    _shortcutConfig!.addListener(_applyDesktopShortcuts);
    _applyDesktopShortcuts();
    // 处理冷启动时缓存的 shortcut 类型：
    // QuickActions.initialize 在 runApp 之前注册，但此时 Navigator 尚未就绪，
    // 因此 main.dart 把 shortcut 类型暂存到 pendingShortcutType，
    // 这里在首帧渲染后消费。
    if (pendingShortcutType != null) {
      final type = pendingShortcutType;
      pendingShortcutType = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handleShortcut(type!);
      });
    }
    // 延迟一帧再建立封面取色桥接：ChangeNotifierProvider 惰性 create，
    // 此时 provider 实例已就绪，且不影响首帧渲染。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCoverColorBridge();
    });
  }

  /// 根据 ShortcutConfigProvider 当前配置，整体替换 Android 桌面快捷方式列表。
  /// type 统一为 `action_open_<tabId>`，由 main.dart handleShortcut 路由到对应页。
  void _applyDesktopShortcuts() {
    final config = context.read<ShortcutConfigProvider>();
    const quickActions = QuickActions();
    quickActions.setShortcutItems([
      for (final s in config.visibleShortcuts)
        ShortcutItem(
          type: 'action_open_${s.id}',
          localizedTitle: s.label,
          icon: s.iconResource,
        ),
    ]);
  }

  /// 建立封面动态取色桥接：监听 PlayerProvider 切歌，把封面主色注入 ThemeProvider。
  void _setupCoverColorBridge() {
    final player = context.read<PlayerProvider>();
    _playerProvider = player;
    player.addListener(_onPlayerChanged);
    // 启动时按当前歌曲提取一次（若 App 有恢复播放）
    _onPlayerChanged();
  }

  /// 切歌回调：当前歌曲封面 url 变化时异步提取主色并注入 ThemeProvider。
  Future<void> _onPlayerChanged() async {
    final url = context.read<PlayerProvider>().currentSong?.artworkUri;
    if (url == null || url == _lastCoverUrl) return;
    _lastCoverUrl = url;
    final color = await ArtworkColorExtractor.extract(url);
    // 过期校验：提取期间已切歌则丢弃结果（参考 AM 歌词动态取色模式）
    if (context.read<PlayerProvider>().currentSong?.artworkUri != url) return;
    context.read<ThemeProvider>().setCoverSeedColor(color);
  }

  @override
  void dispose() {
    _shortcutConfig?.removeListener(_applyDesktopShortcuts);
    _playerProvider?.removeListener(_onPlayerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    // 当前生效的 fontFamily：system 模式为 null（让 Flutter 走系统字体链），
    // bundled/custom 模式为对应字体名。加载失败时降级为 null。
    final fontFamily = themeProvider.effectiveFontFamily;

    return MaterialApp(
      title: 'MD3Music',
      debugShowCheckedModeBanner: false,
      // 同时传 theme 和 darkTheme，并根据 ThemeProvider.effectiveSeedColor
      // 动态生成（支持「莫奈色」开关切换系统主色）。
      // darkTheme 额外接收 useOledBlack 开关，开启时 surface 系列覆盖为纯黑。
      // fontFamily 透传给 ThemeData，影响所有 Material Widget 的默认字体。
      theme: AppTheme.lightThemeFromSeed(
        themeProvider.effectiveSeedColor,
        fontFamily: fontFamily,
      ),
      darkTheme: AppTheme.darkThemeFromSeed(
        themeProvider.effectiveSeedColor,
        useOledBlack: themeProvider.useOledBlack,
        fontFamily: fontFamily,
      ),
      themeMode: themeProvider.themeMode,
      // 根据主题设置系统导航栏颜色
      builder: (context, child) {
        final scale = context.watch<ThemeProvider>().uiScale;
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: _SystemUiUpdater(
            child: Stack(
              children: [
                child!,
                const DlnaCastingOverlay(),
                // 上滑拖拽跟手覆盖层（在 Navigator 之上，拖拽期间显示预览）
                const PlayerDragOverlay(),
              ],
            ),
          ),
        );
      },
      navigatorKey: appNavigatorKey,
      // 优先级：未同意协议 → 协议页；否则未完成新手引导 → 引导页；否则主页
      initialRoute: widget.showUserAgreement
          ? '/user_agreement'
          : (widget.showOnboarding ? '/onboarding' : '/'),
      routes: {
        // '/' 不在 routes 注册，改在 onGenerateRoute 用 _UpFadeMainRoute 创建，
        // 以便 push FullPlayer 时主页面向上淡出（仅 FullPlayer 生效）
        '/search': (_) => const SearchPage(),
        '/library': (_) => const LibraryPage(),
        '/settings': (_) => const SettingsPage(),
        // 发现页右上角头像点击跳转入口（push 独立路由，与底部 tab 中的实例并存无冲突）
        '/user': (_) => const UserCenterPage(),
        '/player': (_) => const FullPlayer(),
        '/personal_fm': (_) => const PersonalFmPage(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/onboarding') {
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => const OnboardingPage(),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: M3ExpressiveMotion.emphasisDuration,
          );
        }
        if (settings.name == '/user_agreement') {
          // 协议页：首次启动时点击"下一步" → 推送新手引导；已同意过则跳过引导直达主页
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => UserAgreementPage(
              isFirstLaunch: true,
              onAgreed: () {
                // 用 pushReplacement 替换协议页，next 路由由 isFirstLaunch 决定
                // 避免新协议栈里残留协议页（用户按返回能跳过）
                appNavigatorKey.currentState?.pushReplacementNamed(
                  widget.showOnboarding ? '/onboarding' : '/',
                );
              },
            ),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: M3ExpressiveMotion.emphasisDuration,
          );
        }
        if (settings.name == '/') {
          return _UpFadeMainRoute<void>(builder: (_) => const _MainLayout());
        }
        if (settings.name == '/playlist') {
          final playlist = settings.arguments as Playlist;
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => PlaylistPage(playlist: playlist),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          );
        }
        return null;
      },
    );
  }
}

/// 根据主题更新系统 UI（状态栏和导航栏颜色）
class _SystemUiUpdater extends StatefulWidget {
  final Widget child;

  const _SystemUiUpdater({required this.child});

  @override
  State<_SystemUiUpdater> createState() => _SystemUiUpdaterState();
}

class _SystemUiUpdaterState extends State<_SystemUiUpdater>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSystemUi();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当应用从后台恢复或从其他页面返回时，恢复系统 UI
    if (state == AppLifecycleState.resumed) {
      _updateSystemUi();
    }
  }

  void _updateSystemUi() {
    // 封面流页横屏实际沉浸中：保留 SystemUiMode.immersiveSticky，
    // 不覆盖系统栏模式（否则方向变化等 rebuild 会冲掉沉浸设置）。
    // 用「实际生效」标志：用户请求沉浸但切到其他 tab/竖屏时仍需恢复系统栏样式。
    if (kCoverFlowImmersiveActive.value) return;
    final brightness = Theme.of(context).brightness;
    final surfaceColor = Theme.of(context).colorScheme.surface;
    final isDark = brightness == Brightness.dark;

    // 主界面使用非沉浸模式：状态栏和导航栏正常显示，不延伸到系统栏后面。
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: surfaceColor,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: surfaceColor,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _MainLayout extends StatefulWidget {
  const _MainLayout();

  @override
  State<_MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<_MainLayout> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  int _previousSelectedIndex = 0;

  /// 上一次同步的沉浸状态，避免重复调用 SystemChrome（幂等去重）。
  bool _immersiveSynced = false;

  /// 词幕连接失败弹窗展示中标记，防止连发 connect_failed 时重复弹窗。
  bool _lyriconFailDialogShown = false;

  /// 根据 tab id 构建对应页面 Widget。
  Widget _buildPageForTab(String tabId) {
    // 统一在 tab 页外层包 ContentEntrance：向上淡入滑动（400ms, easeOutCubic），
    // 与本地音乐 SongsPage 的入场动画一致。
    // ContentEntrance 只在首次构建时播放，父组件 rebuild 不会重播。
    // 与外层 AnimatedSwitcher 的左右滑动叠加，形成"内容上浮 → 页面滑入"的层次感。
    Widget page;
    switch (tabId) {
      case 'launchpad':
        page = LaunchPadPage(
          onTabSelected: _switchToTab,
          onTabEnabled: _enableAndSwitchToTab,
          onTabOpened: _openTabAsPage,
        );
        break;
      case 'discover':
        page = DiscoverPage(
          onAvatarTap: () {
            final tabConfig = context.read<TabConfigProvider>();
            final userIdx = tabConfig.visibleIndexOf('user');
            if (userIdx >= 0) {
              setState(() {
                _previousSelectedIndex = _selectedIndex;
                _selectedIndex = userIdx;
              });
            }
          },
        );
        break;
      case 'coverflow':
        page = const CoverFlowPage();
        break;
      case 'library':
        page = const LibraryPage();
        break;
      case 'favorites':
        page = const FavoritesPage();
        break;
      case 'fm':
        page = const PersonalFmPage();
        break;
      case 'search':
        // Tab 模式：隐藏页面自带 MiniPlayer，由 _MainLayout 统一提供全局 MiniPlayer
        page = const SearchPage(showMiniPlayer: false);
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        // Tab 模式：由 _MainLayout 统一提供全局 MiniPlayer，页面不自带
        page = const SongRecognitionPage(showMiniPlayer: false);
        break;
      case 'audiobook':
        page = const AudiobookPage();
        break;
      case 'scene':
        page = const ScenePage();
        break;
      case 'channel':
        page = const ChannelPage();
        break;
      case 'settings':
        page = const SettingsPage();
        break;
      case 'user':
        page = const UserCenterPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    return ContentEntrance(child: page);
  }

  /// 根据 tab id 获取对应的 NavigationDestination 图标。
  /// 不使用 selectedIcon（Flutter 原生内部为硬切，无过渡动画），
  /// 改由 _AnimatedTabIcon 在选中变化时做缩放弹跳，使切换更生动。
  NavigationDestination _buildDestination(TabItem tab, int index) {
    final isSelected = index == _selectedIndex;
    switch (tab.id) {
      case 'launchpad':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.grid_view_outlined,
            filledIcon: Icons.grid_view,
          ),
          label: tab.label,
        );
      case 'discover':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.explore_outlined,
            filledIcon: Icons.explore,
          ),
          label: tab.label,
        );
      case 'coverflow':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.album_outlined,
            filledIcon: Icons.album,
          ),
          label: tab.label,
        );
      case 'library':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.library_music_outlined,
            filledIcon: Icons.library_music,
          ),
          label: tab.label,
        );
      case 'favorites':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.favorite_outline,
            filledIcon: Icons.favorite,
          ),
          label: tab.label,
        );
      case 'fm':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.radio_outlined,
            filledIcon: Icons.radio,
          ),
          label: tab.label,
        );
      case 'search':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.search_outlined,
            filledIcon: Icons.search,
          ),
          label: tab.label,
        );
      case 'charts':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.leaderboard_outlined,
            filledIcon: Icons.leaderboard,
          ),
          label: tab.label,
        );
      case 'ip':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.edit_note_outlined,
            filledIcon: Icons.edit_note,
          ),
          label: tab.label,
        );
      case 'recognition':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.mic_none_outlined,
            filledIcon: Icons.mic,
          ),
          label: tab.label,
        );
      case 'audiobook':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.auto_stories_outlined,
            filledIcon: Icons.auto_stories,
          ),
          label: tab.label,
        );
      case 'scene':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.landscape_outlined,
            filledIcon: Icons.landscape,
          ),
          label: tab.label,
        );
      case 'channel':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.dynamic_feed_outlined,
            filledIcon: Icons.dynamic_feed,
          ),
          label: tab.label,
        );
      case 'settings':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.settings_outlined,
            filledIcon: Icons.settings,
          ),
          label: tab.label,
        );
      case 'user':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.person_outlined,
            filledIcon: Icons.person,
          ),
          label: tab.label,
        );
      default:
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.circle_outlined,
            filledIcon: Icons.circle,
          ),
          label: tab.label,
        );
    }
  }

  NavigationRailDestination _buildRailDestination(TabItem tab) {
    switch (tab.id) {
      case 'launchpad':
        return NavigationRailDestination(
          icon: const Icon(Icons.grid_view_outlined),
          selectedIcon: const Icon(Icons.grid_view),
          label: Text(tab.label),
        );
      case 'discover':
        return NavigationRailDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          label: Text(tab.label),
        );
      case 'coverflow':
        return NavigationRailDestination(
          icon: const Icon(Icons.album_outlined),
          selectedIcon: const Icon(Icons.album),
          label: Text(tab.label),
        );
      case 'library':
        return NavigationRailDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          label: Text(tab.label),
        );
      case 'favorites':
        return NavigationRailDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          label: Text(tab.label),
        );
      case 'fm':
        return NavigationRailDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          label: Text(tab.label),
        );
      case 'search':
        return NavigationRailDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: Text(tab.label),
        );
      case 'charts':
        return NavigationRailDestination(
          icon: const Icon(Icons.leaderboard_outlined),
          selectedIcon: const Icon(Icons.leaderboard),
          label: Text(tab.label),
        );
      case 'ip':
        return NavigationRailDestination(
          icon: const Icon(Icons.edit_note_outlined),
          selectedIcon: const Icon(Icons.edit_note),
          label: Text(tab.label),
        );
      case 'recognition':
        return NavigationRailDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          label: Text(tab.label),
        );
      case 'audiobook':
        return NavigationRailDestination(
          icon: const Icon(Icons.auto_stories_outlined),
          selectedIcon: const Icon(Icons.auto_stories),
          label: Text(tab.label),
        );
      case 'scene':
        return NavigationRailDestination(
          icon: const Icon(Icons.landscape_outlined),
          selectedIcon: const Icon(Icons.landscape),
          label: Text(tab.label),
        );
      case 'channel':
        return NavigationRailDestination(
          icon: const Icon(Icons.dynamic_feed_outlined),
          selectedIcon: const Icon(Icons.dynamic_feed),
          label: Text(tab.label),
        );
      case 'settings':
        return NavigationRailDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: Text(tab.label),
        );
      case 'user':
        return NavigationRailDestination(
          icon: const Icon(Icons.person_outlined),
          selectedIcon: const Icon(Icons.person),
          label: Text(tab.label),
        );
      default:
        return NavigationRailDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          label: Text(tab.label),
        );
    }
  }

  NavigationDrawerDestination _buildDrawerDestination(TabItem tab) {
    switch (tab.id) {
      case 'launchpad':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.grid_view_outlined),
          selectedIcon: const Icon(Icons.grid_view),
          label: Text(tab.label),
        );
      case 'discover':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          label: Text(tab.label),
        );
      case 'coverflow':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.album_outlined),
          selectedIcon: const Icon(Icons.album),
          label: Text(tab.label),
        );
      case 'library':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          label: Text(tab.label),
        );
      case 'favorites':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          label: Text(tab.label),
        );
      case 'fm':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          label: Text(tab.label),
        );
      case 'search':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: Text(tab.label),
        );
      case 'charts':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.leaderboard_outlined),
          selectedIcon: const Icon(Icons.leaderboard),
          label: Text(tab.label),
        );
      case 'ip':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.edit_note_outlined),
          selectedIcon: const Icon(Icons.edit_note),
          label: Text(tab.label),
        );
      case 'recognition':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          label: Text(tab.label),
        );
      case 'audiobook':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.auto_stories_outlined),
          selectedIcon: const Icon(Icons.auto_stories),
          label: Text(tab.label),
        );
      case 'scene':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.landscape_outlined),
          selectedIcon: const Icon(Icons.landscape),
          label: Text(tab.label),
        );
      case 'channel':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.dynamic_feed_outlined),
          selectedIcon: const Icon(Icons.dynamic_feed),
          label: Text(tab.label),
        );
      case 'settings':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: Text(tab.label),
        );
      case 'user':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.person_outlined),
          selectedIcon: const Icon(Icons.person),
          label: Text(tab.label),
        );
      default:
        return NavigationDrawerDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          label: Text(tab.label),
        );
    }
  }

  @override
  void initState() {
    super.initState();
    // 未登录时尝试播放联网歌曲,弹出登录提示
    context.read<PlayerProvider>().onLoginRequired = _showLoginRequiredDialog;
    // 监听应用生命周期：detached（进程被系统销毁前的最后窗口）时尝试关停本地 API 服务器
    WidgetsBinding.instance.addObserver(this);
    // 监听 shortcut 入口的 tab 切换请求（来自 main.dart 的 handleShortcut）
    shortcutTabRequest.addListener(_handleShortcutTabRequest);
    // 监听封面流沉浸请求（长按切换 / 返回键恢复），变更时重算沉浸状态
    kCoverFlowImmersive.addListener(_onCoverFlowImmersiveChanged);
    // 监听词幕连接失败（原生侧多次重试后 connect_failed）→ 弹窗提示
    LyriconProviderService.instance.addListener(_onLyriconStateChanged);
    // 冷启动前若已连接失败（如后台唤醒时），进入主页后立即补弹一次
    if (LyriconProviderService.instance.connectFailed) {
      _lyriconFailDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLyriconConnectFailedDialog();
      });
    }
  }

  @override
  void dispose() {
    LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    kCoverFlowImmersive.removeListener(_onCoverFlowImmersiveChanged);
    shortcutTabRequest.removeListener(_handleShortcutTabRequest);
    WidgetsBinding.instance.removeObserver(this);
    // 若 App 销毁时仍处于封面流沉浸，恢复系统栏
    if (_immersiveSynced) {
      _immersiveSynced = false;
      kCoverFlowImmersiveActive.value = false;
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
    super.dispose();
  }

  /// 封面流沉浸请求变化（长按 / 返回键）→ 重算实际沉浸状态。
  void _onCoverFlowImmersiveChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 处理 shortcut 入口的 tab 切换请求。
  /// 按 tab id 解析实际索引（tab 可排序/隐藏）：
  /// - tab 可见：切主 tab；
  /// - tab 被隐藏：以二级页面路由打开（与 LaunchPad 隐藏 tab 点击行为一致）。
  void _handleShortcutTabRequest() {
    final tabId = shortcutTabRequest.value;
    if (tabId == null || tabId.isEmpty) return;
    shortcutTabRequest.value = null;
    final tabConfig = context.read<TabConfigProvider>();
    if (tabConfig.visibleIndexOf(tabId) >= 0) {
      _switchToTab(tabId);
    } else {
      _openTabAsPage(tabId);
    }
  }

  /// LaunchPad 导航：切换到指定 tab（仅对已可见的 tab 生效）。
  /// 与 onDestinationSelected 相同的守卫：FullPlayer 在栈顶时忽略。
  void _switchToTab(String tabId) {
    if (isFullPlayerOnTop) return;
    final index = context.read<TabConfigProvider>().visibleIndexOf(tabId);
    if (index < 0) return;
    setState(() {
      _previousSelectedIndex = _selectedIndex;
      _selectedIndex = index;
    });
  }

  /// LaunchPad 长按启用：先启用隐藏的 tab，再切换到该 tab。
  /// 与 [toggleTabVisibility] 的差异：这是 LaunchPad 专属入口，
  /// 隐藏 tab 只有在 LaunchPad 中长按才会被启用（点击不启用）。
  void _enableAndSwitchToTab(String tabId) {
    if (isFullPlayerOnTop) return;
    final tabConfig = context.read<TabConfigProvider>();
    if (tabConfig.hiddenTabs.contains(tabId)) {
      // toggleTabVisibility 内部先同步更新 hiddenTabs 再异步持久化，
      // 调用返回后 visibleIndexOf 即可拿到正确索引，无需等待
      // ignore: discarded_futures
      tabConfig.toggleTabVisibility(tabId);
    }
    _switchToTab(tabId);
  }

  /// LaunchPad 点击隐藏 tab：以二级页面路由打开对应功能页（不切换主 tab）。
  void _openTabAsPage(String tabId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _pageForTabAsRoute(tabId)),
    );
  }

  /// tabId → 可作为二级路由打开的页面（复用主 tab 页面，去掉主 tab 专属参数）。
  ///
  /// 二级路由页统一在底部挂全局 MiniPlayer（与主 tab 模式一致）：
  /// - 页面自带 MiniPlayer 的（如 SearchPage）通过 showMiniPlayer: false 关闭，
  ///   避免与这里提供的重复；
  /// - 其余页面在 tab 模式下依赖 _MainLayout 的全局 MiniPlayer，作为二级路由
  ///   打开时没有该全局条，这里统一补上；
  /// - 设置页除外：不挂 MiniPlayer，保持纯设置界面。
  Widget _pageForTabAsRoute(String tabId) {
    final Widget page;
    switch (tabId) {
      case 'discover':
        page = const DiscoverPage();
        break;
      case 'coverflow':
        page = const CoverFlowPage();
        break;
      case 'library':
        page = const LibraryPage();
        break;
      case 'favorites':
        page = const FavoritesPage();
        break;
      case 'fm':
        page = const PersonalFmPage();
        break;
      case 'search':
        // 路由模式的 MiniPlayer 由本方法统一提供，关闭页面自带的以免重复
        page = const SearchPage(showMiniPlayer: false);
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        // 路由模式的 MiniPlayer 由本方法统一提供，关闭页面自带的以免重复
        page = const SongRecognitionPage(showMiniPlayer: false);
        break;
      case 'audiobook':
        page = const AudiobookPage();
        break;
      case 'scene':
        page = const ScenePage();
        break;
      case 'channel':
        page = const ChannelPage();
        break;
      case 'settings':
        page = const SettingsPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    // 设置页不挂 MiniPlayer，其余二级路由页统一挂载
    if (tabId == 'settings') return page;
    return Column(
      children: [
        Expanded(child: page),
        const MiniPlayer(),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当系统即将销毁应用进程时（包含后台划掉 / 系统回收），Flutter 会先收到 detached。
    // 此时同步触发 API 服务器关停：若进程随之被 kill 也无副作用；若进程仍存活则释放端口。
    if (state == AppLifecycleState.detached) {
      // 同步触发即可，Dart 端很快；不 await，避免阻塞 framework 销毁流程
      // ignore: discarded_futures
      KugouApiServer.stop();
    }
  }

  /// 词幕连接失败（原生侧重试耗尽 → connect_failed）回调：弹窗提示用户。
  /// 只在失败标记置位时触发一次，弹窗期间忽略重复事件。
  void _onLyriconStateChanged() {
    if (!LyriconProviderService.instance.connectFailed) return;
    if (_lyriconFailDialogShown) return;
    _lyriconFailDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showLyriconConnectFailedDialog();
    });
  }

  /// 词幕连接失败提示弹窗（用根 Navigator 的 context，任何页面都能弹出）。
  Future<void> _showLyriconConnectFailedDialog() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      _lyriconFailDialogShown = false;
      return;
    }
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('词幕连接失败'),
        content: const Text('多次尝试连接词幕服务失败，请确认已开启词幕（Lyricon），检查设备上的词幕服务是否正常运行后重试。'),
        actions: [
          TextButton(
            onPressed: () {
              LyriconProviderService.instance.connectFailed = false;
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              // 重新启用触发原生侧重新注册，重试逻辑在原生端（AudioPlaybackService）
              // ignore: discarded_futures
              LyriconProviderService.instance.setEnabled(true);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
    _lyriconFailDialogShown = false;
  }

  void _showLoginRequiredDialog() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('播放音乐需要登录账号,是否前往登录?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
            },
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabConfig = context.watch<TabConfigProvider>();
    final visibleTabs = tabConfig.visibleTabs;

    // 安全守卫：如果当前选中索引超出可见 tab 范围，重置到最后一个
    if (_selectedIndex >= visibleTabs.length) {
      _selectedIndex = visibleTabs.length - 1;
      if (_selectedIndex < 0) _selectedIndex = 0;
    }

    // 动态生成导航目标
    final destinations = <NavigationDestination>[];
    for (var i = 0; i < visibleTabs.length; i++) {
      destinations.add(_buildDestination(visibleTabs[i], i));
    }
    final railDestinations = visibleTabs.map(_buildRailDestination).toList();
    final drawerDestinations = visibleTabs
        .map(_buildDrawerDestination)
        .toList();

    // 封面流页横屏沉浸：由「当前 tab + 方向 + 用户长按请求」统一判定。
    // 横屏默认显示 tab 栏，用户长按封面流页面进入沉浸（隐藏 tab 栏），
    // 沉浸中按返回键恢复。判定与页面生命周期无关，
    // 保证「在封面流页内竖屏→横屏旋转」也能正确进入/退出沉浸。
    final safeIndex = _selectedIndex.clamp(0, visibleTabs.length - 1);
    final currentTab = visibleTabs[safeIndex];
    final immersive =
        currentTab.id == 'coverflow' &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        kCoverFlowImmersive.value;
    _syncImmersiveMode(immersive);

    // 一级页面返回拦截：
    // 1) PopScope 拦截系统返回手势 / 物理返回键，canPop=false → 触发 onPopInvoked
    // 2) 封面流沉浸中：返回键先恢复 tab 栏（退出沉浸），不弹退出确认
    // 3) 否则弹“退出 App”确认对话框
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 上滑拖拽展开中：返回键先收起覆盖层，回到 MiniPlayer
        if (playerDragActive.value) {
          playerDragActive.value = false;
          playerExpansion.value = 0.0;
          return;
        }
        if (immersive) {
          kCoverFlowImmersive.value = false;
        } else {
          _showExitConfirmDialog();
        }
      },
      child: ResponsiveScaffold(
        destinations: destinations,
        railDestinations: railDestinations,
        drawerDestinations: drawerDestinations,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          // 守卫：FullPlayer 在栈顶时（展开进度 > 0.5），忽略 tab 切换，
          // 避免与 FullPlayer 动画叠加导致状态混乱。
          if (isFullPlayerOnTop) {
            return;
          }
          setState(() {
            _previousSelectedIndex = _selectedIndex;
            _selectedIndex = index;
          });
        },
        hideNavigation: immersive,
        body: _buildBody(context, visibleTabs, immersive),
        compactBody: _buildBody(context, visibleTabs, immersive),
        mediumBody: _buildBody(context, visibleTabs, immersive),
        expandedBody: _buildBody(context, visibleTabs, immersive),
      ),
    );
  }

  /// 封面流横屏沉浸：同步「实际生效」标志并设置系统栏沉浸模式。
  /// [immersive] 已由调用方按「tab + 方向 + 用户请求」算好；
  /// 状态变化时调用，非沉浸时恢复默认系统栏。
  void _syncImmersiveMode(bool immersive) {
    if (_immersiveSynced == immersive) return;
    _immersiveSynced = immersive;
    kCoverFlowImmersiveActive.value = immersive;
    // build 阶段不直接调用平台 channel，推迟到帧末执行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (immersive) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    });
  }

  Widget _buildBody(
    BuildContext context,
    List<TabItem> visibleTabs,
    bool immersive,
  ) {
    // 切换方向：横屏（侧边导航栏）用上下淡入，竖屏（底部导航栏）用左右滑动
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final useVerticalTransition = isLandscape;
    final goingRight = _selectedIndex > _previousSelectedIndex;

    // 安全守卫
    final safeIndex = _selectedIndex.clamp(0, visibleTabs.length - 1);
    final currentTab = visibleTabs[safeIndex];

    return Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: M3ExpressiveMotion.defaultDuration,
            switchInCurve: const Interval(
              0.5,
              1.0,
              curve: M3ExpressiveMotion.expressiveEasing,
            ),
            switchOutCurve: const Interval(
              0.0,
              0.5,
              curve: M3ExpressiveMotion.expressiveEasing,
            ),
            transitionBuilder: (child, animation) {
              final isEntering = child.key == ValueKey(currentTab.id);

              if (useVerticalTransition) {
                // 侧边导航栏：基于 tab 顺序上下滑动
                final slideY = isEntering
                    ? (goingRight ? 0.1 : -0.1)
                    : (goingRight ? -0.1 : 0.1);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0.0, slideY),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              } else {
                // 底部导航栏：左右滑动淡入淡出
                final slideX = isEntering
                    ? (goingRight ? 0.12 : -0.12)
                    : (goingRight ? -0.12 : 0.12);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(slideX, 0.0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              }
            },
            child: KeyedSubtree(
              key: ValueKey(currentTab.id),
              child: _buildPageForTab(currentTab.id),
            ),
          ),
        ),
        // 封面流页横屏沉浸：隐藏 MiniPlayer，实现全屏浏览
        if (!immersive) const MiniPlayer(),
      ],
    );
  }

  /// 显示"退出 App"确认对话框。
  ///
  /// 点击退出按钮会触发：
  /// 1) `PlayerProvider.pause()` — 停 just_audio + 同步通知栏
  /// 2) `KugouApiServer.stop()` — 释放本地 API 服务器端口，停止服务器
  /// 3) `SystemNavigator.pop()` — 通知系统 finish 当前 Activity，
  ///    系统会随之销毁进程（等同 kill app）
  void _showExitConfirmDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出 App'),
        content: const Text('确定要退出 md3Music 吗？\n将停止播放并释放本地 API 服务器 服务器。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              // 关闭对话框（避免 SystemNavigator.pop 后 context 失效）
              Navigator.of(ctx).pop();
              // 1) 暂停播放（just_audio 内部会停音频 + 通知栏可同步清空）
              // ignore: discarded_futures
              context.read<PlayerProvider>().pause();
              // 2) 关停 API 服务器（释放端口）
              // 必须等待完成，否则端口未释放，下次冷启动会冲突导致闪退
              try {
                await KugouApiServer.stop();
                // nativeStopNode() 在独立线程执行，MethodChannel 返回只代表调用已发出，
                // 需要给 native 线程一点时间完成 服务器线程退出
                await Future.delayed(const Duration(milliseconds: 300));
              } catch (_) {}
              // 3) 杀进程：exit(0) 立即终止整个进程（含服务器线程），
              //    确保端口一定被释放。SystemNavigator.pop() 只 finish Activity，
              //    进程可能残留，导致下次启动时端口冲突/服务器未启动。
              // ignore: avoid_print
              print('Exiting app...');
              exit(0);
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }
}

/// 底部 NavigationBar 的 tab 图标 + 自定义 M3E Expressive 胶囊 indicator。
///
/// **设计思路**（对齐 MD3E MotionScheme.expressive()）：
/// - 关掉 Flutter 原生 NavigationIndicator 的硬切横向拉伸
///   （见 navigation_bar.dart 第 845-849 行，用 easeInOutCubicEmphasized 单轴缩放）
/// - 自己在图标背后画一个 secondaryContainer 色的圆角胶囊
/// - 胶囊出现/消失用 **带过冲的曲线**（easeOutBack，过冲约 10%），
///   对应 MD3E `defaultSpatialSpec` 的"轻微过冲"原则
/// - 胶囊做 **单轴 X 拉伸**（0.4 → 1.0），对齐 Flutter 原生 NavigationIndicator 的形变方式
/// - 图标在胶囊弹起过程中完成 outlined → filled 切换，被弹跳掩盖
///
/// **文字行为**：由 `NavigationBarThemeData.labelBehavior = onlyShowSelected` 控制，
/// Flutter 原生 `_NavigationDestinationLayoutDelegate` 会自动处理：
/// - 未选中：label 隐藏，icon 垂直居中
/// - 选中：label 淡入 + icon 上移让位（见 navigation_bar.dart 第 1103-1130 行）
///
/// 不使用 NavigationDestination.selectedIcon（Flutter 原生内部是硬切）。
class _AnimatedTabIcon extends StatefulWidget {
  final bool selected;
  final IconData outlinedIcon;
  final IconData filledIcon;

  const _AnimatedTabIcon({
    required this.selected,
    required this.outlinedIcon,
    required this.filledIcon,
  });

  @override
  State<_AnimatedTabIcon> createState() => _AnimatedTabIconState();
}

class _AnimatedTabIconState extends State<_AnimatedTabIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // 胶囊的弹簧进度（0 = 隐藏，1 = 完全展开）
  // 用 easeOutBack 曲线产生轻微过冲，对齐 MD3E Expressive 风格
  late final Animation<double> _progress;

  // MD3E 胶囊尺寸（对齐 Flutter 原生 _kIndicatorWidth/Height）
  static const double _indicatorWidth = 64.0;
  static const double _indicatorHeight = 32.0;
  static const double _indicatorRadius = 16.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: M3ExpressiveMotion.defaultDuration,
      vsync: this,
    );
    // 初始状态：选中则胶囊已展开
    _controller.value = widget.selected ? 1.0 : 0.0;
    _progress = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurveTween(curve: Curves.easeOutBack).animate(_controller));
  }

  @override
  void didUpdateWidget(_AnimatedTabIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      if (widget.selected) {
        _controller.forward(from: 0);
      } else {
        _controller.reverse(from: 1);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) {
        // easeOutBack 在 [0,1] 内会有过冲（峰值约 1.1），clamp 到 [0, 1.1]
        final t = _progress.value;
        final tClamped = t.clamp(0.0, 1.1);
        // 胶囊单轴 X 拉伸：从 0.4 → 1.0，带过冲
        // 对齐 Flutter 原生 NavigationIndicator 的单轴形变方式
        final scaleX = Tween<double>(begin: 0.4, end: 1.0).transform(tClamped);
        return Stack(
          alignment: Alignment.center,
          children: [
            // 底层：自定义 expressive 胶囊 indicator（单轴拉伸 + 过冲）
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(scaleX, 1.0, 1.0),
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Container(
                  width: _indicatorWidth,
                  height: _indicatorHeight,
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius:
                        BorderRadius.circular(_indicatorRadius),
                  ),
                ),
              ),
            ),
            // 上层：图标（选中用 filled，未选中用 outlined）
            Icon(
              widget.selected ? widget.filledIcon : widget.outlinedIcon,
            ),
          ],
        );
      },
    );
  }
}
