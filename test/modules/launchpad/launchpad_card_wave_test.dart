import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/modules/launchpad/launchpad_page.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 长按扭曲波动画的回归测试：
/// 1. **按下即刻**波覆盖层挂进卡片（不等待系统长按识别），且只出现在被按的
///    那一张，不影响邻格；
/// 2. 提前松手 → 波回缩消失，动作不触发；
/// 3. 按满约 2s（系统长按识别 + 父级定时器）→ 动作触发。
///
/// 时间推进一律用**小步长多次 pump**：本机 flutter_test 里「活跃手势 +
/// 单发大 pump」不会推进 AnimationController（假时钟与手势的已知交互，
/// 对照实验验证过），小步长则稳定推进。
void main() {
  /// 按住 [ms] 毫秒：小步长泵推进模拟时间（每步 25ms）。
  Future<void> holdFor(WidgetTester tester, int ms) async {
    for (var i = 0; i < (ms / 25).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Widget buildPage(LaunchPadPage page) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), scaffoldBackgroundColor: Colors.blueGrey.shade100),
          home: page,
        ),
      );

  testWidgets('按下即刻出波且只在一格；提前松手回缩、动作不触发', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final enabled = <String>[];

    await tester.pumpWidget(buildPage(LaunchPadPage(
      onTabSelected: (_) {},
      onTabEnabled: enabled.add,
      onTabUnpinned: (_) {},
      onTabOpened: (_) {},
    )));
    await tester.pumpAndSettle();

    // 每张卡片根节点是 Material（大色块模式 surfaceContainerLow、
    // 壁纸模式透明），finder 不预设颜色，按「Material 且直接子是 Listener」
    // 识别卡片。
    final cards = find.byWidgetPredicate(
      (w) => w is Material && w.child is Listener,
    );
    final firstCard = cards.first;

    // —— 断言 1：按下 75ms 后全屏波层已挂上（不等长按识别）——
    // 波画在根 Overlay（精确居中 / 不被格子裁剪 / 盖在最上层）。app 别处也有
    // CustomPaint，故用「按下前后计数 +1」而非绝对数量断言。
    final baseline = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).length;
    final gesture = await tester.startGesture(tester.getCenter(firstCard));
    await holdFor(tester, 75);
    expect(
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).length,
      baseline + 1,
    );
    // 波不在任一卡片子树里——证实它走的是全屏 Overlay 路径。
    expect(
      find.descendant(of: firstCard, matching: find.byType(CustomPaint)),
      findsNothing,
    );

    // —— 断言 2：提前松手 → 回缩消失，且动作未触发 ——
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).length,
      baseline,
    );
    expect(enabled, isEmpty);
  });

  testWidgets('长按约 2s 走完全程并触发动作', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final enabled = <String>[];

    await tester.pumpWidget(buildPage(LaunchPadPage(
      onTabSelected: (_) {},
      onTabEnabled: enabled.add,
      onTabUnpinned: (_) {},
      onTabOpened: (_) {},
    )));
    await tester.pumpAndSettle();

    final cards = find.byWidgetPredicate(
      (w) => w is Material && w.child is Listener,
    );
    final gesture = await tester.startGesture(tester.getCenter(cards.first));

    // —— 走完全程：长按识别（约 500ms）+ 父级定时器（1500ms）= 总计约 2s ——
    await holdFor(tester, 2100);
    await gesture.up();

    // —— 断言：动作已触发（隐藏 tab 被启用，id 必非空）——
    expect(enabled, hasLength(1));
    expect(enabled.single, isNotEmpty);

    await tester.pumpAndSettle();
  });
}