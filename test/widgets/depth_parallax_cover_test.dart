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
}
