/// 「平衡行换行」偏好的两态行为：默认开启、可持久化、reset 回默认。
///
/// AM 与 MD 各一套独立 key（`lyric_line_balance` / `md3_lyric_line_balance`），
/// 互不影响——这是本仓「两套歌词偏好分家」的既有约定。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LyricPreferences.instance.reset();
    await Md3LyricPreferences.instance.reset();
  });
  tearDown(() async {
    await LyricPreferences.instance.reset();
    await Md3LyricPreferences.instance.reset();
  });

  test('两个偏好默认开启平衡行换行', () {
    expect(LyricPreferences.instance.lineBalance, isTrue);
    expect(Md3LyricPreferences.instance.lineBalance, isTrue);
  });

  test('AM 开关：setter 先通知再落盘，且不影响 MD 开关', () async {
    int notified = 0;
    void listener() => notified++;
    LyricPreferences.instance.addListener(listener);
    addTearDown(() => LyricPreferences.instance.removeListener(listener));

    await LyricPreferences.instance.setLineBalance(false);
    expect(notified, 1, reason: '值变化必须 notifyListeners，视图才能重算换行');
    expect(LyricPreferences.instance.lineBalance, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lyric_line_balance'), isFalse);
    expect(Md3LyricPreferences.instance.lineBalance, isTrue);
  });

  test('AM 开关同值写入不重复通知（沿用仓内 setter 的门控写法）', () async {
    await LyricPreferences.instance.setLineBalance(false);
    int notified = 0;
    void listener() => notified++;
    LyricPreferences.instance.addListener(listener);
    addTearDown(() => LyricPreferences.instance.removeListener(listener));

    await LyricPreferences.instance.setLineBalance(false);
    expect(notified, 0);
  });

  test('MD 开关独立持久化，reset 恢复默认开启', () async {
    await Md3LyricPreferences.instance.setLineBalance(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('md3_lyric_line_balance'), isFalse);

    await Md3LyricPreferences.instance.reset();
    expect(Md3LyricPreferences.instance.lineBalance, isTrue);
  });
}
