/// TvFocusHighlight 的停帧约定与连贯移动 / 贴合判据。
///
/// 1. 停帧（AGENTS.md §10.4.6）：旧的「Ticker 常驻 + 每帧 setState」会让 TV 包在任何
///    静止画面上持续产帧，120Hz 盒子上整页被顶满。以 `hasScheduledFrame` 为观测点：
///    焦点不动时不得再排帧；焦点变化后必须重新进入逐帧跟随。
/// 2. 连贯移动：焦点切换后红框不得瞬移（首帧仍在旧矩形），推进后落在新矩形；
///    圆角半径随目标形状变化（形变）。
/// 3. 贴合：焦点没变、矩形因布局变化而移动（模拟滚动）时必须立即跟着，不得滞后。
/// 4. 程序化滚动的唤醒（[TvFocusHighlightState.wake]）：Ticker 静音后，列表
///    「自动滚到当前曲」这类**不产生焦点变化**的滚动必须能重新唤醒跟随；
///    唤醒不得把正在滑行的红框冻住，也不得破坏静止停帧。
///
/// 焦点一律用显式 [FocusNode] + `requestFocus` 驱动（不用 tap）：`requestFocus`
/// 与遥控方向键走的是同一条 `FocusManager` 通知路径，也正是本组件的判据来源。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/ui_density.dart';
import 'package:md3music/core/remote/tv_focus_highlight.dart';

