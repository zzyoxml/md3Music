import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_theme.dart';

void main() {
  group('预测性返回主题接线', () {
    test('predictiveBack=false 保持 FadeForwards 过渡（默认回归基线）', () {
      final theme = AppTheme.lightThemeFromSeed(
        AppTheme.presetSeedColors.first,
        predictiveBack: false,
      );
      final builder = theme.pageTransitionsTheme.builders[TargetPlatform.android];
      expect(builder.runtimeType.toString(), contains('FadeForwards'));
      expect(builder, isNot(isA<BgSafePredictiveBackBuilder>()));
    });

    test('predictiveBack=true 切换到预测性返回过渡', () {
      final theme = AppTheme.lightThemeFromSeed(
        AppTheme.presetSeedColors.first,
        predictiveBack: true,
      );
      final builder = theme.pageTransitionsTheme.builders[TargetPlatform.android];
      expect(builder, isA<BgSafePredictiveBackBuilder>());
    });

    test('深色主题同两态生效', () {
      final off = AppTheme.darkThemeFromSeed(
        AppTheme.presetSeedColors.first,
        predictiveBack: false,
      );
      final on = AppTheme.darkThemeFromSeed(
        AppTheme.presetSeedColors.first,
        predictiveBack: true,
      );
      expect(
        on.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<BgSafePredictiveBackBuilder>(),
      );
      expect(
        off.pageTransitionsTheme.builders[TargetPlatform.android],
        isNot(isA<BgSafePredictiveBackBuilder>()),
      );
    });
  });
}
