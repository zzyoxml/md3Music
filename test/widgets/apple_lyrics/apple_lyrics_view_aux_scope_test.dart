import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// AM 播放页「副行显示范围」的逐行进度回归测试。
///
/// 钉住四条契约：
/// 1. 默认 `currentLine` 与改造前一致：只有当前行副行展开；
/// 2. `allLines` 下每行都展开到 1；
/// 3. `hidePlayed` 下切行后上一行的副行收回到 0；
/// 4. 高度不变量：`deltaBefore(k) == Σ_{i<k} extra(i)`（前缀和与行高同源，
///    写歪会让二分查找 / 点击跳行命中错行）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lines = <LyricLine>[
    LyricLine(startTime: 0, duration: 3000, text: '第一句', translation: '译一'),
    LyricLine(startTime: 3000, duration: 3000, text: '第二句', translation: '译二'),
    LyricLine(startTime: 6000, duration: 3000, text: '第三句', translation: '译三'),
    LyricLine(startTime: 9000, duration: 3000, text: '第四句', translation: '译四'),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

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
              // 必须 isPlaying：暂停且画面收敛后 Ticker 会停，改 position
              // 只会更新权威时间而不再产帧 → 当前行与逐行进度都不会推进。
              isPlaying: true,
              forceDarkBackground: true,
              accentColor: const Color(0xFF3366CC),
              positionListenable: pos,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state(find.byType(AppleLyricsView));
  }

  /// 推进若干帧，让逐行副行进度指数收敛到目标。
  ///
  /// 速率随行时长自适应（慢歌最低约 4/s），90 帧 ≈ 1.4s 才保证|target-p|
  /// 落进 0.001 吸附阈值——帧数给小了会停在 0.98 之类的中途值。
  Future<void> settle(WidgetTester tester, {int frames = 90}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  void expectAuxProgress(dynamic state, List<double> expected) {
    for (var i = 0; i < expected.length; i++) {
      expect(
        state.auxProgressForTest(i) as double,
        closeTo(expected[i], 0.01),
        reason: '第 $i 行副行进度',
      );
    }
  }

  testWidgets('默认 currentLine：只有当前行副行展开', (tester) async {
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

    expect(state.auxTargetForTest(0) as double, 1.0);
    expect(state.auxTargetForTest(1) as double, 0.0);
    expectAuxProgress(state, <double>[1, 0, 0, 0]);
  });

  testWidgets('allLines：每行副行都展开', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

    expectAuxProgress(state, <double>[1, 1, 1, 1]);
    expect(state.auxAnimatingForTest as bool, isFalse, reason: '稳态不应继续推进');
  });

  testWidgets('hidePlayed：切行后已播行副行收回到 0', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.hidePlayed);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);
    // 当前行 = 第 0 行：0 号与之后的行都显示
    expectAuxProgress(state, <double>[1, 1, 1, 1]);

    pos.value = const Duration(milliseconds: 3500); // 当前行 = 第 1 行
    await settle(tester);
    expectAuxProgress(state, <double>[0, 1, 1, 1]);
  });

  testWidgets('关闭副行开关：三种范围都收起到 0', (tester) async {
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

    for (final scope in LyricAuxScope.values) {
      await LyricPreferences.instance.setAuxScope(scope);
      await settle(tester);
      await LyricPreferences.instance.setShowTranslation(false);
      await settle(tester);
      for (var i = 0; i < lines.length; i++) {
        expect(
          state.auxProgressForTest(i) as double,
          closeTo(0, 0.01),
          reason: 'scope=$scope 第 $i 行应收起',
        );
      }
      await LyricPreferences.instance.setShowTranslation(true);
      await settle(tester);
    }
  });

  testWidgets('高度不变量：上方副行累计 == 各行额外高度之和', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

    for (var k = 0; k <= lines.length; k++) {
      double sum = 0;
      for (var i = 0; i < k; i++) {
        sum += state.auxExtraForTest(i) as double;
      }
      expect(
        state.auxDeltaBeforeForTest(k) as double,
        closeTo(sum, 1e-6),
        reason: '第 $k 行上方累计高度必须等于逐行额外高度之和',
      );
    }

    // 展开中的中间态同样成立（半程取样）
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    await settle(tester, frames: 4);
    for (var k = 0; k <= lines.length; k++) {
      double sum = 0;
      for (var i = 0; i < k; i++) {
        sum += state.auxExtraForTest(i) as double;
      }
      expect(
        state.auxDeltaBeforeForTest(k) as double,
        closeTo(sum, 1e-6),
        reason: '过渡中（第 $k 行）同样成立',
      );
    }
  });

  testWidgets('高斯模糊开启：为有副行的行请求并缓存副行模糊图', (tester) async {
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

    // 造一张 2×2 占位图（同步栅格化，测试里不依赖 runAsync）
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

    final requested = <int>[];
    state.auxBlurRendererForTest =
        (int lineIndex, int blurLevel, DuetAlignment align) async {
          requested.add(lineIndex);
          return makeImage();
        };
    state.lineBlurRendererForTest =
        (int lineIndex, int blurLevel, DuetAlignment align) async => makeImage();

    await LyricPreferences.instance.setUseGaussianBlur(true);
    // 第 1 次 pump：偏好通知 → 重建 → 触发异步请求；
    // 后续 pump：请求完成后的 setState → 模糊层进入 widget 树。
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(requested, isNotEmpty, reason: '有副行的行必须请求副行模糊图');
    expect(
      state.auxBlurImageForTest(requested.first),
      isNotNull,
      reason: '副行图应写入 _auxBlurImages（合成期才能跟随进度绘制）',
    );
  });
}
