import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/services/remote/remote_storage_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 纯 Dart 测试环境无原生通道，需启用包内置的内存测试实现，
    // 否则 read/write/deleteAll 报 MissingPluginException。
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    await storage.deleteAll();
    RemoteStorageRepository.clearCache();
  });

  const cfg = RemoteStorageConfig(
    id: 'cfg1',
    name: 'NAS',
    type: RemoteStorageType.webdav,
    host: 'h',
    username: 'user',
    password: 'secret123',
  );

  test('保存后密码单独加密存储，元数据不含密码', () async {
    final repo = RemoteStorageRepository();
    await repo.saveConfig(cfg);

    // 密码在 secure storage，不在 prefs
    const storage = FlutterSecureStorage();
    final storedPwd = await storage.read(key: 'remote_storage_pwd_cfg1');
    expect(storedPwd, 'secret123');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('remote_storage_configs');
    expect(raw, isNotNull);
    expect(raw!.contains('secret123'), isFalse);
  });

  test('读取配置时回填密码', () async {
    final repo = RemoteStorageRepository();
    await repo.saveConfig(cfg);

    final list = await repo.getConfigs();
    expect(list, hasLength(1));
    expect(list.first.password, 'secret123');
  });

  test('删除配置同时清除密码', () async {
    final repo = RemoteStorageRepository();
    await repo.saveConfig(cfg);
    await repo.deleteConfig('cfg1');

    expect(await repo.getConfigs(), isEmpty);
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'remote_storage_pwd_cfg1'), isNull);
  });

  test('peekConfig 同步缓存命中（播放器取鉴权头用）', () async {
    final repo = RemoteStorageRepository();
    await repo.saveConfig(cfg);
    // 保存后应刷新进程内缓存
    final peeked = RemoteStorageRepository.peekConfig('cfg1');
    expect(peeked, isNotNull);
    expect(peeked!.host, 'h');
    expect(peeked.password, 'secret123');
  });
}