import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_panel_frame.dart';

/// 迷你条 → 全屏**双向展开面板**的几何单测。
///
/// 面板语义：p=0 时可视区域恰好等于迷你条矩形（导航栏完整可见），
/// 随手指上滑，上沿 1:1 上移、下沿同时向下扫过导航栏，p=1 铺满全屏。
void main() {
  // 典型手机竖屏：屏高 869，迷你条顶端 709、条高 80（底端 789），下方 80 是导航栏。
  const h = 869.0;
  const origin = 709.0;
  const miniHeight = 80.0;

  group('playerPanelGeometry 双向展开几何', () {
    test('起点：窗口恰好等于迷你条矩形（导航栏完整可见）', () {
      final g = playerPanelGeometry(
        progress: 0,
        origin: origin,
        miniHeight: miniHeight,
        screenHeight: h,
      );
      expect(g.top, closeTo(origin, 1e-9));
      expect(g.height, closeTo(miniHeight, 1e-9));
      expect(g.top + g.height, closeTo(origin + miniHeight, 1e-9));
    });

    test('终点：铺满全屏', () {
      final g = playerPanelGeometry(
        progress: 1,
        origin: origin,
        miniHeight: miniHeight,
        screenHeight: h,
      );
      expect(g.top, closeTo(0, 1e-9));
      expect(g.height, closeTo(h, 1e-9));
    });

    test('上沿 1:1 跟手：与手指位移同速（top = origin*(1-p)）', () {
      for (final p in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: origin,
          miniHeight: miniHeight,
          screenHeight: h,
        );
        expect(g.top, closeTo(origin * (1 - p), 1e-9));
      }
    });

    test('全程单调：上沿只上移、下沿只下移、且永不越出屏幕', () {
      var prevTop = double.infinity;
      var prevBottom = -double.infinity;
      for (var i = 0; i <= 100; i++) {
        final p = i / 100;
        final g = playerPanelGeometry(
          progress: p,
          origin: origin,
          miniHeight: miniHeight,
          screenHeight: h,
        );
        final bottom = g.top + g.height;
        expect(g.top, lessThanOrEqualTo(prevTop));
        expect(bottom, greaterThanOrEqualTo(prevBottom));
        expect(g.top, greaterThanOrEqualTo(0));
        expect(bottom, lessThanOrEqualTo(h + 1e-9));
        expect(g.height, greaterThan(0));
        prevTop = g.top;
        prevBottom = bottom;
      }
    });

    test('下沿确实向下走（不是只有上沿在动）', () {
      final mid = playerPanelGeometry(
        progress: 0.5,
        origin: origin,
        miniHeight: miniHeight,
        screenHeight: h,
      );
      expect(mid.top + mid.height, greaterThan(origin + miniHeight));
    });

    test('退化情形：迷你条自身贴屏底（二级路由无导航栏）下沿恒等于屏高', () {
      const flushOrigin = h - miniHeight;
      for (final p in [0.0, 0.3, 0.9, 1.0]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: flushOrigin,
          miniHeight: miniHeight,
          screenHeight: h,
        );
        expect(g.top + g.height, closeTo(h, 1e-9));
        // 且面板仍然在长高（不能卡在条高）
        expect(g.height, closeTo(miniHeight + (h - miniHeight) * p, 1e-9));
      }
      expect(
        playerPanelGeometry(
          progress: 1,
          origin: flushOrigin,
          miniHeight: miniHeight,
          screenHeight: h,
        ).height,
        closeTo(h, 1e-9),
        reason: 'p=1 必须铺满全屏 —— 误用 (屏高-origin-条高) 会让这里只剩条高',
      );
    });

    test('非法输入被钳进屏内，不产生 NaN / 越界', () {
      final over = playerPanelGeometry(
        progress: 1,
        origin: 800,
        miniHeight: 200, // 800+200 > 869
        screenHeight: h,
      );
      expect(over.top + over.height, lessThanOrEqualTo(h + 1e-9));

      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        final g = playerPanelGeometry(
          progress: bad,
          origin: bad,
          miniHeight: bad,
          screenHeight: bad,
        );
        expect(g.top.isFinite, isTrue);
        expect(g.height.isFinite, isTrue);
      }
    });

    test('origin 大于屏高时（转屏途中锚点是旧屏快照）仍不自相矛盾', () {
      // 竖屏 origin=709，转横屏屏高只剩 400：锚点还停在转屏前
      for (final p in [0.0, 0.5, 1.0]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: 709,
          miniHeight: miniHeight,
          screenHeight: 400,
        );
        expect(g.top.isFinite, isTrue);
        expect(g.top, greaterThanOrEqualTo(0));
        expect(g.top + g.height, lessThanOrEqualTo(400 + 1e-9));
      }
    });

    test('三处 origin 钳制同源：几何 top == 页面 dy（转屏途中不破）', () {
      // 这条是整个面板设计赖以成立的不变量：窗口上沿必须与页面上沿重合，
      // 否则页面被整体推到窗口之外 → 面板整块透明，且那块透明窗口仍吃命中。
      for (final pair in [(709.0, 869.0), (709.0, 400.0), (0.0, 869.0)]) {
        for (final p in [0.0, 0.37, 0.5, 1.0]) {
          final g = playerPanelGeometry(
            progress: p,
            origin: pair.$1,
            miniHeight: miniHeight,
            screenHeight: pair.$2,
          );
          expect(
            g.top,
            closeTo(
              playerPanelPageOffset(
                progress: p,
                origin: pair.$1,
                screenHeight: pair.$2,
              ).dy,
              1e-9,
            ),
            reason: 'origin=${pair.$1} 屏高=${pair.$2} p=$p',
          );
        }
      }
    });

    test('progress 越界被钳进 [0,1]', () {
      final below = playerPanelGeometry(
        progress: -1,
        origin: origin,
        miniHeight: miniHeight,
        screenHeight: h,
      );
      final above = playerPanelGeometry(
        progress: 2,
        origin: origin,
        miniHeight: miniHeight,
        screenHeight: h,
      );
      expect(below.top, closeTo(origin, 1e-9));
      expect(below.height, closeTo(miniHeight, 1e-9));
      expect(above.top, closeTo(0, 1e-9));
      expect(above.height, closeTo(h, 1e-9));
    });
  });

  group('playerPanelOpacity', () {
    test('起点透明、行程满 20% 屏高后完全不透明、之后保持', () {
      expect(
        playerPanelOpacity(progress: 0, origin: origin, screenHeight: h),
        0,
      );
      expect(
        playerPanelOpacity(
          progress: 0.2 * h / origin,
          origin: origin,
          screenHeight: h,
        ),
        closeTo(1.0, 1e-9),
      );
      expect(
        playerPanelOpacity(progress: 1, origin: origin, screenHeight: h),
        1.0,
      );
    });

    test('与整屏下移时代的旧公式逐点一致（不能顺手改了手感）', () {
      for (final p in [0.0, 0.1, 0.235, 0.5, 1.0]) {
        final legacy =
            (p * origin / (kPlayerExpandDistanceRatio * h)).clamp(0.0, 1.0);
        expect(
          playerPanelOpacity(progress: p, origin: origin, screenHeight: h),
          closeTo(legacy, 1e-9),
        );
      }
    });
  });

  group('与既有映射的一致性（改一处必须同步另一处）', () {
    // 登记簿是全局单例，逐个复位避免污染其它 group
    tearDown(PlayerCoverMorphBus.instance.reset);

    test('面板淡入跨度 == 松手判定阈值比例', () {
      expect(kPlayerPanelFadeSpanRatio, kPlayerExpandDistanceRatio);
    });

    test('面板位移与 playerPageOffset 拖拽分支逐点相等', () {
      for (final p in [0.0, 0.13, 0.5, 0.87, 1.0]) {
        expect(
          playerPanelPageOffset(
            progress: p,
            origin: origin,
            screenHeight: h,
          ),
          playerPageOffset(progress: p, dragOrigin: origin, screenHeight: h),
          reason: 'p=$p：两式漂移会让飞行中的封面与页面错位',
        );
      }
    });

    test('面板位移同样写进形变登记簿', () {
      playerPanelPageOffset(
        progress: 0.5,
        origin: origin,
        screenHeight: h,
      );
      expect(
        PlayerCoverMorphBus.instance.pageOffset,
        const Offset(0, 354.5),
      );
    });
  });
}
