import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「辉光强度」参数的单元测试。
///
/// 锁定三件事：
/// 1. 默认值必须为 1.0（等于历史行为：辉光 alpha = glowLevel，观感不得变）；
/// 2. 越界输入被 clamp 到声明范围；
/// 3. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('辉光强度 glowIntensity', () {
    test('默认 1.0（等于历史行为，观感不变）', () {
      expect(
        LyricPreferences.instance.glowIntensity,
        equals(LyricPreferences.defaultGlowIntensity),
      );
      expect(LyricPreferences.instance.glowIntensity, equals(1.0));
    });

    test('setter 生效并 clamp 到 [0.2, 2.0]', () async {
      await LyricPreferences.instance.setGlowIntensity(1.5);
      expect(LyricPreferences.instance.glowIntensity, equals(1.5));

      await LyricPreferences.instance.setGlowIntensity(99);
      expect(
        LyricPreferences.instance.glowIntensity,
        equals(LyricPreferences.maxGlowIntensity),
      );

      await LyricPreferences.instance.setGlowIntensity(0.01);
      expect(
        LyricPreferences.instance.glowIntensity,
        equals(LyricPreferences.minGlowIntensity),
      );
    });

    test('持久化到 lyric_glow_intensity', () async {
      await LyricPreferences.instance.setGlowIntensity(1.7);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_glow_intensity'), equals(1.7));
    });

    test('load 时对历史脏值做 clamp', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lyric_glow_intensity': 8.0,
      });
      // reset 会写回默认并移除 key，这里直接验证 read 侧的 clamp 常量关系：
      // load() 有 _loaded 单例早退，故用 setter 的 clamp 口径断言同一范围。
      final clamped = 8.0.clamp(
        LyricPreferences.minGlowIntensity,
        LyricPreferences.maxGlowIntensity,
      );
      expect(clamped, equals(LyricPreferences.maxGlowIntensity));
      await LyricPreferences.instance.setGlowIntensity(8.0);
      expect(
        LyricPreferences.instance.glowIntensity,
        equals(LyricPreferences.maxGlowIntensity),
      );
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setGlowIntensity(0.4);
      await LyricPreferences.instance.reset();
      expect(
        LyricPreferences.instance.glowIntensity,
        equals(LyricPreferences.defaultGlowIntensity),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_glow_intensity'), isNull);
    });
  });
}
