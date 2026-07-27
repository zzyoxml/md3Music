import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/shape_tokens.dart';

void main() {
  group('M3ExpressiveShapes', () {
    test('extraSmall 是 4dp 圆角', () {
      expect(M3ExpressiveShapes.extraSmall, isA<RoundedRectangleBorder>());
      final border = M3ExpressiveShapes.extraSmall as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      // Radius 没有 .value getter，用 .x 取实际半径值
      expect(radius.topLeft.x, 4);
      expect(radius.bottomRight.x, 4);
    });

    test('small 是 8dp 圆角', () {
      final border = M3ExpressiveShapes.small as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 8);
    });

    test('medium 是 12dp 圆角', () {
      final border = M3ExpressiveShapes.medium as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 12);
    });

    test('large 是 16dp 圆角', () {
      final border = M3ExpressiveShapes.large as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 16);
    });

    test('extraLarge 是 28dp 圆角（保留给 bottom sheet）', () {
      final border = M3ExpressiveShapes.extraLarge as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 28);
    });

    test('expressive 是 32dp 圆角（M3 Expressive 大卡片专用）', () {
      final border = M3ExpressiveShapes.expressive as RoundedRectangleBorder;
      final radius = border.borderRadius as BorderRadius;
      expect(radius.topLeft.x, 32);
    });

    test('full 是 CircleBorder（用于 FAB / pill indicator）', () {
      expect(M3ExpressiveShapes.full, isA<CircleBorder>());
    });
  });
}
