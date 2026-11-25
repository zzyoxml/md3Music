import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/modules/launchpad/launchpad_page.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 手机竖屏窄格回归（2026-11-21 真机两轮反馈 + 本轮「整组居中」口径）：
///
/// 图标槽曾写死 84*s（≈113dp），安卓竖屏正方形格（≈118dp）装不下
/// 「113dp 槽 + 标签」→ 溢出；后又改成纯图标居中 + 标签沉底，图标虽归中，
/// 但「图标 + 文字」整组视觉重心偏下。
///
/// 现口径：
/// - 大色块模式（关壁纸）：Column 把图标 + 标签视作整体居中（图标在上、
///   标签在下，整组重心居中）；
/// - 壁纸模式（开自定义壁纸）：Stack 叠放，图标在整格正中心、标签沉底
///   不占布局高度（浮层观感）。
///
/// 波锚定图标真实中心，两种口径下波都跟着各自口径走，测试只锁布局。
void main() {
  // 手机竖屏逻辑尺寸约 411x914（dpr 2.63）：3 列、格子约 118dp 正方形。
  Future<void> pumpPage(
    WidgetTester tester,
    ThemeProvider theme,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1080 / 411;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
      ],
      child: MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: LaunchPadPage(
          onTabSelected: (_) {},
          onTabEnabled: (_) {},
          onTabUnpinned: (_) {},
          onTabOpened: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // 卡片根是 Material（大色块模式 surfaceContainerLow、壁纸模式透明），
  // finder 不预设颜色，按「Material 且直接子是 Listener」识别卡片。
  Finder firstCard() => find.descendant(
        of: find.byType(LaunchPadPage),
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.child is Listener,
        ),
      ).first;

  testWidgets('大色块（关壁纸）：图标+标签整组垂直居中、不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({'use_background_image': false});
    final theme = ThemeProvider();
    await pumpPage(tester, theme);

    expect(tester.takeException(), isNull); // 断言 1：无布局溢出异常

    final cellRect = tester.getRect(firstCard());
    // 图标底盘（卡片内唯一的透明底 Container；Icon 的 rect 是字形盒，
    // 与底盘有固定偏差，量整组必须用底盘）。
    final plateFinder = find.descendant(
      of: firstCard(),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == Colors.transparent,
      ),
    );
    final plateRect = tester.getRect(plateFinder);
    final iconRect = tester.getRect(
      find.descendant(of: firstCard(), matching: find.byType(Icon)).first,
    );
    final labelRect = tester.getRect(
      find.descendant(of: firstCard(), matching: find.byType(Text)).first,
    );

    // 断言 2：水平方向图标与标签都居中对齐于格子。
    expect((iconRect.center.dx - cellRect.center.dx).abs(), lessThan(0.5));
    expect((labelRect.center.dx - cellRect.center.dx).abs(), lessThan(0.5));

    // 断言 3：竖向——图标在上、标签在下、不重叠、不出格。
    expect(plateRect.top, greaterThanOrEqualTo(cellRect.top));
    expect(plateRect.bottom, lessThan(labelRect.top));
    expect(labelRect.bottom, lessThanOrEqualTo(cellRect.bottom + 0.5));

    // 断言 4：「图标盘+间隙+标签」整组居中：底盘顶到格顶的余白 ==
    // 标签底到格底的余白（列居中，上下余白相等；padding 对称会抵消）。
    expect(
      (plateRect.top - cellRect.top) -
          (cellRect.bottom - labelRect.bottom),
      lessThan(1.5),
    );
  });

  testWidgets('壁纸（开自定义壁纸）：图标整格居中、标签沉底不溢出',
      (tester) async {
    SharedPreferences.setMockInitialValues({'use_background_image': false});
    final theme = ThemeProvider();
    await pumpPage(tester, theme);
    await theme.setUseBackgroundImage(true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // 断言 1：无布局溢出异常

    final cellRect = tester.getRect(firstCard());
    final iconRect = tester.getRect(
      find.descendant(of: firstCard(), matching: find.byType(Icon)).first,
    );
    final labelRect = tester.getRect(
      find.descendant(of: firstCard(), matching: find.byType(Text)).first,
    );

    // 断言 2：图标中心 == 整格中心（水平与垂直都卡 ±0.5px）。
    expect((iconRect.center.dx - cellRect.center.dx).abs(), lessThan(0.5));
    expect((iconRect.center.dy - cellRect.center.dy).abs(), lessThan(0.5));

    // 断言 3：标签在格子内部、贴底。
    expect(labelRect.bottom, lessThanOrEqualTo(cellRect.bottom + 0.5));
    expect(labelRect.top, greaterThanOrEqualTo(cellRect.top));
  });
}