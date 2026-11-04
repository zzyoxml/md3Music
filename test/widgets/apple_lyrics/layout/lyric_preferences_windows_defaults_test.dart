import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows AM 歌词首次加载与重置使用截图默认值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 已保存的用户值仍优先于平台默认值。
      'lyric_font_size': 44.0,
      'lyric_align_position': 0.3,
    });

    final prefs = LyricPreferences.instance;
    await prefs.load();

    if (!Platform.isWindows) return;

    expect(prefs.fontSize, 44);
    expect(prefs.alignPosition, 0.3);
    expect(prefs.lineSpacing, 1.0);
    expect(prefs.fontWeightValue, 900);
    expect(prefs.fontSource, LyricFontSource.system);
    expect(prefs.customTextColor, isNull);
    expect(prefs.inactiveScale, 0.850);
    expect(prefs.cascadeDecayX, 1.1);
    expect(prefs.staggerFromCurrentLine, isTrue);

    await prefs.reset();

    expect(prefs.fontSize, 50);
    expect(prefs.lineSpacing, 1.0);
    expect(prefs.fontWeightValue, 900);
    expect(prefs.fontSource, LyricFontSource.system);
    expect(prefs.customTextColor, isNull);
    expect(prefs.inactiveScale, 0.850);
    expect(prefs.alignPosition, 0.45);
    expect(prefs.liftHeightPx, 2.5);
    expect(prefs.cascadeMaxDelayMs, 990);
    expect(prefs.cascadeBaseStepMs, 80);
    expect(prefs.cascadeDecayX, 1.1);
    expect(prefs.staggerFromCurrentLine, isTrue);
  }, skip: !Platform.isWindows);
}
