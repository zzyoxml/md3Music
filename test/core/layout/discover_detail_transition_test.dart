import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/core/widgets/app_background.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastRoute = route;
  }
}

void main() {
  testWidgets('Android 单栏壁纸详情转场不绘制下层旧页面', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
      navigatorKey: key,
      theme: AppTheme.lightTheme.copyWith(scaffoldBackgroundColor: Colors.transparent),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => AdaptiveNav.openDetail(context,
          (_) => const Scaffold(body: Text('单栏详情')),
          lightweightTransition: true),
        child: const Text('单栏旧页面'),
      ))),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单栏旧页面'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('单栏旧页面'), findsNothing,
        reason: '透明详情进场时，旧页面不能透过壁纸串影');
    await tester.pumpAndSettle();
    key.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('单栏旧页面'), findsNothing,
        reason: '返回动画结束前，旧页面仍不能与详情叠加');
    await tester.pumpAndSettle();
    expect(find.text('单栏旧页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('$platform 更多轻量转场留在右栏，280ms 收敛且返回可用', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final previous = kWindowsTwoPaneEnabled.value;
      kWindowsTwoPaneEnabled.value = true;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        kWindowsTwoPaneEnabled.value = previous;
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(tester.view.reset);
      final observer = _RouteObserver();
      final detailKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
        theme: AppTheme.lightTheme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        home: DesktopTwoPane(
          responsive: true,
          detailKey: detailKey,
          detailObservers: [observer],
          master: Builder(builder: (context) => TextButton(
            onPressed: () => AdaptiveNav.openDetail(context,
              (_) => const Scaffold(body: Center(child: Text('详情内容'))),
              lightweightTransition: true),
            child: const Text('更多'),
          )),
        ),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.descendant(of: find.byKey(detailKey),
          matching: find.byType(AppBackground)), findsNothing,
          reason: '详情栈底转场不能生成局部壁纸，与全局壁纸交接会闪色');
      expect(find.text('从左侧选择一项查看详情'), findsNothing,
          reason: '空态在详情转场过程中不应透出');
      final route = observer.lastRoute! as TransitionRoute<dynamic>;
      expect(route.transitionDuration, const Duration(milliseconds: 280));
      expect(route.reverseTransitionDuration, const Duration(milliseconds: 260));
      await tester.pump(const Duration(milliseconds: 300));
      expect(route.animation!.status, AnimationStatus.completed);
      expect(tester.getCenter(find.text('详情内容')).dx,
          greaterThan(tester.getCenter(find.text('更多')).dx));
      detailKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('详情内容'), findsNothing);
      expect(find.text('更多'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
