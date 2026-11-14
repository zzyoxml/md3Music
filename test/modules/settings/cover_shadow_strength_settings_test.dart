import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('封面阴影强度未设置时默认 0.7', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await SettingsRepository().getCoverShadowStrength(), 0.7);
  });

  test('已保存的封面阴影强度仍然生效', () async {
    SharedPreferences.setMockInitialValues({});

    await SettingsRepository().setCoverShadowStrength(0.35);

    expect(await SettingsRepository().getCoverShadowStrength(), 0.35);
  });
}
