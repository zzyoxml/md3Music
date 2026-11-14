import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('AM 播放器背景模糊默认 30（与历史硬编码视觉一致）', () async {
    SharedPreferences.setMockInitialValues({});
    final tp = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tp.amPlayerBlur, 30.0);
  });

  test('AM 播放器背景模糊写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final tp = ThemeProvider();
    await tp.setAmPlayerBlur(12);
    expect(tp.amPlayerBlur, 12.0);
    // 新实例加载后读到的仍是持久化值
    final tp2 = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tp2.amPlayerBlur, 12.0);
  });

  test('AM 播放器背景模糊越界值被钳制到 0~200', () async {
    SharedPreferences.setMockInitialValues({});
    final tp = ThemeProvider();
    await tp.setAmPlayerBlur(300);
    expect(tp.amPlayerBlur, 200.0);
    await tp.setAmPlayerBlur(-5);
    expect(tp.amPlayerBlur, 0.0);
  });
}
