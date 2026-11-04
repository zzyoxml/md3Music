import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「歌词模糊强度」参数的单元测试。
///
/// 锁定三件事：
/// 1. 默认值必须为 1.0（等于历史行为：sigma = 距离分级值，观感不得变）；
/// 2. 越界输入被 clamp 到声明范围；
/// 3. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('歌词模糊强度 blurIntensity', () {
    test('默认 1.0（等于历史行为，观感不变）', () {
      expect(LyricPreferences.instance.blurIntensity,
          equals(LyricPreferences.defaultBlurIntensity));
      expect(LyricPreferences.instance.blurIntensity, equals(1.0));
    });

    test('setter 生效并 clamp 到 [0.5, 2.0]', () async {
      await LyricPreferences.instance.setBlurIntensity(1.6);
      expect(LyricPreferences.instance.blurIntensity, equals(1.6));

      await LyricPreferences.instance.setBlurIntensity(99);
      expect(LyricPreferences.instance.blurIntensity,
          equals(LyricPreferences.maxBlurIntensity));

      await LyricPreferences.instance.setBlurIntensity(0.1);
      expect(LyricPreferences.instance.blurIntensity,
          equals(LyricPreferences.minBlurIntensity));
    });

    test('持久化到 lyric_blur_intensity', () async {
      await LyricPreferences.instance.setBlurIntensity(1.4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_blur_intensity'), equals(1.4));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setBlurIntensity(1.8);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.blurIntensity,
          equals(LyricPreferences.defaultBlurIntensity));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_blur_intensity'), isNull);
    });
  });
}
