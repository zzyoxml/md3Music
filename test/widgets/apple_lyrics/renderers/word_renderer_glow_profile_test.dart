import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';

/// 辉光「字形最亮、向外平滑递减」的像素级回归护栏。
///
/// **观感契约**（用户明确要求）：辉光应当在**字形处最亮**，然后向四周
/// **单调递减**——即经典外发光，而不是「字形内部暗、边缘一圈亮环」。
///
/// 反面做法（已废弃，勿再引入）：用 `BlendMode.dstOut` 挖空字形本体。
/// 它看起来"贴笔画"，但亮度峰值落在字形**边缘**而非字形上；文字半透明时
/// （扫光中段 alpha 会掉到 0.4）就露出一圈「字内暗 → 边缘亮 → 外侧暗」，
/// 用户描述为「亮暗亮的边界，越调整越明显」。
///
/// 本文件按**到笔画的距离**分档统计平均亮度，锁定三条契约：
/// 1. 字形内部（实心笔画）最亮；
/// 2. 从字形向外逐档递减（不出现回升）；
/// 3. 光晕有可见的扩散范围（外侧仍有可辨亮度，不是"只有字亮"）。
///
/// 32px「日」实测参考曲线（距笔画 0..14px）：
/// `206,143,123,103,86,69,56,45,37,30,25,20,17,15,12`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 按「到笔画距离」分档的平均 alpha（255 制）。第 0 档 = 字形实心内部。
  Future<List<double>> brightnessByDistance(
    String char,
    double fontSize, {
    int maxDistance = 14,
  }) async {
    final WordRenderer renderer = WordRenderer();
    final ui.Image? sprite = await renderer.debugRenderGlowSpriteForTest(
      text: char,
      fontSize: fontSize,
      rowHeight: 1.4,
    );
    expect(sprite, isNotNull, reason: '$char@$fontSize：辉光精灵必须能烘焙');
    final ByteData sb = (await sprite!.toByteData())!;
    final double ss = WordRenderer.glowSupersampleForTest.toDouble();
    final double padPx = renderer.debugGlowSpritePadForTest(fontSize) * ss;
    final int w = sprite.width;
    final int h = sprite.height;

    // 同口径字形 mask
    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: char,
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: fontSize * ss,
          height: 1.4,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      )
      ..layout();
    final ui.PictureRecorder rec = ui.PictureRecorder();
    tp.paint(ui.Canvas(rec), Offset(padPx, padPx));
    tp.dispose();
    final ui.Picture pic = rec.endRecording();
    final ui.Image mask = await pic.toImage(w, h);
    pic.dispose();
    final ByteData mb = (await mask.toByteData())!;

    bool isStroke(int x, int y) =>
        x >= 0 &&
        y >= 0 &&
        x < w &&
        y < h &&
        mb.getUint8((y * w + x) * 4 + 3) > 128;

    final List<double> sums = List<double>.filled(maxDistance + 1, 0);
    final List<int> counts = List<int>.filled(maxDistance + 1, 0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final double a = sb.getUint8((y * w + x) * 4 + 3).toDouble();
        if (isStroke(x, y)) {
          // 只取实心内部（周围 2px 都是笔画），排除抗锯齿边缘
          bool solid = true;
          for (int dy = -2; dy <= 2 && solid; dy++) {
            for (int dx = -2; dx <= 2 && solid; dx++) {
              if (!isStroke(x + dx, y + dy)) solid = false;
            }
          }
          if (solid) {
            sums[0] += a;
            counts[0]++;
          }
          continue;
        }
        int dist = 999;
        for (int rad = 1; rad <= maxDistance && dist == 999; rad++) {
          for (int dy = -rad; dy <= rad; dy++) {
            for (int dx = -rad; dx <= rad; dx++) {
              if (dx.abs() + dy.abs() > rad) continue;
              if (isStroke(x + dx, y + dy)) dist = rad;
            }
          }
        }
        if (dist > maxDistance) continue;
        sums[dist] += a;
        counts[dist]++;
      }
    }

    final List<double> out = <double>[];
    for (int d = 0; d <= maxDistance; d++) {
      out.add(counts[d] == 0 ? -1 : sums[d] / counts[d]);
    }
    sprite.dispose();
    mask.dispose();
    return out;
  }

  test('字形最亮，且按距笔画距离单调递减（无回升）', () async {
    for (final double fontSize in <double>[32, 72]) {
      final List<double> curve = await brightnessByDistance('日', fontSize);
      expect(curve.first, greaterThan(100),
          reason: 'fs=$fontSize：字形内部必须是最亮的一档');

      // 第 0 档必须是全程最大值
      double maxV = 0;
      for (final double v in curve) {
        if (v > maxV) maxV = v;
      }
      expect(
        curve.first,
        greaterThanOrEqualTo(maxV - 2),
        reason:
            'fs=$fontSize：亮度峰值必须在字形处（不得出现在字形边缘）。'
            '曲线=$curve',
      );

      // 逐档不回升（允许 2/255 的量化抖动）
      final List<double> valid = curve.where((v) => v >= 0).toList();
      for (int i = 1; i < valid.length; i++) {
        expect(
          valid[i],
          lessThanOrEqualTo(valid[i - 1] + 2),
          reason:
              'fs=$fontSize：从字形向外第 $i 档亮度回升了（亮暗亮）。'
              '曲线=$curve',
        );
      }

      // 光晕要有可见扩散：最远档不能为 0
      expect(
        valid.last,
        greaterThan(5),
        reason: 'fs=$fontSize：光晕必须有可见的扩散范围。曲线=$curve',
      );
    }
  });
}
