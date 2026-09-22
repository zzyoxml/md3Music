import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('提醒开关默认开启', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateReminderEnabled(), isTrue);
  });

  test('提醒开关写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateReminderEnabled(false);
    expect(await repo.getUpdateReminderEnabled(), isFalse);
  });

  test('上次检查时间为空时返回 0', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateLastCheckMs(), 0);
  });

  test('上次检查时间写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateLastCheckMs(1735660800000);
    expect(await repo.getUpdateLastCheckMs(), 1735660800000);
  });

  test('已提醒版本为空时返回空串', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateLastNotifiedVersion(), '');
  });

  test('已提醒版本写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateLastNotifiedVersion('5.6.5');
    expect(await repo.getUpdateLastNotifiedVersion(), '5.6.5');
  });
}
