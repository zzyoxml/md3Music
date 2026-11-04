import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('记忆播放状态开关默认开启', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getRestoreMemoryEnabled(), isTrue);
  });

  test('记忆播放状态开关可写入并读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setRestoreMemoryEnabled(false);
    expect(await repo.getRestoreMemoryEnabled(), isFalse);
    await repo.setRestoreMemoryEnabled(true);
    expect(await repo.getRestoreMemoryEnabled(), isTrue);
  });

  test('持久化 key 为 settings_restore_memory', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository().setRestoreMemoryEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_restore_memory'), isFalse);
  });
}
