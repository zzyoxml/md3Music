import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';

/// TwoPanePage：LaunchPad「打开为页面」/快捷方式/发现页搜索图标等**不经 tab
/// 壳层**的整屏入口的双栏包装（回归钉子）。
///
/// - 宽屏（≥1000dp）：master + 详情面板并排，openDetail 落自带面板栈（根
///   Navigator 观察者不可见——与 tab 形态的双栏一致，scope=false 缺陷即由此起）；
/// - 窄屏（<1000dp）：详情整屏盖住 master（DesktopTwoPane 响应式降级）；
/// - 返回键：先弹面板栈详情，栈空才关页面（对齐响应式壳层 maybePop 顺序）。
void main() {
  const phoneSize = Size(400, 800);
  const tabletSize = Size(1280, 853);

  // 双栏开关三端通用后，宽屏双栏用例需显式开启（全局 notifier 初值 false）。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  Future<void> pumpHarness(
    WidgetTester tester, {
    required _RecordingObserver rootObserver,
  }) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [rootObserver],
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TwoPanePage(child: const _MasterProbe()),
                ),
              ),
              child: const Text('打开页面'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 首帧 home 路由的 push 也计入，先清掉再让用例各自断言增量。
    rootObserver.pushes.clear();
  }

  testWidgets('宽屏：页面内 openDetail 落自带面板栈，master 仍在场', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tabletSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    await pumpHarness(tester, rootObserver: rootObserver);

    await tester.tap(find.text('打开页面'));
    await tester.pumpAndSettle();
    expect(find.text('一级页面'), findsOneWidget);
    // 空态占位与 tab 形态一致（TwoPanePage 不传 emptyState）。
    expect(find.text('从左侧选择一项查看详情'), findsOneWidget);
    // 「打开页面」本身的根栈 push 已断言过，清掉只留面板栈增量的判定空间。
    rootObserver.pushes.clear();

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.text('专辑详情'), findsOneWidget);
    expect(find.text('一级页面'), findsOneWidget,
        reason: '双栏下 master（页面本体）仍在左栏并排显示');
    expect(rootObserver.pushes, isEmpty,
        reason: '面板嵌套 Navigator 的 push 对根 Navigator 观察者不可见');
  });

  testWidgets('窄屏：详情整屏盖住 master（单栏降级）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = phoneSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    await pumpHarness(tester, rootObserver: rootObserver);

    await tester.tap(find.text('打开页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.text('专辑详情'), findsOneWidget);
    expect(find.text('一级页面'), findsNothing,
        reason: '单栏态详情铺满，master 转 Offstage');
  });

  testWidgets('返回键：先弹面板详情，栈空才关页面', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tabletSize;
    addTearDown(tester.view.reset);
    final rootObserver = _RecordingObserver();
    await pumpHarness(tester, rootObserver: rootObserver);

    await tester.tap(find.text('打开页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('专辑详情'), findsNothing);
    expect(find.text('一级页面'), findsOneWidget, reason: '页面还在，只弹了面板详情');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('一级页面'), findsNothing, reason: '面板栈空，页面关闭');
    expect(find.text('打开页面'), findsOneWidget);
  });
}

class _MasterProbe extends StatelessWidget {
  const _MasterProbe();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('一级页面'),
            TextButton(
              onPressed: () => AdaptiveNav.openDetail<void>(
                context,
                (_) => const Scaffold(body: Center(child: Text('专辑详情'))),
              ),
              child: const Text('打开详情'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }
}
