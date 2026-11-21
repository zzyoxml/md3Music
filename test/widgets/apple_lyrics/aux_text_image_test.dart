import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/aux_text_image.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/line_renderer.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';

/// 副行「翻转期改用预栅格化图」的回归测试。
///
/// 钉住三条契约：
/// 1. 预热窗口内每行只烘焙一次，**副行进度动画（0→1 / 1→0）不得触发重烘焙**；
/// 2. 翻转角不为 0 时走图像绘制路径（不再逐帧画透视文字）；
/// 3. dispose / 切歌释放已烘焙的 `ui.Image`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lines = <LyricLine>[
    LyricLine(startTime: 0, duration: 3000, text: '第一句', translation: '译一'),
    LyricLine(startTime: 3000, duration: 3000, text: '第二句', translation: '译二'),
    LyricLine(startTime: 6000, duration: 3000, text: '第三句', translation: '译三'),
    LyricLine(startTime: 9000, duration: 3000, text: '第四句'),
    LyricLine(startTime: 12000, duration: 3000, text: '第五句', translation: '译五'),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LineRenderer.debugFlipImageDraws = 0;
    WordRenderer.debugFlipImageDraws = 0;
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  /// 造一张 2×2 占位图（同步栅格化，测试里不依赖 runAsync）。
  ui.Image makeImage() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(2, 2);
    picture.dispose();
    return image;
  }

  /// 只挂载，不额外产帧：让测试在首帧之前注入烘焙实现（首帧 build 才建立
  /// 视口宽度，下一次 tick 才会真正发起预热请求）。
  Future<dynamic> mount(WidgetTester tester, ValueNotifier<Duration> pos) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: pos.value.inMilliseconds,
              // 必须 isPlaying：暂停且画面收敛后 Ticker 会停，位置变化不再产帧。
              isPlaying: true,
              forceDarkBackground: true,
              accentColor: const Color(0xFF3366CC),
              positionListenable: pos,
            ),
          ),
        ),
      ),
    );
    return tester.state(find.byType(AppleLyricsView));
  }

  Future<void> pumpFrames(WidgetTester tester, int frames) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('预热窗口每行只烘焙一次，副行进度动画不重复烘焙', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);

    final requested = <int>[];
    state.auxTextRendererForTest = (int lineIndex) async {
      requested.add(lineIndex);
      return AuxTextImage(image: makeImage(), width: 100, height: 20);
    };
    await pumpFrames(tester, 4);

    expect(requested, contains(0), reason: '当前行必须预热副行清晰图');
    expect(
      requested.toSet().length,
      requested.length,
      reason: '同一行在同一签名下不得重复请求',
    );
    expect(state.auxTextImagesForTest.keys, contains(0));

    // 切到第 2 句：旧行退场、新行入场，副行进度开始逐帧变化。
    pos.value = const Duration(milliseconds: 3500);
    await pumpFrames(tester, 4);
    final afterSwitch = requested.length;
    await pumpFrames(tester, 40);

    expect(
      requested.length,
      afterSwitch,
      reason: '签名不含进度 / alpha，翻转与展开动画期间不得重烘焙',
    );
    expect(
      requested,
      isNot(contains(3)),
      reason: '无副行文本的行不烘焙',
    );
  });

  testWidgets('翻转角不为 0 时走预栅格化图绘制路径', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);

    state.auxTextRendererForTest = (int lineIndex) async => AuxTextImage(
      image: makeImage(),
      width: 100,
      height: 20,
    );
    await pumpFrames(tester, 4);
    expect(state.auxTextImagesForTest, isNotEmpty);

    LineRenderer.debugFlipImageDraws = 0;
    WordRenderer.debugFlipImageDraws = 0;
    // 切行后翻转角从 ±90° 收到 0（死区前），这几帧必须走图像路径。
    pos.value = const Duration(milliseconds: 3500);
    await pumpFrames(tester, 8);

    expect(
      LineRenderer.debugFlipImageDraws + WordRenderer.debugFlipImageDraws,
      greaterThan(0),
      reason: '翻转期间应改用图像透视绘制，避免字形路径逐帧渲染',
    );
  });

  testWidgets('dispose 释放已烘焙的副行清晰图', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);

    state.auxTextRendererForTest = (int lineIndex) async => AuxTextImage(
      image: makeImage(),
      width: 100,
      height: 20,
    );
    await pumpFrames(tester, 4);
    final image = state.auxTextImagesForTest[0];
    expect(image, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(image!.image.debugDisposed, isTrue, reason: '销毁时必须释放 native 图像');
  });
}