void main() {
  testWidgets('焦点静止时停帧，焦点变化后恢复跟随', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    focusNode: first,
                    autofocus: true,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                  Focus(
                    focusNode: second,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                ],
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );

    // 跟随若干拍后（静止判定阈值 10 拍）应静音 Ticker。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '焦点矩形静止后不得继续产帧（§10.4.6）',
    );

    // 焦点变化 → 唤醒，必须重新逐帧跟随。
    second.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '焦点变化后必须重新跟随（否则焦点框会停在旧位置）',
    );
  });

  testWidgets('焦点切换：首帧不瞬移，推进后落在新矩形', (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: Focus(
                focusNode: a,
                autofocus: true,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
            Positioned(
              left: 600,
              top: 400,
              child: Focus(
                focusNode: b,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );
    await tester.pump();

    // 首帧（史上没画过别处）直接落在 a 上。
    final startRect = _rectOfNode(tester, a).inflate(2);
    final target = _rectOfNode(tester, b).inflate(2);
    expect(_frameRect(tester), startRect);

    // 切换后第一帧只唤醒（dt=0），姿态停在起点。
    b.requestFocus();
    await tester.pump();
    expect(_frameRect(tester), startRect, reason: '唤醒帧不得推进');

    // 第二帧才真正起跑：仍在起点附近，但已在动。
    await tester.pump(const Duration(milliseconds: 80));
    final mid = _frameRect(tester);
    expect(mid.left, greaterThan(startRect.left));
    expect(mid.left, lessThan(target.left));
    expect(mid.top, lessThan(target.top));

    // 时长用尽后精确落在目标（外扩 2px）。距离 ≈ 758px → 420ms 封顶，
    // 约 27 帧（唤醒帧 dt=0，留足余量）。
    await pumpFrames(tester, 40);
    expect(_frameRect(tester), target);
  });

  testWidgets('形变：圆角半径随目标形状变化', (tester) async {
    final small = FocusNode();
    final big = FocusNode();
    addTearDown(small.dispose);
    addTearDown(big.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: Focus(
                focusNode: small,
                autofocus: true,
                child: const SizedBox(width: 20, height: 20),
              ),
            ),
            Positioned(
              left: 0,
              top: 120,
              child: Focus(
                focusNode: big,
                child: const SizedBox(width: 160, height: 160),
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );
    await tester.pump();
    // 20×20：20 * 0.22 = 4.4 → 夹到下限 6。
    expect(_frameRadius(tester), 6);

    // 唤醒帧 dt=0（见 _wake 的 _lastTickTime 复位），须再多给一帧才真正推进。
    big.requestFocus();
    await tester.pump();
    expect(_frameRadius(tester), 6, reason: '唤醒帧不推进，仍在起点半径');

    // 距离 ≈ 202px → 时长约 201ms，约 13 帧（唤醒帧 dt=0）。
    await pumpFrames(tester, 25);
    // 160×160：160 * 0.22 = 35.2 → 夹到上限 24。
    expect(_frameRadius(tester), 24);
  });

  testWidgets('内容在动：同焦点 + 布局位移 → 立即贴合，不滞后', (tester) async {
    final a = FocusNode();
    addTearDown(a.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: Focus(
                focusNode: a,
                autofocus: true,
                child: const SizedBox(width: 60, height: 40),
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(_frameRect(tester), _rectOfNode(tester, a).inflate(2));

    // 模拟滚动：整个子树右移 200px，焦点仍在 a 上（FocusManager 不发通知）。
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 200,
              top: 0,
              child: Focus(
                focusNode: a,
                child: const SizedBox(width: 60, height: 40),
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      _frameRect(tester),
      _rectOfNode(tester, a).inflate(2),
      reason: '内容自己在动时必须贴合（起滑行会累积成拖影）',
    );
  });

  testWidgets('静音后内容位移：wake() 唤醒跟随，停稳后重新停帧', (tester) async {
    final key = GlobalKey<TvFocusHighlightState>();
    final node = FocusNode();
    addTearDown(node.dispose);

    Widget build(double top) => MaterialApp(
      home: Stack(
        children: [
          Positioned(
            left: 0,
            top: top,
            child: Focus(
              focusNode: node,
              autofocus: true,
              child: const SizedBox(width: 60, height: 40),
            ),
          ),
          Positioned.fill(child: TvFocusHighlight(key: key)),
        ],
      ),
    );

    await tester.pumpWidget(build(0));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '前置：焦点静止后 Ticker 已静音',
    );

    // 播放列表「自动滚到当前曲」的等价场景：内容位移、焦点不变，
    // 且没有任何 FocusManager 通知。
    await tester.pumpWidget(build(200));
    await tester.pump();
    expect(
      _frameRect(tester),
      const Rect.fromLTRB(-2, -2, 62, 42),
      reason: '复现：静音时内容位移不会自己唤醒，红框停在旧位置（错位）',
    );

    // 宿主接住滚动通知后唤醒：必须立即贴合焦点元素。
    key.currentState!.wake();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      _frameRect(tester),
      _rectOfNode(tester, node).inflate(2),
      reason: '唤醒后红框必须贴住焦点元素',
    );

    // 滚动停止后重新静音：唤醒不得让 TV 包在静止画面持续产帧（§10.4.6）。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '停稳 10 拍后必须重新停帧',
    );
  });

  testWidgets('滑行中每帧 wake()（滚动通知）不得冻结滑行', (tester) async {
    final key = GlobalKey<TvFocusHighlightState>();
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: Focus(
                focusNode: a,
                autofocus: true,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
            Positioned(
              left: 600,
              top: 400,
              child: Focus(
                focusNode: b,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
            Positioned.fill(child: TvFocusHighlight(key: key)),
          ],
        ),
      ),
    );
    await tester.pump();

    b.requestFocus();
    await tester.pump();

    // 滚动期间每帧都会收到通知：wake() 在 Ticker 已在跑时必须无副作用，
    // 否则 _lastTickTime 每帧被复位、dt 恒为 0，滑行会停在起点直到滚动结束。
    for (var i = 0; i < 40; i++) {
      key.currentState!.wake();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      _frameRect(tester),
      _rectOfNode(tester, b).inflate(2),
      reason: '滚动通知不得把正在滑行的红框冻住',
    );
  });

  testWidgets('滚动通知唤醒：列表程序化 animateTo 后红框贴住焦点行', (tester) async {
    // 复刻 app.dart 的接线：NotificationListener → wake()。播放列表切歌后的
    // 「自动滚到当前曲」就是这条路径（滚动但不换焦点）。
    final key = GlobalKey<TvFocusHighlightState>();
    final controller = ScrollController();
    final node = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            key.currentState?.wake();
            return false;
          },
          child: Stack(
            children: [
              ListView.builder(
                controller: controller,
                itemCount: 40,
                itemBuilder: (context, index) => SizedBox(
                  height: 50,
                  child: index == 5
                      ? Focus(
                          focusNode: node,
                          autofocus: true,
                          child: const SizedBox.expand(),
                        )
                      : const SizedBox.expand(),
                ),
              ),
              Positioned.fill(child: TvFocusHighlight(key: key)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // 用户停留片刻：红框 Ticker 静音（切歌前真机常态）。
    await pumpFrames(tester, 20);
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '前置：静音状态',
    );

    // 程序化滚动（与 _scrollToCurrentSong 的 animateTo 同式），焦点不变。
    controller.animateTo(
      120,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    await tester.pump();
    await pumpFrames(tester, 30);

    expect(
      _frameRect(tester),
      _rectOfNode(tester, node).inflate(2),
      reason: '滚动通知必须唤醒跟随，红框不得留在滚动前的位置',
    );
  });

  testWidgets('减弱动态效果：切换后立刻落位', (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: Focus(
                  focusNode: a,
                  autofocus: true,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
              Positioned(
                left: 600,
                top: 400,
                child: Focus(
                  focusNode: b,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
              const Positioned.fill(child: TvFocusHighlight()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final target = _rectOfNode(tester, b).inflate(2);
    b.requestFocus();
    await tester.pump();
    expect(_frameRect(tester), target);
  });

  testWidgets('「显示大小」≠1 时红框按设计像素贴合（不偏 s 倍）', (tester) async {
    // 复现：app.dart 真实结构 MaterialApp.builder → DisplayScaleScope → Stack
    // （焦点内容 + TvFocusHighlight 同级）。修复前 _currentRect 用
    // localToGlobal 量到根（窗口）坐标、已含 FittedBox ×s，画进设计像素空间
    // 再被放大一次 → 红框落在 正确位置 × s（1.25 档：(600,400,40×40) 量成
    // (750,500,50×50)、外扩 2 后 (748,498,50×50)）。修复后量到设计像素锚点，
    // 逐像素贴合。DisplayScaleAnchor 第 2 帧才挂上（postFrame setState），
    // 需多 pump 一帧再等静止。
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DisplayScaleScope(
          scale: 1.25,
          child: Stack(
            children: [
              Positioned(
                left: 600,
                top: 400,
                child: Focus(
                  focusNode: node,
                  autofocus: true,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
              const Positioned.fill(child: TvFocusHighlight()),
            ],
          ),
        ),
      ),
    );
    // 锚点挂载帧 + 静止（>10 拍停帧阈值）。
    await tester.pump();
    await pumpFrames(tester, 20);

    expect(
      _frameRect(tester),
      // 设计像素 (600,400,40×40) 外扩 2：正确落位。锚点未挂的首帧回退根
      // 空间量到 ×1.25 的窗口坐标，第二帧起修正。
      Rect.fromLTWH(598, 398, 44, 44),
      reason: 's=1.25 时红框必须画在设计像素空间（修复前为 (748,498,50×50)）',
    );
  });

  testWidgets('Ticker 静音后换「显示大小」档位必须唤醒跟随', (tester) async {
    // 复现：换档既不产生 FocusManager 通知、也不是窗口 metrics 变化
    // （didChangeMetrics 不响）。修复前 Ticker 静音（§10.4.6 停帧）时换档，
    // 红框冻结在旧档位矩形上。修复后 didChangeDependencies 显式依赖
    // MediaQuery.size，换档 → 依赖变化 → 唤醒 → 红框落到新设计空间。
    final node = FocusNode();
    addTearDown(node.dispose);

    Widget hostAt(double scale) => MaterialApp(
          builder: (context, child) => DisplayScaleScope(
            scale: scale,
            child: Stack(
              children: [
                Center(
                  child: Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                ),
                const Positioned.fill(child: TvFocusHighlight()),
              ],
            ),
          ),
        );

    await tester.pumpWidget(hostAt(1.25));
    await tester.pump();
    await pumpFrames(tester, 20);
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '前置：静止后应已停帧',
    );
    final rectBefore = _frameRect(tester);
    // 1.25 档设计视口 640×480，中心焦点 (300,220,40×40) 外扩 2。
    expect(rectBefore, Rect.fromLTWH(298, 218, 44, 44));

    // 换档 1.25 → 1.5：设计视口从 640×480 变为 533.33×400（FittedBox 仍把
    // 设计空间铺满同一 800×600 物理窗口），Center 焦点落在设计空间中心
    // (246.67,180,40×40) 外扩 2 —— 断言值是运行实测，偏 s² 时会量成
    // (370,270) 附近（×1.5），一眼可辨。
    await tester.pumpWidget(hostAt(1.5));
    await tester.pump();
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '换档后必须重新逐帧跟随（修复前冻结在旧档矩形）',
    );
    await pumpFrames(tester, 20);
    expect(
      _frameRect(tester),
      rectMoreOrLessEquals(
        Rect.fromLTWH(244.67, 178, 44, 44),
        epsilon: 0.5,
      ),
      reason: '红框必须落到 1.5 档设计空间的中心矩形',
    );
  });
}

/// 当前红框绘制的矩形（无框时测试失败）。
Rect _frameRect(WidgetTester tester) {
  final painters = _framePainters(tester);
  expect(painters, hasLength(1), reason: '应有且只有一个焦点框 painter');
  return painters.single.rect;
}

/// 当前红框的圆角半径。
double _frameRadius(WidgetTester tester) => _framePainters(tester).single.radius;

List<TvFocusFramePainter> _framePainters(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<TvFocusFramePainter>()
    .toList();

/// 推进 [count] 个 16ms 帧。
///
/// 注意：单次 `pump(Duration)` 只会触发**一个** ticker 回调（dt 被
/// [kTvFocusFrameMaxTick] 夹到 100ms），所以"等一段时间"必须拆成多帧——这正是
/// 真机上 vsync 的样子。写成一次 `pump(900ms)` 只会推进约 100ms。
Future<void> pumpFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 指定 [FocusNode] 对应元素的屏幕矩形。
Rect _rectOfNode(WidgetTester tester, FocusNode node) {
  final element = node.context;
  expect(element, isNotNull, reason: 'FocusNode 必须已挂到树上');
  final box = element!.findRenderObject() as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
