import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/services/external_media_intent_service.dart';

void main() {
  group('normalizeToFsPath', () {
    test('file:// URI 转为文件系统路径', () {
      expect(
        normalizeToFsPath('file:///storage/emulated/0/Music/a.mp3'),
        '/storage/emulated/0/Music/a.mp3',
      );
    });

    test('裸路径原样返回', () {
      expect(normalizeToFsPath('/sdcard/a.flac'), '/sdcard/a.flac');
    });
  });

  group('externalSongId', () {
    test('同一文件路径生成稳定一致的 id', () {
      const p =
          '/data/user/0/com.md3music.md3music/files/local_music_cache/123.mp3';
      expect(externalSongId(p), externalSongId(p));
      expect(externalSongId(p), startsWith('external_'));
    });

    test('不同路径生成不同 id', () {
      expect(externalSongId('/a/1.mp3'), isNot(externalSongId('/a/2.mp3')));
    });
  });

  group('titleFromFileName', () {
    test('剥离扩展名', () {
      expect(titleFromFileName('晴天 - 周杰伦.mp3'), '晴天 - 周杰伦');
    });

    test('无扩展名时原样返回', () {
      expect(titleFromFileName('demo'), 'demo');
    });
  });

  group('ExternalMediaIntentService.buildSong', () {
    final service = ExternalMediaIntentService.instance;

    test('完整元数据构建 Song', () {
      const req = ExternalMediaRequest(
        uri: 'content://media/external/audio/media/1',
        path: '/tmp/晴天.mp3',
      );
      final song = service.buildSong(req, const {
        'title': '晴天',
        'artist': '周杰伦',
        'album': '叶惠美',
        'durationMs': 269000,
      });
      expect(song.title, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.album, '叶惠美');
      expect(song.duration, const Duration(milliseconds: 269000));
      expect(song.isOnline, isFalse);
      expect(song.localPath, '/tmp/晴天.mp3');
      expect(song.id, startsWith('external_'));
      expect(song.artworkUri, 'local:///tmp/晴天.mp3',
          reason: '本地内嵌封面应标识为 local://<路径>，供 UI 层加载内嵌封面');
    });

    test('元数据缺失时回退文件名标题与未知艺术家/专辑', () {
      const req = ExternalMediaRequest(uri: '', path: '/sdcard/Music/demo.flac');
      final song = service.buildSong(req, const {});
      expect(song.title, 'demo');
      expect(song.artist, '未知艺术家');
      expect(song.album, '未知专辑');
      expect(song.duration, Duration.zero);
      expect(song.artworkUri, 'local:///sdcard/Music/demo.flac');
    });
  });

  group('ExternalMediaIntentService.isPathReadable', () {
    test('不存在的路径返回 false', () {
      expect(
        ExternalMediaIntentService.instance
            .isPathReadable('/nonexistent_dir_md3music/x.mp3'),
        isFalse,
      );
    });
  });
}
