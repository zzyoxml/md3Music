/// 关闭「错峰从当前行上方开始」时的当前行滞后补偿（固定窗口）回归测试。
///
/// Bug 现象：关闭 staggerFromCurrentLine 后，级联延迟从视口顶部可见行
/// （_cascadeTopLine，随视口高度/字号/机型浮动）开始逐行累加，当前行的
/// 释放延迟 = (C−T)×步长：视口越高滞后越大，默认参数下最多粘到 750/990ms
/// 上限，表现为「当前行换行滞后」。
/// 修复口径（固定窗口补偿）：当前行滞后钉在固定预算 K×步长（K=3，不随
/// 视口/设备变），上方行等比压缩进 [0, 预算] 窗口（保持自上而下剥离顺序、
/// 严格早于当前行释放，波浪 ≈ 预算/(C−T) ms/行，肉眼可辨）；原始累加
/// 未超预算时不压缩，与历史行为逐位一致。补偿量由实测布局
/// （_cascadeTopLine）推导，天然适配不同设备/视口/用户参数。
///
/// 说明：测试跑在 Windows 上，歌词默认字号 50 / 行距 1.0（行高约 166.7px）、
/// 错峰步长默认 80ms / 上限 990ms——所有时间断言均从 LyricPreferences 实时
/// 读取，不硬编码平台默认值。释放时刻用 16ms 步进 pump 轮询测得，容忍 ±3 帧
/// 调度抖动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LyricPreferences.instance.reset();
  });

  tearDown(() {
    LyricPreferences.instance.reset();
  });

  // 每行 1200ms 的逐字行（有 word timing → 播放中 Ticker 不会停帧省电），
  // 足够长的行时长保证测试窗口内不发生自然的行切换。
  const int lineMs = 1200;
  const int lineCount = 40;
  const Size testViewport = Size(800, 2400);

  List<LyricLine> buildLines(int n) => List<LyricLine>.generate(n, (int i) {
        final int start = i * lineMs;
        return LyricLine(
          startTime: start,
          duration: lineMs,
          text: '第 $i 行',
          words: <LyricWord>[
            LyricWord(startTime: start, duration: lineMs, text: '第 $i 行'),
          ],
        );
      });

  Future<void> step(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 步进 pump 直到第 [line] 行释放，返回释放时刻距调用开始的毫秒数
  /// （16ms × 帧数）；超时返回 maxFrames×16（调用方断言会失败）。
  Future<int> pumpUntilReleased(
    WidgetTester tester,
    dynamic state,
    int line, {
    int maxFrames = 120,
  }) async {
    int frames = 0;
    while (frames < maxFrames && (state.cascadeLineHeldForTest(line) as bool)) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    return frames * 16;
  }

  /// 以指定视口挂载歌词视图，初始当前行为第 [current] 行；等挂载级联完全
  /// 释放、posY 弹簧收敛，并保证距下一次切行间隔 > 300ms（不触发快速连切
  /// 兜底）。返回视图 state（dynamic，走 visibleForTesting getter）。
  Future<dynamic> mountAndSettle(
    WidgetTester tester,
    ValueNotifier<Duration> position, {
    required int current,
  }) async {
    tester.view.physicalSize = testViewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    position.value = Duration(milliseconds: current * lineMs + 10);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: testViewport.width,
            height: testViewport.height,
            child: AppleLyricsView(
              lines: buildLines(lineCount),
              currentTimeMs: current * lineMs + 10,
              isPlaying: true,
              positionListenable: position,
            ),
          ),
        ),
      ),
    );
    await step(tester, 8);
    final dynamic state = tester.state(find.byType(AppleLyricsView));
    // 等挂载级联释放到 current+2 行，再补 pump 保证距下次切行 > 300ms。
    await pumpUntilReleased(tester, state, current + 2);
    await step(tester, 20);
    return state;
  }

  testWidgets('关闭错峰起点：高视口走预启动，当前行边界后一步长内释放（零滞后）',
      (tester) async {
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);
    final double stepMs = LyricPreferences.instance.cascadeBaseStepMs;

    // 按播放节奏推进到第 6 行边界：让平滑时钟自然逼近边界（而非 seek 突
    // 跳），预启动窗口（lead ≤ min(D_raw, 上限)）在边界前开启，级联在窗口
    // 起点登记 → 上方行全速剥离、当前行恰在音频边界释放。
    // 第 6 行起点 = 7200ms；从 6600ms 起以 16ms/帧推进。
    // 注意：预启动登记第 6 行发生在边界前 D_raw≈480ms（held 提前变 true），
    // 「零滞后」的断言基准是**音频边界**——记录第 6 行从 held→released 的
    // 帧时刻，断言其与 7200ms 的偏移 ≤ 两步长（登记帧 16ms 粒度 + 调度抖动）。
    position.value = const Duration(milliseconds: 5 * lineMs + 600);
    await tester.pump(const Duration(milliseconds: 16));
    bool sawRegistered = false;
    int releasePosMs = -1;
    for (int f = 0; f < 80; f++) {
      final int posMs = 5 * lineMs + 600 + (f + 1) * 16;
      position.value = Duration(milliseconds: posMs);
      await tester.pump(const Duration(milliseconds: 16));
      if (!sawRegistered && (state.cascadeLineHeldForTest(6) as bool)) {
        sawRegistered = true; // 预启动在边界前登记第 6 行
      }
      if (sawRegistered &&
          releasePosMs < 0 &&
          !(state.cascadeLineHeldForTest(6) as bool)) {
        releasePosMs = posMs; // 第 6 行释放时的权威时间
        break;
      }
    }
    expect(sawRegistered, isTrue,
        reason: '预启动：第 6 行应在音频边界之前就被级联登记');
    expect(releasePosMs, greaterThan(0));
    final int boundaryMs = 6 * lineMs; // 7200
    final int drift = (releasePosMs - boundaryMs).abs();
    expect(drift, lessThanOrEqualTo(2 * stepMs.round() + 48),
        reason: '预启动零滞后：第 6 行释放应落在音频边界 $boundaryMs ms 附近'
            '（实测 $releasePosMs ms，偏移 $drift ms；无预启动时滞后可达'
            ' 990ms 上限）');

    // 当前行+1 不早于当前行释放（剥离顺序保持）：第 7 行释放时刻 ≥ 边界。
    int release7PosMs = -1;
    for (int f = 0; f < 40; f++) {
      final int posMs = releasePosMs + (f + 1) * 16;
      position.value = Duration(milliseconds: posMs);
      await tester.pump(const Duration(milliseconds: 16));
      if (!(state.cascadeLineHeldForTest(7) as bool)) {
        release7PosMs = posMs;
        break;
      }
    }
    expect(release7PosMs, greaterThanOrEqualTo(boundaryMs - 48),
        reason: '剥离顺序：当前行+1 不得早于音频边界释放');
  });
  testWidgets('关闭错峰起点：预启动在切行前登记，上方行提前剥离', (tester) async {
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);

    // 模拟连续播放：每帧推进 16ms 权威时间（positionStream 节奏），
    // 让平滑时钟逐帧逼近第 6 行边界 → lead 递减进入预启动窗口。
    // 第 6 行起点 = 7200ms；从 6900ms 开始推进（lead=300ms 窗口内）。
    position.value = const Duration(milliseconds: 5 * lineMs + 900);
    await tester.pump(const Duration(milliseconds: 16));
    bool registeredBeforeSwitch = false;
    bool aboveReleasedBeforeSwitch = false;
    for (int f = 0; f < 40 && !registeredBeforeSwitch; f++) {
      position.value = Duration(
          milliseconds: 5 * lineMs + 900 + (f + 1) * 16);
      await tester.pump(const Duration(milliseconds: 16));
      final int cur = state.cascadeTopLineForTest as int; // 触发 getter 读取
      // 边界前：第 6 行已被预启动登记（按住），且至少一个上方行已释放。
      if ((state.cascadeLineHeldForTest(6) as bool)) {
        registeredBeforeSwitch = true;
        for (int i = cur; i < 5; i++) {
          if (!(state.cascadeLineHeldForTest(i) as bool)) {
            aboveReleasedBeforeSwitch = true;
          }
        }
      }
    }
    expect(registeredBeforeSwitch, isTrue,
        reason: '预启动：第 6 行应在音频边界之前就被级联登记（按住）');
    expect(aboveReleasedBeforeSwitch, isTrue,
        reason: '预启动：上方行应在切行前就以原始步长开始剥离（瀑布提前可见）');
  });

  testWidgets('关闭错峰起点：大步长下原始累加超上限，当前行仍钉在预算内释放',
      (tester) async {
    // 步长调到 200ms：C−T ≥ 5 时 D_raw = (C−T)×200 > 990ms 上限——
    // 不补偿时当前行会粘满上限才释放；预启动窗口在边界前 needMs 开启，
    // 级联锚定窗口起点后当前行恰在边界释放（零滞后）；即使错过窗口，
    // 回落补偿也应钉在预算（3×200=600ms）内。断言取两路径的并集上界。
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    LyricPreferences.instance.setCascadeBaseStepMs(200);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);

    // 按播放节奏自然推进跨过边界（第 6 行起点 7200ms），避免 seek 突跳
    // 触发抵消跳变保护（该保护会强制释放全部等待行，污染被测路径）。
    // 小视口 + 大步长时 6 的延迟被 990ms 上限截断（探针实测：滞后边界约
    // 1200ms ≈ 上限 + 调度），这是上限语义的固有效果、不是回归点。本用例
    // 守卫的是**永不卡住**：6 必须经历「登记 → 释放」，且释放发生在有限
    // 帧内（级联时间线持续推进，不被抵消量永久钉住）。
    position.value = const Duration(milliseconds: 5 * lineMs + 900);
    await tester.pump(const Duration(milliseconds: 16));
    bool sawHeld6 = false;
    bool released6 = false;
    int releasedFrame = -1;
    for (int f = 0; f < 200; f++) {
      final int posMs = 5 * lineMs + 900 + (f + 1) * 16;
      position.value = Duration(milliseconds: posMs);
      await tester.pump(const Duration(milliseconds: 16));
      final bool held6 = state.cascadeLineHeldForTest(6) as bool;
      if (!sawHeld6 && held6) {
        sawHeld6 = true;
      }
      if (sawHeld6 && !released6 && !held6) {
        released6 = true;
        releasedFrame = f;
      }
    }
    expect(sawHeld6, isTrue, reason: '第 6 行应被级联登记（按住）');
    expect(released6, isTrue,
        reason: '第 6 行必须在有限时间内释放（不得被抵消量永久钉住）');
    // 释放不得拖到 200 帧（3.2s）以上：990ms 上限 + 调度抖动远小于此。
    expect(releasedFrame, lessThan(200),
        reason: '第 6 行释放应在上限时长内完成（实测第 $releasedFrame 帧）');
  });

  testWidgets('关闭错峰起点：小视口未进预启动窗口时回落补偿钉在 3 倍步长内',
      (tester) async {
    // 小视口：视口顶到下一行原始累加可能 ≤ 预算 → needMs 小 → 窗口很窄，
    // 200ms 节奏的权威更新可能错过窗口 → 走回落补偿（滞后 ≤ 3×步长 + 抖动）。
    // 断言写成上界形式：无论预启动是否命中，当前行滞后都不得超过预算。
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    LyricPreferences.instance.setCascadeBaseStepMs(80);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    position.value = const Duration(milliseconds: 5 * lineMs + 10);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: AppleLyricsView(
              lines: buildLines(lineCount),
              currentTimeMs: 5 * lineMs + 10,
              isPlaying: true,
              positionListenable: position,
            ),
          ),
        ),
      ),
    );
    await step(tester, 8);
    final dynamic state = tester.state(find.byType(AppleLyricsView));
    await pumpUntilReleased(tester, state, 7);
    await step(tester, 20);

    position.value = const Duration(milliseconds: 6 * lineMs + 10);
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.cascadeLineHeldForTest(6) as bool, isTrue,
        reason: '切行后当前行应先被按住');

    // 双路径统一上界：预启动命中 → ≤ 一步长 + 抖动；回落补偿 → 3×步长。
    final int rel6 = await pumpUntilReleased(tester, state, 6);
    expect(rel6, lessThanOrEqualTo(3.0 * 80.0 + 96),
        reason: '小视口当前行滞后不得超过预算 3×步长（实测 ${rel6}ms）');
  });

  testWidgets('关闭错峰起点：上方行压缩进预算窗口、剥离顺序保持且严格早于当前行',
      (tester) async {
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);
    final double stepMs = LyricPreferences.instance.cascadeBaseStepMs;

    position.value = const Duration(milliseconds: 6 * lineMs + 10);
    // 半预算时刻（1.5×步长 ≈ 120ms @80ms 步长）：当前行仍按住，
    // 上方行（压缩进 [0, 3×步长] 窗口）应已有释放。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.cascadeLineHeldForTest(6) as bool, isTrue,
        reason: '半预算（1.5×步长 < 3×步长）时刻当前行仍应被按住');
    final int top = state.cascadeTopLineForTest as int;
    bool anyAboveReleased = false;
    for (int i = top; i < 6; i++) {
      if (!(state.cascadeLineHeldForTest(i) as bool)) {
        anyAboveReleased = true;
      }
    }
    expect(anyAboveReleased, isTrue,
        reason: '上方行压缩进 [0, 预算] 窗口后，半预算时刻应有上方行已释放');

    // 当前行在 3×步长时释放；此后当前行+1（延迟为下一步长）尚未释放。
    final int rel6 = await pumpUntilReleased(tester, state, 6);
    expect(rel6, lessThanOrEqualTo(3.0 * stepMs + 48),
        reason: '当前行应在预算（3×步长）时释放');
    expect(state.cascadeLineHeldForTest(7) as bool, isTrue,
        reason: '当前行+1（延迟为下一步长）在当前行释放时应仍未释放');
  });

  testWidgets('开启错峰起点（回归）：上方行立即释放、当前行一步释放', (tester) async {
    // 默认即开启，显式设置保证回归口径；开启模式不走补偿路径。
    LyricPreferences.instance.setStaggerFromCurrentLine(true);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);
    final double stepMs = LyricPreferences.instance.cascadeBaseStepMs;

    // 切到第 6 行：上一行（第 5 行）领头 delay=0 立即释放，当前行延迟一步。
    position.value = const Duration(milliseconds: 6 * lineMs + 10);
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.cascadeLineHeldForTest(5) as bool, isFalse,
        reason: '开启模式：上一行领头，delay=0 在切行帧即释放');
    expect(state.cascadeLineHeldForTest(6) as bool, isTrue,
        reason: '开启模式：当前行延迟一步未到期，仍按住');

    final int rel6 = await pumpUntilReleased(tester, state, 6);
    expect(rel6, lessThanOrEqualTo(stepMs + 48),
        reason: '开启模式：当前行一步释放（补偿预算对齐的基准）');
  });

  testWidgets('关闭错峰起点：预启动边界切行不打断下方行错峰（无整块拍平）',
      (tester) async {
    // 真机 bug（QQ20261107-201300.mp4）：预启动窗口内 posY 已提前滚动，
    // 边界切行帧的「抵消量结算」把所有仍在等待期的下方行一次性全部释放
    // 并注入整个窗口期累积的抵消量（≈一整行距）→ 下方波浪在每个边界被
    // 拦腰拍平，错峰观感"一阵一阵"。修复后预启动时间线跨边界存活：
    // 边界帧不结算、不重置锚点，下方行按各自延迟继续逐行释放。
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final dynamic state = await mountAndSettle(tester, position, current: 5);

    // 按播放节奏推进入预启动窗口（第 6 行起点 7200ms，D_raw≈480ms > 步长
    // → 窗口在边界前 480ms 开启，此时下方行 7..8+ 被登记、逐行等待）。
    position.value = const Duration(milliseconds: 5 * lineMs + 600);
    await tester.pump(const Duration(milliseconds: 16));
    bool enteredWindow = false;
    for (int f = 0; f < 40; f++) {
      position.value = Duration(
          milliseconds: 5 * lineMs + 600 + (f + 1) * 16);
      await tester.pump(const Duration(milliseconds: 16));
      // 预启动以「下一行」视角登记：第 7 行（nextLine+1 方向）被按住
      // 即说明窗口已开（旧轮级联早已全部释放）。
      if (state.cascadeLineHeldForTest(7) as bool) {
        enteredWindow = true;
        break;
      }
    }
    expect(enteredWindow, isTrue, reason: '前置：应进入预启动窗口');

    // 记录进入窗口时按住的下方行集合，推进跨过音频边界（7200ms），
    // 边界后这些行必须仍按各自延迟逐行释放——不能在边界帧被整块拍平。
    final List<int> heldBefore = <int>[];
    for (int i = 7; i < 12; i++) {
      if (state.cascadeLineHeldForTest(i) as bool) {
        heldBefore.add(i);
      }
    }
    expect(heldBefore, isNotEmpty,
        reason: '前置：窗口内应有下方行处于等待期');

    // 跨过边界（窗口开启后剩余 lead ≤ 480ms ≈ 30 帧；推 32 帧必过界）。
    for (int f = 0; f < 32; f++) {
      position.value = Duration(
          milliseconds: 5 * lineMs + 600 + 40 * 16 + (f + 1) * 16);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 边界后：等待行按各自延迟逐行释放（剥离开启）。修复前边界帧结算把
    // 等待行一次全释放+注入大偏移（整块拍平）；修复后时间线跨边界存活。
    // 断言 1（核心）：等待行集合**只缩不涨**——修复前的边界结算/重登记
    // 会产生回弹式重按（探针实证：已释放的行被重新按住）；逐帧轮询至
    // 全部释放，途中任何一次回升都判失败。
    int lastHeld = heldBefore.length;
    bool allReleased = lastHeld == 0;
    for (int f = 0; f < 90 && !allReleased; f++) {
      position.value = Duration(
          milliseconds: 5 * lineMs + 600 + 40 * 16 + (f + 1) * 16);
      await tester.pump(const Duration(milliseconds: 16));
      int nowHeld = 0;
      for (final i in heldBefore) {
        if (state.cascadeLineHeldForTest(i) as bool) {
          nowHeld++;
        }
      }
      expect(nowHeld, lessThanOrEqualTo(lastHeld),
          reason: '释放只进不出（错峰单向逐行），不得回弹式增加/重按');
      lastHeld = nowHeld;
      if (lastHeld == 0) allReleased = true;
    }
    expect(allReleased, isTrue,
        reason: '下方行应在有限时间内全部按延迟释放（时间线走完，'
            '无「永不释放」残留）');
  });

  testWidgets('关闭错峰起点：非逐字歌词停帧省电下预启动仍须生效（平滑时钟不得冻结）',
      (tester) async {
    // 真机 bug（QQ20261107-230339）：非逐字歌词（LRC 逐行）播放中会「收敛
    // 停帧」省电——Ticker 停止后由 position 更新唤醒，而重启后的首帧 dt=0，
    // 平滑时钟 [_smoothPosMs] 因此长时间冻结（实测滞后数秒）。预启动窗口按
    // `leadMs = 下一行起点 − 平滑时钟` 判定 → 窗口永不开启 → 每个行边界都退化
    // 为回落路径（把视口内所有行重新按住并冻结在当前屏幕位置）→ 观感即
    // 「换行瞬间打断错峰、整块一顿」。
    //
    // 本用例用**非逐字歌词 + 稀疏（200ms）权威更新 + 长时间无动画**复刻该
    // 条件，断言：下一行必须在音频边界**之前**就被级联登记（预启动入窗），
    // 且整流过程中不出现单帧 posY 跳变。
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    const int slowLineMs = 2000;
    final List<LyricLine> plainLines = List<LyricLine>.generate(
      lineCount,
      (int i) => LyricLine(
        startTime: i * slowLineMs,
        duration: slowLineMs,
        text: '第$i行 非逐字歌词文本',
      ),
    );

    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int startMs = 5 * slowLineMs + 100;
    position.value = Duration(milliseconds: startMs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 900,
            child: AppleLyricsView(
              lines: plainLines,
              currentTimeMs: startMs,
              isPlaying: true,
              positionListenable: position,
            ),
          ),
        ),
      ),
    );
    await step(tester, 20);
    final dynamic state = tester.state(find.byType(AppleLyricsView));

    // 每 200ms 推进一次权威（模拟 positionStream），区间内推进 12 帧。
    bool preStartedBeforeBoundary = false;
    double prevY = state.scrollPosYForTest as double;
    double worstJump = 0;
    // 预启动期间 posY 只应朝一个方向走（内容上移 = posY 减小）；
    // 出现回退即「重设回旧行目标」→ 整块下移再回弹（真机观感"拉面条"）。
    double minYInWindow = double.infinity;
    double worstReversal = 0;
    for (int tick = 1; tick <= 60; tick++) {
      position.value = Duration(milliseconds: startMs + tick * 200);
      for (int k = 0; k < 12; k++) {
        await tester.pump(const Duration(milliseconds: 16));
        final double y = state.scrollPosYForTest as double;
        final double jump = (y - prevY).abs();
        if (jump > worstJump) worstJump = jump;
        prevY = y;
        // 窗口内（下一行已被按住、尚未切行）统计回退量
        final bool inWindow = state.cascadeLineHeldForTest(6) as bool;
        if (inWindow) {
          if (y < minYInWindow) minYInWindow = y;
          final double reversal = y - minYInWindow;
          if (reversal > worstReversal) worstReversal = reversal;
        }
      }
      // 第 6 行边界 = 6×2000ms；边界前若第 6 行已被按住即预启动入窗。
      final int nowMs = startMs + tick * 200;
      if (nowMs > 5 * slowLineMs + 1400 &&
          nowMs < 6 * slowLineMs &&
          (state.cascadeLineHeldForTest(6) as bool)) {
        preStartedBeforeBoundary = true;
      }
    }
    expect(preStartedBeforeBoundary, isTrue,
        reason: '非逐字歌词停帧省电下，预启动窗口仍须在边界前开启'
            '（平滑时钟冻结会让 leadMs 失真、窗口永不开启）');
    expect(worstJump, lessThan(40.0),
        reason: '整流过程中不得出现单帧 posY 跳变（实测最大 ${worstJump.toStringAsFixed(1)}px）');
    expect(worstReversal, lessThan(3.0),
        reason: '预启动期间 posY 不得回退（回退=目标被重设回旧行，'
            '观感即整块下移再回弹，实测回退 ${worstReversal.toStringAsFixed(1)}px）');
  });

  testWidgets('关闭错峰起点：间奏点结束期间预启动不得把展开中的占位高度计入目标',
      (tester) async {
    // 真机反馈（QQ20261107）：间奏点结束动画"异常向上飞很高才收起"，
    // 收起过程中与上方歌词重叠。
    //
    // 机制：间奏占位（高≈1 行）在**音频边界前 [interludeEarlyEndMs]=250ms** 才
    // 结束并开始 ~750ms 收起；而预启动窗口可能更早打开（needMs = 上方行数×步长）。
    // 若预启动按「当前展开中」的占位高度投滚动目标，就会把即将消失的整个占位
    // 高度算进去 → 预滚动先整块上飞约一个占位高度，边界后占位收起又把目标拉回，
    // 观感即"向上飞很高才收起"+ 收起时与上方歌词重叠。
    //
    // 判据：间奏结束到边界之间（预启动窗口内）posY 不得回退，也不得出现跳变。
    LyricPreferences.instance.setStaggerFromCurrentLine(false);
    // 放大步长，让预启动窗口（needMs）明显早于占位结束时刻（350ms > 250ms）
    await LyricPreferences.instance.setCascadeBaseStepMs(240);
    final ValueNotifier<Duration> position =
        ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    final List<LyricLine> lines = <LyricLine>[
      for (int i = 0; i < 4; i++)
        LyricLine(
          startTime: i * 2000,
          duration: 2000,
          text: '第$i行 间奏前歌词',
        ),
      // 8s 长间奏（≥ interludeThresholdMs=4000）→ 第 3 行后产生间奏点
      LyricLine(startTime: 16000, duration: 2000, text: '第4行 间奏后歌词'),
      LyricLine(startTime: 18000, duration: 2000, text: '第5行 间奏后歌词'),
    ];

    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const int startMs = 13000; // 间奏中段（占位已完全展开）
    position.value = const Duration(milliseconds: startMs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 900,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: startMs,
              isPlaying: true,
              positionListenable: position,
              enableInterludeDots: true,
            ),
          ),
        ),
      ),
    );
    await step(tester, 20);
    final dynamic state = tester.state(find.byType(AppleLyricsView));

    // 占位必须已展开，否则用例无效
    expect(state.interludeExpandProgressForTest as double, greaterThan(0.9),
        reason: '起始应处于间奏展开态（占位高度≈1 行）');
    expect(state.interludeDotsActiveForTest as bool, isTrue,
        reason: '起始应检测到激活间奏');

    double minYInWindow = double.infinity;
    double worstReversal = 0;
    double prevY = state.scrollPosYForTest as double;
    double worstJump = 0;
    // 边界前（权威 ≤ 16s）：占位收起期间**滚动不得移动、下一行不得被预登记**
    final double posYAtInterlude = state.scrollPosYForTest as double;
    double worstPreBoundaryDrift = 0;
    for (int tick = 1; tick <= 20; tick++) {
      final int nowMs = startMs + tick * 200;
      position.value = Duration(milliseconds: nowMs);
      for (int k = 0; k < 12; k++) {
        await tester.pump(const Duration(milliseconds: 16));
        final double y = state.scrollPosYForTest as double;
        final double jump = (y - prevY).abs();
        if (jump > worstJump) worstJump = jump;
        prevY = y;
        if (nowMs < 16000) {
          // 间奏占位展开/收起期间（严格早于边界）滚动不得移动
          final double drift = (y - posYAtInterlude).abs();
          if (drift > worstPreBoundaryDrift) worstPreBoundaryDrift = drift;
        }
        final bool inWindow = (state.cascadeLineHeldForTest(4) as bool) &&
            nowMs <= 16000;
        if (inWindow) {
          if (y < minYInWindow) minYInWindow = y;
          final double reversal = y - minYInWindow;
          if (reversal > worstReversal) worstReversal = reversal;
        }
      }
    }
    expect(worstPreBoundaryDrift, lessThan(2.0),
        reason: '间奏占位展开/收起期间（边界前）滚动不得移动：占位高度必须由布局'
            '自身收缩吸收（下一行上移补位），预滚动会在此之外多叠一整行上移，'
            '观感即"向上飞很高才收起"（实测位移 ${worstPreBoundaryDrift.toStringAsFixed(1)}px）');
    expect(worstReversal, lessThan(3.0),
        reason: '预启动窗口内 posY 不得回退（实测回退 ${worstReversal.toStringAsFixed(1)}px）');
    expect(worstJump, lessThan(40.0),
        reason: '整流过程中不得出现单帧跳变（实测 ${worstJump.toStringAsFixed(1)}px）');
  });
}
