import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「使用系统主题色」与「封面动态取色」互斥回归：
/// 取色来源只能有一个——开启其中一个自动关闭另一个，持久化也同步纠正。
/// （此前两者可叠加，界面上两个开关都亮，用户无法判断当前生效的是哪个。）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ThemeProvider> freshProvider() async {
    SharedPreferences.setMockInitialValues({});
    final provider = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return provider;
  }

  test('开封面取色 → 自动关系统主题色，并持久化', () async {
    final provider = await freshProvider();
    await provider.setUseDynamicColor(true);
    expect(provider.useDynamicColor, isTrue);
    expect(provider.useCoverSeedColor, isFalse);

    await provider.setUseCoverSeedColor(true);
    expect(provider.useCoverSeedColor, isTrue);
    expect(provider.useDynamicColor, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('use_dynamic_color'), isFalse);
    expect(prefs.getBool('use_cover_dynamic_color'), isTrue);

    // 重启后仍互斥。
    final restored = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(restored.useDynamicColor, isFalse);
    expect(restored.useCoverSeedColor, isTrue);
  });

  test('开系统主题色 → 自动关封面取色，并持久化', () async {
    final provider = await freshProvider();
    await provider.setUseCoverSeedColor(true);
    expect(provider.useCoverSeedColor, isTrue);
    expect(provider.useDynamicColor, isFalse);

    await provider.setUseDynamicColor(true);
    expect(provider.useDynamicColor, isTrue);
    expect(provider.useCoverSeedColor, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('use_dynamic_color'), isTrue);
    expect(prefs.getBool('use_cover_dynamic_color'), isFalse);
  });

  test('关闭其中一项不影响另一项（互斥只在开启时生效）', () async {
    final provider = await freshProvider();
    await provider.setUseCoverSeedColor(true);
    await provider.setUseCoverSeedColor(false);
    expect(provider.useCoverSeedColor, isFalse);
    expect(provider.useDynamicColor, isFalse);
  });
}
