import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('令牌从 SharedPreferences 迁移到 secure storage 并清除旧值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_mcp_token': 'legacy-token',
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    final store = McpSettingsStore();
    final settings = await store.load();
    expect(settings.token, 'legacy-token');

    final secure = FlutterSecureStorage();
    expect(await secure.read(key: 'settings_mcp_token_secure'), 'legacy-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings_mcp_token'), isNull);
  });

  test('secure storage 已有令牌时直接使用', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'settings_mcp_token_secure': 'secure-token',
    });
    final store = McpSettingsStore();
    expect((await store.load()).token, 'secure-token');
  });
}
