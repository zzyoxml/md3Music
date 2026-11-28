/// 回归：开启「隐藏歌词作者信息」过滤后，英文逐字歌第一句的翻译副行不展开。
///
/// 根因链（真机反馈 + 受控复现实证）：
/// 1. 「隐藏歌词作者信息」把头部名单行整块移除，过滤后的首行起点晚于间奏阈值
///    （默认 4000ms），视图登记「首行之前」的头部间奏槽位；
/// 2. 头部间奏期间渲染焦点是哨兵值 -1（占位本身），首行开唱瞬间翻转为 0；
/// 3. `_auxTargetsSignatureNow()` 曾把该焦点放进 Object.hash，而 Dart 的
///    Object.hash 对 (-1, x) 与 (0, x) 返回相同哈希 —— 签名判定"未变化"，
///    `_rebuildAuxTargets()` 在整场播放里再未被调用；
/// 4. 于是首行的翻译目标恒为 0：副行永远不展开、行盒也没有副行预留高度，
///    而其它行切换一切正常（与「仅限第一句」吻合）。
///
/// 本组用例钉死两条不变量：
/// A. 焦点 -1 → 0 的翻转必须触发目标重算（否则首句翻译永久消失）；
/// B. 高斯模糊偏好不得改变歌词几何（「打开模糊就正常」的对照口径）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 与头部间奏回归组同尺寸的夹具：fontSize=64、lineHeight=76.8。
  const step = Duration(milliseconds: 16);

  Future<void> pumpFrames(WidgetTester tester, int n) async {
    for (int i = 0; i < n; i++) {
      await tester.pump(step);
    }
  }

  /// 「隐藏歌词作者信息」过滤后的首行（名单行已移除）：逐字英文 + 中文翻译，
  /// 起点 12s（前奏超过间奏阈值 4s → 存在头部间奏槽位）。
  List<LyricLine> filteredSongLines() => <LyricLine>[
        LyricLine(
          startTime: 12000,
          duration: 4000,
          text: 'You were the mythical',
          translation: '你曾是那个神话般的存在',
          words: [
            LyricWord(startTime: 12000, duration: 400, text: 'You'),
            LyricWord(startTime: 12400, duration: 500, text: 'were'),
            LyricWord(startTime: 12900, duration: 450, text: 'the'),
            LyricWord(startTime: 13350, duration: 550, text: 'mythical'),
          ],
        ),
        LyricLine(
          startTime: 30000,
          duration: 4000,
          text: 'Eternal light of dawn',
          translation: '永恒的黎明之光',
        ),
      ];

  Future<dynamic> mount(
    WidgetTester tester,
    ValueNotifier<Duration> pos, {
    required bool useGaussian,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: AppleLyricsView(
              // 每次挂载给独立 key：否则两次挂载复用同一 State，
              // 帧时钟与弹簧历史会串到下一次运行，对照失去意义。
              key: ValueKey('mount-$useGaussian'),
              lines: filteredSongLines(),
              currentTimeMs: 0,
              positionListenable: pos,
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    return tester.state(find.byType(AppleLyricsView));
  }

  group('AM 歌词副行：头部间奏后首行翻译展开（签名碰撞回归）', () {
    testWidgets('头部间奏期间首行副行收起；开唱后目标立即展开为 1 并长出',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final blurWas = LyricPreferences.instance.useGaussianBlur;
      await LyricPreferences.instance.setUseGaussianBlur(false);

      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 2000));
      addTearDown(pos.dispose);
      addTearDown(() => LyricPreferences.instance
          .setUseGaussianBlur(blurWas));
      final state =
          await mount(tester, pos, useGaussian: false) as dynamic;

      await pumpFrames(tester, 40);
      // 基线：头部间奏占位期间没有任何行处于焦点 → 首行副行完全收起。
      expect(state.focusLineIndexForTest, -1,
          reason: '夹具应处于头部间奏期（焦点为哨兵 -1）');
      expect(state.auxTargetForTest(0), 0.0,
          reason: '间奏期间首行不应有副行');
      expect(state.auxProgressForTest(0), 0.0);

      // 首行开唱（12500ms > 11750ms 窗口终点）：焦点翻转为 0。
      pos.value = const Duration(milliseconds: 12500);
      await pumpFrames(tester, 2);
      expect(state.currentLineIndexForTest, 0);
      expect(state.focusLineIndexForTest, 0,
          reason: '开唱后焦点必须回到首行（翻转前的 -1 即根因入口）');
      // 核心回归断言：目标必须在焦点翻转的同一帧重算为 1。
      // 旧实现（Object.hash 碰撞）里它恒为 0，整场播放都不展开。
      expect(state.auxTargetForTest(0), 1.0,
          reason: '首行成为当前行后翻译目标必须立刻变为 1'
              '（旧实现因 Object.hash(-1,x)==hash(0,x) 永不重算，恒为 0）');

      // 展开过程：进度单调上升、副行额外高度同步增长。
      double prevP = state.auxProgressForTest(0) as double;
      bool sawPartialExpansion = false;
      for (int i = 0; i < 60; i++) {
        await tester.pump(step);
        final double p = state.auxProgressForTest(0) as double;
        expect(p, greaterThanOrEqualTo(prevP - 1e-9),
            reason: '副行进度必须单调上升，不能卡死或回退');
        prevP = p;
        if (p > 0.05 && p < 0.95) sawPartialExpansion = true;
        final double extra = state.auxExtraForTest(0) as double;
        expect(extra, greaterThanOrEqualTo(0));
        expect(extra, closeTo(p * state.auxSubHeightForTest(0), 1e-6),
            reason: '副行预留高度 = 满高度 × 进度');
      }
      expect(sawPartialExpansion, isTrue, reason: '应观察到中间态的过渡过程');

      // 收敛：翻译展开到满高度，行距不再变化（下方行零位移）。
      await pumpFrames(tester, 60);
      expect(state.auxProgressForTest(0) -
          state.auxTargetForTest(0),
          lessThan(0.02),
          reason: '过渡完成后进度应收敛到目标 1');
      expect(state.auxExtraForTest(0) -
          state.auxSubHeightForTest(0),
          lessThan(0.02),
          reason: '满进度下首行行盒应含完整副行预留高度');

      // 行序不变：第一行始终在第二行上方，且两者行距稳定（无挤压重叠）。
      final double y0 = state.lineScreenYForTest(0) as double;
      final double y1 = state.lineScreenYForTest(1) as double;
      expect(y1, greaterThan(y0));
      final double y0Again = state.lineScreenYForTest(0) as double;
      final double y1Again = state.lineScreenYForTest(1) as double;
      expect((y1Again - y0Again) - (y1 - y0), lessThan(0.5),
          reason: '副行展开过程中行距应保持稳定');
    });

    testWidgets('无头部间奏的歌不受影响（焦点直接为首行，行为同旧版）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final blurWas = LyricPreferences.instance.useGaussianBlur;
      await LyricPreferences.instance.setUseGaussianBlur(false);

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => LyricPreferences.instance
          .setUseGaussianBlur(blurWas));

      // 首行 1s 起唱：不产生头部间奏槽位（对照夹具）。
      final lines = <LyricLine>[
        LyricLine(
          startTime: 1000,
          duration: 2000,
          text: 'Hello world tonight',
          translation: '今夜你好世界',
          words: [
            LyricWord(startTime: 1000, duration: 400, text: 'Hello'),
            LyricWord(startTime: 1400, duration: 400, text: 'world'),
            LyricWord(startTime: 1800, duration: 400, text: 'tonight'),
          ],
        ),
        LyricLine(
          startTime: 6000,
          duration: 2000,
          text: 'Goodnight my love',
          translation: '晚安我的爱',
        ),
      ];
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 1500));
      addTearDown(pos.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: AppleLyricsView(
                lines: lines,
                currentTimeMs: 0,
                positionListenable: pos,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      final state =
          tester.state(find.byType(AppleLyricsView)) as dynamic;

      await pumpFrames(tester, 10);
      expect(state.focusLineIndexForTest, 0,
          reason: '无头部间奏时焦点就是首行（不存在 -1 哨兵阶段）');
      expect(state.auxTargetForTest(0), 1.0,
          reason: '首行为当前行 → 翻译目标立即为 1（旧版本同样满足）');
      await pumpFrames(tester, 60);
      expect(state.auxProgressForTest(0) -
          state.auxTargetForTest(0),
          lessThan(0.02));
    });
  });

  group('AM 歌词副行：多视觉行首行的几何（真机 Stay Beautiful 对照）', () {
    // 真机场景复现：Taylor Swift《Stay Beautiful》首句折 2 个视觉行、
    // 翻译同样折行；此前回归夹具全是单行，覆盖不到换行行的副行定位。
    // 断言：翻译底部不得越过下一行顶部；主行底到翻译顶有正常间隙；
    // 展开全程下一行不被压叠。
    testWidgets('折行首行：副行底部始终在下一行顶部之上，且间隙随进度同步',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final blurWas = LyricPreferences.instance.useGaussianBlur;
      await LyricPreferences.instance.setUseGaussianBlur(false);

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => LyricPreferences.instance
          .setUseGaussianBlur(blurWas));

      // 首行刻意折成 2 个视觉行、翻译折 2 行；次行单行、长前奏触发头部间奏。
      final lines = <LyricLine>[
        LyricLine(
          startTime: 12000,
          duration: 5000,
          text: 'Corey eyes are like a jungle tonight in the window',
          translation: '科里的眼睛像今夜窗外的丛林一样',
          words: [
            LyricWord(startTime: 12000, duration: 350, text: 'Corey'),
            LyricWord(startTime: 12350, duration: 300, text: 'eyes'),
            LyricWord(startTime: 12650, duration: 380, text: 'are'),
            LyricWord(startTime: 13030, duration: 420, text: 'like'),
            LyricWord(startTime: 13450, duration: 400, text: 'a'),
            LyricWord(startTime: 13850, duration: 900, text: 'jungle'),
            LyricWord(startTime: 14750, duration: 700, text: 'tonight'),
            LyricWord(startTime: 15450, duration: 500, text: 'in'),
            LyricWord(startTime: 15950, duration: 550, text: 'the'),
            LyricWord(startTime: 16500, duration: 1100, text: 'window'),
          ],
        ),
        LyricLine(
          startTime: 32000,
          duration: 4000,
          text: 'He smiles like the radio plays his song',
          translation: '他微笑得像收音机放着他的歌',
        ),
      ];
      final pos = ValueNotifier<Duration>(const Duration(milliseconds: 2000));
      addTearDown(pos.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: AppleLyricsView(
                key: const ValueKey('wrap-first'),
                lines: lines,
                currentTimeMs: 0,
                positionListenable: pos,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      final state =
          tester.state(find.byType(AppleLyricsView)) as dynamic;

      // 头部间奏 → 首行开唱
      await pumpFrames(tester, 40);
      expect(state.focusLineIndexForTest, -1);
      pos.value = const Duration(milliseconds: 12500);
      await pumpFrames(tester, 3);
      expect(state.auxTargetForTest(0), 1.0);

      final double auxH = state.auxSubHeightForTest(0) as double;
      // 基线行距：首行副行尚未展开时的 y1-y0（纯主行高 + 已有偏移）。
      // 模型不变量：展开中任意时刻 (y1-y0) 必须 ≈ 基线行距 + auxH×进度。
      // 若预留不足，翻译底部会越过下一行顶部（「拥挤/重叠」的直接量测）。
      final double y1Base = state.lineScreenYForTest(1) as double;
      final double y0Base = state.lineScreenYForTest(0) as double;
      final double basePitch = y1Base - y0Base;
      void checkPitch(String tag) {
        final double y0 = state.lineScreenYForTest(0) as double;
        final double y1 = state.lineScreenYForTest(1) as double;
        final double p = state.auxProgressForTest(0) as double;
        expect(y1, greaterThan(y0), reason: '$tag：行序不得颠倒');
        final double expected = basePitch + auxH * p;
        expect((y1 - y0) - expected, lessThan(3.0),
            reason: '$tag：实测行距 (${(y1 - y0).toStringAsFixed(1)}) '
                '应等于基线(${basePitch.toStringAsFixed(1)}) + 副行满高'
                '(${auxH.toStringAsFixed(1)})×进度(${p.toStringAsFixed(2)})；'
                '明显小于即意味着翻译越过下一行顶部（拥挤）');
        expect((y1 - y0) - expected, greaterThanOrEqualTo(-3.0));
      }

      checkPitch('刚开唱');
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        checkPitch('展开中 t=${(i / 120 * 100).round()}%');
      }
      // 收敛态：行距含完整副行预留
      await pumpFrames(tester, 60);
      checkPitch('收敛');
      expect((state.auxProgressForTest(0) as double) -
          state.auxTargetForTest(0),
          lessThan(0.02));

      await LyricPreferences.instance.setUseGaussianBlur(blurWas);
    });
  });

  group('AM 歌词副行：模糊开关不改变首行几何（「开模糊正常」对照）', () {
    testWidgets('高斯模糊开/关两种偏好下行 y 与副行进度逐点一致',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final blurWas = LyricPreferences.instance.useGaussianBlur;

      Future<List<double>> samplePath({required bool useGaussian}) async {
        await LyricPreferences.instance.setUseGaussianBlur(useGaussian);
        final pos =
            ValueNotifier<Duration>(const Duration(milliseconds: 2000));
        try {
          final state = await mount(tester, pos, useGaussian: useGaussian)
              as dynamic;
          final List<double> path = <double>[];
          await pumpFrames(tester, 40);
          path.add(state.lineScreenYForTest(0) as double);
          path.add(state.lineScreenYForTest(1) as double);
          path.add(state.auxExtraForTest(0) as double);
          path.add(state.auxProgressForTest(0) as double);
          pos.value = const Duration(milliseconds: 12500);
          await pumpFrames(tester, 3);
          path.add(state.auxTargetForTest(0) as double);
          path.add(state.lineScreenYForTest(0) as double);
          await pumpFrames(tester, 120);
          path.add(state.lineScreenYForTest(0) as double);
          path.add(state.lineScreenYForTest(1) as double);
          path.add(state.auxExtraForTest(0) as double);
          path.add(state.auxProgressForTest(0) as double);
          return path;
        } finally {
          pos.dispose();
        }
      }

      final offPath = await samplePath(useGaussian: false);
      final onPath = await samplePath(useGaussian: true);

      expect(onPath.length, offPath.length);
      for (int i = 0; i < offPath.length; i++) {
        expect(onPath[i], closeTo(offPath[i], 0.01),
            reason: '采样点 $i：模糊偏好（${onPath[i]} vs ${offPath[i]}）'
                '不应改变歌词几何——关闭模糊也必须与开启模糊同布局');
      }
      // 两条路径都应完成首行翻译展开（本修复的核心行为，模糊无关）。
      expect(offPath.last, greaterThan(0.99));
      expect(onPath.last, greaterThan(0.99));

      await LyricPreferences.instance.setUseGaussianBlur(blurWas);
    });
  });
}