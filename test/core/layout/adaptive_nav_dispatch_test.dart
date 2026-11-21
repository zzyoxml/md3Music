import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';

/// AdaptiveNav.openDetail 的分派钉子（封面连贯过渡对齐原生 Hero 的地基）：
///
/// - 真双栏几何（≥1000dp）→ 详情面板嵌套 Navigator：master 列与面板栈跨栈，
///   框架 Hero 配对不了，封面连贯过渡维持 PlaylistCoverFlightBus 自绘飞行；
/// - 单栏几何（手机）→ 最近中央栈：Tab 栈自带 HeroController，两端同栈，
///   封面过渡走框架 Hero（与搜索页专辑大封面过渡同一条链路）；
/// - 点击发生在面板栈内部（详情页里再开详情）→ **不论几何**一律留在面板栈：
///   推到中央栈会与面板栈形成并行二级栈，且两端 Hero 分属不同栈。
///
/// 判别器：根 Navigator 的观察者只看得见中央栈 push（嵌套面板 push 对它
/// 不可见），配合 detailKey.canPop() 区分路由落点。
void main() {
  const phoneSize = Size(400, 800);
  const tabletSize = Size(1280, 853);

  // 双栏开关三端通用后，宽屏双栏用例需显式开启（全局 notifier 初值 false）。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  Future<GlobalKey<NavigatorState>> pumpHarness(
    WidgetTester tester, {
    required _RecordingObserver rootObserver,
  }) async {
    final detailKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [rootObserver],
      home: DesktopTwoPane(
        responsive: true,
        detailKey: detailKey,
        master: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => AdaptiveNav.openDetail<void>(
                  context,
                  (_) => _detailPage(),
                ),
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 首帧 home 路由的 push 也会计入，先清掉再让用例各自断言增量。
    rootObserver.pushes.clear();
    return detailKey;
  }

  testWidgets('单栏几何：master 点击 → 详情推中央栈（面板栈不动）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = phoneSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    final detailKey = await pumpHarness(tester, rootObserver: rootObserver);

    expect(DetailPaneScope.isTwoPaneOf(
        tester.element(find.text('打开详情'))), isFalse);

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.text('歌单详情'), findsOneWidget);
    expect(rootObserver.pushes.length, 1,
        reason: '中央栈 push 对根 Navigator 观察者可见（旧 pane 行为是 0）');
    expect(
      detailKey.currentState!.canPop(), isFalse,
        reason: '单栏详情不再进面板栈，封面过渡交给框架 Hero');
  });

  testWidgets('双栏几何：master 点击 → 详情推面板栈（行为不变）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tabletSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    final detailKey = await pumpHarness(tester, rootObserver: rootObserver);

    final masterContext = tester.element(find.text('打开详情'));
    expect(DetailPaneContent.isTwoPaneOf(masterContext), isFalse,
        reason: '主列表不在右侧详情内容作用域内');
    expect(DetailPaneScope.isTwoPaneOf(masterContext), isTrue,
        reason: '查看更多应从主列表的双栏作用域识别右侧面板');

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.text('歌单详情'), findsOneWidget);
    expect(find.text('打开详情'), findsOneWidget,
        reason: '双栏下 master 仍在左栏并排显示');
    expect(rootObserver.pushes, isEmpty,
        reason: '面板嵌套 Navigator 的 push 对根 Navigator 观察者不可见');
    expect(
      detailKey.currentState!.canPop(), isTrue,
        reason: '详情落在面板栈上（自绘飞行链路维持原状）');
  });

  testWidgets('面板栈内部点击：双栏下再开详情仍留在面板栈', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tabletSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    final detailKey = await pumpHarness(tester, rootObserver: rootObserver);

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再开一层'));
    await tester.pumpAndSettle();

    expect(find.text('第二层'), findsOneWidget);
    expect(rootObserver.pushes, isEmpty);
    expect(
      detailKey.currentState!.canPop(), isTrue,
        reason: '面板栈已叠两层（pop 一次回不到空面板）');
  });

  testWidgets('面板栈内部点击：旋转成单栏后仍留在面板栈（nearestIsPane 钉子）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tabletSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    final detailKey = await pumpHarness(tester, rootObserver: rootObserver);

    // 双栏下先攒一层面板栈详情，再旋转成单栏：几何已变 twoPane=false，
    // 但面板栈里还有活路由，页面内的详情入口必须继续落面板栈。
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = phoneSize;
    await tester.pumpAndSettle();
    expect(find.text('歌单详情'), findsOneWidget);

    await tester.tap(find.text('再开一层'));
    await tester.pumpAndSettle();

    expect(find.text('第二层'), findsOneWidget);
    expect(rootObserver.pushes, isEmpty,
        reason: '落到中央栈会形成与面板栈并行的二级栈（观察者会看到一次 push）');
    expect(
      detailKey.currentState!.canPop(), isTrue,
        reason: '第二层在面板栈上，返回后仍有一层详情');
  });
}

Widget _detailPage() => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('歌单详情'),
            Builder(
              builder: (context) => TextButton(
                onPressed: () => AdaptiveNav.openDetail<void>(
                  context,
                  (_) => const Scaffold(body: Text('第二层')),
                ),
                child: const Text('再开一层'),
              ),
            ),
          ],
        ),
      ),
    );

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }
}
