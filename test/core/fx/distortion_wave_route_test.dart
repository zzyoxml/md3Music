import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/fx/waves/distortion_wave.dart';

/// 主机上没有 GPU：`WavePrograms.ready` 为 null，整条路由走 300ms 淡入淡出。
/// 所以这里校的是路由接线（推入、返回、两侧子树的生命周期），不是观感。
void main() {
  testWidgets('推入与返回都走完整条路由，不抛异常', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => nav.currentState!.push(
                  DistortionWaveRoute<void>(
                    settings: const RouteSettings(name: 'brush/vertical'),
                    source: const Rect.fromLTWH(300, 20, 44, 44),
                    style: DistortionWaveStyle.screenCenter,
                    revealedLive: true,
                    builder: (_) => const Scaffold(body: Center(child: Text('竖屏流'))),
                  ),
                ),
                child: const Text('进入'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('进入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('竖屏流'), findsOneWidget);
    expect(tester.takeException(), isNull);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('竖屏流'), findsNothing);
    expect(find.text('进入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统要求减少动画时退成短淡入淡出', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Center(
              child: TextButton(
                onPressed: () => nav.currentState!.push(
                  DistortionWaveRoute<void>(
                    style: DistortionWaveStyle.screenCenter,
                    builder: (_) => const Scaffold(body: Center(child: Text('竖屏流'))),
                  ),
                ),
                child: const Text('进入'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('进入'));
    // 300ms 足够走完退化的那一档。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('竖屏流'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
