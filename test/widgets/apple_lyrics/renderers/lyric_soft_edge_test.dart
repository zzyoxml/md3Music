import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词字体柔边抗锯齿（默认关闭）的回归护栏。
///
/// 锁定三件事：
/// 1. 关闭时仍走普通 `color` 绘制（不引入 Paint/MaskFilter，逐像素零回归）；
/// 2. 开启时 `foreground` Paint 带 `MaskFilter.blur`，sigma 落在设计范围；
/// 3. 预栅格化字形图必须自带柔边 pad，且字缘中间 alpha 档位明显增加。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  test('关闭柔边：样式仍是普通 color 绘制', () {
    final TextStyle style = LyricLayout.paintStyle(
      fontSize: 30,
      height: 1.2,
      color: const Color(0xFFFFFFFF),
    );
    expect(style.foreground, isNull, reason: '默认关闭时不得引入 foreground Paint');
    expect(style.color, const Color(0xFFFFFFFF));
    expect(style.fontFamily, LyricLayout.fontFamily);
    expect(style.fontWeight, LyricLayout.fontWeight);
  });

  test('开启柔边：foreground Paint 带 MaskFilter，sigma 落在 [0.35, 1.0]', () async {
    await LyricPreferences.instance.setSoftEdgeAntiAlias(true);

    final TextStyle style = LyricLayout.paintStyle(
      fontSize: 30,
      height: 1.2,
      color: const Color(0xFF00FF00),
    );
    expect(style.color, isNull, reason: 'foreground 与 color 互斥');
    final Paint? foreground = style.foreground;
    expect(foreground, isNotNull);
    expect(foreground!.maskFilter, isNotNull, reason: '柔边必须挂 MaskFilter.blur');

    final double sigma = LyricLayout.softEdgeSigma(30);
    expect(sigma, inInclusiveRange(0.35, 1.0));
    expect(LyricLayout.softEdgePad(30), closeTo(sigma * 3, 1e-9),
        reason: 'pad 取 3σ，保证模糊衰减不被边界裁断');
  });

  test('开启柔边：字形图四周增加 pad，字缘出现更多中间 alpha', () async {
    final WordRenderer renderer = WordRenderer();
    const double fontSize = 32;
    const double rowHeight = 1.4;
    const double wordWidth = 32;

    final ui.Image? sharp = await renderer.debugRenderWordGlyphForTest(
      text: '日',
      fontSize: fontSize,
      rowHeight: rowHeight,
      wordWidth: wordWidth,
    );
    expect(sharp, isNotNull, reason: '关闭柔边时也必须能烘焙字形图');
    final ByteData sharpBytes = (await sharp!.toByteData())!;
    final int sharpMidAlpha = _midAlphaCount(sharpBytes);
    final int sharpWidth = sharp.width;

    await LyricPreferences.instance.setSoftEdgeAntiAlias(true);
    final ui.Image? soft = await renderer.debugRenderWordGlyphForTest(
      text: '日',
      fontSize: fontSize,
      rowHeight: rowHeight,
      wordWidth: wordWidth,
    );
    expect(soft, isNotNull);

    final ByteData softBytes = (await soft!.toByteData())!;
    final double padRender = LyricLayout.softEdgePad(fontSize) *
        WordRenderer.wordGlyphSupersampleForTest;
    expect(
      soft.width - sharpWidth,
      closeTo((padRender * 2).ceil(), 1),
      reason: '字形图四周必须留 pad，避免柔边被图片边界裁成硬边',
    );
    expect(
      _midAlphaCount(softBytes),
      greaterThan(sharpMidAlpha),
      reason: '柔化后字缘中间 alpha 档位应增加（边缘过渡更柔滑）',
    );

    sharp.dispose();
    soft.dispose();
  });

  testWidgets('开启柔边后 AM 歌词完整绘制链路不抛异常', (tester) async {
    await LyricPreferences.instance.setSoftEdgeAntiAlias(true);
    final List<LyricLine> lines = <LyricLine>[
      const LyricLine(
        startTime: 0,
        duration: 2000,
        text: '柔边测试',
        translation: 'soft edge',
        words: <LyricWord>[
          LyricWord(startTime: 0, duration: 1000, text: '柔边'),
          LyricWord(startTime: 1000, duration: 1000, text: '测试'),
        ],
      ),
      const LyricLine(
        startTime: 2000,
        duration: 1500,
        text: '第二行',
        translation: 'second line',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppleLyricsView(
            lines: lines,
            currentTimeMs: 500,
            isPlaying: true,
          ),
        ),
      ),
    );
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(tester.takeException(), isNull);
    expect(find.byType(AppleLyricsView), findsOneWidget);
  });
}

/// 统计 0 < alpha < 255 的像素数（字形边缘的过渡像素）。
int _midAlphaCount(ByteData bytes) {
  int count = 0;
  for (int i = 3; i < bytes.lengthInBytes; i += 4) {
    final int alpha = bytes.getUint8(i);
    if (alpha > 0 && alpha < 255) count++;
  }
  return count;
}
