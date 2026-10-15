import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpSettings', () {
    test('空存储时回落默认且自动生成 token', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 令牌已迁移到 secure storage，测试需注入 mock 平台实现
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = McpSettingsStore();
      final first = await store.load();
      expect(first.enabled, isFalse);
      expect(first.port, 17888);
      expect(first.bindLan, isFalse);
      expect(first.readOnly, isFalse);
      expect(first.token.length, greaterThan(20));

      // token 必须持久化，不能每次读取都变
      expect((await store.load()).token, first.token);
    });

    test('保存后可原样读回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = McpSettingsStore();
      final base = await store.load();
      await store.save(base.copyWith(enabled: true, port: 18000, bindLan: true, readOnly: true));
      final loaded = await store.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.port, 18000);
      expect(loaded.bindLan, isTrue);
      expect(loaded.readOnly, isTrue);
    });

    test('重置 token 会生成新值且写入存储', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = McpSettingsStore();
      final before = (await store.load()).token;
      final after = await store.regenerateToken();
      expect(after, isNot(before));
      expect((await store.load()).token, after);
    });
  });
}
