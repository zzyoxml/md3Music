import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/typography_m3e.dart';

void main() {
  group('M3ExpressiveTypography', () {
    final textTheme = M3ExpressiveTypography.build(
      const Color(0xFF000000),
      fontFamily: null,
    );

    test('displayLarge 是 64sp w300', () {
      expect(textTheme.displayLarge?.fontSize, 64);
      expect(textTheme.displayLarge?.fontWeight, FontWeight.w300);
    });

    test('displayMedium 是 52sp w400', () {
      expect(textTheme.displayMedium?.fontSize, 52);
      expect(textTheme.displayMedium?.fontWeight, FontWeight.w400);
    });

    test('displaySmall 是 36sp w400', () {
      expect(textTheme.displaySmall?.fontSize, 36);
      expect(textTheme.displaySmall?.fontWeight, FontWeight.w400);
    });

    test('headlineLarge 是 36sp w500（M3E 强调字重对比）', () {
      expect(textTheme.headlineLarge?.fontSize, 36);
      expect(textTheme.headlineLarge?.fontWeight, FontWeight.w500);
    });

    test('titleLarge 是 22sp w500（原 w600 调柔和）', () {
      expect(textTheme.titleLarge?.fontSize, 22);
      expect(textTheme.titleLarge?.fontWeight, FontWeight.w500);
    });

    test('titleMedium 是 16sp w500', () {
      expect(textTheme.titleMedium?.fontSize, 16);
      expect(textTheme.titleMedium?.fontWeight, FontWeight.w500);
    });

    test('labelLarge 是 14sp w700（按钮文字更突出）', () {
      expect(textTheme.labelLarge?.fontSize, 14);
      expect(textTheme.labelLarge?.fontWeight, FontWeight.w700);
    });

    test('所有 style 都有 color 设置', () {
      expect(textTheme.bodyLarge?.color, const Color(0xFF000000));
      expect(textTheme.bodyMedium?.color, const Color(0xFF000000));
    });

    test('fontFamily 透传到所有 style', () {
      final withFont = M3ExpressiveTypography.build(
        const Color(0xFF000000),
        fontFamily: 'SimHei',
      );
      expect(withFont.bodyLarge?.fontFamily, 'SimHei');
      expect(withFont.displayLarge?.fontFamily, 'SimHei');
    });
  });
}
