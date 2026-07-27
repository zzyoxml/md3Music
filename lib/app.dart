import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/layout/responsive_layout.dart';
import 'core/theme/app_theme.dart';
import 'data/models/playlist.dart';
import 'main.dart' show appNavigatorKey;
import 'modules/charts/charts_page.dart';
import 'modules/discover/discover_page.dart';
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
import 'modules/personal_fm/personal_fm_page.dart';
import 'modules/recognition/song_recognition_page.dart';
import 'providers/downloads_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/kugou_provider.dart';
import 'providers/library_provider.dart';
import 'providers/player_provider.dart';
import 'providers/playlist_collection_notifier.dart';
import 'providers/device_provider.dart';
import 'providers/theme_provider.dart';
import 'services/nodejs_server.dart';

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
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => DownloadsProvider()),
        // 跨页面广播「收藏的歌单」变更（详情页 → 我的收藏 tab 立即刷新）
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
      ],
      child: const _AppView(),
    );
  }
}

class _AppView extends StatelessWidget {
  const _AppView();

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
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: _SystemUiUpdater(child: child!),
        );
      },
      navigatorKey: appNavigatorKey,
      initialRoute: '/',
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

class _SystemUiUpdaterState extends State<_SystemUiUpdater> with WidgetsBindingObserver {
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

    // 主界面使用非沉浸模式：状态栏不透明（用 surface 色填充），
    // 导航栏跟随 surface 色，确保从播放器沉浸模式返回后恢复正常显示。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: surfaceColor,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: surfaceColor,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));
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

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      DiscoverPage(onAvatarTap: () => setState(() {
        _previousSelectedIndex = _selectedIndex;
        _selectedIndex = 4;
      })),
      const ChartsPage(),
      const FavoritesPage(),
      const PersonalFmPage(),
      const UserCenterPage(),
    ];
    // 未登录时尝试播放联网歌曲,弹出登录提示
    context.read<PlayerProvider>().onLoginRequired = _showLoginRequiredDialog;
    // 监听应用生命周期：detached（进程被系统销毁前的最后窗口）时尝试关停本地 Node.js
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: '发现',
    ),
    NavigationDestination(
      icon: Icon(Icons.trending_up_outlined),
      selectedIcon: Icon(Icons.trending_up),
      label: '排行',
    ),
    NavigationDestination(
      icon: Icon(Icons.favorite_outline),
      selectedIcon: Icon(Icons.favorite),
      label: '我收藏',
    ),
    NavigationDestination(
      icon: Icon(Icons.radio_outlined),
      selectedIcon: Icon(Icons.radio),
      label: '私人FM',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outlined),
      selectedIcon: Icon(Icons.person),
      label: '我的',
    ),
  ];

  static const List<NavigationRailDestination> _railDestinations = [
    NavigationRailDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: Text('发现'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.trending_up_outlined),
      selectedIcon: Icon(Icons.trending_up),
      label: Text('排行'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.favorite_outline),
      selectedIcon: Icon(Icons.favorite),
      label: Text('我收藏'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.radio_outlined),
      selectedIcon: Icon(Icons.radio),
      label: Text('私人FM'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.person_outlined),
      selectedIcon: Icon(Icons.person),
      label: Text('我的'),
    ),
  ];

  static const List<NavigationDrawerDestination> _drawerDestinations = [
    NavigationDrawerDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: Text('发现'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.trending_up_outlined),
      selectedIcon: Icon(Icons.trending_up),
      label: Text('排行'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.favorite_outline),
      selectedIcon: Icon(Icons.favorite),
      label: Text('我收藏'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.radio_outlined),
      selectedIcon: Icon(Icons.radio),
      label: Text('私人FM'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.person_outlined),
      selectedIcon: Icon(Icons.person),
      label: Text('我的'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // 一级页面返回拦截：
    // 1) PopScope 拦截系统返回手势 / 物理返回键，canPop=false → 触发 onPopInvoked
    // 2) 弹"退出 App"确认对话框
    // 3) 确认后顺序关停：暂停播放 → 关停本地 Node.js → SystemNavigator.pop 杀进程
    //    任务栈为空时系统默认行为是退出 App，但不会主动关停 Node.js server 和
    //    audio service，端口会被占用（下一次冷启动会冲突），通知栏会残留。
    //    因此需要这个拦截 + 手动 cleanup。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitConfirmDialog();
      },
      child: ResponsiveScaffold(
        destinations: _destinations,
        railDestinations: _railDestinations,
        drawerDestinations: _drawerDestinations,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          // 守卫：FullPlayer 在栈顶时（展开进度 > 0.5），忽略 tab 切换，
          // 避免与 FullPlayer 动画叠加导致状态混乱。
          // 阈值用 0.5 与 isFullPlayerOnTop 一致，避免 dismiss 期间残留的小数值误拦截
          if (isFullPlayerOnTop) {
            return;
          }
          setState(() {
            _previousSelectedIndex = _selectedIndex;
            _selectedIndex = index;
          });
        },
        body: _buildBody(context),
        compactBody: _buildBody(context),
        mediumBody: _buildBody(context),
        expandedBody: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 切换方向：横屏（侧边导航栏）用上下淡入，竖屏（底部导航栏）用左右滑动
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final useVerticalTransition = isLandscape;
    final goingRight = _selectedIndex > _previousSelectedIndex;

    return Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: const Interval(0.5, 1.0, curve: Curves.easeOut),
            switchOutCurve: const Interval(0.0, 0.5, curve: Curves.easeIn),
            transitionBuilder: (child, animation) {
              final isEntering = child.key == ValueKey(_selectedIndex);

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
              key: ValueKey(_selectedIndex),
              child: _pages[_selectedIndex],
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
