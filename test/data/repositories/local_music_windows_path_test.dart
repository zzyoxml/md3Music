import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/audio_scanner.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';

void main() {
  group('Windows 本地文件夹归组', () {
    test('反斜杠路径归入文件夹', () {
      const song = Song(
        id: 'local_windows',
        title: '本地歌曲',
        artist: '歌手',
        album: '专辑',
        duration: Duration(seconds: 10),
        localPath: r'C:\Music\album\track.mp3',
      );

      final folders = LocalMusicRepository().buildFolders([song]);
      expect(folders.single.path, 'C:/Music/album');
      expect(folders.single.name, 'album');
      expect(folders.single.songIds, ['local_windows']);
    });

    test('盘符根目录的文件夹名退化为盘符而非空', () {
      const song = Song(
        id: 'local_root',
        title: '根目录歌曲',
        artist: '歌手',
        album: '专辑',
        duration: Duration(seconds: 10),
        localPath: r'D:\a.mp3',
      );

      final folders = LocalMusicRepository().buildFolders([song]);
      expect(folders.single.name, 'D:');
    });
  });

  group('平台默认扫描目录', () {
    test('桌面端默认目录不混入 Android 专属路径', () {
      final dirs = defaultScanDirsForPlatform;
      // Android 路径（/storage/emulated/0/...）在桌面端一律不存在，
      // 若仍作默认目录，用户不手动加目录就只能看到空的本地音乐。
      expect(
        dirs.any((d) => d.startsWith('/storage/emulated/0')),
        isFalse,
        reason: '默认扫描目录不应混入 Android 专属路径',
      );
    });

    test('默认目录非空', () {
      expect(defaultScanDirsForPlatform, isNotEmpty);
    });
  });

  test('音频扩展名覆盖 Windows 常见格式', () {
    expect(audioExtensions, containsAll(<String>['.mp3', '.flac', '.wav']));
  });
}