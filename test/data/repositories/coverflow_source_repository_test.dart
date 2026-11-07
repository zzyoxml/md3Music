import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsRepository coverflow source', () {
    test('未持久化时返回 null（调用方按默认每日推荐处理）', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      expect(await repo.getCoverFlowSourceRaw(), isNull);
    });

    test('set 后 get 读回原值（round-trip）', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setCoverFlowSourceRaw('personalFm');
      expect(await repo.getCoverFlowSourceRaw(), 'personalFm');
      await repo.setCoverFlowSourceRaw('homeDiscover');
      expect(await repo.getCoverFlowSourceRaw(), 'homeDiscover');
      await repo.setCoverFlowSourceRaw('daily');
      expect(await repo.getCoverFlowSourceRaw(), 'daily');
    });
  });
}
