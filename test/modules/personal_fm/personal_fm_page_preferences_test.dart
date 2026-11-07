import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('没有保存过时使用完整私人 FM 页的默认推荐方式', () async {
    final selection = await PersonalFmPagePreferences.load();

    expect(selection.mode, 'normal');
    expect(selection.songPoolId, 0);
  });

  test('保存和恢复完整私人 FM 页的推荐方式，不占用发现页电台键', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('discover_fm_station_index', 2);

    await PersonalFmPagePreferences.save(mode: 'small', songPoolId: 1);
    final selection = await PersonalFmPagePreferences.load();

    expect(selection.mode, 'small');
    expect(selection.songPoolId, 1);
    expect(prefs.getInt('discover_fm_station_index'), 2);
  });
}
