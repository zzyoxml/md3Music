import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「下一行 → 当前行」的模糊层淡出过渡门控测试。
///
/// 关键契约：渐变切换开关关闭时，切行行为与改造前完全一致
///（入场模糊层恒不显示，清晰层直接逐字入场）。
const List<LyricLine> lines = <LyricLine>[
  LyricLine(startTime: 0, duration: 2000, text: '第一行歌词'),
  LyricLine(startTime: 2000, duration: 4000, text: '第二行歌词'),
  LyricLine(startTime: 6000, duration: 4000, text: '第三行歌词'),
];

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
    await LyricPreferences.instance.setUseGaussianBlur(true);
    await LyricPreferences.instance.setBlurLevelCrossfade(false);
    await LyricPreferences.instance
        .setBlurLevelFadeMs(LyricPreferences.defaultBlurLevelFadeMs);
  });

  Future<dynamic> pumpAt(WidgetTester tester, int timeMs) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: AppleLyricsView(
            lines: lines,
            currentTimeMs: timeMs,
            isPlaying: true,
          ),
        ),
      ),
    ));
    final dynamic state = tester.state(find.byType(AppleLyricsView));
    state.lineBlurRendererForTest =
        (int i, int level, DuetAlignment align) async => makeImage();
    return state;
  }

  testWidgets('开关关闭：切行不启用入场模糊淡出（零回归）', (tester) async {
    final state = await pumpAt(tester, 500);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await pumpAt(tester, 2500);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.entryBlurProgressForTest, equals(1.0),
        reason: '关闭时入场模糊层必须保持停用，切行仍是原来的清晰层逐字入场');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('开关开启：切行启动入场模糊淡出并按时长收敛', (tester) async {
    await LyricPreferences.instance.setBlurLevelCrossfade(true);
    await LyricPreferences.instance.setBlurLevelFadeMs(200);

    final state = await pumpAt(tester, 500);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await pumpAt(tester, 2500);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.entryBlurProgressForTest, lessThan(1.0),
        reason: '开启时新当前行的旧模糊图应处于淡出过程中');

    for (var i = 0; i < 24 && state.entryBlurProgressForTest < 1.0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.entryBlurProgressForTest, equals(1.0),
        reason: '淡出必须在时长滑块规定的窗口内收敛');

    await LyricPreferences.instance.setBlurLevelCrossfade(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
