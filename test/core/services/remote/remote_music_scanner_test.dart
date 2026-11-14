import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_music_scanner.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/services/remote/webdav_client.dart';

void main() {
  const cfg = RemoteStorageConfig(
    id: 'cfg1',
    name: 'NAS',
    type: RemoteStorageType.webdav,
    host: 'h',
    username: 'u',
    password: 'p',
    rootPath: '/music',
  );

  test('递归扫描生成 Song（id/url/封面/remoteType/remoteSourceId/isOnline）', () async {
    final scanner = RemoteMusicScanner(
      listDir: (path) async {
        if (path == '/music') {
          return [
            _dir('/music/album1'),
            _file('/music/song.mp3', 1000),
            _file('/music/cover.jpg', 500),
          ];
        }
        return [_file('/music/album1/track.flac', 2000)];
      },
    );
    final songs = await scanner.scan(config: cfg);

    expect(songs, hasLength(2));

    final song = songs.firstWhere((s) => s.title == 'song');
    expect(song.id, startsWith('remote_webdav_cfg1_'));
    expect(song.url, 'http://h:80/music/song.mp3');
    expect(song.remoteType, SongRemoteType.webdav);
    expect(song.remoteSourceId, 'cfg1');
    expect(song.isOnline, isFalse);
    expect(song.artist, '未知艺术家');
    expect(song.quality, isNull); // mp3 不标注质量
    // 同目录 cover.jpg 作为封面
    expect(song.artworkUri, 'http://h:80/music/cover.jpg');

    final flac = songs.firstWhere((s) => s.title == 'track');
    expect(flac.artworkUri, isNull); // album1 目录无封面文件
    expect(flac.quality, 'flac'); // 无损格式标注
  });

  test('音频扩展名白名单过滤', () async {
    final scanner = RemoteMusicScanner(
      listDir: (path) async => [
        _file('/music/song.mp3', 1),
        _file('/music/readme.txt', 1),
        _file('/music/audio.m4a', 1),
      ],
    );
    final songs = await scanner.scan(config: cfg);

    expect(songs.map((s) => s.title), containsAll(['song', 'audio']));
    expect(songs.map((s) => s.title), isNot(contains('readme')));
  });

  test('封面同名优先于 cover/folder/album', () async {
    final scanner = RemoteMusicScanner(
      listDir: (path) async => [
        _file('/music/song.mp3', 1),
        _file('/music/cover.jpg', 1),
        _file('/music/song.png', 1),
      ],
    );
    final songs = await scanner.scan(config: cfg);

    final song = songs.single;
    expect(song.title, 'song');
    expect(song.artworkUri, 'http://h:80/music/song.png');
  });
}

WebDavEntry _dir(String path) =>
    WebDavEntry(path: path, name: path.split('/').last, isDirectory: true);

WebDavEntry _file(String path, int size) => WebDavEntry(
      path: path,
      name: path.split('/').last,
      isDirectory: false,
      size: size,
    );