import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/layout/responsive_layout.dart';
import 'core/theme/app_theme.dart';
import 'data/models/playlist.dart';
import 'modules/home/home_page.dart';
import 'modules/library/library_page.dart';
import 'modules/player/full_player.dart';
import 'modules/player/mini_player.dart';
import 'modules/playlist/playlist_page.dart';
import 'modules/search/search_page.dart';
import 'modules/settings/settings_page.dart';
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
      title: 'EchoMusic',
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
        '/playlist': (_) => const PlaylistPage(
              playlist: Playlist(
                id: '',
                name: '',
                songCount: 0,
                songs: [],
              ),
            ),
        '/player': (_) => const FullPlayer(),
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
    HomePage(),
    SearchPage(),
    LibraryPage(),
    SettingsPage(),
  ];

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: '首页',
    ),
    NavigationDestination(
      icon: Icon(Icons.search_outlined),
      selectedIcon: Icon(Icons.search),
      label: '搜索',
    ),
    NavigationDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: '音乐库',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  static const List<NavigationRailDestination> _railDestinations = [
    NavigationRailDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: Text('首页'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.search_outlined),
      selectedIcon: Icon(Icons.search),
      label: Text('搜索'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: Text('音乐库'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text('设置'),
    ),
  ];

  static const List<NavigationDrawerDestination> _drawerDestinations = [
    NavigationDrawerDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: Text('首页'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.search_outlined),
      selectedIcon: Icon(Icons.search),
      label: Text('搜索'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: Text('音乐库'),
    ),
    NavigationDrawerDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text('设置'),
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
          Expanded(
            child: _pages[_selectedIndex],
          ),
          const MiniPlayer(),
        ],
      ),
      compactBody: Column(
        children: [
          Expanded(
            child: _pages[_selectedIndex],
          ),
          const MiniPlayer(),
        ],
      ),
      mediumBody: Column(
        children: [
          Expanded(
            child: _pages[_selectedIndex],
          ),
          const MiniPlayer(),
        ],
      ),
      expandedBody: Column(
        children: [
          Expanded(
            child: _pages[_selectedIndex],
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
