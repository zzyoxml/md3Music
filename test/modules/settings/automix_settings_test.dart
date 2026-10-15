import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('automix 默认关闭，写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsRepository();
    expect(await s.getAutomixEnabled(), isFalse);
    await s.setAutomixEnabled(true);
    expect(await s.getAutomixEnabled(), isTrue);
  });
}
