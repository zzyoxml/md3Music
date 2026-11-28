import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「渐变赋色取色浓度」（过曝轨迹混白比例）的单元测试。
///
/// 锁定四件事：
/// 1. 默认必须为 0.5（取色与白各半，范围正中）——纯取色太鲜艳，用户
///    2026-11-20 反馈，先压到 75%，随后放开 0~100 并把默认落回中轴；
/// 2. setter 落盘到约定的 SharedPreferences key，且越界值被钳制到
///    [0, 1]（下界同日从 0.5 放开：不取色的极端档）；
/// 3. load() 从持久值恢复；
/// 4. reset 后回到默认值且 key 被移除；本参数不进动画预设参数表。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('渐变赋色取色浓度 gradientFillRatio', () {
    test('默认 0.5（取色与白各半，范围正中）', () {
      expect(
        LyricPreferences.instance.gradientFillRatio,
        equals(LyricPreferences.defaultGradientFillRatio),
      );
      expect(LyricPreferences.instance.gradientFillRatio, closeTo(0.5, 1e-9));
    });

    test('setter 生效并落盘到 lyric_gradient_fill_ratio，越界钳制', () async {
      await LyricPreferences.instance.setGradientFillRatio(1.0);
      expect(LyricPreferences.instance.gradientFillRatio, 1.0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_gradient_fill_ratio'), 1.0);

      // 越界：低于 0 钳到 0（不取色），高于 1.0 钳到 1.0
      await LyricPreferences.instance.setGradientFillRatio(0.2);
      expect(LyricPreferences.instance.gradientFillRatio, 0.2,
          reason: '0.2 已在新下界 0 之上，不再被钳制');
      await LyricPreferences.instance.setGradientFillRatio(-0.5);
      expect(LyricPreferences.instance.gradientFillRatio, 0.0,
          reason: '下界放开为 0：负数钳到 0（纯白光核）');
      await LyricPreferences.instance.setGradientFillRatio(1.5);
      expect(LyricPreferences.instance.gradientFillRatio, 1.0);

      // 回到区间内可正常取值（50% 半半混、0% 不取色）
      await LyricPreferences.instance.setGradientFillRatio(0.6);
      expect(LyricPreferences.instance.gradientFillRatio, 0.6);
    });

    test('0% = 不取色：渲染侧 raw 通道回落纯白', () async {
      await LyricPreferences.instance.setGradientFillRatio(0.0);
      expect(
        WordRenderer.mixWithWhiteForTest(
          51,
          LyricPreferences.instance.gradientFillRatio,
        ),
        255,
        reason: 'ratio=0 时取色浓度为零，混白结果恒为纯白',
      );
    });

    test('load() 从持久值恢复', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lyric_gradient_fill_ratio', 0.55);
      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.gradientFillRatio, 0.55);
    });

    test('值未变化时不重复通知监听者', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      // 默认已是 0.5，再设同值应早退
      await LyricPreferences.instance.setGradientFillRatio(0.5);
      expect(notified, 0);

      await LyricPreferences.instance.setGradientFillRatio(0.9);
      expect(notified, 1);
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setGradientFillRatio(0.6);
      await LyricPreferences.instance.reset();
      expect(
        LyricPreferences.instance.gradientFillRatio,
        equals(LyricPreferences.defaultGradientFillRatio),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_gradient_fill_ratio'), isNull);
    });

    test('不进动画预设参数表（预设契约保持不变）', () {
      expect(
        LyricPreferences.animationValueKeys.contains('gradientFillRatio'),
        isFalse,
      );
      expect(
        LyricPreferences.sanitizeAnimationValues(<String, Object>{
          'gradientFillRatio': 0.8,
        }),
        isEmpty,
      );
    });
  });
}