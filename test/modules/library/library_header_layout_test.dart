import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Library extends LibraryProvider {
  _Library({this.withMusic = true});
  final bool withMusic;
  int scans = 0;
  @override
  bool get hasMusic => withMusic;
  @override
  Future<void> loadSavedSongs() async {}
  @override
  Future<void> loadScanFolders() async {}
  @override
  Future<void> loadLocalMusic() async {
    scans++;
  }
}

class _Player extends ChangeNotifier implements PlayerProvider {
  @override
  Song? get currentSong => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    bool withMusic = true,
    double scale = 1,
    double safe = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = _Library(withMusic: withMusic);
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<PlayerProvider>(create: (_) => _Player()),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: EdgeInsets.fromLTRB(safe, 0, safe, 76),
              viewPadding: EdgeInsets.fromLTRB(safe, 0, safe, 20),
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: const LibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('竖屏分类居中且横屏加号位于分类行右侧', (tester) async {
    await pump(tester, const Size(400, 900));
    final search = tester.getRect(find.byType(TextField));
    final left = tester.getRect(find.text('曲目')).left;
    final right = tester.getRect(find.text('收藏')).right;
    final delta = (left + right) / 2 - search.center.dx;
    final portraitFab = find.byType(M3EFab).evaluate().length;
    tester.view.physicalSize = const Size(900, 420);
    await tester.pumpAndSettle();
    final add = tester.getRect(find.byIcon(Icons.add));
    final category = tester.getRect(find.byType(TabBar));
    final inAppBar = find
        .ancestor(of: find.byIcon(Icons.add), matching: find.byType(AppBar))
        .evaluate()
        .isNotEmpty;
    final landscapeFab = find.byType(M3EFab).evaluate().length;
    debugPrint(
      jsonEncode({
        'portraitTabsCenterDelta': delta,
        'portraitFab': portraitFab,
        'landscapeAddY': add.center.dy,
        'landscapeCategoryCenterY': category.center.dy,
        'landscapeAddInAppBar': inAppBar,
        'landscapeFab': landscapeFab,
      }),
    );
    expect(delta, closeTo(0, .1), reason: '竖屏五个分类的整体中点应位于页面中线');
    expect(portraitFab, 1);
    expect(inAppBar, isTrue);
    expect(landscapeFab, 0);
    expect(add.center.dy, closeTo(category.center.dy, 1));
    expect(add.center.dx, greaterThan(category.right));
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(900, 420), Size(720, 360), Size(500, 340)]) {
    testWidgets('横屏加号对齐内容右缘且仍可扫描 $size', (tester) async {
      await pump(tester, size, safe: 24);
      final action = find.byKey(const ValueKey('library_scan_toolbar'));
      final rect = tester.getRect(action);
      final width = size.width - 48;
      final expectedRight =
          size.width - 24 - (width > 840 ? (width - 840) / 2 : 0) - 16;
      expect(rect.right, closeTo(expectedRight, .1));
      expect(rect.height, greaterThanOrEqualTo(48));
      final tabsRect = tester.getRect(find.byType(TabBar));
      expect(rect.center.dy, closeTo(tabsRect.center.dy, 1));
      expect(rect.left, greaterThan(tabsRect.right));
      final field = tester.widget<TextField>(find.byType(TextField));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('扫描本地音乐'), findsWidgets);
      expect(field.focusNode!.hasFocus, isFalse);
      final page = tester.element(find.byType(LibraryPage));
      final library = page.read<LibraryProvider>() as _Library;
      // 矮横屏也要能滚到最后一项，不仅是能点开菜单。
      final filter = find.byType(SwitchListTile);
      await tester.ensureVisible(filter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('过滤不超过 60 秒的音频'));
      await tester.pumpAndSettle();
      expect(library.filterShortAudio, isTrue);
      await tester.ensureVisible(find.text('扫描音乐'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('扫描音乐'));
      await tester.pumpAndSettle();
      expect(library.scans, 1);
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('横屏空库仍可从右上角打开扫描', (tester) async {
    await pump(tester, const Size(900, 420), withMusic: false);
    expect(find.byType(M3EFab), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library_scan_toolbar')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('扫描音乐')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字体竖屏保留居中配置与可滚动分类', (tester) async {
    await pump(tester, const Size(320, 700), scale: 1.5);
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.tabAlignment, TabAlignment.center);
    expect(tabs.isScrollable, isTrue);
    await tester.ensureVisible(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 4);
    expect(tester.takeException(), isNull);
  });
}
