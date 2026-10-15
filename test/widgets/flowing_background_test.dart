import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/flowing_background.dart';

/// [FlowingBackground] 的驱动约定（AGENTS.md §10 / 功耗分析报告 P0-1、P0-2）：
///
/// - 流光必须挂在全局共享节拍 [PlayerFrameDriver] 上、每 2 拍推进一次（≈30fps），
///   不得再自建独立 `Timer.periodic`；
/// - 停帧判据必须覆盖「暂停」「被不透明路由覆盖（TickerMode=false）」「移出树」
///   三种场景，即解绑驱动 → `PlayerFrameDriver.instance.hasListeners == false`。
///
/// 全部用例只以 `hasListeners`（公开诊断属性）为观测点，不引入任何生产代码测试钩子。
void main() {
  // 结构保持稳定，只切 TickerMode.enabled —— 这样同一 State 被复用，
  // 才能真正走到 didChangeDependencies 的同步路径（而不是重建 initState）。
  Widget host(Widget child, {bool tickerEnabled = true}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: TickerMode(
            enabled: tickerEnabled,
            child: SizedBox(width: 300, height: 600, child: child),
          ),
        ),
      ),
    );
  }

  // artworkUrl 传 null：不触发任何封面下载/取色，用例只关心驱动订阅状态。
  Widget flowing({bool isPlaying = true}) =>
      host(FlowingBackground(artworkUrl: null, isPlaying: isPlaying));

  setUp(() {
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '用例之间不得残留共享节拍订阅（否则互相污染）',
    );
  });

  tearDown(() {
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '用例结束必须已解绑（dispose/deactivate 不泄漏）',
    );
  });

  testWidgets('暂停时不挂共享节拍（完全静止）', (tester) async {
    await tester.pumpWidget(flowing(isPlaying: false));
    await tester.pump();
    // 跨过 400ms 入场延迟，确认"确实是因为没在播"而不是"还没到时间"。
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'isPlaying=false 时不得占用共享节拍',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放中：过完 400ms 入场延迟后挂共享节拍', (tester) async {
    await tester.pumpWidget(flowing());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '入场延迟（400ms）走完之前不得开跑，避免与路由入场动画叠加',
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '播放中且可见时应挂共享 60fps 节拍，在回调内每 2 拍推进一次（§10.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 关闭（被不透明路由覆盖）：不挂共享节拍', (tester) async {
    await tester.pumpWidget(
      host(FlowingBackground(artworkUrl: null, isPlaying: true),
          tickerEnabled: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '被覆盖时必须停帧（§10.4.3：不可见仍持续 tick 是本仓最常见漏电点）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 由关闭切回开启：经 didChangeDependencies 重新挂上',
      (tester) async {
    await tester.pumpWidget(
      host(FlowingBackground(artworkUrl: null, isPlaying: true),
          tickerEnabled: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    // 同一 State 重建为 TickerMode(true)，等价于路由 pop / TabBarView 切回。
    await tester.pumpWidget(flowing());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '重新可见必须立刻恢复驱动（依赖 didChangeDependencies 而非重建）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('移出树后解绑，不留订阅', (tester) async {
    await tester.pumpWidget(flowing());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'dispose/deactivate 必须解绑，否则离屏仍持续产帧',
    );
  });
}