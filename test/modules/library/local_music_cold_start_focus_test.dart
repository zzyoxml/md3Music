import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

/// 不启动播放 / 扫描的空壳 PlayerProvider。
class _IdlePlayer extends ChangeNotifier implements PlayerProvider {
  @override
  Song? get currentSong => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Discover extends StatelessWidget {
  const _Discover();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('发现')));
}

/// 复刻 app.dart `_MainLayout` 的壳层结构：`ResponsiveScaffold` + `ResponsiveShell`，
/// tab 0 = 发现、tab 1 = 本地音乐。冷启动时停在 tab 0，用户点底栏切到本地音乐。
class _MainShellHost extends StatefulWidget {
  const _MainShellHost();
  @override
  State<_MainShellHost> createState() => _MainShellHostState();
}

class _MainShellHostState extends State<_MainShellHost> {
  int _index = 0;
  final shellKey = GlobalKey<ResponsiveShellState>();

  @override
  Widget build(BuildContext context) {
    return ResponsiveScaffold(
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: '发现'),
        NavigationDestination(icon: Icon(Icons.library_music), label: '本地音乐'),
      ],
      railDestinations: const [
        NavigationRailDestination(icon: Icon(Icons.home), label: Text('发现')),
        NavigationRailDestination(
            icon: Icon(Icons.library_music), label: Text('本地音乐')),
      ],
      drawerDestinations: const [],
      selectedIndex: _index,
      onDestinationSelected: (index) => setState(() => _index = index),
      body: ResponsiveShell(
        key: shellKey,
        visibleTabs: const [
          TabItem(id: 'discover', label: '发现', pinnedTitle: true),
          TabItem(id: 'library', label: '本地音乐', pinnedTitle: true),
        ],
        selectedIndex: _index,
        pageBuilder: (id) =>
            id == 'library' ? const LibraryPage() : const _Discover(),
      ),
    );
  }
}

/// 预置扫描缓存：冷启动时 `LibraryProvider` 先是空的，
/// [LibraryProvider.loadSavedSongs] 在首帧后才把歌曲回填，
/// 搜索框随之从「不构建」翻到「构建」——这正是缺陷的触发路径。
Future<List<Song>> _seedCachedSongs() async {
  final repository = LocalMusicRepository();
  final songs = [
    Song(
      id: 'cold-start-1',
      title: '冷启动回归',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(seconds: 200),
      localPath: '/Music/A/a.mp3',
    ),
  ];
  await repository.saveSongs(songs);
  return songs;
}

Future<void> _pumpShell(WidgetTester tester) async {
  await _seedCachedSongs();
  final library = LibraryProvider();
  final player = _IdlePlayer();
  addTearDown(library.dispose);
  addTearDown(player.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MaterialApp(home: _MainShellHost()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // 本地 Rust 服务器 ready：否则 KugouApiClient._onRequest 会挂一个 8s 等待
  // 定时器，树卸载后仍 pending，被测试框架判为「Timer is still pending」
  // （与本用例的断言无关，纯粹是噪音）。
  setUpAll(KugouApiClient.markServerReady);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('冷启动切到本地音乐 tab：不自动聚焦搜索框、不弹输入法', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    await _pumpShell(tester);

    // 冷启动后用户点击底部导航栏的「本地音乐」
    await tester.tap(find.text('本地音乐'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode, isNotNull);
    expect(field.focusNode!.hasFocus, isFalse,
        reason: '搜索框在缓存回填后才挂载，不得被框架焦点链路自动抢到焦点');
    expect(tester.testTextInput.hasAnyClients, isFalse,
        reason: '焦点即输入法判据：无焦点则不得建立输入连接');
  });

  testWidgets('冷启动切到本地音乐 tab：主动点击仍可输入', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    await _pumpShell(tester);

    await tester.tap(find.text('本地音乐'));
    await tester.pumpAndSettle();
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focus.hasFocus, isFalse);

    // 用户主动点击仍然要能输入（修复不能把主动输入也一起废掉）
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地音乐 tab 反复切走再切回：不抢焦点', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);
    await _pumpShell(tester);

    // 全程只点底栏（不直接 setState），与用户操作等价。
    for (final label in ['本地音乐', '发现', '本地音乐']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  });
}

