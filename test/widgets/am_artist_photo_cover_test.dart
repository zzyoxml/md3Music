// test/widgets/am_artist_photo_cover_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/am_artist_photo_cover.dart';
import 'package:md3music/modules/player/full_player_route.dart'
    show playerExpansion;

void _mockPathProvider() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

Future<void> pumpCover(WidgetTester tester, String? url) async {
  _mockPathProvider();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 800,
          child: AmArtistPhotoCover(currentUrl: ValueNotifier(url)),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 在遮罩渐变上求 y 处的 alpha（stops 分段线性）。
double _alphaAt(LinearGradient g, double y) {
  final stops = g.stops!, colors = g.colors;
  if (y <= stops.first) return colors.first.a;
  if (y >= stops.last) return colors.last.a;
  for (var i = 1; i < stops.length; i++) {
    if (y <= stops[i]) {
      final span = stops[i] - stops[i - 1];
      final t = span == 0 ? 1.0 : (y - stops[i - 1]) / span;
      return colors[i - 1].a + (colors[i].a - colors[i - 1].a) * t;
    }
  }
  return 0;
}

/// 横向渐变求 x（px）处 alpha（400 宽容器，stops 为 0..1 归一）。
double _alphaAtH(LinearGradient g, double xPx) => _alphaAt(g, xPx / 400.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('统一模糊 + alpha 过渡（800dp 高容器：top=0.15，bottom=0.75）', () {
    test('两枚遮罩：最外缘 alpha=0（消融进背景），中部=1（不压暗）', () {
      for (final g in [amPhotoMasterFade(800), amPhotoSharpMask(800)]) {
        expect(g.colors.first.a, 0.0);
        expect(g.colors.last.a, 0.0);
        expect(_alphaAt(g, 0.4), 1.0);
        expect(_alphaAt(g, 0.6), 1.0);
      }
    });

    test('stops 严格升序（主罩与清晰罩都不许乱序/交叉）', () {
      for (final g in [amPhotoMasterFade(800), amPhotoSharpMask(800)]) {
        final stops = g.stops!;
        for (var i = 1; i < stops.length; i++) {
          expect(stops[i], greaterThan(stops[i - 1]));
        }
      }
    });

    test('smoothstep 过渡（带心处低于线性中点，无直线折点）', () {
      final g = amPhotoMasterFade(800);
      // 顶带 [0, 0.15]：f=0.25 处 smoothstep≈0.156 < 0.25
      expect(_alphaAt(g, 0.15 * 0.25), lessThan(0.25));
      // f=0.75 处 smoothstep≈0.844 > 0.75
      expect(_alphaAt(g, 0.15 * 0.75), greaterThan(0.75));
    });

    test('清晰罩提前升满（0.8*top 处已=1），与主罩收尾错开', () {
      final sharp = amPhotoSharpMask(800);
      expect(_alphaAt(sharp, 0.15 * 0.8), greaterThanOrEqualTo(0.999));
      // 主罩此时仍在收尾（<1），两层不会同时半透明产生条带
      final master = amPhotoMasterFade(800);
      expect(_alphaAt(master, 0.15 * 0.8), lessThan(1.0));
    });

    test('回归钉：不透明标记必须为白色（黑色会被 modulate 乘成纯黑）', () {
      for (final g in [amPhotoMasterFade(800), amPhotoSharpMask(800)]) {
        final opaque = g.colors.firstWhere((c) => c.a > 0.99);
        expect(opaque.r, 1.0);
        expect(opaque.g, 1.0);
        expect(opaque.b, 1.0);
      }
    });

    test('矮容器（200dp）：羽化带压缩不交叉', () {
      for (final g in [amPhotoMasterFade(200), amPhotoSharpMask(200)]) {
        final stops = g.stops!;
        for (var i = 1; i < stops.length; i++) {
          expect(stops[i], greaterThan(stops[i - 1]));
        }
      }
    });

    test('模糊 sigma 随容器缩放：竖屏大封面上限 16，小封面按比例收窄', () {
      expect(amPhotoBlurSigma(553), 16.0); // 553*0.03=16.6 → 钳到上限
      expect(amPhotoBlurSigma(248), closeTo(7.44, 1e-9)); // 横屏左栏
      expect(amPhotoBlurSigma(120), 6.0); // 120*0.03=3.6 → 钳到下限
    });

    test('小封面（270dp 横屏左栏）：带高按比例收窄，中部保持清晰', () {
      const h = 270.0;
      final master = amPhotoMasterFade(h);
      // 顶带 = min(120, 270*0.25=67.5) → stop 0.25；底带 35% → 0.65。
      expect(_alphaAt(master, 0.25), greaterThanOrEqualTo(0.999));
      expect(_alphaAt(master, 0.4), 1.0);
      expect(_alphaAt(master, 0.6), 1.0);
      expect(_alphaAt(master, 0.75), lessThan(1.0));
      // 旧固定 dp 时两带会吃掉 0.44+0.74 的空间——中部不可能全不透明
    });
  });

  testWidgets('url=null → 收缩为 SizedBox，无图片无遮罩', (tester) async {
    await pumpCover(tester, null);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(const Key('amArtistPhotoMasterFade')), findsNothing);
  });

  testWidgets('有图 → 统一模糊底 + 清晰层 + 主淡出罩', (tester) async {
    await pumpCover(tester, 'https://photo.invalid/a.jpg');
    expect(tester.takeException(), isNull);
    // 同一张图渲染两遍（模糊底 + 清晰层）
    expect(find.byType(CachedNetworkImage), findsNWidgets(2));
    // 只有一档统一模糊
    expect(find.byType(ImageFiltered), findsOneWidget);
    for (final key in ['amArtistPhotoMasterFade', 'amArtistPhotoSharpMask']) {
      final mask = tester.widget<ShaderMask>(find.byKey(Key(key)));
      expect(mask.blendMode, BlendMode.modulate);
    }
    // 主罩包住整个 Stack（模糊层与清晰层都在其内）
    expect(
      find.ancestor(
        of: find.byKey(const Key('amArtistPhotoSharpMask')),
        matching: find.byKey(const Key('amArtistPhotoMasterFade')),
      ),
      findsOneWidget,
    );
  });

  group('左右缘过渡（横屏出血层：两侧平滑消融）', () {
    test('主罩：左右外缘透明，向中部平滑过渡并保持平台', () {
      final g = amPhotoRightFade(400);
      expect(_alphaAtH(g, 0.0), 0.0);
      expect(_alphaAtH(g, 70.0), greaterThan(0.0));
      expect(_alphaAtH(g, 70.0), lessThan(1.0));
      expect(_alphaAtH(g, 140.0), 1.0);
      expect(_alphaAtH(g, 200.0), 1.0);
      expect(_alphaAtH(g, 260.0), 1.0);
      expect(_alphaAtH(g, 330.0), lessThan(1.0));
      expect(_alphaAtH(g, 400.0), 0.0);
      final stops = g.stops!;
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
      for (var x = 1.0; x <= 140; x += 1) {
        expect(_alphaAtH(g, x), greaterThanOrEqualTo(_alphaAtH(g, x - 1)));
      }
      for (var x = 261.0; x <= 400; x += 1) {
        expect(_alphaAtH(g, x), lessThanOrEqualTo(_alphaAtH(g, x - 1)));
      }
      expect(g.begin, Alignment.centerLeft);
      expect(g.end, Alignment.centerRight);
    });

    test('清晰罩提前降完（带宽 80% 处已透明，末端留给主罩收尾）', () {
      final sharp = amPhotoSharpMaskRight(400);
      // 带 = min(200, 400*0.35=140) = 140 → 起点 260；80% 处 x=372
      expect(_alphaAtH(sharp, 260), 1.0);
      expect(_alphaAtH(sharp, 260 + 140 * 0.8), lessThanOrEqualTo(0.001));
      expect(_alphaAtH(sharp, 400), 0.0);
      // 主罩此时仍在收尾（>0），两层不会同时全透明
      expect(_alphaAtH(amPhotoRightFade(400), 372), greaterThan(0.0));
    });

    test('回归钉：两侧遮罩不透明标记为白色', () {
      for (final g in [amPhotoRightFade(400), amPhotoSharpMaskRight(400)]) {
        final opaque = g.colors.firstWhere((c) => c.a > 0.99);
        expect(opaque.r, 1.0);
        expect(opaque.g, 1.0);
        expect(opaque.b, 1.0);
      }
    });
  });

  testWidgets('feather=rightEdge → 两枚右缘遮罩 key + ClipRect 存在', (
    tester,
  ) async {
    _mockPathProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 600,
            child: AmArtistPhotoCover(
              currentUrl: ValueNotifier('https://photo.invalid/a.jpg'),
              feather: AmPhotoFeather.rightEdge,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('amArtistPhotoRightFade')), findsOneWidget);
    expect(find.byKey(const Key('amArtistPhotoSharpRight')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(ImageFiltered),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
    );
  });

  for (final width in [1264.0, 1023.0]) {
    for (final dpr in [1.0, 1.25]) {
      testWidgets('分数分栏 $width / $dpr：全页滤镜与遮罩，右栏 alpha=0', (tester) async {
        _mockPathProvider();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, 681 * dpr);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          home: AmArtistPhotoCover(
            currentUrl: ValueNotifier('https://photo.invalid/a.jpg'),
            feather: AmPhotoFeather.rightEdge,
            photoWidthFraction: 0.4,
          ),
        ));
        await tester.pump();
        final master = find.byKey(const Key('amArtistPhotoRightFade'));
        expect(tester.getSize(master).width, closeTo(width, 0.01));
        expect(tester.getSize(find.byType(ImageFiltered)).width, closeTo(width, 0.01));
        for (final photo in find.byType(CachedNetworkImage).evaluate()) {
          expect(tester.getSize(find.byWidget(photo.widget)).width, closeTo(width * 0.4, 0.01));
        }
        final mask = tester.widget<ShaderMask>(master);
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          final rect = Rect.fromLTWH(0, 0, width, 10);
          canvas.drawRect(rect, Paint()..shader = mask.shaderCallback(rect));
          final picture = recorder.endRecording();
          final image = await picture.toImage(width.ceil(), 10);
          final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          int alpha(int x) => data.getUint8((5 * width.ceil() + x) * 4 + 3);
          expect(alpha((width * 0.2).floor()), 255);
          expect(alpha((width * 0.4).ceil() + 1), 0);
          expect(alpha(width.floor() - 1), 0);
          image.dispose();
          picture.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('vertical 档同样被 ClipRect 包住（修竖屏滑动穿帮）', (
    tester,
  ) async {
    await pumpCover(tester, 'https://photo.invalid/a.jpg');
    expect(
      find.ancestor(
        of: find.byKey(const Key('amArtistPhotoMasterFade')),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
    );
  });

  testWidgets('两枚图片层 key 唯一（同 Stack 重复 ValueKey 会闪）', (
    tester,
  ) async {
    await pumpCover(tester, 'https://photo.invalid/a.jpg');
    final images = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    ).toList();
    final keys = images.map((w) => w.key).toSet();
    expect(keys.length, images.length); // 无重复 key
  });

  testWidgets('转场进行中（playerExpansion∈(0,1)）不渲染模糊层', (
    tester,
  ) async {
    addTearDown(() => playerExpansion.value = 1.0);
    await pumpCover(tester, 'https://photo.invalid/a.jpg');
    expect(find.byType(ImageFiltered), findsOneWidget); // 静止：有模糊
    playerExpansion.value = 0.5;
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing); // 位移中：去模糊防白线
    expect(
      find.byKey(const Key('amArtistPhotoSharpMask')),
      findsOneWidget, // 清晰层与主淡出罩保留
    );
    playerExpansion.value = 1.0;
    await tester.pump();
    expect(find.byType(ImageFiltered), findsOneWidget); // 落位恢复
  });
}
