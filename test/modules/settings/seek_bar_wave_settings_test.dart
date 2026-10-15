import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('进度条波浪未设置时默认开启', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await SettingsRepository().getSeekBarWaveEnabled(), isTrue);
  });

  test('已保存的进度条波浪选择仍然生效', () async {
    SharedPreferences.setMockInitialValues({
      SettingsRepository.seekBarWaveEnabledPreferenceKey: false,
    });

    expect(await SettingsRepository().getSeekBarWaveEnabled(), isFalse);
  });
}
