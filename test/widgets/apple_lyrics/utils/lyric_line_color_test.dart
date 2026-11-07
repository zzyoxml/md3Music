import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/utils/lyric_line_color.dart';

/// 歌词行级颜色规则单测。
///
/// 锁定两件事：
/// 1. [resolveActiveLineColorValue] 的优先级与混色口径（自定义色 > 动态取色 >
///    无；比例 0 = 纯白，比例 1 = 主色；明度抬到 ≥ 0.78）；
/// 2. [lineColorOverrideValue] 只对「当前行 + 上方行」生效，下方行永不着色。
void main() {
  const accent = Color(0xFF3366CC);
  const custom = Color(0xFFAB12CD);

  /// 与实现同式的期望值（比例混色 + 明度下限），避免在测试里硬编码十六进制。
  Color expectedMix(Color accentColor, double ratio) {
    final mixed = Color.lerp(const Color(0xFFFFFFFF), accentColor, ratio)!;
    final hsl = HSLColor.fromColor(mixed);
    return hsl
        .withLightness(
          hsl.lightness < kActiveLyricMinLightness
              ? kActiveLyricMinLightness
              : hsl.lightness,
        )
        .toColor();
  }

  group('resolveActiveLineColorValue', () {
    test('自定义歌词文字色优先，压过动态取色', () {
      expect(
        resolveActiveLineColorValue(
          useDynamicColor: true,
          accentColor: accent,
          customTextColor: custom,
          mixRatio: 1.0,
        ),
        custom.toARGB32(),
      );
    });

    test('动态取色关闭时返回 null（回退主题歌词色）', () {
      expect(
        resolveActiveLineColorValue(
          useDynamicColor: false,
          accentColor: accent,
          customTextColor: null,
          mixRatio: 0.5,
        ),
        isNull,
      );
    });

    test('未提取到封面主色时返回 null', () {
      expect(
        resolveActiveLineColorValue(
          useDynamicColor: true,
          accentColor: null,
          customTextColor: null,
          mixRatio: 0.5,
        ),
        isNull,
      );
    });

    test('比例 0 = 纯白（明度已在上限）', () {
      expect(
        resolveActiveLineColorValue(
          useDynamicColor: true,
          accentColor: accent,
          customTextColor: null,
          mixRatio: 0.0,
        ),
        const Color(0xFFFFFFFF).toARGB32(),
      );
    });

    test('比例 0.15 与历史默认观感一致', () {
      expect(
        resolveActiveLineColorValue(
          useDynamicColor: true,
          accentColor: accent,
          customTextColor: null,
          mixRatio: 0.15,
        ),
        expectedMix(accent, 0.15).toARGB32(),
      );
    });

    test('比例 1 = 完全主色（明度抬到 ≥ 0.78）', () {
      final value = resolveActiveLineColorValue(
        useDynamicColor: true,
        accentColor: accent,
        customTextColor: null,
        mixRatio: 1.0,
      );
      expect(value, expectedMix(accent, 1.0).toARGB32());
      expect(
        HSLColor.fromColor(Color(value!)).lightness,
        greaterThanOrEqualTo(kActiveLyricMinLightness - 1e-9),
      );
    });

    test('比例越界被夹到 [0, 1]，非有限值按 0 处理', () {
      int? resolve(double ratio) => resolveActiveLineColorValue(
            useDynamicColor: true,
            accentColor: accent,
            customTextColor: null,
            mixRatio: ratio,
          );
      expect(resolve(5.0), resolve(1.0));
      expect(resolve(-3.0), resolve(0.0));
      expect(resolve(double.nan), resolve(0.0));
    });
  });

  group('lineColorOverrideValue', () {
    const active = 0xFF112233;
    const above = 0xFF445566;

    test('当前行用高亮色', () {
      expect(
        lineColorOverrideValue(
          activeLineColorValue: active,
          aboveLineColorValue: above,
          isActive: true,
          isAboveCurrent: false,
        ),
        active,
      );
    });

    test('上方行用上方行颜色（开关关闭时调用方传 null）', () {
      expect(
        lineColorOverrideValue(
          activeLineColorValue: active,
          aboveLineColorValue: above,
          isActive: false,
          isAboveCurrent: true,
        ),
        above,
      );
    });

    test('上方行颜色为 null 时不覆盖', () {
      expect(
        lineColorOverrideValue(
          activeLineColorValue: active,
          aboveLineColorValue: null,
          isActive: false,
          isAboveCurrent: true,
        ),
        isNull,
      );
    });

    test('当前行以下永不覆盖', () {
      expect(
        lineColorOverrideValue(
          activeLineColorValue: active,
          aboveLineColorValue: above,
          isActive: false,
          isAboveCurrent: false,
        ),
        isNull,
      );
    });

    test('高亮色为 null 时即便上方行也不覆盖', () {
      expect(
        lineColorOverrideValue(
          activeLineColorValue: null,
          aboveLineColorValue: null,
          isActive: false,
          isAboveCurrent: true,
        ),
        isNull,
      );
    });
  });
}
