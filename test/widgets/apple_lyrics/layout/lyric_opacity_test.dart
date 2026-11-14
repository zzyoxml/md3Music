import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/line_renderer.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 已播 / 未播歌词透明度：公式零回归、渲染接线、缓存失效、模糊层系数、预设。
///
/// 默认值 1.0 / 0.4 代入新公式必须逐点等于原
/// `factor*0.8+0.2` / `factor*0.2+0.2`，这是升级后观感不变的验收点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = LyricPreferences.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await prefs.reset();
  });

  group('默认值零视觉回归', () {
    test('alpha 公式逐点等于原公式', () {
      for (final f in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(LyricLayout.brightAlphaFor(f), closeTo(f * 0.8 + 0.2, 1e-9));
        expect(LyricLayout.darkAlphaFor(f), closeTo(f * 0.2 + 0.2, 1e-9));
      }
      expect(LyricLayout.alphaBase, closeTo(0.2, 1e-9));
      expect(LyricLayout.brightAlphaFor(1.0), closeTo(1.0, 1e-9));
      expect(LyricLayout.darkAlphaFor(0.0), closeTo(0.2, 1e-9));
    });

    test('WordRenderer 两 getter 默认值下等于原式', () {
      final renderer = WordRenderer();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.factor, closeTo(1.0, 1e-9));
      expect(renderer.dynamicBrightAlpha, closeTo(1.0, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.4, 1e-9));
      renderer.setLineState(isActive: false, scale: LyricLayout.inactiveScale);
      expect(renderer.dynamicBrightAlpha, closeTo(0.2, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.2, 1e-9));
    });

    test('LineRenderer 默认初值 / target 保持 0.2 与 1.0', () {
      final renderer = LineRenderer();
      expect(renderer.currentAlpha, closeTo(0.2, 1e-9));
      expect(renderer.targetAlpha, closeTo(0.2, 1e-9));
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.targetAlpha, closeTo(1.0, 1e-9));
      renderer.setLineState(
        isActive: false,
        scale: LyricLayout.inactiveScale,
        blurActive: false,
      );
      expect(renderer.targetAlpha, closeTo(0.2, 1e-9));
    });
  });

  group('非默认值生效', () {
    test('WordRenderer 亮/暗档跟随偏好且保留 factor 线性联动', () async {
      await prefs.setPlayedOpacity(0.5);
      await prefs.setUnplayedOpacity(0.2);
      final renderer = WordRenderer();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.dynamicBrightAlpha, closeTo(0.5, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.2, 1e-9));
      renderer.setLineState(isActive: false, scale: LyricLayout.inactiveScale);
      expect(renderer.dynamicBrightAlpha, closeTo(0.1, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.1, 1e-9));

      final mid = (LyricLayout.inactiveScale + LyricLayout.activeScale) / 2;
      renderer.setLineState(isActive: true, scale: mid);
      expect(renderer.factor, closeTo(0.5, 1e-9));
      expect(renderer.dynamicBrightAlpha,
          closeTo(LyricLayout.brightAlphaFor(0.5), 1e-9));
      expect(renderer.dynamicDarkAlpha,
          closeTo(LyricLayout.darkAlphaFor(0.5), 1e-9));
    });

    test('LineRenderer 稳态下偏好变化不被输入缓存早退吞掉', () async {
      final renderer = LineRenderer();
      renderer.setLineState(
        isActive: false,
        scale: LyricLayout.inactiveScale,
        blurActive: false,
      );
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(0.2, 1e-9));

      await prefs.setUnplayedOpacity(0.8);
      // 5 个原始输入完全不变，仅偏好变化：必须重算 targetAlpha。
      // 变异验证：删掉 setLineState 早退判断里的两条偏好比较，此断言必须失败。
      renderer.setLineState(
        isActive: false,
        scale: LyricLayout.inactiveScale,
        blurActive: false,
      );
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(0.4, 1e-9),
          reason: 'base = 0.8 * 0.5，偏好变化必须穿透输入缓存');
    });
  });

  group('边界', () {
    test('inactiveScale == activeScale 时 factor 退化为 1，无 NaN', () async {
      await prefs.setInactiveScale(
          LyricPreferences.maxInactiveScaleForCurrentPlatform);
      expect(LyricLayout.factorFor(LyricLayout.activeScale), 1.0);
      final line = LineRenderer();
      line.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(line.targetAlpha.isNaN, isFalse);
      final word = WordRenderer();
      word.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(word.dynamicBrightAlpha.isNaN, isFalse);
    });

    test('U=0 时暗态完全隐藏；P<U 时不做 clamp', () async {
      await prefs.setUnplayedOpacity(0.0);
      await prefs.setPlayedOpacity(0.1);
      expect(LyricLayout.darkAlphaFor(1.0), closeTo(0.0, 1e-9));
      expect(LyricLayout.brightAlphaFor(1.0), closeTo(0.1, 1e-9));
    });
  });

  group('高斯模糊层系数', () {
    test('默认偏好恒为 1.0（零回归），调低生效、调高不叠加', () async {
      expect(LyricLayout.blurOpacityScaleFor(isAbove: true), 1.0);
      expect(LyricLayout.blurOpacityScaleFor(isAbove: false), 1.0);
      await prefs.setPlayedOpacity(0.0);
      await prefs.setUnplayedOpacity(0.0);
      expect(LyricLayout.blurOpacityScaleFor(isAbove: true), 0.0);
      expect(LyricLayout.blurOpacityScaleFor(isAbove: false), 0.0);
      await prefs.setUnplayedOpacity(1.0);
      expect(LyricLayout.blurOpacityScaleFor(isAbove: false), 1.0,
          reason: 'Opacity 上限 1.0，调高不叠加');
    });
  });

  group('预设 20 项', () {
    test('导出 / 导入包含两项，且缺失键保持当前值', () async {
      expect(LyricPreferences.animationValueKeys, hasLength(20));
      final values = prefs.exportAnimationValues();
      expect(values.keys.toSet(), LyricPreferences.animationValueKeys.toSet());
      expect(values['playedOpacity'], 1.0);
      expect(values['unplayedOpacity'], 0.4);

      await prefs.applyAnimationValues(<String, Object?>{
        'playedOpacity': 0.25,
        'unplayedOpacity': 0.75,
      });
      expect(prefs.playedOpacity, 0.25);
      expect(prefs.unplayedOpacity, 0.75);

      await prefs.applyAnimationValues(<String, Object?>{
        'alignPosition': 0.4,
      });
      expect(prefs.playedOpacity, 0.25);
      expect(prefs.unplayedOpacity, 0.75);
      expect(
        LyricPreferences.sanitizeAnimationValues(<String, Object?>{
          'playedOpacity': 'x',
          'unplayedOpacity': 'y',
        }),
        isEmpty,
      );
    });
  });
}
