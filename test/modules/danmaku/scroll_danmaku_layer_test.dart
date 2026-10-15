import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/danmaku/scroll_danmaku_layer.dart';

/// 自绘滚动弹幕层的行为测试。
///
/// 重点盯 AGENTS §10 的两件事：**帧率由共享节拍决定**（不另起 Ticker）、
/// **场上清空后必须解绑**（不可见/无内容仍在产帧是最常见的漏电点）。
Widget _host(ScrollDanmakuController controller, {double speed = 10000}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          height: 200,
          child: ScrollDanmakuLayer(controller: controller, speed: speed),
        ),
      ),
    ),
  );
}

DanmakuEntry _entry(String text, {int index = 0}) => DanmakuEntry(
      time: Duration.zero,
      text: text,
      id: 'e$index',
    );

void main() {
  test('未 attach 时调用命令不抛（宿主可能在弹层建出来之前就投递）', () {
    final controller = ScrollDanmakuController();
    expect(controller.isFlying, isFalse);
    expect(controller.liveCount, 0);
    controller.spawn(_entry('第一条'));
    controller.setFlying(false);
    controller.clear();
  });

  testWidgets('投放即订阅共享节拍；高速下飞完后自动解绑，不漏电', (tester) async {
    final controller = ScrollDanmakuController();
    await tester.pumpWidget(_host(controller));
    expect(PlayerFrameDriver.instance.isRunning, isFalse);

    controller.spawn(_entry('一条会很快飞出屏幕的弹幕'));
    expect(controller.liveCount, 1);
    expect(controller.isFlying, isTrue);
    expect(PlayerFrameDriver.instance.isRunning, isTrue);

    // speed=10000px/s、容器宽 300 → 一两拍就出屏。pump 会推进共享节拍的 Timer。
    await tester.pump(const Duration(milliseconds: 120));
    expect(controller.liveCount, 0, reason: '出屏条目应被移除');
    expect(controller.isFlying, isFalse, reason: '清空后必须解绑共享节拍');
    expect(PlayerFrameDriver.instance.isRunning, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setFlying(false) 冻住飞行：不产帧也不前进，条目仍留在场上', (tester) async {
    final controller = ScrollDanmakuController();
    // 低速：不 freeze 的话 120ms 内早飞完了，用来证明「暂停确实没推进」。
    await tester.pumpWidget(_host(controller, speed: 20));
    controller.spawn(_entry('暂停期间应冻在原地的弹幕'));
    expect(controller.isFlying, isTrue);

    controller.setFlying(false);
    expect(controller.isFlying, isFalse);

    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.isFlying, isFalse);
    expect(controller.liveCount, 1, reason: '暂停只停帧，不该清空场上弹幕');

    controller.setFlying(true);
    expect(controller.isFlying, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('同屏多条各占一条轨道，不叠字', (tester) async {
    final controller = ScrollDanmakuController();
    await tester.pumpWidget(_host(controller, speed: 20));
    for (var i = 0; i < 4; i++) {
      controller.spawn(_entry('第$i条弹幕', index: i));
    }
    expect(controller.liveCount, 4);
    // 200 高 × areaRatio 0.45 / 行高 ≈ 6 条轨道，4 条应落在 4 条不同轨道上。
    expect(controller.lanesInUse, 4, reason: '轨道够用时必须各占一条，不能叠字');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clear() 清屏并解绑（向后 seek 用）', (tester) async {
    final controller = ScrollDanmakuController();
    await tester.pumpWidget(_host(controller, speed: 20));
    controller.spawn(_entry('要被清掉的弹幕'));
    expect(controller.isFlying, isTrue);

    controller.clear();
    expect(controller.liveCount, 0);
    expect(controller.isFlying, isFalse);

    await tester.pumpWidget(const SizedBox());
  });
}
