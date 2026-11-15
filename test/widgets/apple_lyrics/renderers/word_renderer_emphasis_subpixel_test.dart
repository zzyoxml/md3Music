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

/// 强调辉光「放大 / 上浮」在换行行上不得退回整像素台阶的回归护栏。
///
/// 背景：文本绘制的**垂直**位置会被栅格化量化到整 device 像素（历史坑，见
/// `word_renderer_glyph_blit_test.dart`）。强调字靠预烘焙字形图绕开它，但
/// 换行行（0.8× 行盒）此前被硬编码为「退回 TextPainter」——因为图是按主线
/// 行盒烘焙的、压扁复用会整字上移。实测该路径的逐帧质心是
/// `179.47 → 178.50 → 177.54`（每级约 0.96px、级间 20 帧不动），
/// 观感即「放大/上浮被一格一格吸附」。
///
/// 修复：字形图按**实际视觉行盒**烘焙（`_charImageRowHeights` 记账），
/// 换行行也走图片 + 双线性采样。本文件锁两件事：
/// 1. 主行 / 换行行的强调字，亚像素 y 位移都必须改变画面；
/// 2. 换行行的图必须记在 0.8× 行盒上（记成主行行盒说明预热把绘制侧覆盖了，
///    会出现「烘焙 → 作废 → 再烘焙」的乒乓，最终退回文本路径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int kWidth = 520;
  const int kHeight = 420;
  const double kFontSize = 34.85685451574663; // 与 Windows AM 页默认字号一致

  // 前一个词 600ms（低于阈值，不强调）用于制造换行；后一个词 1800ms 触发辉光。
  const LyricLine line = LyricLine(
    startTime: 0,
    duration: 2400,
    text: 'Go STAY',
    words: <LyricWord>[
      LyricWord(startTime: 0, duration: 600, text: 'Go '),
      LyricWord(startTime: 600, duration: 1800, text: 'STAY'),
    ],
  );

  Future<ByteData> render(WordRenderer r, double originY, double maxWidth) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kWidth.toDouble(), kHeight.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );
    r.paintLine(canvas, Offset(20, originY), line, kFontSize,
        maxWidth: maxWidth);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(kWidth, kHeight);
    picture.dispose();
    final ByteData data = (await image.toByteData())!;
    image.dispose();
    return data;
  }

  /// 两帧在指定行区间内是否有肉眼可辨的差异（>3 级）。
  bool differsInRows(ByteData a, ByteData b, int y0, int y1) {
    for (int y = y0; y < y1; y++) {
      for (int x = 0; x < kWidth; x++) {
        final int i = (y * kWidth + x) * 4;
        if ((a.getUint8(i) - b.getUint8(i)).abs() > 3) return true;
      }
    }
    return false;
  }

  /// 把整幅画面按 [stepPx] 逐级下移，统计目标行区间内出现多少种「不同画面」。
  ///
  /// - 字形图 + 双线性：每一级都是新图案（≈ 级数）
  /// - TextPainter：垂直位置被量化到整 device 像素，只剩 2~4 种
  Future<int> distinctShifts(
    WordRenderer r,
    double maxWidth,
    int y0,
    int y1, {
    double stepPx = 0.1,
  }) async {
    final List<ByteData> shots = <ByteData>[];
    for (int k = 0; k < 10; k++) {
      shots.add(await render(r, 40 + k * stepPx, maxWidth));
    }
    final List<int> uniq = <int>[];
    for (int i = 0; i < shots.length; i++) {
      bool seen = false;
      for (final int j in uniq) {
        if (!differsInRows(shots[i], shots[j], y0, y1)) {
          seen = true;
          break;
        }
      }
      if (!seen) uniq.add(i);
    }
    return uniq.length;
  }

  /// 绑定 + 预热到 t=900ms（强调字激活），返回渲染器。
  Future<WordRenderer> warmUp(double maxWidth) async {
    final WordRenderer r = WordRenderer();
    r.emphasizeEffect = EmphasizeEffect();
    r.thresholdMs = 1000;
    r.setLineState(
      isActive: true,
      scale: LyricLayout.activeScale,
      activeColorValue: 0xFFFFFFFF,
    );
    await render(r, 40, maxWidth);
    for (int t = 0; t <= 900; t += 16) {
      r.tick(0.016, t, isPlaying: true);
      await render(r, 40, maxWidth);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    return r;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.load();
    await LyricPreferences.instance.setUseGlowEffect(true);
    // 辉光强度置 0：光晕精灵 alpha=0 不可见，画面只剩「强调变换 + 文字」，
    // 这样亚像素位移的差异像素只可能来自文字本体（光晕是图片、会污染度量）。
    await LyricPreferences.instance.setGlowIntensity(0);
    await LyricPreferences.instance.setUnplayedOpacity(0.8);
  });

  tearDown(() {
    LyricPreferences.instance.reset();
  });

  test('主行强调字：垂直位移必须亚像素连续', () async {
    final WordRenderer r = await warmUp(double.infinity);
    final int y0 = 40;
    final int y1 = (40 + kFontSize * LyricLayout.lineHeight * 1.1).round();
    expect(
      await distinctShifts(r, double.infinity, y0, y1),
      greaterThanOrEqualTo(8),
      reason: '主行强调字必须走字形图；退化成 TextPainter 时只剩 2~4 种图案',
    );
  });

  test('换行行（0.8× 行盒）强调字：0.3px 垂直位移必须改变画面', () async {
    const double maxWidth = 90; // 只放得下 'Go '，'STAY' 落到第二个视觉行
    final WordRenderer r = await warmUp(maxWidth);
    final double rowH = kFontSize * LyricLayout.lineHeight;
    final int y0 = (40 + rowH).round();
    final int y1 = (y0 + rowH * 1.1).round();

    expect(
      await distinctShifts(r, maxWidth, y0, y1),
      greaterThanOrEqualTo(8),
      reason: '换行行强调字也必须走字形图，不得退回 TextPainter（1px 台阶）',
    );
  });

  test('换行行字形图按 0.8× 行盒记账（不得被预热覆盖回主行）', () async {
    const double maxWidth = 90;
    final WordRenderer r = await warmUp(maxWidth);
    // 再画几帧，让按 0.8× 行盒的重烘焙落地
    for (int i = 0; i < 10; i++) {
      r.tick(0.016, 900 + i * 16, isPlaying: true);
      await render(r, 40, maxWidth);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final double wrappedRow =
        LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
    expect(
      r.debugCharImageRowHeightForTest(1, 0),
      closeTo(wrappedRow, 1e-6),
      reason: '换行行的字符图必须记在自己的 0.8× 行盒上，'
          '记成主行说明预热与绘制侧在互相覆盖',
    );
    expect(
      r.debugCharImageRowHeightForTest(1, 3),
      closeTo(wrappedRow, 1e-6),
    );
  });
}
