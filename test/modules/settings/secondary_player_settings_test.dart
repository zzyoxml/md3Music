import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('悬浮迷你播放器未设置时默认关闭', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await SettingsRepository().getSecondaryPlayerEnabled(), isFalse);
  });

  test('已保存的悬浮迷你播放器选择仍然生效', () async {
    SharedPreferences.setMockInitialValues({
      SettingsRepository.secondaryPlayerEnabledPreferenceKey: true,
    });

    expect(await SettingsRepository().getSecondaryPlayerEnabled(), isTrue);
  });
}
