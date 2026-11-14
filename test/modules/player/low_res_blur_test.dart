import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/player/widgets/low_res_blur.dart';

/// 造一张纯色源图（长边 [w]×[h]，中灰）：不依赖解码器，像素内容可预期。
Future<ui.Image> _solidImage(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF808080),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildLowResBlurProxy', () {
    test('合法输入：长边缩到 96 上限、保持目标盒宽高比', () async {
      final src = await _solidImage(200, 200);
      addTearDown(src.dispose);
      // 300×200 的盒：scale=96/300=0.32 → 96×64
      final proxy = buildLowResBlurProxy(src, 24.0, const Size(300, 200));
      expect(proxy, isNotNull);
      expect(proxy!.width, 96);
      expect(proxy.height, 64);
      proxy.dispose();
    });

    test('目标盒长边 ≤96 时不放大（scale=1）', () async {
      final src = await _solidImage(200, 200);
      addTearDown(src.dispose);
      final proxy = buildLowResBlurProxy(src, 10.0, const Size(40, 80));
      expect(proxy, isNotNull);
      expect(proxy!.width, 40);
      expect(proxy.height, 80);
      proxy.dispose();
    });

    test('非法输入一律返回 null（调用方退滤镜兜底）', () async {
      final src = await _solidImage(200, 200);
      addTearDown(src.dispose);
      expect(buildLowResBlurProxy(null, 24.0, const Size(300, 300)), isNull);
      expect(buildLowResBlurProxy(src, 0.0, const Size(300, 300)), isNull);
      expect(buildLowResBlurProxy(src, -1.0, const Size(300, 300)), isNull);
      expect(buildLowResBlurProxy(src, 24.0, Size.zero), isNull);
      expect(
        buildLowResBlurProxy(src, 24.0, const Size(double.infinity, 100)),
        isNull,
      );
    });

    test('快照不透明（铺满绘制不需要清晰底层）', () async {
      final src = await _solidImage(200, 200);
      addTearDown(src.dispose);
      final proxy = buildLowResBlurProxy(src, 24.0, const Size(100, 100))!;
      addTearDown(proxy.dispose);
      final data = await proxy.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      // 中心像素：源是中灰不透明，模糊后仍应不透明（alpha=255）
      final px = (proxy.width ~/ 2) + (proxy.height ~/ 2) * proxy.width;
      expect(data!.getUint8(px * 4 + 3), 255);
    });
  });

  group('LowResBlurCover', () {
    Widget host(String? uri, {double sigma = 40}) => MaterialApp(
      home: SizedBox(
        width: 200,
        height: 200,
        child: LowResBlurCover(
          artworkUri: uri,
          blurSigma: sigma,
          fallback: const Center(child: Text('fb')),
        ),
      ),
    );

    testWidgets('无 URI / 源解析不了：渲染 fallback（与未优化时一致）', (
      tester,
    ) async {
      await tester.pumpWidget(host(null));
      expect(find.text('fb'), findsOneWidget);
      // 非法 URI（不是 http/file 形态）：provider 造不出来 → 永久 fallback
      await tester.pumpWidget(host('local://no-bytes'));
      await tester.pump();
      expect(find.text('fb'), findsOneWidget);
    });

    testWidgets('强度低于闸门（σ<30）：不建快照，始终 fallback', (
      tester,
    ) async {
      const pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final dir = Directory.systemTemp.createTempSync('md3_lowres_gate');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/g.png')..writeAsBytesSync(
        base64Decode(pngBase64),
      );
      final uri = Uri.file(file.path).toString();
      // σ=10（低于 kLowResBlurMinSigma=30）：真封面也不走低分辨率路径。
      await tester.runAsync(() async {
        await tester.pumpWidget(host(uri, sigma: 10));
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      expect(find.text('fb'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LowResBlurPainter,
        ),
        findsNothing,
      );
    });

    testWidgets('file:// 封面：小卷积快照就绪后替换 fallback；换歌到不可解析源立即撤快照', (
      tester,
    ) async {
      // 真 1×1 PNG 落到临时目录（与 full_player_am_cover_flip_test 同款）。
      const pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final dir = Directory.systemTemp.createTempSync('md3_lowres_blur');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/c.png')..writeAsBytesSync(
        base64Decode(pngBase64),
      );
      final uri = Uri.file(file.path).toString();

      // 解析走真实 IO/解码，需要 runAsync 放行定时器与 microtask。
      await tester.runAsync(() async {
        await tester.pumpWidget(host(uri));
        for (var i = 0; i < 20 && find.text('fb').evaluate().isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      // 快照就绪：fallback 被 CustomPaint 替换（不再含 'fb'）。
      expect(find.text('fb'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LowResBlurPainter,
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        // 换到解析不了的源：在飞窗口旧快照可短暂顶显示，但最终必须撤掉
        // 走 fallback——绝不把旧封面永久铺在当前层上。
        await tester.pumpWidget(host('local://no-bytes'));
        for (var i = 0; i < 20 && find.text('fb').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      expect(find.text('fb'), findsOneWidget);
    });
  });
}
