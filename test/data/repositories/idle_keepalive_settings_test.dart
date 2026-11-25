import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsRepository idle keepalive stop', () {
    test('默认 10 分钟', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SettingsRepository().getIdleKeepaliveStopMinutes(), 10);
    });

    test('可保存关闭与档位', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      for (final minutes in [0, 5, 10, 15]) {
        await repo.setIdleKeepaliveStopMinutes(minutes);
        expect(await repo.getIdleKeepaliveStopMinutes(), minutes);
      }
    });
  });
}
