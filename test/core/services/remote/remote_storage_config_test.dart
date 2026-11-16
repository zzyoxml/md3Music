import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';

void main() {
  group('SongRemoteType', () {
    test('fromJson 映射字符串', () {
      expect(SongRemoteType.fromJson('webdav'), SongRemoteType.webdav);
      expect(SongRemoteType.fromJson('ftp'), SongRemoteType.ftp);
      expect(SongRemoteType.fromJson(null), SongRemoteType.none);
      expect(SongRemoteType.fromJson('unknown'), SongRemoteType.none);
    });
    test('toJson 序列化为字符串', () {
      expect(SongRemoteType.webdav.toJson(), 'webdav');
      expect(SongRemoteType.none.toJson(), null);
    });
  });

  group('RemoteStorageConfig', () {
    const cfg = RemoteStorageConfig(
      id: 'cfg1',
      name: '我的NAS',
      type: RemoteStorageType.webdav,
      host: '192.168.1.10',
      port: 5005,
      useTls: false,
      username: 'user',
      rootPath: '/music',
    );

    test('round-trip JSON 序列化（不含密码）', () {
      final json = cfg.toJson();
      expect(json.containsKey('password'), isFalse);
      final restored = RemoteStorageConfig.fromJson(json);
      expect(restored.id, 'cfg1');
      expect(restored.name, '我的NAS');
      expect(restored.type, RemoteStorageType.webdav);
      expect(restored.port, 5005);
      expect(restored.rootPath, '/music');
    });

    test('默认端口：webdav http=80 / https=443 / ftp=21', () {
      // port 字段缺省为 0，默认端口由 effectivePort 推导（见 RemoteStorageConfig）。
      const w = RemoteStorageConfig(
          id: 'w', name: 'w', type: RemoteStorageType.webdav, host: 'h');
      expect(w.effectivePort, 80);
      const ws = RemoteStorageConfig(
          id: 'ws',
          name: 'ws',
          type: RemoteStorageType.webdav,
          host: 'h',
          useTls: true);
      expect(ws.effectivePort, 443);
      const f = RemoteStorageConfig(
          id: 'f', name: 'f', type: RemoteStorageType.ftp, host: 'h');
      expect(f.effectivePort, 21);
    });

    test('baseUrl 拼接正确', () {
      expect(cfg.baseUrl, 'http://192.168.1.10:5005');
    });
  });
}