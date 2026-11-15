// PlayPauseMorphIcon 双轨实心形变测试。
//
// 回归点：
// 1) 左轨几何：t=0 为实心三角（左缘钉住 x=6.5、右尖 x≈20.5），t=1 为左竖条
//    （右缘 x=9.5、全高 15）；
// 2) 右轨：t=0.2 不可见（右轨 0.30 才起步），t=1 全高 15 单位、圆角 ≤ 半宽；
// 3) roundedPolygonPath：角点圆化、重合角点不崩、路径闭合；
// 4) Widget：isPlaying 初始值即静止帧；翻转后向目标值动画（Task 2 补齐）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/widgets/play_pause_morph_icon.dart';

void main() {
  group('playPauseLeftCorners', () {
    test('t=0 为播放三角：左缘钉住、右尖在 x≈20.5', () {
      final List<Offset> pts = playPauseLeftCorners(0.0);
      expect(pts[0], const Offset(6.5, 4.5)); // 左上
      expect(pts[3], const Offset(6.5, 19.5)); // 左下
      expect(pts[1].dx, closeTo(20.5, 0.01)); // 右尖上
      expect(pts[2].dx, closeTo(20.5, 0.01)); // 右尖下
      // 尖端微小切面（上下两点不重合，供圆角钳制）
      expect((pts[2].dy - pts[1].dy).abs(), closeTo(1.3, 0.01));
    });

    test('t=1 为左竖条：右缘 x=9.5、全高', () {
      final List<Offset> pts = playPauseLeftCorners(1.0);
      expect(pts[1], const Offset(9.5, 4.5));
      expect(pts[2], const Offset(9.5, 19.5));
    });

    test('右尖随 t 单调回缩', () {
      final double x1 = playPauseLeftCorners(0.2)[1].dx;
      final double x2 = playPauseLeftCorners(0.5)[1].dx;
      final double x3 = playPauseLeftCorners(1.0)[1].dx;
      expect(x1, greaterThan(9.5));
      expect(x1, lessThan(20.5));
      expect(x2, lessThan(x1));
      expect(x3, lessThan(x2));
    });
  });

  group('playPauseRightBar', () {
    test('t=0.2 尚未出现（右轨 0.30 才起步）', () {
      expect(playPauseRightBar(0.2), isNull);
      expect(playPauseRightBarProgress(0.2), 0.0);
    });

    test('t=1 全高 15 单位、宽度固定 3、圆角不超过半宽', () {
      final RRect bar = playPauseRightBar(1.0)!;
      expect(bar.left, closeTo(14.5, 0.01));
      expect(bar.right, closeTo(17.5, 0.01));
      expect(bar.top, closeTo(12 - 7.5, 0.01));
      expect(bar.bottom, closeTo(12 + 7.5, 0.01));
      expect(bar.blRadiusX, lessThanOrEqualTo(1.5));
    });

    test('高度从垂直中心对称长高', () {
      final RRect bar = playPauseRightBar(0.6)!;
      expect(bar.top, lessThan(12));
      expect(bar.bottom, greaterThan(12));
      expect(12 - bar.top, closeTo(bar.bottom - 12, 0.01));
      expect(bar.bottom - bar.top, lessThan(15));
    });
  });

  group('roundedPolygonPath', () {
    test('方形角点圆化：边界不越界、角部被切、路径闭合', () {
      const List<Offset> square = <Offset>[
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 10),
        Offset(0, 10),
      ];
      final Path path = roundedPolygonPath(square, 2);
      final Rect bounds = path.getBounds();
      expect(bounds.left, 0.0);
      expect(bounds.top, 0.0);
      expect(bounds.right, 10.0);
      expect(bounds.bottom, 10.0);
      // 直角点附近的角部区域被圆角切掉
      expect(path.contains(const Offset(0.2, 0.2)), isFalse);
      expect(path.contains(const Offset(5, 5)), isTrue);
      expect(path.computeMetrics().first.isClosed, isTrue);
    });

    test('重合角点不崩', () {
      const List<Offset> degenerate = <Offset>[
        Offset(0, 0),
        Offset(10, 10),
        Offset(10, 10),
        Offset(0, 20),
      ];
      final Path path = roundedPolygonPath(degenerate, 1.5);
      expect(path.computeMetrics().first.isClosed, isTrue);
    });

    test('半径大于半边长时钳制为半边长（细长条端部全圆不越界）', () {
      const List<Offset> bar = <Offset>[
        Offset(0, 0),
        Offset(3, 0),
        Offset(3, 20),
        Offset(0, 20),
      ];
      final Path path = roundedPolygonPath(bar, 5);
      final Rect bounds = path.getBounds();
      expect(bounds.width, closeTo(3, 0.01));
      expect(bounds.height, closeTo(20, 0.01));
    });
  });

  group('PlayPauseMorphIcon widget', () {
    Future<PlayPauseMorphIconState> pumpHost(
      WidgetTester tester,
      bool isPlaying,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: PlayPauseMorphIcon(isPlaying: isPlaying)),
          ),
        ),
      );
      await tester.pump();
      return tester.state<PlayPauseMorphIconState>(
        find.byType(PlayPauseMorphIcon),
      );
    }

    testWidgets('isPlaying=true 初始即暂停形态静止帧（无入场动画）', (tester) async {
      final PlayPauseMorphIconState state = await pumpHost(tester, true);
      expect(state.progress, 1.0);
    });

    testWidgets('isPlaying=false 初始即播放形态', (tester) async {
      final PlayPauseMorphIconState state = await pumpHost(tester, false);
      expect(state.progress, 0.0);
    });

    testWidgets('isPlaying 翻转为 false 后反向动画回播放形态', (tester) async {
      await pumpHost(tester, true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: PlayPauseMorphIcon(isPlaying: false)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      final PlayPauseMorphIconState state =
          tester.state<PlayPauseMorphIconState>(
        find.byType(PlayPauseMorphIcon),
      );
      expect(state.progress, greaterThan(0.0));
      expect(state.progress, lessThan(1.0));
      await tester.pumpAndSettle();
      expect(state.progress, 0.0);
    });

    testWidgets('isPlaying 翻转为 true 后正向动画到暂停形态', (tester) async {
      await pumpHost(tester, false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: PlayPauseMorphIcon(isPlaying: true)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      final PlayPauseMorphIconState state =
          tester.state<PlayPauseMorphIconState>(
        find.byType(PlayPauseMorphIcon),
      );
      expect(state.progress, greaterThan(0.0));
      expect(state.progress, lessThan(1.0));
      await tester.pumpAndSettle();
      expect(state.progress, 1.0);
    });

    testWidgets('渲染不抛异常且 CustomPaint 在树上', (tester) async {
      await pumpHost(tester, true);
      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
