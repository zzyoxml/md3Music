import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/layout/responsive_layout.dart';
import 'core/theme/app_theme.dart';
import 'data/models/playlist.dart';
import 'modules/discover/discover_page.dart';
import 'modules/charts/charts_page.dart';
import 'modules/user/user_center_page.dart';

import 'modules/player/full_player.dart';
import 'modules/player/mini_player.dart';
import 'modules/playlist/playlist_page.dart';
import 'modules/search/search_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/library/library_page.dart';
import 'modules/login/login_page.dart';
import 'modules/personal_fm/personal_fm_page.dart';
import 'providers/downloads_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/kugou_provider.dart';
import 'providers/library_provider.dart';
import 'providers/player_provider.dart';
import 'providers/theme_provider.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => DownloadsProvider()),
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

    return MaterialApp(
      title: 'MD3Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      initialRoute: '/',
      routes: {
        '/': (_) => const _MainLayout(),
        '/search': (_) => const SearchPage(),
        '/library': (_) => const LibraryPage(),
        '/settings': (_) => const SettingsPage(),
        '/player': (_) => const FullPlayer(),
        '/personal_fm': (_) => const PersonalFmPage(),
      },
      onGenerateRoute: (settings) {
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

class _MainLayout extends StatefulWidget {
  const _MainLayout();

  @override
  State<_MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<_MainLayout> {
  int _selectedIndex = 0;

  final List<Widget> _pages = const [
    DiscoverPage(),
    ChartsPage(),
    PersonalFmPage(),
    UserCenterPage(),
  ];

  @override
  void initState() {
    super.initState();
    // 未登录时尝试播放联网歌曲,弹出登录提示
    context.read<PlayerProvider>().onLoginRequired = _showLoginRequiredDialog;
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
    return ResponsiveScaffold(
      destinations: _destinations,
      railDestinations: _railDestinations,
      drawerDestinations: _drawerDestinations,
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) {
        setState(() {
          _selectedIndex = index;
        });
      },
      body: Column(
        children: [
          Expanded(child: _pages[_selectedIndex]),
          const MiniPlayer(),
        ],
      ),
      compactBody: Column(
        children: [
          Expanded(child: _pages[_selectedIndex]),
          const MiniPlayer(),
        ],
      ),
      mediumBody: Column(
        children: [
          Expanded(child: _pages[_selectedIndex]),
          const MiniPlayer(),
        ],
      ),
      expandedBody: Column(
        children: [
          Expanded(child: _pages[_selectedIndex]),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
