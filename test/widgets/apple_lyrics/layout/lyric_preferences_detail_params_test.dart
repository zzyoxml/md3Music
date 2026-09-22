import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「已播字上浮高度」参数的单元测试。
///
/// 锁定三件事：
/// 1. 默认值必须等于历史写死值 3.0（默认观感不得变）；
/// 2. 越界输入被 clamp 到声明范围；
/// 3. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('① 已播字上浮高度 liftHeightPx', () {
    test('默认 3.0（等于历史写死值 3px）', () {
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPx));
      expect(LyricPreferences.instance.liftHeightPx, equals(3.0));
    });

    test('setter 生效并 clamp 到 [0.0, 10.0]', () async {
      await LyricPreferences.instance.setLiftHeightPx(6.5);
      expect(LyricPreferences.instance.liftHeightPx, equals(6.5));

      await LyricPreferences.instance.setLiftHeightPx(999);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.maxLiftHeightPx));

      await LyricPreferences.instance.setLiftHeightPx(-5);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.minLiftHeightPx));
    });

    test('持久化到 lyric_lift_height_px', () async {
      await LyricPreferences.instance.setLiftHeightPx(4.5);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), equals(4.5));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setLiftHeightPx(9);

      await LyricPreferences.instance.reset();

      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPx));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), isNull);
    });
  });

  group('④ 级联错峰起点 staggerFromCurrentLine', () {
    test('默认 true（从当前行开始错峰）', () {
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      expect(LyricPreferences.instance.staggerFromCurrentLine,
          equals(LyricPreferences.defaultStaggerFromCurrentLine));
    });

    test('setter 落盘到 lyric_stagger_from_current', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      expect(LyricPreferences.instance.staggerFromCurrentLine, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isFalse);
    });

    test('reset 后回到默认 true 且 key 被移除', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isNull);
    });
  });
}
