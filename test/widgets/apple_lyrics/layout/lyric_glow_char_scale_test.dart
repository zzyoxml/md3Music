import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「辉光字符缩放」开关的单元测试。
///
/// 锁定三件事：
/// 1. 默认必须为 true（= 历史行为：凸起放大 + 左右外扩，升级后观感不变）；
/// 2. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）；
/// 3. reset 后回到默认值且 key 被移除。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('辉光字符缩放 useGlowCharScale', () {
    test('默认 true（等于历史行为，观感不变）', () {
      expect(
        LyricPreferences.instance.useGlowCharScale,
        equals(LyricPreferences.defaultGlowCharScale),
      );
      expect(LyricPreferences.instance.useGlowCharScale, isTrue);
    });

    test('setter 生效并落盘到 lyric_glow_char_scale', () async {
      await LyricPreferences.instance.setUseGlowCharScale(false);
      expect(LyricPreferences.instance.useGlowCharScale, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_glow_char_scale'), isFalse);

      await LyricPreferences.instance.setUseGlowCharScale(true);
      expect(LyricPreferences.instance.useGlowCharScale, isTrue);
      expect(prefs.getBool('lyric_glow_char_scale'), isTrue);
    });

    test('值未变化时不重复通知监听者', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      // 默认已是 true，再设 true 应早退
      await LyricPreferences.instance.setUseGlowCharScale(true);
      expect(notified, 0);

      await LyricPreferences.instance.setUseGlowCharScale(false);
      expect(notified, 1);
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setUseGlowCharScale(false);
      await LyricPreferences.instance.reset();
      expect(
        LyricPreferences.instance.useGlowCharScale,
        equals(LyricPreferences.defaultGlowCharScale),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_glow_char_scale'), isNull);
    });
  });
}
