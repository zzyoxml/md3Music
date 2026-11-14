import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/depth_shader_cover.dart';

void main() {
  group('shiftScaleFor（ShengChao strengthScale 对齐）', () {
    test('层次丰富（std=0.18）→ 1.0', () {
      expect(DepthShaderCover.shiftScaleFor(0.18), closeTo(1.0, 1e-6));
    });
    test('层次平（std=0.09）→ 放大到 2.0', () {
      expect(DepthShaderCover.shiftScaleFor(0.09), closeTo(2.0, 1e-6));
    });
    test('极平（std=0.05）→ 上限 2.5；极丰富（std=0.3）→ 下限 0.6', () {
      expect(DepthShaderCover.shiftScaleFor(0.05), closeTo(2.5, 1e-6));
      expect(DepthShaderCover.shiftScaleFor(0.3), closeTo(0.6, 1e-6));
    });
    test('std=0（异常兜底）→ 1.0', () {
      expect(DepthShaderCover.shiftScaleFor(0.0), 1.0);
    });
  });

  group('bgFillPath 构造面', () {
    testWidgets('bgFillPath 为可选参数；测试环境 shader/纹理加载失败时优雅降级不抛异常',
        (tester) async {
      var failed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: DepthShaderCover(
                coverPath: 'nonexistent_cover.img',
                depthPath: 'nonexistent_depth.img',
                depthStd: 0.2,
                tiltStream: const Stream.empty(),
                strengthPx: 9.0,
                bgFillPath: null, // 不传时行为必须与旧版完全一致
                onFailed: () => failed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // _load 链上有多个真实 IO 等待点（shader 资产加载、文件读取），
      // fake async 均不放行 → 循环 runAsync（真实事件循环）+ pump（flush 微任务）
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      // 占位 Image.file 在测试环境必然加载失败（文件不存在），属预期降级表现；
      // 关键断言：未捕获异常仅为该预期类型，且 onFailed 降级回调已触发
      final err = tester.takeException();
      expect(err, anyOf(isNull, isA<PathNotFoundException>()));
      expect(failed, isTrue);
    });
  });
}
