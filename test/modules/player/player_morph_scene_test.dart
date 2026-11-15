import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_dimens.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_morph_scene.dart';

/// 展开起点几何（`panelAnchorFor`）的来源优先级回归测试。
///
/// 目标：把 W1 定的优先级钉死，并防止"兜底又退回桌面播放栏高 72"。
/// - `scene`（形态快照）优先于一切全局锚点与拖拽参数；
/// - 旧拖拽参数 / 全局锚点的行为不变；
/// - 兜底合成的是**胶囊几何**（底端到屏底、高 = discReservedBottom），
///   不是桌面栏高 [kPlayerFallbackMiniBarHeight]。
///
/// [DraggablePlayerRoute] 的构造不需要 `BuildContext`，故纯 `test` 即可。
void main() {
  const double kScreen = 869;

  setUp(() {
    // 全局锚点是跨用例共享的静态量，留残值会让"兜底"用例失真。
    playerDragOriginTop = 0;
    playerDragOriginBottom = 0;
  });

  tearDown(() {
    playerDragOriginTop = 0;
    playerDragOriginBottom = 0;
  });

  DraggablePlayerRoute<void> makeRoute({
    PlayerMorphScene? scene,
    double? dragOriginTop,
    double? dragOriginBottom,
    double? screenHeight,
  }) => DraggablePlayerRoute<void>(
    builder: (_) => const SizedBox.shrink(),
    scene: scene,
    dragOriginTop: dragOriginTop,
    dragOriginBottom: dragOriginBottom,
    screenHeight: screenHeight,
  );

  group('scene 优先于旧来源', () {
    test('传 scene 时返回 scene.panelRect 的 top / height', () {
      final PlayerMorphScene scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(0, 700, 400, 169),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingCapsule,
      );
      final anchor = makeRoute(scene: scene).panelAnchorFor(kScreen);
      expect(anchor.top, scene.panelTop);
      expect(anchor.height, scene.panelHeight);
      expect(anchor.top, 700);
      expect(anchor.height, 169);
    });

    test('全局锚点有值也被 scene 忽略', () {
      playerDragOriginTop = 640;
      playerDragOriginBottom = 720;
      final PlayerMorphScene scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(0, 793, 400, 76),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingDisc,
      );
      final anchor = makeRoute(scene: scene).panelAnchorFor(kScreen);
      expect(anchor.top, 793);
      expect(anchor.height, 76);
    });

    test('拖拽参数有值也被 scene 覆盖', () {
      final PlayerMorphScene scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(0, 793, 400, 76),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingCapsule,
      );
      final anchor = makeRoute(
        scene: scene,
        dragOriginTop: 600,
        dragOriginBottom: 680,
        screenHeight: kScreen,
      ).panelAnchorFor(kScreen);
      expect(anchor.top, 793);
      expect(anchor.height, 76);
    });

    test('scene 矩形高度为 0 时退回到后面的来源（视为未采集）', () {
      final PlayerMorphScene empty = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(0, 700, 0, 0),
        screenHeight: kScreen,
        form: PlayerBarForm.unknown,
      );
      final anchor = makeRoute(
        scene: empty,
        dragOriginTop: 600,
        dragOriginBottom: 680,
        screenHeight: kScreen,
      ).panelAnchorFor(kScreen);
      expect(anchor.top, 600);
      expect(anchor.height, 80);
    });
  });

  group('panelRadius（起点外轮廓圆角）', () {
    test('显式 cornerRadius 优先', () {
      final scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(16, 793, 368, 64),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingCapsule,
        cornerRadius: 12,
      );
      expect(scene.panelRadius, 12);
    });

    test('胶囊 / 圆盘缺省 = 直径/2（32），圆盘即正圆', () {
      for (final form in [PlayerBarForm.floatingCapsule, PlayerBarForm.floatingDisc]) {
        final scene = PlayerMorphScene(
          panelRect: const Rect.fromLTWH(16, 793, 368, 64),
          screenHeight: kScreen,
          form: form,
        );
        expect(
          scene.panelRadius,
          BottomChromeDimens.discDiameter / 2,
          reason: '$form 的起点圆角必须与真身可见轮廓一致',
        );
      }
    });

    test('常驻条 / unknown 缺省 = 方角（与引入圆角之前一致）', () {
      for (final form in [PlayerBarForm.residentBar, PlayerBarForm.unknown]) {
        final scene = PlayerMorphScene(
          panelRect: const Rect.fromLTWH(0, 709, 400, 80),
          screenHeight: kScreen,
          form: form,
        );
        expect(scene.panelRadius, 0.0);
      }
    });

    test('非法 cornerRadius 回退按形态推导', () {
      final scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(16, 793, 368, 64),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingCapsule,
        cornerRadius: double.nan,
      );
      expect(scene.panelRadius, BottomChromeDimens.discDiameter / 2);
    });

    test('panelGeometryFor：scene 的矩形与圆角原样透传（钳进当前屏）', () {
      final scene = PlayerMorphScene(
        panelRect: const Rect.fromLTWH(16, 793, 368, 64),
        screenHeight: kScreen,
        form: PlayerBarForm.floatingCapsule,
        cornerRadius: 32,
      );
      final g = makeRoute(scene: scene).panelGeometryFor(const Size(400, kScreen));
      expect(g.rect, const Rect.fromLTWH(16, 793, 368, 64));
      expect(g.radius, 32);
    });

    test('panelGeometryFor：无 scene 时读全局锚点的横向范围与圆角', () {
      publishPlayerDragOrigin(
        top: 700,
        bottom: 764,
        left: 16,
        width: 368,
        radius: 32,
      );
      addTearDown(() => publishPlayerDragOrigin(top: 0, bottom: 0));
      final g = makeRoute().panelGeometryFor(const Size(400, kScreen));
      expect(g.rect, const Rect.fromLTWH(16, 700, 368, 64));
      expect(g.radius, 32);
    });

    test('panelGeometryFor：常驻条（通栏、不写横向）→ 整屏宽 + 方角', () {
      publishPlayerDragOrigin(top: 700, bottom: 780);
      addTearDown(() => publishPlayerDragOrigin(top: 0, bottom: 0));
      final g = makeRoute().panelGeometryFor(const Size(400, kScreen));
      expect(g.rect, const Rect.fromLTWH(0, 700, 400, 80));
      expect(g.radius, 0.0);
    });

    test('panelGeometryFor 的纵向与 panelAnchorFor 同源（底栏下沉量的依据）', () {
      publishPlayerDragOrigin(top: 640, bottom: 720, left: 16, width: 368, radius: 32);
      addTearDown(() => publishPlayerDragOrigin(top: 0, bottom: 0));
      final route = makeRoute();
      final anchor = route.panelAnchorFor(kScreen);
      final g = route.panelGeometryFor(const Size(400, kScreen));
      expect(g.rect.top, anchor.top);
      expect(g.rect.height, anchor.height);
    });
  });

  group('兜底改为胶囊几何', () {
    test('无 scene / 无拖拽参数 / 全局锚点为 0：高 = discReservedBottom、底端 = 屏底', () {
      final anchor = makeRoute().panelAnchorFor(kScreen);
      expect(
        anchor.height,
        BottomChromeDimens.discReservedBottom,
        reason: '兜底必须合成胶囊几何（64 + 12），不是别的值',
      );
      expect(
        anchor.height,
        isNot(kPlayerFallbackMiniBarHeight),
        reason: '回归即退回桌面播放栏高 72：移动端没有那条 bar',
      );
      expect(
        anchor.top,
        closeTo(kScreen - BottomChromeDimens.discReservedBottom, 1e-9),
      );
      expect(anchor.top + anchor.height, closeTo(kScreen, 1e-9), reason: '底端必须贴屏底');
      expect(anchor.top, greaterThan(0), reason: '不能合成到屏幕顶端那一条');
    });
  });

  group('旧行为不变', () {
    test('传 dragOriginTop / dragOriginBottom 时取测量值', () {
      final anchor = makeRoute(
        dragOriginTop: 700,
        dragOriginBottom: 780,
        screenHeight: kScreen,
      ).panelAnchorFor(kScreen);
      expect(anchor.top, 700);
      expect(anchor.height, 80);
    });

    test('无拖拽参数时读全局锚点', () {
      playerDragOriginTop = 640;
      playerDragOriginBottom = 720;
      final anchor = makeRoute().panelAnchorFor(kScreen);
      expect(anchor.top, 640);
      expect(anchor.height, 80);
    });

    test('拖拽顶端有值、底端缺省时底端回落到全局锚点（成对写不变）', () {
      playerDragOriginBottom = 700; // 顶端全局仍为 0
      final anchor = makeRoute(dragOriginTop: 620).panelAnchorFor(kScreen);
      expect(anchor.top, 620);
      expect(anchor.height, 80);
    });
  });
}
