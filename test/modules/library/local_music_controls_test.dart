import 'package:material_ui/material_ui.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/models/music_folder.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/data/models/artist.dart';
import 'package:md3music/modules/library/albums_page.dart';
import 'package:md3music/modules/library/artists_page.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/modules/library/folders_page.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final pages = <String, Widget>{
    '文件夹': const FoldersPage(
      folders: [MusicFolder(path: '/Music/A', name: 'A', songIds: [])],
    ),
    '专辑': AlbumsPage(
      albums: [
        Album(
          id: 'A',
          name: 'A',
          artist: '歌手',
          songCount: 0,
          artworkUri: File(
            'assets/images/app_icon.png',
          ).absolute.uri.toString(),
        ),
      ],
    ),
    '艺术家': const ArtistsPage(
      artists: [Artist(id: 'A', name: 'A', songCount: 0, albumCount: 0)],
    ),
  };
  for (final entry in pages.entries) {
    testWidgets('搜索框有焦点时进入${entry.key}，返回不恢复输入焦点', (tester) async {
      final searchFocus = FocusNode();
      final navigatorKey = GlobalKey<NavigatorState>();
      addTearDown(searchFocus.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LibraryProvider()),
            ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
            ChangeNotifierProvider(create: (_) => DeviceProvider()),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: Column(
                children: [
                  TextField(focusNode: searchFocus),
                  Expanded(child: entry.value),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(searchFocus.hasFocus, isTrue);
      await tester.tap(find.text('A'));
      // 在详情首帧之前返回，仅验证导航焦点恢复，不启动播放服务。
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(searchFocus.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      // 用户主动点击仍然能够输入。
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(searchFocus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  }

  testWidgets('加号随播放栏占位上移，菜单过滤默认关闭且可切换', (tester) async {
    // 竖屏保留 FAB；横屏扫描入口已移到右上角工具栏。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    var reserved = 0.0;
    Widget page() => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: library),
        // LibraryPage 的 build 会读取页面标题对齐配置，缺失即整页构建失败。
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: reserved),
            viewPadding: EdgeInsets.zero,
          ),
          child: child!,
        ),
        home: const LibraryPage(),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final original = tester.getCenter(find.byIcon(Icons.add)).dy;
    reserved = 76;
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final raised = tester.getCenter(find.byIcon(Icons.add)).dy;
    expect(original - raised, greaterThanOrEqualTo(76));
    expect(tester.getRect(find.byIcon(Icons.add)).bottom, lessThan(800 - 76));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.text('过滤不超过 60 秒的音频'));
    await tester.pumpAndSettle();
    expect(library.filterShortAudio, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹全选、取消和确认移除的完整流程', (tester) async {
    const toastChannel = MethodChannel('PonnamKarthik/fluttertoast');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      toastChannel,
      (_) async => true,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        toastChannel,
        null,
      ),
    );
    final repository = LocalMusicRepository();
    await repository.saveSongs([
      for (final folder in ['A', 'B'])
        Song(
          id: folder,
          title: folder,
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(seconds: 120),
          localPath: '/Music/$folder/a.mp3',
        ),
    ]);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await library.loadSavedSongs();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: library,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<LibraryProvider>(
              builder: (context, value, child) =>
                  FoldersPage(folders: value.folders),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个'), findsOneWidget);
    await tester.tap(find.byTooltip('移除所选文件夹索引'));
    await tester.pumpAndSettle();
    expect(find.text('移除 2 个文件夹？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.allSongs, hasLength(2));
    expect(await repository.getExcludedFolders(), isEmpty);
    await tester.tap(find.byTooltip('移除所选文件夹索引'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除索引'));
    await tester.pumpAndSettle();
    expect(library.allSongs, isEmpty);
    expect(library.folders, isEmpty);
    expect(find.text('暂无文件夹'), findsOneWidget);
    expect(
      await repository.getExcludedFolders(),
      containsAll(['/Music/A', '/Music/B']),
    );
    // 等待 Toast 的节流计时器结束。
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 TV：扫描 FAB 整树禁聚焦，M3E 内核焦点环不随键盘遍历出现', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: library),
          // 页面标题对齐（page_title_alignment）会 watch TabConfigProvider。
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();
    // M3EButton 内核自建 FocusNode 并用 FocusRing 画 primary 色描边，外观与
    // TV 焦点环一致；非 TV 下键盘方向键/Tab 遍历到就会显示。契约：FAB 必须在
    // ExcludeFocus 内（与 TV 下 DpadFocusable.excludeChildFocus 同语义），
    // 保证该节点永远无法持焦。
    expect(
      find.ancestor(
        of: find.byType(M3EFab),
        matching: find.byType(ExcludeFocus),
      ),
      findsOneWidget,
    );
  });
}
