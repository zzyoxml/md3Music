import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/emphasize_effect.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 辉光「发光范围跟随字内进度推进」的回归护栏。
///
/// **需求**：辉光不再是对整个字统一上色，而要沿文字行进方向逐段点亮——
/// 已唱侧接近峰值、前沿处过渡、未唱侧淡出，与文字自身的扫光/渐变同步推进。
///
/// **实现契约**：辉光层复用文字那套前沿参数（sweep 的 4 停 `sweepRampFor`、
/// classic 的左右边缘 `_alphaAtX`），用 `BlendMode.modulate` 把渐变乘到
/// 纯白精灵上。因此辉光前沿与文字前沿**严格同位置**，不另造一套参数。
///
/// 度量方式：把一个长字分成左右两半，比较两半的光晕能量比。
/// 进度推进时应唱侧（左半）相对未唱侧（右半）越来越亮。
/// sweep 实测：0.07 → 0.17 → 0.32；classic：0.04 → 0.24 → 0.26。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int kWidth = 320;
  const int kHeight = 240;
  const Offset kOrigin = Offset(20, 40);
  const double kFontSize = 32;

  /// 渲染指定时刻的一帧（含辉光 + 文字），返回像素。
  Future<ByteData> frameAt(int timeMs, LyricFillMode mode) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.load();
    await LyricPreferences.instance.setUseGlowEffect(true);
    await LyricPreferences.instance.setFillMode(mode);
    addTearDown(() => LyricPreferences.instance.reset());

    // 单字时长 4000ms：字内进度有充足时间展开
    const LyricLine line = LyricLine(
      startTime: 0,
      duration: 8000,
      text: '永远',
      words: <LyricWord>[
        LyricWord(startTime: 0, duration: 4000, text: '永'),
        LyricWord(startTime: 4000, duration: 4000, text: '远'),
      ],
    );
    final WordRenderer renderer = WordRenderer();
    renderer.emphasizeEffect = EmphasizeEffect();
    renderer.setLineState(
      isActive: true,
      scale: LyricLayout.activeScale,
      activeColorValue: 0xFFFFFFFF,
    );
    // 先绑行，再推进到目标时刻（期间反复绘制，让异步精灵烘焙落地）
    final ui.PictureRecorder warm = ui.PictureRecorder();
    renderer.paintLine(Canvas(warm), kOrigin, line, kFontSize);
    warm.endRecording().dispose();
    for (int t = 0; t <= timeMs; t += 16) {
      renderer.tick(0.016, t, isPlaying: true);
      final ui.PictureRecorder warm2 = ui.PictureRecorder();
      renderer.paintLine(Canvas(warm2), kOrigin, line, kFontSize);
      warm2.endRecording().dispose();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kWidth.toDouble(), kHeight.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );
    renderer.paintLine(canvas, kOrigin, line, kFontSize);
    final ui.Picture pic = rec.endRecording();
    final ui.Image img = await pic.toImage(kWidth, kHeight);
    pic.dispose();
    final ByteData bytes = (await img.toByteData())!;
    img.dispose();
    return bytes;
  }

  /// 光晕能量：只统计中间亮度带（排除纯黑底与纯白文字本体）。
  double haloEnergy(ByteData bytes, int x0, int x1) {
    double sum = 0;
    for (int x = x0; x < x1; x++) {
      for (int y = 0; y < kHeight; y++) {
        final int v = bytes.getUint8((y * kWidth + x) * 4);
        if (v > 8 && v < 200) sum += v;
      }
    }
    return sum;
  }

  /// 文字本体的 x 范围（纯白像素所在的列）。
  ({int lo, int hi}) textSpan(ByteData bytes) {
    int lo = -1;
    int hi = -1;
    for (int x = 0; x < kWidth; x++) {
      bool has = false;
      for (int y = 0; y < kHeight; y++) {
        if (bytes.getUint8((y * kWidth + x) * 4) > 200) {
          has = true;
          break;
        }
      }
      if (has) {
        if (lo < 0) lo = x;
        hi = x;
      }
    }
    return (lo: lo, hi: hi);
  }

  Future<List<double>> collectRatios(LyricFillMode mode) async {
    final List<double> ratios = <double>[];
    // 字内进度约 30% / 60% / 85%
    for (final int timeMs in <int>[1200, 2400, 3400]) {
      final ByteData bytes = await frameAt(timeMs, mode);
      final ({int lo, int hi}) span = textSpan(bytes);
      expect(span.lo, greaterThanOrEqualTo(0),
          reason: '$mode@${timeMs}ms：必须渲染出文字本体');
      final int mid = (span.lo + span.hi) ~/ 2;
      final double left = haloEnergy(bytes, (span.lo - 12).clamp(0, kWidth), mid);
      final double right =
          haloEnergy(bytes, mid, (mid + 40).clamp(0, kWidth));
      expect(right, greaterThan(0), reason: '$mode@${timeMs}ms：右侧必须有光晕');
      ratios.add(left / right);
    }
    return ratios;
  }

  test('sweep：辉光跟随字内进度向右推进', () async {
    final List<double> ratios = await collectRatios(LyricFillMode.sweep);
    for (int i = 1; i < ratios.length; i++) {
      expect(
        ratios[i],
        greaterThan(ratios[i - 1] - 0.05),
        reason: 'sweep：辉光应随进度向右推进（左/右能量比应增大）。实测 $ratios',
      );
    }
    expect(
      ratios.last,
      greaterThan(ratios.first + 0.1),
      reason: 'sweep：推进幅度必须可辨。实测 $ratios',
    );
  });

  test('classic：辉光跟随字内进度向右推进', () async {
    final List<double> ratios = await collectRatios(LyricFillMode.classic);
    for (int i = 1; i < ratios.length; i++) {
      expect(
        ratios[i],
        greaterThan(ratios[i - 1] - 0.05),
        reason: 'classic：辉光应随进度向右推进（左/右能量比应增大）。实测 $ratios',
      );
    }
    expect(
      ratios.last,
      greaterThan(ratios.first + 0.1),
      reason: 'classic：推进幅度必须可辨。实测 $ratios',
    );
  });
}
