import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_default_font.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词字体链路：Windows 的「系统默认」档必须落到便携包内置思源黑体。
///
/// 歌词走 TextPainter + Canvas 直绘，不继承 `ThemeData.fontFamily`，所以
/// 「还原所有设置」把字体来源键删回 system 之后，若歌词侧没接内置字体就会
/// 掉到引擎兜底字形（与全局 UI 不同族，表现为只有歌词字体变丑）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 歌词默认档/还原后/自定义失败均使用内置字体', () async {
    final source = File('windows/runner/fonts/SOURCEHANSANSCN-MEDIUM.OTF');
    expect(source.existsSync(), isTrue);
    await WindowsDefaultFont.load(fontFilePath: source.absolute.path);
    expect(WindowsDefaultFont.loadedFamily, WindowsDefaultFont.family);

    final am = LyricPreferences.instance;
    final md3 = Md3LyricPreferences.instance;

    // ① 全新安装：字体来源键缺失 → system 档用内置字体
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await am.load();
    await md3.load();
    expect(am.fontSource, LyricFontSource.system);
    expect(md3.fontSource, Md3LyricFontSource.system);
    expect(am.effectiveFontFamily, WindowsDefaultFont.family);
    expect(md3.effectiveFontFamily, WindowsDefaultFont.family);
    // system 档不得被误判成「自定义字体已加载」
    expect(am.customFontLoaded, isFalse);
    expect(md3.customFontLoaded, isFalse);

    // ② 自定义字体加载失败（路径不存在）→ 降级到内置字体，而不是引擎兜底
    const missing = r'C:\md3music_test_missing_font.ttf';
    await am.setCustomFontPath(missing);
    await am.setFontSource(LyricFontSource.custom);
    await md3.setCustomFontPath(missing);
    await md3.setFontSource(Md3LyricFontSource.custom);
    expect(am.customFontLoaded, isFalse);
    expect(md3.customFontLoaded, isFalse);
    expect(am.effectiveFontFamily, WindowsDefaultFont.family);
    expect(md3.effectiveFontFamily, WindowsDefaultFont.family);

    // ③ 还原所有设置（两个 reset 由 WindowsSettingsRuntime.reset 调用）
    await am.reset();
    await md3.reset();
    expect(am.fontSource, LyricFontSource.system);
    expect(md3.fontSource, Md3LyricFontSource.system);
    expect(am.effectiveFontFamily, WindowsDefaultFont.family);
    expect(md3.effectiveFontFamily, WindowsDefaultFont.family);
  }, skip: !Platform.isWindows);

  test('非 Windows 的 system 档保持 null（走系统字体链）', () async {
    // 平台门控回归：WindowsDefaultFont 在非 Windows 恒不加载，
    // 歌词 system 档必须仍是 null，Android/TV 渲染行为零变化。
    expect(WindowsDefaultFont.loadedFamily, isNull);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.load();
    await Md3LyricPreferences.instance.load();
    expect(LyricPreferences.instance.effectiveFontFamily, isNull);
    expect(Md3LyricPreferences.instance.effectiveFontFamily, isNull);
  }, skip: Platform.isWindows);
}
