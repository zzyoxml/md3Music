import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:quick_actions/quick_actions.dart';

import 'core/layout/responsive_layout.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/motion_constants.dart';
import 'data/models/playlist.dart';
import 'main.dart'
    show
        appNavigatorKey,
        handleShortcut,
        pendingShortcutType,
        shortcutTabRequest;
import 'modules/discover/discover_page.dart';
import 'modules/charts/charts_page.dart';
import 'modules/user/user_center_page.dart';
import 'modules/user/favorites_page.dart';

import 'modules/player/full_player.dart';
import 'modules/player/full_player_route.dart';
import 'modules/player/mini_player.dart';
import 'modules/playlist/playlist_page.dart';
import 'modules/search/search_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/library/library_page.dart';
import 'modules/login/login_page.dart';
import 'modules/onboarding/onboarding_page.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'modules/personal_fm/personal_fm_page.dart';
import 'modules/recognition/song_recognition_page.dart';
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
import 'providers/tab_config_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/comment_display_provider.dart';
import 'services/nodejs_server.dart';
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
  @override
  void initState() {
    super.initState();
    // 注册 Android 长按应用图标 Shortcut items
    const quickActions = QuickActions();
    quickActions.setShortcutItems(const [
      ShortcutItem(
        type: 'action_open_favorites',
        localizedTitle: '我的收藏',
        icon: 'ic_shortcut_favorite',
      ),
      ShortcutItem(
        type: 'action_open_recognition',
        localizedTitle: '听歌识曲',
        icon: 'ic_shortcut_mic',
      ),
      ShortcutItem(
        type: 'action_open_search',
        localizedTitle: '搜索',
        icon: 'ic_shortcut_search',
      ),
    ]);
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

  /// 根据 tab id 构建对应页面 Widget。
  Widget _buildPageForTab(String tabId) {
    switch (tabId) {
      case 'discover':
        return DiscoverPage(
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
      case 'library':
        return const LibraryPage();
      case 'favorites':
        return const FavoritesPage();
      case 'fm':
        return const PersonalFmPage();
      case 'search':
        // Tab 模式：隐藏页面自带 MiniPlayer，由 _MainLayout 统一提供全局 MiniPlayer
        return const SearchPage(showMiniPlayer: false);
      case 'charts':
        return const ChartsPage();
      case 'recognition':
        return const SongRecognitionPage();
      case 'user':
        return const UserCenterPage();
      default:
        return const SizedBox.shrink();
    }
  }

  /// 根据 tab id 获取对应的 NavigationDestination 图标。
  NavigationDestination _buildDestination(TabItem tab) {
    switch (tab.id) {
      case 'discover':
        return NavigationDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          label: tab.label,
        );
      case 'library':
        return NavigationDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          label: tab.label,
        );
      case 'favorites':
        return NavigationDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          label: tab.label,
        );
      case 'fm':
        return NavigationDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          label: tab.label,
        );
      case 'search':
        return NavigationDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: tab.label,
        );
      case 'charts':
        return NavigationDestination(
          icon: const Icon(Icons.leaderboard_outlined),
          selectedIcon: const Icon(Icons.leaderboard),
          label: tab.label,
        );
      case 'recognition':
        return NavigationDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          label: tab.label,
        );
      case 'user':
        return NavigationDestination(
          icon: const Icon(Icons.person_outlined),
          selectedIcon: const Icon(Icons.person),
          label: tab.label,
        );
      default:
        return NavigationDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          label: tab.label,
        );
    }
  }

  NavigationRailDestination _buildRailDestination(TabItem tab) {
    switch (tab.id) {
      case 'discover':
        return NavigationRailDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
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
      case 'recognition':
        return NavigationRailDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
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
      case 'discover':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
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
      case 'recognition':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
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
    // 监听应用生命周期：detached（进程被系统销毁前的最后窗口）时尝试关停本地 Node.js
    WidgetsBinding.instance.addObserver(this);
    // 监听 shortcut 入口的 tab 切换请求（来自 main.dart 的 handleShortcut）
    shortcutTabRequest.addListener(_handleShortcutTabRequest);
  }

  @override
  void dispose() {
    shortcutTabRequest.removeListener(_handleShortcutTabRequest);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 处理 shortcut 入口的 tab 切换请求
  void _handleShortcutTabRequest() {
    final index = shortcutTabRequest.value;
    if (index == null) return;
    shortcutTabRequest.value = null;
    setState(() => _selectedIndex = index);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当系统即将销毁应用进程时（包含后台划掉 / 系统回收），Flutter 会先收到 detached。
    // 此时同步触发 Node.js 关闭：若进程随之被 kill 也无副作用；若进程仍存活则关闭 libuv。
    if (state == AppLifecycleState.detached) {
      // 同步触发即可，Dart 端很快；不 await，避免阻塞 framework 销毁流程
      // ignore: discarded_futures
      NodeJsServer.stop();
    }
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
    final destinations = visibleTabs.map(_buildDestination).toList();
    final railDestinations = visibleTabs.map(_buildRailDestination).toList();
    final drawerDestinations = visibleTabs
        .map(_buildDrawerDestination)
        .toList();

    // 一级页面返回拦截：
    // 1) PopScope 拦截系统返回手势 / 物理返回键，canPop=false → 触发 onPopInvoked
    // 2) 弹“退出 App”确认对话框
    // 3) 确认后顺序关停：暂停播放 → 关停本地 Node.js → SystemNavigator.pop 杀进程
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitConfirmDialog();
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
        body: _buildBody(context, visibleTabs),
        compactBody: _buildBody(context, visibleTabs),
        mediumBody: _buildBody(context, visibleTabs),
        expandedBody: _buildBody(context, visibleTabs),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<TabItem> visibleTabs) {
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
        const MiniPlayer(),
      ],
    );
  }

  /// 显示"退出 App"确认对话框。
  ///
  /// 点击退出按钮会触发：
  /// 1) `PlayerProvider.pause()` — 停 just_audio + 同步通知栏
  /// 2) `NodeJsServer.stop()` — 释放 127.0.0.1:8080 端口 + 关 libuv
  /// 3) `SystemNavigator.pop()` — 通知系统 finish 当前 Activity，
  ///    系统会随之销毁进程（等同 kill app）
  void _showExitConfirmDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出 App'),
        content: const Text('确定要退出 md3Music 吗？\n将停止播放并释放本地 Node.js 服务器。'),
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
              // 2) 关停 Node.js（释放 8080 端口 + libuv 事件循环退出）
              // 必须等待完成，否则端口未释放，下次冷启动会冲突导致闪退
              try {
                await NodeJsServer.stop();
                // nativeStopNode() 在独立线程执行，MethodChannel 返回只代表调用已发出，
                // 需要给 native 线程一点时间完成 libuv 事件循环退出
                await Future.delayed(const Duration(milliseconds: 300));
              } catch (_) {}
              // 3) 杀进程：exit(0) 立即终止整个进程（含 Node.js 线程），
              //    确保 8080 端口一定被释放。SystemNavigator.pop() 只 finish Activity，
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
