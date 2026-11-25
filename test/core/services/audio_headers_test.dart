import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_service_io.dart';
import 'package:md3music/core/services/remote/playback_headers.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/services/remote/remote_storage_repository.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';

/// 构造测试用歌曲（仅填必要字段）。
Song _song({
  String id = 's',
  String? url,
  String? localPath,
  bool isOnline = false,
  SongRemoteType remoteType = SongRemoteType.none,
  String? remoteSourceId,
}) => Song(
  id: id,
  title: 't',
  artist: 'a',
  album: 'b',
  duration: Duration.zero,
  url: url,
  localPath: localPath,
  isOnline: isOnline,
  remoteType: remoteType,
  remoteSourceId: remoteSourceId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 保证进程内配置缓存为空，命中「未配置」分支
    RemoteStorageRepository.clearCache();
  });

  group('createAudioSource 透传 headers', () {
    test('headers 正确透传到 source.headers', () {
      final source = createAudioSource(
        id: 'x',
        url: 'http://127.0.0.1:5005/music/a.mp3',
        title: 'a',
        headers: const {'Authorization': 'Basic xxx'},
      );
      expect(source.headers, {'Authorization': 'Basic xxx'});
    });

    test('未传 headers 时为 null', () {
      final source = createAudioSource(
        id: 'x',
        url: 'http://127.0.0.1:5005/music/a.mp3',
        title: 'a',
      );
      expect(source.headers, isNull);
    });
  });

  group('buildPlaybackHeaders', () {
    test('非 WebDAV（none / ftp）返回 null', () {
      expect(
        buildPlaybackHeaders(
          remoteType: SongRemoteType.none,
          remoteSourceId: 'cfg1',
        ),
        isNull,
      );
      expect(
        buildPlaybackHeaders(
          remoteType: SongRemoteType.ftp,
          remoteSourceId: 'cfg1',
        ),
        isNull,
      );
    });

    test('WebDAV 但配置缓存未命中返回 null', () {
      expect(
        buildPlaybackHeaders(
          remoteType: SongRemoteType.webdav,
          remoteSourceId: null,
        ),
        isNull,
      );
      expect(
        buildPlaybackHeaders(
          remoteType: SongRemoteType.webdav,
          remoteSourceId: 'missing',
        ),
        isNull,
      );
    });
  });

  group('resolvePlaybackUrlForSource（缺陷 A 回归：WebDAV 不得取空 localPath）', () {
    test('WebDAV 歌曲返回 song.url，而非为 null 的 localPath', () {
      final song = _song(
        url: 'http://192.168.1.10:5005/music/a.mp3',
        remoteType: SongRemoteType.webdav,
        remoteSourceId: 'cfg1',
      );
      final resolved = resolvePlaybackUrlForSource(song);
      expect(resolved, song.url);
      expect(resolved, isNotEmpty);
    });

    test('FTP 已下载（localPath 已回写）优先本地路径，未下载回退 url', () {
      final downloaded = _song(
        url: 'ftp://h:21/music/a.mp3',
        localPath: 'file:///tmp/a.mp3',
        remoteType: SongRemoteType.ftp,
      );
      expect(resolvePlaybackUrlForSource(downloaded), 'file:///tmp/a.mp3');

      final notYet = _song(
        url: 'ftp://h:21/music/a.mp3',
        remoteType: SongRemoteType.ftp,
      );
      expect(resolvePlaybackUrlForSource(notYet), 'ftp://h:21/music/a.mp3');
    });

    test('在线歌曲返回 url；本地歌曲返回 localPath', () {
      final online = _song(url: 'http://cdn/a.mp3', isOnline: true);
      expect(resolvePlaybackUrlForSource(online), 'http://cdn/a.mp3');

      final local = _song(url: 'content://x', localPath: '/storage/a.mp3');
      expect(resolvePlaybackUrlForSource(local), '/storage/a.mp3');
    });
  });
}