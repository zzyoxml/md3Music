import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';

/// 辉光「无锯齿」的像素级回归护栏。
///
/// 锯齿来源：**精灵按 1× 逻辑像素烘焙**，光晕的连续 alpha 斜坡先被量化成
/// 整数台阶，再被 DPR（2.75~3.5×）放大，台阶一起放大。
/// 修法是超采样烘焙（见 `WordRenderer._glowSpriteSupersample`）
/// + `drawImageRect` 缩回逻辑尺寸。
///
/// 度量方式：统计光晕过渡带内**相邻像素 alpha 跳变**。台阶越硬，跳变越大。
/// 阈值按实测标定：1× 无超采样时平均 23.5、最大 117、>32 的大台阶 228 处；
/// 2× 超采样后平均 9.1、最大 34、大台阶 56 处。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 只在「有斜坡」的位置统计：邻域 16px 内 alpha 跨度够大，排除平坦区。
  Map<String, double> edgeStats(ByteData bytes, int w, int h) {
    int steps = 0;
    int bigJumps = 0;
    int maxJump = 0;
    double sumJump = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x + 1 < w; x++) {
        final int a = bytes.getUint8((y * w + x) * 4 + 3);
        final int b = bytes.getUint8((y * w + x + 1) * 4 + 3);
        if (a <= 16 && b <= 16) continue;
        int lo = 255;
        int hi = 0;
        for (int k = -8; k <= 8; k++) {
          final int xx = x + k;
          if (xx < 0 || xx >= w) continue;
          final int v = bytes.getUint8((y * w + xx) * 4 + 3);
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        if (hi - lo < 40) continue;
        final int d = (a - b).abs();
        if (d == 0) continue;
        steps++;
        sumJump += d;
        if (d > maxJump) maxJump = d;
        if (d >= 32) bigJumps++;
      }
    }
    return <String, double>{
      'steps': steps.toDouble(),
      'avgJump': steps == 0 ? 0 : sumJump / steps,
      'bigJumps': bigJumps.toDouble(),
      'maxJump': maxJump.toDouble(),
    };
  }

  test('辉光光晕带不得出现硬台阶（超采样烘焙）', () async {
    for (final double fontSize in <double>[32, 72]) {
      final WordRenderer renderer = WordRenderer();
      final ui.Image? sprite = await renderer.debugRenderGlowSpriteForTest(
        text: '日',
        fontSize: fontSize,
        rowHeight: 1.4,
      );
      expect(sprite, isNotNull, reason: 'fs=$fontSize：辉光精灵必须能烘焙');
      final ByteData bytes = (await sprite!.toByteData())!;
      final Map<String, double> s = edgeStats(
        bytes,
        sprite.width,
        sprite.height,
      );

      expect(s['steps'], greaterThan(100),
          reason: 'fs=$fontSize：必须有足够的光晕过渡带样本');
      expect(
        s['avgJump'],
        lessThan(14.0),
        reason:
            'fs=$fontSize：光晕过渡带相邻 alpha 平均跳变必须足够小（实测修复前 23.5）。'
            '实测 avgJump=${s['avgJump']}',
      );
      expect(
        s['maxJump'],
        lessThan(60.0),
        reason:
            'fs=$fontSize：单处最大 alpha 跳变必须压下去（实测修复前 117，硬边遮罩）。'
            '实测 maxJump=${s['maxJump']}',
      );
      expect(
        s['bigJumps'],
        lessThan(120.0),
        reason:
            'fs=$fontSize：>32 的硬台阶数量必须显著减少（实测修复前 228）。'
            '实测 bigJumps=${s['bigJumps']}',
      );
      sprite.dispose();
    }
  });

  test('超采样烘焙 + 缩回逻辑尺寸：字形与光晕尺寸不变形', () async {
    const double fontSize = 32;
    final WordRenderer renderer = WordRenderer();
    final ui.Image? sprite = await renderer.debugRenderGlowSpriteForTest(
      text: '日',
      fontSize: fontSize,
      rowHeight: 1.4,
    );
    expect(sprite, isNotNull);

    // 精灵是「逻辑尺寸 × 超采样倍数」；绘制期用 drawImageRect 缩回逻辑尺寸，
    // 所以这里反过来校验：精灵尺寸 / 倍数 必须等于逻辑尺寸（含 pad）。
    final double pad = renderer.debugGlowSpritePadForTest(fontSize);
    final double logicalW = sprite!.width / WordRenderer.glowSupersampleForTest;
    final double logicalH =
        sprite.height / WordRenderer.glowSupersampleForTest;
    expect(logicalH, closeTo(fontSize * 1.4 + pad * 2, 1.5),
        reason: '精灵高度必须 = 行盒 + 上下 pad');
    expect(logicalW, greaterThan(pad * 2), reason: '精灵宽度必须包容字形 + pad');

    expect(
      renderer.glowImageFilterQualityForTest,
      isNot(FilterQuality.none),
      reason: '缩回逻辑尺寸必须用双线性，最近邻会把抗锯齿信息丢光（字缘硬台阶）',
    );
    sprite.dispose();
  });
}
