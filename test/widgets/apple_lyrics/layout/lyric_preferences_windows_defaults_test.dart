import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 便携版歌词动画首次加载与重置使用新默认值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 已保存的用户值仍优先于平台默认值。
      'lyric_font_size': 44.0,
      'lyric_align_position': 0.3,
      // 历史脏值：load() 应按当前平台范围 clamp，而非丢弃。
      'lyric_cascade_max_delay_ms': 2500.0,
      'lyric_glow_fixed_threshold_ms': 1500.0,
      'lyric_line_spacing': 9.0,
    });

    final prefs = LyricPreferences.instance;
    await prefs.load();

    if (!Platform.isWindows) return;

    expect(prefs.fontSize, 44);
    expect(prefs.alignPosition, 0.3);
    // 9.0 超出 Windows 新上限 1.2 → clamp
    expect(prefs.lineSpacing,
        LyricPreferences.maxLineSpacingForCurrentPlatform);
    expect(prefs.fontWeightValue, 900);
    expect(prefs.fontSource, LyricFontSource.system);
    expect(prefs.customTextColor, isNull);
    // 2500 超出 Windows 上限 → clamp；1500 超出上限 → clamp。
    expect(prefs.cascadeMaxDelayMs,
        LyricPreferences.maxCascadeMaxDelayMsForCurrentPlatform);
    expect(prefs.glowFixedThresholdMs,
        LyricPreferences.maxGlowFixedThresholdMsForCurrentPlatform);
    expect(prefs.staggerFromCurrentLine, isTrue);

    await prefs.reset();

    // 「歌词显示」面板三项：用户实调值即默认（50px / 黑体 900 / 0.8×）。
    expect(prefs.fontSize, 50);
    expect(prefs.fontWeightValue, 900);
    expect(prefs.lineSpacing, 0.8);
    expect(prefs.fontSource, LyricFontSource.system);
    expect(prefs.customTextColor, isNull);
    expect(prefs.staggerFromCurrentLine, isTrue);

    // 字号与行距：默认值必须落在范围正中，两侧均可自由调。
    expect(prefs.fontSize,
        equals(LyricPreferences.defaultFontSizeForCurrentPlatform));
    expect(
      (LyricPreferences.minFontSizeForCurrentPlatform +
              LyricPreferences.maxFontSizeForCurrentPlatform) /
          2,
      closeTo(LyricPreferences.defaultFontSizeForCurrentPlatform, 1e-9),
    );
    expect(prefs.lineSpacing,
        equals(LyricPreferences.defaultLineSpacingForCurrentPlatform));
    expect(
      (LyricPreferences.minLineSpacingForCurrentPlatform +
              LyricPreferences.maxLineSpacingForCurrentPlatform) /
          2,
      closeTo(LyricPreferences.defaultLineSpacingForCurrentPlatform, 1e-9),
    );

    // 字重：900 已是 FontWeight 可用的最高档，只能占满 300~900 全档，
    // 无法数学居中（滑块离散步进 100）。
    expect(prefs.fontWeightValue,
        equals(LyricPreferences.defaultFontWeightForCurrentPlatform));
    expect(LyricPreferences.minFontWeightForCurrentPlatform, 300);
    expect(LyricPreferences.maxFontWeightForCurrentPlatform, 900);

    // 各参数 reset 后必须等于「当前平台默认」，且默认值落在范围正中（能两侧自由调）。
    void expectCentered(double value, double lo, double hi, double mid) {
      expect(value, equals(mid));
      expect(mid, closeTo((lo + hi) / 2, 1e-9));
    }

    // 快照：用户按截图确认的新中轴值（0.80 / 1.7 / 0 / 0 / 1.00）。
    // 非当前行缩放：范围 0~1 全覆盖，默认 0.60（用户指定）。
    expect(prefs.inactiveScale, 0.60);
    expect(LyricPreferences.minInactiveScaleForCurrentPlatform, 0.0);
    expect(LyricPreferences.maxInactiveScaleForCurrentPlatform, 1.0);
    expect(LyricPreferences.defaultInactiveScaleForCurrentPlatform, 0.60);

    expectCentered(
      prefs.alignPosition,
      LyricPreferences.minAlignPositionForCurrentPlatform,
      LyricPreferences.maxAlignPositionForCurrentPlatform,
      LyricPreferences.defaultAlignPositionForCurrentPlatform,
    );
    expect(prefs.alignPosition, 0.35);

    expectCentered(
      prefs.liftHeightPx,
      LyricPreferences.minLiftHeightPxForCurrentPlatform,
      LyricPreferences.maxLiftHeightPxForCurrentPlatform,
      LyricPreferences.defaultLiftHeightPxForCurrentPlatform,
    );
    expect(prefs.liftHeightPx, 1.7);

    expectCentered(
      prefs.interludeDotsStartX,
      LyricPreferences.minInterludeDotsStartXForCurrentPlatform,
      LyricPreferences.maxInterludeDotsStartXForCurrentPlatform,
      LyricPreferences.defaultInterludeDotsStartXForCurrentPlatform,
    );
    expect(prefs.interludeDotsStartX, 1.5);

    expectCentered(
      prefs.interludeDotRadius,
      LyricPreferences.minInterludeDotRadiusForCurrentPlatform,
      LyricPreferences.maxInterludeDotRadiusForCurrentPlatform,
      LyricPreferences.defaultInterludeDotRadiusForCurrentPlatform,
    );
    expect(prefs.interludeDotRadius, 0.18);

    expectCentered(
      prefs.interludeDotSpacing,
      LyricPreferences.minInterludeDotSpacingForCurrentPlatform,
      LyricPreferences.maxInterludeDotSpacingForCurrentPlatform,
      LyricPreferences.defaultInterludeDotSpacingForCurrentPlatform,
    );
    expect(prefs.interludeDotSpacing, 0.90);

    // 错峰三项：默认 990 / 80 / 1.00 同样必须落在范围正中。
    expectCentered(
      prefs.cascadeMaxDelayMs,
      LyricPreferences.minCascadeMaxDelayMsForCurrentPlatform,
      LyricPreferences.maxCascadeMaxDelayMsForCurrentPlatform,
      LyricPreferences.defaultCascadeMaxDelayMsForCurrentPlatform,
    );
    expect(prefs.cascadeMaxDelayMs, 990);
    expect(LyricPreferences.minCascadeMaxDelayMsForCurrentPlatform, 0);
    expect(LyricPreferences.maxCascadeMaxDelayMsForCurrentPlatform, 1980);

    expectCentered(
      prefs.cascadeBaseStepMs,
      LyricPreferences.minCascadeBaseStepMsForCurrentPlatform,
      LyricPreferences.maxCascadeBaseStepMsForCurrentPlatform,
      LyricPreferences.defaultCascadeBaseStepMsForCurrentPlatform,
    );
    expect(prefs.cascadeBaseStepMs, 80);
    expect(LyricPreferences.minCascadeBaseStepMsForCurrentPlatform, 0);
    expect(LyricPreferences.maxCascadeBaseStepMsForCurrentPlatform, 160);

    expectCentered(
      prefs.cascadeDecayX,
      LyricPreferences.minCascadeDecayXForCurrentPlatform,
      LyricPreferences.maxCascadeDecayXForCurrentPlatform,
      LyricPreferences.defaultCascadeDecayXForCurrentPlatform,
    );
    expect(prefs.cascadeDecayX, 1.0);
    expect(LyricPreferences.minCascadeDecayXForCurrentPlatform, 0.5);
    expect(LyricPreferences.maxCascadeDecayXForCurrentPlatform, 1.5);

    expectCentered(
      prefs.blurIntensity,
      LyricPreferences.minBlurIntensityForCurrentPlatform,
      LyricPreferences.maxBlurIntensityForCurrentPlatform,
      LyricPreferences.defaultBlurIntensityForCurrentPlatform,
    );
    expect(prefs.blurIntensity, 1.0);

    expectCentered(
      prefs.dynamicColorMixRatio,
      LyricPreferences.minDynamicColorMixRatioForCurrentPlatform,
      LyricPreferences.maxDynamicColorMixRatioForCurrentPlatform,
      LyricPreferences.defaultDynamicColorMixRatioForCurrentPlatform,
    );
    expect(prefs.dynamicColorMixRatio, 0.15);

    expectCentered(
      prefs.glowIntensity,
      LyricPreferences.minGlowIntensityForCurrentPlatform,
      LyricPreferences.maxGlowIntensityForCurrentPlatform,
      LyricPreferences.defaultGlowIntensityForCurrentPlatform,
    );
    expect(prefs.glowIntensity, 1.0);

    expectCentered(
      prefs.glowThresholdFactor,
      LyricPreferences.minGlowThresholdFactorForCurrentPlatform,
      LyricPreferences.maxGlowThresholdFactorForCurrentPlatform,
      LyricPreferences.defaultGlowThresholdFactorForCurrentPlatform,
    );
    expect(prefs.glowThresholdFactor, 1.2);

    expectCentered(
      prefs.glowFixedThresholdMs,
      LyricPreferences.minGlowFixedThresholdMsForCurrentPlatform,
      LyricPreferences.maxGlowFixedThresholdMsForCurrentPlatform,
      LyricPreferences.defaultGlowFixedThresholdMsForCurrentPlatform,
    );
    expect(prefs.glowFixedThresholdMs, 500);

    // 已播 / 未播歌词透明度：alpha 物理上限为 1.0，不套用「默认居中」约定，
    // 故这里只断言默认值与范围，不调用 expectCentered。
    expect(prefs.playedOpacity, 1.0);
    expect(prefs.unplayedOpacity, 0.4);
    expect(LyricPreferences.minPlayedOpacityForCurrentPlatform, 0.0);
    expect(LyricPreferences.maxPlayedOpacityForCurrentPlatform, 1.0);
    expect(LyricPreferences.minUnplayedOpacityForCurrentPlatform, 0.0);
    expect(LyricPreferences.maxUnplayedOpacityForCurrentPlatform, 1.0);
  }, skip: !Platform.isWindows);
}
