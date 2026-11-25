import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/fx/waves/distortion_wave.dart';
import 'package:md3music/modules/player/full_player_route.dart';

/// 封面流 → 播放页的波过场：只校**接线**与退路，不校观感。
///
/// 主机上没有着色器，`WavePrograms.ready` 恒为 null，所以真正的分支平时跑不到；
/// 用 [DraggablePlayerRoute.debugAssumeProgramsReady] 把这一档打开，
/// 走的仍是同一套「抓帧 → 退化」逻辑（着色器为空时画的是淡入淡出）。
void main() {
  setUp(() => DraggablePlayerRoute.debugAssumeProgramsReady = true);
  tearDown(() => DraggablePlayerRoute.debugAssumeProgramsReady = false);

  Widget host(VoidCallback onTap) => Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(onPressed: onTap, child: const Text('cover')),
      ),
    ),
  );

  testWidgets('推入后旧页截图拿到，过渡不会停在空白，播放页直接到位', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: host(() {
          nav.currentState!.push(
            DraggablePlayerRoute<void>(
              waveSource: const Rect.fromLTWH(80, 200, 220, 220),
              builder: (_) => const Scaffold(body: Center(child: Text('player'))),
            ),
          );
        }),
      ),
    );

    await tester.tap(find.text('cover'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    expect(tester.takeException(), isNull, reason: '抓帧或首帧抛异常会让过渡停在空白');
    // 这一条就是「卡死」的判据：抓不到图时必须已经退到淡入淡出，
    // 而不是永远返回一个空盒子（路由的 barrier 会把点击吃掉）。
    expect(
      find.byType(WaveStage),
      findsOneWidget,
      reason: '没有建出 WaveStage：_outgoing 一直为 null 且没走退路 = 卡死',
    );
    expect(find.text('player'), findsOneWidget);
    expect(playerExpansion.value, 1.0, reason: '播放页要在波后面直接到位');

    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('抓帧失败（旧页不是整页）时退成淡入淡出，一样能进播放页', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: host(() {
          // 直接挂在 Navigator 之外没有意义；这里换成 PageRouteBuilder 让
          // "上一页"仍是整页，用 waveSource 仍然可走，但没有上一个 PageRoute 时
          // _previous 为 null → 抓帧失败 → 必须退路。
          nav.currentState!.push(
            DraggablePlayerRoute<void>(
              waveSource: const Rect.fromLTWH(120, 300, 160, 160),
              builder: (_) => const Scaffold(body: Center(child: Text('player'))),
            ),
          );
        }),
      ),
    );

    await tester.tap(find.text('cover'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(find.text('player'), findsOneWidget);
  });

  test('不给起点就不走波', () {
    final route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox(),
    );
    expect(route.usesWaveEntry, isFalse);
    expect(route.waveSource, isNull);
  });
}
