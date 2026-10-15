// Zen 的 chrome 分层（计划 §2.1 / §0「Zen 的真缺口」/ R5）。
//
// 钉三件事：
// 1. 淡出到 0 之后子树必须退出命中树 —— Opacity(0) 不改命中测试，那会让看不见
//    的一条带子照样吃掉点击，Zen 下切页通道就全断了。
// 2. 折回可见后不能留在 Offstage 里（单向门会让 chrome 再也唤不出来）。
// 3. peek 倒计时渐隐（ZenChromeDim 的因子）只乘进不透明度，不得参与折叠判据。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/player_dock/zen_fade.dart';

const Key _chromeKey = Key('chrome');

Future<AnimationController> _pumpChrome(
  WidgetTester tester,
  double initialValue,
) async {
  final controller = AnimationController(
    vsync: tester,
    duration: const Duration(milliseconds: 220),
    value: initialValue,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ZenFade(
              animation: controller,
              child: const SizedBox(height: 96, key: _chromeKey),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ),
    ),
  );
  return controller;
}

bool _chromeOffstage(WidgetTester tester) {
  final offstages = tester.widgetList<Offstage>(
    find.descendant(
      of: find.byType(ZenFade),
      matching: find.byType(Offstage),
    ),
  );
  // 命中链上任何一层 Offstage(offstage: true) 都算被摘出手势树
  return offstages.any((w) => w.offstage);
}

/// 渲染出来的不透明度。测试的 child 是一个裸 `SizedBox`，ZenFade 子树里只有它自己
/// 那层 `Opacity`，所以这里不需要 `.first`。
double _renderedOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(of: find.byType(ZenFade), matching: find.byType(Opacity)),
    )
    .opacity;

/// 挂在本仓唯一的 [ZenChromeDim] 作用域下装载 chrome，[dim] 为初始压暗因子。
/// 同时回传控制器与因子，便于用例分别驱动「Zen 折叠」与「peek 渐隐」两条轴。
Future<(AnimationController chrome, ValueNotifier<double> dim)>
    _pumpScopedChrome(
      WidgetTester tester, {
      required double chromeValue,
      required double dim,
    }) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 220),
        value: chromeValue,
      );
      addTearDown(controller.dispose);
      final notifier = ValueNotifier<double>(dim);
      addTearDown(notifier.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZenChromeDim(
              notifier: notifier,
              child: Column(
                children: [
                  ZenFade(
                    animation: controller,
                    child: const SizedBox(height: 96, key: _chromeKey),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ),
      );
      return (controller, notifier);
    }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('动画为 0（常态）时 chrome 可见并占位', (tester) async {
    await _pumpChrome(tester, 0.0);
    expect(_chromeOffstage(tester), isFalse);
    expect(tester.getSize(find.byType(ZenFade)).height, 96);
    expect(
      tester.getRect(find.byKey(_chromeKey)).height,
      greaterThan(0),
      reason: '常态下 chrome 的点击目标必须真实存在',
    );
  });

  testWidgets('动画到 1（Zen）时 chrome 折成 0 高并退出命中树', (tester) async {
    final controller = await _pumpChrome(tester, 0.0);

    controller.value = 1.0;
    await tester.pump();

    expect(
      _chromeOffstage(tester),
      isTrue,
      reason: 'Opacity(0) 不改命中测试 —— 不 Offstage 就会留下一层看不见但拦手势的膜',
    );
    expect(tester.getSize(find.byType(ZenFade)).height, 0);
  });

  testWidgets('退出 Zen 后 chrome 回到树上且重新可交互', (tester) async {
    final controller = await _pumpChrome(tester, 1.0);
    expect(_chromeOffstage(tester), isTrue);

    controller.value = 0.0;
    await tester.pump();

    expect(
      _chromeOffstage(tester),
      isFalse,
      reason: 'Offstage 不能是单向门，否则 chrome 再也唤不出来',
    );
    expect(tester.getSize(find.byType(ZenFade)).height, 96);
  });

  // ── peek 倒计时渐隐：ZenChromeDim 的因子只压暗，不得动几何与命中树 ──

  testWidgets('作用域把因子乘进不透明度，但几何与命中树不受影响', (tester) async {
    final (_, dim) = await _pumpScopedChrome(
      tester,
      chromeValue: 0.0,
      dim: 0.5,
    );

    expect(
      _renderedOpacity(tester),
      closeTo(0.5, 0.001),
      reason: '未压暗的可见度 1.0 × 因子 0.5',
    );
    expect(_chromeOffstage(tester), isFalse);
    expect(
      tester.getSize(find.byType(ZenFade)).height,
      96,
      reason: '压暗只是视觉的，chrome 照常占位',
    );

    // 斜坡是「同一个 animation 一路改 notifier.value」驱动的，不重建 ZenFade 也该变
    dim.value = 0.2;
    await tester.pump();
    expect(
      _renderedOpacity(tester),
      closeTo(0.2, 0.001),
      reason: '因子变化应逐次反映到渲染的不透明度上，否则倒计时信号到不了用户眼里',
    );
    expect(tester.getSize(find.byType(ZenFade)).height, 96);
  });

  testWidgets('因子归 0 也不折叠、不摘出命中树（hidden 只认 Zen 动画）', (tester) async {
    await _pumpScopedChrome(tester, chromeValue: 0.0, dim: 0.0);

    expect(
      _chromeOffstage(tester),
      isFalse,
      reason: 'hidden 若改看「可见度 × 因子」，压暗到底会把还该用的 chrome 折掉',
    );
    expect(_renderedOpacity(tester), 0.0);
    expect(tester.getSize(find.byType(ZenFade)).height, 96);
  });

  testWidgets('Zen 到点：因子 0.2 与折叠叠加后仍折成 0 高并退出命中树', (tester) async {
    final (chrome, dim) = await _pumpScopedChrome(
      tester,
      chromeValue: 0.0,
      dim: 0.2,
    );

    dim.value = 0.2;
    chrome.value = 1.0;
    await tester.pump();

    expect(_chromeOffstage(tester), isTrue);
    expect(tester.getSize(find.byType(ZenFade)).height, 0);
    expect(_renderedOpacity(tester), 0.0);
  });
}
