import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/fx/waves/distortion_wave_style.dart';
import 'package:md3music/core/fx/waves/wave_reveal.dart';
import 'package:md3music/core/fx/waves/wave_stage.dart';

/// 主机上没有着色器（`WavePrograms.ready == null`），所以这里校的是退路：
/// 不该硬演半截动画，也不该把传进来的那一帧漏着不释放。
void main() {
  group('reverseStageProgress（回缩进度映射）', () {
    final style = DistortionWaveStyle.screenCenter;
    test('τ=0：p=1（波前在屏幕外，源屏定格满屏）', () {
      expect(reverseStageProgress(0.0, style), 1.0);
    });
    test('τ=1：p=0（波前收进源头）', () {
      expect(reverseStageProgress(1.0, style), 0.0);
    });
    test('单调不增（进度只往回收，不许中途掉头）', () {
      var prev = 1.0;
      for (var i = 1; i <= 100; i++) {
        final p = reverseStageProgress(i / 100, style);
        expect(p, lessThanOrEqualTo(prev + 1e-9), reason: 'τ=$i/100');
        prev = p;
      }
    });
  });

  ui.Image solidImage() {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFF3366FF),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(8, 8);
    picture.dispose();
    return image;
  }

  testWidgets('着色器没就绪：不画东西，当帧就回调 onDone', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const ColoredBox(color: Color(0xFF00FF00)),
            WaveReveal(
              image: solidImage(),
              source: const Rect.fromLTWH(20, 20, 120, 120),
              onDone: () => done++,
            ),
          ],
        ),
      ),
    );
    // post-frame 里回调，pumpWidget 结束时已经跑过。
    expect(done, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统要求减少动画：同样直接切换', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Stack(
            children: [
              const ColoredBox(color: Color(0xFF00FF00)),
              WaveReveal(image: solidImage(), onDone: () => done++),
            ],
          ),
        ),
      ),
    );
    expect(done, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('演到一半被摘掉也不抛：那一帧由本组件释放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const ColoredBox(color: Color(0xFF00FF00)),
            WaveReveal(image: solidImage(), onDone: () {}),
          ],
        ),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('反向（回缩）：同样走退路当帧回调，不抛', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const ColoredBox(color: Color(0xFF00FF00)),
            WaveReveal(
              image: solidImage(),
              source: const Rect.fromLTWH(20, 20, 120, 120),
              reverse: true,
              onDone: () => done++,
            ),
          ],
        ),
      ),
    );
    expect(done, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('反向且强制 plain：p=1 画旧帧、p=0 画新页，全程不抛', (tester) async {
    // 强制 plain 走降级分支：reverse 的端点语义在降级路径也不能颠倒。
    final controller = AnimationController(vsync: tester)..value = 1.0;
    Widget stage({required bool reverse}) => Directionality(
      textDirection: TextDirection.ltr,
      child: WaveStage(
        progress: controller,
        reverse: reverse,
        plain: true,
        style: DistortionWaveStyle.screenCenter,
        palette: DistortionWaveStyle.screenCenter.paletteFor(
          ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        programs: null,
        pixelRatio: 1.0,
        source: const Rect.fromLTWH(20, 20, 120, 120),
        contentImage: solidImage(),
        revealed: const ColoredBox(color: Color(0xFF00FF00)),
      ),
    );
    // 反向 p=1（退出起点）：旧帧压满屏。
    await tester.pumpWidget(stage(reverse: true));
    expect(tester.takeException(), isNull);
    // 反向 p=0（退出终点）：新页独占。
    controller.value = 0.0;
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 中段交叉也不抛。
    controller.value = 0.5;
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 正向同一段代码不回归：p=1 新页、p=0 旧帧。
    await tester.pumpWidget(stage(reverse: false));
    controller.value = 1.0;
    await tester.pump();
    controller.value = 0.0;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
