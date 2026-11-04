import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_panel_frame.dart';

/// 场景常量（与真机量级同阶）：
/// - 屏高 800；
/// - 底栏槽位 80（NavigationBar 64 + 手势条净空 16）；
/// - 迷你条贴在底栏上方：顶端 640、底端 720（= 屏高 − 槽位高 = 底栏顶边）。
const double _kScreen = 800;
const double _kSlot = 80;
const double _kMiniTop = 640;
const double _kMiniBottom = 720;

void main() {
  group('resolveBottomChromeSinkOffset', () {
    test('progress = 0 时不动', () {
      expect(
        resolveBottomChromeSinkOffset(
          progress: 0,
          screenHeight: _kScreen,
          slotHeight: _kSlot,
          anchorTop: _kMiniTop,
          anchorBottom: _kMiniBottom,
        ),
        0.0,
      );
    });

    test('迷你条贴底栏时位移 = 槽位高 × p', () {
      for (final double p in <double>[0.25, 0.5, 1.0]) {
        expect(
          resolveBottomChromeSinkOffset(
            progress: p,
            screenHeight: _kScreen,
            slotHeight: _kSlot,
            anchorTop: _kMiniTop,
            anchorBottom: _kMiniBottom,
          ),
          closeTo(_kSlot * p, 0.001),
        );
      }
    });

    test('与 playerPanelGeometry 的面板下沿逐点一致（不留缝的根据）', () {
      for (final double p in <double>[0.1, 0.3, 0.6, 0.9]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: _kMiniTop,
          miniHeight: _kMiniBottom - _kMiniTop,
          screenHeight: _kScreen,
        );
        final panelBottom = g.top + g.height;
        final offset = resolveBottomChromeSinkOffset(
          progress: p,
          screenHeight: _kScreen,
          slotHeight: _kSlot,
          anchorTop: _kMiniTop,
          anchorBottom: _kMiniBottom,
        );
        // 底栏顶边（屏高 − 槽位高）加上位移，必须正好落在面板下沿
        expect(_kScreen - _kSlot + offset, closeTo(panelBottom, 0.001));
      }
    });

    test('迷你条离底栏还有净空时不抢先下沉', () {
      // 迷你条底端 700 → 距底栏顶边（720）还有 20dp 净空
      final offset = resolveBottomChromeSinkOffset(
        progress: 0.5,
        screenHeight: _kScreen,
        slotHeight: _kSlot,
        anchorTop: 620,
        anchorBottom: 700,
      );
      // 面板下沿 = 700 + (800 − 700) × 0.5 = 750 → 位移 = 750 − 720 = 30
      expect(offset, closeTo(30, 0.001));
    });

    test('锚点未登记时用兜底条高（贴屏幕底一条 72）', () {
      final offset = resolveBottomChromeSinkOffset(
        progress: 0.5,
        screenHeight: _kScreen,
        slotHeight: _kSlot,
        anchorTop: 0,
        anchorBottom: 0,
      );
      // 兜底锚点 top = 800 − 72 = 728、bottom = 800 → 面板下沿 = 800
      expect(offset, closeTo(_kSlot, 0.001));
    });

    test('progress 越界被钳制，非法尺寸返回 0', () {
      double run({required double progress, double screen = _kScreen, double slot = _kSlot}) =>
          resolveBottomChromeSinkOffset(
            progress: progress,
            screenHeight: screen,
            slotHeight: slot,
            anchorTop: _kMiniTop,
            anchorBottom: _kMiniBottom,
          );

      expect(run(progress: 0.5), greaterThan(0)); // 先证明该组参数在合法区间会动
      expect(run(progress: 2), closeTo(_kSlot, 0.001));
      expect(run(progress: -1), 0.0);
      expect(run(progress: 0.5, screen: 0), 0.0);
      expect(run(progress: 0.5, slot: 0), 0.0);
    });
  });

  group('BottomChromeSink', () {
    testWidgets('按面板下沿整体下移 child，且不改 child 尺寸', (WidgetTester tester) async {
      PlayerPanelSignal.publishAnchor(top: _kMiniTop, bottom: _kMiniBottom);
      final progress = ValueNotifier<double>(0.0);
      addTearDown(progress.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(400, _kScreen)),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: BottomChromeSink(
                slotHeight: _kSlot,
                progress: progress,
                child: const SizedBox(key: Key('bar'), height: _kSlot, width: 400),
              ),
            ),
          ),
        ),
      );
      final double baseTop = tester.getTopLeft(find.byKey(const Key('bar'))).dy;

      progress.value = 0.5;
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const Key('bar'))).dy,
        closeTo(baseTop + _kSlot * 0.5, 0.5),
      );
      expect(tester.getSize(find.byKey(const Key('bar'))).height, closeTo(_kSlot, 0.5));

      progress.value = 0.0;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const Key('bar'))).dy, closeTo(baseTop, 0.5));
    });

    testWidgets('progress 为 null 时原样返回 child（桌面/其它形态零变化）', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Align(
            alignment: Alignment.bottomCenter,
            child: BottomChromeSink(
              slotHeight: 80,
              child: SizedBox(key: Key('bar'), height: 80, width: 400),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('bar')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('bar'))).height, closeTo(80, 0.5));
    });
  });

  group('PlayerPanelSignal 是 player 模块全局量的唯一状态本体', () {
    setUp(() {
      PlayerPanelSignal.expansion.value = 0.0;
      PlayerPanelSignal.publishAnchor(top: 0, bottom: 0);
    });

    tearDown(() {
      PlayerPanelSignal.expansion.value = 0.0;
      PlayerPanelSignal.publishAnchor(top: 0, bottom: 0);
    });

    test('playerExpansion 就是同一个通知器实例', () {
      expect(identical(playerExpansion, PlayerPanelSignal.expansion), isTrue);
    });

    test('publishPlayerDragOrigin 写进 core 锚点，player 侧读到同值', () {
      publishPlayerDragOrigin(top: 640, bottom: 720);
      expect(PlayerPanelSignal.anchorTop, 640);
      expect(PlayerPanelSignal.anchorBottom, 720);
      expect(playerDragOriginTop, 640);
      expect(playerDragOriginBottom, 720);
      expect(playerMiniBarHeight(), closeTo(80, 0.001));
    });

    test('五字段成组写：胶囊的窄矩形/圆角不会泄漏给下一次常驻条登记', () {
      // 悬浮胶囊上拉：登记可见本体 + 32 圆角
      publishPlayerDragOrigin(
        top: 793,
        bottom: 857,
        left: 16,
        width: 368,
        radius: 32,
      );
      expect(playerDragOriginLeft, 16);
      expect(playerDragOriginWidth, 368);
      expect(playerDragOriginRadius, 32);

      // 下一次是常驻条（只传两参）：横向范围与圆角必须**复位**成通栏/方角，
      // 否则常驻条的面板起点会带上胶囊留下的窄矩形（凭空变窄变圆）。
      publishPlayerDragOrigin(top: 700, bottom: 780);
      expect(playerDragOriginLeft, 0.0);
      expect(playerDragOriginWidth, 0.0);
      expect(playerDragOriginRadius, 0.0);
    });

    test('playerPanelAnchorRect：width≤0 视为通栏；有登记则按登记钳进屏内', () {
      const Size screen = Size(400, 869);
      publishPlayerDragOrigin(top: 700, bottom: 780);
      expect(
        playerPanelAnchorRect(screen),
        const Rect.fromLTWH(0, 700, 400, 80),
      );

      publishPlayerDragOrigin(
        top: 793,
        bottom: 857,
        left: 16,
        width: 368,
        radius: 32,
      );
      expect(
        playerPanelAnchorRect(screen),
        const Rect.fromLTWH(16, 793, 368, 64),
      );

      // 越界（旧视口快照）：左缘钳进 [0, 屏宽 − 宽]，不会把窗口推出屏外
      publishPlayerDragOrigin(
        top: 793,
        bottom: 857,
        left: 500,
        width: 368,
        radius: 32,
      );
      final clamped = playerPanelAnchorRect(screen);
      expect(clamped.right, lessThanOrEqualTo(screen.width + 1e-9));
      expect(clamped.left, greaterThanOrEqualTo(0));
    });

    test('kPlayerFallbackMiniBarHeight 与 core 兜底条高同源', () {
      expect(kPlayerFallbackMiniBarHeight, PlayerPanelSignal.fallbackBarHeight);
    });
  });
}
