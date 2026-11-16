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

  testWidgets('仅当前行范围：非当前行副行完全收起，不烘焙副行模糊图',
      (tester) async {
    // currentLine 范围下非当前行的副行进度/目标都恒为 0，不参与模糊渲染；
    // 当前行本身走清晰层，因此该范围不会烘焙任何副行模糊图。
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);

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

    final auxRequested = <int>[];
    final mainRequested = <int>[];
    state.auxBlurRendererForTest =
        (int lineIndex, int blurLevel, DuetAlignment align) async {
          auxRequested.add(lineIndex);
          return makeImage();
        };
    state.lineBlurRendererForTest =
        (int lineIndex, int blurLevel, DuetAlignment align) async {
          mainRequested.add(lineIndex);
          return makeImage();
        };

    await LyricPreferences.instance.setUseGaussianBlur(true);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(mainRequested, isNotEmpty, reason: '主行模糊图仍应正常烘焙');
    expect(auxRequested, isEmpty, reason: 'currentLine 范围不应烘焙副行模糊图');
    expect(state.auxBlurImageForTest(state.currentLineIndexForTest as int),
        isNull,
        reason: '副行模糊缓存不应写入');
  });

  testWidgets('已播行除外：退场中的副行不参与模糊渲染', (tester) async {
    // 收起期间副行模糊图的块几何/翻转锚点与清晰副行不同步（错位），
    // 因此收起中的副行不烘焙也不绘制，由清晰层跟随收起。
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.hidePlayed);
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);
    // 当前行 = 第 0 行：0..3 的副行都展开。
    expectAuxProgress(state, <double>[1, 1, 1, 1]);
    expect(state.auxBlurVisibleForTest(0) as bool, isTrue,
        reason: '前置：展开态的副行参与模糊渲染');

    // 切到第 1 行：第 0 行副行开始收起。
    pos.value = const Duration(milliseconds: 3500);
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.auxProgressForTest(0) as double, greaterThan(0.5),
        reason: '前置：退场行副行仍在展开高度上（正在收起）');
    expect(state.auxBlurVisibleForTest(0) as bool, isFalse,
        reason: '收起中的副行不得参与模糊渲染（否则与清晰副行错位）');
    expect(state.auxBlurVisibleForTest(1) as bool, isTrue,
        reason: '展开态/当前行副行仍应参与模糊渲染');
  });

  testWidgets('切行：副行过渡平滑起步（首帧增量≈0）且收起+展开互补', (tester) async {
    // 指数插值首帧就会掉 ~10%（行时长 3000ms → 速率 6.9/s），把下方所有行
    // 整体拽动一截——「上拉到位速度突变、有翻译副行更明显」的根因。
    // smoothstep 两端速度为 0：切行首帧增量应为 0。
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    final state = await mount(tester, pos);
    await settle(tester);
    expectAuxProgress(state, <double>[1, 0, 0, 0]);

    // 切到第 1 行：第 0 行副行收起、第 1 行展开。
    pos.value = const Duration(milliseconds: 3500);
    await tester.pump(const Duration(milliseconds: 16));
    final double p0 = state.auxProgressForTest(0) as double;
    final double p1 = state.auxProgressForTest(1) as double;
    expect(1.0 - p0, lessThan(0.02),
        reason: '切行首帧旧行副行收起不得突跳'
            '（实测 ${(1 - p0).toStringAsFixed(3)}）');
    expect(p1, lessThan(0.02),
        reason: '切行首帧新行副行展开不得突跳'
            '（实测 ${p1.toStringAsFixed(3)}）');
    expect(p0 + p1, closeTo(1.0, 0.01),
        reason: '收起 + 展开互补，保证当前行以下的行零位移');

    // 过渡全程保持互补（同一时长、同一时间锚），最终到达目标。
    for (var f = 0; f < 80; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      final double a = state.auxProgressForTest(0) as double;
      final double b = state.auxProgressForTest(1) as double;
      expect(a + b, closeTo(1.0, 0.01),
          reason: '第 $f 帧：收起+展开之和必须恒为 1');
    }
    expectAuxProgress(state, <double>[0, 1, 0, 0]);
  });
}
