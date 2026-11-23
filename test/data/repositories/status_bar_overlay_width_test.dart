import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RedMagic status-bar lyric widths', () {
    test('new users get independent portrait and landscape defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = SettingsRepository();
      expect(await repository.getStatusBarPortraitWidthPercent(), 30);
      expect(await repository.getStatusBarLandscapeWidthPercent(), 55);
    });

    test('orientation widths persist independently', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = SettingsRepository();
      await repository.setStatusBarPortraitWidthPercent(40);
      expect(await repository.getStatusBarPortraitWidthPercent(), 40);
      expect(await repository.getStatusBarLandscapeWidthPercent(), 55);
      await repository.setStatusBarLandscapeWidthPercent(85);
      expect(await repository.getStatusBarPortraitWidthPercent(), 40);
      expect(await repository.getStatusBarLandscapeWidthPercent(), 85);
    });

    test('invalid writes are ignored and corrupted stored values are clamped', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = SettingsRepository();
      await repository.setStatusBarPortraitWidthPercent(10);
      await repository.setStatusBarLandscapeWidthPercent(100);
      expect(await repository.getStatusBarPortraitWidthPercent(), 30);
      expect(await repository.getStatusBarLandscapeWidthPercent(), 55);

      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings_dl_status_bar_portrait_width_pct': 0,
        'settings_dl_status_bar_landscape_width_pct': 200,
      });
      expect(await repository.getStatusBarPortraitWidthPercent(), 15);
      expect(await repository.getStatusBarLandscapeWidthPercent(), 90);
    });
  });
}
