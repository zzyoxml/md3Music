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

  test('悬浮播放器透明度默认不透明并可持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = SettingsRepository();

    expect(await repository.getSecondaryPlayerOpacity(), 1.0);
    await repository.setSecondaryPlayerOpacity(0.45);
    expect(await repository.getSecondaryPlayerOpacity(), 0.45);
  });

  test('悬浮播放器透明度限制在可读范围内', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = SettingsRepository();

    await repository.setSecondaryPlayerOpacity(0.0);
    expect(await repository.getSecondaryPlayerOpacity(), 0.2);
    await repository.setSecondaryPlayerOpacity(2.0);
    expect(await repository.getSecondaryPlayerOpacity(), 1.0);
  });
}
