import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('字体颜色默认跟随主题，设置后持久化，清除后恢复默认', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(provider.customTextColor, isNull);

    const chosen = Color(0xFF734BA1);
    await provider.setCustomTextColor(chosen);
    expect(provider.customTextColor, chosen);
    final restored = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(restored.customTextColor, chosen);

    await provider.setCustomTextColor(null);
    expect(provider.customTextColor, isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey('custom_text_color'),
      isFalse,
    );
  });

  test('浅色与深色主题只在指定时覆盖表面文字色', () {
    const seed = Color(0xFF0061A4);
    const chosen = Color(0xFF734BA1);
    for (final theme in [
      AppTheme.lightThemeFromSeed(seed, textColor: chosen),
      AppTheme.darkThemeFromSeed(seed, textColor: chosen),
    ]) {
      expect(theme.colorScheme.onSurface, chosen);
      expect(theme.textTheme.bodyMedium?.color, chosen);
      expect(theme.appBarTheme.titleTextStyle?.color, chosen);
    }
    expect(
      AppTheme.lightThemeFromSeed(seed).colorScheme.onSurface,
      isNot(chosen),
    );
  });
}
