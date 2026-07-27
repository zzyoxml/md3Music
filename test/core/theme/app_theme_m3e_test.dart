import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';

void main() {
  group('AppTheme M3 Expressive 集成', () {
    final lightTheme = AppTheme.lightTheme;
    final darkTheme = AppTheme.darkTheme;

    test('cardTheme.shape 是 expressive (32dp)', () {
      final shape = lightTheme.cardTheme.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      final radius = shape!.borderRadius as BorderRadius;
      // Radius 没有 .value getter，用 .x 取实际半径值
      expect(radius.topLeft.x, 32);
    });

    test('chipTheme.shape 是 small (8dp)', () {
      final shape = lightTheme.chipTheme.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      final radius = shape!.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 8);
    });

    test('floatingActionButtonTheme.shape 是 CircleBorder', () {
      final shape = lightTheme.floatingActionButtonTheme.shape;
      expect(shape, isA<CircleBorder>());
    });

    test('bottomSheetTheme.shape 是 28dp 顶部圆角', () {
      final shape = lightTheme.bottomSheetTheme.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      final radius = shape!.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 28);
    });

    test('textTheme.displayLarge 是 64sp w300（M3E）', () {
      final style = lightTheme.textTheme.displayLarge;
      expect(style?.fontSize, 64);
      expect(style?.fontWeight, FontWeight.w300);
    });

    test('textTheme.labelLarge 是 14sp w700（M3E 按钮）', () {
      final style = lightTheme.textTheme.labelLarge;
      expect(style?.fontSize, 14);
      expect(style?.fontWeight, FontWeight.w700);
    });

    test('darkTheme 也应用了 expressive shape', () {
      final shape = darkTheme.cardTheme.shape as RoundedRectangleBorder?;
      final radius = shape!.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 32);
    });

    test('useOledBlack 模式下 shape 仍然是 expressive', () {
      final oledTheme = AppTheme.darkThemeFromSeed(
        const Color(0xFF6750A4),
        useOledBlack: true,
      );
      final shape = oledTheme.cardTheme.shape as RoundedRectangleBorder?;
      final radius = shape!.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 32);
    });
  });
}
