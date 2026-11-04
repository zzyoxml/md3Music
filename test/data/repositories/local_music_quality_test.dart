import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/utils/audio_scanner.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song song(
  String path, {
  String? quality,
  bool online = false,
  SongRemoteType remote = SongRemoteType.none,
}) => Song(
  id: 'local_$path',
  title: path,
  artist: '歌手',
  album: '专辑',
  duration: const Duration(minutes: 3),
  localPath: path,
  quality: quality,
  isOnline: online,
  remoteType: remote,
  isLocallyFavorited: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final bitrate in [64000, 96000, 128000]) {
    test('MP3 $bitrate bps 是标准而非无损', () {
      expect(LocalMusicRepository.inferQuality(bitrate, 'a.mp3'), '128');
    });
  }
  for (final bitrate in [128001, 192000, 256000, 320000, 512000]) {
    test('有损编码 $bitrate bps 不能因高码率标为无损', () {
      for (final ext in ['mp3', 'aac', 'm4a', 'ogg', 'opus', 'wma']) {
        expect(LocalMusicRepository.inferQuality(bitrate, 'a.$ext'), '320');
      }
    });
  }
  for (final ext in ['flac', 'FLAC', 'ape', 'wav', 'aif', 'aiff']) {
    test('$ext 格式无码率时仍可识别', () {
      expect(LocalMusicRepository.inferQuality(null, 'a.$ext'), 'flac');
    });
  }
  test('缺失或非法码率不猜测音质', () {
    for (final bitrate in [null, 0, -1]) {
      expect(LocalMusicRepository.inferQuality(bitrate, 'a.mp3'), isNull);
      expect(LocalMusicRepository.inferQuality(bitrate, null), isNull);
    }
  });

  test('真实扫描入口读取合成 MP3 帧，码率单位为 bps', () {
    final root = Directory('tmp/local-audio-quality/fixtures')
      ..createSync(recursive: true);
    final dir = root.createTempSync('mp3-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // MPEG1 Layer III，128kbps / 44.1kHz；仅用合成帧验证元数据，不含音乐内容。
    final file = File('${dir.path}/standard.mp3');
    final frame = List<int>.filled(417, 0);
    frame.setRange(0, 4, [0xff, 0xfb, 0x90, 0x00]);
    file.writeAsBytesSync(
      List.generate(40, (_) => frame).expand((e) => e).toList(),
    );
    final metadata = scanAudioFilesInIsolate([file.path]).single;
    expect(metadata['bitrate'], 128000);
    expect(
      LocalMusicRepository.inferQuality(metadata['bitrate'] as int?, file.path),
      '128',
    );
  });

  group('旧本地索引迁移', () {
    test('撤销错误标签但保留歌曲、收藏和目录；无损格式保留标签', () async {
      final old = [
        song('a.mp3', quality: 'flac'),
        song('b.m4a', quality: 'flac'),
        song('c.FLAC', quality: 'flac'),
        song('d.mp3', quality: '320'),
      ];
      SharedPreferences.setMockInitialValues({
        'local_music_cached_songs': jsonEncode(
          old.map((s) => s.toJson()).toList(),
        ),
        'local_music_scan_folders': ['Music'],
        'local_music_cached_at': 123,
      });
      final repo = LocalMusicRepository();
      final restored = await repo.getSavedSongs();
      expect(restored.map((s) => s.quality), [null, null, 'flac', null]);
      expect(restored.map((s) => s.id), old.map((s) => s.id));
      expect(restored.every((s) => s.isLocallyFavorited), isTrue);
      expect(await repo.getSavedFolders(), ['Music']);
      expect(await repo.getCachedAt(), 123);
      // 再保存/重启也不能把已清理的标签变回无损。
      await repo.saveSongs(restored);
      expect(
        (await LocalMusicRepository().getSavedSongs()).map((s) => s.quality),
        [null, null, 'flac', null],
      );
    });
    test('在线和远程歌曲不套用本地旧索引修正规则', () async {
      final songs = [
        song('a.mp3', quality: 'high', online: true),
        song('b.m4a', quality: 'flac', remote: SongRemoteType.webdav),
      ];
      SharedPreferences.setMockInitialValues({
        'local_music_cached_songs': jsonEncode(
          songs.map((s) => s.toJson()).toList(),
        ),
      });
      expect(
        (await LocalMusicRepository().getSavedSongs()).map((s) => s.quality),
        ['high', 'flac'],
      );
    });
    test('新扫描索引的真实档位在重启后不丢失', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = LocalMusicRepository();
      await repo.saveSongs([
        song('a.mp3', quality: '128'),
        song('b.mp3', quality: '320'),
        song('c.flac', quality: 'flac'),
        song('d.aac'),
      ]);
      expect(
        (await LocalMusicRepository().getSavedSongs()).map((s) => s.quality),
        ['128', '320', 'flac', null],
      );
    });
  });
}
