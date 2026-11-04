import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/depth_parallax_cover.dart';

class _FakeTilt {
  final controller = StreamController<(double, double)>.broadcast();
  Stream<(double, double)> call() => controller.stream;
}

// 最小合法 1x1 PNG，避免测试环境解码非法字节报错
const String _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  late Directory tmp;
  late _FakeTilt tilt;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('parallax_test');
    tilt = _FakeTilt();
    final png = base64Decode(_kPngBase64);
    for (var i = 0; i < 3; i++) {
      File('${tmp.path}/layer$i.png').writeAsBytesSync(png);
    }
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: DepthParallaxCover(
            layerPaths: [0, 1, 2].map((i) => '${tmp.path}/layer$i.png').toList(),
            tiltStream: tilt.call(),
          ),
        ),
      );

  testWidgets('渲染 3 层且变换随倾斜输入更新', (tester) async {
    await pump(tester);
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(3));

    tilt.controller.add((0.5, -0.5)); // 注入倾斜
    await tester.pump();
    await tester.pump();
    final transforms = tester
        .widgetList<Transform>(find.byType(Transform))
        .map((t) => t.transform.getTranslation())
        .toList();
    // 三层平移量不同（视差成立）
    expect(transforms.toSet().length, 3);
  });

  testWidgets('绘制顺序：背景在栈底、前景在栈顶（层级不许反）', (tester) async {
    await pump(tester);
    await tester.pump();
    // Stack 首个子项在最底层；背景 scale=1.0、前景 scale=1.06。
    // 用 scale 作为层的指纹，断言背景在最先、前景在最后。
    final scales = tester
        .widgetList<Transform>(find.byType(Transform))
        .map((t) => t.transform.storage[0])
        .toList();
    expect(scales.length, 3);
    expect(scales.first, closeTo(1.0, 0.001), reason: '背景层应在栈底');
    expect(scales.last, closeTo(1.06, 0.001), reason: '前景层应在栈顶');
  });

  // ── 修补底板（「图片修补没生效」的修复）──────────────────────────────────
  //
  // 三条深度带铺满 0..1、合成后 = 原图完整，而修补结果只进 layer0 的背景带
  // （主体 ≈0.9 不在该带里）→ 不铺一张修补底板，前景移开时露出的就是原图里
  // 那份主体（错位重影），用户看到的就是「修补没生效」。
  group('修补底板 backgroundPath', () {
    Future<void> pumpWithPlate(WidgetTester tester, {required bool withPlate}) {
      final plate = '${tmp.path}/bg_fill.png';
      File(plate).writeAsBytesSync(base64Decode(_kPngBase64));
      return tester.pumpWidget(
        MaterialApp(
          home: DepthParallaxCover(
            layerPaths:
                [0, 1, 2].map((i) => '${tmp.path}/layer$i.png').toList(),
            backgroundPath: withPlate ? plate : null,
            tiltStream: tilt.call(),
          ),
        ),
      );
    }

    testWidgets('有底板 → 4 张图，且底板在栈最底层（内部第 1 个图）', (tester) async {
      await pumpWithPlate(tester, withPlate: true);
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(4));
      // 底板与 layer0 同变换（scale 1.0）；顺序上底板必须是第一个
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images.length, 4);
      final firstPath = (images.first.image as FileImage).file.path;
      expect(firstPath, endsWith('bg_fill.png'),
          reason: '底板必须最先（最底层）：它只在前景移开处露出');
      final scales = tester
          .widgetList<Transform>(find.byType(Transform))
          .map((t) => t.transform.storage[0])
          .toList();
      expect(scales.first, closeTo(1.0, 0.001), reason: '底板与背景层同尺度');
      expect(scales.last, closeTo(1.06, 0.001), reason: '前景仍在栈顶');
    });

    testWidgets('无底板（旧缓存 / Android）→ 仍是 3 层，行为与旧版一致',
        (tester) async {
      await pumpWithPlate(tester, withPlate: false);
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(3));
    });
  });
}
