import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「动态赋色方式」（整行赋色 / 渐变赋色）的单元测试。
///
/// 锁定四件事：
/// 1. 默认必须为 lineUniform（= 历史行为：整行统一混色，升级后观感不变）；
/// 2. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）；
/// 3. load() 只认 'wordGradient'，null / 未知串一律回落 lineUniform；
/// 4. reset 后回到默认值且 key 被移除；本开关不进动画预设参数表。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('动态赋色方式 fillStyle', () {
    test('默认 lineUniform（等于历史行为，观感不变）', () {
      expect(
        LyricPreferences.instance.fillStyle,
        equals(LyricFillStyle.lineUniform),
      );
    });

    test('setter 生效并落盘到 lyric_fill_style', () async {
      await LyricPreferences.instance.setFillStyle(
        LyricFillStyle.wordGradient,
      );
      expect(LyricPreferences.instance.fillStyle, LyricFillStyle.wordGradient);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_style'), 'wordGradient');

      await LyricPreferences.instance.setFillStyle(LyricFillStyle.lineUniform);
      expect(LyricPreferences.instance.fillStyle, LyricFillStyle.lineUniform);
      expect(prefs.getString('lyric_fill_style'), 'lineUniform');
    });

    test('load() 从持久值恢复 wordGradient', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lyric_fill_style', 'wordGradient');

      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.fillStyle, LyricFillStyle.wordGradient);
    });

    test('load() 对 null / 未知串一律回落 lineUniform', () async {
      // 无存储值：默认 lineUniform
      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.fillStyle, LyricFillStyle.lineUniform);

      // 未知枚举串不得崩溃或误命中（对照 _fillModeFromName 的经典回退口径）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lyric_fill_style', 'bogus');
      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.fillStyle, LyricFillStyle.lineUniform);
    });

    test('值未变化时不重复通知监听者', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      // 默认已是 lineUniform，再设同值应早退
      await LyricPreferences.instance.setFillStyle(LyricFillStyle.lineUniform);
      expect(notified, 0);

      await LyricPreferences.instance.setFillStyle(
        LyricFillStyle.wordGradient,
      );
      expect(notified, 1);
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setFillStyle(
        LyricFillStyle.wordGradient,
      );
      await LyricPreferences.instance.reset();
      expect(
        LyricPreferences.instance.fillStyle,
        equals(LyricFillStyle.lineUniform),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_style'), isNull);
    });

    test('不进动画预设参数表（预设契约保持 20 项）', () {
      expect(
        LyricPreferences.animationValueKeys.contains('fillStyle'),
        isFalse,
      );
      expect(
        LyricPreferences.sanitizeAnimationValues(<String, Object>{
          'fillStyle': 'wordGradient',
        }),
        isEmpty,
      );
    });

    // ==================== backgroundBloom（背景增透，2026-11-22） ====================

    test('backgroundBloom：标签 / setter 落盘 / reset 清 key', () async {
      expect(lyricFillStyleLabel(LyricFillStyle.backgroundBloom), '背景增透');

      await LyricPreferences.instance.setFillStyle(
        LyricFillStyle.backgroundBloom,
      );
      expect(
        LyricPreferences.instance.fillStyle,
        LyricFillStyle.backgroundBloom,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_style'), 'backgroundBloom');

      // 枚举成员完整性：三选一，且 label 三条齐全（设置页下拉依赖 values）
      expect(LyricFillStyle.values.length, 3);
      for (final style in LyricFillStyle.values) {
        expect(lyricFillStyleLabel(style), isNotEmpty);
      }
      // 未知串回落由主组 'load() 对 bogus 一律回落 lineUniform' 锁定；
      // 精确串命中是 switch 直接映射，setter 往返已覆盖持久化口径；
      // （load() 有 _loaded 早退守卫，单例进程内不可二次加载，故此处不重复走 load）
    });

    test('reset 后 backgroundBloom 回落默认且 key 被移除', () async {
      await LyricPreferences.instance.setFillStyle(
        LyricFillStyle.backgroundBloom,
      );
      await LyricPreferences.instance.reset();
      expect(
        LyricPreferences.instance.fillStyle,
        equals(LyricFillStyle.lineUniform),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_style'), isNull);
    });
  });
}