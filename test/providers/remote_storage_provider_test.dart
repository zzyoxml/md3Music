import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/services/remote/remote_storage_repository.dart';
import 'package:md3music/core/services/remote/webdav_client.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/remote_storage_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 构造一个最小远程歌曲（仅关注 id / remoteSourceId 用于汇聚与删除断言）。
Song _song(String id, String sourceId) => Song(
      id: id,
      title: id,
      artist: '未知艺术家',
      album: '未知艺术家',
      duration: Duration.zero,
      remoteType: SongRemoteType.webdav,
      remoteSourceId: sourceId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 纯 Dart 测试无原生通道：prefs / secure storage 均需内存 mock。
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    RemoteStorageRepository.clearCache();
  });

  const cfgA = RemoteStorageConfig(
    id: 'a',
    name: 'A',
    type: RemoteStorageType.webdav,
    host: 'h',
  );

  test('初始态：configs 为空、isScanning 为 false', () {
    final p = RemoteStorageProvider();
    expect(p.configs, isEmpty);
    expect(p.remoteSongs, isEmpty);
    expect(p.isScanning, isFalse);
    expect(p.scanError, isNull);
  });

  test('setConfigs 后 configs / configById 正确', () {
    final p = RemoteStorageProvider();
    p.setConfigs([cfgA]);
    expect(p.configs, hasLength(1));
    expect(p.configById('a')?.name, 'A');
    expect(p.configById('missing'), isNull);
    expect(p.configById(null), isNull);
  });

  test('setRemoteSongs 后 remoteSongs 正确', () {
    final p = RemoteStorageProvider();
    final song = _song('s1', 'a');
    p.setRemoteSongs([song]);
    expect(p.remoteSongs, [song]);
  });

  test('scanAll 用注入的假会话产出 remoteSongs', () async {
    final p = RemoteStorageProvider();
    p.setConfigs([cfgA]);
    // 注入假会话：/music 下有一个音频文件与一个非音频文件。
    // WebDAVClient / FtpClient 被完全绕过，无需真实网络。
    p.sessionFactory = (config) => RemoteScanSession(
          listDir: (path) async => [
            const WebDavEntry(
              path: '/music/song.mp3',
              name: 'song.mp3',
              isDirectory: false,
              size: 10,
            ),
            const WebDavEntry(
              path: '/music/readme.txt',
              name: 'readme.txt',
              isDirectory: false,
              size: 5,
            ),
          ],
          dispose: () async {},
        );

    await p.scanAll();

    expect(p.isScanning, isFalse);
    expect(p.scanError, isNull);
    expect(p.remoteSongs, hasLength(1));
    expect(p.remoteSongs.first.title, 'song');
    expect(p.remoteSongs.first.remoteSourceId, 'a');
    expect(p.remoteSongs.first.remoteType, SongRemoteType.webdav);
  });

  test('单条配置扫描失败不中断整体', () async {
    final p = RemoteStorageProvider();
    p.setConfigs([
      cfgA,
      const RemoteStorageConfig(
        id: 'b',
        name: 'B',
        type: RemoteStorageType.webdav,
        host: 'h2',
      ),
    ]);
    p.sessionFactory = (config) {
      if (config.id == 'a') {
        return RemoteScanSession(
          listDir: (path) async => throw StateError('boom'),
          dispose: () async {},
        );
      }
      return RemoteScanSession(
        listDir: (path) async => [
          const WebDavEntry(
            path: '/music/b.mp3',
            name: 'b.mp3',
            isDirectory: false,
            size: 1,
          ),
        ],
        dispose: () async {},
      );
    };

    await p.scanAll();

    expect(p.scanError, contains('A'));
    expect(p.remoteSongs, hasLength(1));
    expect(p.remoteSongs.first.remoteSourceId, 'b');
  });

  test('deleteConfig 移除对应 remoteSourceId 的歌曲并持久化', () async {
    final p = RemoteStorageProvider();
    await p.saveConfig(cfgA);
    await p.saveConfig(const RemoteStorageConfig(
      id: 'b',
      name: 'B',
      type: RemoteStorageType.ftp,
      host: 'h2',
    ));
    p.setRemoteSongs([_song('s1', 'a'), _song('s2', 'b')]);

    await p.deleteConfig('a');

    expect(p.configs.map((c) => c.id), isNot(contains('a')));
    expect(p.remoteSongs, hasLength(1));
    expect(p.remoteSongs.first.remoteSourceId, 'b');

    // 持久化：已删除配置的歌曲不应再写入 prefs
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(RemoteStorageProvider.remoteSongsKey);
    expect(raw, isNotNull);
    expect(raw!.contains('s1'), isFalse);
    expect(raw.contains('s2'), isTrue);
  });
}