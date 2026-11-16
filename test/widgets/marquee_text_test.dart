import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/marquee_text.dart';

/// [GentleScrollingText] 的帧率约定（AGENTS.md §10）：
/// 溢出滚动必须限帧到共享 60fps 节拍（不得用 Ticker），
/// 且不溢出 / 不可见时必须解绑驱动。
void main() {
  // 80px 宽下该文本必然溢出，从而进入滚动分支。
  const longText = '一个很长很长的歌名需要滚动才能看完';

  Widget host(Widget child, {bool tickerEnabled = true}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: TickerMode(
            enabled: tickerEnabled,
            child: SizedBox(width: 80, height: 24, child: child),
          ),
        ),
      ),
    );
  }

  setUp(() {
    // 用例之间不得残留订阅（上一个用例的 widget 已被 dispose）。
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '用例间不应残留驱动订阅',
    );
  });

  testWidgets('文本溢出且可见：挂共享 60fps 驱动，且不启动 Ticker', (tester) async {
    await tester.pumpWidget(host(const GentleScrollingText(longText)));
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '溢出滚动应挂共享 60fps 节拍（§10.3）',
    );
    // 关键断言：驱动源必须是 Timer 而非 Ticker。
    // 若仍用 repeat()，Ticker 会注册 transient callback，此处为 >0。
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '常驻滚动不得由 Ticker 驱动（AGENTS.md §10.4.1）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('文本不溢出：不挂驱动（完全静止）', (tester) async {
    await tester.pumpWidget(host(const GentleScrollingText('短')));
    await tester.pump();

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 关闭（被覆盖 / 切走）：解绑驱动', (tester) async {
    await tester.pumpWidget(host(const GentleScrollingText(longText)));
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    // 同一 State 重建为 TickerMode(false)，等价于被不透明路由覆盖 / TabBarView 切走。
    await tester.pumpWidget(
      host(const GentleScrollingText(longText), tickerEnabled: false),
    );
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '不可见必须解绑（§10.4.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose 后解绑，不留 pending timer', (tester) async {
    await tester.pumpWidget(host(const GentleScrollingText(longText)));
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox());

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });
}
