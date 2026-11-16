import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/library_provider.dart';

Song audio(String path, int milliseconds) => Song(
  id: path,
  title: path,
  artist: path,
  album: path,
  duration: Duration(milliseconds: milliseconds),
  localPath: path,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('时长过滤默认关闭，严格过滤60秒，重启保留并可恢复原始索引', () async {
    final repository = LocalMusicRepository();
    await repository.saveSongs([
      audio('/Music/unknown.mp3', 0),
      audio('/Music/short.mp3', 59000),
      audio('/Music/exact.mp3', 60000),
      audio('/Music/over.mp3', 60001),
      audio('/Other/long.mp3', 61000),
    ]);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await library.loadSavedSongs();
    expect(library.filterShortAudio, isFalse);
    expect(library.allSongs, hasLength(5));

    await library.setFilterShortAudio(true);
    expect(library.allSongs.map((s) => s.duration.inMilliseconds), [
      60001,
      61000,
    ]);
    expect(library.albums, hasLength(2));
    expect(library.artists, hasLength(2));
    expect(library.folders, hasLength(2));
    expect(library.searchLocal('exact'), isEmpty);
    expect(await repository.getSavedSongs(), hasLength(5));

    final restored = LibraryProvider();
    addTearDown(restored.dispose);
    await restored.loadSavedSongs();
    expect(restored.filterShortAudio, isTrue);
    expect(restored.allSongs, hasLength(2));
    await restored.setFilterShortAudio(false);
    expect(restored.allSongs, hasLength(5));
    expect(restored.albums, hasLength(5));
  });

  test('多选仅移除索引和子目录，保留文件及相似目录，重启不回流', () async {
    final directory = await Directory('tmp').createTemp('local-index-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/preserved.mp3',
    ).writeAsBytes([1, 2, 3]);
    final path = directory.absolute.path.replaceAll('\\', '/');
    final repository = LocalMusicRepository();
    await repository.saveFolders([path, '/Music', '/Keep']);
    await repository.saveSongs([
      audio(file.absolute.path.replaceAll('\\', '/'), 120000),
      audio('/Music/a.mp3', 120000),
      audio('/Music/Child/b.mp3', 120000),
      audio('/Music2/c.mp3', 120000),
      audio('/Keep/short.mp3', 10000),
    ]);
    final library = LibraryProvider();
    addTearDown(library.dispose);
    await library.loadSavedSongs();
    await library.setFilterShortAudio(true);
    await library.removeFoldersFromIndex([path, '/Music']);
    expect(library.allSongs.map((s) => s.localPath), ['/Music2/c.mp3']);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(await repository.getSavedFolders(), ['/Keep']);
    expect(
      await repository.getExcludedFolders(),
      containsAll([path, '/Music']),
    );
    expect(await repository.getSavedSongs(), hasLength(2));

    final restored = LibraryProvider();
    addTearDown(restored.dispose);
    await restored.loadSavedSongs();
    await restored.setFilterShortAudio(false);
    expect(restored.allSongs.map((s) => s.localPath), [
      '/Music2/c.mp3',
      '/Keep/short.mp3',
    ]);
    expect(restored.folders, hasLength(2));
    await repository.addFolder('/Music');
    expect(await repository.getExcludedFolders(), isNot(contains('/Music')));
    expect(await repository.getSavedFolders(), contains('/Music'));
  });

  test('排除按目录边界匹配，兼容反斜杠和尾部斜杠', () {
    final songs = [
      audio('D:\\Music\\a.mp3', 120000),
      audio('D:/Music2/a.mp3', 120000),
    ];
    expect(
      LocalMusicRepository()
          .filterSongs(songs, excludedFolders: ['D:/Music/'])
          .map((s) => s.localPath),
      ['D:/Music2/a.mp3'],
    );
  });
}
