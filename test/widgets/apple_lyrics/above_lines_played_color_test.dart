import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/utils/lyric_line_color.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「上方行使用已播颜色」的渲染回归测试。
///
/// 只验证可观测的两条契约：
/// 1. 当前行**上方**那一行的模糊图被 `ColorFiltered(srcIn)` 染成已播色，
///    当前行下方那一行不染（仍按主题色烘焙）；
/// 2. 关掉开关或调整混色比例时着色即时变化，且不依赖模糊图重渲染
///    （缓存签名不含颜色，图仍是同一张）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Color accent = Color(0xFF3366CC);

  final lines = <LyricLine>[
    const LyricLine(startTime: 0, duration: 2000, text: '第一行歌词'),
    const LyricLine(startTime: 2000, duration: 4000, text: '第二行歌词'),
    const LyricLine(startTime: 6000, duration: 4000, text: '第三行歌词'),
  ];

  /// 造一张 2×2 的占位模糊图（同步栅格化，测试里不依赖 runAsync）。
  ui.Image makeImage() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(2, 2);
    picture.dispose();
    return image;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  /// 挂载三行歌词（当前行 = 第 1 行），此时高斯模糊关闭。
  Future<dynamic> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: 2000,
              isPlaying: false,
              forceDarkBackground: true,
              accentColor: accent,
            ),
          ),
        ),
      ),
    );
    return tester.state(find.byType(AppleLyricsView));
  }

  /// 注入假模糊渲染器后打开高斯模糊，等异步缓存就位并重建模糊层。
  Future<void> enableBlur(WidgetTester tester, dynamic state) async {
    state.lineBlurRendererForTest =
        (int lineIndex, int blurLevel, DuetAlignment align) async => makeImage();
    await LyricPreferences.instance.setUseGaussianBlur(true);
    // 第 1 次 pump：偏好通知 → 重建 → 触发异步模糊图请求；
    // 第 2 次 pump：请求完成后的 setState → 模糊层真正进入 widget 树。
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('仅当前行上方的行被染成已播色，下方行不染', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setUseDynamicLyricColor(true);
    await prefs.setUseAboveLinesPlayedColor(true);
    await prefs.setDynamicColorMixRatio(0.5);

    final state = await mount(tester);
    await enableBlur(tester, state);

    final filters =
        tester.widgetList<ColorFiltered>(find.byType(ColorFiltered)).toList();
    expect(filters, hasLength(1),
        reason: '当前行上方只有第 0 行，下方第 2 行不应着色');

    final int expected = resolveActiveLineColorValue(
      useDynamicColor: true,
      accentColor: accent,
      customTextColor: null,
      mixRatio: 0.5,
    )!;
    expect(
      filters.single.colorFilter,
      equals(ColorFilter.mode(Color(expected), BlendMode.srcIn)),
      reason: '模糊层应按「当前行已播色」整体染色（保留模糊 alpha）',
    );
  });

  testWidgets('关闭开关后不再着色，重新开启恢复', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setUseDynamicLyricColor(true);
    await prefs.setUseAboveLinesPlayedColor(true);

    final state = await mount(tester);
    await enableBlur(tester, state);
    expect(find.byType(ColorFiltered), findsOneWidget);

    await prefs.setUseAboveLinesPlayedColor(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ColorFiltered), findsNothing,
        reason: '关掉独立开关后上方行必须回到主题歌词色');

    await prefs.setUseAboveLinesPlayedColor(true);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ColorFiltered), findsOneWidget);
  });

  testWidgets('调整混色比例即时改变上方行颜色（不重建模糊图）', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setUseDynamicLyricColor(true);
    await prefs.setUseAboveLinesPlayedColor(true);
    await prefs.setDynamicColorMixRatio(0.2);

    final state = await mount(tester);
    await enableBlur(tester, state);
    final ui.Image? imageBefore = state.lineBlurImageForTest(0);
    final ColorFilter filterBefore =
        tester.widget<ColorFiltered>(find.byType(ColorFiltered)).colorFilter;

    await prefs.setDynamicColorMixRatio(1.0);
    await tester.pump();
    await tester.pump();

    final ColorFilter filterAfter =
        tester.widget<ColorFiltered>(find.byType(ColorFiltered)).colorFilter;
    expect(filterAfter, isNot(equals(filterBefore)),
        reason: '比例变化必须反映到上方行颜色上');
    expect(state.lineBlurImageForTest(0), same(imageBefore),
        reason: '颜色着色发生在合成期，模糊图缓存不应重建');
  });
}
