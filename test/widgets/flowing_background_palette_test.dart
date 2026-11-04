import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:material_ui/material_ui.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/flowing_background_palette.dart';

/// 流光调色板派生的语义（纯函数，不 depend GPU/图片解码）。
///
/// 覆盖：
/// - 单色封面 → 4 个互不相同的 pigment；
/// - base 亮度严格低于全部 pigment（shader 里 base 是"有限覆盖"的底色）；
/// - 32 个运动变体在色域内、无 NaN；
/// - url → palette 缓存命中时不重复解码（注入 loader 计数）；
/// - 黑白/低饱和封面兜底沿用 slate 基调（不退刺激眼紫）。
void main() {
  double lightness(Color c) {
    final values = <double>[c.r, c.g, c.b]..sort();
    return (values.first + values.last) / 2;
  }

  group('pigment 派生', () {
    test('单色封面派生 4 个互不相同的 pigment', () {
      final palette = buildFlowingPalette(const [Color(0xFF3366CC)]);
      expect(palette.pigments.length, 4);
      expect(palette.pigments.toSet().length, 4, reason: '4 个 pigment 不得重复');
      // shader 的四场要能看出差别：色相或亮度必须不同
      final hsl = palette.pigments.map((c) {
        final r = c.r, g = c.g, b = c.b;
        final max = [r, g, b].reduce((a, b) => a > b ? a : b);
        final min = [r, g, b].reduce((a, b) => a < b ? a : b);
        return (max, min);
      }).toList();
      expect(hsl.toSet().length, 4);
    });

    test('base 亮度低于全部 pigment', () {
      final cases = <FlowingPalette>[
        buildFlowingPalette(const [Color(0xFF3366CC)]),
        buildFlowingPalette(const [
          Color(0xFFE0B060),
          Color(0xFF2A4E7A),
          Color(0xFFB03050),
        ]),
        FlowingPalette.fallback,
      ];
      for (final palette in cases) {
        final baseLightness = lightness(palette.baseColor);
        for (final pigment in palette.pigments) {
          expect(baseLightness, lessThan(lightness(pigment)),
              reason: 'base=$baseLightness pigment=${lightness(pigment)}');
        }
      }
    });

    test('pigments 按亮度降序（pigments[2] 恒为最暗，供回退 painter 基底）', () {
      final palette = buildFlowingPalette(const [
        Color(0xFF2A4E7A),
        Color(0xFFE0B060),
        Color(0xFFB03050),
      ]);
      final l0 = lightness(palette.pigments[0]);
      final l1 = lightness(palette.pigments[1]);
      final l2 = lightness(palette.pigments[2]);
      expect(l0, greaterThanOrEqualTo(l1));
      expect(l1, greaterThanOrEqualTo(l2));
    });
  });

  group('32 个运动变体', () {
    test('长度 32、全部在色域内、无 NaN', () {
      final palettes = <FlowingPalette>[
        FlowingPalette.fallback,
        buildFlowingPalette(const [Color(0xFF3366CC)]),
        buildFlowingPalette(const [Color(0xFFE0B060)]),
      ];
      for (final palette in palettes) {
        expect(palette.motionColors.length, 4 * fluidMotionColourCount);
        for (final c in palette.motionColors) {
          expect(c.r.isFinite && c.g.isFinite && c.b.isFinite && c.a.isFinite,
              isTrue,
              reason: '运动色出现 NaN：$c');
          expect(c.r, inInclusiveRange(0, 1));
          expect(c.g, inInclusiveRange(0, 1));
          expect(c.b, inInclusiveRange(0, 1));
          expect(c.a, 1);
        }
        // 访问器与扁平索引一致（shader 按 field/variant 取样）
        for (var field = 0; field < 4; field++) {
          for (var variant = 0; variant < fluidMotionColourCount; variant++) {
            expect(
              palette.motionColor(field, variant),
              palette.motionColors[field * fluidMotionColourCount + variant],
            );
          }
        }
        // 同一场的 8 个变体不能全同（否则 shader 里看不出颜色流动）
        for (var field = 0; field < 4; field++) {
          final set = <Color>{
            for (var variant = 0; variant < fluidMotionColourCount; variant++)
              palette.motionColor(field, variant),
          };
          expect(set.length, greaterThan(1), reason: 'field=$field 变体全同');
        }
      }
    });
  });

  group('黑白 / 低饱和封面兜底', () {
    test('无候选 / 灰色封面 → slate 基调，不用刺眼紫', () {
      final neutral = FlowingPalette.fallback;
      expect(identical(buildFlowingPalette(const []), neutral), isTrue);
      expect(identical(buildFlowingPalette(const [Color(0xFF808080)]), neutral),
          isTrue);
      // 原 slate 三色基调（顺序即原 _colors，回退 painter 的光斑角色不变）
      expect(neutral.pigments[0], const Color(0xFF4A5568));
      expect(neutral.pigments[1], const Color(0xFF5A6478));
      expect(neutral.pigments[2], const Color(0xFF2F3A50));
      expect(neutral.pigments.length, 4);
      expect(neutral.baseColor, const Color(0xFF080A0E));
      // 低饱和：不得回到 deepPurple/indigo 那种高饱和紫（用 HSL 饱和度衡量——
      // slate 的 HSV 饱和度偏高，但 HSL 饱和度只有 ~0.2）
      for (final c in neutral.pigments) {
        final r = c.r, g = c.g, b = c.b;
        final max = [r, g, b].reduce((a, b) => a > b ? a : b);
        final min = [r, g, b].reduce((a, b) => a < b ? a : b);
        final lightness = (max + min) / 2;
        final delta = max - min;
        final saturation = delta == 0
            ? 0.0
            : lightness > 0.5
                ? delta / (2 - max - min)
                : delta / (max + min);
        expect(saturation, lessThan(0.30), reason: '兜底色 $c 饱和度过高');
      }
    });
  });

  group('缓存', () {
    test('同一 url 只解码一次，结果复用同一 FlowingPalette 实例', () async {
      var loads = 0;
      final cache = FlowingPaletteCache(
        loader: (String url) async {
          loads++;
          return const <Color>[Color(0xFF3366CC), Color(0xFFCC3366)];
        },
      );
      final first = await cache.paletteFor('cover://a');
      final second = await cache.paletteFor('cover://a');
      expect(loads, 1, reason: '缓存命中不得重复解码');
      expect(identical(first, second), isTrue);
      expect(cache.length, 1);
      expect(cache.loadCount, 1);
      // peek 不触发解码
      expect(identical(cache.peek('cover://a'), first), isTrue);
      expect(cache.peek('cover://missing'), isNull);
      expect(cache.loadCount, 1);
    });

    test('并发请求同一 url 复用同一个 Future', () async {
      var loads = 0;
      final cache = FlowingPaletteCache(
        loader: (String url) async {
          loads++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return const <Color>[Color(0xFF3366CC), Color(0xFFCC3366)];
        },
      );
      final results = await Future.wait([
        cache.paletteFor('cover://b'),
        cache.paletteFor('cover://b'),
      ]);
      expect(loads, 1);
      expect(identical(results[0], results[1]), isTrue);
    });

    test('loader 失败 → 兜底 palette，且失败不写缓存（可重试）', () async {
      var loads = 0;
      final cache = FlowingPaletteCache(
        loader: (String url) async {
          loads++;
          if (loads == 1) throw StateError('network down');
          return const <Color>[Color(0xFF3366CC)];
        },
      );
      final failed = await cache.paletteFor('cover://c');
      expect(identical(failed, FlowingPalette.fallback), isTrue);
      expect(cache.length, 0, reason: '失败结果不得入缓存');
      await cache.paletteFor('cover://c');
      expect(loads, 2, reason: '失败后应可重试');
    });
  });

  /// 深色模式档（`Theme.brightness == Brightness.dark` 时使用）。
  ///
  /// AM 播放页恒为深色背景，深色档只压低流光的亮度/饱和度来减少夜间眩光；
  /// 关键是**不可变**：派生不得就地改写共享的兜底/缓存实例。
  group('深色模式档（buildDeepFlowingPalette）', () {
    double hue(Color c) => HSLColor.fromColor(c).hue;

    double hueDistance(Color a, Color b) {
      final diff = (hue(a) - hue(b)).abs() % 360;
      return math.min(diff, 360 - diff);
    }

    test('pigment / base / 运动色亮度全部下降，色相不变', () {
      final cases = <FlowingPalette>[
        FlowingPalette.fallback,
        buildFlowingPalette(const [Color(0xFFE0B060)]),
        buildFlowingPalette(const [Color(0xFF3366CC), Color(0xFFCC3366)]),
      ];
      for (final source in cases) {
        final deep = buildDeepFlowingPalette(source);

        expect(deep.pigments.length, source.pigments.length);
        for (var i = 0; i < source.pigments.length; i++) {
          expect(lightness(deep.pigments[i]),
              lessThan(lightness(source.pigments[i])),
              reason: 'pigment[$i] 必须变暗');
          // 派生色里最深的那一档本身低饱和，8bit HSL↔RGB 往返有 ~1° 量化漂移；
          // 这里拦的是「色相被真的改动」这个量级。
          expect(hueDistance(deep.pigments[i], source.pigments[i]),
              lessThan(3.0),
              reason: 'pigment[$i] 色相不得偏移');
        }

        expect(lightness(deep.baseColor), lessThan(lightness(source.baseColor)),
            reason: 'base 必须变暗');

        for (var i = 0; i < source.motionColors.length; i++) {
          expect(lightness(deep.motionColors[i]),
              lessThanOrEqualTo(lightness(source.motionColors[i]) + 1e-9),
              reason: '运动色[$i] 不得变亮');
          // 低饱和/极暗色在 8bit HSL↔RGB 往返里本身就有几度量化漂移，
          // 这里只拦「色相被真的改动」这个量级（<6°）。
          expect(hueDistance(deep.motionColors[i], source.motionColors[i]),
              lessThan(6.0),
              reason: '运动色[$i] 色相不得偏移');
        }
      }
    });

    test('派生后不变量保持：base 仍最暗、4 个 pigment 仍互不相同', () {
      final source = buildFlowingPalette(const [Color(0xFF3366CC)]);
      final deep = buildDeepFlowingPalette(source);

      final baseLightness = lightness(deep.baseColor);
      for (final pigment in deep.pigments) {
        expect(baseLightness, lessThan(lightness(pigment)),
            reason: 'shader 里 base 是"有限覆盖"的底色，必须最暗');
      }
      expect(deep.pigments.toSet().length, 4, reason: '压暗不得把 pigment 压成重色');
    });

    test('返回新实例，绝不就地改写输入（共享实例回归）', () {
      final sharedBefore = List<Color>.of(FlowingPalette.fallback.pigments);
      final sharedBaseBefore = FlowingPalette.fallback.baseColor;
      final sharedMotionBefore =
          List<Color>.of(FlowingPalette.fallback.motionColors);

      final deep = buildDeepFlowingPalette(FlowingPalette.fallback);

      expect(identical(deep, FlowingPalette.fallback), isFalse);
      expect(FlowingPalette.fallback.pigments, equals(sharedBefore),
          reason: '兜底实例是跨页面共享的，不得被改写');
      expect(FlowingPalette.fallback.baseColor, equals(sharedBaseBefore));
      expect(FlowingPalette.fallback.motionColors, equals(sharedMotionBefore));

      // 缓存里取出的实例同样不得被改写
      final cached = buildFlowingPalette(const [Color(0xFF3366CC)]);
      final cachedBefore = List<Color>.of(cached.pigments);
      buildDeepFlowingPalette(cached);
      expect(cached.pigments, equals(cachedBefore));
    });
  });
}
