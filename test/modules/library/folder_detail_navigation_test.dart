import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/modules/library/folders_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';

class _Player extends ChangeNotifier implements PlayerProvider {
  @override
  Song? get currentSong => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String id, String path, {String? folder}) => Song(
  id: id,
  title: id,
  artist: '歌手',
  album: '专辑',
  duration: const Duration(minutes: 3),
  localPath: path,
  folderPath: folder,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('文件夹分组和详情使用相同目录：Windows、UNC、Android、SAF', () async {
    const tree = 'content://external/tree/ABCD%3AMusic';
    final songs = [
      _song('windows', r'C:\Music\media\a.mp3'),
      _song('windows-slash', 'C:/Music/media/b.mp3'),
      _song('unc', r'\\server\share\media\c.mp3'),
      _song('android', '/storage/emulated/0/Music/d.mp3'),
      _song('saf', '$tree/document/song', folder: tree),
    ];
    await LocalMusicRepository().saveSongs(songs);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await library.loadSavedSongs();
    for (final folder in library.folders) {
      expect(
        library.getSongsInFolder(folder.path).map((s) => s.id),
        unorderedEquals(folder.songIds),
        reason: folder.path,
      );
    }
    expect(library.getSongsInFolder('C:/Missing'), isEmpty);
    expect(library.allSongs.map((s) => s.localPath), songs.map((s) => s.localPath));
  });

  testWidgets('Windows 文件夹详情显示歌曲和左上角返回，点击回到文件夹列表', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final oldDesktop = kDesktopModeEnabled.value;
    kDesktopModeEnabled.value = true;
    addTearDown(() => kDesktopModeEnabled.value = oldDesktop);
    await LocalMusicRepository().saveSongs([
      _song('文件夹测试歌曲', r'C:\Music\media\a.mp3'),
    ]);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await library.loadSavedSongs();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ChangeNotifierProvider<PlayerProvider>(create: (_) => _Player()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider(syncOnStart: false)),
      ],
      child: MaterialApp(home: Scaffold(body: FoldersPage(folders: library.folders))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('media'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('文件夹测试歌曲'), findsOneWidget);
    final back = find.byType(BackButton);
    expect(back, findsOneWidget);
    expect(tester.getCenter(back).dx, lessThan(80));
    expect(tester.getCenter(back).dy, lessThan(80));
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byType(FolderSongsPage), findsNothing);
    expect(find.text('1 个文件夹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
