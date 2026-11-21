import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/core/services/spectrum_disc_spin.dart';
import 'package:md3music/widgets/spectrum_artwork.dart';

/// 谱频圆盘在 **mini→full 封面形变期间**的两条行为：
/// 1. 环形频谱柱让位（目标不透明度 0），交接后再淡入回来 —— 否则整棵子树被槽位
///    `Opacity(0)` 隐藏，柱体会在交接帧突然显形；
/// 2. 封面旋转角取自**共享相位** [SpectrumDiscSpin]（不是组件私有），这是形变层
///    落位帧能与真身逐角度重合的前提。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final spin = SpectrumDiscSpin.instance;

  setUp(spin.reset);
  tearDown(() {
    spin.reset();
  });

  Widget host({required bool isPlaying, ValueListenable<double>? gate}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 320,
            child: SpectrumArtwork(
              artworkUri: null,
              isPlaying: isPlaying,
              bandCount: 8,
              morphProgress: gate,
            ),
          ),
        ),
      ),
    );
  }

  double ringTargetOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  double coverRotation(WidgetTester tester) {
    final t = tester.widget<Transform>(
      find.descendant(
        of: find.byType(SpectrumArtwork),
        matching: find.byType(Transform),
      ),
    );
    final m = t.transform;
    return math.atan2(m.entry(1, 0), m.entry(0, 0));
  }

  testWidgets('morphProgress 为 null：播放中目标不透明度 1，暂停 0', (tester) async {
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();
    expect(ringTargetOpacity(tester), 1.0);

    await tester.pumpWidget(host(isPlaying: false));
    await tester.pump();
    expect(ringTargetOpacity(tester), 0.0);
  });

  testWidgets('飞行途中（0<p<1）环形柱让位，端点恢复', (tester) async {
    final gate = ValueNotifier<double>(0.0);
    addTearDown(gate.dispose);

    await tester.pumpWidget(host(isPlaying: true, gate: gate));
    await tester.pump();
    expect(ringTargetOpacity(tester), 1.0, reason: '稳态（p=0）按播放态显示');

    gate.value = 0.5;
    await tester.pump();
    expect(ringTargetOpacity(tester), 0.0, reason: '飞行期必须让位，否则交接帧柱体硬闪');

    gate.value = 1.0;
    await tester.pump();
    expect(ringTargetOpacity(tester), 1.0, reason: '落位后恢复，由 AnimatedOpacity 350ms 淡入');
  });

  testWidgets('暂停 + 飞行：两者都要求让位', (tester) async {
    final gate = ValueNotifier<double>(0.5);
    addTearDown(gate.dispose);

    await tester.pumpWidget(host(isPlaying: false, gate: gate));
    await tester.pump();
    expect(ringTargetOpacity(tester), 0.0);
  });

  testWidgets('封面旋转角取自共享相位', (tester) async {
    spin.debugSetAngle(1.25);
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();
    expect(coverRotation(tester), closeTo(1.25, 1e-6));

    spin.debugSetAngle(2.5);
    await tester.pump();
    expect(coverRotation(tester), closeTo(2.5, 1e-6));
  });

  testWidgets('播放中登记为共享相位消费者，暂停即摘掉', (tester) async {
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();
    expect(spin.isSpinning, isTrue);
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(host(isPlaying: false));
    await tester.pump();
    expect(spin.isSpinning, isFalse);
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  testWidgets('销毁后不残留消费者与节拍订阅', (tester) async {
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();
    expect(spin.isSpinning, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(spin.isSpinning, isFalse);
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });
}
