import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricLayout.inactiveScale / blurRenderScale 单元测试
///
/// 锁定「AM 歌词清晰层非当前行与模糊层共用同一个缩放值」这一契约：
/// 模糊图离屏渲染时烘焙的就是这个值，任何取值下两层都必须严格重合，
/// 因此禁止后续给模糊层另加光学补偿等独立因子。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('LyricLayout.inactiveScale', () {
    test('默认值保持历史写死值 0.97', () async {
      await LyricPreferences.instance.reset();
      expect(LyricLayout.inactiveScale,
          equals(LyricPreferences.defaultInactiveScale));
      expect(LyricLayout.inactiveScale, equals(0.97));
    });

    test('跟随 LyricPreferences 变化', () async {
      await LyricPreferences.instance.setInactiveScale(0.90);
      expect(LyricLayout.inactiveScale, equals(0.90));
    });
  });

  group('LyricLayout.blurRenderScale', () {
    test('enableScale=true 时与清晰层非当前行 scale 完全同源（无额外因子）',
        () async {
      await LyricPreferences.instance.setInactiveScale(0.90);
      expect(
        LyricLayout.blurRenderScale(enableScale: true),
        equals(LyricLayout.inactiveScale),
      );
    });

    test('enableScale=false 时取 activeScale（清晰层非当前行此时为 1.0）', () {
      expect(
        LyricLayout.blurRenderScale(enableScale: false),
        equals(LyricLayout.activeScale),
      );
    });

    test('调节非当前行缩放时两层同步变化，任意取值下保持重合', () async {
      for (final value in <double>[0.80, 0.855, 0.94, 1.00]) {
        await LyricPreferences.instance.setInactiveScale(value);
        expect(LyricLayout.blurRenderScale(enableScale: true),
            equals(LyricLayout.inactiveScale));
      }
    });
  });

  group('LyricLayout.alignPosition（当前行垂直锚位）', () {
    test('默认值保持历史写死值 0.35', () async {
      await LyricPreferences.instance.reset();
      expect(LyricLayout.alignPosition,
          equals(LyricPreferences.defaultAlignPosition));
      expect(LyricLayout.alignPosition, equals(0.35));
    });

    test('跟随 LyricPreferences 变化', () async {
      await LyricPreferences.instance.setAlignPosition(0.5);
      expect(LyricLayout.alignPosition, equals(0.5));
    });

    test('低于下限被夹到 minAlignPosition', () async {
      await LyricPreferences.instance.setAlignPosition(0.0);
      expect(LyricPreferences.instance.alignPosition,
          equals(LyricPreferences.minAlignPosition));
    });

    test('高于上限被夹到 maxAlignPosition', () async {
      await LyricPreferences.instance.setAlignPosition(0.9);
      expect(LyricPreferences.instance.alignPosition,
          equals(LyricPreferences.maxAlignPosition));
    });

    test('滑块步长为 0.01', () {
      const step = (LyricPreferences.maxAlignPosition -
              LyricPreferences.minAlignPosition) /
          LyricPreferences.alignPositionDivisions;
      expect(step, closeTo(0.01, 1e-9));
    });
  });

  group('LyricLayout.lineHeight 跟随行间距', () {
    test('setLineSpacing 改变 lineHeight（行高缓存键依赖此链路）', () async {
      final base = LyricLayout.lineHeight;
      final fontSize = LyricPreferences.instance.fontSize;
      await LyricPreferences.instance.setLineSpacing(
          LyricPreferences.instance.lineSpacing + 0.3);
      expect(
        LyricLayout.lineHeight,
        closeTo((fontSize / LyricPreferences.defaultFontSize) *
            (LyricPreferences.instance.lineSpacing),
            1e-9),
      );
      expect(LyricLayout.lineHeight, isNot(equals(base)));
    });
  });

  group('LyricPreferences.setInactiveScale 边界', () {
    test('低于下限被夹到 minInactiveScale', () async {
      await LyricPreferences.instance.setInactiveScale(0.5);
      expect(LyricPreferences.instance.inactiveScale,
          equals(LyricPreferences.minInactiveScale));
    });

    test('高于上限被夹到 maxInactiveScale', () async {
      await LyricPreferences.instance.setInactiveScale(1.5);
      expect(LyricPreferences.instance.inactiveScale,
          equals(LyricPreferences.maxInactiveScale));
    });

    test('滑块档位步长为 0.005', () {
      const step = (LyricPreferences.maxInactiveScale -
              LyricPreferences.minInactiveScale) /
          LyricPreferences.inactiveScaleDivisions;
      expect(step, closeTo(0.005, 1e-9));
    });
  });
}
