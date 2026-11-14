import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows「已播字上浮」平滑修复的回归护栏。
///
/// 背景：文本绘制的**垂直**位置会被栅格化量化到整 device 像素（实测
/// y+0.375 与 y+0.0 逐像素相同），上浮仅 1~3px 时整段动画只剩 2~3 个台阶，
/// 观感「卡住再被吸过去」。修复方式 = 整词预渲染字形图 + drawImageRect
/// 分数目标（GPU 双线性采样），仅 Windows 且开启上浮时启用。
///
/// 本文件锁三件事：
/// 1. 门控：非 Windows（测试默认 android）不启用，Windows 且上浮 >0 才启用；
/// 2. 生成：Windows 下绘制后异步产出整词字形图；
/// 3. 效果：同一行在**亚像素** y 偏移变化下画面必须变化（文本路径不变）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const LyricLine line = LyricLine(
    startTime: 0,
    duration: 4000,
    text: '运命的华',
    words: [
      LyricWord(startTime: 0, duration: 1000, text: '运'),
      LyricWord(startTime: 1000, duration: 1000, text: '命'),
      LyricWord(startTime: 2000, duration: 1000, text: '的'),
      LyricWord(startTime: 3000, duration: 1000, text: '华'),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.reset();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  /// 渲染一行到图片（带深色底，便于统计差异像素）。
  Future<Uint8List> renderPixels(
    WordRenderer renderer, {
    LyricLine? target,
  }) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 400, 120),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    renderer.paintLine(canvas, ui.Offset.zero, target ?? line, 24);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(400, 120);
    picture.dispose();
    final ByteData? data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List();
  }

  int diffPixels(Uint8List a, Uint8List b) {
    int diff = 0;
    for (int i = 0; i < a.length; i += 4) {
      if ((a[i] - b[i]).abs() > 3 ||
          (a[i + 1] - b[i + 1]).abs() > 3 ||
          (a[i + 2] - b[i + 2]).abs() > 3) {
        diff++;
      }
    }
    return diff;
  }

  test('非 Windows（测试默认 android）不启用字形图路径', () async {
    await LyricPreferences.instance.setLiftHeightPx(3.0);
    final WordRenderer renderer = WordRenderer();
    await renderPixels(renderer);
    expect(renderer.glyphBlitActiveForTest, isFalse);
    expect(renderer.glyphImageCountForTest, 0);
  });

  test('Windows 且上浮为 0 时不启用字形图路径', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await LyricPreferences.instance.setLiftHeightPx(0);
    final WordRenderer renderer = WordRenderer();
    await renderPixels(renderer);
    expect(renderer.glyphBlitActiveForTest, isFalse);
    expect(renderer.glyphImageCountForTest, 0);
  });

  test('Windows 且开启上浮时启用，并异步产出整词字形图', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await LyricPreferences.instance.setLiftHeightPx(3.0);
    final WordRenderer renderer = WordRenderer();
    await renderPixels(renderer);
    expect(renderer.glyphBlitActiveForTest, isTrue);
    // toImage 经 native 回调完成，多等几轮事件循环
    for (int i = 0; i < 40 && renderer.glyphImageCountForTest < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      renderer.glyphImageCountForTest,
      4,
      reason: '四个字都应产出字形图',
    );
  });

  test('Windows 字形图路径：亚像素 y 变化必须改变画面', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await LyricPreferences.instance.setLiftHeightPx(3.0);
    final WordRenderer renderer = WordRenderer();
    // 首帧完成行绑定 + 发起字形图渲染
    await renderPixels(renderer);
    for (int i = 0; i < 40 && renderer.glyphImageCountForTest < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(renderer.glyphImageCountForTest, 4);

    // 亚像素上浮：0 与 0.3 逻辑 px（远小于 1 device px 的量化台阶）
    final List<double> offsets = renderer.wordYOffsetsRef;
    for (int i = 0; i < offsets.length; i++) {
      offsets[i] = 0;
    }
    final Uint8List base = await renderPixels(renderer);
    for (int i = 0; i < offsets.length; i++) {
      offsets[i] = -0.3;
    }
    final Uint8List lifted = await renderPixels(renderer);

    expect(
      diffPixels(base, lifted),
      greaterThan(0),
      reason: '字形图路径下 0.3px 位移必须产生画面变化（否则又退回整像素台阶）',
    );
  });

  group('离屏位图重采样必须用非最近邻采样', () {
    // 背景：`Paint()` 默认 filterQuality = none（最近邻）。本仓三张离屏位图
    // （整词字形图 / 强调字图 / 辉光精灵）都是「超采样或按逻辑像素渲染，
    // 绘制时缩放到设备像素」，最近邻会把抗锯齿信息整体丢掉。
    // 真机 Windows 光栅器实测（tmp/glyph_resample_probe.txt）：
    //   - Windows 3× 字形图 2.40× 降采样：alpha 档位 228 → 16，中间 alpha 20.5% → 10.9%
    //   - Android 光晕 3× 放大：相邻像素跳变 255 → 73~93，alpha 档位 246 → 16
    // 因此这三个 Paint 一旦被改回默认值，画面会立刻退化成硬边台阶。
    test('三个 Paint 的 filterQuality 均不为 none', () {
      final WordRenderer renderer = WordRenderer();
      expect(
        renderer.glyphFilterQualityForTest,
        isNot(FilterQuality.none),
        reason: '整词字形图（Windows 上浮路径）不得退回最近邻采样',
      );
      expect(
        renderer.charImageFilterQualityForTest,
        isNot(FilterQuality.none),
        reason: '强调字字形图不得退回最近邻采样',
      );
      expect(
        renderer.glowImageFilterQualityForTest,
        isNot(FilterQuality.none),
        reason: '辉光精灵（1× 逻辑像素放大到 DPR 倍）不得退回最近邻采样',
      );
    });

    test('强调字路径绘制一帧后采样模式仍成立（Android 辉光场景）', () async {
      // 强调字：字时长 >= 阈值（默认 fixed 1000ms）+ CJK 内容
      const LyricLine glowLine = LyricLine(
        startTime: 0,
        duration: 4000,
        text: '华',
        words: [LyricWord(startTime: 0, duration: 2000, text: '华')],
      );
      final WordRenderer renderer = WordRenderer();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      await renderPixels(renderer, target: glowLine);
      // 推进到该字演唱中段，激活逐字符辉光/字形图路径
      for (int i = 0; i < 30; i++) {
        renderer.tick(0.016, 800);
        await renderPixels(renderer, target: glowLine);
      }
      expect(
        renderer.charImageFilterQualityForTest,
        isNot(FilterQuality.none),
      );
      expect(
        renderer.glowImageFilterQualityForTest,
        isNot(FilterQuality.none),
      );
    });
  });
}
