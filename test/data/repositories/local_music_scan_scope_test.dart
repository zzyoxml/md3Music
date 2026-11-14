import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/library_provider.dart';

const _tree = 'content://com.android.externalstorage.documents/tree/primary%3AMusic';

Song _song(String path) => Song(
  id: path, title: path, artist: '歌手', album: '专辑',
  duration: const Duration(minutes: 3), localPath: path, isOnline: false,
);

class _ScanRepository extends LocalMusicRepository {
  int scans = 0;
  bool? selectedOnly;
  List<String>? folders;
  @override
  Future<List<Song>> scanSongs({List<String>? customFolders,
    List<String>? excludedFolders, bool scanOnlySelectedFolders = false}) async {
    scans++;
    selectedOnly = scanOnlySelectedFolders;
    folders = customFolders;
    return [_song('/storage/emulated/0/Music/song.mp3')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('com.md3music.md3music/folder_picker');
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(picker, null));

  test('默认关闭，开启后新实例可恢复，不改变已选目录', () async {
    final repo = LocalMusicRepository();
    expect(await repo.getScanOnlySelectedFolders(), isFalse);
    await repo.saveFolders([_tree]);
    await repo.setScanOnlySelectedFolders(true);
    expect(await LocalMusicRepository().getScanOnlySelectedFolders(), isTrue);
    expect(await repo.getSavedFolders(), [_tree]);
    await repo.setScanOnlySelectedFolders(false);
    expect(await LocalMusicRepository().getScanOnlySelectedFolders(), isFalse);
  });

  test('仅指定目录但未选目录时为空，不回退默认扫描', () async {
    expect(await LocalMusicRepository().scanSongs(scanOnlySelectedFolders: true), isEmpty);
  });

  test('仅指定 SAF 目录返回所选子目录，并保留排除规则', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
      calls.add(call);
      return [
        {'filePath': 'content://audio/1', 'folderPath': '/storage/emulated/0/Music/Albums',
          'displayName': 'song.mp3', 'title': '音乐'},
        {'filePath': 'content://audio/2', 'folderPath': '/storage/emulated/0/Music/Recordings',
          'displayName': 'call.mp3', 'title': '录音'},
      ];
    });
    final songs = await LocalMusicRepository().scanSongs(
      customFolders: [_tree], scanOnlySelectedFolders: true,
      excludedFolders: ['/storage/emulated/0/Music/Recordings'],
    );
    expect(songs.map((s) => s.title), ['音乐']);
    expect(calls.map((c) => c.method), ['queryTreeAudioFiles']);
    expect(calls.single.arguments, {'uri': _tree});
  });

  test('缓存范围匹配目录边界，支持 SAF 与真实路径互认', () {
    final repo = LocalMusicRepository();
    final songs = [_song('/storage/emulated/0/Music/A/song.mp3'),
      _song('/storage/emulated/0/MusicBackup/call.mp3'),
      _song('/storage/emulated/0/Recordings/call.mp3')];
    expect(repo.filterSongs(songs, includedFolders: [_tree]), [songs.first]);
    expect(repo.filterSongs(songs, includedFolders: []), isEmpty);
    expect(repo.filterSongs(songs), songs);
    expect(repo.filterSongs(songs, includedFolders: [_tree],
      excludedFolders: ['/storage/emulated/0/Music/A']), isEmpty);
    expect(repo.filterSongs([_song(r'D:\Music\A\song.mp3'),
      _song(r'D:\MusicBackup\song.mp3')], includedFolders: [r'D:\Music']).length, 1);
  });

  test('开关立即约束缓存，关闭可恢复旧索引，重启保持扫描范围', () async {
    final repo = LocalMusicRepository();
    final music = _song('/storage/emulated/0/Music/song.mp3');
    final call = _song('/storage/emulated/0/Recordings/call.mp3');
    await repo.saveSongs([music, call]);
    await repo.saveFolders([_tree]);
    final provider = LibraryProvider(repository: repo);
    addTearDown(provider.dispose);
    await provider.loadSavedSongs();
    expect(provider.songs.length, 2);
    await provider.setScanOnlySelectedFolders(true);
    expect(provider.songs.map((s) => s.id), [music.id]);
    final restored = LibraryProvider(repository: LocalMusicRepository());
    addTearDown(restored.dispose);
    await restored.loadSavedSongs();
    expect(restored.scanOnlySelectedFolders, isTrue);
    expect(restored.songs.map((s) => s.id), [music.id]);
    await provider.setScanOnlySelectedFolders(false);
    expect(provider.songs.length, 2);
    expect((await repo.getSavedSongs()).length, 2);
  });

  test('未选目录时提示，不调用扫描器且退出扫描状态', () async {
    final repo = _ScanRepository();
    await repo.setScanOnlySelectedFolders(true);
    final provider = LibraryProvider(repository: repo);
    addTearDown(provider.dispose);
    await provider.loadLocalMusic();
    expect(repo.scans, 0);
    expect(provider.error, '请先添加要扫描的文件夹');
    expect(provider.isScanning, isFalse);
  });

  test('扫描传递指定范围，SAF 无需申请全盘媒体权限，移除目录立即隐藏缓存', () async {
    final repo = _ScanRepository();
    await repo.saveFolders([_tree]);
    await repo.setScanOnlySelectedFolders(true);
    final provider = LibraryProvider(repository: repo);
    addTearDown(provider.dispose);
    await provider.loadLocalMusic();
    expect(repo.scans, 1);
    expect(repo.selectedOnly, isTrue);
    expect(repo.folders, [_tree]);
    expect(provider.songs.length, 1);
    await provider.removeScanFolder(_tree);
    expect(provider.songs, isEmpty);
  });
}
