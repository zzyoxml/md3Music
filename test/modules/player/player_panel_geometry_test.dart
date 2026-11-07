import 'dart:math' as math;

import 'package:flutter/widgets.dart';
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

    test('tv: 顶栏迷你条（origin 远小于 span）整段行程走完即不透明', () {
      // tv: 顶栏迷你条 origin ≈ 56，总行程远不足 20% 屏高。旧公式在 p=1
      // 时只能到 ~0.33（播放页幽灵化、主页透出），行程封顶后 p=1 恒为 1，
      // 且整段行程内线性（起点仍为 0）。
      const tvOrigin = 56.0;
      expect(
        playerPanelOpacity(progress: 0, origin: tvOrigin, screenHeight: h),
        0,
      );
      final mid = playerPanelOpacity(
        progress: 0.5,
        origin: tvOrigin,
        screenHeight: h,
      );
      expect(mid, closeTo(0.5, 1e-9), reason: '行程不足 span 时按 p 线性');
      expect(
        playerPanelOpacity(progress: 1, origin: tvOrigin, screenHeight: h),
        1.0,
        reason: '全行程终点必须完全不透明（幽灵化回归钉）',
      );
    });

    test('origin 为 0（无位移）时恒不透明', () {
      expect(
        playerPanelOpacity(progress: 0, origin: 0, screenHeight: h),
        1.0,
      );
    });
  });

  group('playerPanelContour（矩形 + 外轮廓圆角）', () {
    const Size screen = Size(400, 869);
    // 悬浮胶囊可见本体：左右各 16 内缩、高 64、底端距屏底 12
    const Rect capsule = Rect.fromLTRB(16, 793, 384, 857);
    const double capsuleRadius = 32;
    const BorderRadius screenRadii = BorderRadius.only(
      topLeft: Radius.circular(58),
      topRight: Radius.circular(58),
      bottomLeft: Radius.circular(58),
      bottomRight: Radius.circular(58),
    );

    PlayerPanelContour contour(
      double p, {
      Rect originRect = capsule,
      double originRadius = capsuleRadius,
      BorderRadius? radii = screenRadii,
    }) => playerPanelContour(
      progress: p,
      originRect: originRect,
      screenSize: screen,
      originRadius: originRadius,
      screenRadii: radii,
    );

    test('p=0：矩形与圆角严格等于源形态（胶囊本体 + 32）', () {
      final c = contour(0);
      expect(c.rect, capsule);
      expect(c.radius, BorderRadius.circular(capsuleRadius));
    });

    test('p=1：铺满全屏 + 方角（**覆盖**屏幕 r 角而不是被它裁）', () {
      final c = contour(1);
      expect(c.rect, const Rect.fromLTWH(0, 0, 400, 869));
      // 尾段收回映射（[kPlayerPanelRadiusRetractStart]）：终态半径归零。
      // 真机报障两条：①上报值与实际物理圆角对不齐时，满屏窗口 + r 角裁剪会在
      // 四角弧形缺口露出底下的主页面；②r 角裁剪在完全展开后永久保留。
      // 「宁可小一些也不要露底」的落点 = 覆盖到屏边、由物理屏幕自己圆角。
      expect(c.radius, BorderRadius.zero);
    });

    test('圆角中段达到屏幕 r 角峰值，尾段线性收回（前升后降、p=1 收干净）', () {
      // 峰值点 = 收敛起点：此处恰为屏幕 r 角
      final peak = contour(kPlayerPanelRadiusRetractStart);
      expect(peak.radius, screenRadii);
      var prev = contour(0).radius.topLeft.x;
      for (var i = 1; i <= 100; i++) {
        final p = i / 100;
        final r = contour(p).radius.topLeft.x;
        expect(r, greaterThanOrEqualTo(0), reason: 'p=$p 半径非负');
        if (p <= kPlayerPanelRadiusRetractStart) {
          expect(r, greaterThanOrEqualTo(prev - 1e-9), reason: 'p=$p 前段应不缩');
        } else {
          expect(r, lessThanOrEqualTo(prev + 1e-9), reason: 'p=$p 尾段应不涨');
        }
        prev = r;
      }
      expect(prev, 0.0, reason: 'p=1 必须收干净');
    });

    test('未上报屏幕圆角时终点为方角（与引入圆角之前逐像素一致）', () {
      final c = contour(1, radii: null);
      expect(c.radius, BorderRadius.zero);
    });

    test('常驻条口径（通栏 + 圆角 0）：横向恒为整屏、圆角恒 0', () {
      const Rect resident = Rect.fromLTRB(0, 709, 400, 789);
      for (final p in [0.0, 0.3, 1.0]) {
        final c = contour(
          p,
          originRect: resident,
          originRadius: 0,
          radii: null,
        );
        expect(c.rect.left, 0);
        expect(c.rect.right, closeTo(400, 1e-9));
        expect(c.radius, BorderRadius.zero);
      }
    });

    test('全程单调：上沿只上移、下沿只下移、左缘只左移、右缘只右移', () {
      var prev = contour(0);
      for (var i = 1; i <= 100; i++) {
        final c = contour(i / 100);
        expect(c.rect.top, lessThanOrEqualTo(prev.rect.top + 1e-9));
        expect(c.rect.bottom, greaterThanOrEqualTo(prev.rect.bottom - 1e-9));
        expect(c.rect.left, lessThanOrEqualTo(prev.rect.left + 1e-9));
        expect(c.rect.right, greaterThanOrEqualTo(prev.rect.right - 1e-9));
        prev = c;
      }
    });

    test('纵向与 playerPanelGeometry 完全同源（top == dy 不变量保留）', () {
      const Rect resident = Rect.fromLTRB(0, origin, 400, origin + miniHeight);
      for (final p in [0.0, 0.17, 0.5, 0.83, 1.0]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: origin,
          miniHeight: miniHeight,
          screenHeight: h,
        );
        final c = contour(
          p,
          originRect: resident,
          originRadius: 0,
          radii: null,
        );
        expect(c.rect.top, closeTo(g.top, 1e-9), reason: 'p=$p 上沿');
        expect(c.rect.height, closeTo(g.height, 1e-9), reason: 'p=$p 高度');
      }
    });

    test('圆角逐角钳进 min(w,h)/2（小窗口不会被插值半径吃掉轮廓）', () {
      // p 很小时窗口只有 64 高，插值出来的半径可能 > 32
      final c = contour(0.5, radii: screenRadii);
      final maxR = math.min(c.rect.width, c.rect.height) / 2;
      for (final r in [
        c.radius.topLeft.x,
        c.radius.topRight.x,
        c.radius.bottomLeft.x,
        c.radius.bottomRight.x,
      ]) {
        expect(r, lessThanOrEqualTo(maxR + 1e-9));
        expect(r, greaterThanOrEqualTo(0));
      }
    });

    test('越界 / 非法输入被钳进屏内，不产生 NaN', () {
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        final c = playerPanelContour(
          progress: bad,
          originRect: Rect.fromLTRB(bad, bad, bad, bad),
          screenSize: Size(bad, bad),
          originRadius: bad,
          screenRadii: null,
        );
        expect(c.rect.left.isFinite, isTrue);
        expect(c.rect.top.isFinite, isTrue);
        expect(c.rect.width, greaterThanOrEqualTo(0));
        expect(c.rect.height, greaterThanOrEqualTo(0));
        expect(c.radius.topLeft.x.isFinite, isTrue);
      }
      // 转屏途中：起点矩形来自旧视口（比新屏大）
      final c = contour(0.5, originRect: const Rect.fromLTRB(0, 900, 900, 1200));
      expect(c.rect.top, greaterThanOrEqualTo(0));
      expect(c.rect.right, lessThanOrEqualTo(screen.width + 1e-9));
      expect(c.rect.bottom, lessThanOrEqualTo(screen.height + 1e-9));
    });
  });

  group('resolvePanelScreenRadii（小窗 / 分屏下的非对称屏幕 r 角）', () {
    const Size screen = Size(400, 869);
    // 悬浮胶囊可见本体：左右各 16 内缩、高 64、底端距屏底 12
    const Rect capsule = Rect.fromLTRB(16, 793, 384, 857);
    const double capsuleRadius = 32;

    BorderRadius radiiOf({
      double topLeft = 0,
      double topRight = 0,
      double bottomRight = 0,
      double bottomLeft = 0,
    }) => BorderRadius.only(
      topLeft: Radius.circular(topLeft),
      topRight: Radius.circular(topRight),
      bottomLeft: Radius.circular(bottomLeft),
      bottomRight: Radius.circular(bottomRight),
    );

    test('全屏四角同值：原样透传（正常状态圆角不变）', () {
      final fullscreen = radiiOf(
        topLeft: 58,
        topRight: 58,
        bottomRight: 58,
        bottomLeft: 58,
      );
      expect(resolvePanelScreenRadii(fullscreen), fullscreen);
    });

    test('四角全 0（未上报 / 方角屏）：原样透传，终点本来就是方角', () {
      final zero = radiiOf();
      expect(resolvePanelScreenRadii(zero), zero);
    });

    test('null（未上报）：原样返回，沿用既有「未上报 → 方角」口径', () {
      expect(resolvePanelScreenRadii(null), isNull);
    });

    test('小窗停在屏幕右下（仅 bottomRight 有值）：判为不可信 → 全方角', () {
      expect(
        resolvePanelScreenRadii(radiiOf(bottomRight: 58)),
        BorderRadius.zero,
        reason: '真机报障场景：小窗里过渡动画左方右圆',
      );
    });

    test('贴右停靠（右侧两角有值、左侧无值）：全方角', () {
      expect(
        resolvePanelScreenRadii(radiiOf(topRight: 58, bottomRight: 58)),
        BorderRadius.zero,
      );
    });

    test('贴底停靠（下侧两角有值、上侧无值）：全方角', () {
      expect(
        resolvePanelScreenRadii(radiiOf(bottomLeft: 58, bottomRight: 58)),
        BorderRadius.zero,
      );
    });

    test('贴顶停靠（上侧两角有值、下侧无值）：全方角', () {
      expect(
        resolvePanelScreenRadii(radiiOf(topLeft: 58, topRight: 58)),
        BorderRadius.zero,
      );
    });

    test('贴左下（仅 bottomLeft 有值）：全方角', () {
      expect(
        resolvePanelScreenRadii(radiiOf(bottomLeft: 58)),
        BorderRadius.zero,
      );
    });

    test('四角非零但不相等（物理屏上下圆角不同）：不误伤，原样透传', () {
      final asymmetric = radiiOf(
        topLeft: 40,
        topRight: 40,
        bottomRight: 58,
        bottomLeft: 58,
      );
      expect(resolvePanelScreenRadii(asymmetric), asymmetric);
    });

    test('非有限值 / 负值按「该角无值」处理：与有值角混在一起 → 全方角', () {
      final bad = BorderRadius.only(
        topLeft: Radius.circular(double.nan),
        topRight: const Radius.circular(58),
        bottomRight: const Radius.circular(-1),
        bottomLeft: const Radius.circular(58),
      );
      expect(resolvePanelScreenRadii(bad), BorderRadius.zero);
    });

    test('小窗口径贯穿整段过渡：四角半径恒 0（常驻条源形态）', () {
      final trusted = resolvePanelScreenRadii(radiiOf(bottomRight: 58));
      const Rect resident = Rect.fromLTRB(0, 709, 400, 789);
      for (final p in [0.0, 0.3, 0.6, kPlayerPanelRadiusRetractStart, 1.0]) {
        final c = playerPanelContour(
          progress: p,
          originRect: resident,
          screenSize: screen,
          originRadius: 0,
          screenRadii: trusted,
        );
        expect(c.radius, BorderRadius.zero, reason: 'p=$p');
      }
    });

    test('小窗口径下悬浮胶囊源形态：圆角 32 均匀收到 0，全程不出现单侧圆角', () {
      final trusted = resolvePanelScreenRadii(radiiOf(bottomRight: 58));
      for (final p in [0.0, 0.3, 0.6, 0.9, 1.0]) {
        final c = playerPanelContour(
          progress: p,
          originRect: capsule,
          screenSize: screen,
          originRadius: capsuleRadius,
          screenRadii: trusted,
        );
        final BorderRadius r = c.radius;
        expect(r.topLeft, r.topRight, reason: 'p=$p 上缘左右不同高');
        expect(r.bottomLeft, r.bottomRight, reason: 'p=$p 下缘左右不同高');
        expect(r.topLeft, r.bottomLeft, reason: 'p=$p 同侧上下不同高');
        expect(r.topLeft.x, lessThanOrEqualTo(capsuleRadius + 1e-9));
      }
    });
  });

  group('playerPanelBaseOpacity（底色渐显）', () {
    test('p=0 完全透明、4% 行程后全不透明、之后保持', () {
      expect(playerPanelBaseOpacity(0), 0.0);
      expect(
        playerPanelBaseOpacity(kPlayerPanelBaseFadeSpanRatio / 2),
        closeTo(0.5, 1e-9),
      );
      expect(playerPanelBaseOpacity(kPlayerPanelBaseFadeSpanRatio), 1.0);
      expect(playerPanelBaseOpacity(0.5), 1.0);
      expect(playerPanelBaseOpacity(1), 1.0);
    });

    test('越界与非法输入被钳制', () {
      expect(playerPanelBaseOpacity(-1), 0.0);
      expect(playerPanelBaseOpacity(2), 1.0);
      expect(playerPanelBaseOpacity(double.nan), 0.0);
    });

    test('渐显区间必须远短于页面淡入区间（底色要尽快挡住背后主页面）', () {
      expect(kPlayerPanelBaseFadeSpanRatio, lessThan(kPlayerPanelFadeSpanRatio));
      expect(kPlayerPanelBaseFadeSpanRatio, greaterThan(0));
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
