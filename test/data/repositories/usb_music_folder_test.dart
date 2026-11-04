import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/folder_picker_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.md3music.md3music/folder_picker');
  const tree = 'content://com.android.externalstorage.documents/tree/ABCD-1234%3AMusic';
  const document = '$tree/document/ABCD-1234%3AMusic%2Fsong.mp3';

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('U 盘目录保留 SAF URI 而不是猜测 /storage 路径', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pickFolder') return tree;
      if (call.method == 'queryTreeAudioFiles') {
        expect(call.arguments, {'uri': tree});
        return [
          {'filePath': document, 'folderPath': tree, 'displayName': 'song.mp3'}
        ];
      }
      return null;
    });

    final provider = LibraryProvider();
    expect(await provider.addScanFolder(), isTrue);
    expect(provider.scanFolders, [tree]);
    expect(await LocalMusicRepository().getSavedFolders(), [tree]);
    expect(FolderPickerService.displayName(tree), 'Music');
    final rows = await FolderPickerService.queryTreeAudioFiles(tree);
    expect(rows.single['filePath'], document);
  });

  test('SAF 歌曲缓存及文件夹归属保留，排除目录生效', () {
    final song = Song(
      id: 'local_$document',
      title: 'song',
      artist: '未知艺术家',
      album: '未知专辑',
      duration: const Duration(minutes: 3),
      localPath: document,
      folderPath: tree,
    );
    final restored = Song.fromJson(song.toJson());
    expect(restored.folderPath, tree);
    final repository = LocalMusicRepository();
    expect(repository.buildFolders([restored]).single.displayName, 'Music');
    expect(repository.filterSongs([restored], excludedFolders: [tree]), isEmpty);
  });
}
