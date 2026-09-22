import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/lyric_animation_settings_page.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词动画设置页的「恢复本页默认值」按钮测试。
///
/// 锁定两条契约：
/// 1. 二次确认点「恢复默认」后，本页 6 个参数全部回到默认值；
/// 2. 点「取消」什么都不动。
///
/// 注意：**绝不能**断言 `LyricPreferences.reset()` 的效果——按钮的实现
/// 刻意逐参数恢复，避免把字号/行距/辉光等不在本页的设置一并清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: LyricAnimationSettingsPage()),
    );
    await tester.pumpAndSettle();
  }

  /// 把本页 6 个参数全部设成非默认值（错峰起点开关设为 false）。
  Future<void> setAllNonDefault() async {
    final prefs = LyricPreferences.instance;
    await prefs.setInactiveScale(0.9);
    await prefs.setAlignPosition(0.5);
    await prefs.setLiftHeightPx(8.0);
    await prefs.setCascadeMaxDelayMs(300);
    await prefs.setCascadeBaseStepMs(120);
    await prefs.setCascadeDecayX(1.5);
    await prefs.setStaggerFromCurrentLine(false);
  }

  /// 断言 6 个参数 + 错峰起点开关全部等于默认值。
  void expectAllDefaults() {
    final prefs = LyricPreferences.instance;
    expect(prefs.inactiveScale, equals(LyricPreferences.defaultInactiveScale));
    expect(prefs.alignPosition, equals(LyricPreferences.defaultAlignPosition));
    expect(prefs.liftHeightPx, equals(LyricPreferences.defaultLiftHeightPx));
    expect(prefs.cascadeMaxDelayMs,
        equals(LyricPreferences.defaultCascadeMaxDelayMs));
    expect(prefs.cascadeBaseStepMs,
        equals(LyricPreferences.defaultCascadeBaseStepMs));
    expect(prefs.cascadeDecayX, equals(LyricPreferences.defaultCascadeDecayX));
    expect(prefs.staggerFromCurrentLine,
        equals(LyricPreferences.defaultStaggerFromCurrentLine));
  }

  /// 断言 6 个参数 + 开关仍是非默认值（用于取消路径）。
  void expectAllNonDefault() {
    final prefs = LyricPreferences.instance;
    expect(prefs.inactiveScale, equals(0.9));
    expect(prefs.alignPosition, equals(0.5));
    expect(prefs.liftHeightPx, equals(8.0));
    expect(prefs.cascadeMaxDelayMs, equals(300.0));
    expect(prefs.cascadeBaseStepMs, equals(120.0));
    expect(prefs.cascadeDecayX, equals(1.5));
    expect(prefs.staggerFromCurrentLine, isFalse);
  }

  group('AppBar 重置按钮（恢复本页默认值）', () {
    testWidgets('二次确认点「恢复默认」：本页 6 个参数全部回到默认', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      // 二次确认对话框出现
      expect(find.text('恢复本页默认值'), findsOneWidget);

      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expectAllDefaults();
    });

    testWidgets('二次确认点「取消」：所有参数保持不变', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      expect(find.text('恢复本页默认值'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expectAllNonDefault();
    });

    testWidgets('重置按钮只动本页参数：字号/行距不受影响', (tester) async {
      await pumpPage(tester);
      await setAllNonDefault();
      // 本页之外的参数（字号/行距）预先设成非默认，验证重置不碰它们
      final prefs = LyricPreferences.instance;
      await prefs.setFontSize(33);
      await prefs.setLineSpacing(1.2);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expectAllDefaults();
      expect(prefs.fontSize, equals(33.0)); // 不在本页 → 不被重置
      expect(prefs.lineSpacing, equals(1.2));
    });

    testWidgets('错峰起点开关：切换即写入偏好', (tester) async {
      await pumpPage(tester);
      // 默认开启
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);

      // 开关位于 ListView 末尾，测试视口（800×600）折线以下不构建，先滚进来。
      // scrollUntilVisible 后中心点可能仍差几像素落在视口外（tap 落空），
      // 再用 ensureVisible 对齐到视口内。
      await tester.scrollUntilVisible(find.text('错峰从当前行上方开始'), 300);
      await tester.ensureVisible(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(find.text('错峰从当前行上方开始'), findsOneWidget);

      await tester.tap(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isFalse);

      await tester.tap(find.text('错峰从当前行上方开始'));
      await tester.pumpAndSettle();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
    });
  });
}
