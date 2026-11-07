import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/core/layout/ui_density.dart';
import 'package:md3music/core/widgets/windows_window_frame.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

/// Windows 标题栏（32dp）与「设计像素锚点」的几何契约。
///
/// 现象：封面飞行动画整段低一条标题栏、落位时向上跳 32dp。
/// 根因：探针（`DisplayScaleReference` 锚点空间）量到的是**含标题栏**的整窗坐标，
/// 而顶层浮层若挂在 `WindowsWindowFrame` 内部，就按正文局部坐标画 —— 差 32dp。
///
/// 本测试按生产装配搭一棵最小树：正文（Frame 内）+ 顶层飞行层（Frame 外、与
/// 锚点同级），把「终点」设成正文里一个真实子件的锚点矩形，断言飞行层画出的
/// 矩形**与它逐像素重合**。若把飞行层挪回 Frame 内部，这里会整体低 32dp。
void main() {
  testWidgets('正文里的目标矩形与顶层飞行层落点逐像素重合（含 32dp 标题栏）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final bus = PlaylistCoverFlightBus.instance;
    bus.debugReset();
    addTearDown(bus.debugReset);

    const sourceKey = ValueKey('windows_space_source');
    const destKey = ValueKey('windows_space_dest');
    const tag = 'md3/playlist-cover/space-test';

    await tester.pumpWidget(
      MaterialApp(
        home: DisplayScaleScope(
          scale: 1.0,
          child: Stack(
            children: [
              // 正文：Frame 内部（Windows 上标题栏把整棵子树下移 32dp）。
              WindowsWindowFrame(
                child: Stack(
                  children: const [
                    Positioned(
                      left: 40,
                      top: 60,
                      width: 60,
                      height: 60,
                      child: SizedBox(
                        key: sourceKey,
                        child: ColoredBox(color: Color(0xFFFF0000)),
                      ),
                    ),
                    Positioned(
                      left: 300,
                      top: 200,
                      width: 140,
                      height: 140,
                      child: SizedBox(
                        key: destKey,
                        child: ColoredBox(color: Color(0xFF0000FF)),
                      ),
                    ),
                  ],
                ),
              ),
              // 顶层飞行层：与 App 级设计像素锚点同空间（Frame 之外）。
              const Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: Stack(children: [PlaylistCoverFlightLayer()]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = DisplayScaleReference.anchorOf(
      tester.element(find.byKey(sourceKey)),
    );
    expect(anchor, isNotNull, reason: '缺少设计像素锚点');

    Rect anchorRect(Key key) {
      final box = tester.renderObject<RenderBox>(find.byKey(key));
      return MatrixUtils.transformRect(
        box.getTransformTo(anchor),
        Offset.zero & box.size,
      );
    }

    final sourceRect = anchorRect(sourceKey);
    final destRect = anchorRect(destKey);
    // 标题栏 32dp 确实插入了正文之上：这两个 y 就是「锚点空间」里的真实值。
    expect(sourceRect.top, 92, reason: '32dp 标题栏 + 正文内 top=60');
    expect(destRect.top, 232, reason: '32dp 标题栏 + 正文内 top=200');

    final source = bus.registerSource(
      tag,
      Object(),
      BorderRadius.zero,
      const ColoredBox(color: Color(0xFFFF0000)),
    );
    bus.debugPublish(source, rect: sourceRect);
    bus.beginFlight(
      source: source,
      destRadius: BorderRadius.circular(12),
      content: const ColoredBox(color: Color(0xFF0000FF)),
      destRect: destRect,
      // 进度钉在 1（落位）+ held：飞行层保持在终点矩形上出帧。
      routeAnimation: const AlwaysStoppedAnimation<double>(1.0),
      beginValue: 0.0,
      isPop: false,
      held: true,
    );
    await tester.pump(); // 登记簿微任务派发 → 标脏
    await tester.pump(); // 重建出帧

    final flying = tester.getRect(
      find.descendant(
        of: find.byType(PlaylistCoverFlightLayer),
        matching: find.byType(ClipRRect),
      ),
    );
    final reason =
        '顶层飞行层必须与设计像素锚点同空间；低 32dp 就说明它被放回了 '
        'WindowsWindowFrame 内部（封面落位会向上跳）。';
    expect(flying.left, closeTo(destRect.left, 0.01), reason: reason);
    expect(flying.top, closeTo(destRect.top, 0.01), reason: reason);
    expect(flying.width, closeTo(destRect.width, 0.01), reason: reason);
    expect(flying.height, closeTo(destRect.height, 0.01), reason: reason);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
