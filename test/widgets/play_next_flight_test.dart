// 「下一首播放」封面跳水动画：弧线数学 / 全局控制器生命周期。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/play_next_flight.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PlayNextFlightController.instance.reset();
  });

  group('PlayNextFlightPath', () {
    PlayNextFlightSpec specFor(Rect start, Rect target, double screenWidth) =>
        PlayNextFlightSpec(
          artworkUri: null,
          fallbackFilePath: null,
          songId: 's1',
          start: start,
          target: target,
          screenWidth: screenWidth,
        );

    test('evaluate：t=0 起点、t=1 终点、t=0.5 为三点加权中点', () {
      final spec = specFor(
        Rect.fromLTWH(100, 400, 32, 32),
        Rect.fromLTWH(10, 800, 44, 44),
        400,
      );
      final path = PlayNextFlightPath.fromSpec(spec);
      expect(path.evaluate(0), spec.start.center);
      expect(path.evaluate(1), spec.target.center);
      // 二次贝塞尔 t=0.5 = (p0 + 2·p1 + p2) / 4
      final expected = (spec.start.center +
              spec.target.center +
              path.p1 * 2) /
          4;
      final mid = path.evaluate(0.5);
      expect(mid.dx, closeTo(expected.dx, 0.001));
      expect(mid.dy, closeTo(expected.dy, 0.001));
    });

    test('弧线鼓向屏幕中心一侧（起终点在左半屏、近乎竖直 → 鼓包向右）', () {
      final spec = specFor(
        Rect.fromLTWH(30, 400, 32, 32),
        Rect.fromLTWH(10, 800, 44, 44),
        400,
      );
      final path = PlayNextFlightPath.fromSpec(spec);
      final midDx = (spec.start.center.dx + spec.target.center.dx) / 2;
      expect(path.p1.dx, greaterThan(midDx));
    });

    test('起终点几乎重合时控制点退化为中点（防除零）', () {
      // 圆心距 < 1px：start center (66, 516) / target center (66.5, 516.2)
      final spec = specFor(
        const Rect.fromLTWH(50, 500, 32, 32),
        const Rect.fromLTWH(44.5, 494.2, 44, 44),
        400,
      );
      final path = PlayNextFlightPath.fromSpec(spec);
      const mid = Offset(66.25, 516.1);
      expect(path.p1, mid);
      expect(path.evaluate(0.5), mid);
    });
  });

  group('PlayNextFlightController', () {
    PlayNextFlightSpec specAt(double y) => PlayNextFlightSpec(
          artworkUri: null,
          fallbackFilePath: null,
          songId: 's1',
          start: Rect.fromLTWH(100, y, 32, 32),
          target: const Rect.fromLTWH(10, 800, 44, 44),
          screenWidth: 400,
        );

    test('launch 写入 spec；reset 后 Future 完成', () async {
      final c = PlayNextFlightController.instance;
      var landed = false;
      final done = c.launch(specAt(400)).then((_) => landed = true);
      expect(c.spec.value, isNotNull);
      expect(landed, isFalse); // 动画未结束前 Future 挂起
      c.reset();
      await done;
      expect(landed, isTrue);
    });

    test('新 launch 顶替旧飞行：旧 Future 立即完成、spec 换新', () async {
      final c = PlayNextFlightController.instance;
      final first = c.launch(specAt(400));
      final second = c.launch(specAt(500));
      await first; // 被顶替 → 立即完成
      expect(c.spec.value!.start.top, 500);
      c.reset();
      await second;
    });
  });

  group('PlayNextFlightLayer（端到端绘制）', () {
    testWidgets('launch 后显示小球：0.5s 俯冲 + 0.3s 展开后自动清除', (tester) async {
      const ballKey = ValueKey('play_next_flight_ball');
      const target = Rect.fromLTWH(10, 750, 44, 44);
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: const [
              SizedBox.expand(),
              // 模拟 MiniPlayer 封面落点（视觉锚点，不参与逻辑）
              Positioned(
                left: 10,
                top: 750,
                width: 44,
                height: 44,
                child: ColoredBox(color: Colors.red),
              ),
              PlayNextFlightLayer(),
            ],
          ),
        ),
      );
      expect(find.byKey(ballKey), findsNothing);

      PlayNextFlightController.instance.launch(
        PlayNextFlightSpec(
          artworkUri: null,
          fallbackFilePath: null,
          songId: 's1',
          start: const Rect.fromLTWH(100, 400, 32, 32),
          target: target,
          screenWidth: 400,
        ),
      );
      await tester.pump(); // 球上树（俯冲 t=0）
      expect(find.byKey(ballKey), findsOneWidget);
      // t=0：球在起点（32×32 圆，左上角 = start 左上角）
      expect(tester.getTopLeft(find.byKey(ballKey)),
          const Offset(100, 400));

      await tester.pump(const Duration(milliseconds: 250)); // 俯冲中段
      expect(find.byKey(ballKey), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400)); // 俯冲完 + 展开中段
      // 展开中：尺寸在 32~44 之间
      final midSize = tester.getSize(find.byKey(ballKey));
      expect(midSize.width, inInclusiveRange(32, 44));

      await tester.pumpAndSettle(); // 跑完展开 + 自清除
      expect(find.byKey(ballKey), findsNothing);
      expect(PlayNextFlightController.instance.spec.value, isNull);
    });

    testWidgets('顶替飞行：旧球立即消失、新球从头开始', (tester) async {
      const ballKey = ValueKey('play_next_flight_ball');
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(
            children: [
              SizedBox.expand(),
              PlayNextFlightLayer(),
            ],
          ),
        ),
      );
      PlayNextFlightController.instance.launch(PlayNextFlightSpec(
        artworkUri: null,
        fallbackFilePath: null,
        songId: 's1',
        start: const Rect.fromLTWH(100, 400, 32, 32),
        target: const Rect.fromLTWH(10, 750, 44, 44),
        screenWidth: 400,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 俯冲过半
      expect(find.byKey(ballKey), findsOneWidget);

      PlayNextFlightController.instance.launch(PlayNextFlightSpec(
        artworkUri: null,
        fallbackFilePath: null,
        songId: 's2',
        start: const Rect.fromLTWH(200, 300, 32, 32),
        target: const Rect.fromLTWH(10, 750, 44, 44),
        screenWidth: 400,
      ));
      await tester.pump();
      // 新球在它自己的起点附近（x≈200 一带），而非旧球轨迹上
      expect(tester.getTopLeft(find.byKey(ballKey)).dx, greaterThan(150));
      await tester.pumpAndSettle();
      expect(find.byKey(ballKey), findsNothing);
    });
  });
}
