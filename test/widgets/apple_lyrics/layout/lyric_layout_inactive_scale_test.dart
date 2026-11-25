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
    test('默认值与可配置偏好保持一致（按当前平台）', () async {
      await LyricPreferences.instance.reset();
      expect(
        LyricLayout.inactiveScale,
        equals(LyricPreferences.defaultInactiveScaleForCurrentPlatform),
      );
    });

    test('跟随 LyricPreferences 变化', () async {
      // 0.95 落在所有平台范围内（安卓 0.80~1.00，Windows 0.90~1.00）
      await LyricPreferences.instance.setInactiveScale(0.95);
      expect(LyricLayout.inactiveScale, equals(0.95));
    });
  });

  group('LyricLayout.blurRenderScale', () {
    test('enableScale=true 时与清晰层非当前行 scale 完全同源（无额外因子）', () async {
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
      // 使用当前平台范围内的取值，确保 Windows/安卓均有效
      final lo = LyricPreferences.minInactiveScaleForCurrentPlatform;
      final hi = LyricPreferences.maxInactiveScaleForCurrentPlatform;
      for (final value in <double>[lo, (lo + hi) / 2, hi - 0.01, hi]) {
        await LyricPreferences.instance.setInactiveScale(value);
        expect(
          LyricLayout.blurRenderScale(enableScale: true),
          equals(LyricLayout.inactiveScale),
        );
      }
    });
  });

  group('LyricLayout.alignPosition（当前行垂直锚位）', () {
    test('默认值按当前平台生效', () async {
      await LyricPreferences.instance.reset();
      expect(
        LyricLayout.alignPosition,
        equals(LyricPreferences.defaultAlignPositionForCurrentPlatform),
      );
    });

    test('跟随 LyricPreferences 变化', () async {
      await LyricPreferences.instance.setAlignPosition(0.5);
      expect(LyricLayout.alignPosition, equals(0.5));
    });

    test('低于下限被夹到当前平台 minAlignPosition', () async {
      await LyricPreferences.instance.setAlignPosition(0.0);
      expect(
        LyricPreferences.instance.alignPosition,
        equals(LyricPreferences.minAlignPositionForCurrentPlatform),
      );
    });

    test('高于上限被夹到当前平台 maxAlignPosition', () async {
      await LyricPreferences.instance.setAlignPosition(0.9);
      expect(
        LyricPreferences.instance.alignPosition,
        equals(LyricPreferences.maxAlignPositionForCurrentPlatform),
      );
    });

    test('默认值落在当前平台范围正中（两侧对称可调）', () {
      final lo = LyricPreferences.minAlignPositionForCurrentPlatform;
      final hi = LyricPreferences.maxAlignPositionForCurrentPlatform;
      final mid = LyricPreferences.defaultAlignPositionForCurrentPlatform;
      expect(mid, closeTo((lo + hi) / 2, 1e-9));
    });

    test('滑块步长为 0.01（安卓基线常量）', () {
      const step =
          (LyricPreferences.maxAlignPosition -
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
        LyricPreferences.instance.lineSpacing + 0.3,
      );
      expect(
        LyricLayout.lineHeight,
        closeTo(
          (fontSize / LyricPreferences.defaultFontSize) *
              (LyricPreferences.instance.lineSpacing),
          1e-9,
        ),
      );
      expect(LyricLayout.lineHeight, isNot(equals(base)));
    });
  });

  group('LyricPreferences.setInactiveScale 边界', () {
    test('低于下限被夹到当前平台 minInactiveScale', () async {
      // 传负值确保低于任何平台的 min（安卓 0.80 / Windows 0.00）
      await LyricPreferences.instance.setInactiveScale(-1);
      expect(
        LyricPreferences.instance.inactiveScale,
        equals(LyricPreferences.minInactiveScaleForCurrentPlatform),
      );
    });

    test('高于上限被夹到当前平台 maxInactiveScale', () async {
      await LyricPreferences.instance.setInactiveScale(1.5);
      expect(
        LyricPreferences.instance.inactiveScale,
        equals(LyricPreferences.maxInactiveScaleForCurrentPlatform),
      );
    });

    test('全局滑块档位步长为 0.005（安卓基线常量）', () {
      const step =
          (LyricPreferences.maxInactiveScale -
              LyricPreferences.minInactiveScale) /
          LyricPreferences.inactiveScaleDivisions;
      expect(step, closeTo(0.005, 1e-9));
    });
  });
}
