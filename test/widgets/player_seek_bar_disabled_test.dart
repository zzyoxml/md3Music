import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_seek_bar.dart';

/// 只读进度条（一起听听众端）。
///
/// 成员拖动进度会被远端纠偏立刻拉回（见 `ListenTogetherProvider.followingAsGuest`
/// 与 `RoomSession.guestResyncAfterSeek`），所以成员态下进度条必须退化成只读
/// 指示器：不响应点按/拖动、不下发 seek、也不进入拖动流程（`onSeekStart` 会
/// `pauseForSeek()`，被漏出去会无端暂停播放）。
///
/// 这里钉的是**手势闸门本身**，防止将来调整动画时把闸门绕过去。
Widget _host({
  required bool enabled,
  ValueChanged<Duration>? onSeekEnd,
  VoidCallback? onDisabledTap,
  VoidCallback? onSeekStart,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 300,
        child: PlayerSeekBar(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 3),
          activeColor: Colors.red,
          inactiveColor: Colors.grey,
          labelColor: Colors.black,
          enabled: enabled,
          onSeekEnd: onSeekEnd,
          onDisabledTap: onDisabledTap,
          onSeekStart: onSeekStart,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('只读态：点按不下发 seek，只给「为什么拖不动」的提示', (tester) async {
    final seeks = <Duration>[];
    var hints = 0;
    await tester.pumpWidget(
      _host(enabled: false, onSeekEnd: seeks.add, onDisabledTap: () => hints++),
    );

    await tester.tap(find.byType(PlayerSeekBar));
    await tester.pump();

    expect(seeks, isEmpty, reason: '只读态不得下发 seek');
    expect(hints, 1, reason: '应给出提示，否则用户只看到一条拖不动的线');
  });

  testWidgets('只读态：水平拖动不下发 seek，也不进入拖动流程', (tester) async {
    final seeks = <Duration>[];
    var seekStarts = 0;
    await tester.pumpWidget(
      _host(
        enabled: false,
        onSeekEnd: seeks.add,
        onSeekStart: () => seekStarts++,
        onDisabledTap: () {},
      ),
    );

    await tester.drag(find.byType(PlayerSeekBar), const Offset(120, 0));
    await tester.pump();

    expect(seeks, isEmpty, reason: '只读态不得下发 seek');
    expect(
      seekStarts,
      0,
      reason: '不得进入拖动流程：onSeekStart 会 pauseForSeek，漏出去会无端暂停播放',
    );
  });

  testWidgets('可交互态：点按照常下发一次 seek（回归守卫）', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(_host(enabled: true, onSeekEnd: seeks.add));

    await tester.tap(find.byType(PlayerSeekBar));
    await tester.pumpAndSettle();

    expect(seeks.length, 1, reason: '可交互态行为不得被本次改动影响');
    // 300px 轨道的中点即 50% → 3 分钟的一半
    expect(seeks.single.inSeconds, closeTo(90, 2));
  });
}
