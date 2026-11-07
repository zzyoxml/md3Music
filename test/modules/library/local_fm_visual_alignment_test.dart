import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tracks = [
  KugouSongDetail(hash: 'a', songName: '仰望', artistName: '杨丞琳'),
  KugouSongDetail(hash: 'b', songName: '在深秋', artistName: '阿悄'),
  KugouSongDetail(hash: 'c', songName: '晴', artistName: '汪苏泷'),
];

class _Library extends LibraryProvider {
  @override
  bool get hasMusic => true;
  @override
  List<Song> get songs => [
    for (var i = 0; i < 12; i++)
      Song(
        id: 'local-$i',
        title: '本地歌曲 $i',
        artist: '歌手',
        album: '专辑',
        duration: const Duration(minutes: 3),
        localPath: '/fixture/$i.mp3',
      ),
  ];
  @override
  Future<void> loadSavedSongs() async {}
  @override
  Future<void> loadScanFolders() async {}
}

class _Kugou extends ChangeNotifier implements KugouProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  bool get isLoggedIn => true;
  @override
  List<KugouSongDetail> get personalFmSongs => _tracks;
  @override
  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
    bool forceRefresh = false,
  }) async {}
  @override
  Future<List<KugouSongDetail>?> reportPersonalFmAction({
    required String action,
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? curMark,
    int? playtime,
    bool isOverplay = false,
  }) async => null;
}

class _Player extends PlayerProvider {
  @override
  Song? get currentSong => _tracks.first.toSong();
  @override
  bool get isPlaying => false;
  @override
  List<Song> get playlist => const [];
  @override
  int get currentIndex => -1;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
}

class _Favorites extends FavoritesProvider {
  @override
  Future<void> loadFavorites() async {}
  @override
  bool isFavorite(String songId) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const baseline = bool.fromEnvironment('VISUAL_BASELINE');
  const capture = bool.fromEnvironment('VISUAL_CAPTURE');
  final phase = baseline ? 'baseline' : 'modified';
  setUpAll(() async {
    if (!capture) return;
    final icons = File(
      r'D:\dev\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    );
    if (icons.existsSync()) {
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await iconLoader.load();
    }
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('VisualTest')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
  });

  for (final scenario in const [
    (size: Size(400, 900), safe: 0.0, bottom: 0.0, scale: 1.0),
    (size: Size(900, 420), safe: 0.0, bottom: 0.0, scale: 1.0),
    (size: Size(720, 360), safe: 0.0, bottom: 0.0, scale: 1.0),
    (size: Size(1200, 800), safe: 0.0, bottom: 0.0, scale: 1.0),
    (size: Size(500, 340), safe: 0.0, bottom: 0.0, scale: 1.0),
    (size: Size(900, 420), safe: 24.0, bottom: 76.0, scale: 1.3),
    (size: Size(400, 900), safe: 0.0, bottom: 76.0, scale: 1.4),
  ]) {
    final size = scenario.size;
    testWidgets('两页视觉基线 $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundaryKey = GlobalKey();
      Future<void> pump(Widget page) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<LibraryProvider>(
                create: (_) => _Library(),
              ),
              ChangeNotifierProvider<PlayerProvider>(create: (_) => _Player()),
              ChangeNotifierProvider<KugouProvider>(create: (_) => _Kugou()),
              ChangeNotifierProvider<FavoritesProvider>(
                create: (_) => _Favorites(),
              ),
              ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
              ChangeNotifierProvider(create: (_) => TabConfigProvider()),
              ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: EdgeInsets.fromLTRB(
                    scenario.safe,
                    0,
                    scenario.safe,
                    scenario.bottom,
                  ),
                  viewPadding: EdgeInsets.fromLTRB(
                    scenario.safe,
                    0,
                    scenario.safe,
                    scenario.bottom > 0 ? 20 : 0,
                  ),
                  textScaler: TextScaler.linear(scenario.scale),
                ),
                child: child!,
              ),
              theme: ThemeData(
                useMaterial3: true,
                fontFamily: 'VisualTest',
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff64702b),
                ),
              ),
              home: RepaintBoundary(key: boundaryKey, child: page),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
      }

      Future<void> screenshot(String page) async {
        if (!capture ||
            scenario.scale != 1 ||
            (size.width != 400 && size.width != 900)) {
          return;
        }
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File(
            'tmp/fm-card-layout/previews/$page-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        });
      }

      await pump(const LibraryPage());
      final search = tester.getRect(find.byType(TextField));
      final tabs = tester.getRect(find.byType(TabBar));
      await screenshot('library');
      expect(tester.takeException(), isNull);
      await pump(const PersonalFmPage());
      final hero = tester.getRect(find.byKey(const ValueKey('fm-hero-card')));
      final switches = tester.getRect(
        find.byKey(const ValueKey('fm-recommendation-controls')),
      );
      final queue = tester.getRect(
        find.byKey(const ValueKey('fm-upcoming-queue')),
      );
      debugPrint(
        jsonEncode({
          'phase': phase,
          'size': '${size.width}x${size.height}',
          'searchLeft': search.left,
          'heroLeft': hero.left,
          'heroWidth': hero.width,
          'tabsY': tabs.center.dy,
          'searchY': search.center.dy,
          'switchLeft': switches.left,
          'queueLeft': queue.left,
          'queueTop': queue.top,
          'heroBottom': hero.bottom,
        }),
      );
      if (!baseline) {
        final width = size.width - scenario.safe * 2;
        final left = scenario.safe + (width > 840 ? (width - 840) / 2 : 0) + 16;
        expect(search.left, closeTo(left, .1));
        expect(hero.left, closeTo(left, .1));
        if (size.width > size.height && width >= 600) {
          expect(tabs.center.dy, closeTo(search.center.dy, .1));
          expect(switches.left, greaterThan(hero.right));
          expect(switches.top, closeTo(hero.top, .1));
          expect(queue.left, closeTo(hero.left, .1));
          expect(queue.right, closeTo(hero.right, .1));
          expect(queue.top, closeTo(hero.bottom + 16, .1));
        } else {
          expect(tabs.top, greaterThanOrEqualTo(search.bottom));
          expect(switches.left, closeTo(hero.left, .1));
          expect(switches.right, closeTo(hero.right, .1));
          expect(switches.top, greaterThan(hero.bottom));
          expect(queue.top, greaterThan(switches.bottom));
        }
        final modes = [
          for (final value in ['normal', 'small', 'peak', 'radio'])
            tester.getRect(find.byKey(ValueKey('fm-mode-$value'))),
        ];
        final pools = [
          for (final value in [0, 1, 2])
            tester.getRect(find.byKey(ValueKey('fm-pool-$value'))),
        ];
        for (final row in [modes, pools]) {
          expect(row.first.left, closeTo(switches.left + 16, .1));
          expect(row.last.right, closeTo(switches.right - 16, .1));
          for (final tile in row) {
            expect(tile.width, closeTo(row.first.width, .1));
            expect(tile.height, greaterThanOrEqualTo(48));
            expect(tile.left, greaterThanOrEqualTo(switches.left + 15.9));
            expect(tile.right, lessThanOrEqualTo(switches.right - 15.9));
          }
        }
        expect(pools.first.left, closeTo(modes.first.left, .1));
      }
      await screenshot('fm');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
