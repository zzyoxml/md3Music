import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「模糊等级渐变切换」开关（默认关闭）的门控回归测试。
///
/// 最关键的一条契约：**开关关闭时行为与改造前逐像素一致**——旧模糊图仍
/// 在替换瞬间 dispose，不暂存、不推进过渡、不唤醒帧驱动。
ui.Image makeImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(2, 2);
  picture.dispose();
  return image;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.setUseGaussianBlur(false);
    await LyricPreferences.instance.setBlurLevelCrossfade(false);
    await LyricPreferences.instance
        .setBlurLevelFadeMs(LyricPreferences.defaultBlurLevelFadeMs);
  });

  Future<dynamic> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppleLyricsView(
        lines: <LyricLine>[
          LyricLine(startTime: 0, duration: 4000, text: '测试歌词'),
        ],
        currentTimeMs: 0,
      ),
    ));
    return tester.state(find.byType(AppleLyricsView));
  }

  /// 安装一个可手动控制完成时序的模糊图渲染器。
  List<Completer<ui.Image?>> installRenderer(dynamic state) {
    final requests = <Completer<ui.Image?>>[];
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) {
      final request = Completer<ui.Image?>();
      requests.add(request);
      return request.future;
    };
    return requests;
  }

  group('偏好项 blurLevelCrossfade', () {
    test('默认关闭（历史观感不变）', () {
      expect(LyricPreferences.instance.blurLevelCrossfade, isFalse);
    });

    test('setter 生效并持久化到 lyric_blur_level_crossfade', () async {
      await LyricPreferences.instance.setBlurLevelCrossfade(true);
      expect(LyricPreferences.instance.blurLevelCrossfade, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_blur_level_crossfade'), isTrue);

      await LyricPreferences.instance.setBlurLevelCrossfade(false);
      expect(prefs.getBool('lyric_blur_level_crossfade'), isFalse);
    });

    test('reset 后回到默认且 key 被移除', () async {
      await LyricPreferences.instance.setBlurLevelCrossfade(true);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.blurLevelCrossfade, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_blur_level_crossfade'), isNull);
    });
  });

  group('偏好项 blurLevelFadeMs（动画细节滑块）', () {
    test('默认 500ms，范围 50~1000ms', () {
      expect(LyricPreferences.defaultBlurLevelFadeMs, equals(500.0));
      expect(LyricPreferences.minBlurLevelFadeMs, equals(50.0));
      expect(LyricPreferences.maxBlurLevelFadeMs, equals(1000.0));
      expect(
        LyricPreferences.instance.blurLevelFadeMs,
        equals(LyricPreferences.defaultBlurLevelFadeMs),
      );
    });

    test('setter clamp 到范围并持久化', () async {
      await LyricPreferences.instance.setBlurLevelFadeMs(-10);
      expect(LyricPreferences.instance.blurLevelFadeMs, equals(50.0));
      await LyricPreferences.instance.setBlurLevelFadeMs(99999);
      expect(LyricPreferences.instance.blurLevelFadeMs, equals(1000.0));
      await LyricPreferences.instance.setBlurLevelFadeMs(750);
      expect(LyricPreferences.instance.blurLevelFadeMs, equals(750.0));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_blur_level_fade_ms'), equals(750.0));
    });

    test('reset 后回到默认且 key 被移除', () async {
      await LyricPreferences.instance.setBlurLevelFadeMs(800);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.blurLevelFadeMs,
          equals(LyricPreferences.defaultBlurLevelFadeMs));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_blur_level_fade_ms'), isNull);
    });

    test('不进动画预设参数表（20 项契约不变）', () {
      expect(LyricPreferences.animationValueKeys, hasLength(20));
      expect(
        LyricPreferences.animationValueKeys.contains('blurLevelFadeMs'),
        isFalse,
      );
    });
  });

  group('渲染侧门控', () {
    testWidgets('渲染侧读取时长偏好：1000ms 时 10 帧后仍未收敛',
        (tester) async {
      await LyricPreferences.instance.setBlurLevelCrossfade(true);
      await LyricPreferences.instance.setBlurLevelFadeMs(1000);
      final state = await mount(tester);
      final requests = installRenderer(state);

      state.updateLineBlurCacheForTest(<int, int>{0: 1});
      final first = makeImage();
      requests[0].complete(first);
      await tester.pump();

      state.updateLineBlurCacheForTest(<int, int>{0: 2});
      final second = makeImage();
      requests[1].complete(second);
      await tester.pump();

      // 10 帧 × 16ms ≈ 160ms；若渲染侧仍用旧的 150ms 常量，此刻早已收敛。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state.blurLevelFadeForTest, greaterThan(0.0));
      expect(state.blurLevelFadeForTest, lessThan(0.3));

      await LyricPreferences.instance.setBlurLevelCrossfade(false);
      await LyricPreferences.instance
          .setBlurLevelFadeMs(LyricPreferences.defaultBlurLevelFadeMs);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('开关关闭：切换 blurLevel 仍立即释放旧图、无过渡状态',
        (tester) async {
      final state = await mount(tester);
      final requests = installRenderer(state);

      state.updateLineBlurCacheForTest(<int, int>{0: 1});
      final first = makeImage();
      requests[0].complete(first);
      await tester.pump();
      expect(state.lineBlurImageForTest(0), same(first));

      state.updateLineBlurCacheForTest(<int, int>{0: 2});
      final second = makeImage();
      requests[1].complete(second);
      await tester.pump();

      expect(state.lineBlurImageForTest(0), same(second));
      expect(first.debugDisposed, isTrue, reason: '关闭时旧图必须立即释放');
      expect(state.hasFadingBlurForTest, isFalse);
      expect(state.blurLevelFadeForTest, equals(1.0));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('开关开启：旧图暂存、过渡从 0 起步，收敛后释放',
        (tester) async {
      await LyricPreferences.instance.setBlurLevelCrossfade(true);
      final state = await mount(tester);
      final requests = installRenderer(state);

      state.updateLineBlurCacheForTest(<int, int>{0: 1});
      final first = makeImage();
      requests[0].complete(first);
      await tester.pump();

      state.updateLineBlurCacheForTest(<int, int>{0: 2});
      final second = makeImage();
      requests[1].complete(second);
      await tester.pump();

      expect(first.debugDisposed, isFalse, reason: '过渡期旧图必须保留');
      expect(state.hasFadingBlurForTest, isTrue);
      expect(state.blurLevelFadeForTest, lessThan(1.0));

      // 逐帧推进直到收敛：过渡在异步回调里唤醒帧驱动，首帧 dt=0，
      // 不能用单次大跨度 pump 假定它已经跑过。滑块上限 1000ms，
      // 16ms 步长下约需 63 帧，故上限取 80。
      for (var i = 0; i < 80 && state.blurLevelFadeForTest < 1.0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state.blurLevelFadeForTest, equals(1.0),
          reason: '过渡必须靠既有帧驱动收敛，不能停在半途');
      expect(state.hasFadingBlurForTest, isFalse);
      expect(first.debugDisposed, isTrue);

      await LyricPreferences.instance.setBlurLevelCrossfade(false);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('过渡未结束又切等级时旧批次不累积', (tester) async {
      await LyricPreferences.instance.setBlurLevelCrossfade(true);
      final state = await mount(tester);
      final requests = installRenderer(state);

      final images = <ui.Image>[];
      for (var level = 1; level <= 3; level++) {
        state.updateLineBlurCacheForTest(<int, int>{0: level});
        final image = makeImage();
        images.add(image);
        requests[level - 1].complete(image);
        await tester.pump();
      }

      expect(state.lineBlurImageForTest(0), same(images[2]));
      expect(images[0].debugDisposed, isTrue, reason: '被替换的旧批次必须释放');
      expect(state.hasFadingBlurForTest, isTrue, reason: '最多只保留一批旧图');

      await LyricPreferences.instance.setBlurLevelCrossfade(false);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
