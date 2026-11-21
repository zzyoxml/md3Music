import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// 回归（两轮）：单栏态（手机宽度）经 AdaptiveNav.openDetail 打开详情时——
/// 1) 详情面板嵌套 Navigator 的栈底 DetailEmptyState 曾在转场中露出，
///    整屏闪现「从左侧选择一项查看详情」→ 单栏栈底必须渲染空白；
///    （详情改走中央栈后，单栏下不再触碰面板栈，该缺陷结构性消失；
///    `_ResponsiveDetailBase` 渲染空白仍服务「双栏面板栈旋转降级单栏」场景。）
/// 2) master 列曾在新路由动画未收敛时就被 Offstage，转场底下是空背景，
///    表现为「列表突失 + 详情页凭空半路出现」的硬切闪烁 → 转场全程
///    master 必须在场垫底。
/// 真双栏（≥1000dp）未选中时的占位是设计行为，必须保留。
void main() {
  const emptyText = '从左侧选择一项查看详情';

  // 双栏开关三端通用后，宽屏（1280）用例需显式开启；单栏（400）用例关掉
  // 也仍是单栏几何，不受影响。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  Future<void> pumpFavorites(WidgetTester tester, double width) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          visibleTabs: const [TabItem(id: 'favorites', label: '收藏')],
          selectedIndex: 0,
          pageBuilder: (_) => Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开歌单'),
                onPressed: () => AdaptiveNav.openDetail(
                  context,
                  (_) => const Scaffold(body: Text('歌单详情')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('单栏打开详情：转场全程 master 在场垫底且不得出现空态占位', (tester) async {
    await pumpFavorites(tester, 400);
    expect(find.text(emptyText), findsNothing);

    await tester.tap(find.text('打开歌单'));
    // 进入转场约 300ms：逐帧检查前半程——既不能露空态，也不能把 master
    // 提前 Offstage（旧缺陷：列表突然消失 + 半路详情页凭空出现 = 硬切闪烁）。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text(emptyText), findsNothing, reason: '第 $i 帧露出空态');
      expect(find.text('打开歌单'), findsOneWidget,
          reason: '第 $i 帧 master 已被硬切隐藏');
    }
    await tester.pumpAndSettle();
    expect(find.text('歌单详情'), findsOneWidget);
    // 单栏详情已改走中央栈（框架 Hero 链路）：master 不再被本组件 Offstage，
    // 而是作为被不透明路由盖住的路由进入 Overlay backstage
    // （_TheaterElement.debugVisitOnstageChildren 跳过），finder 不可见——
    // 与所有 A 类 tab 的被盖路由同一待遇，断言维持 findsNothing。
    expect(find.text('打开歌单'), findsNothing); // 收敛后单栏详情独占整宽

    // 返回转场：master 在场垫底，被退出的详情页必须还在台上播动画，
    // 不得被面板 Offstage 直接抹掉（canPop 在 pop 首帧即变 false 的坑）。
    final detailContext = tester.element(find.text('歌单详情'));
    Navigator.of(detailContext).pop();
    // pop 的观察者回调登记在帧末，先过一帧让状态落地再逐帧断言。
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text(emptyText), findsNothing, reason: '返回第 $i 帧露出空态');
      expect(find.text('打开歌单'), findsOneWidget,
          reason: '返回第 $i 帧 master 未垫底');
      expect(find.text('歌单详情'), findsOneWidget,
          reason: '返回第 $i 帧退场页被硬切抹掉');
    }
    await tester.pumpAndSettle();
    expect(find.text('打开歌单'), findsOneWidget);
    expect(find.text('歌单详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('双栏未选中时保留空态占位，打开详情后进右栏', (tester) async {
    await pumpFavorites(tester, 1280);
    expect(find.text(emptyText), findsOneWidget); // 设计行为，不许回归掉

    await tester.tap(find.text('打开歌单'));
    await tester.pumpAndSettle();
    expect(find.text('歌单详情'), findsOneWidget);
    expect(find.text('打开歌单'), findsOneWidget); // master 仍在左栏
    expect(tester.takeException(), isNull);
  });
}
