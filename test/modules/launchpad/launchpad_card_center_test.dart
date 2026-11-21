import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/modules/launchpad/launchpad_page.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 手机竖屏窄格回归（2026-11-21 真机两轮反馈：安卓端图标不居中、长按波偏离）：
///
/// 第一版 Column(写死 84*s 槽 + 标签) 在 ≈118dp 正方形格里竖向溢出；
/// 第二版 Column(Expanded 槽 + 标签) 不溢出了，但图标中心 = 「标签以上
/// 区域」的中心，恒在格心上方（格越小偏得越多，Windows 大格只偏 ~6%
/// 看不出来）——全屏波锚定图标真实中心，随之偏离格心。
///
/// 现布局 = Stack：图标在**整格**正中心、标签 Positioned 沉底（不占布局
/// 高度）。本测试锁住：
/// 1. 无布局溢出异常；
/// 2. 图标中心 == 格子中心（水平与垂直都卡 ±0.5px）；
/// 3. 标签仍在格子内部、贴底。
void main() {
  testWidgets('竖屏窄格：图标在整格正中心、标签贴底不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 手机竖屏逻辑尺寸约 411x914（dpr 2.63）：3 列、格子约 118dp 正方形。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1080 / 411;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        ),
        home: LaunchPadPage(
          onTabSelected: (_) {},
          onTabEnabled: (_) {},
          onTabUnpinned: (_) {},
          onTabOpened: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 卡片根是 Material（口径同 launchpad_background_test）。
    final firstCard = find.descendant(
      of: find.byType(LaunchPadPage),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.child is Listener,
      ),
    ).first;

    // 断言 1：窄格下不再有 RenderFlex 溢出异常。
    expect(tester.takeException(), isNull);

    final cellRect = tester.getRect(firstCard);
    final iconRect = tester.getRect(
      find.descendant(of: firstCard, matching: find.byType(Icon)).first,
    );
    final labelRect = tester.getRect(
      find.descendant(of: firstCard, matching: find.byType(Text)).first,
    );

    // 断言 2：图标中心 == 整格中心（波以图标真实中心为锚 → 波心即格心）。
    expect(
      (iconRect.center.dx - cellRect.center.dx).abs(),
      lessThan(0.5),
    );
    expect(
      (iconRect.center.dy - cellRect.center.dy).abs(),
      lessThan(0.5),
    );

    // 断言 3：标签在格子内部、贴底（不随图标挤走，也不溢出格子）。
    expect(labelRect.bottom, lessThanOrEqualTo(cellRect.bottom + 0.5));
    expect(labelRect.top, greaterThanOrEqualTo(cellRect.top));
  });
}
