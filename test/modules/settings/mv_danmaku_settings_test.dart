import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MV 弹幕开关默认关闭（与官方 App 行为一致）', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getMvDanmakuEnabled(), isFalse);
  });

  test('MV 弹幕开关可写入并读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setMvDanmakuEnabled(true);
    expect(await repo.getMvDanmakuEnabled(), isTrue);
    await repo.setMvDanmakuEnabled(false);
    expect(await repo.getMvDanmakuEnabled(), isFalse);
  });

  test('持久化 key 为 settings_mv_danmaku_enabled', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository().setMvDanmakuEnabled(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_mv_danmaku_enabled'), isTrue);
  });

  test('弹幕透明度默认 1.0，越界值被钳制到 0.1-1.0', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    expect(await repo.getMvDanmakuOpacity(), 1.0);

    await repo.setMvDanmakuOpacity(0.4);
    expect(await repo.getMvDanmakuOpacity(), 0.4);

    await repo.setMvDanmakuOpacity(5.0);
    expect(await repo.getMvDanmakuOpacity(), 1.0);
    await repo.setMvDanmakuOpacity(0.0);
    expect(await repo.getMvDanmakuOpacity(), 0.1);
  });
}
