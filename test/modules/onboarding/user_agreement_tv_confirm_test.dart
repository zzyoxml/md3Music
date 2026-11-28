import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/onboarding/user_agreement_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户协议页 TV 焦点回归（2026-11-10）。
///
/// **现象**：TV 版进入用户协议页，遥控器无法选中「下一步」。
///
/// **根因**：页面打开时默认勾选，dpad 首停点落在勾选框（阅读顺序最靠上）。
/// 遥控器按 OK 会把它**取消**勾选，而确认按钮此时是
/// `onPressed: _agreed ? _onAgree : null`，禁用按钮的 `canRequestFocus`
/// 为 false，焦点再也落不到按钮上 —— 唯一停点只剩勾选框。
///
/// **修法**：按钮恒可点，按下即自动勾选并同意；TV 上按钮 `autofocus`，
/// 主动作拿首焦点。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpPage(
    WidgetTester tester, {
    required VoidCallback onAgreed,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<CarModeProvider>(
            create: (_) => CarModeProvider(),
          ),
        ],
        child: MaterialApp(
          home: UserAgreementPage(onAgreed: onAgreed),
        ),
      ),
    );
    await tester.pump();
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  testWidgets('取消勾选后确认按钮仍可聚焦，按下即自动同意', (tester) async {
    var agreedCalls = 0;
    await pumpPage(tester, onAgreed: () => agreedCalls++);

    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isTrue,
      reason: '协议页默认勾选',
    );

    // 模拟遥控器在勾选框上按 OK：勾选被取消
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

    // 核心回归：未勾选时按钮不得禁用（禁用按钮在 TV 上不可聚焦）
    expect(
      confirmButton(tester).onPressed,
      isNotNull,
      reason: '禁用按钮 canRequestFocus=false，遥控器无法选中「下一步」',
    );

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(agreedCalls, 1, reason: '按下确认应直接进入下一步');
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isTrue,
      reason: '按下确认应自动补勾，视为同意协议',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('user_agreement_accepted_v1'), isTrue);
  });
}
