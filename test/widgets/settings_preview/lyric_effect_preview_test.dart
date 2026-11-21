import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/settings_preview/lyric_effect_preview.dart';
import 'package:md3music/widgets/settings_preview/preview_demo_assets.dart';

/// 演示卡里「当前行」固定取中间那行（见 LyricEffectPreview._currentLineIndex）。
final _currentLineText = kPreviewSingleTexts[1];

/// 演示卡按**字**渲染（辉光要逐字控制），故不能按整行 find.text。
/// 这里把一行文案拼回单字列表，用于逐字断言。
List<String> _charsOf(String text) =>
    [for (final r in text.runes) String.fromCharCode(r)];

/// 取某个字的 Text widget 列表（同一行内字号/颜色一致，取第一个即可）。
List<Text> _textsOf(WidgetTester tester, String char) =>
    tester.widgetList<Text>(find.text(char)).toList();

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LyricPreferences.instance.load();
    // 每个用例从干净的偏好开始（单例会被别的用例污染）
    await LyricPreferences.instance.setUseDuetLayout(false);
    await LyricPreferences.instance.setUseGlowEffect(false);
    await LyricPreferences.instance.setUseGaussianBlur(false);
    await LyricPreferences.instance.setUseDynamicLyricColor(false);
    await LyricPreferences.instance.setUseAboveLinesPlayedColor(false);
    await LyricPreferences.instance
        .setDynamicColorMixRatio(LyricPreferences.defaultDynamicColorMixRatio);
  });

  testWidgets('AM 对唱开启时两行左右分列，且不带性别前缀', (tester) async {
    await LyricPreferences.instance.setUseDuetLayout(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    // 男=左、女=右；前缀「男：」「女：」已被剥掉，不进正文。
    // 用两行首字的 x 中心比较（首字即该行最靠近对齐侧的字）。
    final maleFirst = _charsOf(kPreviewDuetTexts[0]).first;
    final femaleFirst = _charsOf(kPreviewDuetTexts[1]).first;
    expect(_textsOf(tester, maleFirst), isNotEmpty);
    expect(_textsOf(tester, femaleFirst), isNotEmpty);

    // 两行首字都出现且 x 不同（一个靠左、一个靠右）
    final maleX = tester.getCenter(find.text(maleFirst).first).dx;
    final femaleX = tester.getCenter(find.text(femaleFirst).first).dx;
    expect(maleX != femaleX, isTrue, reason: '对唱两行不应重叠在同一 x');

    // 非对唱的第三行不应出现（对唱态只有两行）
    expect(
      _textsOf(tester, _charsOf(kPreviewSingleTexts[2]).first),
      isEmpty,
      reason: '对唱态不应出现第三行单列歌词',
    );
  });

  testWidgets('关闭对唱时渲染三行单列', (tester) async {
    await LyricPreferences.instance.setUseDuetLayout(false);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    // 三行的首字都应渲染
    for (final line in kPreviewSingleTexts) {
      expect(
        _textsOf(tester, _charsOf(line).first),
        isNotEmpty,
        reason: '三行单列都应渲染：$line',
      );
    }
  });

  testWidgets('MD3 风格下不演示 AM 专属开关（对唱/辉光/模糊）', (tester) async {
    // 三个 AM 开关全开，但 isAmStyle=false 时演示卡必须忽略它们
    await LyricPreferences.instance.setUseDuetLayout(true);
    await LyricPreferences.instance.setUseGlowEffect(true);
    await LyricPreferences.instance.setUseGaussianBlur(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: false),
          ),
        ),
      ),
    );
    await tester.pump();

    // 对唱的两行不应出现（MD3 不演示对唱）
    expect(
      _textsOf(tester, _charsOf(kPreviewDuetTexts[0]).first),
      isEmpty,
    );
    expect(find.text('当前：Material 风格'), findsOne);
  });

  testWidgets('高斯模糊只作用于非当前行，当前行恒清晰', (tester) async {
    await LyricPreferences.instance.setUseGaussianBlur(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    // 当前行首字不被 ImageFiltered 包裹
    final currentFirst = _charsOf(_currentLineText).first;
    final currentInFilter = find.ancestor(
      of: find.text(currentFirst).first,
      matching: find.byType(ImageFiltered),
    );
    expect(currentInFilter, findsNothing, reason: '当前行必须清晰可作对比');

    // 上下两行首字被 ImageFiltered 包裹
    for (final other in [
      kPreviewSingleTexts[0],
      kPreviewSingleTexts[2],
    ]) {
      final otherFirst = _charsOf(other).first;
      final otherInFilter = find.ancestor(
        of: find.text(otherFirst).first,
        matching: find.byType(ImageFiltered),
      );
      expect(otherInFilter, findsOne, reason: '$other 应被模糊');
    }
  });

  testWidgets('辉光只给当前行的第一个字，同行其余字不发光', (tester) async {
    await LyricPreferences.instance.setUseGlowEffect(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    final currentChars = _charsOf(_currentLineText);
    expect(currentChars.length, greaterThan(1));

    // 第一个字带 shadow（辉光），第二个字不带
    final firstTexts = _textsOf(tester, currentChars[0]);
    final secondTexts = _textsOf(tester, currentChars[1]);
    expect(firstTexts, isNotEmpty);
    expect(secondTexts, isNotEmpty);

    expect(
      firstTexts.first.style?.shadows?.isNotEmpty ?? false,
      isTrue,
      reason: '当前行第一个字应有辉光',
    );
    expect(
      secondTexts.first.style?.shadows?.isNotEmpty ?? false,
      isFalse,
      reason: '同行其余字不应整行发光',
    );
  });

  testWidgets('辉光强度倍数直接作用在演示卡阴影 alpha 上', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setUseGlowEffect(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    final glowChar = _charsOf(_currentLineText).first;
    double? firstShadowAlpha() {
      final texts = _textsOf(tester, glowChar);
      final shadows = texts.first.style?.shadows;
      return shadows == null || shadows.isEmpty ? null : shadows.first.color.a;
    }

    final atDefault = firstShadowAlpha();
    expect(atDefault, isNotNull, reason: '当前行首字应有辉光阴影');
    // 默认 100%：每层一条阴影（三层剖面）
    expect(
      _textsOf(tester, glowChar).first.style!.shadows!.length,
      equals(3),
    );

    // 强度 200% → 最内层权重 0.55 × 2 = 1.1 > 1，拆成「饱和 1.0 + 追加 0.1」
    await prefs.setGlowIntensity(2.0);
    await tester.pump();
    final shadowsAtMax = _textsOf(tester, glowChar).first.style!.shadows!;
    expect(
      shadowsAtMax.length,
      greaterThan(3),
      reason: '超过 100% 的强度必须有追加层，否则亮度封顶不再变化',
    );
    expect(shadowsAtMax.first.color.a, equals(1.0));
    expect(shadowsAtMax[1].color.a, closeTo(0.1, 1e-6));

    // 强度减半 → 阴影 alpha 减半
    await prefs.setGlowIntensity(0.5);
    await tester.pump();
    final atHalf = firstShadowAlpha();
    expect(atHalf, isNotNull);
    expect(atHalf!, closeTo(atDefault! * 0.5, 1e-6));
  });

  testWidgets('浅色主题下不出现整片白字', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final currentFirst = _charsOf(_currentLineText).first;
    expect(_textsOf(tester, currentFirst), isNotEmpty);
  });

  testWidgets('上方行使用已播颜色：开启后与普通背景行不同色，关闭后恢复', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setUseDynamicLyricColor(true);
    await prefs.setUseAboveLinesPlayedColor(true);
    await prefs.setDynamicColorMixRatio(0.5);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: LyricEffectPreview(isAmStyle: true),
          ),
        ),
      ),
    );
    await tester.pump();

    // 第 0 行 = 当前行上方（已唱）；第 2 行 = 当前行下方（待唱，仍是背景色）。
    final aboveFirst = _charsOf(kPreviewSingleTexts[0]).first;
    final belowFirst = _charsOf(kPreviewSingleTexts[2]).first;
    final aboveTexts = _textsOf(tester, aboveFirst);
    expect(aboveTexts, isNotEmpty);
    final Color playedColor = aboveTexts.first.style!.color!;
    final Color plainColor =
        _textsOf(tester, belowFirst).first.style!.color!;
    expect(playedColor, isNot(equals(plainColor)),
        reason: '开关开启后上方行必须改用已播色');

    await prefs.setUseAboveLinesPlayedColor(false);
    await tester.pump();
    expect(
      _textsOf(tester, aboveFirst).first.style!.color,
      equals(plainColor),
      reason: '关闭开关后上方行回到普通背景色',
    );
  });
}
