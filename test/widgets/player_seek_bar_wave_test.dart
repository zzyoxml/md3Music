/// 波浪进度条的帧率约定回归测试（AGENTS.md §10）
///
/// 验证：
/// 1. md3Style + 播放中 → 订阅 PlayerFrameDriver 共享 60fps 节拍
/// 2. 暂停后波幅 250ms 收敛完成 → 必须解绑（不留空转帧提交）
/// 3. AM 皮肤（md3Style=false）播放中也绝不订阅
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/player_seek_bar.dart';

PlayerSeekBar _bar({
  required bool isPlaying,
  bool md3Style = true,
  bool waveEnabled = true,
}) => PlayerSeekBar(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
      isPlaying: isPlaying,
      md3Style: md3Style,
      waveEnabled: waveEnabled,
      activeColor: Colors.blue,
      inactiveColor: Colors.grey,
      labelColor: Colors.black,
    );

Widget _harness(PlayerSeekBar bar) =>
    MaterialApp(home: Scaffold(body: bar));

void main() {
  testWidgets('md3 皮肤播放中订阅共享节拍，暂停收敛后解绑', (tester) async {
    await tester.pumpWidget(_harness(_bar(isPlaying: true)));
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '播放中波浪相位应挂到共享 60fps 节拍上',
    );

    await tester.pumpWidget(_harness(_bar(isPlaying: false)));
    // 等波幅 250ms 收敛动画走完再断言解绑（§10.4：停帧条件覆盖动画收敛）
    await tester.pump(const Duration(milliseconds: 320));
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '波形压平后必须解绑，不可持续产帧',
    );
  });

  testWidgets('AM 皮肤播放中不订阅共享节拍', (tester) async {
    await tester.pumpWidget(_harness(_bar(isPlaying: true, md3Style: false)));
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  testWidgets('回退开关关闭时，播放中也不订阅共享节拍', (tester) async {
    await tester.pumpWidget(
      _harness(_bar(isPlaying: true, waveEnabled: false)),
    );
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '开关关闭即回退形态，不产帧',
    );
  });

  testWidgets('播放中关闭回退开关：波幅收敛后解绑', (tester) async {
    await tester.pumpWidget(_harness(_bar(isPlaying: true)));
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(
      _harness(_bar(isPlaying: true, waveEnabled: false)),
    );
    // 波幅 250ms 收敛动画走完才解绑（§10.4：停帧条件覆盖动画收敛）
    await tester.pump(const Duration(milliseconds: 320));
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  testWidgets('播放中重新打开回退开关：重新订阅', (tester) async {
    await tester.pumpWidget(
      _harness(_bar(isPlaying: true, waveEnabled: false)),
    );
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    await tester.pumpWidget(_harness(_bar(isPlaying: true)));
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);
  });
}
